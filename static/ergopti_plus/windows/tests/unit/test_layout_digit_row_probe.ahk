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
	SavedDigits := _LDRP_SetLayoutFeature("direct_access_digits", "digits")
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
		_LDRP_SetLayoutFeature("direct_access_digits", "native")
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
		AssertTrue(InStr(Body, "Hkl := IsObject(ForegroundFn) ? ForegroundFn.Call() : GetForegroundKeyboardLayout()") > 0,
			Name . " must snapshot the native foreground layout of the press")
		StrReplace(Body, "GetForegroundKeyboardLayout()", , , &Reads)
		AssertEqual(1, Reads, Name . " must not splice two foreground windows into one decision")
		AssertTrue(InStr(Body, "_DigitRowSwapResolution(Sc, Hkl)") > 0,
			Name . " must resolve the effective row on that exact native snapshot")
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

; Actual native HKLs plus the real registry source cross the callback boundary:
; the capture stores the registered criterion and emission callback, not copies
; of their conditions. Every assertion stays outside the intercepted callbacks.
_LDRP_EffectiveRegistryRow() {
	global Features, CategoryEnabled, LayerEnabled, KLE_Registered, _DigitRowProfiles, _SendHook
	global _Stub_RecordedSends, KLE_State, KEYLAYOUT_NEUTRAL_STATE
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, KLE_Registered, State.Clone(), _DigitRowProfiles, _SendHook]
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\layouts\number_row_levels.json", "UTF-8"))
	AssertEqual(10, Corpus["digits"].Length, "the independent corpus must cover the complete number row")
	try {
		Features := Map("layout", Map("emulated_layout", "ergol", "ergopti_base", true,
			"ergopti_alt_gr", true, "ergopti_plus", false, "direct_access_digits", "digits"))
		CategoryEnabled := Map("Layout", true)
		LayerEnabled := false
		State["initialized"] := false
		MasterGateInitialize(Features, Map("keys", Map()), (*) => true)
		Desired := State["features"]["layout"]
		_KLT_Load("ergol")
		_DigitRowProfiles := Map()
		Layouts := []
		for Native in Corpus["native"] {
			Hkl := _LDRP_Layout(Native["klid"])
			if !Hkl
				continue
			Layouts.Push({Hkl: Hkl, Expected: Native})
			AssertFalse(DigitRowIsSwapped(Hkl),
				"an already-direct registry row must never borrow " . Native["id"] . "'s native swap")
		}
		AssertTrue(Layouts.Length > 0, "at least one native source must be available")
		if EnvGet("GITHUB_ACTIONS") == "true"
			AssertEqual(2, Layouts.Length, "CI must compare both real AZERTY and QWERTY HKLs")
		Capture := {Criterion: 0, Rows: Map()}
		Foreground := {Hkl: Layouts[1].Hkl}
		KLE_Registered := false
		KeylayoutEmulation_Register(LayoutRegistry_Keycodes(),
			(Name, Callback, Options) => Capture.Rows[Name] := {Criterion: Capture.Criterion, Callback: Callback},
			(Args*) => Capture.Criterion := Args.Length ? Args[1] : 0,
			() => Foreground.Hkl)
		_SendHook := _HOOK_RecordSend
		loop 2 {
			for Native in Layouts {
				Foreground.Hkl := Native.Hkl
				for Index, Sc in Corpus["scancodes"] {
					Code := Integer("0x" . SubStr(Sc, 3))
					Row := Capture.Rows["+" . Sc]
					for Caps in [false, true] {
						Levels := KeylayoutEmulation_NumberRowLevels(Code, Caps)
						AssertEqual("text", Levels["plain"]["Kind"])
						AssertEqual(Corpus["emulated"]["plain"][Index], Levels["plain"]["Text"])
						AssertEqual(Corpus["emulated"]["shift"][Index], Levels["shift"]["Text"])
						AssertEqual("", DigitRowSwapSymbol(Code, Native.Hkl, Caps),
							"direct digits preserve the selected source's Shift level, including CapsLock")
					}
					AssertTrue(Row.Criterion.Call(), "the actual registered Shift variant must retain the key")
					ResetHotstringRecorders()
					Row.Callback.Call()
					AssertEqual(1, _Stub_RecordedSends.Length, "the real callback must emit exactly once")
					AssertEqual(Corpus["emulated"]["shift"][Index], _Stub_RecordedSends[1].args[1],
						"the callback must emit the registry symbol, never the native HKL symbol")
					Desired["ergopti_base"] := false
					AssertEqual(Native.Expected["plain"][Index], _APRL_Text(Native.Hkl, Code, []),
						"the native DLL must match the independently captured unshifted row")
					AssertEqual(Native.Expected["shift"][Index], _APRL_Text(Native.Hkl, Code, [0x10]),
						"the native DLL must match the independently captured shifted row")
					AssertFalse(Row.Criterion.Call(), "AltGr alone does not claim a base/Shift key")
					AssertEqual(Native.Expected["swapped"] ? Native.Expected["plain"][Index] : "",
						DigitRowSwapSymbol(Code, Native.Hkl, false), "without base the native source owns the row")
					Desired["ergopti_base"] := true
					CategoryEnabled["Layout"] := false
					AssertFalse(Row.Criterion.Call(), "a gated category must not retain the source")
					AssertEqual(0, KeylayoutEmulation_NumberRowLevels(Code, false))
					CategoryEnabled["Layout"] := true
					LayerEnabled := true
					AssertFalse(Row.Criterion.Call(), "navigation must keep its physical key ownership")
					LayerEnabled := false
					AssertTrue(Row.Criterion.Call(), "restoring the source must recover its registered Shift variant")
				}
			}
		}
		for Index, Sc in Corpus["scancodes"] {
			AssertEqual(Corpus["emulated"]["altgr"][Index], KeylayoutEmulation_Press(Sc, false, false, true))
			AssertEqual(Corpus["emulated"]["altgr_shift"][Index], KeylayoutEmulation_Press(Sc, true, false, true))
		}
		KeylayoutEmulation_Press("SC010", true, false, true)
		Pending := KLE_State
		AssertTrue(Pending !== KEYLAYOUT_NEUTRAL_STATE, "the real source must arm its circumflex state")
		for Caps in [false, true] {
			for Native in Layouts {
				for Sc in Corpus["scancodes"] {
					Code := Integer("0x" . SubStr(Sc, 3))
					KeylayoutEmulation_NumberRowLevels(Code, Caps)
					DigitRowSwapSymbol(Code, Native.Hkl, Caps)
					AssertEqual(Pending, KLE_State, "level inspection must not consume or reset a pending dead key")
				}
			}
		}
		AssertEqual(Chr(0xB9), KeylayoutEmulation_Press("SC002", false, false, false),
			"the next real press must still complete the original circumflex action")
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		KLE_Registered := Saved[4]
		State.Clear()
		for Key, Value in Saved[5]
			State[Key] := Value
		_DigitRowProfiles := Saved[6]
		_SendHook := Saved[7]
	}
}
Test("digit row: registered registry Shift callbacks preserve ten effective levels over native HKL changes (digit-row-effective-source)",
	_KLT_WithEmulation.Bind(_LDRP_EffectiveRegistryRow))

