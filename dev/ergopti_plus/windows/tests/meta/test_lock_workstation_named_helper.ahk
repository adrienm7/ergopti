; tests/meta/test_lock_workstation_named_helper.ahk

; ==============================================================================
; MODULE: Win+L LockWorkstation Named-Helper Meta Test
; DESCRIPTION:
; Static source guard for finding "lock-workstation-lambda-implicit-concat".
;
; The Win+L (remapped L) hotkey originally used an arrow body that relied on
; implicit string concatenation to run two statements:
;     (*) => DllCall("LockWorkStation") UpdateLastSentCharacter(Character)
; The two side effects happen to fire, but the intent (sequence two statements)
; is not expressed, and a refactor "simplifying" the dead concatenation could
; silently drop one call. It also bypassed the Critical-serialised emit path.
;
; The fix replaces the arrow with a named _LockWorkstationEmit helper whose body
; lists DllCall("LockWorkStation") on its own explicit line under Critical("On").
; This is a meta-static test because layout.ahk registers top-level hotkeys and
; cannot be #Included by the headless runner; it scans source text so a
; regression that re-introduces the implicit-concat arrow fails the suite.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_LWNH_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ==================================================
; ==================================================
; ======= 2/ Named-helper assertions ===============
; ==================================================
; ==================================================

_LWNH_AssertNamedHelperExists() {
	Src := _LWNH_ReadSource("modules/keymap/layout.ahk")
	Body := _DriverFuncBody("_LockWorkstationEmit")
	Assert(Body != "", "layout.ahk must define a named _LockWorkstationEmit helper instead of an inline arrow (lock-workstation-lambda-implicit-concat)")
	Assert(InStr(Body, "LockWorkStation") > 0,
		"_LockWorkstationEmit must call DllCall(LockWorkStation) on an explicit line (lock-workstation-lambda-implicit-concat)")
}
Test("layout: Win+L lock uses a named _LockWorkstationEmit helper (lock-workstation-lambda-implicit-concat)", _LWNH_AssertNamedHelperExists)

_LWNH_AssertNoImplicitConcatArrow() {
	Src := _LWNH_ReadSource("modules/keymap/layout.ahk")
	; The original implicit-concat arrow placed the two calls back-to-back on one
	; expression. Guard against its return: DllCall(LockWorkStation) must never be
	; immediately followed by UpdateLastSentCharacter on the same line.
	Assert(!InStr(Src, ") UpdateLastSentCharacter(Character)"),
		"the Win+L handler must not rely on implicit concatenation of DllCall + UpdateLastSentCharacter (lock-workstation-lambda-implicit-concat)")
}
Test("layout: Win+L lock no longer uses an implicit-concat arrow body (lock-workstation-lambda-implicit-concat)", _LWNH_AssertNoImplicitConcatArrow)
