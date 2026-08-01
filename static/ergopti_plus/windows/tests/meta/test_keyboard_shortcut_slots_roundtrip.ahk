; tests/meta/test_keyboard_shortcut_slots_roundtrip.ahk

; ==============================================================================
; MODULE: Keyboard Shortcut Slot Round-Trip Meta Test
; DESCRIPTION:
; A keyboard shortcut the user adds must survive the reload that saves it.
;
; SetKeyboardShortcutAction persists the chosen slot to config.toml and then
; calls Reload. ReadKeyboardShortcutsConfig iterated only the fifteen shipped
; KEYBOARD_SHORTCUT_DEFAULTS, while the slot picker offers every modifier chord
; in GESTURE_ACTIONS — on the order of six hundred. So a slot like win_b was
; written to disk and then never read back: absent from
; KeyboardShortcutAssignments, no hotkey registered by the boot loop, and gone
; from the menu, which builds from the same Map.
;
; The value stayed in config.toml, so nothing looked lost. The addition simply
; appeared not to have taken.
;
; FEATURES & RATIONALE:
; 1. Encodes the ROOT CAUSE — the read must cover PERSISTED slots, not just the
;    shipped ones — rather than naming win_b or any particular chord.
; 2. Pins the drift directly: _GlobalClearAllBindings already walks _IniCache for
;    exactly these non-default slots. The clear path and the read path must agree
;    about which slots exist, and this asserts both consult the same source.
;
; SCOPE: source introspection of infra/config_io.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================
; ==================================================
; ======= 1/ The read covers persisted slots =======
; ==================================================
; ==================================================

_KSSR_ReadCoversPersistedSlots() {
	Body := _DriverFuncBody("ReadKeyboardShortcutsConfig")
	Assert(Body != "", "ReadKeyboardShortcutsConfig() must exist in infra/config_io.ahk")

	Assert(InStr(Body, "_IniCache") > 0,
		"ReadKeyboardShortcutsConfig must consult the persisted config section — reading only KEYBOARD_SHORTCUT_DEFAULTS silently drops every slot the user added, on the very reload that was meant to save it")
	Assert(InStr(Body, '"ahk.shortcuts.keyboard"') > 0,
		"the read must enumerate the persisted ahk.shortcuts.keyboard section")

	; The defaults must still seed the Map, or a slot the user never touched
	; loses its shipped action.
	Assert(InStr(Body, "KEYBOARD_SHORTCUT_DEFAULTS") > 0,
		"the shipped defaults must still seed KeyboardShortcutAssignments")

	; Enumerating the persisted section only inside the defaults loop would look
	; right and fix nothing, so require the union to be built before iterating.
	UnionPos := InStr(Body, "SlotsToRead")
	Assert(UnionPos > 0,
		"the read must iterate the UNION of shipped and persisted slots — iterating the defaults and merely consulting the cache inside that loop leaves added slots unreachable")
}

; The clear path and the read path must agree on which slots exist. They drifted
; once: _GlobalClearAllBindings walked _IniCache for non-default slots while the
; reader did not, which is what proves the restriction was accidental.
_KSSR_ClearAndReadAgreeOnSlotSource() {
	Clear := _DriverFuncBody("_GlobalClearAllBindings")
	Read := _DriverFuncBody("ReadKeyboardShortcutsConfig")
	Assert(Clear != "" and Read != "", "both the clear and read paths must exist")

	for Name, Body in Map("_GlobalClearAllBindings", Clear, "ReadKeyboardShortcutsConfig", Read) {
		Assert(InStr(Body, '_IniCache["ahk.shortcuts.keyboard"]') > 0,
			Name . " must enumerate the persisted keyboard-shortcut section — if only one of the two does, a slot exists for one operation and not the other")
	}
}


Test("meta shortcuts: the keyboard read covers persisted slots, not just defaults",
	_KSSR_ReadCoversPersistedSlots)
Test("meta shortcuts: the clear and read paths enumerate the same slot source",
	_KSSR_ClearAndReadAgreeOnSlotSource)