; A swapped source level can be a dead-key action, not a printable symbol.
; Inspection preserves both states, and the registered pending-key callback
; must route its real press through that source's own action machine.
_LDRP_TypedSourceSwap() {
	global Features, CategoryEnabled, LayerEnabled, KLE_Registered, _SendHook
	global KLE_State, KEYLAYOUT_NEUTRAL_STATE, _Stub_RecordedSends
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, KLE_Registered, State.Clone(), _SendHook]
	try {
		Features := Map("layout", Map("emulated_layout", "typed-row-fixture", "ergopti_base", true,
			"ergopti_alt_gr", false, "ergopti_plus", false, "direct_access_digits", "digits"))
		CategoryEnabled := Map("Layout", true)
		LayerEnabled := false
		State["initialized"] := false
		MasterGateInitialize(Features, Map("keys", Map()), (*) => true)
		Modifiers := '<keyMapSelect mapIndex="0"><modifier keys=""/></keyMapSelect>'
			. '<keyMapSelect mapIndex="1"><modifier keys="anyShift caps?"/></keyMapSelect>'
			. '<keyMapSelect mapIndex="2"><modifier keys="caps"/></keyMapSelect>'
		Maps := '<keyMap index="0"><key code="18" action="row_dead"/><key code="12" action="letter"/></keyMap>'
			. '<keyMap index="1"><key code="18" output="1"/></keyMap>'
			. '<keyMap index="2"><key code="18" output="&#xA7;"/></keyMap>'
		Actions := '<action id="row_dead"><when state="none" next="circumflex"/></action>'
			. '<action id="letter"><when state="none" output="a"/><when state="circumflex" output="&#xE2;"/></action>'
		Text := _KLT_Doc(_KLT_Layouts(), Modifiers, Maps, Actions)
		Text := StrReplace(Text, "</keyboard>", '<terminators><when state="circumflex" output="^"/></terminators></keyboard>')
		KeylayoutEmulation_Load("typed-row-fixture", Text, "ansi", LayoutRegistry_Keycodes())
		Hkl := GetForegroundKeyboardLayout()
		for Caps in [false, true] {
			KLE_State := "circumflex"
			Resolution := _DigitRowSwapResolution(0x02, Hkl, Caps)
			AssertTrue(Resolution["swap"], "both effective levels put the digit behind Shift")
			AssertEqual("emulated", Resolution["source"])
			Descriptor := Resolution["descriptor"]
			AssertEqual(Caps ? "text" : "dead", Descriptor["Kind"])
			AssertEqual(Caps ? Chr(0xA7) : "^", Descriptor["Text"])
			AssertEqual(Caps ? "" : "row_dead", Descriptor["Action"])
			AssertEqual(Caps ? "" : "circumflex", Descriptor["State"])
			AssertEqual("circumflex", KLE_State, "probing the selected level must preserve pending composition")
		}
		KLE_Registered := false
		Capture := {Criterion: 0, Rows: Map()}
		KeylayoutEmulation_Register(LayoutRegistry_Keycodes(),
			(Name, Callback, Options) => Capture.Rows[Name] := {Criterion: Capture.Criterion, Callback: Callback},
			(Args*) => Capture.Criterion := Args.Length ? Args[1] : 0)
		Row := Capture.Rows["+SC002"]
		AssertTrue(Row.Criterion.Call(), "the pending-dead-key variant must own the already-armed sequence")
		CapsBefore := GetKeyState("CapsLock", "T")
		_SendHook := _HOOK_RecordSend
		ResetHotstringRecorders()
		; The callback must consume the same pending state which made its real
		; registered criterion eligible, rather than silently switching owners.
		Row.Callback.Call()
		if CapsBefore {
			AssertEqual(1, _Stub_RecordedSends.Length)
			AssertEqual("^" . Chr(0xA7), _Stub_RecordedSends[1].args[1],
				"the real emitter must finish its pending terminator and honor hardware CapsLock")
			AssertEqual(KEYLAYOUT_NEUTRAL_STATE, KLE_State)
		} else {
			AssertEqual(1, _Stub_RecordedSends.Length)
			AssertEqual("^", _Stub_RecordedSends[1].args[1],
				"only the previous dead key's terminator is typed, never native HKL text")
			AssertEqual("circumflex", KLE_State, "the repeated source action must retain its own dead state")
			AssertEqual(Chr(0xE2), KeylayoutEmulation_Press("SC010", false, false, false),
				"the next real key must still compose through the selected source")
		}
		AssertEqual(CapsBefore, GetKeyState("CapsLock", "T"), "source emission must never change hardware CapsLock")
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		KLE_Registered := Saved[4]
		State.Clear()
		for Key, Value in Saved[5]
			State[Key] := Value
		_SendHook := Saved[6]
	}
}
Test("digit row: typed source swaps preserve CapsLock and the real dead-key owner (digit-row-effective-source)",
	_KLT_WithEmulation.Bind(_LDRP_TypedSourceSwap))

