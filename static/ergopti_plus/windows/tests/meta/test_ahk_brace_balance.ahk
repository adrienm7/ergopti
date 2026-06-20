; tests/meta/test_ahk_brace_balance.ahk

; ==============================================================================
; MODULE: AHK Brace Balance Validation Test
; DESCRIPTION:
; Meta-test that verifies every AHK source file under lib/ and modules/ has
; perfectly balanced curly braces after stripping string literals, line
; comments, and block comments.
;
; CATCHES:
; Orphan closing or opening braces left over when refactoring control-flow
; into early-return guards. Such orphans are silent parse errors that only
; surface at AHK runtime startup, never during development.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ File listing helper =======
; ======================================
; ======================================

_MetaBrace_ListFiles(Dir) {
	Files := []
	TempFile := A_Temp . "\meta_brace_list.txt"
	try FileDelete(TempFile)
	RunWait('cmd /c dir /b /s /a-d "' . Dir . '" > "' . TempFile . '"', , "Hide")
	try {
		Raw := FileRead(TempFile)
	} catch {
		return Files
	}
	for Line in StrSplit(Raw, "`n", "`r") {
		Line := Trim(Line)
		if Line = ""
			continue
		Line := StrReplace(Line, "\", "/")
		if not Line ~= "i)\.ahk$"
			continue
		; Skip test files — only validate production source
		if Line ~= "i)/tests/"
			continue
		Files.Push(Line)
	}
	return Files
}





; =======================================
; =======================================
; ======= 2/ Brace balance parser =======
; =======================================
; =======================================

; Counts { and } in Source after stripping string literals, line comments,
; and block comments. Returns a Map with keys "open" and "close".
_MetaBrace_Count(Source) {
	Open := 0
	Close := 0
	I := 1
	Len := StrLen(Source)
	DQ := Chr(34)  ; double-quote character
	BT := Chr(96)  ; backtick (AHK v2 string-escape prefix)

	while I <= Len {
		Ch := SubStr(Source, I, 1)

		; Block comment: /* ... */
		if Ch = "/" && SubStr(Source, I + 1, 1) = "*" {
			End := InStr(Source, "*/", true, I + 2)
			I := (End > 0) ? End + 2 : Len + 1
			continue
		}

		; Line comment: ; ... newline
		if Ch = ";" {
			NL := InStr(Source, "`n", true, I)
			I := (NL > 0) ? NL + 1 : Len + 1
			continue
		}

		; String literal: "..." (BT is the AHK v2 escape prefix inside strings)
		if Ch = DQ {
			I++
			while I <= Len {
				SC := SubStr(Source, I, 1)
				if SC = BT {
					I += 2   ; skip backtick-escaped character
					continue
				}
				if SC = DQ {
					I++
					break
				}
				I++
			}
			continue
		}

		if Ch = "{"
			Open++
		else if Ch = "}"
			Close++
		I++
	}

	return Map("open", Open, "close", Close)
}





; =====================================
; =====================================
; ======= 3/ Test registrations =======
; =====================================
; =====================================

_MetaRunBraceBalanceTests() {
	SplitPath(A_ScriptDir, , &_DriverRootRaw)
	DriverRoot := StrReplace(_DriverRootRaw, "\", "/") . "/"
	Checked := 0

	for Sub in ["lib", "modules", "ui"] {
		for AbsPath in _MetaBrace_ListFiles(StrReplace(DriverRoot . Sub, "/", "\")) {
			AbsCopy := AbsPath
			_MetaBraceCheckOne() {
				Checked++
				try {
					Source := FileRead(StrReplace(AbsCopy, "/", "\"))
				} catch {
					Assert(false, "cannot read " . AbsCopy)
					return
				}
				Counts := _MetaBrace_Count(Source)
				NormRoot := StrReplace(DriverRoot, "\", "/")
				Rel := SubStr(StrReplace(AbsCopy, "\", "/"), StrLen(NormRoot) + 1)
				Assert(
					Counts["open"] = Counts["close"],
					"unbalanced braces in " . Rel
					. " — open: " . Counts["open"]
					. "  close: " . Counts["close"]
				)
			}
			Test("brace balance: " . RegExReplace(AbsPath, ".*[/\\]"), _MetaBraceCheckOne)
		}
	}

	_MetaBraceAtLeastOne() {
		Assert(Checked > 0, "no AHK source files were located — check SrcDirs")
	}
	Test("meta brace balance: at least one file checked", _MetaBraceAtLeastOne)
}

_MetaRunBraceBalanceTests()
