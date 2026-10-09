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
; Tab, Space, Enter, Escape, Backspace and Delete are the opposite class: they
; stay the key itself under a held modifier on every driver (Linux
; NATIVE_UNDER_MODIFIER, the macOS rules), so none of their tap-hold variants
; may carry the wildcard. Enter, Escape, Backspace and Delete had it on their
; hold variants, so Ctrl+Enter became the tap-hold's Enter instead of Ctrl+Enter
; (native-under-modifier-parity-2026-09-25). Without the wildcard, the key's
; own auto-repeat under the modifier its owner holds matches no hotkey either
; and reached the application as that chord (Enter held as Ctrl typed
; Ctrl+Enter repeatedly, measured with AutoHotkey 2.0.26), so each of the six
; keys has a wildcard swallower gated on its owned press.
; The LAlt one-shot Shift is the one deliberate exception among the modifier
; keys: under another modifier it lets the native Alt through for that shortcut.
; ==============================================================================

#Requires AutoHotkey v2.0

; Scan codes of CapsLock and the modifier keys that carry a tap-hold.
global _THAM_KEY_PATTERN := "SC(?:03A|01D|02A|038|15B|138|11D|036)"

; Scan codes of the six keys that stay native under a held modifier.
global _THAM_NATIVE_KEY_PATTERN := "SC(?:00F|039|01C|001|00E|153)"

; Every static hotkey label on a key matching Pattern, with its prefix symbols
; and the #HotIf governing it (a multi-line #HotIf joined on one line).
; @return {Array} Objects { Label, Prefix, HotIf }.
_THAM_Variants(Src, Pattern) {
	Variants := []
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
		if RegExMatch(Line, "^([~$*#!^+<>]*)(" . Pattern . ")(?: Up)?::", &Label)
			Variants.Push({ Label: Label[0], Prefix: Label[1], HotIf: HotIf })
	}
	return Variants
}

; Scans Src for tap-hold hotkeys (governed by a #HotIf that requires the layer
; off) on those keys and returns the ones without the * wildcard, excluding
; the LAlt one-shot Shift. Custom combinations ("A & B") act as wildcards.
_THAM_Offenders(Src, &Subjects, &Exempt) {
	global _THAM_KEY_PATTERN
	Subjects := 0
	Exempt := 0
	Offenders := ""
	for _, Variant in _THAM_Variants(Src, _THAM_KEY_PATTERN) {
		; The AltGr owners' layer-off test lives in their named criteria.
		if !(InStr(Variant.HotIf, "not LayerEnabled") or InStr(Variant.HotIf, "#HotIf AltGrOwner"))
			continue
		Subjects++
		if InStr(Variant.Prefix, "*")
			continue
		if InStr(Variant.HotIf, 'TapHoldTapAction(TapHold, "left_alt") == "one_shot_shift"') {
			Exempt++
			continue
		}
		Offenders .= (Offenders = "" ? "" : ", ") . Variant.Label
	}
	return Offenders
}

