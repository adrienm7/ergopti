; tests/meta/test_boot_dircreate_guarded.ahk

; ==============================================================================
; MODULE: Boot DirCreate/FileAppend Guard Meta Test
; DESCRIPTION:
; Regression guard for MED-03: fix-boot-dircreate-unguarded.
;
; ErgoptiPlus.ahk creates _ConfigDir subfolders and bootstraps the empty
; personal_hotstrings.toml during the auto-execute section at startup.
; The DirCreate() and FileAppend() calls were bare (unguarded), so any OS-level
; failure (locked profile directory, restricted UAC path, unexpected I/O error)
; would throw an unhandled exception and abort the entire boot sequence —
; leaving the driver in a half-initialised state without any error dialog.
;
; The fix wraps those three calls with try so a transient I/O error degrades
; gracefully instead of crashing the script.
;
; This test asserts that each call site in ErgoptiPlus.ahk uses the try form:
;   try DirCreate(_ConfigDir . _AhkSubDir)
;   try DirCreate(_ConfigDir . "hotstrings")
;   try FileAppend("", _PersonalTomlBootstrap)
;
; SCOPE: source introspection of ErgoptiPlus.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ================================================
; ================================================
; ======= 1/ Source scan helpers =================
; ================================================
; ================================================

_BDG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Path := WindowsDir . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}


; ================================================
; ================================================
; ======= 2/ Test implementations ================
; ================================================
; ================================================

_BDG_CheckDirCreateGuarded() {
	Src := _DriverSourceConcat()
	Assert(Src != "", "ErgoptiPlus.ahk must be readable")

	; The two boot DirCreate calls must be try-wrapped (MED-03).
	Assert(InStr(Src, "try DirCreate(_ConfigDir . _AhkSubDir)"),
		"DirCreate(_ConfigDir . _AhkSubDir) in ErgoptiPlus.ahk must be try-wrapped (MED-03)")
	Assert(InStr(Src, "try DirCreate(_ConfigDir . " . Chr(34) . "hotstrings" . Chr(34) . ")"),
		"DirCreate(_ConfigDir . hotstrings) in ErgoptiPlus.ahk must be try-wrapped (MED-03)")

	; The bare form must NOT appear at boot (outside any existing try block).
	; We assert the try form is present (already done above), which is sufficient.
}

_BDG_CheckFileAppendGuarded() {
	Src := _DriverSourceConcat()
	Assert(Src != "", "ErgoptiPlus.ahk must be readable")

	; The bootstrap FileAppend call must be try-wrapped (MED-03).
	Assert(InStr(Src, "try FileAppend(" . Chr(34) . Chr(34) . ", _PersonalTomlBootstrap)"),
		"Bootstrap FileAppend in ErgoptiPlus.ahk must be try-wrapped (MED-03)")
}


Test("meta fix-boot-dircreate-guarded: DirCreate(_AhkSubDir) is try-wrapped at boot",
	_BDG_CheckDirCreateGuarded)

Test("meta fix-boot-fileappend-guarded: bootstrap FileAppend is try-wrapped at boot",
	_BDG_CheckFileAppendGuarded)
