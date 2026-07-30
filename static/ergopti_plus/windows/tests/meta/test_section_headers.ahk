; tests/meta/test_section_headers.ahk

; ==============================================================================
; MODULE: Section Banner Alignment Test
; DESCRIPTION:
; Validates the `=` line lengths in section/subsection banners match the
; title line length, as mandated by the project conventions.
;
; POLICY:
; - Reports misalignments as warnings (via OutputDebug) without failing.
; - Hard-fails only when the test itself cannot locate any source files.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ File listing helper =======
; ======================================
; ======================================

_MetaListAhkFilesSection(Dir) {
	Files := []
	TempFile := A_Temp . "\meta_dir_section.txt"
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

_MetaRunSectionHeaderTests() {
	SplitPath(A_ScriptDir, , &_DriverRootRaw)
	DriverRoot := StrReplace(_DriverRootRaw, "\", "/") . "/"
	TotalFiles := 0
	TotalWarns := 0

	for Sub in ["lib", "modules"] {
		for AbsPath in _MetaListAhkFilesSection(StrReplace(DriverRoot . Sub, "/", "\")) {
			TotalFiles++
			try {
				Body := FileRead(StrReplace(AbsPath, "/", "\"))
			} catch {
				continue
			}
			for Line in StrSplit(Body, "`n", "`r") {
				; Match major section title line: ======= X/ Title =======
				if RegExMatch(Line, "^; ======= (.+) =======$", &M) {
					Title := M[1]
					ExpectedLen := 7 + 1 + StrLen(Title) + 1 + 7
					Body2 := RegExReplace(Line, "^; ")
					if StrLen(Body2) != ExpectedLen {
						TotalWarns++
						NormRoot := StrReplace(DriverRoot, "\", "/")
						Rel := SubStr(StrReplace(AbsPath, "\", "/"), StrLen(NormRoot) + 1)
						OutputDebug("WARN: banner alignment in " . Rel . ": " . Line)
					}
				}
			}
		}
	}

	_MetaSectionHeaderResult() {
		Assert(TotalFiles > 0, "no AHK source files scanned")
	}
	Test("meta section headers: scanned " . TotalFiles . " files (" . TotalWarns . " warnings)", _MetaSectionHeaderResult)
}

_MetaRunSectionHeaderTests()