; Tap-hold variants (layer off) of the six native keys that carry the wildcard.
_THAM_NativeWildcards(Src, &Subjects) {
	global _THAM_NATIVE_KEY_PATTERN
	Subjects := 0
	Offenders := ""
	for _, Variant in _THAM_Variants(Src, _THAM_NATIVE_KEY_PATTERN) {
		if !InStr(Variant.HotIf, "not LayerEnabled")
			continue
		Subjects++
		if InStr(Variant.Prefix, "*")
			Offenders .= (Offenders = "" ? "" : ", ") . Variant.Label
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
	AssertEqual(1, Exempt,
		"only the LAlt one-shot Shift may stay native under a held modifier")
}
Test("tap-hold admission: CapsLock and modifier-key tap-holds fire under a held modifier (held-modifier-tap-2026-09-25)",
	_THAM_EveryModifierTapHoldFiresUnderAHeldModifier)

_THAM_NativeScannerFindsTheWildcardShape() {
	Fixture := '#HotIf TapHoldHoldModifier(TapHold, "enter") != "" and not LayerEnabled`n'
		. "*$SC01C:: {`n}`n$SC00E:: return`n^SC00F:: return`n"
		. '#HotIf TapHoldPressIsOwned("enter")' . "`n*SC01C:: return`n"
	Offenders := _THAM_NativeWildcards(Fixture, &Subjects)
	AssertEqual("*$SC01C::", Offenders,
		"the scanner must flag a wildcard tap-hold variant of a native key, and only that one")
	AssertEqual(3, Subjects, "the owned-repeat swallower is not a tap-hold variant")
}
Test("tap-hold admission: the scanner flags a native key's wildcard variant (native-under-modifier-parity-2026-09-25)",
	_THAM_NativeScannerFindsTheWildcardShape)

; Space stays Space while another key holds the navigation layer, even when its
; own hold is that layer: the layer maps no Space. A quick tap types a space and
; a held one auto-repeats, as on Linux, whose engine pins the same rule
; (layer-under-layer). A Space-only swallower once ate every Space the layer
; saw; only Space's own owned press is swallowed now, so its auto-repeat still
; types nothing while it holds the layer. CapsWord's Space is its own feature and ends CapsWord
; (nav-layer-space-2026-09-25).
_THAM_SpaceStaysItselfUnderAnotherLayerHolder() {
	Src := _StripFullLineComments(_DriverSourceConcat())
	Assert(Src != "", "the driver source must be readable")
	Seen := 0
	Eligible := ""
	for _, Variant in _THAM_Variants(Src, "SC039") {
		Seen++
		if (InStr(Variant.HotIf, "not LayerEnabled")
				or Variant.HotIf == '#HotIf TapHoldPressIsOwned("space")'
				or Variant.HotIf == "#HotIf CapsWordEnabled"
				; A key combination that ends on Space is the user's own binding:
				; it takes Space only while its first key is held and a slot is set.
				or Variant.HotIf == "#HotIf KeyCombinationOwnsHotkey()")
			continue
		Eligible .= (Eligible = "" ? "" : " | ") . Variant.Label . " under " . Variant.HotIf
	}
	AssertEqual("", Eligible,
		"a Space pressed while another key holds the navigation layer must stay Space; only Space's own owned press may be swallowed")
	Assert(Seen >= 5, "every static Space hotkey must be scanned, got " . Seen)
}
Test("tap-hold admission: Space stays itself while another key holds the navigation layer (nav-layer-space-2026-09-25)",
	_THAM_SpaceStaysItselfUnderAnotherLayerHolder)

; LAlt tapping Backspace with the layer on hold is the one key the navigation
; layer swallows while another key holds it: passed through as Alt, it would
; put Alt under every chord of the layer. Linux's engine pins the same rule
; (layer-under-layer), which it had lost.
_THAM_LAltSwallowedUnderAnotherLayerHolder() {
	Src := _StripFullLineComments(_DriverSourceConcat())
	Assert(Src != "", "the driver source must be readable")
	Swallowers := 0
	for _, Variant in _THAM_Variants(Src, "SC038") {
		if (InStr(Variant.HotIf, "_LAltIsBackspaceLayer()")
				and RegExMatch(Variant.HotIf, "(?<!not )LayerEnabled")
				and Variant.Prefix == "*")
			Swallowers++
	}
	AssertEqual(1, Swallowers,
		"LAlt tapping Backspace with the layer on hold must be swallowed, without ~, while the layer is on")
}
Test("tap-hold admission: LAlt tapping Backspace is swallowed while another key holds the navigation layer (layer-under-layer)",
	_THAM_LAltSwallowedUnderAnotherLayerHolder)

_THAM_NativeKeysStayNativeUnderAHeldModifier() {
	Src := _StripFullLineComments(_DriverDirConcat("platform/remap"))
	Assert(Src != "", "the tap-hold sources must be readable")
	Offenders := _THAM_NativeWildcards(Src, &Subjects)
	AssertEqual("", Offenders,
		"Tab, Space, Enter, Escape, Backspace and Delete must stay the key itself under a held modifier, as on Linux and macOS")
	Assert(Subjects >= 20, "every tap-hold variant of the six native keys must be scanned, got " . Subjects)
}
Test("tap-hold admission: Tab, Space, Enter, Escape, Backspace and Delete stay native under a held modifier (native-under-modifier-parity-2026-09-25)",
	_THAM_NativeKeysStayNativeUnderAHeldModifier)

; Every tap-hold key, not only the six native ones: under a layer hold none of a
; modifier key's own variants is eligible any more, so its repeat fell to the
; navigation layer's mapping of the same key (CapsLock held as the layer
; repeated the layer's Backspace) or reached the system (owned-press-repeat-all-2026-09-25).
_THAM_EveryTapHoldKeySwallowsItsOwnedRepeat() {
	global _TH_TapHoldScToKeyId
	Src := _StripFullLineComments(_DriverDirConcat("platform/remap"))
	Assert(Src != "", "the tap-hold sources must be readable")
	Checked := 0
	for Sc, KeyId in _TH_TapHoldScToKeyId {
		ScanCode := Format("SC{:03X}", Sc)
		Gate := '#HotIf TapHoldPressIsOwned("' . KeyId . '")'
		Found := false
		for _, Variant in _THAM_Variants(Src, ScanCode) {
			if (Variant.HotIf == Gate and Variant.Prefix == "*")
				Found := true
		}
		Assert(Found, KeyId . " must swallow its own auto-repeat with a *" . ScanCode
			. " hotkey under " . Gate . ", or the repeat reaches the application or the navigation layer")
		Checked++
	}
	AssertEqual(14, Checked, "every tap-hold key must be checked")
}
Test("tap-hold admission: every tap-hold key's owned press swallows its own auto-repeat (owned-press-repeat-all-2026-09-25)",
	_THAM_EveryTapHoldKeySwallowsItsOwnedRepeat)

; A swallower wins over the navigation layer's mapping of its key only because
; AutoHotkey fires the first eligible variant in definition order.
_THAM_SwallowersPrecedeTheLayerMappings() {
	Src := _StripFullLineComments(_DriverSourceConcat())
	Assert(Src != "", "the driver source must be readable")
	LayerAt := InStr(Src, "#Include remap/nav_layer.ahk")
	Assert(LayerAt > 0, "the tap-hold aggregate must include the navigation layer")
	Modules := 0
	Pos := 1
	while (At := RegExMatch(Src, "m)^#Include remap/(\w+)\.ahk", &Include, Pos)) {
		Pos := At + Include.Len
		if (Include[1] == "nav_layer")
			continue
		Modules++
		Assert(At < LayerAt, Include[1] . ".ahk must be included before nav_layer.ahk, or the layer maps its owned repeat")
	}
	Assert(Modules >= 14, "every tap-hold key module must be checked, got " . Modules)
}
Test("tap-hold admission: owned-repeat swallowers precede the layer mappings (owned-press-repeat-all-2026-09-25)",
	_THAM_SwallowersPrecedeTheLayerMappings)

; The Kana layout's AltGr is VK_OEM_8, which AutoHotkey does not count as a
; modifier: under it no modifier was down for the hook, the variants without *
; matched, and AltGr+Tab ran the Tab tap action (the window switcher) instead of
; the layout's AltGr+Tab (kana-altgr-native-keys-2026-09-26). Every tap-hold
; variant of the six keys therefore asks TapHoldKanaAltGrHeld, and the owned
; repeat swallowers do not: a press already owned keeps swallowing its repeat.
_THAM_NativeKeysStayNativeUnderTheKanaAltGr() {
	global _THAM_NATIVE_KEY_PATTERN
	Src := _StripFullLineComments(_DriverDirConcat("platform/remap"))
	Subjects := 0
	Missing := ""
	for _, Variant in _THAM_Variants(Src, _THAM_NATIVE_KEY_PATTERN) {
		if InStr(Variant.HotIf, "TapHoldPressIsOwned(") {
			AssertFalse(InStr(Variant.HotIf, "TapHoldKanaAltGrHeld()") > 0,
				Variant.Label . ": an owned press must keep swallowing its repeat under AltGr")
			continue
		}
		if !InStr(Variant.HotIf, "not LayerEnabled")
			continue
		Subjects++
		if !InStr(Variant.HotIf, "not TapHoldKanaAltGrHeld()")
			Missing .= (Missing = "" ? "" : ", ") . Variant.Label
	}
	AssertEqual("", Missing, "these native-key tap-holds still fire under the Kana AltGr")
	Assert(Subjects >= 20, "every tap-hold variant of the six native keys must be scanned, got " . Subjects)
}
Test("tap-hold admission: the six native keys stay native under the Kana AltGr (kana-altgr-native-keys-2026-09-26)",
	_THAM_NativeKeysStayNativeUnderTheKanaAltGr)

; A stand-in for the logical key state where only the layout's AltGr is down,
; when Down is true. (A closure over a for-loop variable is not captured.)
_THAM_AltGrStateFn(Down) {
	return (Name) => Down and Name == KS_AltGrKeyName()
}

_THAM_KanaAltGrHeldReadsTheLayoutAltGr() {
	global _TapHoldModifierIsHeld
	SavedHeld := _TapHoldModifierIsHeld
	try {
		for _, Kana in [true, false] {
			Family := _TestSetAltGrFamily(Kana)
			try {
				for _, Down in [true, false] {
					_TapHoldModifierIsHeld := _THAM_AltGrStateFn(Down)
					AssertEqual(Kana and Down, TapHoldKanaAltGrHeld(),
						(Kana ? "Kana" : "standard") . " layout, AltGr " . (Down ? "held" : "up")
						. ": only a held Kana AltGr is a modifier AutoHotkey does not count")
				}
			} finally _TestRestoreAltGrFamily(Family)
		}
		; A tap under the Kana AltGr keeps it (Send never lifts VK_OEM_8), so its
		; payload stays bare, the Backspace the hotstring buffer recognizes.
		Family := _TestSetAltGrFamily(true)
		try {
			_TapHoldModifierIsHeld := (Name) => Name == KS_AltGrKeyName()
			AssertFalse(TapHoldAnyModifierHeld(), "a tap under the Kana AltGr alone needs no {Blind}")
		} finally _TestRestoreAltGrFamily(Family)
	} finally {
		_TapHoldModifierIsHeld := SavedHeld
	}
}
Test("tap-hold admission: TapHoldKanaAltGrHeld is true for a held Kana AltGr only (kana-altgr-native-keys-2026-09-26)",
	_THAM_KanaAltGrHeldReadsTheLayoutAltGr)
