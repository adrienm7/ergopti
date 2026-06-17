; drivers/autohotkey/lib/tap_hold/tap_hold_loader.ahk

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
	Result := Map("keys", Map(), "layers", Map())
	InheritDefaults := true

	; Parse the user file once into UserData. Extract inherit_defaults from
	; the result so we do not need a second pre-flight read of the same file.
	; The data is later merged on top of the defaults overlay so the final
	; order is still: defaults → user (user wins per-key).
	UserData := Map("keys", Map(), "layers", Map())
	if FileExist(FilePath)
		_TapHold_ParseFileInto(FilePath, UserData)

	if UserData.Has("inherit_defaults")
		InheritDefaults := !!UserData["inherit_defaults"]

	; Load shared defaults first when the caller supplies the path. Missing
	; defaults file is non-fatal (logs a debug notice and continues).
	if (DefaultsFilePath != "" and InheritDefaults) {
		if FileExist(DefaultsFilePath) {
			try LoggerDebug("TapHoldLoader", "Loading tap-hold defaults from '{1}'…", DefaultsFilePath)
			_TapHold_ParseFileInto(DefaultsFilePath, Result)
		} else {
			try LoggerDebug("TapHoldLoader", "Shared defaults not found at '{1}' — skipping.", DefaultsFilePath)
		}
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

	try LoggerSuccess("TapHoldLoader", "Tap-hold config loaded ({1} key(s), {2} layer(s)).",
		Result["keys"].Count, Result["layers"].Count)
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

; Return the hold-time threshold for ``KeyId`` in seconds, with a sensible
; default of 0.2s when unset.
TapHoldDuration(TapHold, KeyId) {
	if !(TapHold.Has("keys") and TapHold["keys"].Has(KeyId)) {
		return 0.2
	}
	Entry := TapHold["keys"][KeyId]
	return Entry.Has("time_activation_seconds") ? Entry["time_activation_seconds"] : 0.2
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
