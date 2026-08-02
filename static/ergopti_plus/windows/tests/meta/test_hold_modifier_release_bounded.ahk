; tests/meta/test_hold_modifier_release_bounded.ahk

; ==============================================================================
; MODULE: Generic Hold-Modifier Bounded-Release Guard Meta Test
; DESCRIPTION:
; Static source guard for the hold-modifier-unbounded-keywait finding.
;
; The GENERIC "hold = ctrl/shift/alt/win" tap-hold long-press branches arm a
; synthetic modifier Down, then wait on KeyWait for the PHYSICAL key to be
; released, then send the modifier Up. The buggy form did this with an
; UNBOUNDED KeyWait and no try/finally: if the key-up event was lost (focus
; stolen by a UAC prompt, the global Suspend hotkey toggled mid-press) or a
; Send threw, the modifier Up was skipped and Ctrl/Shift/Alt/Win latched Down
; system-wide (every subsequent keystroke becomes a chord).
;
; The one_shot_shift paths were already hardened (oneshotshift-lalt-lshift-stuck)
; but these generic branches were missed. The fix wraps each long-press
; arm/release pair in try { KeyWait(.., "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC) }
; finally { TextPressKey(ModKey, "Up") } so the release ALWAYS runs and the wait
; is bounded.
;
; Meta-static (scans source text) because platform/remap/*.ahk register
; top-level #HotIf hotkeys and cannot be #Included by the headless runner. If a
; long-press branch regresses to a bare unbounded KeyWait or drops the finally,
; this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Returns the concatenated tap_holds module source. The per-key #HotIf anchors and
; _SpaceHold* function markers are unique across these files, so a whole-dir scan
; resolves each block regardless of how the module is split — move-resilient.
; RelPath is kept for call-site clarity.
_HMRB_ReadSource(RelPath) {
	return _DriverDirConcat("platform/remap")
}

; Extracts the body of a single hotkey block: from the Anchor (a substring on the
; block's #HotIf line) to the first closing brace at column 0 (top-level hotkey
; blocks close with `}` flush-left; inner if/try/finally blocks close indented).
_HMRB_Block(Src, Anchor) {
	Idx := InStr(Src, Anchor)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		return SubStr(Rest, 1, End + 1)
	return Rest
}

; Asserts the generic hold-modifier long-press block bounds its wait and releases
; the modifier in a finally, and that no bare unbounded KeyWait(key, "U") remains.
_HMRB_AssertBounded(RelPath, Anchor, Where) {
	Q := Chr(34)
	Src := _HMRB_ReadSource(RelPath)
	Body := _HMRB_Block(Src, Anchor)
	Assert(Body != "", Where . " generic hold-modifier #HotIf block must exist")
	Assert(InStr(Body, "STUCK_MODIFIER_RELEASE_TIMEOUT_SEC") > 0,
		Where . " long-press KeyWait must be capped by STUCK_MODIFIER_RELEASE_TIMEOUT_SEC so a lost key-up cannot block the modifier release forever")
	Assert(InStr(Body, "finally") > 0,
		Where . " must release the modifier in a finally so a lost key-up or thrown Send can never latch Ctrl/Shift/Alt/Win Down")
	Assert(InStr(Body, "KeyWait") > 0, Where . " must still KeyWait for the physical release")
	; A bare unbounded wait ends with the literal "U") — the capped form is "U T".
	Assert(InStr(Body, "KeyWait(") > 0 and !InStr(Body, Q . "U" . Q . ")"),
		Where . " must not use a bare unbounded KeyWait(key, " . Q . "U" . Q . ") — use the capped " . Q . "U T" . Q . " . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC form")
}




; ==================================================
; ==================================================
; ======= 2/ Per-block guard assertions ============
; ==================================================
; ==================================================

_HMRB_CapsLockGuarded() {
	_HMRB_AssertBounded("platform/remap/capslock.ahk", "_CapsLockHasHoldModifier() and not LayerEnabled", "capslock.ahk 2.3")
}
Test("tap-holds: CapsLock generic hold-modifier release is bounded + in finally (hold-modifier-unbounded-keywait)", _HMRB_CapsLockGuarded)

_HMRB_EnterGuarded() {
	Q := Chr(34)
	; Full #HotIf condition — the bare "enter" call also appears in _EnterHoldModKey().
	_HMRB_AssertBounded("platform/remap/enter.ahk", "TapHoldHoldModifier(TapHold, " . Q . "enter" . Q . ") != " . Q . Q . " and not LayerEnabled", "enter.ahk 9.1")
}
Test("tap-holds: Enter generic hold-modifier release is bounded + in finally (hold-modifier-unbounded-keywait)", _HMRB_EnterGuarded)

_HMRB_LAltBackspaceGuarded() {
	Q := Chr(34)
	; Full #HotIf condition — the bare backspace check also appears in _LAltIsSpecialTap().
	_HMRB_AssertBounded("platform/remap/lalt.ahk", "TapHoldTapAction(TapHold, " . Q . "left_alt" . Q . ") == " . Q . "backspace" . Q . " and TapHoldHoldModifier(TapHold, " . Q . "left_alt" . Q . ") != " . Q . Q, "lalt.ahk 4.6")
}
Test("tap-holds: LAlt backspace hold-modifier release is bounded + in finally (hold-modifier-unbounded-keywait)", _HMRB_LAltBackspaceGuarded)

_HMRB_LAltGenericGuarded() {
	Q := Chr(34)
	Anchor := "not _LAltIsSpecialTap() and TapHoldHoldModifier(TapHold, " . Q . "left_alt" . Q . ")"
	_HMRB_AssertBounded("platform/remap/lalt.ahk", Anchor, "lalt.ahk 4.7")
	Body := _HMRB_Block(_HMRB_ReadSource("platform/remap/lalt.ahk"), Anchor)
	SuppressIdx := InStr(Body, "TapHoldShouldSuppressHold")
	DownIdx := InStr(Body, "TapHoldSyntheticKeyDown(ModKey)")
	Assert(SuppressIdx > 0 and DownIdx > SuppressIdx,
		"lalt.ahk 4.7 must not acquire the synthetic modifier before its wheel-cancellation guard (lalt-generic-cancel-releases-modifier)")
}
Test("tap-holds: LAlt generic hold-modifier release is bounded + cancellation precedes acquisition (lalt-generic-cancel-releases-modifier)", _HMRB_LAltGenericGuarded)

_HMRB_RCtrlGenericGuarded() {
	Q := Chr(34)
	_HMRB_AssertBounded("platform/remap/rctrl.ahk", "not _RCtrlIsSpecialTap() and TapHoldHoldModifier(TapHold, " . Q . "right_ctrl" . Q . ")", "rctrl.ahk 7.4")
}
Test("tap-holds: RCtrl generic hold-modifier release is bounded + in finally (hold-modifier-unbounded-keywait)", _HMRB_RCtrlGenericGuarded)

_HMRB_SpaceGenericModifierGuarded() {
	Src := _HMRB_ReadSource("platform/remap/space.ahk")
	Body := _HMRB_Block(Src, "_SpaceHoldWithModifier(captured)")
	_HMRB_AssertBounded("platform/remap/space.ahk", "_SpaceHoldWithModifier(captured)", "space.ahk _SpaceHoldWithModifier")
	Assert(!InStr(Body, "U T2"), "space.ahk generic modifier hold must not contain magic number " . Chr(34) . "U T2" . Chr(34) . " — use STUCK_MODIFIER_RELEASE_TIMEOUT_SEC")
}
Test("tap-holds: Space generic hold-modifier release is bounded + in finally (hold-modifier-unbounded-keywait)", _HMRB_SpaceGenericModifierGuarded)

; alt_tab_monitor blocks were missed by the original hardening sweep: the LAlt 4.3
; block (lalt.ahk) had a bare unbounded KeyWait(SC038, "U") as its SOLE release path,
; and the Tab 8.1 hold path (tab.ahk) relied only on a Suspend-disarmable SC00F Up::.
_HMRB_LAltAltTabGuarded() {
	Q := Chr(34)
	_HMRB_AssertBounded("platform/remap/lalt.ahk", "TapHoldTapAction(TapHold, " . Q . "left_alt" . Q . ") == " . Q . "alt_tab_monitor" . Q, "lalt.ahk 4.3 alt_tab_monitor")
}
Test("tap-holds: LAlt alt_tab_monitor hold release is bounded + in finally (hold-modifier-unbounded-keywait)", _HMRB_LAltAltTabGuarded)

_HMRB_TabAltTabGuarded() {
	Q := Chr(34)
	_HMRB_AssertBounded("platform/remap/tab.ahk", "TapHoldTapAction(TapHold, " . Q . "tab" . Q . ") == " . Q . "alt_tab_monitor" . Q, "tab.ahk 8.1 alt_tab_monitor")
}
Test("tap-holds: Tab alt_tab_monitor hold release is bounded + in finally (hold-modifier-unbounded-keywait)", _HMRB_TabAltTabGuarded)




; ==================================================
; ==================================================
; ======= 3/ Whole-class KeyWait guard =============
; ==================================================
; ==================================================

; Scans the ENTIRE platform/remap/ directory for any bare KeyWait(key, "U")
; call — the unbounded form that can latch a modifier or layer permanently on a
; lost key-up event. The per-block guards above cover the documented regression
; sites; this guard catches any missed sibling added to any tap_holds file.
_HMRB_WholeClassNoBareUnbounded() {
	Q := Chr(34)
	Src := _DriverDirConcat("platform/remap")
	; Q . "U" . Q . ")" is the 4-char token "U") — the bare unbounded form of the
	; KeyWait mode argument. The bounded form "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC
	; never produces this token because the timeout constant follows before the closing
	; paren, making the mode string "U T<N>" not "U".
	Assert(!InStr(Src, Q . "U" . Q . ")"),
		"platform/remap/ contains a bare KeyWait(key, " . Q . "U" . Q . ") "
		. "— all hold-modifier and hold-layer long-press waits must use "
		. Q . "U T" . Q . " . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC "
		. "so a lost key-up never latches a modifier or layer permanently")
}
Test("tap-holds: no bare unbounded KeyWait anywhere in platform/remap/ (hold-keywait-whole-class)", _HMRB_WholeClassNoBareUnbounded)
