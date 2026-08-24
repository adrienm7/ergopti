; tests/meta/test_hold_layer_release_bounded.ahk

; ==============================================================================
; MODULE: Hold-Layer Bounded-Release Guard Meta Test
; DESCRIPTION:
; Static source guard for the hold-layer-unbounded-keywait finding.
;
; The "hold = layer" tap-hold long-press branches activate the layer on
; key-down, wait on KeyWait for the PHYSICAL key to be released, then
; disable the layer. The buggy form used a bare unbounded KeyWait with no
; try/finally: if the key-up event was lost (focus stolen by a UAC prompt,
; Suspend toggled mid-press, or an exception thrown mid-block), DisableLayer()
; was skipped and the layer stayed stuck on permanently.
;
; The fix wraps each ActivateLayer/KeyWait/DisableLayer triple in
; try { KeyWait(.., "U T" . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC) }
; finally { DisableLayer() } so the layer is ALWAYS deactivated and the wait
; is bounded.
;
; Meta-static (scans source text) because platform/remap/*.ahk register
; top-level #HotIf hotkeys and cannot be #Included by the headless runner.
; If a hold-layer branch regresses to a bare unbounded KeyWait or drops the
; finally, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Returns the concatenated tap_holds module source. The per-key #HotIf anchors are
; unique across these files, so a whole-dir scan resolves each block regardless of
; how the module is split — move-resilient. RelPath is kept for call-site clarity.
_HLRB_ReadSource(RelPath) {
	return _DriverDirConcat("platform/remap")
}

; Extracts the body of a single hotkey block: from the Anchor (a substring on
; the block's #HotIf line or opening brace area) to the first closing brace at
; column 0 (top-level hotkey blocks close with `}` flush-left; inner
; if/try/finally blocks close indented).
_HLRB_Block(Src, Anchor) {
	Idx := InStr(Src, Anchor)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		return SubStr(Rest, 1, End + 1)
	return Rest
}

; Every hold-layer hotkey must delegate to the shared owner.  That owner makes
; LayerEnabled visible synchronously on key-down, bounds every physical-release
; wait, and disables the layer in a finally before the caller emits a tap.
_HLRB_AssertBounded(RelPath, Anchor, Where) {
	Q := Chr(34)
	Src := _HLRB_ReadSource(RelPath)
	Body := _HLRB_Block(Src, Anchor)
	Assert(Body != "", Where . " hold-layer #HotIf block must exist")
	Assert(InStr(Body, "TapHoldOwnImmediateLayer(") > 0,
		Where . " must activate the shared layer owner synchronously on key-down")
	Assert(!InStr(Body, "KeyWait("),
		Where . " must not wait for the tap threshold before publishing LayerEnabled")
}




; ==================================================
; ==================================================
; ======= 2/ Per-block guard assertions ============
; ==================================================
; ==================================================

_HLRB_RCtrlHoldLayer() {
	Q := Chr(34)
	; The anchor is a LOCATOR for block 7.5, not part of the guarantee. It used
	; to include the gate's `and TapHoldTapAction(...) != ""` conjunct, which was
	; dropped so a hold arms on the hold alone (taphold-hold-option-unreachable);
	; the `not _RCtrlIsSpecialTap()` prefix is the stable half and is what
	; test_hold_modifier_release_bounded already anchors on for block 7.4.
	_HLRB_AssertBounded("platform/remap/rctrl.ahk",
		"not _RCtrlIsSpecialTap() and TapHoldHoldLayer(TapHold, " . Q . "right_ctrl" . Q . ") != " . Q . Q,
		"rctrl.ahk 7.5")
}
Test("tap-holds: RCtrl hold-layer release is bounded + in finally (hold-layer-unbounded-keywait)", _HLRB_RCtrlHoldLayer)

_HLRB_EscapeHoldLayer() {
	Q := Chr(34)
	_HLRB_AssertBounded("platform/remap/escape.ahk",
		"TapHoldHoldLayer(TapHold, " . Q . "escape" . Q . ") != " . Q . Q . " and TapHoldHoldModifier(TapHold, " . Q . "escape" . Q . ") == " . Q . Q,
		"escape.ahk 11.2")
}
Test("tap-holds: Escape hold-layer release is bounded + in finally (hold-layer-unbounded-keywait)", _HLRB_EscapeHoldLayer)

_HLRB_EnterHoldLayer() {
	Q := Chr(34)
	_HLRB_AssertBounded("platform/remap/enter.ahk",
		"TapHoldHoldLayer(TapHold, " . Q . "enter" . Q . ") != " . Q . Q . " and TapHoldHoldModifier(TapHold, " . Q . "enter" . Q . ") == " . Q . Q,
		"enter.ahk 9.2")
}
Test("tap-holds: Enter hold-layer release is bounded + in finally (hold-layer-unbounded-keywait)", _HLRB_EnterHoldLayer)

_HLRB_LAltTabLayer() {
	Q := Chr(34)
	; Section 4.2: tab tap + hold-layer — bare KeyWait("SC038") with no flags.
	_HLRB_AssertBounded("platform/remap/lalt.ahk",
		"TapHoldTapAction(TapHold, " . Q . "left_alt" . Q . ") == " . Q . "tab" . Q . " and not LayerEnabled",
		"lalt.ahk 4.2")
}
Test("tap-holds: LAlt tab+layer hold-layer release is bounded + in finally (hold-layer-unbounded-keywait)", _HLRB_LAltTabLayer)

_HLRB_LAltBackspaceLayer() {
	Q := Chr(34)
	; Section 4.5: backspace tap + hold-layer.
	_HLRB_AssertBounded("platform/remap/lalt.ahk",
		"_LAltIsBackspaceLayer() and not LayerEnabled",
		"lalt.ahk 4.5")
}
Test("tap-holds: LAlt backspace+layer hold-layer release is bounded + in finally (hold-layer-unbounded-keywait)", _HLRB_LAltBackspaceLayer)

_HLRB_LAltGenericLayer() {
	Q := Chr(34)
	; Section 4.8: generic hold-layer, any non-special tap. The trailing
	; `and TapHoldTapAction` was only a locator suffix; the gate no longer
	; requires a tap action so a hold arms on the hold alone
	; (taphold-hold-option-unreachable). The assertions are unchanged.
	_HLRB_AssertBounded("platform/remap/lalt.ahk",
		"not _LAltIsSpecialTap() and TapHoldHoldLayer(TapHold, " . Q . "left_alt" . Q . ") != " . Q . Q,
		"lalt.ahk 4.8")
}
Test("tap-holds: LAlt generic hold-layer release is bounded + in finally (hold-layer-unbounded-keywait)", _HLRB_LAltGenericLayer)

_HLRB_BackspaceHoldLayer() {
	Q := Chr(34)
	_HLRB_AssertBounded("platform/remap/backspace.ahk",
		"TapHoldHoldLayer(TapHold, " . Q . "backspace" . Q . ") != " . Q . Q,
		"backspace.ahk 10.2")
}
Test("tap-holds: Backspace hold-layer is immediate and shared", _HLRB_BackspaceHoldLayer)

_HLRB_DeleteHoldLayer() {
	Q := Chr(34)
	_HLRB_AssertBounded("platform/remap/delete.ahk",
		"TapHoldHoldLayer(TapHold, " . Q . "delete" . Q . ") != " . Q . Q,
		"delete.ahk 13.2")
}
Test("tap-holds: Delete hold-layer is immediate and shared", _HLRB_DeleteHoldLayer)

_HLRB_WinHoldLayer() {
	Q := Chr(34)
	_HLRB_AssertBounded("platform/remap/win.ahk",
		"TapHoldHoldLayer(TapHold, " . Q . "win" . Q . ") != " . Q . Q,
		"win.ahk 12.2")
}
Test("tap-holds: Win hold-layer is immediate and shared", _HLRB_WinHoldLayer)

_HLRB_SpaceHoldLayer() {
	_HLRB_AssertBounded("platform/remap/space.ahk", "SpaceTapHoldLayer()", "space.ahk layer owner")
}
Test("tap-holds: Space hold-layer is immediate and shared", _HLRB_SpaceHoldLayer)

_HLRB_TabHoldLayer() {
	Q := Chr(34)
	_HLRB_AssertBounded("platform/remap/tab.ahk",
		"TapHoldTapAction(TapHold, " . Q . "tab" . Q . ") != " . Q . "alt_tab_monitor" . Q . " and TapHoldHoldLayer",
		"tab.ahk 8.3")
}
Test("tap-holds: Tab hold-layer is immediate and shared", _HLRB_TabHoldLayer)

_HLRB_CapsLockHoldLayer() {
	_HLRB_AssertBounded("platform/remap/capslock.ahk", "_CapsLockHasHoldLayer() and not LayerEnabled", "capslock.ahk layer owner")
}
Test("tap-holds: CapsLock hold-layer is immediate and shared", _HLRB_CapsLockHoldLayer)
