; platform/remap/tap_hold_writer.ahk

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





; ===========================
; ===========================
; ======= 1/ Key defs =======
; ===========================
; ===========================

; Ordered list of physical keys exposed in the tap-hold tray submenu.
; Each entry: Map("id" => v2_key_id, "i18n" => group_i18n_key).
;
; **Canonical order mirrors _shared/modules/menu/menu_manifest.json
; tap_hold_keys_catalog (MENU-4).** Entries restricted to platforms=["ahk"]
; here; macOS-only keys (fn, spacebar, left_control, left_option, left_command,
; right_command, right_option, return_or_enter, delete_or_backspace) live
; only in the shared catalog and are filtered out by the AHK manifest reader.
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
; **Canonical list mirrors _shared/modules/menu/menu_manifest.json
; hold_options (MENU-4).**
global _TH_HoldModifierIds := ["ctrl", "shift", "alt", "alt_gr", "win"]
global _TH_HoldOptions := _TH_BuildHoldOptions()

; Build the menu hold options once at startup: native-key sentinel, all
; modifier combinations, and nav layer entry.
_TH_BuildHoldOptions() {
	Options := []
	Options.Push(Map("id", "", "kind", "none", "i18n", "tap_hold.hold.none"))

	ModifierCombos := []
	_TH_EnumerateHoldModifierCombos("", 1, _TH_HoldModifierIds, ModifierCombos)
	for _, ComboId in ModifierCombos {
		Options.Push(Map("id", ComboId, "kind", "modifier", "i18n", ""))
	}

	Options.Push(Map("id", "nav", "kind", "layer", "i18n", "tap_hold.hold.nav_layer"))
	return Options
}

; Recursively enumerate all non-empty combinations of `_TH_HoldModifierIds` with
; deterministic order: single modifiers first, then longer ordered combinations.
_TH_EnumerateHoldModifierCombos(Prefix, StartIndex, Modifiers, Out) {
	Loop Modifiers.Length {
		if (A_Index < StartIndex)
			continue
		ComboId := Prefix == "" ? Modifiers[A_Index] : (Prefix . "+" . Modifiers[A_Index])
		Out.Push(ComboId)
		_TH_EnumerateHoldModifierCombos(ComboId, A_Index + 1, Modifiers, Out)
	}
}

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

; Return the i18n-resolved short label for the current tap action of a key.
; Falls back to _GestureActionLabel() so the gesture-action locale chain is
; the single source of truth for action names.
TapHoldCurrentTapLabel(KeyId) {
	global TapHold, _TH_TapNoneI18n
	TapAction := TapHoldTapAction(TapHold, KeyId)
	if (TapAction == "") {
		return t(_TH_TapNoneI18n)
	}
	return GestureActionDisplayLabel(TapAction, GestureBindingId("tap_hold", KeyId))
}

