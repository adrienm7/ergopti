; tests/unit/test_key_state_dllcall_guards.ahk

; ==============================================================================
; MODULE: KeyState DllCall Fail-Safe Guard Tests
; DESCRIPTION:
; KS_ResolveKeyboardLayout and KS_ScanScancodeForChar had no try/catch around their Win32 DllCall probes, unlike this file's own
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

TestKeyState_ProbeAltGrLayoutDoesNotThrow() {
	Hkl := KS_ResolveKeyboardLayout()
	Threw := false
	Probe := 0
	try {
		Probe := KS_ProbeAltGrLayout(Hkl)
	} catch {
		Threw := true
	}
	AssertFalse(Threw, "KS_ProbeAltGrLayout must not throw on a real HKL")
	AssertTrue(Probe is Map and Probe["rmenu_sc"] is Integer and Probe["altgr_vk"] is Integer,
		"KS_ProbeAltGrLayout must return both probe results")
	AssertTrue(Probe["valid"], "the active layout must know its AltGr key one way or the other")
}
Test("key_state: KS_ProbeAltGrLayout does not throw on a real layout (key-state-dllcall-uncaught)", TestKeyState_ProbeAltGrLayoutDoesNotThrow)

; An invalid HKL answers 0 to both lookups. The reverse probe's 0 alone used to
; mean a Kana layout (altgr-probe-invalid-hkl-2026-09-26).
TestKeyState_ProbeAltGrLayout_InvalidHklIsNotKana() {
	Probe := KS_ProbeAltGrLayout(0xDEADBEEF)
	AssertFalse(Probe["valid"], "an invalid HKL must be reported as a layout the probe could not read")
	AssertFalse(Probe["kana"], "an invalid HKL must never be taken for a Kana layout")
}
Test("key_state: an invalid HKL is not taken for a Kana layout (altgr-probe-invalid-hkl-2026-09-26)",
	TestKeyState_ProbeAltGrLayout_InvalidHklIsNotKana)

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

; The space bar (SC039, VK_SPACE) types a space on every layout, so it pins the
; two label probes against the real OS without depending on the user's layout.
TestKeyState_KeyTextProbesReadTheSpaceBar() {
	Hkl := KS_ResolveKeyboardLayout()
	Vk := KS_ScancodeToVk(0x39, Hkl)
	AssertEqual(0x20, Vk, "KS_ScancodeToVk must map SC039 to VK_SPACE")
	Result := KS_KeyTextNoStateChange(Vk, 0x39, Hkl)
	AssertEqual(1, Result.Count, "KS_KeyTextNoStateChange must report one character for the space bar")
	AssertEqual(" ", Result.Text, "KS_KeyTextNoStateChange must read the space the space bar types")
}
Test("key_state: the label probes read the space bar (key-state-dllcall-uncaught)",
	TestKeyState_KeyTextProbesReadTheSpaceBar)




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
Test("key_state: KS_ScanScancodeForChar has a try/catch (key-state-dllcall-uncaught)",
	() => _KSDG_CheckFunctionHasCatch("KS_ScanScancodeForChar"))
Test("key_state: KS_ScancodeToVk has a try/catch (key-state-dllcall-uncaught)",
	() => _KSDG_CheckFunctionHasCatch("KS_ScancodeToVk"))
Test("key_state: KS_KeyTextNoStateChange has a try/catch (key-state-dllcall-uncaught)",
	() => _KSDG_CheckFunctionHasCatch("KS_KeyTextNoStateChange"))