/** Replays the independent typed capability and real descriptor corpus. */
_NRP_SharedPolicyCorpus() {
	global _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\layouts\number_row_policy.json"))
	AssertEqual(18, Corpus["capabilities"].Length, "all three drivers and source capabilities are represented")
	for Row in Corpus["capabilities"]
		AssertEqual(Row["expected"], NumberRowPolicyCapable(Row["platform"], Row["mode"], Row["symbols"]))
	for Row in Corpus["symbols"] {
		Actual := NumberRowPolicySymbolsShift(Row["digit"], Row["plain"], Row["shifted"])
		AssertEqual(Row["supported"], Actual["supported"], "only actual typed text/dead source descriptors are valid")
		if Row["supported"]
			AssertEqual(Row["shift"], Actual["shift"], "the non-digit level is independently specified")
	}
	for Value in Corpus["invalid_modes"]
		AssertEqual("", NumberRowPolicyMode(Value), "legacy booleans belong to migration, never runtime truthiness")
	Owner := Map(), Source := Map()
	Expected := Map("owner", Owner, "source", Source, "native_owner", Map(), "generation", 2, "lifecycle", 3,
		"hkl", -268435447, "platform", "ahk", "mode", "native", "symbols", true,
		"master", true, "paused", false, "blocked", false, "caps", false)
	for Mode in ["native", "digits", "symbols"]
		AssertTrue(NumberRowPolicyIntent(Expected, Expected.Clone(), Mode))
	for Field in ["owner", "source", "native_owner", "generation", "lifecycle", "hkl", "mode", "symbols", "caps"] {
		Current := Expected.Clone()
		Current[Field] := Field == "owner" || Field == "source" || Field == "native_owner" ? Map()
			: Field == "mode" ? "digits" : Field == "caps" ? true
			: Field == "symbols" ? false : Current[Field] + 1
		AssertFalse(NumberRowPolicyIntent(Expected, Current, "native"), "a retained callback cannot borrow changed " . Field)
	}
}
Test("number row: shared typed source policy refuses unsupported and stale owners", _NRP_SharedPolicyCorpus)

