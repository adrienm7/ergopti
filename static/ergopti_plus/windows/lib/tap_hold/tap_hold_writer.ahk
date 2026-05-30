; lib/tap_hold/tap_hold_writer.ahk

; ==============================================================================
; MODULE: Tap-Hold Writer
; DESCRIPTION:
; Persists user tray-menu choices for tap/hold configuration to the v2
; ``tap_hold.toml`` file. The new architecture gives each physical key two
; independent selectors — tap (any action from GESTURE_ACTIONS) and hold
; (modifier or nav layer) — mirroring the macOS Karabiner menu design.
;
; FEATURES & RATIONALE:
; 1. Per-key tap + hold pickers: every key exposes a free tap selector
;    (drawing from the full GESTURE_ACTIONS registry) and a hold selector
;    (fixed set of modifiers and the nav layer). No more pre-baked variant
;    tuples — the user composes the pair themselves.
; 2. Single source of truth for key order, hold options, and i18n keys —
;    all defined here and consumed by the tray-menu builder.
; 3. Preserves per-key ``time_activation_seconds`` already in TapHold —
;    the tray menu does not expose this, but hand-editing tap_hold.toml is
;    supported and survives writes.
; ==============================================================================




; ==========================
; ==========================
; ======= 1/ Key defs =======
; ==========================
; ==========================

; Ordered list of physical keys exposed in the tap-hold tray submenu.
; Each entry: Map("id" => v2_key_id, "i18n" => group_i18n_key).
global _TH_KeyDefs := [
	Map("id", "escape",       "i18n", "tap_hold.group.escape"),
	Map("id", "tab",          "i18n", "tap_hold.group.tab"),
	Map("id", "caps_lock",    "i18n", "tap_hold.group.caps_lock"),
	Map("id", "left_shift",   "i18n", "tap_hold.group.left_shift"),
	Map("id", "left_ctrl",    "i18n", "tap_hold.group.left_ctrl"),
	Map("id", "win",          "i18n", "tap_hold.group.win"),
	Map("id", "left_alt",     "i18n", "tap_hold.group.left_alt"),
	Map("id", "space",        "i18n", "tap_hold.group.space"),
	Map("id", "alt_gr",       "i18n", "tap_hold.group.alt_gr"),
	Map("id", "right_ctrl",   "i18n", "tap_hold.group.right_ctrl"),
	Map("id", "right_shift",  "i18n", "tap_hold.group.right_shift"),
	Map("id", "enter",        "i18n", "tap_hold.group.enter"),
	Map("id", "backspace",    "i18n", "tap_hold.group.backspace"),
	Map("id", "delete",       "i18n", "tap_hold.group.delete"),
]

; Ordered hold options — value stored as hold_modifier or hold_layer in TOML.
; Each entry: Map("id" => storage_value, "kind" => "modifier"|"layer"|"none",
;                 "i18n" => label_i18n_key).
global _TH_HoldOptions := [
	Map("id", "",      "kind", "none",     "i18n", "tap_hold.hold.none"),
	Map("id", "ctrl",  "kind", "modifier", "i18n", "tap_hold.hold.ctrl"),
	Map("id", "shift", "kind", "modifier", "i18n", "tap_hold.hold.shift"),
	Map("id", "alt",   "kind", "modifier", "i18n", "tap_hold.hold.alt"),
	Map("id", "alt_gr","kind", "modifier", "i18n", "tap_hold.hold.alt_gr"),
	Map("id", "win",   "kind", "modifier", "i18n", "tap_hold.hold.win"),
	Map("id", "nav",   "kind", "layer",    "i18n", "tap_hold.hold.nav_layer"),
]

; i18n key for the "nothing / disable" tap action sentinel.
global _TH_TapNoneI18n := "tap_hold.tap.none"




; ==========================================
; ==========================================
; ======= 2/ Public accessor helpers =======
; ==========================================
; ==========================================

; Return the ordered key-definition array.
TapHoldKeyDefs() {
	global _TH_KeyDefs
	return _TH_KeyDefs
}

; Return the ordered hold-option array.
TapHoldHoldOptions() {
	global _TH_HoldOptions
	return _TH_HoldOptions
}

; Return the i18n-resolved display label for a physical key group.
TapHoldGroupLabel(KeyId) {
	global _TH_KeyDefs
	for Def in _TH_KeyDefs {
		if (Def["id"] == KeyId) {
			return t(Def["i18n"])
		}
	}
	return KeyId
}

; Return the i18n-resolved short label for the current tap action of a key.
; Falls back to _GestureActionLabel() so the gesture-action locale chain is
; the single source of truth for action names.
TapHoldCurrentTapLabel(KeyId) {
	global TapHold, _TH_TapNoneI18n
	TapAction := TapHoldTapAction(TapHold, KeyId)
	if (TapAction == "") {
		return t(_TH_TapNoneI18n)
	}
	return _GestureActionLabel(TapAction)
}

