; drivers/autohotkey/lib/toml/toml_config_loader.ahk

; ==============================================================================
; MODULE: TOML Config Loader
; DESCRIPTION:
; Reads the user ``config.toml`` produced by the first-boot generator from
; ``_shared/features/manifest.toml``. Distinct from the legacy ``toml_loader.ahk``
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
; 3. Unknown sections (not present in the post-manifest Features Map) trigger a
;    WARN at boot but never abort — the user's config can carry stale keys that
;    no longer exist in the manifest without breaking the driver.
; 4. Dormant until cut-over: written ahead of the migration so the disruptive
;    PR can be focused on call-site rewrites only.
; ==============================================================================





; ==============================================================
; =================================
; ======= 1. Value coercion =======
; =================================
; ==============================================================

; Coerce a raw TOML literal to an AHK value. Extends the base ``TomlCoerceValue``
; with single-line array support (``[a, b, c]``). Nested arrays and inline
; tables are intentionally NOT supported here — keep the user config simple.
TomlCoerceValueExt(Raw) {
	Trimmed := Trim(Raw, " `t")

	; Array literal — naive single-line split on commas. Acceptable because the
	; manifest-generated templates never contain commas inside string values.
	if (StrLen(Trimmed) >= 2
		and SubStr(Trimmed, 1, 1) == "["
		and SubStr(Trimmed, StrLen(Trimmed), 1) == "]") {
		Inner := SubStr(Trimmed, 2, StrLen(Trimmed) - 2)
		Result := []
		if (Trim(Inner) != "") {
			for Item in StrSplit(Inner, ",") {
				Result.Push(TomlCoerceValueExt(Trim(Item, " `t")))
			}
		}
		return Result
	}

	; Delegate primitive coercion to the v1 helper to keep the rules in one
	; place (true/false/integer/float/quoted-string fallback).
	return TomlCoerceValue(Trimmed)
}





; ==============================================================
; ==================================
; ======= 2. Apply v2 config =======
; ==================================
; ==============================================================

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
; downstream ``.Enabled`` access (discovered the hard way during Phase 1
; of the sliced cut-over). During the cut-over production passes
; ``Features``; tests pass their isolated Map fixture.
ApplyConfigToml(Features, FilePath) {
	Applied := 0
	if !FileExist(FilePath) {
		try LoggerDebug("TomlConfigLoader", "v2 config.toml not found at '{1}' — skipping.", FilePath)
		return Applied
	}
	try LoggerStart("TomlConfigLoader", "Applying v2 config from '{1}'…", FilePath)

	CurrentSection := ""
	SkippingForeign := false

	loop parse, ReadTomlFile(FilePath), "`n", "`r" {
		Line := Trim(A_LoopField, " `t")
		if (Line == "" or SubStr(Line, 1, 1) == "#") {
			continue
		}

		; Section header — capture the dotted path and decide whether to apply
		; or skip its contents.
		if RegExMatch(Line, "^\[([^\[\]]+)\]$", &SecMatch) {
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
		if RegExMatch(Line, "^`"([^`"\\]+)`"\s*=\s*(.+)$", &Match) {
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
		Parts := StrSplit(CurrentSection, ".")
		Node := Features
		Failed := false
		for Part in Parts {
			if (Part == "") {
				continue
			}
			if (Type(Node) == "Map" and Node.Has(Part)) {
				Node := Node[Part]
			} else if (IsObject(Node) and Node.HasOwnProp(Part)) {
				Node := Node.%Part%
			} else {
				Failed := true
				break
			}
		}
		if Failed {
			try LoggerWarn("TomlConfigLoader",
				"v2 override skipped — unknown section path '{1}'.", CurrentSection)
			continue
		}

		; Assign the leaf key on the resolved node. Nested Map vs object
		; properties are both accepted to match the legacy Features shape.
		try {
			if (Type(Node) == "Map") {
				Node[Key] := Value
			} else if IsObject(Node) {
				Node.%Key% := Value
			} else {
				try LoggerWarn("TomlConfigLoader",
					"v2 override skipped — '[{1}]' is not an object.", CurrentSection)
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
