; tests/meta/test_tap_hold_hotkeys_admit_held_modifiers.ahk

; ==============================================================================
; MODULE: Modifier and CapsLock tap-holds fire under a held modifier
; DESCRIPTION:
; A hotkey without the * wildcard fires only when the held modifiers match its
; own exactly (measured with AutoHotkey 2.0.26, even for the driver's own
; synthetic holds). With any modifier already held, a tap-hold on RCtrl, LAlt,
; CapsLock, Win, AltGr on QWERTY or as a Kana tap-only key, or a tap-only LShift,
; LCtrl or RShift therefore did not fire: the key performed its native function,
; so the configured tap and hold were both lost. CapsLock held as Ctrl, RCtrl
; held as Shift and X gave Ctrl+X, not Ctrl+Shift+X
; (held-modifier-tap-2026-09-25).
; Tab, Space, Enter, Escape, Backspace and Delete stay the key itself under a
; held modifier on every driver (Linux NATIVE_UNDER_MODIFIER), so their keys are
; not scanned. The LAlt one-shot Shift is the one deliberate exception: under
; another modifier it lets the native Alt through for that shortcut.
; ==============================================================================

#Requires AutoHotkey v2.0

; Scan codes of CapsLock and the modifier keys that carry a tap-hold.
global _THAM_KEY_PATTERN := "SC(?:03A|01D|02A|038|15B|138|11D|036)"

; Scans Src for tap-hold hotkeys (governed by a #HotIf that requires the layer
; off) on those keys and returns the ones without the * wildcard, excluding
; the LAlt one-shot Shift. Custom combinations ("A & B") act as wildcards.
_THAM_Offenders(Src, &Subjects, &Exempt) {
	global _THAM_KEY_PATTERN
	Subjects := 0
	Exempt := 0
	Offenders := ""
	HotIf := ""
	Depth := 0
	Loop Parse, Src, "`n", "`r" {
		Line := Trim(A_LoopField)
		if (Depth > 0) {
			HotIf .= " " . Line
			Depth += _THAM_ParenBalance(Line)
			continue
		}
		if (SubStr(Line, 1, 6) = "#HotIf") {
			HotIf := Line
			Depth := _THAM_ParenBalance(Line)
			continue
		}
		if !RegExMatch(Line, "^([~$*#!^+<>]*)(" . _THAM_KEY_PATTERN . ")(?: Up)?::", &Label)
			continue
		if !InStr(HotIf, "not LayerEnabled")
			continue
		Subjects++
		if InStr(Label[1], "*")
			continue
		if InStr(HotIf, 'TapHoldTapAction(TapHold, "left_alt") == "one_shot_shift"') {
			Exempt++
			continue
		}
		Offenders .= (Offenders = "" ? "" : ", ") . Label[0]
	}
	return Offenders
}

_THAM_ParenBalance(Line) {
	return StrLen(Line) - StrLen(StrReplace(Line, "(")) - (StrLen(Line) - StrLen(StrReplace(Line, ")")))
}

_THAM_ScannerFindsTheExactMatchShape() {
	Fixture := '#HotIf TapHoldHoldModifier(TapHold, "right_ctrl") != "" and not LayerEnabled`n'
		. "$SC11D:: {`n}`n+SC11D:: return`n*SC03A:: return`nSC01D & SC138:: return`n"
		. "#HotIf (`n`tTapHoldTapAction(TapHold, " . Chr(34) . "left_alt" . Chr(34)
		. ") == " . Chr(34) . "one_shot_shift" . Chr(34) . "`n`tand not LayerEnabled`n)`nSC03A:: return`n"
		. "#HotIf LayerEnabled`nSC138:: return`n"
	Offenders := _THAM_Offenders(Fixture, &Subjects, &Exempt)
	AssertEqual("$SC11D::, +SC11D::", Offenders,
		"the scanner must flag every tap-hold variant that needs an exact modifier match")
	AssertEqual(4, Subjects, "the layer's own hotkeys are not tap-holds; combinations are not labels")
	AssertEqual(1, Exempt, "a multi-line #HotIf must still identify the LAlt one-shot Shift")
}
Test("tap-hold admission: the scanner flags a variant without the wildcard (held-modifier-tap-2026-09-25)",
	_THAM_ScannerFindsTheExactMatchShape)

_THAM_EveryModifierTapHoldFiresUnderAHeldModifier() {
	Src := _StripFullLineComments(_DriverDirConcat("platform/remap"))
	Offenders := _THAM_Offenders(Src, &Subjects, &Exempt)
	AssertEqual("", Offenders,
		"these tap-hold variants do not fire under a held modifier, so the key's native function replaces the configured tap and hold")
	Assert(Subjects >= 30, "every tap-hold variant of the modifier keys must be scanned, got " . Subjects)
	AssertEqual(2, Exempt,
		"only the LAlt one-shot Shift and its CapsLock rescue may stay native under a held modifier")
}
Test("tap-hold admission: CapsLock and modifier-key tap-holds fire under a held modifier (held-modifier-tap-2026-09-25)",
	_THAM_EveryModifierTapHoldFiresUnderAHeldModifier)
