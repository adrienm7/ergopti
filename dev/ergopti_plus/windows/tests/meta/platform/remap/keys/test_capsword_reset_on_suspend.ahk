; tests/meta/platform/remap/keys/test_capsword_reset_on_suspend.ahk

; ==============================================================================
; MODULE: CapsWord Reset on Suspend Meta Test
; DESCRIPTION:
; Regression guard for the AHK-16 CapsWord-on-suspend fix.
;
; Before the fix, CapsWord remained active across a driver suspend. This caused
; two visible problems:
;   1. The hardware CapsLock LED stayed lit while the driver was paused,
;      misleading the user into thinking CapsLock was active.
;   2. The mouse-cancel HookDispatcher listeners (EVT_MS_LDOWN / EVT_MS_RDOWN)
;      registered by CapsWord kept firing through native Suspend, because AHK
;      timer and hook callbacks bypass native Suspend.
;
; The fix calls DisableCapsWord() from Ergopti_OnSuspendEnter() so CapsWord is
; torn down at the start of every suspend: CapsWordEnabled is cleared, the mouse
; listeners are unregistered, and UpdateCapsLockLED() corrects the LED.
;
; This test asserts that Ergopti_OnSuspendEnter calls DisableCapsWord() with an IsSet
; guard. What DisableCapsWord then does (clears the flag, disarms the listeners,
; corrects the LED) is pinned by behaviour in
; unit/modules/shortcuts/test_capsword_state.ahk.
;
; SCOPE: source introspection of infra/lifecycle.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Source scan helpers =====================
; ====================================================
; ====================================================

_CWRS_ReadLifecycleSrc() {
	return _DriverDirConcat("infra")
}

_CWRS_ReadCapswordSrc() {
	return _DriverDirConcat("modules/shortcuts")
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_CWRS_SuspendEnterCallsDisableCapsWord() {
	Src := _CWRS_ReadLifecycleSrc()
	Assert(Src != "", "infra/ source must be readable")

	Body := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(Body != "", "Ergopti_OnSuspendEnter must be defined in infra/lifecycle.ahk")

	Assert(InStr(Body, "DisableCapsWord()") > 0,
		"Ergopti_OnSuspendEnter must call DisableCapsWord() — CapsWord must be deactivated on every suspend to correct the LED and unregister the mouse listeners that bypass native Suspend (AHK-16)")
}

Test("lifecycle: Ergopti_OnSuspendEnter calls DisableCapsWord (capsword-reset-on-suspend)",
	_CWRS_SuspendEnterCallsDisableCapsWord)


_CWRS_SuspendEnterIsSetGuardPresent() {
	Body := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(Body != "", "Ergopti_OnSuspendEnter must be defined — prerequisite for this test")

	; The call must be guarded by IsSet(DisableCapsWord) so the entry point does not
	; throw when CapsWord is not loaded (e.g. in stripped configs)
	Assert(InStr(Body, "IsSet(DisableCapsWord)") > 0,
		"Ergopti_OnSuspendEnter must guard the DisableCapsWord() call with IsSet(DisableCapsWord) — the function may not be present in all build configurations")
}

Test("lifecycle: DisableCapsWord call in suspend enter is IsSet-guarded (capsword-reset-on-suspend)",
	_CWRS_SuspendEnterIsSetGuardPresent)