; Return the i18n-resolved short label for the current hold option of a key.
TapHoldCurrentHoldLabel(KeyId) {
	global TapHold, _TH_HoldOptions
	HoldMod   := TapHoldHoldModifier(TapHold, KeyId)
	HoldLayer := TapHoldHoldLayer(TapHold, KeyId)
	for Opt in _TH_HoldOptions {
		if (Opt["kind"] == "modifier" and Opt["id"] == HoldMod) {
			return t(Opt["i18n"])
		}
		if (Opt["kind"] == "layer" and Opt["id"] == HoldLayer) {
			return t(Opt["i18n"])
		}
		if (Opt["kind"] == "none" and HoldMod == "" and HoldLayer == "") {
			return t(Opt["i18n"])
		}
	}
	return HoldMod != "" ? HoldMod : (HoldLayer != "" ? HoldLayer : t(_TH_HoldOptions[1]["i18n"]))
}

; Return true when the tap action for a key matches the given action id.
IsTapHoldTapActive(KeyId, ActionId) {
	global TapHold
	if !IsSet(TapHold) {
		return false
	}
	Current := TapHoldTapAction(TapHold, KeyId)
	if (ActionId == "") {
		return (Current == "")
	}
	return (Current == ActionId)
}

; Return true when the hold option for a key matches the given hold option entry.
IsTapHoldHoldActive(KeyId, HoldOpt) {
	global TapHold
	if !IsSet(TapHold) {
		return false
	}
	HoldMod   := TapHoldHoldModifier(TapHold, KeyId)
	HoldLayer := TapHoldHoldLayer(TapHold, KeyId)
	Kind := HoldOpt["kind"]
	Id   := HoldOpt["id"]
	if (Kind == "none") {
		return (HoldMod == "" and HoldLayer == "")
	}
	if (Kind == "modifier") {
		return (HoldMod == Id)
	}
	if (Kind == "layer") {
		return (HoldLayer == Id)
	}
	return false
}




; ============================
; ============================
; ======= 3/ Tap writer =======
; ============================
; ============================

; Apply a new tap action for a key directly to TapHold + tap_hold.toml.
; ``ActionId`` is a GESTURE_ACTIONS id string, or "" to clear the tap slot.
WriteTapHoldTap(KeyId, ActionId) {
	global TapHold
	if !IsSet(TapHold) {
		try LoggerWarn("TapHoldWriter", "TapHold global unset — skipping WriteTapHoldTap.")
		return
	}
	if !TapHold.Has("keys") {
		TapHold["keys"] := Map()
	}

	if !TapHold["keys"].Has(KeyId) {
		TapHold["keys"][KeyId] := Map()
	}
	Entry := TapHold["keys"][KeyId]

	if (ActionId == "") {
		; Clear the tap slot. If hold is also clear, remove the entry entirely.
		Entry.Delete("tap_action")
		if (!Entry.Has("hold_modifier") and !Entry.Has("hold_layer")) {
			TapHold["keys"].Delete(KeyId)
		}
	} else {
		Entry["tap_action"] := ActionId
	}

	_TH_WriteTapHoldToml()
	try LoggerDebug("TapHoldWriter", "Tap set: '{1}' -> '{2}'.", KeyId, ActionId)
}

; Apply a new hold option for a key directly to TapHold + tap_hold.toml.
; ``HoldOpt`` is one entry from ``_TH_HoldOptions``.
WriteTapHoldHold(KeyId, HoldOpt) {
	global TapHold
	if !IsSet(TapHold) {
		try LoggerWarn("TapHoldWriter", "TapHold global unset — skipping WriteTapHoldHold.")
		return
	}
	if !TapHold.Has("keys") {
		TapHold["keys"] := Map()
	}

	if !TapHold["keys"].Has(KeyId) {
		TapHold["keys"][KeyId] := Map()
	}
	Entry := TapHold["keys"][KeyId]

	; Always clear both hold fields before writing the new one — they are
	; mutually exclusive and a stale field would confuse IsTapHoldVariantActive.
	; Map.Delete() throws if the key is absent, so guard with Has().
	if Entry.Has("hold_modifier")
		Entry.Delete("hold_modifier")
	if Entry.Has("hold_layer")
		Entry.Delete("hold_layer")

	Kind := HoldOpt["kind"]
	Id   := HoldOpt["id"]

	if (Kind == "modifier") {
		Entry["hold_modifier"] := Id
	} else if (Kind == "layer") {
		Entry["hold_layer"] := Id
	}
	; else kind == "none" — both fields already deleted above.

	; Remove the entry entirely when both tap and hold are now empty.
	if (!Entry.Has("tap_action") and !Entry.Has("hold_modifier") and !Entry.Has("hold_layer")) {
		TapHold["keys"].Delete(KeyId)
	}

	_TH_WriteTapHoldToml()
	try LoggerDebug("TapHoldWriter", "Hold set: '{1}' -> kind={2}, id='{3}'.", KeyId, Kind, Id)
}