/** Uses the real registry callback and existing Send capture, including repeats. */
_NRP_RegisteredSymbols() {
	global Features, CategoryEnabled, LayerEnabled, KLE_Registered, _SendHook, _Stub_RecordedSends, _SharedDir
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, KLE_Registered, State.Clone(), _SendHook]
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\layouts\number_row_levels.json"))
	try {
		Features := Map("layout", Map("emulated_layout", "ergol", "ergopti_base", true,
			"ergopti_alt_gr", true, "ergopti_plus", false, "direct_access_digits", "symbols"))
		CategoryEnabled := Map("Layout", true)
		LayerEnabled := false
		State["initialized"] := false
		MasterGateInitialize(Features, Map("keys", Map()), (*) => true)
		_KLT_Load("ergol")
		AssertTrue(NumberRowSymbolsCapable(false))
		AssertTrue(NumberRowSymbolsCapable(true), "hardware CapsLock has an independently valid source pair")
		KLE_Registered := false
		Capture := { Criterion: 0, Rows: Map() }
		KeylayoutEmulation_Register(LayoutRegistry_Keycodes(),
			(Name, Callback, Options) => Capture.Rows[Name] := { Criterion: Capture.Criterion, Callback: Callback },
			(Args*) => Capture.Criterion := Args.Length ? Args[1] : 0)
		_SendHook := _HOOK_RecordSend
		CapsBefore := GetKeyState("CapsLock", "T")
		for Index, Sc in Corpus["scancodes"] {
			Legend := LayerEditor_CurrentEmulation()["character"].Call(Sc)
			AssertEqual(Corpus["emulated"]["shift"][Index], Legend,
				"the actual layer-editor legend follows the same unshifted symbols source")
			for Shift in [false, true] {
				Row := Capture.Rows[Shift ? "+" . Sc : Sc]
				AssertTrue(Row.Criterion.Call(), "the original KLE owner admits its actual key")
				Loop 2 {
					ResetHotstringRecorders()
					Row.Callback.Call()
					AssertEqual(1, _Stub_RecordedSends.Length, "each press and repeat emits once")
					AssertEqual(Corpus["emulated"][Shift ? "plain" : "shift"][Index], _Stub_RecordedSends[1].args[1],
						"symbols-first retains exact source levels, with Shift reversing them")
				}
			}
		}
		AssertEqual(CapsBefore, GetKeyState("CapsLock", "T"), "policy never changes hardware CapsLock")
		State["features"]["layout"]["emulated_layout"] := "foreign-source"
		AssertFalse(NumberRowSymbolsCapable(CapsBefore), "a loaded old source is not a current capability receipt")
		AssertEqual("native", NumberRowEffectiveMode(), "unsupported desired symbols cannot claim effective symbols")
		AssertEqual("symbols", State["features"]["layout"]["direct_access_digits"], "unsupported intent remains explicit, never default-flushed")
		State["features"]["layout"]["emulated_layout"] := "ergol"
		CategoryEnabled["Layout"] := false
		AssertEqual("native", NumberRowEffectiveMode(), "master-off retains native input despite the stored enum")
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		KLE_Registered := Saved[4]
		State.Clear()
		for Key, Value in Saved[5]
			State[Key] := Value
		_SendHook := Saved[6]
	}
}
Test("number row: symbols use actual registered KLE levels and repeat owner", () => _KLT_WithEmulation(_NRP_RegisteredSymbols))


