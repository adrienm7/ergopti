; tests/meta/test_capsword_reset_on_suspend.ahk

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
; This test asserts:
;   1. Ergopti_OnSuspendEnter calls DisableCapsWord() (with IsSet guard).
;   2. DisableCapsWord resets CapsWordEnabled to False.
;   3. DisableCapsWord calls HookDispatcher.Unregister for the mouse-down events.
;   4. DisableCapsWord calls UpdateCapsLockLED to sync the physical LED.
;
; SCOPE: source introspection of lib/lifecycle.ahk and modules/shortcuts/capsword.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Source scan helpers =====================
; ====================================================
; ====================================================

_CWRS_ReadLifecycleSrc() {
	return _DriverDirConcat("lib")
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
	Assert(Src != "", "lib/ source must be readable")

	Body := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(Body != "", "Ergopti_OnSuspendEnter must be defined in lib/lifecycle.ahk")

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


_CWRS_DisableCapsWordResetsCapsWordEnabled() {
	Src := _CWRS_ReadCapswordSrc()
	Assert(Src != "", "modules/shortcuts/ source must be readable")

	Body := _DriverFuncBody("DisableCapsWord")
	Assert(Body != "", "DisableCapsWord must be defined in modules/shortcuts/capsword.ahk")

	Assert(InStr(Body, "CapsWordEnabled") > 0 and InStr(Body, "False") > 0,
		"DisableCapsWord must set CapsWordEnabled to False — the global flag that HotIf predicates read to decide whether to pass CapsWord keystrokes (AHK-16)")
}

Test("capsword: DisableCapsWord resets CapsWordEnabled to False (capsword-reset-on-suspend)",
	_CWRS_DisableCapsWordResetsCapsWordEnabled)


_CWRS_DisableCapsWordUnregistersMouseListeners() {
	Body := _DriverFuncBody("DisableCapsWord")
	Assert(Body != "", "DisableCapsWord must be defined — prerequisite for this test")

	Assert(InStr(Body, "HookDispatcher.Unregister") > 0,
		"DisableCapsWord must call HookDispatcher.Unregister to remove the mouse-click listeners — listeners that are not unregistered keep firing through Suspend and prevent other HookDispatcher subscribers from receiving the events cleanly (AHK-16)")
}

Test("capsword: DisableCapsWord unregisters mouse-down listeners via HookDispatcher (capsword-reset-on-suspend)",
	_CWRS_DisableCapsWordUnregistersMouseListeners)


_CWRS_DisableCapsWordUpdatesLED() {
	Body := _DriverFuncBody("DisableCapsWord")
	Assert(Body != "", "DisableCapsWord must be defined — prerequisite for this test")

	Assert(InStr(Body, "UpdateCapsLockLED") > 0,
		"DisableCapsWord must call UpdateCapsLockLED() — without this the hardware CapsLock LED stays lit while the driver is suspended, falsely signalling that CapsLock is active (AHK-16)")
}

Test("capsword: DisableCapsWord calls UpdateCapsLockLED to correct the hardware LED (capsword-reset-on-suspend)",
	_CWRS_DisableCapsWordUpdatesLED)