; =======================================
; =======================================
; ======= 4/ tap_hold.toml writer =======
; =======================================
; =======================================

; Rewrite ``<config>/ahk/tap_hold.toml`` from scratch from the current
; in-memory ``TapHold`` global. Preserves the ``layers`` block verbatim
; so any user-customised layer mappings survive a key-section write.
_TH_WriteTapHoldToml() {
	global TapHold, _ConfigDir
	if !IsSet(_ConfigDir) {
		try LoggerWarn("TapHoldWriter", "_ConfigDir unset — cannot persist tap_hold.toml.")
		return
	}
	Path := _ConfigDir . "ahk\tap_hold.toml"

	Lines := []
	Lines.Push("# Auto-generated by Ergopti+ tray-menu writes — hand edits stay safe outside")
	Lines.Push("# the [tap_hold.keys.*] blocks (which get rewritten from scratch on every")
	Lines.Push("# toggle). The [tap_hold.layers.*] sections are emitted verbatim from the")
	Lines.Push("# in-memory state, so customisations made via direct editing round-trip.")
	Lines.Push("")

	; Keys section.
	if TapHold.Has("keys") {
		for KeyId, Entry in TapHold["keys"] {
			if !(IsObject(Entry) and Type(Entry) == "Map") {
				continue
			}
			Lines.Push("[tap_hold.keys." . KeyId . "]")
			for K, V in Entry {
				Lines.Push(_TH_TomlFormatLine(K, V))
			}
			Lines.Push("")
		}
	}

	; Layers section — emitted verbatim.
	if TapHold.Has("layers") {
		for LayerId, LayerData in TapHold["layers"] {
			if !(IsObject(LayerData) and Type(LayerData) == "Map") {
				continue
			}
			Lines.Push("[tap_hold.layers." . LayerId . "]")
			; Top-level layer metadata (description_key etc.).
			for K, V in LayerData {
				if (K == "mappings") {
					continue  ; mappings emitted as a sub-section below
				}
				Lines.Push(_TH_TomlFormatLine(K, V))
			}
			Lines.Push("")
			if LayerData.Has("mappings") and IsObject(LayerData["mappings"]) {
				Lines.Push("[tap_hold.layers." . LayerId . ".mappings]")
				for K, V in LayerData["mappings"] {
					Lines.Push(_TH_TomlFormatLine(K, V))
				}
				Lines.Push("")
			}
		}
	}

	Content := ""
	for L in Lines {
		Content .= L . "`r`n"
	}

	try {
		if FileExist(Path) {
			FileDelete(Path)
		}
		FileAppend(Content, Path, "UTF-8-RAW")
		try LoggerDebug("TapHoldWriter", "tap_hold.toml rewritten ({1} key(s)).",
			TapHold.Has("keys") ? TapHold["keys"].Count : 0)
	} catch as Err {
		try LoggerError("TapHoldWriter", "Could not write tap_hold.toml: {1}.", Err.Message)
	}
}

; ===========================================================================
; ===========================================================================
; ======= 5/ Legacy compat stubs (no longer called by the new menu) =======
; ===========================================================================
; ===========================================================================

; No-op stub kept so that path_translator.ahk routing code does not crash
; if reached by a stale caller. The new tray menu uses WriteTapHoldTap and
; WriteTapHoldHold directly via callbacks; WriteTapHoldBatch is dead code.
WriteTapHoldBatch(BatchEntries) {
	try LoggerDebug("TapHoldWriter", "WriteTapHoldBatch called — no-op in new menu architecture.")
	return 0
}

; Stub kept so GetMenuTitleByPath / _ResolveMenuItemEnabled do not crash if
; reached with a TapHolds.* path from old code. Always returns false because
; no variant-style TapHolds paths are used by the new picker menu.
IsTapHoldVariantActive(V1Path) {
	return false
}

; Stub kept so GetMenuTitleByPath does not crash on TapHolds.Key.Variant paths.
TapHoldVariantLabel(V1KeyId, Variant) {
	return V1KeyId . "." . Variant
}

; Format a single ``key = value`` line for tap_hold.toml. Handles strings
; (quoted), booleans, and numbers; arrays and nested tables are not used
; in this schema.
_TH_TomlFormatLine(Key, Value) {
	if (Value = true) {
		return Key . " = true"
	}
	if (Value = false) {
		return Key . " = false"
	}
	if (Type(Value) == "Integer" or Type(Value) == "Float") {
		return Key . " = " . Value
	}
	; String — quote, escape backslashes and quotes.
	S := String(Value)
	S := StrReplace(S, "\", "\\")
	S := StrReplace(S, '"', '\"')
	return Key . " = `"" . S . "`""
}
