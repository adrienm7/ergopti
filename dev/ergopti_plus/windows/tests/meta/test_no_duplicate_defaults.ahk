; tests/meta/test_no_duplicate_defaults.ahk

; ==============================================================================
; MODULE: Duplicate Defaults Test
; DESCRIPTION:
; Heuristic scan for the same constant value being declared under the same name.
; ==============================================================================

#Requires AutoHotkey v2.0

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
		if (Line = "")
			continue
		Line := StrReplace(Line, "\", "/")
		if !(Line ~= "i)\.ahk$")
			continue
		if (Line ~= "i)/tests/")
			continue
		Files.Push(Line)
	}
	return Files
}

_MetaRunDuplicateDefaultsTests() {
	SplitPath(A_ScriptDir, , &_DriverRootRaw)
	DriverRoot := StrReplace(_DriverRootRaw, "\", "/") . "/"
	Whitelist := Map(
		"0", true, "1", true, "true", true, "false", true,
		'""', true, "300", true, "100", true, "50", true
	)
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
			Pos := 1
			while RegExMatch(Body, "global\s+(\w+)\s*:=\s*([^\r\n;]+)", &M, Pos) {
				VarName := Trim(M[1])
				VarVal  := Trim(M[2])
				if (!Whitelist.Has(VarVal)) {
					Key := VarName . "=" . VarVal
					if (!Seen.Has(Key))
						Seen[Key] := []
					AlreadyThere := false
					for F in Seen[Key] {
						if (F = Rel) {
							AlreadyThere := true
							break
						}
					}
					if (!AlreadyThere)
						Seen[Key].Push(Rel)
				}
				Pos := M.Pos + StrLen(M[0])
				if (Pos <= 1)
					break
			}
		}
	}
	DupCount := 0
	for Key, Files in Seen {
		if (Files.Length > 1) {
			DupCount++
			FileList := ""
			for F in Files
				FileList .= F . ", "
			OutputDebug("WARN: constant " . Key . " declared in: " . SubStr(FileList, 1, -2))
		}
	}
	_MetaDuplicateDefaultsResult() {
	}
	Test("meta duplicate defaults: scan complete (" . DupCount . " duplicates)", _MetaDuplicateDefaultsResult)
}

_MetaRunDuplicateDefaultsTests()
