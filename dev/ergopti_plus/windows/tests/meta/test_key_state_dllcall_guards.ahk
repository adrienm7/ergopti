; tests/unit/test_key_state_dllcall_guards.ahk

; ==============================================================================
; MODULE: KeyState DllCall Fail-Safe Guard Tests
; DESCRIPTION:
; KS_ResolveKeyboardLayout, KS_ProbeRightAltScancode, and KS_ScanScancodeForChar
; had no try/catch around their Win32 DllCall probes, unlike this file's own
; documented FAIL-SAFE contract (KS_IsDown/KS_IsUp: "An unknown key name or
; any AHK error yields 0/1, never propagates"). Called unguarded at boot
; (ErgoptiPlus.ahk), an exception here would abort the entire boot sequence.
;
; These probes are read-only Win32 keyboard-layout queries (no OS mutation,
; no network/installer/browser side effects), so they are exercised directly.
; ==============================================================================

#Requires AutoHotkey v2.0




; =========================================================
; =========================================================
; ======= 1/ Real calls do not throw ========================
; =========================================================
; =========================================================

TestKeyState_ResolveKeyboardLayoutDoesNotThrow() {
	Threw := false
	Hkl := 0
	try {
		Hkl := KS_ResolveKeyboardLayout()
	} catch {
		Threw := true
	}
	AssertFalse(Threw, "KS_ResolveKeyboardLayout must not throw on a real call")
	AssertTrue(Hkl is Integer, "KS_ResolveKeyboardLayout must return an integer HKL (or 0)")
}
Test("key_state: KS_ResolveKeyboardLayout does not throw (key-state-dllcall-uncaught)", TestKeyState_ResolveKeyboardLayoutDoesNotThrow)

TestKeyState_ProbeRightAltScancodeDoesNotThrow() {
	Hkl := KS_ResolveKeyboardLayout()
	Threw := false
	Sc := 0
	try {
		Sc := KS_ProbeRightAltScancode(Hkl)
	} catch {
		Threw := true
	}
	AssertFalse(Threw, "KS_ProbeRightAltScancode must not throw on a real HKL")
	AssertTrue(Sc is Integer, "KS_ProbeRightAltScancode must return an integer scancode (or 0)")
}
Test("key_state: KS_ProbeRightAltScancode does not throw (key-state-dllcall-uncaught)", TestKeyState_ProbeRightAltScancodeDoesNotThrow)

TestKeyState_ProbeRightAltScancode_InvalidHklReturnsZero() {
	; An invalid/garbage HKL must not throw -- MapVirtualKeyExW simply returns 0.
	Threw := false
	Sc := -1
	try {
		Sc := KS_ProbeRightAltScancode(0xDEADBEEF)
	} catch {
		Threw := true
	}
	AssertFalse(Threw, "KS_ProbeRightAltScancode must not throw on an invalid HKL")
	AssertEqual(0, Sc, "KS_ProbeRightAltScancode must return 0 for an invalid HKL")
}
Test("key_state: KS_ProbeRightAltScancode degrades to 0 on an invalid HKL (key-state-dllcall-uncaught)",
	TestKeyState_ProbeRightAltScancode_InvalidHklReturnsZero)

TestKeyState_ScanScancodeForCharDoesNotThrow() {
	Hkl := KS_ResolveKeyboardLayout()
	Threw := false
	Result := 0
	try {
		Result := KS_ScanScancodeForChar(Hkl, "a")
	} catch {
		Threw := true
	}
	AssertFalse(Threw, "KS_ScanScancodeForChar must not throw on a real HKL")
	AssertTrue(Result is Map, "KS_ScanScancodeForChar must return a Map")
	AssertTrue(Result.Has("scan") and Result.Has("vk"), "KS_ScanScancodeForChar's Map must have scan and vk keys")
}
Test("key_state: KS_ScanScancodeForChar does not throw (key-state-dllcall-uncaught)", TestKeyState_ScanScancodeForCharDoesNotThrow)




; =========================================================
; =========================================================
; ======= 2/ Each function has its own try/catch ============
; =========================================================
; =========================================================

_KSDG_CheckFunctionHasCatch(FuncName) {
	Body := _DriverFuncBody(FuncName)
	Assert(Body != "", FuncName . " must exist in adapters/key_state.ahk")
	Assert(InStr(Body, "try {") > 0 or InStr(Body, "try{") > 0,
		FuncName . " must wrap its DllCall probes in try, matching this file's own documented FAIL-SAFE contract for KS_IsDown/KS_IsUp")
	Assert(InStr(Body, "catch") > 0,
		FuncName . " must have a catch clause so an unguarded DllCall failure at boot does not abort the entire boot sequence")
}

Test("key_state: KS_ResolveKeyboardLayout has a try/catch (key-state-dllcall-uncaught)",
	() => _KSDG_CheckFunctionHasCatch("KS_ResolveKeyboardLayout"))
Test("key_state: KS_ProbeRightAltScancode has a try/catch (key-state-dllcall-uncaught)",
	() => _KSDG_CheckFunctionHasCatch("KS_ProbeRightAltScancode"))
Test("key_state: KS_ScanScancodeForChar has a try/catch (key-state-dllcall-uncaught)",
	() => _KSDG_CheckFunctionHasCatch("KS_ScanScancodeForChar"))
