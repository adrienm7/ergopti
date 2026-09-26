; tests/meta/test_altgr_prefix_arms_on_press.ahk

; ==============================================================================
; MODULE: The AltGr prefix arms on its own press
; DESCRIPTION:
; AutoHotkey decides whether a prefix key is armed while it handles that key's
; own press (hook.cpp Case #1, Hotkey::PrefixHasEnabledSuffixes evaluates the
; suffixes' #HotIf criteria), before it records a modifier's physical state.
; Every "SC138 & X" combination gated on IsRealAltGrPress, which reads the
; physical AltGr, so on QWERTY (no AltGr fake LCtrl) the prefix never armed on a
; press: AltGr+E typed Alt+E and the AltGr layer only worked after the key's
; auto-repeat (qwerty-altgr-prefix-2026-09-26). Where the prefix did arm (every
; Kana press), SC138 was a suppressed prefix with enabled suffixes, so AHK
; postponed every standalone SC138 hotkey without ~ to the release: AltGr held
; as Ctrl never pressed Ctrl, a 2 s hold still tapped, the navigation Escape
; came on release (kana-altgr-fires-on-release-2026-09-26). An always-eligible
; combination with ~ on the prefix fixes both: the prefix arms on every press
; and the standalone hotkeys fire on the press (hook.cpp: "If
; suppress_this_prefix == false, this prefix key's key-down hotkey should fire
; immediately"). No input can drive the hook here, so the source is pinned.
; ==============================================================================

#Requires AutoHotkey v2.0

; Text of the #HotIf line governing the declaration found at Pos in Src.
_APAP_GoverningHotIf(Src, Pos) {
	HotIfPos := 0
	ScanAt := 1
	while (Found := InStr(Src, "#HotIf", , ScanAt)) && (Found < Pos) {
		HotIfPos := Found
		ScanAt := Found + 1
	}
	if !HotIfPos
		return ""
	return Trim(SubStr(Src, HotIfPos, InStr(Src, "`n", , HotIfPos) - HotIfPos), " `t`r")
}

_APAP_AnchorArmsThePrefixOnEveryPress() {
	Src := _StripFullLineComments(_DriverDirConcat("platform/remap"))
	Anchor := RegExMatch(Src, "m)^~SC138 & ~F24::")
	AssertTrue(Anchor > 0,
		"an always-eligible combination with ~ on the SC138 prefix must arm the AltGr prefix on its own press")
	AssertEqual("#HotIf", _APAP_GoverningHotIf(Src, Anchor),
		"the anchor must have no criterion: a criterion is evaluated at the press, where the physical AltGr is not known yet")
	Registered := 0
	Pos := 1
	Everything := _DriverSourceNoComments()
	while (At := RegExMatch(Everything, 'Hotkey\(\s*(?:_ScriptAltGrHookKey\()?"SC138 & ', , Pos)) {
		Registered += 1
		Pos := At + 1
	}
	AssertTrue(Registered >= 4, "the AltGr combinations the anchor arms for must still be registered (found " . Registered . ")")
}
Test("altgr prefix: an always-eligible pass-through combination arms SC138 on its press (qwerty-altgr-prefix-2026-09-26)",
	_APAP_AnchorArmsThePrefixOnEveryPress)

_APAP_SuspendDrainWaitsForAltGrOnEveryLayout() {
	for _, Name in ["_SuspendPrefixesAreClear", "_SuspendHeldPrefixKeys"] {
		Body := _DriverFuncBody(Name)
		AssertFalse(InStr(Body, "_ALTGR_KANA_FIXUP") > 0,
			Name . " must wait for SC138 on every layout: the anchor arms it everywhere, and a prefix latched across Suspend fires the AltGr layer without AltGr")
		AssertTrue(InStr(Body, "SUSPEND_CUSTOM_COMBO_PREFIX_KEYS") > 0, Name . " must still walk the drain list")
	}
}
Test("altgr prefix: the suspend drain waits for SC138 on every layout (qwerty-altgr-prefix-2026-09-26)",
	_APAP_SuspendDrainWaitsForAltGrOnEveryLayout)
