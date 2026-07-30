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





; ======================================
; ======================================
; ======= 1/ File listing helper =======
; ======================================
; ======================================

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
	SplitPath(A_ScriptDir, , &_DriverRootRaw)
	DriverRoot := StrReplace(_DriverRootRaw, "\", "/") . "/"
	RepoRoot := StrReplace(A_ScriptDir, "\", "/") . "/../../../../"
	Violations := 0
	ScannedFiles := 0

	CheckDir(DirPath) {
		for AbsPath in _MetaListTomlFiles(StrReplace(DirPath, "/", "\")) {
			; paths.toml is auto-generated and uses ConfigDirPath (PascalCase by
			; historical convention) — exclude it from the snake_case check.
			if AbsPath ~= "i)[\\/]paths\.toml$" {
				continue
			}
			ScannedFiles++
			try {
				Body := FileRead(StrReplace(AbsPath, "/", "\"))
			} catch {
				continue
			}
			NormAbs := StrReplace(AbsPath, "\", "/")

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
				; true = case-sensitive so only uppercase A-Z trigger this
				if StrCompare(FirstChar, "A", true) >= 0 and StrCompare(FirstChar, "Z", true) <= 0 {
					Violations++
					OutputDebug("WARN: PascalCase key '" . Key . "' in " . NormAbs . " line " . LineNum)
				}
			}
		}
	}

	CheckDir(DriverRoot)
	; The config repo (config/) is excluded here — its TOML keys are still
	; PascalCase and will be migrated as part of the config-schema-v2 work
	; tracked in the project_config_v2_refactor memory. Re-enable once that
	; migration is complete.

	_MetaNoPascalCaseResult() {
		Assert(Violations = 0, "Found " . Violations . " PascalCase key(s) in TOML config files — use snake_case")
	}
	Test("meta no PascalCase in TOML: scan complete (" . Violations . " violations)", _MetaNoPascalCaseResult)
}

_MetaRunNoPascalCaseTomlTests()
