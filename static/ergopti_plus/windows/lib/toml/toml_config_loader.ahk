; lib/toml/toml_config_loader.ahk

; ==============================================================================
; MODULE: TOML Config Loader
; DESCRIPTION:
; Reads the user ``config.toml`` produced by the first-boot generator from
; ``_shared/modules/features/manifest.toml``. Distinct from the legacy ``toml_loader.ahk``
; which only handles flat ``[script]``/``[features]`` overrides — this loader
; supports arbitrarily nested sections (``[hotstrings.autocorrection.accents]``)
; and simple array values (``val_modifiers = ["alt"]``).
;
; FEATURES & RATIONALE:
; 1. Strips the ``ahk.`` prefix on section headers so a v2 source section like
;    ``[ahk.layout]`` lands on the in-memory ``Features["layout"]`` Map — same
;    nesting depth as the legacy hardcoded literal.
; 2. Skips any ``[hs.*]`` section silently (foreign to this driver). They live
;    in the same TOML by design (single user-editable file per driver) but the
;    HS driver is the only consumer.
; 3. Unknown sections (not present in the post-manifest Features Map) trigger an
;    ERROR at boot but never abort — the driver still applies every valid key so
;    a single typo or stale section does not wipe the user's configuration. The
;    ERROR level ensures the problem is impossible to miss during log review.
; 4. Dormant until cut-over: written ahead of the migration so the disruptive
;    PR can be focused on call-site rewrites only.
; 5. ``hotstrings.personal.<user-chosen-name>`` and ``personal_editor`` are
;    exempt from the manifest-tree validation in (3): their leaf names are
;    per-user runtime data (personal hotstring categories, editor UI prefs),
;    not compile-time schema, so missing segments are auto-vivified rather
;    than logged as an error.
; 6. An EXISTING ``config.toml`` that cannot be READ latches
;    ``_ConfigBootReadFailed`` (declared with its siblings in ``toml_helpers``).
;    It is the session-wide "the feature tree in memory is defaults, not the
;    user's settings" signal that ``SaveFullConfig`` honours, and it is
;    deliberately never cleared: nothing re-applies the config in-process, so
;    the tree stays untrustworthy until the driver restarts.
; ==============================================================================





; =================================
; =================================
; ======= 1. Value coercion =======
; =================================
; =================================

; True when ``SectionPath`` is a namespace that is inherently dynamic and can
; never be enumerated in the static, compile-time manifest:
;   - ``hotstrings.personal.<name>`` — <name> is a user-chosen personal
;     hotstring category created at runtime via the personal TOML editor
;     (see EnsurePersonalHotstringFeature in lib/personal_features.ahk).
;   - ``personal_editor`` — flat UI-preference keys written directly by
;     ui/personal_toml_editor.ahk via TOML_Write/TOML_Read, never routed
;     through the manifest-built Features tree at all.
; Both would otherwise fail the "every segment must already exist in the
; manifest" walk below on every single boot, since neither can be declared
; ahead of time in manifest.toml.
TomlSectionIsDynamicPersonalNamespace(SectionPath) {
	if (SectionPath == "personal_editor") {
		return true
	}
	return (StrLen(SectionPath) >= 19 and SubStr(SectionPath, 1, 19) == "hotstrings.personal")
		and (SectionPath == "hotstrings.personal" or SubStr(SectionPath, 20, 1) == ".")
}

; Coerce a raw TOML literal to an AHK value. Extends the base ``TomlCoerceValue``
; with single-line array support (``[a, b, c]``). Nested arrays and inline
; tables are intentionally NOT supported here — keep the user config simple.
TomlCoerceValueExt(Raw) {
	Trimmed := Trim(Raw, " `t")

	; Array literal — quote-aware split so commas inside quoted strings are not
	; treated as element separators (e.g. ["foo, bar", "baz"] must yield two
	; items, not three). Uses the same algorithm as CS_CoerceValue.
	if (StrLen(Trimmed) >= 2
		and SubStr(Trimmed, 1, 1) == "["
		and SubStr(Trimmed, StrLen(Trimmed), 1) == "]") {
		Inner := SubStr(Trimmed, 2, StrLen(Trimmed) - 2)
		Result := []
		if (Trim(Inner) != "") {
			in_str  := false
			escaped := false
			cur     := ""
			for ch in StrSplit(Inner) {
				c := ch
				if escaped {
					escaped := false
				} else if (c == "\") {
					escaped := true
				} else if (c == Chr(0x22)) {
					in_str := !in_str
				} else if (!in_str && c == ",") {
					Result.Push(TomlCoerceValueExt(Trim(cur, " `t")))
					cur := ""
					continue
				}
				cur .= c
			}
			if (Trim(cur, " `t") != "")
				Result.Push(TomlCoerceValueExt(Trim(cur, " `t")))
		}
		return Result
	}

	; Delegate primitive coercion to the v1 helper to keep the rules in one
	; place (true/false/integer/float/quoted-string fallback).
	return TomlCoerceValue(Trimmed)
}





