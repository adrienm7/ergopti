; tests/meta/test_no_class_global_conflict.ahk

; ==============================================================================
; MODULE: Class/Global Conflict Meta Test
; DESCRIPTION:
; Scans all production AHK source files for `global <Name>` declarations whose
; Name matches a `class <Name>` definition elsewhere in the codebase. In AHK
; v2, class names are globally accessible without a `global` declaration, so
; any `global ClassName` statement is redundant at best and causes a fatal
; startup crash (`This class declaration conflicts with an existing global
; variable`) at worst — exactly the defect that introduced this test.
;
; FEATURES & RATIONALE:
; 1. Regression guard: prevents the specific crash that was triggered by
;    `global Keylogger` in crash_reporter.ahk conflicting with the
;    `class Keylogger` definition in keylogger.ahk.
; 2. Codebase-wide: scans both infra/ and modules/ so new modules are covered
;    automatically without updating this file.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ File listing helper =======
; ======================================
; ======================================

_MetaListAhkFilesCC(Dir) {
	Files := []
	TempFile := A_Temp . "\meta_dir_cc.txt"
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
		if not Line ~= "i)\.ahk$" {
			continue
		}
		; Exclude test files — they may intentionally stub class names
		if Line ~= "i)\\tests\\" {
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

_MetaRunClassGlobalConflictTests() {
	SplitPath(A_ScriptDir, , &_DriverRootRaw)
	DriverRoot := StrReplace(_DriverRootRaw, "\", "/") . "/"

	; Pass 1 — collect all class names defined anywhere in infra/ and modules/
	ClassNames := Map()
	GlobalDecls := []   ; array of {name, file} objects

	for Sub in ["infra", "modules", "platform"] {
		for AbsPath in _MetaListAhkFilesCC(StrReplace(DriverRoot . Sub, "/", "\")) {
			try {
				Body := FileRead(StrReplace(AbsPath, "/", "\"))
			} catch {
				continue
			}
			NormRoot := StrReplace(DriverRoot, "\", "/")
			Rel := SubStr(StrReplace(AbsPath, "\", "/"), StrLen(NormRoot) + 1)

			; Strip full-line comments before scanning so that comment text
			; like "; declaring `global Keylogger` here …" or
			; "; … the class is not yet initialized" never produces false
			; positives in the class/global regex passes below.
			ScanBody := RegExReplace(Body, "m)^\s*;[^\n]*\n?", "")

			; Collect `class Name` definitions (at any indentation level)
			Pos := 1
			while RegExMatch(ScanBody, "i)\bclass\s+(\w+)\b", &M, Pos) {
				Name := M[1]
				if not ClassNames.Has(Name) {
					ClassNames[Name] := []
				}
				ClassNames[Name].Push(Rel)
				Pos := M.Pos + StrLen(M[0])
				if Pos <= 1 {
					break
				}
			}

			; Collect `global Name` declarations (standalone — not `global X := ...`)
			; We look for `global <Word>` NOT followed by `[` or `:=` (those are
			; variable assignments, not class-alias declarations).
			Pos := 1
			while RegExMatch(ScanBody, "i)\bglobal\s+(\w+)(?!\s*\[|\s*:=)", &M, Pos) {
				Decl := {name: M[1], file: Rel}
				GlobalDecls.Push(Decl)
				Pos := M.Pos + StrLen(M[0])
				if Pos <= 1 {
					break
				}
			}
		}
	}

	; Pass 2 — find every `global Name` where Name is also a class
	Conflicts := []
	for Decl in GlobalDecls {
		if ClassNames.Has(Decl.name) {
			Conflicts.Push(Decl)
		}
	}

	; Register one test per conflict found (each is a hard failure).
	; AssertEqual("", actual) is the canonical failure pattern in this suite —
	; a non-empty actual string means a violation was detected.
	if Conflicts.Length = 0 {
		; The clean case used to register an EMPTY body. It could not fail whether the
		; scan had examined every class in the driver or none at all — and "none at
		; all" is what a renamed token or a moved tree produces, which is exactly when
		; this guard is needed. Assert the scan saw the classes instead.
		_MetaNoConflict() {
			Assert(ClassNames.Count > 20,
				"the class scan found only " . ClassNames.Count . " class definition(s) across the "
				. "driver — it is looking for something that is no longer there, so finding no "
				. "conflicts proves nothing")
		}
		Test("meta class/global conflict: no conflicting `global ClassName` declarations found ("
			. ClassNames.Count . " classes scanned)", _MetaNoConflict)
	} else {
		for Conflict in Conflicts {
			; Capture loop variables for the closure
			_ConflictName  := Conflict.name
			_ConflictFile  := Conflict.file
			_ConflictFiles := ClassNames[Conflict.name]
			_MetaConflictFail() {
				FileList := ""
				for F in _ConflictFiles {
					FileList .= F . ", "
				}
				Msg := "global " . _ConflictName
					. " in " . _ConflictFile
					. " conflicts with class defined in: "
					. SubStr(FileList, 1, -2)
				; AssertEqual("", non-empty) fails with the conflict description as the diff
				AssertEqual("", Msg)
			}
			Test(
				"meta class/global conflict: `global " . Conflict.name . "` in " . Conflict.file,
				_MetaConflictFail
			)
		}
	}
}

_MetaRunClassGlobalConflictTests()