/** Records an exact native writer result; assertions remain outside callbacks. */
_NRP_MenuWriter(Mode, Seen, Path, Updates, Content, Presence) {
	Seen["calls"] += 1
	Seen["content"] := Content
	Seen["presence"] := Presence
	if Mode == "source-race" {
		Foreign := StrReplace(Content, '"kept"', '"foreign"')
		Seen["changed"] := StrCompare(Content, Foreign, true) != 0
		FileDelete(Path)
		FileAppend(Foreign, Path, "UTF-8-RAW")
		return _TOML_BatchWriteImpl(Path, Updates, [], "write", Content, Presence)
	}
	if Mode == "throw"
		throw Error("owned number-row writer refusal")
	if Mode == "nil"
		return
	if Mode == "false"
		return false
	if Mode == "two"
		return 2
	if Mode == "string"
		return "1"
	if Mode == "float"
		return 1.0
	return _TOML_BatchWriteImpl(Path, Updates, [], "write", Content, Presence)
}

_NRP_MenuFixture(Path, Mode := "native") {
	global Features, CategoryEnabled, LayerEnabled
	Features := Map("layout", Map("emulated_layout", "ergol", "ergopti_base", true,
		"ergopti_alt_gr", true, "ergopti_plus", false, "direct_access_digits", Mode))
	CategoryEnabled := Map("Layout", true)
	LayerEnabled := false
	State := MasterGateState()
	State["initialized"] := false
	MasterGateInitialize(Features, Map("keys", Map()), (*) => true)
	_KLT_Load("ergol")
	Image := '[layout]`nemulated_layout = "ergol"`nergopti_base = true`n'
		. 'future = "kept" # exact neighbour`n'
	if Mode != "native"
		Image .= 'direct_access_digits = "' . Mode . '"`n'
	Image .= '`n[category_enabled]`nlayout = true`n'
	if FileExist(Path)
		FileDelete(Path)
	FileAppend(Image, Path, "UTF-8-RAW")
	return Image
}

