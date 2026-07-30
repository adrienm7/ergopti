; lib/tap_hold/tap_hold_loader.ahk

; ==============================================================================
; MODULE: Tap-Hold Loader
; DESCRIPTION:
; Loads tap-hold configuration into a hierarchical Map. Supports an optional
; defaults overlay: when ``DefaultsFilePath`` is supplied, the shared
; ``_shared/tap_hold/defaults.toml`` is parsed first, then the user file is
; merged on top — user values win, absent user keys inherit the default. This
; means editing ``defaults.toml`` takes effect on every reload even when the
; user file exists, satisfying the cross-driver consistency goal.
;
; FEATURES & RATIONALE:
; 1. Single-pass TOML parser tailored to the tap_hold schema — supports
;    ``[tap_hold.keys.<id>]`` and ``[tap_hold.layers.<id>.mappings]`` sections
;    only. The full TOML grammar is intentionally NOT supported here: this is
;    a narrow file format produced by the codegen pipeline.
; 2. Returns a hierarchical Map with the shape:
;        TapHold["keys"]["caps_lock"]["tap_action"]        = "enter"
;        TapHold["keys"]["caps_lock"]["hold_modifier"]     = "ctrl"
;        TapHold["keys"]["caps_lock"]["time_activation_seconds"] = 0.35
;        TapHold["layers"]["nav"]["mappings"]["h"]         = "arrow_left"
; 3. Runtime overlay: when DefaultsFilePath is given, defaults are loaded
;    first and user values are merged on top. Absent user keys inherit the
;    default so ``time_activation_seconds`` changes in defaults.toml take
;    effect without requiring a user-file edit.
; 4. Backward-compatible: callers that omit DefaultsFilePath behave exactly
;    as before — only the user file is parsed.
; ==============================================================================

; Default per-key tap-hold activation threshold in seconds, used when a key has
; no time_activation_seconds (e.g. a tap-only override under inherit_defaults =
; false). Single source for the former 0.2 literal that TapHoldDuration used to
; duplicate across its two return branches
global TAPHOLD_DEFAULT_ACTIVATION_SECONDS := 0.2
; Upper sanity bound for a hold threshold read from the user-editable
; tap_hold.toml. A hold longer than this is certainly a typo (a stray unit, a
; misplaced decimal point) rather than an intent, and the value is concatenated
; straight into a KeyWait timeout — so anything past it is rejected at the
; loader boundary instead of stalling a hotkey thread for minutes.
global TAPHOLD_MAX_ACTIVATION_SECONDS := 10





; ==============================================================
; =====================================
; ======= 1. Public entry point =======
; =====================================
; ==============================================================

