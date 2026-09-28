; tests/unit/test_layout_digit_row_probe.ahk

; ==============================================================================
; MODULE: The digit row on real keyboard layouts
; DESCRIPTION:
; "Chiffres en accès direct" swaps the digit row of a layout whose digits need
; Shift: Shift+digit key then types the layout's own unshifted symbol, and the
; Ergopti Shift and CapsLock layers leave that row alone. The probe that decided
; it passed "1" to VkKeyScanExW as a string: the function read the low bits of
; the string's address, found no such character (-1) on every layout, and the
; -1's high byte read as Shift. QWERTY and the Ergopti Kana layout, whose digits
; are direct, got the swap: Shift+1 typed "1" (measured on this machine's
; Ergopti Kana layout, bépo and AZERTY: -1 on all three). The symbols themselves
; came from GetKeyName, which reads the script thread's own layout, not the one
; the row was probed on (digit-row-probe-2026-09-27).
; The swap was then registered at load for the boot layout, so the layout poll
; reloaded the driver on every switch between layouts whose digit rows differ:
; with Windows' per-window input methods, on every switch between an AZERTY
; window and a QWERTY or Kana one. The swap and the layers' digit row are now
; registered on every layout and decided per press on the foreground window's
; layout (DigitRowIsSwapped), and no digit row makes the poll reload
; (digit-row-live-2026-09-27).
; The oracle is independent of VkKeyScanExW: a layout's digits are shifted when
; the "1" key does not type "1" unshifted (MapVirtualKeyExW). On the CI runner
; AZERTY and US QWERTY are loaded without being activated; elsewhere only the
; installed layouts are read. No key is sent and no hook installed.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================
; ===============================
; ======= 1/ Real layouts =======
; ===============================
; ===============================

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

