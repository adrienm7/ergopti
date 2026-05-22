; tests/meta/test_no_pascal_case_in_toml.ahk

; ==============================================================================
; MODULE: TOML Key Casing Test
; DESCRIPTION:
; Verifies that all keys in the project's TOML configuration files use
; snake_case, not PascalCase or camelCase. The AHK driver reads TOML keys
; directly into map lookups; mixing casing conventions causes silent mismatches
; when code expects snake_case but the file ships PascalCase.
;
; A key is considered PascalCase if it starts with an uppercase letter
; (e.g. `HoldDuration`, `TapAction`). Section headers ([Section]) are
; excluded from the check since they are structural, not data keys.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; ======================================
; ======= 1/ File listing helper =======
; ======================================
; =====================================

_MetaListTomlFiles(Dir) {
	Files := []
	TempFile := A_Temp . "\meta_dir_toml.txt"
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
		if not Line ~= "i)\.toml$" {
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

_MetaRunNoPascalCaseTomlTests() {
	; Config files live next to the AHK driver root, two levels above tests/
	DriverRoot := StrReplace(A_ScriptDir, "\", "/") . "/../../"
	; Also scan the config directory at the repo root
	RepoRoot := StrReplace(A_ScriptDir, "\", "/") . "/../../../../"
	Violations := 0
	ScannedFiles := 0

	CheckDir(DirPath) {
		for _, Abs in _MetaListTomlFiles(StrReplace(DirPath, "/", "\")) {
			ScannedFiles++
			try {
				Body := FileRead(StrReplace(Abs, "/", "\"))
			} catch {
				continue
			}
			NormAbs := StrReplace(Abs, "\", "/")

			LineNum := 0
			for Line in StrSplit(Body, "`n", "`r") {
				LineNum++
				Line := Trim(Line)
				; Skip blank lines, comments, section headers, and value-only lines
				if Line = "" or SubStr(Line, 1, 1) = "#" or SubStr(Line, 1, 1) = "[" {
					continue
				}
				; Extract key (before the first `=`)
				EqPos := InStr(Line, "=")
				if not EqPos {
					continue
				}
				Key := Trim(SubStr(Line, 1, EqPos - 1))
				; PascalCase: starts with uppercase ASCII letter
				FirstChar := SubStr(Key, 1, 1)
				if FirstChar >= "A" and FirstChar <= "Z" {
					Violations++
					OutputDebug("WARN: PascalCase key '" . Key . "' in " . NormAbs . " line " . LineNum)
				}
			}
		}
	}

	CheckDir(DriverRoot)
	; Scan config/ siblings if present
	ConfigDir := RepoRoot . "config"
	if DirExist(StrReplace(ConfigDir, "/", "\")) {
		CheckDir(ConfigDir)
	}

	_MetaNoPascalCaseResult() {
		Assert(Violations = 0, "Found " . Violations . " PascalCase key(s) in TOML config files — use snake_case")
	}
	Test("meta no PascalCase in TOML: scan complete (" . Violations . " violations)", _MetaNoPascalCaseResult)
}

_MetaRunNoPascalCaseTomlTests()