; Read ``FilePath`` (user config) and return the hierarchical TapHold Map.
; When ``DefaultsFilePath`` is supplied the shared defaults are loaded first
; and the user file is merged on top — user values take precedence, absent
; user keys inherit the default value.
; On missing or unreadable user file the defaults (if provided) are returned
; as-is so a fresh install still gets working defaults after first boot.
LoadTapHoldToml(FilePath, DefaultsFilePath := "") {
	try LoggerDebug("TapHoldLoader", "LoadTapHoldToml start: user='{1}', defaults='{2}'.", FilePath, DefaultsFilePath)
	Result := Map("keys", Map(), "layers", Map())
	InheritDefaults := true

	; Parse the user file once into UserData. Extract inherit_defaults from
	; the result so we do not need a second pre-flight read of the same file.
	; The data is later merged on top of the defaults overlay so the final
	; order is still: defaults → user (user wins per-key).
	UserData := Map("keys", Map(), "layers", Map())
	if FileExist(FilePath)
		_TapHold_ParseFileInto(FilePath, UserData)
	else
		try LoggerDebug("TapHoldLoader", "No user tap-hold file found yet at '{1}'.", FilePath)

	if UserData.Has("inherit_defaults") {
		InheritDefaults := !!UserData["inherit_defaults"]
		; Carry the flag into the map we RETURN, not only into this local. The
		; writer gates its ``[tap_hold]`` emit on Data.Has("inherit_defaults")
		; (tap_hold_writer.ahk), and it serializes the live TapHold global — so a
		; loader that keeps the flag to itself makes the opt-out a one-way trip:
		; the next individual tray write drops the line and the following reload
		; re-merges every shipped default, undoing « Tout désactiver ».
		Result["inherit_defaults"] := InheritDefaults
	}

	try LoggerDebug("TapHoldLoader", "Parsed user tap-hold: {1} key(s), {2} layer(s), inherit_defaults={3}.",
		UserData["keys"].Count, UserData["layers"].Count, InheritDefaults)

	; Load shared defaults first when the caller supplies the path. Missing
	; defaults file is non-fatal (logs a debug notice and continues).
	if (DefaultsFilePath != "" and InheritDefaults) {
		if FileExist(DefaultsFilePath) {
			try LoggerDebug("TapHoldLoader", "Loading tap-hold defaults from '{1}'…", DefaultsFilePath)
			_TapHold_ParseFileInto(DefaultsFilePath, Result)
		} else {
			try LoggerDebug("TapHoldLoader", "Shared defaults not found at '{1}' — skipping.", DefaultsFilePath)
		}
	} else if (DefaultsFilePath != "" and !InheritDefaults) {
		try LoggerDebug("TapHoldLoader", "Skipping shared defaults load because inherit_defaults=false in user tap-hold file.")
	}

	if !FileExist(FilePath) {
		try LoggerDebug("TapHoldLoader", "tap_hold.toml not found at '{1}' — skipping.", FilePath)
		try LoggerSuccess("TapHoldLoader", "Tap-hold config loaded ({1} key(s), {2} layer(s)) — defaults only.",
			Result["keys"].Count, Result["layers"].Count)
		return Result
	}
	try LoggerStart("TapHoldLoader", "Loading tap-hold config from '{1}'…", FilePath)

	; Merge user data (already parsed above) on top of defaults.
	; Per-key fields overwrite default fields individually so a user entry
	; that sets only tap_action still inherits time_activation_seconds from
	; the default for that key.
	; NOTE: must iterate field-by-field, NOT assign the whole user Map, or the
	; defaults-populated Map for that key is replaced entirely and inherited
	; fields (e.g. time_activation_seconds) are lost.
	for k, v in UserData["keys"] {
		if !Result["keys"].Has(k)
			Result["keys"][k] := Map()
		; hold_modifier / hold_layer are mutually exclusive: evict the opposite
		; field that may have come from the defaults overlay.
		if v.Has("hold_modifier") and Result["keys"][k].Has("hold_layer")
			Result["keys"][k].Delete("hold_layer")
		else if v.Has("hold_layer") and Result["keys"][k].Has("hold_modifier")
			Result["keys"][k].Delete("hold_modifier")
		for field, val in v
			Result["keys"][k][field] := val
	}

	if UserData["keys"].Has("left_ctrl") {
		try LoggerDebug("TapHoldLoader", "User override includes left_ctrl: tap_action='{1}', hold_modifier='{2}', hold_layer='{3}'.",
			UserData["keys"]["left_ctrl"].Has("tap_action") ? (UserData["keys"]["left_ctrl"]["tap_action"] == "" ? "<native>" : UserData["keys"]["left_ctrl"]["tap_action"]) : "<unset>",
			UserData["keys"]["left_ctrl"].Has("hold_modifier") ? UserData["keys"]["left_ctrl"]["hold_modifier"] : "<unset>",
			UserData["keys"]["left_ctrl"].Has("hold_layer") ? UserData["keys"]["left_ctrl"]["hold_layer"] : "<unset>")
	}
	for k, v in UserData["layers"] {
		if !Result["layers"].Has(k)
			Result["layers"][k] := Map("mappings", Map())
		for field, val in v {
			if (field == "mappings") {
				if !Result["layers"][k].Has("mappings")
					Result["layers"][k]["mappings"] := Map()
				for mk, mv in val
					Result["layers"][k]["mappings"][mk] := mv
			} else {
				Result["layers"][k][field] := val
			}
		}
	}

	if Result["keys"].Has("left_ctrl") {
		LCfg := Result["keys"]["left_ctrl"]
		try LoggerDebug("TapHoldLoader", "Resolved left_ctrl after merge: tap_action='{1}', hold_modifier='{2}', hold_layer='{3}', inherit_defaults={4}.",
			LCfg.Has("tap_action") ? (LCfg["tap_action"] == "" ? "<native>" : LCfg["tap_action"]) : "<unset>",
			LCfg.Has("hold_modifier") ? LCfg["hold_modifier"] : "<unset>",
			LCfg.Has("hold_layer") ? LCfg["hold_layer"] : "<unset>",
			InheritDefaults ? "true" : "false")
	}

	; Truncated-write sentinel: the user file exists yet the merged config has
	; zero keys AND the user did NOT explicitly opt out via inherit_defaults =
	; false. The only legitimate way to reach an empty keys map is the explicit
	; opt-out (« Tout desactiver »), so an empty config here most likely means a
	; crash/power loss truncated the file mid-write. Surface it loudly instead
	; of silently leaving every tap-hold disabled.
	if (Result["keys"].Count == 0 and InheritDefaults) {
		try LoggerWarn("TapHoldLoader", "tap_hold.toml at '{1}' exists but parsed to 0 key(s) without inherit_defaults=false — possible truncated/corrupt write.",
			FilePath)
	}

	; A user file that EXISTS but could not be READ is not an empty one. The
	; defaults overlay above fills ``keys`` with the shipped mappings, so the
	; truncated-write sentinel cannot fire and the map is indistinguishable from
	; a user who customised nothing. Say so at ERROR rather than asserting a load
	; that never happened — _TH_WriteTapHoldToml consults the same sentinel and
	; refuses to rewrite the file from this map.
	if TOML_UnreadableFile(FilePath) {
		try LoggerError("TapHoldLoader", "Cannot read '{1}': the tap-hold config in memory is the shipped defaults, not the user's. Writes are blocked until the file is readable again.",
			FilePath)
	} else {
		try LoggerSuccess("TapHoldLoader", "Tap-hold config loaded ({1} key(s), {2} layer(s)).",
			Result["keys"].Count, Result["layers"].Count)
	}
	return Result
}





