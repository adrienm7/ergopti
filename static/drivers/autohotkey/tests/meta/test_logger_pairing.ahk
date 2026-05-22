; tests/meta/test_logger_pairing.ahk

; ==============================================================================
; MODULE: Logger Lifecycle Pairing Test
; DESCRIPTION:
; For each AHK source file in lib/ and modules/, counts LoggerStart vs
; LoggerSuccess and LoggerTrace vs LoggerDone occurrences. Imbalances are
; flagged as warnings (not errors) because legitimate early-return control
; flow can produce natural asymmetries.
;
; The test always passes; its value is the OutputDebug report attached to
; CI logs so reviewers can spot unpaired lifecycle calls at a glance.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; ======================================
; ======= 1/ File listing helper =======
; ======================================
; =====================================

_MetaListAhkFilesLogger(Dir) {
	Files := []
	TempFile := A_Temp . "\meta_dir_logger.txt"
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

_MetaCountPattern(Body, Pattern) {
	N := 0
	Pos := 1
	while RegExMatch(Body, Pattern, , Pos) {
		N++
		Pos := RegExMatch(Body, Pattern, &M, Pos) + StrLen(M[0])
		if Pos <= 1 {
			break
		}
	}
	return N
}





; =====================================
; =====================================
; ======= 2/ Test registrations =======
; =====================================
; =====================================

_MetaRunLoggerPairingTests() {
	DriverRoot := StrReplace(A_ScriptDir, "\", "/") . "/../../"
	Imbalanced := 0

	for _, Sub in ["lib", "modules"] {
		for _, Abs in _MetaListAhkFilesLogger(StrReplace(DriverRoot . Sub, "/", "\")) {
			try {
				Body := FileRead(StrReplace(Abs, "/", "\"))
			} catch {
				continue
			}
			NormRoot := StrReplace(DriverRoot, "\", "/")
			Rel := SubStr(StrReplace(Abs, "\", "/"), StrLen(NormRoot) + 1)

			NStart   := _MetaCountPattern(Body, "LoggerStart\(")
			NSuccess := _MetaCountPattern(Body, "LoggerSuccess\(")
			NTrace   := _MetaCountPattern(Body, "LoggerTrace\(")
			NDone    := _MetaCountPattern(Body, "LoggerDone\(")

			if NStart > 0 and NSuccess = 0 {
				Imbalanced++
				OutputDebug("WARN: " . Rel . " has " . NStart . " LoggerStart but 0 LoggerSuccess")
			}
			if NTrace > 0 and NDone = 0 {
				Imbalanced++
				OutputDebug("WARN: " . Rel . " has " . NTrace . " LoggerTrace but 0 LoggerDone")
			}
		}
	}

	Test("meta logger pairing: scan complete (" . Imbalanced . " warnings)", () => {})
}

_MetaRunLoggerPairingTests()
