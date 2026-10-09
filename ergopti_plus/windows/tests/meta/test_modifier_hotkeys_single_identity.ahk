; tests/meta/test_modifier_hotkeys_single_identity.ahk

; ==============================================================================
; MODULE: One hotkey identity per physical modifier key
; DESCRIPTION:
; AutoHotkey hooks a hotkey declared by a modifier NAME ("RAlt::", "RCtrl::",
; also with ~ * $ or as vkA5) on that modifier's standard scan code. It is a
; different hotkey from "SC138::" or "*$SC138::" on the same key, and when every
; variant of the name hotkey is ineligible it does not fall back to the scan-code
; hotkeys: nothing fires (measured with AutoHotkey 2.0.26). altgr.ahk and
; nav_layer.ahk declared "RAlt::" for standard layouts beside the SC138 hotkeys
; for Kana-style layouts, so on a Kana layout every SC138 hotkey was silenced:
; the AltGr tap-hold never ran and the navigation layer's AltGr Escape was lost
; (altgr-single-identity-2026-09-25). "RAlt Up::" and "RAlt & X" combinations do
; not shadow and stay allowed.
; This test bans every standalone hotkey named by a modifier key in the driver,
; static or registered through Hotkey(), and proves its scanner on a fixture.
; ==============================================================================

#Requires AutoHotkey v2.0

global _MHSI_MODIFIER_NAMES := Map()
for _MhsiName in ["lctrl", "lcontrol", "rctrl", "rcontrol", "ctrl", "control",
		"lalt", "ralt", "alt", "lshift", "rshift", "shift", "lwin", "rwin",
		"vka0", "vka1", "vka2", "vka3", "vka4", "vka5", "vk5b", "vk5c",
		"vk10", "vk11", "vk12"]
	_MHSI_MODIFIER_NAMES[_MhsiName] := true

; Key part of a hotkey declaration without its prefix symbols or " Up" suffix,
; lowercased; "" for a custom combination ("A & B"), which never shadows.
_MHSI_StandaloneKey(Declaration) {
	if InStr(Declaration, "&")
		return ""
	Key := RegExReplace(Trim(Declaration), "i)\s+up$")
	Key := LTrim(Key, "~*$#!^+<>")
	return StrLower(Trim(Key))
}

; Every standalone hotkey declared in Code, both static labels and literal
; Hotkey() registrations: Map of lowercased key -> first declaration seen.
; @param Code {String} Source with comments masked; strings kept for Hotkey().
; @param Masked {String} The same source with strings masked too.
_MHSI_StandaloneHotkeys(Code, Masked, &StaticCount, &DynamicCount) {
	Found := []
	StaticCount := 0
	DynamicCount := 0
	Position := 1
	while (At := RegExMatch(Masked, "im)^[ \t]*([~*$#!^+<>]*[A-Za-z][A-Za-z0-9]*(?:[ \t]*&[ \t]*~?[A-Za-z][A-Za-z0-9]*)?(?:[ \t]+up)?)[ \t]*::", &Label, Position)) {
		Position := At + Label.Len
		StaticCount++
		Key := _MHSI_StandaloneKey(Label[1])
		if (Key != "")
			Found.Push(Label[1])
	}
	Position := 1
	Quotes := Chr(34) . "'"
	while (At := RegExMatch(Code, "Hotkey\(\s*(?:[A-Za-z_]\w*\(\s*)?([" . Quotes . "])([^" . Quotes . "]*)\1(?=\s*[,)])", &Call, Position)) {
		Position := At + Call.Len
		DynamicCount++
		Key := _MHSI_StandaloneKey(Call[2])
		if (Key != "")
			Found.Push(Call[2])
	}
	return Found
}

_MHSI_Offenders(Declarations) {
	global _MHSI_MODIFIER_NAMES
	Offenders := ""
	for Declaration in Declarations {
		if _MHSI_MODIFIER_NAMES.Has(_MHSI_StandaloneKey(Declaration))
			Offenders .= (Offenders = "" ? "" : ", ") . Declaration
	}
	return Offenders
}

_MHSI_ScannerFindsTheShadowingShape() {
	Fixture := "#HotIf false`nRAlt::`nRAlt Up:: return`n#HotIf`n*$SC138:: return`n"
		. "SC01D & SC138::`nx := 1`n"
		. 'Hotkey("RAlt & Enter", Fn)' . "`n"
		. 'Hotkey("~*RCtrl", Fn)' . "`n"
	Masked := Fixture
	Found := _MHSI_StandaloneHotkeys(Fixture, Masked, &LabelCount, &CallCount)
	AssertEqual("RAlt, RAlt Up, ~*RCtrl", _MHSI_Offenders(Found),
		"the scanner must flag standalone modifier-name hotkeys, static and dynamic, and nothing else")
}
Test("hotkeys: the modifier-identity scanner flags exactly the shadowing shapes (altgr-single-identity-2026-09-25)",
	_MHSI_ScannerFindsTheShadowingShape)

_MHSI_NoModifierNameStandaloneHotkey() {
	Src := _DriverSourceConcat()
	Assert(Src != "", "the driver source must be readable for the modifier-identity meta-test")
	Masked := _DriverMaskNonCode(&Src)
	Code := _StripFullLineComments(Src)
	Found := _MHSI_StandaloneHotkeys(Code, Masked, &LabelCount, &CallCount)
	Assert(LabelCount > 100, "the scan must see the driver's static hotkeys, found " . LabelCount)
	Assert(CallCount > 20, "the scan must see the driver's Hotkey() registrations, found " . CallCount)
	SawScanCodeModifier := false
	for Declaration in Found {
		if (_MHSI_StandaloneKey(Declaration) = "sc138")
			SawScanCodeModifier := true
	}
	Assert(SawScanCodeModifier, "the AltGr key must still be declared by its scan code")
	AssertEqual("", _MHSI_Offenders(Found),
		"declare a modifier key's standalone hotkeys by scan code only: a name such as RAlt:: shadows the scan-code hotkeys of the same key whenever its own #HotIf is false")
}
Test("hotkeys: no standalone hotkey is declared by a modifier name (altgr-single-identity-2026-09-25)",
	_MHSI_NoModifierNameStandaloneHotkey)
