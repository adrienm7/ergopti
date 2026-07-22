; tests/meta/test_hse_suppress_release_bounded.ahk

; ==============================================================================
; MODULE: HSE Suppress Release Window Gate
; DESCRIPTION:
; Guards that the suppress-release delay is a single named constant and stays
; within a reasonable upper bound. The suppress window gates physical keystrokes
; OUT of the engine buffer after an expansion burst, and the release fires via a
; negative SetTimer. On a system under load the timer can fire well past its
; nominal delay — every extra ms is a ms where a physical keystroke is silently
; dropped, desyncing HSE_Buffer from the real screen and causing the next
; trigger to misfire.
;
; The constant must be:
;   1. <= 100 ms so the worst-case blind spot cannot drift beyond one keystroke.
;   2. Used in EVERY SetTimer that releases suppress — no hardcoded -60 literal
;      that would survive a constant rename/tightening unscathed.
; ==============================================================================

#Requires AutoHotkey v2.0


_HSE_SRL_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Src := ""
	try Src := FileRead(WindowsDir . "\" . RelPath)
	return Src
}

_HSE_SuppressReleaseBounded() {
	Src := _HSE_SRL_ReadSource("lib\hotstrings\hotstring_dispatch.ahk")
	Assert(Src != "", "hotstring_dispatch.ahk must be readable")

	; 1. Constant exists and is bounded to <= 100 ms.
	FoundDecl := false
	MaxDelay := 0
	Loop Parse, Src, "`n", "`r" {
		Line := A_LoopField
		if InStr(Line, "HSE_SUPPRESS_RELEASE_DELAY_MS") && InStr(Line, ":=") {
			FoundDecl := true
			; Extract digits after :=
			Pos := InStr(Line, ":=")
			if Pos {
				After := SubStr(Line, Pos + 2)
				; Strip leading whitespace and trailing comment
				After := RegExReplace(After, "^\s+", "")
				After := RegExReplace(After, "\s*;.*$", "")
				After := RegExReplace(After, "\s+$", "")
				if (After != "") {
					try MaxDelay := Number(After)
				}
			}
			break
		}
	}
	Assert(FoundDecl, "HSE_SUPPRESS_RELEASE_DELAY_MS must be declared in hotstring_dispatch.ahk")
	Assert(MaxDelay <= 100,
		"HSE_SUPPRESS_RELEASE_DELAY_MS = " . MaxDelay . " ms exceeds 100 ms upper bound")

	; 2. Every SetTimer that releases suppress must route through the constant.
	;    Scan for SetTimer lines containing a bare negative literal (e.g. -60)
	;    that is NOT the named constant. The constant-referencing lines like
	;    "-HSE_SUPPRESS_RELEASE_DELAY_MS" contain letters and are fine.
	Loop Parse, Src, "`n", "`r" {
		Line := A_LoopField
		if !InStr(Line, "SetTimer")
			continue
		; Skip lines that use the named constant — they are correct.
		if InStr(Line, "HSE_SUPPRESS_RELEASE_DELAY_MS")
			continue
		; Check for a bare negative numeric literal: a minus sign followed by
		; digits, NOT followed by a letter (which would be a variable name).
		; Pattern: look for "-\d+" that is NOT followed by [a-zA-Z_].
		Pos := 1
		while Pos := RegExMatch(Line, "-(\d+)", &M, Pos) {
			AfterMatch := Pos + StrLen(M[0])
			NextChar := SubStr(Line, AfterMatch, 1)
			; If the next character is NOT a letter or underscore, it's a
			; hardcoded numeric literal — flag it.
			if (NextChar == "") || !RegExMatch(NextChar, "[a-zA-Z_]") {
				Assert(false,
					"SetTimer with hardcoded negative literal found (use HSE_SUPPRESS_RELEASE_DELAY_MS instead): "
					. Trim(Line))
			}
			Pos := AfterMatch
		}
	}
}

Test("meta hse: suppress-release delay bounded to <=100 ms and gated by named constant",
	_HSE_SuppressReleaseBounded)