; ==============================================================
; ========================================
; ======= 2. Internal parse helper =======
; ========================================
; ==============================================================

; Parse ``FilePath`` and merge its key/value pairs into ``Result`` in-place.
; Existing entries are overwritten field-by-field so a user file that only
; specifies some fields of a key still inherits the rest from a prior pass.
_TapHold_ParseFileInto(FilePath, Result) {
	; Track the current section header path (e.g. "tap_hold.keys.caps_lock" or
	; "tap_hold.layers.nav.mappings"). Empty when outside any recognised section
	; so unrelated TOML headers are skipped silently.
	CurrentPath := ""

	loop parse, ReadTomlFile(FilePath), "`n", "`r" {
		Line := Trim(A_LoopField, " `t")
		if (Line == "" or SubStr(Line, 1, 1) == "#") {
			continue
		}

		if RegExMatch(Line, "^\[([^\[\]]+)\]$", &SecMatch) {
			CurrentPath := Trim(SecMatch[1])
			continue
		}

		if (CurrentPath == "") {
			continue
		}

		if !RegExMatch(Line, "^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$", &KvMatch) {
			continue
		}
		Key := KvMatch[1]
		Value := TomlCoerceValue(KvMatch[2])

		; [tap_hold] root metadata (e.g. inherit_defaults = false).
		if (CurrentPath == "tap_hold") {
			if (Key == "inherit_defaults")
				Result["inherit_defaults"] := (Value == true or Value == 1
					or Value == "true" or Value == "1")
			continue
		}

		; tap_hold.keys.<id>
		if RegExMatch(CurrentPath, "^tap_hold\.keys\.([A-Za-z0-9_]+)$", &KeyMatch) {
			KeyId := KeyMatch[1]
			if !Result["keys"].Has(KeyId) {
				Result["keys"][KeyId] := Map()
			}
			; hold_modifier and hold_layer are mutually exclusive: writing one
			; must evict the other so a defaults entry with hold_layer is not
			; left in place when the user file overrides with hold_modifier,
			; which would make IsTapHoldVariantActive match both variants.
			if (Key == "hold_modifier") and Result["keys"][KeyId].Has("hold_layer") {
				Result["keys"][KeyId].Delete("hold_layer")
			} else if (Key == "hold_layer") and Result["keys"][KeyId].Has("hold_modifier") {
				Result["keys"][KeyId].Delete("hold_modifier")
			}
			Result["keys"][KeyId][Key] := Value
			continue
		}

		; tap_hold.layers.<id> (description_key etc.)
		if RegExMatch(CurrentPath, "^tap_hold\.layers\.([A-Za-z0-9_]+)$", &LayerMatch) {
			LayerId := LayerMatch[1]
			if !Result["layers"].Has(LayerId) {
				Result["layers"][LayerId] := Map("mappings", Map())
			}
			Result["layers"][LayerId][Key] := Value
			continue
		}

		; tap_hold.layers.<id>.mappings
		if RegExMatch(CurrentPath, "^tap_hold\.layers\.([A-Za-z0-9_]+)\.mappings$", &MapMatch) {
			LayerId := MapMatch[1]
			if !Result["layers"].Has(LayerId) {
				Result["layers"][LayerId] := Map("mappings", Map())
			}
			if !Result["layers"][LayerId].Has("mappings") {
				Result["layers"][LayerId]["mappings"] := Map()
			}
			Result["layers"][LayerId]["mappings"][Key] := Value
			continue
		}
	}
}