; AZERTY and US QWERTY when available, then every installed layout (the
; maintainer's Kana layout on this machine), each once.
_LDRP_RealLayouts() {
	Layouts := []
	Seen := Map()
	Candidates := [_LDRP_Layout("0000040C"), _LDRP_Layout("00000409")]
	for _, Hkl in KS_InstalledKeyboardLayouts()
		Candidates.Push(Hkl)
	for _, Hkl in Candidates {
		if (Hkl != 0 and !Seen.Has(Hkl)) {
			Seen[Hkl] := true
			Layouts.Push(Hkl)
		}
	}
	return Layouts
}

; The layouts forth, then back: every switch between two of them both ways.
_LDRP_BackAndForth(Layouts) {
	Sequence := []
	for _, Hkl in Layouts
		Sequence.Push(Hkl)
	Index := Layouts.Length
	while (Index >= 1) {
		Sequence.Push(Layouts[Index])
		Index -= 1
	}
	for _, Hkl in Layouts
		Sequence.Push(Hkl)
	return Sequence
}

; Sets Features["layout"] Key to Value; returns what to restore.
_LDRP_SetLayoutFeature(Key, Value) {
	global Features
	Saved := Features["layout"][Key]
	Features["layout"][Key] := Value
	return Saved
}





; =============================
; =============================
; ======= 2/ The probes =======
; =============================
; =============================

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





; ========================================================
; ========================================================
; ======= 3/ The row follows the foreground layout =======
; ========================================================
; ========================================================

; Switching back and forth between the real layouts, what the swap and the
; layers' digit-row criteria read (DigitRowIsSwapped, DigitRowSwapSymbol) is
; each layout's own row, every time, from one probe per layout; with the
; feature off no layout is swapped.
_LDRP_RowFollowsTheForegroundLayout() {
	global _DigitRowProfiles
	Layouts := _LDRP_RealLayouts()
	SavedProfiles := _DigitRowProfiles
	SavedDigits := _LDRP_SetLayoutFeature("direct_access_digits", true)
	_DigitRowProfiles := Map()
	try {
		Shifted := 0, Direct := 0
		for _, Hkl in _LDRP_BackAndForth(Layouts) {
			IsShifted := _LDRP_OneKeyChar(Hkl) != "1"
			Where := Format("layout 0x{:X}", Hkl)
			AssertEqual(IsShifted, DigitRowIsSwapped(Hkl), Where . ": the row is swapped exactly where its digits need Shift")
			Symbols := KS_LayoutDigitRowSymbols(Hkl)
			for Sc in [0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B]
				AssertEqual(IsShifted ? Symbols.Get(Sc, "") : "", DigitRowSwapSymbol(Sc, Hkl),
					Where . Format(": Shift+SC{:03X} types that layout's own unshifted symbol, or is not swapped", Sc))
			if IsShifted
				Shifted += 1
			else
				Direct += 1
		}
		AssertEqual(Layouts.Length, _DigitRowProfiles.Count, "each layout's digit row is probed once")
		if (EnvGet("GITHUB_ACTIONS") = "true")
			AssertTrue(Shifted > 0 and Direct > 0, "the CI runner switches between a shifted and a direct digit row")
		AssertFalse(DigitRowIsSwapped(0), "no foreground window (HKL 0): nothing is swapped")
		_LDRP_SetLayoutFeature("direct_access_digits", false)
		for _, Hkl in Layouts {
			AssertFalse(DigitRowIsSwapped(Hkl), Format("the feature off: layout 0x{:X} is not swapped", Hkl))
			AssertEqual("", DigitRowSwapSymbol(0x02, Hkl), Format("the feature off: layout 0x{:X} types no swapped symbol", Hkl))
		}
	} finally {
		_LDRP_SetLayoutFeature("direct_access_digits", SavedDigits)
		_DigitRowProfiles := SavedProfiles
	}
}
Test("digit row: the swap follows the foreground layout back and forth, one probe per layout (digit-row-live-2026-09-27)",
	_LDRP_RowFollowsTheForegroundLayout)

; Under the shipped defaults, the layout poll, through the real remap
; signature and probes, never reloads for a switch between the real layouts,
; both ways: the digit row no longer depends on the boot layout. It reloaded
; on the first switch between an AZERTY and a QWERTY or Kana layout.
_LDRP_SwitchingLayoutsNeverReloadsUnderTheDefaults() {
	global _LAST_KEYBOARD_HKL, _PENDING_KEYBOARD_HKL, _LAYOUT_REMAP_HKL, _LayoutPollRetry
	Layouts := _LDRP_RealLayouts()
	AssertTrue(Layouts.Length >= 1, "at least the session's own layout must be readable")
	; The entry owns the trackers; the harness never loads it.
	Saved := { Last: IsSet(_LAST_KEYBOARD_HKL) ? _LAST_KEYBOARD_HKL : 0,
		Pending: IsSet(_PENDING_KEYBOARD_HKL) ? _PENDING_KEYBOARD_HKL : 0,
		Remap: IsSet(_LAYOUT_REMAP_HKL) ? _LAYOUT_REMAP_HKL : 0, Retry: _LayoutPollRetry }
	SavedDigits := _LDRP_SetLayoutFeature("direct_access_digits",
		ManifestRecommendedFor("layout.direct_access_digits"))
	SavedEmulated := _LDRP_SetLayoutFeature("ergopti_base",
		ManifestRecommendedFor("layout.ergopti_base"))
	Reloads := []
	Port := Map(
		"needs_reload", LayoutRemapNeedsReload,
		"reload", (RefusedFn) => (Reloads.Push(RefusedFn), true),
		"pending", () => false,
		"veto_honored", () => true,
		"now", () => A_TickCount,
		"notify", () => 0)
	_LAYOUT_REMAP_HKL := Layouts[1]
	_LAST_KEYBOARD_HKL := Layouts[1]
	_PENDING_KEYBOARD_HKL := 0
	_LayoutPollRetry := _LayoutPollNewRetry(0)
	try {
		for _, Hkl in _LDRP_BackAndForth(Layouts) {
			Loop 3
				LayoutPollTick(Hkl, false, false, 0, 0, 5000, false, Port)
			AssertEqual(0, Reloads.Length, Format("a switch to layout 0x{:X} must not reload", Hkl))
			AssertEqual(Hkl, _LAST_KEYBOARD_HKL, Format("the poll adopts layout 0x{:X} as its baseline", Hkl))
		}
	} finally {
		_LDRP_SetLayoutFeature("direct_access_digits", SavedDigits)
		_LDRP_SetLayoutFeature("ergopti_base", SavedEmulated)
		_LAST_KEYBOARD_HKL := Saved.Last
		_PENDING_KEYBOARD_HKL := Saved.Pending
		_LAYOUT_REMAP_HKL := Saved.Remap
		_LayoutPollRetry := Saved.Retry
	}
}
Test("digit row: under the explicitly selected preset no switch between real layouts reloads, both ways (digit-row-live-2026-09-27)",
	_LDRP_SwitchingLayoutsNeverReloadsUnderTheDefaults)

; modules/keymap/layout.ahk registers the swap at load, so the harness cannot
; include it: the swap and the layers' digit row must be registered on every
; layout, each deciding per press on the foreground layout, and only the
; profile reads the probes, the check and the symbols on one layout.
_LDRP_RowRegisteredOnEveryLayout() {
	Src := _DriverSourceNoComments()
	AssertTrue(InStr(Src, "HotIf(_DigitRowSwapIsLive.Bind(") > 0
			and InStr(Src, "_DigitRowSwapSend.Bind(") > 0,
		"the swap must be registered on every layout, gated per press")
	for _, Name in ["_DigitRowSwapIsLive", "_DigitRowSwapSend"] {
		Body := _StripFullLineComments(_DriverFuncBody(Name))
		AssertTrue(InStr(Body, "DigitRowSwapSymbol(Sc, GetForegroundKeyboardLayout())") > 0,
			Name . " must read the swap on the foreground layout of the press")
		AssertFalse(InStr(Body, "GetKeyName(") > 0,
			Name . ": GetKeyName reads the script thread's own layout, never the foreground one")
	}
	for _, Name in ["RegisterShiftLayer", "RegisterCapsLockLayer"] {
		Body := _StripFullLineComments(_DriverFuncBody(Name))
		AssertTrue(InStr(Body, "and !DigitRowIsSwapped(GetForegroundKeyboardLayout()))") > 0,
			Name . " must stand its digit row down per press where the swap owns it")
	}
	Profile := _StripFullLineComments(_DriverFuncBody("_DigitRowProfile"))
	for _, Probe in ["KS_LayoutDigitsAreShifted(", "KS_LayoutDigitRowSymbols("] {
		AssertTrue(InStr(Profile, Probe . "Hkl)") > 0, "the profile must read " . Probe . ") on its one layout")
		StrReplace(Src, Probe, , , &Uses)
		; The definition, and the one call in the profile.
		AssertEqual(2, Uses, Probe . ") must be read only through the profile, never decided at load")
	}
}
Test("digit row: the swap and the layers' digit row are registered on every layout and decided per press (digit-row-live-2026-09-27)",
	_LDRP_RowRegisteredOnEveryLayout)
