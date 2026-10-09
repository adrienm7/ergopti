; tests/meta/test_processentry32w_size.ahk

; ==============================================================================
; MODULE: PROCESSENTRY32W Size Regression Test
; DESCRIPTION:
; Static source guard and behavioral verification for the F09 fix — ensures
; _KL_AV_FindCaptureExeSnapshot uses the correct 568-byte struct size for
; PROCESSENTRY32W on x64 instead of the wrong 560-byte value that caused
; Process32FirstW to return ERROR_BAD_LENGTH (24) on every call, permanently
; disabling screen-recording detection.
; ==============================================================================

#Requires AutoHotkey v2.0

_PE32_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_PE32_SourceScanCheck() {
	Src := _PE32_ReadSource("modules/keylogger/keylogger_av_state.ahk")
	Assert(Src != "", "Source file keylogger_av_state.ahk must exist")

	Body := _DriverFuncBody("_KL_AV_FindCaptureExeSnapshot")
	Assert(Body != "", "_KL_AV_FindCaptureExeSnapshot must exist in keylogger_av_state.ahk")

	; Regression guard: the old wrong size must no longer appear anywhere in the function body
	Assert(!InStr(Body, "Buffer(560"), "Body must NOT contain Buffer(560 — old wrong PROCESSENTRY32W size (use PE32_SIZE constant instead)")

	; The named constant must be used for both allocation and dwSize initialisation
	Assert(InStr(Body, "PE32_SIZE") > 0, "Body must reference PE32_SIZE named constant")

	; The correct numeric value must be present (either in the constant definition or a comment)
	Assert(InStr(Body, "568") > 0, "Body must contain 568 — the correct sizeof(PROCESSENTRY32W) on x64")

	; Fail-loud guard: an else branch logging the Process32FirstW failure must exist
	Assert(InStr(Body, "Process32FirstW failed") > 0, "Body must log a warning when Process32FirstW fails")
}

_PE32_SizeIsCorrectForX64() {
	; PROCESSENTRY32W layout on x64:
	; dwSize(0-4)+cntUsage(4-8)+th32ProcessID(8-12)+[4 pad](12-16)+
	; th32DefaultHeapID(16-24)+th32ModuleID(24-28)+cntThreads(28-32)+
	; th32ParentProcessID(32-36)+pcPriClassBase(36-40)+dwFlags(40-44)+
	; szExeFile[260]*2=520(44-564) rounded up to 568 for 8-byte alignment.
	; AssertEqual(568, 568) compared a literal to itself. The value that matters is
	; the CONSTANT the driver actually passes to Process32FirstW — if that drifts,
	; the call fails with ERROR_BAD_LENGTH and process enumeration returns nothing,
	; which the keylogger reports as "no AV running".
	; PE32_SIZE is function-local, so its VALUE has to be read from the source.
	Body := _DriverFuncBody("_KL_AV_FindCaptureExeSnapshot")
	AssertTrue(RegExMatch(Body, "PE32_SIZE[ 	]*:=[ 	]*568"),
		"PROCESSENTRY32W size on x64 must be 568 — a wrong dwSize makes Process32FirstW "
		. "fail with ERROR_BAD_LENGTH, enumeration returns nothing, and the keylogger "
		. "reports that as no AV running")
	; On x86 the correct size is 556, so the constant is only right for 64-bit.
	; Assert the assumption rather than restate it: the whole suite runs 64-bit.
	AssertEqual(8, A_PtrSize,
		"this constant is the x64 layout — on a 32-bit host PE32_SIZE would have to be 556")
}

Test("keylogger_av_state: PROCESSENTRY32W dwSize must use PE32_SIZE=568 constant (not hardcoded 560)", _PE32_SourceScanCheck)
Test("keylogger_av_state: PROCESSENTRY32W dwSize must be 568 on x64", _PE32_SizeIsCorrectForX64)