; Return the i18n-resolved short label for the current hold option of a key.
TapHoldCurrentHoldLabel(KeyId) {
	global TapHold, _TH_HoldOptions
	HoldMod   := TapHoldHoldModifier(TapHold, KeyId)
	HoldLayer := TapHoldHoldLayer(TapHold, KeyId)
	for _, Opt in _TH_HoldOptions {
		if (Opt["kind"] == "modifier" and Opt["id"] == HoldMod) {
			return _TH_HoldOptionLabel(HoldMod)
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

; Human label for a hold modifier identifier.
; Built from base i18n keys when possible, then joined with ' + '.
_TH_HoldOptionLabel(HoldId) {
	if (HoldId == "") {
		return t("tap_hold.hold.none")
	}
	Parts := StrSplit(HoldId, "+")
	Out := []
	for _, Part in Parts {
		Clean := Trim(Part)
		if (Clean == "") {
			continue
		}
		Label := t("tap_hold.hold." . Clean)
		if (InStr(Label, "tap_hold.hold.") > 0) {
			Label := Clean
		}
		Out.Push(Label)
	}
	if (Out.Length == 0) {
		return t("tap_hold.hold.none")
	}
	Result := ""
	for Index, Label in Out {
		Result .= (Index = 1 ? "" : " + ") . Label
	}
	return Result
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





; =============================
; =============================
; ======= 3/ Tap writer =======
; =============================
; =============================

; Apply a new tap action for a key directly to TapHold + tap_hold.toml.
; ``ActionId`` is a GESTURE_ACTIONS id string, or "" to force native passthrough
; while still persisting an explicit per-key override (so shipped defaults do not
; leak back on reload).
WriteTapHoldTap(KeyId, ActionId) {
        global TapHold
	if !IsSet(TapHold) {
		try LoggerWarn("TapHoldWriter", "TapHold global unset — skipping WriteTapHoldTap.")
		return
	}
        Candidate := _TH_CloneData(TapHold)
        if !Candidate.Has("keys") {
                Candidate["keys"] := Map()
        }

        if !Candidate["keys"].Has(KeyId) {
                Candidate["keys"][KeyId] := Map()
        }
        Entry := Candidate["keys"][KeyId]
	PrevTap      := Entry.Has("tap_action") ? (Entry["tap_action"] == "" ? "<native>" : Entry["tap_action"]) : "<unset>"
	PrevHoldMod  := Entry.Has("hold_modifier") ? Entry["hold_modifier"] : "<unset>"
	PrevHoldLay  := Entry.Has("hold_layer") ? Entry["hold_layer"] : "<unset>"
	try LoggerDebug("TapHoldWriter", "WriteTapHoldTap requested: key='{1}', action='{2}' (prev_tap='{3}', prev_hold_modifier='{4}', prev_hold_layer='{5}').",
		KeyId, (ActionId == "" ? "<native>" : ActionId), PrevTap, PrevHoldMod, PrevHoldLay)

	if (ActionId == "") {
		; Empty string means explicit native passthrough for this key and must
		; stay in the merged map to block default fallback on reload.
		Entry["tap_action"] := ""
	} else {
		Entry["tap_action"] := ActionId
	}
	NewTap := Entry["tap_action"] == "" ? "<native>" : Entry["tap_action"]
	try LoggerDebug("TapHoldWriter", "WriteTapHoldTap applied: key='{1}', new_tap='{2}'.", KeyId, NewTap)

        if !_TH_WriteTapHoldToml(Candidate)
                return false
        TapHold := Candidate
        try LoggerDebug("TapHoldWriter", "Tap persisted: '{1}' -> '{2}'.", KeyId, NewTap)
        return true
}

; Apply a new hold option for a key directly to TapHold + tap_hold.toml.
; ``HoldOpt`` is one entry from ``_TH_HoldOptions``.
WriteTapHoldHold(KeyId, HoldOpt) {
	global TapHold
	if !IsSet(TapHold) {
		try LoggerWarn("TapHoldWriter", "TapHold global unset — skipping WriteTapHoldHold.")
		return
	}
        Candidate := _TH_CloneData(TapHold)
        if !Candidate.Has("keys") {
                Candidate["keys"] := Map()
	}

        if !Candidate["keys"].Has(KeyId) {
                Candidate["keys"][KeyId] := Map()
	}
        Entry := Candidate["keys"][KeyId]
	PrevHoldMod  := Entry.Has("hold_modifier") ? Entry["hold_modifier"] : "<unset>"
	PrevHoldLay  := Entry.Has("hold_layer") ? Entry["hold_layer"] : "<unset>"
	PrevTap      := Entry.Has("tap_action") ? (Entry["tap_action"] == "" ? "<native>" : Entry["tap_action"]) : "<unset>"
	try LoggerDebug("TapHoldWriter", "WriteTapHoldHold requested: key='{1}', kind='{2}', id='{3}' (prev_tap='{4}', prev_hold_modifier='{5}', prev_hold_layer='{6}').",
		KeyId, HoldOpt["kind"], HoldOpt["id"], PrevTap, PrevHoldMod, PrevHoldLay)

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
	} else if (Kind == "none") {
		; Explicit "none" by writing an empty hold slot, preventing defaults
		; from reintroducing a hold value on merge.
		Entry["hold_modifier"] := ""
	}

	; Remove the entry entirely when both tap and hold are now empty.
	if (!Entry.Has("tap_action") and !Entry.Has("hold_modifier") and !Entry.Has("hold_layer")) {
                Candidate["keys"].Delete(KeyId)
	}
	NewHoldMod  := Entry.Has("hold_modifier") ? Entry["hold_modifier"] : "<unset>"
	NewHoldLay  := Entry.Has("hold_layer") ? Entry["hold_layer"] : "<unset>"
	NewTap      := Entry.Has("tap_action") ? (Entry["tap_action"] == "" ? "<native>" : Entry["tap_action"]) : "<unset>"
	try LoggerDebug("TapHoldWriter", "WriteTapHoldHold applied: key='{1}', new_tap='{2}', new_hold_modifier='{3}', new_hold_layer='{4}'.", KeyId, NewTap, NewHoldMod, NewHoldLay)

        if !_TH_WriteTapHoldToml(Candidate)
                return false
        TapHold := Candidate
        try LoggerDebug("TapHoldWriter", "Hold persisted: '{1}' -> kind='{2}', id='{3}'.", KeyId, Kind, Id)
        return true
}

; Atomically switch one key back to native tap + no hold.  The tray's Disable
; action used to call WriteTapHoldTap then WriteTapHoldHold, which could persist
; only the first half if the second write failed.
WriteTapHoldNative(KeyId) {
        global TapHold
        if !IsSet(TapHold)
                return false
        Candidate := _TH_CloneData(TapHold)
        if !Candidate.Has("keys")
                Candidate["keys"] := Map()
        if !Candidate["keys"].Has(KeyId)
                Candidate["keys"][KeyId] := Map()
        Entry := Candidate["keys"][KeyId]
        Entry["tap_action"] := ""
        if Entry.Has("hold_modifier")
                Entry.Delete("hold_modifier")
        if Entry.Has("hold_layer")
                Entry.Delete("hold_layer")
        if !_TH_WriteTapHoldToml(Candidate)
                return false
        TapHold := Candidate
        return true
}





; =======================================
; =======================================
; ======= 4/ tap_hold.toml writer =======
; =======================================
; =======================================

; Persist an explicit « all tap-holds disabled » state. Without
; ``inherit_defaults = false`` the loader would re-merge shipped defaults on
; the next reload, undoing « Tout désactiver ».
_TH_WriteTapHoldDisabled() {
	global TapHold
	if !IsSet(TapHold) {
		try LoggerWarn("TapHoldWriter", "TapHold global unset — cannot disable tap-holds.")
		return false
	}
	; Never mutate the live map before the on-disk transaction succeeds.  A
	; failed FileMove used to leave the running driver disabled while its next
	; reload restored the old file, producing an unexplained state reversal.
	Candidate := _TH_CloneData(TapHold)
	Candidate["keys"] := Map()
	Candidate["layers"] := Map()
	Candidate["inherit_defaults"] := false
	if !_TH_WriteTapHoldToml(Candidate)
		return false
	TapHold := Candidate
	try LoggerInfo("TapHoldWriter", "All tap-hold mappings disabled and persisted.")
	return true
}

; Rewrite ``<config>/autohotkey/tap_hold.toml`` from scratch from the current
; in-memory ``TapHold`` global. Preserves the ``layers`` block verbatim
; so any user-customised layer mappings survive a key-section write.
_TH_WriteTapHoldToml(Data := unset) {
        global TapHold, _ConfigDir, _AhkSubDir
        if !IsSet(Data)
                Data := TapHold
	if !IsSet(_ConfigDir) {
		try LoggerWarn("TapHoldWriter", "_ConfigDir unset — cannot persist tap_hold.toml.")
		return
	}
	Path := _ConfigDir . _AhkSubDir . "tap_hold.toml"
	; Refuse to rebuild a file the loader could not READ. Everything below is
	; serialized from the in-memory map, and when the load saw nothing that map
	; is the shipped defaults overlay — byte-for-byte what a user who customised
	; nothing produces. Rewriting from it erases their per-key overrides, their
	; hand-edited layer mappings and their explicit disable-all opt-out, and
	; every caller here re-publishes TapHold only on a true return, so refusing
	; leaves memory and disk consistent.
	if TOML_UnreadableFile(Path) {
		try LoggerError("TapHoldWriter", "Refusing to rewrite '{1}': it could not be read at load, so the in-memory tap-hold map holds the shipped defaults rather than the user's configuration. Restart the driver once the file is readable.", Path)
		return false
	}
	try LoggerDebug("TapHoldWriter", "Persisting tap-hold config to '{1}' (keys={2}, layers={3}, inherit_defaults={4}).",
                Path, Data.Has("keys") ? Data["keys"].Count : 0, Data.Has("layers") ? Data["layers"].Count : 0,
                Data.Has("inherit_defaults") ? (Data["inherit_defaults"] ? "true" : "false") : "unset")

	Lines := []
	Lines.Push("# Auto-generated by Ergopti+ tray-menu writes — hand edits stay safe outside")
	Lines.Push("# the [tap_hold.keys.*] blocks (which get rewritten from scratch on every")
	Lines.Push("# toggle). The [tap_hold.layers.*] sections are emitted verbatim from the")
	Lines.Push("# in-memory state, so customisations made via direct editing round-trip.")
	Lines.Push("")

	; Root [tap_hold] section — emit inherit_defaults when it is false so
	; the loader does not re-merge shipped defaults on the next reload.
        if Data.Has("inherit_defaults") and !Data["inherit_defaults"] {
		Lines.Push("[tap_hold]")
		Lines.Push("inherit_defaults = false")
		Lines.Push("")
	}

	; Keys section.
        if Data.Has("keys") {
                for KeyId, Entry in Data["keys"] {
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
        if Data.Has("layers") {
                for LayerId, LayerData in Data["layers"] {
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

	; Atomic write: stage the content in a sibling temp file, then rename over
	; the target. FileMove with overwrite=true is atomic on NTFS, so a crash or
	; power loss between the old non-atomic FileDelete and FileAppend can no
	; longer leave a truncated tap_hold.toml that silently drops every remap.
	Tmp := Path . ".tmp"
	try {
		if FileExist(Tmp) {
			FileDelete(Tmp)
		}
		FileAppend(Content, Tmp, "UTF-8-RAW")
		FileMove(Tmp, Path, true)
		try LoggerDebug("TapHoldWriter", "tap_hold.toml rewritten ({1} key(s)).",
                        Data.Has("keys") ? Data["keys"].Count : 0)
                return true
	} catch as Err {
		try FileDelete(Tmp)
                try LoggerError("TapHoldWriter", "Could not write tap_hold.toml: {1}.", Err.Message)
                return false
        }
}

_TH_CloneData(Value) {
        if Value is Map {
                Copy := Map()
                for K, V in Value
                        Copy[K] := _TH_CloneData(V)
                return Copy
        }
        if Value is Array {
                Copy := []
                for _, V in Value
                        Copy.Push(_TH_CloneData(V))
                return Copy
        }
        return Value
}





; =========================================================================
; =========================================================================
; ======= 5/ Legacy compat stubs (no longer called by the new menu) =======
; =========================================================================
; =========================================================================

; No-op stub kept so that path_translator.ahk routing code does not crash
; if reached by a stale caller. The new tray menu uses WriteTapHoldTap and
; WriteTapHoldHold directly via callbacks; WriteTapHoldBatch is dead code.
WriteTapHoldBatch(BatchEntries) {
	try LoggerDebug("TapHoldWriter", "WriteTapHoldBatch called — no-op in new menu architecture.")
	return 0
}

; Format a single ``key = value`` line for tap_hold.toml. Handles strings
; (quoted), booleans, and numbers; arrays and nested tables are not used
; in this schema.
_TH_TomlFormatLine(Key, Value) {
	; Check numeric types first — integer 0 satisfies (Value = false) in AHK v2,
	; so the Type() guard must come before any boolean comparison
	if (Type(Value) == "Integer" or Type(Value) == "Float") {
		return Key . " = " . Value
	}
	if (Value == true) {
		return Key . " = true"
	}
	if (Value == false) {
		return Key . " = false"
	}
	; String — quote, escape backslashes and quotes.
	S := String(Value)
	S := StrReplace(S, "\", "\\")
	S := StrReplace(S, Chr(0x22), "\" . Chr(0x22))
	return Key . ' = "' . S . '"'
}