; ==============================================================
; ========================================
; ======= 3. Convenience accessors =======
; ========================================
; ==============================================================

; Return true when the key ``KeyId`` has a configured tap_action OR hold_layer
; OR hold_modifier — i.e. when the tap-hold for this key should be armed.
TapHoldIsConfigured(TapHold, KeyId) {
	if !(TapHold.Has("keys") and TapHold["keys"].Has(KeyId)) {
		return false
	}
	Entry := TapHold["keys"][KeyId]
	return Entry.Has("tap_action") or Entry.Has("hold_layer") or Entry.Has("hold_modifier")
}

; Return the configured tap action for ``KeyId`` (a string) or "" if
; absent. Callers compare to known action ids ("enter", "tab", "backspace"…)
; to decide which Send() to emit.
TapHoldTapAction(TapHold, KeyId) {
	if !(TapHold.Has("keys") and TapHold["keys"].Has(KeyId)) {
		return ""
	}
	Entry := TapHold["keys"][KeyId]
	return Entry.Has("tap_action") ? Entry["tap_action"] : ""
}

; Return the hold-time threshold for ``KeyId`` in seconds, falling back to the
; single-sourced TAPHOLD_DEFAULT_ACTIVATION_SECONDS when the key is unconfigured
; or declares no ``time_activation_seconds``.
TapHoldDuration(TapHold, KeyId) {
	if !(TapHold.Has("keys") and TapHold["keys"].Has(KeyId)) {
		return TAPHOLD_DEFAULT_ACTIVATION_SECONDS
	}
	Entry := TapHold["keys"][KeyId]
	if !Entry.Has("time_activation_seconds")
		return TAPHOLD_DEFAULT_ACTIVATION_SECONDS
	Raw := Entry["time_activation_seconds"]
	; Validate at the boundary (fail fast, copilot-instructions 5.3). This value
	; comes verbatim from the user-editable tap_hold.toml and is concatenated into
	; a KeyWait option string ("T" . value) at ~11 call sites. A non-numeric entry
	; produced "Tabc", and KeyWait then THREW on the hook thread — after
	; TapHoldSyntheticKeyDown had already armed a synthetic modifier and before its
	; release, which is what made the modifier-latch window reachable at all. The
	; throw was absorbed by the global error net, so the user only saw a tap-hold
	; that intermittently did nothing, never a config error.
	if (!IsNumber(Raw) or Raw <= 0 or Raw > TAPHOLD_MAX_ACTIVATION_SECONDS) {
		try LoggerWarn("TapHoldLoader",
			"Invalid time_activation_seconds '{1}' for tap-hold key '{2}' — falling back to {3}s.",
			Raw, KeyId, TAPHOLD_DEFAULT_ACTIVATION_SECONDS)
		return TAPHOLD_DEFAULT_ACTIVATION_SECONDS
	}
	return Raw
}

; Return the configured hold modifier for ``KeyId`` (e.g. "ctrl", "shift",
; "alt", "alt_gr") or "" if the variant doesn't activate a modifier on
; hold (e.g. plain tap-only variants like CapsLock-BackSpace or LAlt-BackSpace
; key-repeat where the held key simply repeats the tap action).
TapHoldHoldModifier(TapHold, KeyId) {
	if !(TapHold.Has("keys") and TapHold["keys"].Has(KeyId)) {
		return ""
	}
	Entry := TapHold["keys"][KeyId]
	return Entry.Has("hold_modifier") ? Entry["hold_modifier"] : ""
}

