; tests/meta/test_shift_digit_passthrough_not_shadowed.ahk

; ==============================================================================
; MODULE: Shift Digit Passthrough Shadow Prevention Meta Test
; DESCRIPTION:
; Regression guard ensuring RegisterShiftLayer does not shadow the OS-shifted-
; digit passthrough hotkeys when direct_access_digits is active.
;
; The bug: modules/layout.ahk registers global (no-criterion) +SC002..+SC00B
; hotkeys as passthrough for OS layouts where digits are behind Shift (AZERTY,
; bépo, etc.). RegisterShiftLayer then registers the same +SCxxx chords under
; an ergopti_base criterion.  AHK picks a criterion variant over a global one
; whenever the criterion is met, so the passthrough was unreachable on those
; layouts even though it was registered first.
;
; The fix: RegisterShiftLayer skips SC002..SC00B when direct_access_digits is
; active and the OS layout has shifted digits, keeping the two variant sets
; disjoint so the global passthrough owns the digit row.
;
; SCOPE: source introspection of lib/layout/layout_shift_caps.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ Source scan helpers ==================
; =================================================
; =================================================

_SDPS_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	SplitPath(WindowsDir, , &Root)
	Path := Root . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}

_SDPS_FuncBody(Src, FnDecl) {
	FnPos := InStr(Src, FnDecl)
	if (!FnPos)
		return ""
	depth := 0
	i := FnPos
	Len := StrLen(Src)
	while (i <= Len) {
		ch := SubStr(Src, i, 1)
		if (ch == "{")
			depth++
		else if (ch == "}") {
			depth--
			if (depth <= 0)
				return SubStr(Src, FnPos, i - FnPos + 1)
		}
		i++
	}
	return SubStr(Src, FnPos)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_SDPS_CheckDigitSCsMapExists() {
	Src := _SDPS_ReadSource("lib/layout/layout_shift_caps.ahk")
	Assert(Src != "", "lib/layout/layout_shift_caps.ahk must be readable")

	Assert(InStr(Src, "_SHIFT_DIGIT_SCS"),
		"_SHIFT_DIGIT_SCS set must be defined in layout_shift_caps.ahk to mark SC002..SC00B for exclusion")

	; All ten digit-row scancodes must be listed
	for _, SC in ["SC002", "SC003", "SC004", "SC005", "SC006",
	              "SC007", "SC008", "SC009", "SC00A", "SC00B"] {
		Assert(InStr(Src, '"' . SC . '"'),
			"_SHIFT_DIGIT_SCS must include " . SC)
	}
}

_SDPS_CheckRegisterShiftHasSkipGuard() {
	Src := _SDPS_ReadSource("lib/layout/layout_shift_caps.ahk")
	Assert(Src != "", "lib/layout/layout_shift_caps.ahk must be readable")

	Body := _SDPS_FuncBody(Src, "RegisterShiftLayer() {")
	Assert(Body != "", "RegisterShiftLayer must be present in layout_shift_caps.ahk")

	Assert(InStr(Body, "SkipDigitRow") || InStr(Body, "_SHIFT_DIGIT_SCS"),
		"RegisterShiftLayer must check for digit-row exclusion to avoid shadowing the passthrough")

	Assert(InStr(Body, "direct_access_digits"),
		"RegisterShiftLayer must gate the exclusion on Features[layout][direct_access_digits]")
}

_SDPS_CheckSkipUsedInsideLoop() {
	Src := _SDPS_ReadSource("lib/layout/layout_shift_caps.ahk")
	Assert(Src != "", "lib/layout/layout_shift_caps.ahk must be readable")

	Body := _SDPS_FuncBody(Src, "RegisterShiftLayer() {")
	Assert(Body != "", "RegisterShiftLayer must be present in layout_shift_caps.ahk")

	; The skip/continue must appear inside the SHIFTED_LETTERS loop
	LoopPos  := InStr(Body, "for SC in SHIFTED_LETTERS")
	SkipPos  := InStr(Body, "_SHIFT_DIGIT_SCS.Has(SC)")
	; Search for the Hotkey call that binds the shifted digit variants
	HotkeyPos := InStr(Body, 'Hotkey("+" . SC')

	Assert(LoopPos > 0, "RegisterShiftLayer must iterate SHIFTED_LETTERS")
	Assert(SkipPos > LoopPos,
		"Digit-row skip check must appear inside the SHIFTED_LETTERS loop")
	Assert(HotkeyPos > SkipPos,
		"Hotkey registration must come after the digit-row skip guard in the loop")
}


Test("meta shift-digit-passthrough: _SHIFT_DIGIT_SCS covers all ten digit-row scancodes",
	_SDPS_CheckDigitSCsMapExists)

Test("meta shift-digit-passthrough: RegisterShiftLayer has skip guard for direct_access_digits",
	_SDPS_CheckRegisterShiftHasSkipGuard)

Test("meta shift-digit-passthrough: digit-row skip applied inside SHIFTED_LETTERS loop before Hotkey call",
	_SDPS_CheckSkipUsedInsideLoop)