_NRP_MenuNativeOwners() {
	global Features, CategoryEnabled, LayerEnabled, ConfigurationFile, _TrayRootLifecycleEpoch, _LayoutPollRetry
	Saved := [Features, CategoryEnabled, LayerEnabled, ConfigurationFile,
		MasterGateState().Clone(), _TrayRootLifecycleEpoch, A_IsSuspended, MagicEditorState()["configuration_generation"], _LayoutPollRetry]
	Dir := _KLT_TempDir()
	ConfigurationFile := Dir . "config.toml"
	try {
		if A_IsSuspended
			Suspend(false)
		for Mode in ["ack", "false", "nil", "two", "string", "float", "throw", "source-race"] {
			Before := _NRP_MenuFixture(ConfigurationFile)
			Seen := Map("calls", 0, "refresh", 0, "changed", false)
			Rows := _LAY_NumberRowRows(_NRP_MenuWriter.Bind(Mode, Seen), (*) => Seen["refresh"] += 1, (*) => true)
			AssertEqual(1, Rows.Length, "the actual choice renderer must produce its canonical head")
			AssertEqual(3, Rows[1]["items"].Length)
			AssertTrue(Rows[1]["items"][1]["checked"])
			AssertFalse(Rows[1]["items"][2].Get("disabled", false), "fresh digits choice is executable")
			AssertFalse(Rows[1]["items"][3].Get("disabled", false), "only a real supported KLE source admits symbols")
			AssertFalse(Rows[1]["items"][1]["action"].Call(), "same-native status acquires no default write")
			AssertEqual(0, Seen["calls"])
			Result := Rows[1]["items"][3]["action"].Call()
			AssertEqual(Mode == "ack", Result, "only strict native publication may acknowledge the selection")
			AssertEqual(1, Seen["calls"])
			AssertEqual(Before, Seen["content"], "the terminal seam receives the admitted raw image")
			AssertEqual(1, Seen["presence"])
			AssertEqual(Mode == "ack" ? 1 : 0, Seen["refresh"])
			AssertEqual(Mode == "ack" ? "symbols" : "native", MasterGateDesiredFeatures(Features)["layout"]["direct_access_digits"])
			if Mode == "source-race" {
				AssertTrue(Seen["changed"], "foreign replacement must genuinely change bytes outside the caught writer")
				AssertEqual(StrReplace(Before, '"kept"', '"foreign"'), FSReadUtf8Exact(ConfigurationFile))
			} else if Mode != "ack"
				AssertEqual(Before, FSReadUtf8Exact(ConfigurationFile))
			else {
				AssertContains(FSReadUtf8Exact(ConfigurationFile), 'direct_access_digits = "symbols"')
				AssertContains(FSReadUtf8Exact(ConfigurationFile), 'future = "kept" # exact neighbour')
			}
		}
		for Condition in ["source", "external-mode", "model", "pause", "master", "configuration", "lifecycle", "native-source"] {
			Before := _NRP_MenuFixture(ConfigurationFile)
			Seen := Map("calls", 0, "refresh", 0)
			Rows := _LAY_NumberRowRows(_NRP_MenuWriter.Bind("ack", Seen), (*) => Seen["refresh"] += 1, (*) => true)
			Callback := Rows[1]["items"][3]["action"]
			switch Condition {
				case "source": FileAppend("# foreign edit`n", ConfigurationFile, "UTF-8-RAW")
				case "external-mode":
					Image := StrReplace(Before, '[layout]', '[layout]`ndirect_access_digits = "digits"')
					FileDelete(ConfigurationFile)
					FileAppend(Image, ConfigurationFile, "UTF-8-RAW")
				case "model": _KLT_Load("ergol")
				case "pause": Suspend(true)
				case "master": CategoryEnabled["Layout"] := false
				case "configuration":
					MagicEditorConfigurationChanged()
				case "lifecycle": _TrayRootLifecycleEpoch += 1
				case "native-source":
					Hkl := GetForegroundKeyboardLayout()
					Other := 0
					for Native in _LDRP_RealLayouts() {
						if Native != Hkl {
							Other := Native
							break
						}
					}
					AssertTrue(Other != 0, "a second genuine HKL must qualify the observed source cycle")
					_LayoutPollObserve(Other)
					_LayoutPollObserve(Hkl)

			}
			Foreign := FSReadUtf8Exact(ConfigurationFile)
			AssertFalse(Callback.Call(), Condition . " must retire the captured source")
			AssertEqual(0, Seen["calls"])
			AssertEqual(0, Seen["refresh"])
			AssertEqual(Foreign, FSReadUtf8Exact(ConfigurationFile))
			if A_IsSuspended
				Suspend(false)
		}
	} finally {
		if A_IsSuspended != Saved[7]
			Suspend(Saved[7])
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		ConfigurationFile := Saved[4]
		State := MasterGateState()
		State.Clear()
		for Key, Value in Saved[5]
			State[Key] := Value
		_TrayRootLifecycleEpoch := Saved[6]
		MagicEditorState()["configuration_generation"] := Saved[8]
		_LayoutPollRetry := Saved[9]
		DirDelete(Dir, true)
	}
}
Test("number row: real menu callbacks retain source and strict native ACK before publication", _KLT_WithEmulation.Bind(_NRP_MenuNativeOwners))


