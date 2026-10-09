; tests/meta/test_tap_hold_taps_use_held_modifier_emitter.ahk

; ==============================================================================
; MODULE: Tap-hold keystroke taps go through TapHoldEmitKeyTap
; DESCRIPTION:
; A keystroke tap sent as a bare key drops every modifier the user holds on
; another key: Shift held then an AltGr tap gave Tab instead of Shift+Tab
; (held-modifier-tap-2026-09-25). The unit tests pin TapHoldEmitKeyTap and the
; configured-action path; the native taps and the Backspace fallbacks live in
; hotkey bodies and handlers the unit runner cannot reach, so their wiring is
; pinned here, and no tap output may bind a bare key to TextPressKey again.
; ==============================================================================

#Requires AutoHotkey v2.0

_THME_NativeTapsUseTheEmitter() {
	Src := _DriverDirConcat("platform/remap")
	Quote := Chr(34)
	for KeyId, Key in Map("tab", "Tab", "enter", "Enter", "escape", "Escape",
			"backspace", "BackSpace", "delete", "Delete") {
		Needle := "TapHoldDispatchTap(" . Quote . KeyId . Quote . ", TapHoldEmitKeyTap.Bind("
			. Quote . Key . Quote . "))"
		Assert(InStr(Src, Needle) > 0,
			"the native " . Key . " tap must be sent under the held modifiers: " . Needle)
	}
	for _, KeyId in ["left_alt", "right_ctrl"] {
		Needle := "TapHoldDispatchTap(" . Quote . KeyId . Quote . ", TapHoldEmitKeyTap.Bind(" . Quote . "Tab" . Quote . "))"
		Assert(InStr(Src, Needle) > 0, "the " . KeyId . " Tab tap must be sent under the held modifiers")
	}
}
Test("tap-hold modifiers: native and special Tab taps use the held-modifier emitter (held-modifier-tap-2026-09-25)",
	_THME_NativeTapsUseTheEmitter)

_THME_NoTapBindsABareKey() {
	Src := _DriverDirConcat("platform/remap")
	Dispatches := 0
	Pos := 1
	while Pos := RegExMatch(Src, "TapHoldDispatchTap\(\s*" . Chr(34) . "(\w+)" . Chr(34) . "\s*,\s*([^\r\n]*)", &Match, Pos) {
		Dispatches++
		Assert(!RegExMatch(Match[2], "^TextPressKey\.Bind\(\s*" . Chr(34) . "\w+" . Chr(34) . "\s*,\s*(\[\]|" . Chr(34) . Chr(34) . ")\s*\)"),
			"the '" . Match[1] . "' tap binds a bare key, which drops the held modifiers: " . Match[0])
		Assert(!InStr(Match[2], "LLM_Tooltip_FireTabOrAccept.Bind("),
			"the '" . Match[1] . "' tap binds the Tab wrapper without the held modifiers: " . Match[0])
		Pos += StrLen(Match[0])
	}
	Assert(Dispatches >= 15, "every tap dispatch of platform/remap must be scanned, got " . Dispatches)
}
Test("tap-hold modifiers: no tap dispatch binds a bare key (held-modifier-tap-2026-09-25)",
	_THME_NoTapBindsABareKey)

_THME_BackspaceFallbacksUseTheEmitter() {
	for _, Name in ["_LAltBackspaceTap", "_RCtrlBackspaceTap"] {
		Body := _DriverFuncBody(Name)
		Assert(InStr(Body, "TapHoldEmitKeyTap(" . Chr(34) . "BackSpace" . Chr(34) . ")") > 0,
			Name . " must send its plain Backspace under the held modifiers")
	}
}
Test("tap-hold modifiers: the Backspace tap fallbacks use the held-modifier emitter (held-modifier-tap-2026-09-25)",
	_THME_BackspaceFallbacksUseTheEmitter)
