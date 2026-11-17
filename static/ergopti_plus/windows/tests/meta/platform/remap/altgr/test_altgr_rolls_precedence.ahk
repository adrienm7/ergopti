; tests/meta/platform/remap/altgr/test_altgr_rolls_precedence.ahk

; ==============================================================================
; MODULE: AltGr Rolls Registration-Precedence Guard Meta Test
; DESCRIPTION:
; Guards the precedence of the two AltGr rolls (altgr-rolls-dead-precedence).
;
; The two AltGr rolls (SC138 & SC012 chevron_equal, SC138 & SC017 hashtag_quote /
; paren_quote / bracket_quote) bind the SAME custom-combination chords that the
; ErgoptiAltGr base rows bind. When several variants of one hotkey are eligible,
; AHK fires the one CREATED EARLIEST (the #HotIf documentation). An earlier fix
; believed the opposite and registered the rolls LAST: the base-row variant then
; always won, the roll handlers never ran, and « (# » typed « (# » instead of
; « (" » (the maintainer, 2026-11-17).
;
; Two checks: the interpreter's rule itself, on two variants of a real hotkey
; fired by a synthetic key, so a wrong belief about it fails here; and the
; registration ORDER the rule requires, scanned in modules/keymap/layout.ahk,
; which registers top-level hotkeys and is not #Included by the headless runner
; (the SC138-prefix chord itself needs a physical AltGr/Kana key).
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helper ====================
; ==================================================
; ==================================================

; ==================================================
; ==================================================
; ======= 2/ Registration-order assertion ==========
; ==================================================
; ==================================================

; Position of the bare CALL line "Name()" (flush-left, own line). The multiline
; anchors exclude the "Name() {" definition (line does not end after the parens)
; and any "; ... Name() ..." comment (line does not start with the call).
_ARP_CallLinePos(Src, Name) {
	if RegExMatch(Src, "m)^" . Name . "\(\)\s*$", &M)
		return M.Pos
	return 0
}

_ARP_RollsRegisteredFirst() {
	; Move-resilient: both call sites live in modules/keymap/layout.ahk; scope to the
	; modules tree so their relative registration order is preserved in the concat
	Src := _DriverDirsConcat("modules", "gestures/engine", "gestures/adapters", "diagnostics/engine/reports", "ai/engine")
	PosLayer := _ARP_CallLinePos(Src, "RegisterAltGrLayer")
	PosRolls := _ARP_CallLinePos(Src, "_RegisterRollsAltGrHotkeys")
	Assert(PosLayer > 0, "RegisterAltGrLayer() call site must exist in modules/keymap/layout.ahk")
	Assert(PosRolls > 0, "_RegisterRollsAltGrHotkeys() call site must exist in modules/keymap/layout.ahk")
	Assert(PosRolls < PosLayer,
		"_RegisterRollsAltGrHotkeys() must be called BEFORE RegisterAltGrLayer(): the earliest-created eligible variant fires, so a roll registered after the base rows is shadowed on SC138 & SC012 / SC138 & SC017 and the roll feature is silently dead (altgr-rolls-dead-precedence)")
	; Registered first, a roll must stand down where its base row does.
	Body := _DriverFuncBody("_RollAltGrRowLive")
	AssertContains(Body, "ergopti_alt_gr", "a roll follows the AltGr layer switch")
	AssertContains(Body, "LayoutRowIsEmulatedHotkey(Name)", "a roll follows its row's emulation")
	AssertContains(Body, "IsRealAltGrPress()", "a roll needs a real AltGr press")
}
Test("layout: AltGr rolls are registered FIRST so they outrank the base rows (altgr-rolls-dead-precedence)", _ARP_RollsRegisteredFirst)

; ==================================================
; ==================================================
; ======= 3/ Interpreter precedence rule ===========
; ==================================================
; ==================================================

; ahk-parallel: session-exclusive the case injects a synthetic F23 and F24 at send level 1.
global _ARP_Fired := ""

_ARP_Mark(Which, *) {
	global _ARP_Fired
	_ARP_Fired .= Which
}

; Two eligible variants of one hotkey, and of one custom combination, created
; one after the other: the first created fires, alone.
_ARP_EarliestVariantFires() {
	global _ARP_Fired
	InstallKeybdHook()
	PreviousLevel := A_SendLevel
	try {
		HotIf((*) => true)
		Hotkey("$F23", _ARP_Mark.Bind("first"), "I0")
		HotIf((*) => 1 == 1)
		Hotkey("$F23", _ARP_Mark.Bind("second"), "I0")
		HotIf((*) => true)
		Hotkey("F24 & F23", _ARP_Mark.Bind("first-combo"), "I0")
		HotIf((*) => 1 == 1)
		Hotkey("F24 & F23", _ARP_Mark.Bind("second-combo"), "I0")
		HotIf()
		SendLevel(1)
		_ARP_Fired := ""
		SendEvent("{F23}")
		Started := A_TickCount
		while (_ARP_Fired == "") && (A_TickCount - Started < 2000)
			Sleep(10)
		Sleep(100)
		AssertEqual("first", _ARP_Fired, "the earliest-created eligible variant of a hotkey fires, alone")
		_ARP_Fired := ""
		SendEvent("{F24 down}{F23}{F24 up}")
		Started := A_TickCount
		while (_ARP_Fired == "") && (A_TickCount - Started < 2000)
			Sleep(10)
		Sleep(100)
		AssertEqual("first-combo", _ARP_Fired, "the earliest-created eligible variant of a custom combination fires, alone")
	} finally {
		SendLevel(PreviousLevel)
		HotIf((*) => true)
		try Hotkey("$F23", "Off")
		try Hotkey("F24 & F23", "Off")
		HotIf((*) => 1 == 1)
		try Hotkey("$F23", "Off")
		try Hotkey("F24 & F23", "Off")
		HotIf()
	}
}
Test("AutoHotkey fires the earliest-created eligible variant of a hotkey (altgr-rolls-dead-precedence)", _ARP_EarliestVariantFires)
