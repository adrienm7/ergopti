; static/ergopti_plus/windows/tests/unit/test_audit_v4_fixes.ahk
;
; DESCRIPTION:
; Static-source regression guards for the five bugs fixed from the expert audit
; report RAPPORT_AUDIT_EXPERT_V4.md:
;   1. KL_Net_Start() stagger overwritten by immediate repeating SetTimer calls
;   2. A_MaxHotkeysPerInterval set inside *WheelUp/WheelDown hotkey bodies
;   3. CallbackCreate pointer never stored; CallbackFree never called
;   4. GR_DrawBitmap missing finally — GDI resources leaked on exception
;   5. SaveFullConfig returns without rescheduling when !_DriverReady

; (test_framework.ahk is provided once by run_all.ahk — do not re-include it here
; or the suite errors on duplicate definitions / a missing path under unit/.)

_AuditV4_ReadSrc(RelPath) {
	Base := StrReplace(A_LineFile, "tests\unit\test_audit_v4_fixes.ahk", "")
	return FileRead(Base . RelPath, "UTF-8")
}


; ==========================================================
; ===== 1) KL_Net_Start stagger — no immediate overwrite
; ==========================================================

TestAuditV4_NetStartStagger() {
	Src := _AuditV4_ReadSrc("modules\keylogger\keylogger_network.ahk")

	; The bug: SetTimer(KLNet.wifi_fn, KLNetConst.NETWORK_TICK_MS) called right
	; after the one-shot, destroying the stagger before it fires.
	; The fix: starters (wifi_start_fn etc.) arm the repeating timer after first fire.
	AssertFalse(
		InStr(Src, "SetTimer(KLNet.wifi_fn,  KLNetConst.NETWORK_TICK_MS)"),
		"KL_Net_Start must not immediately overwrite stagger with repeating timer for wifi_fn"
	)
	AssertTrue(
		InStr(Src, "wifi_start_fn"),
		"KL_Net_Start must use wifi_start_fn starters to defer repeating timer arm"
	)
	AssertTrue(
		InStr(Src, "wifi_start_fn") and InStr(Src, "reach_start_fn") and InStr(Src, "vpn_start_fn"),
		"KL_Net_Stop must cancel all three starters (wifi/reach/vpn_start_fn)"
	)
}
Test("Audit-v4: KL_Net_Start stagger not overwritten by immediate repeating SetTimer", TestAuditV4_NetStartStagger)


; ===================================================================
; ===== 2) A_MaxHotkeysPerInterval not set inside hotkey bodies
; ===================================================================

TestAuditV4_MaxHotkeysNotInHotkey() {
	Src := _AuditV4_ReadSrc("platform\remap\nav_layer.ahk")

	; The bug: assignment inside *WheelUp:: and *WheelDown:: hotkey bodies — only
	; takes effect after the first wheel event, too late to suppress the warning.
	; The fix: move assignment to module top-level (runs at #Include time).

	; Confirm the assignment exists (somewhere before the hotkey section).
	; Single-sourced from infra/nav_layer_helpers.ahk's NAV_LAYER_MAX_HOTKEYS_PER_INTERVAL
	; constant (F16) rather than a duplicated literal.
	AssertTrue(
		InStr(Src, "A_MaxHotkeysPerInterval := NAV_LAYER_MAX_HOTKEYS_PER_INTERVAL"),
		"nav_layer.ahk must set A_MaxHotkeysPerInterval := NAV_LAYER_MAX_HOTKEYS_PER_INTERVAL"
	)

	; Extract the *WheelUp hotkey body and assert it no longer sets the variable
	WheelUpStart := InStr(Src, "*WheelUp::")
	WheelDownEnd := InStr(Src, "*WheelDown::", 1, WheelUpStart + 1) + 50
	HotkeyBlock  := SubStr(Src, WheelUpStart, WheelDownEnd - WheelUpStart + 100)
	AssertFalse(
		InStr(HotkeyBlock, "A_MaxHotkeysPerInterval"),
		"A_MaxHotkeysPerInterval must not appear inside the *WheelUp/*WheelDown hotkey bodies"
	)
}
Test("Audit-v4: A_MaxHotkeysPerInterval set at load time, not inside hotkey bodies", TestAuditV4_MaxHotkeysNotInHotkey)


; ==============================================================
; ===== 3) CallbackCreate pointer stored; CallbackFree called
; ==============================================================