/** A real dead action is routed through the unchanged KLE composition owner. */
_NRP_RegisteredSymbolsDeadAction() {
	global Features, CategoryEnabled, LayerEnabled, KLE_Registered, _SendHook, KLE_State, _Stub_RecordedSends
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, KLE_Registered, State.Clone(), _SendHook]
	try {
		Features := Map("layout", Map("emulated_layout", "ergol", "ergopti_base", true,
			"ergopti_alt_gr", true, "ergopti_plus", false, "direct_access_digits", "symbols"))
		CategoryEnabled := Map("Layout", true)
		LayerEnabled := false
		State["initialized"] := false
		MasterGateInitialize(Features, Map("keys", Map()), (*) => true)
		Text := _KLT_LayoutText("ergol")
		Text := _KLT_Tamper(Text, '<key code="18"  action="ae01_' . Chr(0x20AC) . '" />',
			'<key code="18"  action="number_row_dead" />')
		Text := _KLT_Tamper(Text, '</actions>',
			'<action id="number_row_dead"><when state="none" next="number_row_pending"/></action></actions>')
		Text := _KLT_Tamper(Text, '</terminators>',
			'<when state="number_row_pending" output="^"/></terminators>')
		KeylayoutEmulation_Load("ergol", Text, "ansi", LayoutRegistry_Keycodes())
		AssertTrue(NumberRowSymbolsCapable(false), "all ten real levels include the typed dead source")
		AssertEqual("dead", KeylayoutEmulation_NumberRowLevels(0x02, false)["shift"]["Kind"])
		AssertEqual("number_row_pending", KeylayoutEmulation_NumberRowLevels(0x02, false)["shift"]["State"])
		KLE_Registered := false
		Capture := { Criterion: 0, Rows: Map() }
		KeylayoutEmulation_Register(LayoutRegistry_Keycodes(),
			(Name, Callback, Options) => Capture.Rows[Name] := { Criterion: Capture.Criterion, Callback: Callback },
			(Args*) => Capture.Criterion := Args.Length ? Args[1] : 0)
		_SendHook := _HOOK_RecordSend
		Row := Capture.Rows["SC002"]
		AssertTrue(Row.Criterion.Call())
		ResetHotstringRecorders()
		; CapsLock is read by the genuine callback. Both source Caps maps share
		; the digits level; only its Shift source was changed by the exact XML.
		Row.Callback.Call()
		AssertEqual("number_row_pending", KLE_State, "symbols-first must arm the real action state")
		AssertEqual(0, _Stub_RecordedSends.Length, "arming a dead source emits no invented Unicode glyph")
		AssertEqual("^q", KeylayoutEmulation_Press("SC010", false, false, false), "the unchanged source machine retires its own pending state")
		AssertEqual("none", KLE_State)
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		KLE_Registered := Saved[4]
		State.Clear()
		for Key, Value in Saved[5]
			State[Key] := Value
		_SendHook := Saved[6]
	}
}
Test("number row: symbols retain real dead-action composition without a new emitter", _KLT_WithEmulation.Bind(_NRP_RegisteredSymbolsDeadAction))
