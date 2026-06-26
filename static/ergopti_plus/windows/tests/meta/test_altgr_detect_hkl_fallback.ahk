; tests/meta/test_altgr_detect_hkl_fallback.ahk

; ==============================================================================
; MODULE: AltGrDetect HKL Fallback Meta Test
; DESCRIPTION:
; Regression guard ensuring the AltGrDetect log block in ErgoptiPlus.ahk does
; not call GetForegroundKeyboardLayout() bare and use its return value directly
; as the HKL argument. At startup with no foreground window the function returns
; 0, causing MapVirtualKeyExW to use the wrong layout or fail silently.
;
; The fix: the AltGrDetect block must apply the same HKL cascade used by the
; magic-key scanner — fallback to GetKeyboardLayout(A_ThreadID), then to
; SystemParametersInfo(SPI_GETDEFAULTINPUTLANG).
;
; SCOPE: source introspection of ErgoptiPlus.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_AGHF_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Path := WindowsDir . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_AGHF_CheckNoDirectHKLArg() {
	Src := _DriverSourceConcat()
	Assert(Src != "", "ErgoptiPlus.ahk must be readable")

	; Detect the AltGrDetect log block by looking for its unique signature.
	; The block must NOT pass GetForegroundKeyboardLayout() directly as the HKL
	; argument to MapVirtualKeyExW — it must cache the resolved HKL first.
	; We check that MapVirtualKeyExW is never called with GetForegroundKeyboardLayout()
	; inline in the same expression.
	BadPattern := '"Ptr", GetForegroundKeyboardLayout()'
	Assert(!InStr(Src, BadPattern),
		"AltGrDetect block must not pass GetForegroundKeyboardLayout() directly to MapVirtualKeyExW — cache HKL with fallback first")
}

_AGHF_CheckHKLFallbackPresent() {
	Src := _DriverSourceConcat()
	Assert(Src != "", "ErgoptiPlus.ahk must be readable")

	; The block must resolve HKL into a variable and apply thread-layout fallback
	Assert(InStr(Src, "_DetectHKL"),
		"AltGrDetect block must cache the resolved HKL in _DetectHKL")
	Assert(InStr(Src, "GetKeyboardLayout") && InStr(Src, "GetCurrentThreadId"),
		"AltGrDetect block must include GetKeyboardLayout(GetCurrentThreadId()) as first HKL fallback")
}


Test("meta altgr-detect: does not pass GetForegroundKeyboardLayout() directly to MapVirtualKeyExW",
	_AGHF_CheckNoDirectHKLArg)

Test("meta altgr-detect: caches HKL in _DetectHKL with thread-layout fallback",
	_AGHF_CheckHKLFallbackPresent)