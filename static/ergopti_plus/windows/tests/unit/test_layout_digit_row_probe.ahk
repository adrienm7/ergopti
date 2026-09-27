; tests/unit/test_layout_digit_row_probe.ahk

; ==============================================================================
; MODULE: The digit-row probe on real keyboard layouts
; DESCRIPTION:
; "Chiffres en accès direct" swaps the digit row of a layout whose digits need
; Shift: Shift+digit key then types the layout's own unshifted symbol, and the
; Ergopti Shift layer leaves that row alone. The probe that decided it passed
; "1" to VkKeyScanExW as a string: the function read the low bits of the
; string's address, found no such character (-1) on every layout, and the -1's
; high byte read as Shift. QWERTY and the Ergopti Kana layout, whose digits are
; direct, got the swap: Shift+1 typed "1" (measured on this machine's Ergopti
; Kana layout, bépo and AZERTY: -1 on all three). The symbols themselves came
; from GetKeyName, which reads the script thread's own layout, not the one the
; row was probed on (digit-row-probe-2026-09-27).
; The oracle is independent of VkKeyScanExW: a layout's digits are shifted when
; the "1" key does not type "1" unshifted (MapVirtualKeyExW). On the CI runner
; AZERTY and US QWERTY are loaded without being activated; elsewhere only the
; installed layouts are read. No key is sent and no hook installed.
; ==============================================================================

#Requires AutoHotkey v2.0

; HKL of the layout with KLID Klid: loaded on the CI runner, looked up among
; the installed ones elsewhere (0 when absent).
_LDRP_Layout(Klid) {
	if (EnvGet("GITHUB_ACTIONS") = "true") {
		; KLF_NOTELLSHELL (0x80): load for the probe, activate nothing.
		Hkl := DllCall("LoadKeyboardLayoutW", "Str", Klid, "UInt", 0x80, "Ptr")
		Assert(Hkl != 0, "the CI runner must be able to load keyboard layout " . Klid)
		return Hkl
	}
	Wanted := Integer("0x" . Klid)
	for _, Hkl in KS_InstalledKeyboardLayouts() {
		if ((Hkl & 0xFFFFFFFF) == ((Wanted << 16) | Wanted))
			return Hkl
	}
	return 0
}

; The unshifted character of the "1" key (VK_1) on layout Hkl.
_LDRP_OneKeyChar(Hkl) {
	return Chr(DllCall("MapVirtualKeyExW", "UInt", 0x31, "UInt", 2, "Ptr", Hkl, "UInt") & 0xFFFF)
}

_LDRP_ShiftedDigitsOnRealLayouts() {
	Azerty := _LDRP_Layout("0000040C")
	if (Azerty != 0) {
		AssertTrue(KS_LayoutDigitsAreShifted(Azerty), "French AZERTY types its digits with Shift")
		Symbols := KS_LayoutDigitRowSymbols(Azerty)
		AssertEqual("&", Symbols.Get(0x02, ""), "AZERTY's 1 key types & unshifted")
		AssertEqual("à", Symbols.Get(0x0B, ""), "AZERTY's 0 key types à unshifted")
		AssertEqual(10, Symbols.Count, "every AZERTY digit-row key types a symbol")
	}
	Qwerty := _LDRP_Layout("00000409")
	if (Qwerty != 0) {
		AssertFalse(KS_LayoutDigitsAreShifted(Qwerty), "US QWERTY types its digits without Shift")
		AssertEqual("1", KS_LayoutDigitRowSymbols(Qwerty).Get(0x02, ""), "QWERTY's 1 key types 1")
	}
	Checked := 0
	for _, Hkl in KS_InstalledKeyboardLayouts() {
		Direct := _LDRP_OneKeyChar(Hkl) == "1"
		AssertEqual(!Direct, KS_LayoutDigitsAreShifted(Hkl),
			Format("installed layout 0x{:X}: digits are shifted exactly when its 1 key does not type 1", Hkl))
		AssertEqual(_LDRP_OneKeyChar(Hkl), KS_LayoutDigitRowSymbols(Hkl).Get(0x02, ""),
			Format("installed layout 0x{:X}: the 1 key's symbol is read on that layout", Hkl))
		Checked += 1
	}
	AssertTrue(Checked >= 1, "at least the session's own layout must be probed")
	AssertFalse(KS_LayoutDigitsAreShifted(0), "no layout read (HKL 0) is never taken for a shifted one")
	AssertEqual(0, KS_LayoutDigitRowSymbols(0).Count, "no layout read (HKL 0) gives no symbol")
}
Test("digit-row probe: digits are shifted only where the 1 key does not type 1, symbols read on that layout (digit-row-probe-2026-09-27)",
	_LDRP_ShiftedDigitsOnRealLayouts)

; modules/keymap/layout.ahk registers the swap at load, so the harness cannot
; include it: its check and its symbols must both read the one layout the boot
; registrations are built for, through the adapter probes tested above.
_LDRP_SwapReadsOneLayout() {
	Check := _StripFullLineComments(_DriverFuncBody("_OsLayoutDigitsAreShifted"))
	AssertTrue(InStr(Check, "KS_LayoutDigitsAreShifted(_LAYOUT_REMAP_HKL)") > 0,
		"the shifted-digit check must probe the layout the boot registrations are built for")
	; The whole driver source, comments stripped: the swap is the only block
	; opening on this condition, wherever its file lives.
	Src := _DriverSourceNoComments()
	Swap := InStr(Src, 'if Features["layout"]["direct_access_digits"] and _OsLayoutDigitsAreShifted() {')
	AssertTrue(Swap > 0, "the digit-row swap must still be registered")
	Block := SubStr(Src, Swap, 600)
	AssertTrue(InStr(Block, "KS_LayoutDigitRowSymbols(_LAYOUT_REMAP_HKL)") > 0,
		"the swap's symbols must be read on the layout its check probed")
	AssertFalse(InStr(Block, "GetKeyName(") > 0,
		"GetKeyName reads the script thread's own layout, never the probed one")
}
Test("digit-row probe: the swap's check and symbols read one layout (digit-row-probe-2026-09-27)",
	_LDRP_SwapReadsOneLayout)
