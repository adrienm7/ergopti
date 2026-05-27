; tests/meta/test_no_duplicate_defaults.ahk

; ==============================================================================
; MODULE: Duplicate Defaults Test
; DESCRIPTION:
; Heuristic scan for the same constant value being declared under the same
; name in two different AHK modules — a smell that violates the "single source
; of truth" rule (conventions section 5.2). Reports findings as warnings rather
; than failures because some duplicates (e.g., 0/1/true) are legitimate.
;
; The whitelist skips well-known trivial values that appear in many files by
; design and carry no semantic duplication risk.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; ======================================
; ======= 1/ File listing helper =======
; ======================================
; =====================================

_MetaListAhkFilesDups(Dir) {
	Files := []
	TempFile := A_Temp . "\meta_dir_dups.txt"
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

_MetaRunDuplicateDefaultsTests() {
	SplitPath(A_ScriptDir, , &_DriverRootRaw)
	DriverRoot := StrReplace(_DriverRootRaw, "\", "/") . "/"
	; Trivial values that are always whitelisted
	Whitelist := Map(
		"0", true, "1", true, "true", true, "false", true,
		"`"`"", true, "300", true, "100", true, "50", true
	)

	; Map of "name=value" -> array of relative file paths
	Seen := Map()

	for Sub in ["lib", "modules"] {
		for AbsPath in _MetaListAhkFilesDups(StrReplace(DriverRoot . Sub, "/", "\")) {
			try {
				Body := FileRead(StrReplace(AbsPath, "/", "\"))
			} catch {
				continue
			}
			NormRoot := StrReplace(DriverRoot, "\", "/")
			Rel := SubStr(StrReplace(AbsPath, "\", "/"), StrLen(NormRoot) + 1)

			; Scan for global constant declarations: `global NAME := VALUE`
			Pos := 1
			while RegExMatch(Body, "global\s+(\w+)\s*:=\s*([^\r\n;]+)", &M, Pos) {
				VarName := Trim(M[1])
				VarVal  := Trim(M[2])
				if not Whitelist.Has(VarVal) {
					Key := VarName . "=" . VarVal
					if not Seen.Has(Key) {
						Seen[Key] := []
					}
					AlreadyThere := false
					for F in Seen[Key] {
						if F = Rel {
							AlreadyThere := true
							break
						}
					}
					if not AlreadyThere {
						Seen[Key].Push(Rel)
					}
				}
				Pos := M.Pos + StrLen(M[0])
				if Pos <= 1 {
					break
				}
			}
		}
	}

	DupCount := 0
	for Key, Files in Seen {
		if Files.Length > 1 {
			DupCount++
			FileList := ""
			for F in Files {
				FileList .= F . ", "
			}
			OutputDebug("WARN: constant " . Key . " declared in: " . SubStr(FileList, 1, -2))
		}
	}

	_MetaDuplicateDefaultsResult() {
	}
	Test("meta duplicate defaults: scan complete (" . DupCount . " duplicates)", _MetaDuplicateDefaultsResult)
}

_MetaRunDuplicateDefaultsTests()
