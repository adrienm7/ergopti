; tests/meta/test_remap_emit_critical_uneven.ahk

; ==============================================================================
; MODULE: Layout Emit Serialization Meta Test
; DESCRIPTION:
; Static source guard for finding "remap-emit-critical-uneven".
;
; SendMode is "Event" (globally interruptible). _RemapEmit wraps its SendEvent in
; Critical("On") so remapped letters cannot interleave in the single OS input
; queue, but the digit-row and shifted-symbol emitters were left NON-Critical.
; A digit handler firing between two remapped letters could start its SendEvent
; while a letter's SendEvent was still draining, re-introducing the exact
; out-of-order emission Critical was added to prevent - only with the digit as
; the unprotected boundary.
;
; The fix routes the digit-row down/up emits (_DigitRowDown / _DigitRowUp) and
; the shifted-symbol emit (_DigitShiftSend) through the SAME Critical("On")
; contract as _RemapEmit. This is a meta-static test because layout.ahk
; registers top-level hotkeys and cannot be #Included by the headless runner;
; it scans source text so a new non-serialised emitter fails the suite.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Source scan helpers =======
; ======================================
; ======================================

; Reads a windows/-relative source file. Still used by the SC029/SC00C/SC00D
; hotkey scan below: SC029:: is NOT unique across the modules tree (it also tags
; the screenshot hotkey in modules/shortcuts/win.ahk), so no concat helper can
; safely scope that positional/first-match scan — it stays a pinned read.
_RECU_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Asserts the function FnName exists in the driver source and its body wraps the
; emit in Critical("On") - the shared atomicity contract. Move-resilient: locates
; the function via the framework helper (bare name) instead of a pinned read.
_RECU_AssertEmitterIsCritical(FnName) {
	Body := _DriverFuncBody(FnName)
	Assert(Body != "", FnName . " must exist in layout.ahk (remap-emit-critical-uneven)")
	Assert(InStr(Body, "Critical(") > 0,
		FnName . " must serialise its SendEvent with Critical so it cannot interleave with a remapped letter's emit (remap-emit-critical-uneven)")
}





; ====================================================
; ====================================================
; ======= 2/ Critical-serialization assertions =======
; ====================================================
; ====================================================

_RECU_AssertDigitRowEmittersCritical() {
	_RECU_AssertEmitterIsCritical("_DigitRowDown")
	_RECU_AssertEmitterIsCritical("_DigitRowUp")
}
Test("layout: digit-row emitters are Critical-serialised (remap-emit-critical-uneven)", _RECU_AssertDigitRowEmittersCritical)

_RECU_AssertShiftSymbolEmitterCritical() {
	_RECU_AssertEmitterIsCritical("_DigitShiftSend")
}
Test("layout: shifted-symbol emitter is Critical-serialised (remap-emit-critical-uneven)", _RECU_AssertShiftSymbolEmitterCritical)

_RECU_AssertNumberRowRoutesThroughHelpers() {
	; Move-resilient: scan the modules dir via the framework helper. _DigitRowDown(
	; and _DigitRowUp( are unique to layout.ahk within modules, so these present
	; checks are unambiguous.
	Src := _DriverDirConcat("modules")
	; The inline number-row hotkeys must delegate to the serialised helpers
	; rather than calling SendEvent("{1 Down}") directly (the old non-Critical
	; path). A regression that inlines a bare SendEvent again drops this token.
	Assert(InStr(Src, "_DigitRowDown(") > 0,
		"the number-row hotkeys must delegate to _DigitRowDown so the emit is Critical-serialised (remap-emit-critical-uneven)")
	Assert(InStr(Src, "_DigitRowUp(") > 0,
		"the number-row hotkeys must delegate to _DigitRowUp so the emit is Critical-serialised (remap-emit-critical-uneven)")
}
Test("layout: number-row hotkeys delegate to the serialised emit helpers (remap-emit-critical-uneven)", _RECU_AssertNumberRowRoutesThroughHelpers)


_RECU_AssertOuterSymbolsRouteViaShiftSend() {
	Src := _RECU_ReadSource("modules/keymap/layout.ahk")
	; SC029 ($), SC00C (%), SC00D (=) sit outside the SC002-SC00B digit run but
	; are still part of the same number-row block. They must delegate to
	; _DigitShiftSend (which wraps Critical("On")) instead of calling
	; SendNewResult directly — a bare SendNewResult has no Critical and can
	; interleave with a neighbouring remap's SendEvent (remap-emit-critical-uneven).
	for SC in ["SC029", "SC00C", "SC00D"] {
		; Find the hotkey line for this scancode.
		Idx := InStr(Src, SC . "::")
		Assert(Idx > 0, SC . ":: hotkey must exist in modules/keymap/layout.ahk")
		; Extract the rest of that line and assert it routes via _DigitShiftSend.
		LineEnd := InStr(Src, "`n", , Idx)
		HotkeyLine := LineEnd ? SubStr(Src, Idx, LineEnd - Idx) : SubStr(Src, Idx, 120)
		Assert(InStr(HotkeyLine, "_DigitShiftSend(") > 0,
			SC . ":: must delegate to _DigitShiftSend — calling SendNewResult directly bypasses Critical and allows transposition with a neighbouring remap (remap-emit-critical-uneven)")
	}
}
Test("layout: SC029/SC00C/SC00D route through _DigitShiftSend (remap-emit-critical-uneven)", _RECU_AssertOuterSymbolsRouteViaShiftSend)
