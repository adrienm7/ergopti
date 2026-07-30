; tests/meta/test_file_headers.ahk

; ==============================================================================
; MODULE: File Header Invariant Test
; DESCRIPTION:
; Ensures every AHK source file under the AutoHotkey driver starts with a
; comment line containing its own relative path, as required by the project
; coding conventions documented in copilot-instructions.md.
;
; FAILURE POLICY:
; - Hard fail: an AHK file's first non-blank line is not a comment.
; - Warning : the declared path doesn't exactly match the file's actual path.
;   Reported via OutputDebug but doesn't fail the suite.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ File listing helper =======
; ======================================
; ======================================

_MetaListAhkFiles(Dir) {
	Files := []
	TempFile := A_Temp . "\meta_dir_list.txt"
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

_MetaRunFileHeaderTests() {
	; A_ScriptDir is set by run_all.ahk → tests/ (absolute, no ..)
	; SplitPath strips the last component to reach autohotkey/
	SplitPath(A_ScriptDir, , &_DriverRootRaw)
	DriverRoot := StrReplace(_DriverRootRaw, "\", "/") . "/"
	SrcDirs := ["lib", "modules", "ui"]
	Checked := 0
	Mismatches := 0

	for Sub in SrcDirs {
		for AbsPath in _MetaListAhkFiles(StrReplace(DriverRoot . Sub, "/", "\")) {
			FileName := RegExReplace(AbsPath, ".*[/\\]")
			AbsCopy := AbsPath
			_MetaCheckFileHeader() {
				Checked++
				try {
					Raw := FileRead(AbsCopy)
				} catch {
					Assert(false, "cannot read " . AbsCopy)
					return
				}
				; Strip UTF-8 BOM if present
				if SubStr(Raw, 1, 3) = Chr(0xEF) . Chr(0xBB) . Chr(0xBF) {
					Raw := SubStr(Raw, 4)
				}
				Lines := StrSplit(Raw, "`n", "`r")
				First := Lines.Length > 0 ? Trim(Lines[1]) : ""
				; First line must be an AHK comment
				Assert(SubStr(First, 1, 1) = ";", "first line is not an AHK comment: " . First)
				; Path should appear in the comment (warning-only)
				; Derive relative path from driver root
				NormAbs := StrReplace(AbsCopy, "\", "/")
				NormRoot := StrReplace(DriverRoot, "\", "/")
				Rel := SubStr(NormAbs, StrLen(NormRoot) + 1)
				if not InStr(First, Rel) {
					Mismatches++
					OutputDebug("WARN: header in " . Rel . " does not name itself: " . First)
				}
			}
			Test("file header: " . FileName, _MetaCheckFileHeader)
		}
	}

	_MetaFileHeadersAtLeastOne() {
		Assert(Checked > 0, "no AHK source files were located — check SrcDirs")
	}
	Test("meta file headers: at least one file checked", _MetaFileHeadersAtLeastOne)
}

_MetaRunFileHeaderTests()