; Return the configured hold layer for ``KeyId`` (e.g. "nav") or "" if
; the variant doesn't activate a remap layer on hold. Used to distinguish
; Layer-on-hold variants from modifier-on-hold variants (e.g. LAlt-BackSpace
; vs LAlt-BackSpaceLayer share tap_action "backspace" but only the latter
; arms the navigation layer).
TapHoldHoldLayer(TapHold, KeyId) {
	if !(TapHold.Has("keys") and TapHold["keys"].Has(KeyId)) {
		return ""
	}
	Entry := TapHold["keys"][KeyId]
	return Entry.Has("hold_layer") ? Entry["hold_layer"] : ""
}





; ==============================================================
; ===========================================
; ======= 4. Hold-modifier resolution =======
; ===========================================
; ==============================================================

; Central hold_modifier -> AHK key-name resolver shared by every tap-holds
; module's per-key XxxHoldModKey() wrapper. Centralizing the switch means a
; typo'd hold_modifier value (e.g. "contrl") — which passes the #HotIf
; non-empty gate but matches no case here — is caught and logged in exactly
; one place instead of silently degrading to an empty ModKey in 9 separate
; copies of this switch, each fed unguarded into TextPressKey.
; @param ModifierValue {String} Raw hold_modifier value, typically read via
;        TapHoldHoldModifier(TapHold, FieldLabel).
; @param FieldLabel {String} The tap-holds field name (e.g. "backspace"),
;        used only in the warning message so the log pinpoints the bad
;        tap_hold.toml row.
; @param CtrlKeyName {String} AHK key name for the "ctrl" case. Defaults to
;        "LCtrl"; rctrl.ahk passes "RCtrl" so holding the physical Right Ctrl
;        key as its own "ctrl" hold modifier arms the right-side key.
; @returns {String|Array} An AHK key name, or array of AHK key names for
;        hold modifier combinations, or "" when ModifierValue is invalid.
ResolveHoldModifierKey(ModifierValue, FieldLabel, CtrlKeyName := "LCtrl") {
	Raw := Trim(String(ModifierValue))
	if (Raw == "") {
		return ""
	}

	; Accept both legacy single token and combo forms, e.g. "ctrl",
	; "ctrl+shift", or "Ctrl + Shift".
	Normalized := StrReplace(Raw, " ", "+")
	while (InStr(Normalized, "++") > 0) {
		Normalized := StrReplace(Normalized, "++", "+")
	}
	Normalized := Trim(Normalized, "+")
	Tokens := StrSplit(Normalized, "+")
	if (Tokens.Length == 0) {
		return ""
	}

	Resolved := []
	Invalid := []
	for _, Token in Tokens {
		if (Token == "")
			continue
        NormalizedToken := StrLower(Trim(Token))
        switch NormalizedToken {
			case "ctrl", "lctrl":
				Resolved.Push(CtrlKeyName)
			case "shift", "lshift":
				Resolved.Push("LShift")
			case "alt", "lalt":
				Resolved.Push("LAlt")
			case "alt_gr", "altgr", "ralt":
				Resolved.Push("RAlt")
			case "win", "lwin":
				Resolved.Push("LWin")
			case "":
				continue
			default:
				Invalid.Push(Token)
		}
	}

	if (Invalid.Length > 0) {
		try LoggerWarn("TapHoldLoader", "Unrecognized hold_modifier '{1}' for tap-hold key '{2}' — check tap_hold.toml for a typo; no modifier will be armed (expected one of ctrl/shift/alt/alt_gr/win).",
			ModifierValue, FieldLabel)
		return ""
	}
	if (Resolved.Length == 0) {
		try LoggerWarn("TapHoldLoader", "No recognized hold_modifier in '{1}' for tap-hold key '{2}'.",
			ModifierValue, FieldLabel)
		return ""
	}
	if (Resolved.Length == 1) {
		try LoggerDebug("TapHoldLoader", "Resolved hold_modifier '{1}' for tap-hold key '{2}' as '{3}'.",
			ModifierValue, FieldLabel, Resolved[1])
		return Resolved[1]
	}

	Label := ""
    for _, ResolvedModifier in Resolved {
        Label .= (Label == "" ? "" : ",") . ResolvedModifier
	}
	try LoggerDebug("TapHoldLoader", "Resolved hold_modifier '{1}' for tap-hold key '{2}' as [{3}].",
		ModifierValue, FieldLabel, Label)
	return Resolved
}
