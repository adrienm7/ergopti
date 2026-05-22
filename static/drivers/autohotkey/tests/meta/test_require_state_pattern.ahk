; tests/meta/test_require_state_pattern.ahk

; ==============================================================================
; MODULE: Guard Pattern Test
; DESCRIPTION:
; AHK modules that declare a module-level guard variable (e.g. a global flag
; or state Map initialised at startup) should define a corresponding guard
; check before every public function that relies on that state, in line with
; convention section 5.3 (fail fast, no silent failures).
;
; This test is a heuristic warning scan. It flags modules that declare
; a `global` initialisation Map/flag at top level but never reference any
; guard pattern (`if not` or early-return check). Findings are reported
; via OutputDebug without failing the suite.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; ======================================
; ======= 1/ File listing helper =======
; ======================================
; =====================================

_MetaListAhkFilesGuard(Dir) {
	Files := []
	TempFile := A_Temp . "\meta_dir_guard.txt"
	try FileDelete(TempFile)
	RunWait('cmd /c dir /b /s /a-d "' . Dir . '" > "' . TempFile . '"', , "Hide")
	try {
		Raw := FileRead(TempFile)
	} catch {
		return Files
	}
	for Line in StrSplit(Raw, "`n", "`r") {
		Line := Trim(Line)
		if Line = "" {
			continue
		}
		Line := StrReplace(Line, "\", "/")
		if not Line ~= "i)\.ahk$" {
			continue
		}
		if Line ~= "i)/tests/" {
			continue
		}
		Files.Push(Line)
	}
	return Files
}





; =====================================
; =====================================
; ======= 2/ Test registrations =======
; =====================================
; =====================================

_MetaRunRequireStateTests() {
	DriverRoot := StrReplace(A_ScriptDir, "\", "/") . "/../../"
	Missing := 0

	for _, Abs in _MetaListAhkFilesGuard(StrReplace(DriverRoot . "modules", "/", "\")) {
		try {
			Body := FileRead(StrReplace(Abs, "/", "\"))
		} catch {
			continue
		}
		NormRoot := StrReplace(DriverRoot, "\", "/")
		Rel := SubStr(StrReplace(Abs, "\", "/"), StrLen(NormRoot) + 1)

		; "Stateful" heuristic: file declares a global state Map at top level
		IsStateful := Body ~= "global\s+\w+State\s*:=" or Body ~= "global\s+\w+Enabled\s*:="
		if not IsStateful {
			continue
		}
		; Guard pattern: any use of "if not" checking a state variable or early return
		HasGuard := InStr(Body, "if not ") or InStr(Body, "if (!") or InStr(Body, "return")
		if not HasGuard {
			Missing++
			OutputDebug("WARN: " . Rel . " appears stateful but has no guard pattern")
		}
	}

	_MetaRequireStateResult() {
	}
	Test("meta require_state pattern: scan complete (" . Missing . " warnings)", _MetaRequireStateResult)
}

_MetaRunRequireStateTests()
