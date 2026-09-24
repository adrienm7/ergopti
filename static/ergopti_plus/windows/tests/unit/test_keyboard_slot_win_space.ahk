; static/ergopti_plus/windows/tests/unit/test_keyboard_slot_win_space.ahk

; ==============================================================================
; MODULE: Win+Space is a suppressing keyboard slot (win-space-slot)
; DESCRIPTION:
; Windows binds Win+Space to "generate an AI prediction" through an ordinary
; keyboard slot (win_space), replacing the AI menu's own trigger shortcut. The
; slot must resolve to a native hotkey WITHOUT the "~" pass-through prefix:
; that prefix would let the press through, and Windows would still switch the
; input language on every prediction request.
;
; ROOT CAUSE ENCODED: the chord a slot id names and the native spec the
; registrar builds from it are two translations; this pins both for win_space,
; and the menu label the slot shows. The default binding itself lives in
; infra/feature_state.ahk, which the suite does not load; the JS gate
; test-keyboard-slot-recommended-bindings.cjs pins it to the manifest.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ The chord and its spec =======
; =========================================
; =========================================

_KSWS_WinSpaceResolvesToASuppressingSpec() {
	Chord := _KeyboardSlotChord("win_space")
	Parsed := ChordParse(Chord)
	Assert(Parsed["ok"], "win_space must resolve to a chord, got '" . Chord . "'")
	Spec := HotkeyRegistrarNativeSpec(Parsed["mods"], Parsed["key"])
	AssertEqual("#space", Spec,
		"win_space must register as #space, with no ~ prefix: the key must never reach Windows")
	AssertEqual("Win + " . t("common.key_space"), _FormatSlotLabel("win_space"),
		"the menu must name the chord in the user's language")
}
Test("Keyboard slots: win_space is a suppressing Win+Space hotkey (win-space-slot)",
	_KSWS_WinSpaceResolvesToASuppressingSpec)