TestAuditV4_CallbackFree() {
	; Callback creation stays in init while the ownership-aware release helper
	; lives in window_cycle. The behavioral ahk-126 test pins native refusal;
	; this legacy source ratchet only prevents the original thunk leak returning.
	Src := _DriverDirConcat("modules/gestures")
	ReleaseBody := _DriverFuncBody("_GestureReleaseWinHook")
	UnhookBody := _DriverFuncBody("_GestureUnhook")

	; The bug: CallbackCreate returned directly to SetWinEventHook with no store;
	; _GestureUnhook only called UnhookWinEvent, leaking the thunk.
	; The fix: store in _GestureCallbackPtr and retire it through the shared
	; helper only after its native hook has been detached.
	AssertTrue(
		InStr(Src, "_GestureCallbackPtr"),
		"gestures.ahk must store CallbackCreate result in _GestureCallbackPtr"
	)
	AssertTrue(ReleaseBody != "" && InStr(ReleaseBody, "FreeFn.Call(CallbackPtr)"),
		"gesture WinEvent teardown must release the retained callback thunk")
	AssertTrue(UnhookBody != "" && InStr(UnhookBody, "_GestureReleaseWinHook()"),
		"_GestureUnhook must delegate native ownership retirement to the shared helper")
}
Test("Audit-v4: CallbackCreate pointer stored and retired by gesture teardown", TestAuditV4_CallbackFree)


; ===================================================
; ===== 4) GR_DrawBitmap uses try/finally for GDI
; ===================================================

TestAuditV4_GrDrawBitmapFinally() {
	Src := _AuditV4_ReadSrc("adapters\graphics_renderer.ahk")

	; The bug: if an AHK exception escaped after SelectObject but before the
	; manual cleanup calls, MemDC/HBmp/ScreenDC were never released.
	; The fix: wrap the paint+upload block in try { } finally { cleanup }.
	AssertTrue(
		InStr(Src, "} finally {"),
		"GR_DrawBitmap must use a try/finally block to guarantee GDI cleanup"
	)
	; Ensure cleanup calls are inside the finally, not duplicated outside
	FinallyStart := InStr(Src, "} finally {")
	FinallyBlock := SubStr(Src, FinallyStart, 300)
	AssertTrue(
		InStr(FinallyBlock, "DeleteObject") and InStr(FinallyBlock, "DeleteDC") and InStr(FinallyBlock, "ReleaseDC"),
		"The finally block must contain DeleteObject, DeleteDC and ReleaseDC"
	)
}
Test("Audit-v4: GR_DrawBitmap GDI cleanup guaranteed by try/finally", TestAuditV4_GrDrawBitmapFinally)


; =============================================================
; ===== 5) SaveFullConfig reschedules when !_DriverReady
; =============================================================

TestAuditV4_SaveFullConfigReschedule() {
	Src := _DriverSourceConcat()

	; The bug: boot timer is one-shot (-500 ms); if SaveFullConfig runs before
	; _DriverReady is set, it returns immediately, silently dropping the save.
	; The fix: preserve a generation and arm the coalesced deferred wrapper.
	GuardPos := InStr(Src, "if !_DriverReady")
	AssertTrue(GuardPos > 0, "SaveFullConfig must guard on !_DriverReady")

	; Verify the durable coordinator owns the wake-up inside the guard block.
	GuardBlock := SubStr(Src, GuardPos, 400)
	AssertTrue(
		InStr(GuardBlock, "_ConfigArmFullSaveRetry("),
		"SaveFullConfig must reschedule itself when !_DriverReady — one-shot timer is not re-fired otherwise"
	)
}
Test("Audit-v4: SaveFullConfig reschedules when _DriverReady is not yet set", TestAuditV4_SaveFullConfigReschedule)
