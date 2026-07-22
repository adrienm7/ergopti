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
; Meta-static (scans source text) because modules/tap_holds/*.ahk register
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
	return _DriverDirConcat("modules/tap_holds")
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

; Asserts the hold-layer long-press block bounds its KeyWait and releases the
; layer in a finally, and that no bare unbounded KeyWait remains.
_HLRB_AssertBounded(RelPath, Anchor, Where) {
	Q := Chr(34)
	Src := _HLRB_ReadSource(RelPath)
	Body := _HLRB_Block(Src, Anchor)
	Assert(Body != "", Where . " hold-layer #HotIf block must exist")
	Assert(InStr(Body, "STUCK_MODIFIER_RELEASE_TIMEOUT_SEC") > 0,
		Where . " long-press KeyWait must be capped by STUCK_MODIFIER_RELEASE_TIMEOUT_SEC so a lost key-up cannot block DisableLayer() forever")
	Assert(InStr(Body, "finally") > 0,
		Where . " must call DisableLayer() in a finally so a lost key-up or thrown error can never leave the layer stuck on")
	Assert(InStr(Body, "KeyWait") > 0, Where . " must still KeyWait for the physical release")
	; A bare unbounded wait ends with the literal "U") or bare KeyWait("key") --
	; detect both: "U") signals no timeout cap, bare no-arg form misses "U T".
	Assert(!InStr(Body, Q . "U" . Q . ")"),
		Where . " must not use a bare unbounded KeyWait(key, " . Q . "U" . Q . ") — use the capped " . Q . "U T" . Q . " . STUCK_MODIFIER_RELEASE_TIMEOUT_SEC form")
}




; ==================================================
; ==================================================
; ======= 2/ Per-block guard assertions ============
; ==================================================
; ==================================================

_HLRB_RCtrlHoldLayer() {
	Q := Chr(34)
	_HLRB_AssertBounded("modules/tap_holds/rctrl.ahk",
		"TapHoldHoldLayer(TapHold, " . Q . "right_ctrl" . Q . ") != " . Q . Q . " and TapHoldTapAction(TapHold, " . Q . "right_ctrl" . Q . ") != " . Q . Q,
		"rctrl.ahk 7.5")
}
Test("tap-holds: RCtrl hold-layer release is bounded + in finally (hold-layer-unbounded-keywait)", _HLRB_RCtrlHoldLayer)

_HLRB_EscapeHoldLayer() {
	Q := Chr(34)
	_HLRB_AssertBounded("modules/tap_holds/escape.ahk",
		"TapHoldHoldLayer(TapHold, " . Q . "escape" . Q . ") != " . Q . Q . " and TapHoldHoldModifier(TapHold, " . Q . "escape" . Q . ") == " . Q . Q,
		"escape.ahk 11.2")
}
Test("tap-holds: Escape hold-layer release is bounded + in finally (hold-layer-unbounded-keywait)", _HLRB_EscapeHoldLayer)

_HLRB_EnterHoldLayer() {
	Q := Chr(34)
	_HLRB_AssertBounded("modules/tap_holds/enter.ahk",
		"TapHoldHoldLayer(TapHold, " . Q . "enter" . Q . ") != " . Q . Q . " and TapHoldHoldModifier(TapHold, " . Q . "enter" . Q . ") == " . Q . Q,
		"enter.ahk 9.2")
}
Test("tap-holds: Enter hold-layer release is bounded + in finally (hold-layer-unbounded-keywait)", _HLRB_EnterHoldLayer)

_HLRB_LAltTabLayer() {
	Q := Chr(34)
	; Section 4.2: tab tap + hold-layer — bare KeyWait("SC038") with no flags.
	_HLRB_AssertBounded("modules/tap_holds/lalt.ahk",
		"TapHoldTapAction(TapHold, " . Q . "left_alt" . Q . ") == " . Q . "tab" . Q . " and not LayerEnabled",
		"lalt.ahk 4.2")
}
Test("tap-holds: LAlt tab+layer hold-layer release is bounded + in finally (hold-layer-unbounded-keywait)", _HLRB_LAltTabLayer)

_HLRB_LAltBackspaceLayer() {
	Q := Chr(34)
	; Section 4.5: backspace tap + hold-layer.
	_HLRB_AssertBounded("modules/tap_holds/lalt.ahk",
		"_LAltIsBackspaceLayer() and not LayerEnabled",
		"lalt.ahk 4.5")
}
Test("tap-holds: LAlt backspace+layer hold-layer release is bounded + in finally (hold-layer-unbounded-keywait)", _HLRB_LAltBackspaceLayer)

_HLRB_LAltGenericLayer() {
	Q := Chr(34)
	; Section 4.8: generic hold-layer, any non-special tap.
	_HLRB_AssertBounded("modules/tap_holds/lalt.ahk",
		"not _LAltIsSpecialTap() and TapHoldHoldLayer(TapHold, " . Q . "left_alt" . Q . ") != " . Q . Q . " and TapHoldTapAction",
		"lalt.ahk 4.8")
}
Test("tap-holds: LAlt generic hold-layer release is bounded + in finally (hold-layer-unbounded-keywait)", _HLRB_LAltGenericLayer)