; ==================================
; ==================================
; ======= 2. Apply v2 config =======
; ==================================
; ==================================

; Apply the user's v2 ``config.toml`` onto the given v2-shaped Features Map.
; Returns the number of overrides applied (mostly for diagnostics).
; Idempotent and resilient to a missing file (returns 0 silently).
;
; The caller passes the target Map explicitly so this loader can never
; accidentally clobber a v1-shaped global. The v1 PascalCase section names
; (``Layout``, ``Shortcuts``, ``TapHolds``, ``Gestures``, ``LLM``,
; ``Metrics``, ``Script``, ``Hotstrings``) coincidentally also exist as
; top-level v1 ``Features`` Map keys; without the explicit parameter, the
; loader would walk those v1 entries and overwrite the inner
; ``{Enabled: True}`` object literals with plain booleans, breaking every
; downstream ``.Enabled`` access (discovered the hard way during the
; of the sliced cut-over). During the cut-over production passes
; ``Features``; tests pass their isolated Map fixture.
ApplyConfigToml(Features, FilePath) {
	Applied := 0
	if !FileExist(FilePath) {
		try LoggerDebug("TomlConfigLoader", "v2 config.toml not found at '{1}' — skipping.", FilePath)
		return Applied
	}
	try LoggerStart("TomlConfigLoader", "Applying v2 config from '{1}'…", FilePath)

	; Read once and check for an unreadable-but-existing file BEFORE applying
	; anything. ReadTomlFile returns "" in that case, which `loop parse` happily
	; treats as "zero overrides" — leaving Features at manifest DEFAULTS while
	; the apply still logs SUCCESS "0 value(s)". The deferred boot save then
	; serializes that default tree over the user's real config. Abort loudly and
	; latch the failure so SaveFullConfig refuses to persist the feature tree.
	global _ConfigBootReadFailed
	Content := ReadTomlFile(FilePath)
	if TOML_UnreadableFile(FilePath) {
		_ConfigBootReadFailed := true
		try LoggerError("TomlConfigLoader",
			"v2 config at '{1}' exists but could not be read — applying NOTHING and blocking config persistence so the defaults now in memory cannot overwrite it.", FilePath)
		return -1
	}

	CurrentSection := ""
	SkippingForeign := false

	loop parse, Content, "`n", "`r" {
		Line := Trim(A_LoopField, " `t")
		if (Line == "" or SubStr(Line, 1, 1) == "#") {
			continue
		}

		; Section header — capture the dotted path and decide whether to apply
		; or skip its contents. The comment is cut first because this pattern is
		; anchored: on a commented header it simply fails to match, the line
		; falls through to the key parser, fails that too, and ``continue``
		; leaves CurrentSection on the PREVIOUS section — so every key that
		; follows is silently applied to the wrong section.
		if RegExMatch(TOML_StripInlineComment(Line), "^\[([^\[\]]+)\]$", &SecMatch) {
			Header := Trim(SecMatch[1])
			SkippingForeign := false

			; ``[hs.*]`` belongs to the Hammerspoon driver — skip silently.
			if (StrLen(Header) >= 3 and SubStr(Header, 1, 3) == "hs.") {
				CurrentSection := ""
				SkippingForeign := true
				continue
			}

			; ``[_meta]`` and any ``[_*]`` section are TOML metadata blocks, not
			; driver features. ``[updater]`` / ``[ahk.updater]`` is consumed by the
			; updater module at start-up independently of the Features Map. Both skip
			; silently. The ahk. prefix is stripped later, so match both forms here.
			if (SubStr(Header, 1, 1) == "_" or Header == "updater" or Header == "ahk.updater") {
				CurrentSection := ""
				SkippingForeign := true
				continue
			}

			; Strip the ``ahk.`` prefix so the in-memory path matches the
			; Features Map built by ManifestBuildFeaturesMap (which also strips).
			if (StrLen(Header) >= 4 and SubStr(Header, 1, 4) == "ahk.") {
				Header := SubStr(Header, 5)
			}
			CurrentSection := Header
			continue
		}

		if (CurrentSection == "" and !SkippingForeign) {
			; Out-of-section key=value lines are not part of v2.
			continue
		}
		if SkippingForeign {
			continue
		}

		; Parse ``key = value``. Quoted keys are accepted for IDs that
		; contain reserved characters (rare in the manifest-generated config).
		if RegExMatch(Line, '^"([^"\\]+)"\s*=\s*(.+)$', &Match) {
			Key := Match[1]
			Value := TomlCoerceValueExt(Match[2])
		} else if RegExMatch(Line, "^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$", &Match) {
			Key := Match[1]
			Value := TomlCoerceValueExt(Match[2])
		} else {
			continue
		}

		; Walk the section path. Each segment must already exist in Features —
		; the manifest defines the universe of valid paths. Unknown paths
		; trigger a WARN and are skipped.
		;
		; Exception: hotstrings.personal.<user-chosen-name> and personal_editor
		; are dynamic, per-user namespaces that structurally cannot appear in the
		; static manifest (see TomlSectionIsDynamicPersonalNamespace) — missing
		; segments are auto-vivified as empty Maps instead of being rejected.
		IsDynamicPersonalNamespace := TomlSectionIsDynamicPersonalNamespace(CurrentSection)
		Parts := StrSplit(CurrentSection, ".")
		Node := Features
		Failed := false
		for _, Part in Parts {
			if (Part == "") {
				continue
			}
			if (Type(Node) == "Map" and Node.Has(Part)) {
				Node := Node[Part]
			} else if (IsObject(Node) and Node.HasOwnProp(Part)) {
				Node := Node.%Part%
			} else if (IsDynamicPersonalNamespace and Type(Node) == "Map") {
				Node[Part] := Map()
				Node := Node[Part]
			} else {
				Failed := true
				break
			}
		}
		if Failed {
			; An unknown section path means the user config contains a key that
			; does not exist in the manifest — likely a typo or a stale key left
			; over from an older schema version. Surface it as an error so it is
			; impossible to miss in the logs, but do not abort the driver (the
			; remaining valid keys are still applied).
			try LoggerError("TomlConfigLoader",
				"v2 override skipped — unknown section path '[{1}]' not found in the manifest.", CurrentSection)
			continue
		}

		; Assign the leaf key on the resolved node. Nested Map vs object
		; properties are both accepted to match the legacy Features shape.
		try {
			if (Type(Node) == "Map") {
				; Refuse to flatten a seeded Map node (e.g. {enabled:...}) into a scalar via a
				; colliding flat-form [section] key (or vice versa) — that clobbers the shape and
				; crashes a later [...]["enabled"] access (toml-loader-shape-mismatch).
				if (Node.Has(Key) and (Node[Key] is Map) != (Value is Map)) {
					try LoggerWarn("TomlConfigLoader",
						"v2 override skipped - [{1}].{2} would change Map/scalar shape; keeping the manifest-seeded node.", CurrentSection, Key)
					continue
				}
				Node[Key] := Value
			} else if IsObject(Node) {
				Node.%Key% := Value
			} else {
				try LoggerError("TomlConfigLoader",
					"v2 override skipped — '[{1}]' resolved to a scalar, not an object — check the manifest shape.", CurrentSection)
				continue
			}
			Applied++
			try LoggerDebug("TomlConfigLoader", "[{1}].{2} = {3}.", CurrentSection, Key, Value)
		} catch as e {
			try LoggerWarn("TomlConfigLoader",
				"v2 override failed for [{1}].{2}: {3}.", CurrentSection, Key, e.Message)
		}
	}

	try LoggerSuccess("TomlConfigLoader", "v2 config applied ({1} value(s)).", Applied)
	return Applied
}
