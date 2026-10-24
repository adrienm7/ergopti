; tests/unit/adapters/test_keyboard_layout_switch.ahk

; ==============================================================================
; MODULE: Keyboard Layout Switch Adapter
; DESCRIPTION:
; KLS_LayoutId, KLS_Choices and KLS_Select through fake list, registry and
; post ports: a layout is offered and selected by its KLID, a custom layout id
; is resolved through the registry, and a refusal is false, never a pretended
; switch.
; ==============================================================================

#Requires AutoHotkey v2.0




; French, US, and a custom layout (layout id 00c0) installed for French.
global _KLST_HKLS := [0x040C040C, 0x04090409, 0xF0C0040C, 0x0809040C]

_KLST_Lookup(LayoutIdHex) {
	return LayoutIdHex == "00c0" ? "A000040C" : ""
}

_KLST_Label(Klid) {
	return "label " . Klid
}

/** A standard handle names its KLID, a custom one is looked up. */
_KLST_LayoutIds() {
	AssertEqual("0000040C", KLS_LayoutId(0x040C040C, _KLST_Lookup))
	AssertEqual("00000809", KLS_LayoutId(0x0809040C, _KLST_Lookup), "a device id that is not the language")
	AssertEqual("A000040C", KLS_LayoutId(0xF0C0040C, _KLST_Lookup))
	AssertEqual("", KLS_LayoutId(0xF0D0040C, _KLST_Lookup), "an unknown custom id has no KLID")
	AssertThrows(() => KLS_LayoutId(0, _KLST_Lookup), "a null handle is refused")
}

/** Choices keep Windows' order, skip an unresolved layout and a duplicate KLID. */
_KLST_Choices() {
	global _KLST_HKLS
	Hkls := _KLST_HKLS.Clone()
	Hkls.Push(0xF0D0040C, 0x040C0809)
	Choices := KLS_Choices(() => Hkls, _KLST_Lookup, _KLST_Label)
	AssertEqual(4, Choices.Length, "the unresolved custom layout is left out")
	AssertEqual("0000040C", Choices[1]["id"])
	AssertEqual("label 0000040C", Choices[1]["label"])
	AssertEqual("A000040C", Choices[3]["id"])
	AssertEqual(0xF0C0040C, Choices[3]["hkl"], "the handle is kept for the switch")
	AssertEqual("00000809", Choices[4]["id"])
	AssertEqual(0x040C040C, Choices[1]["hkl"], "the first handle of a KLID wins over 0x040C0809")
}

/** A select posts the installed handle of its KLID, once. */
_KLST_Select() {
	global _KLST_HKLS
	Posted := []
	AssertEqual(1, KLS_Select("A000040C", () => _KLST_HKLS, (Hkl) => Posted.Push(Hkl), _KLST_Lookup))
	AssertEqual(1, Posted.Length)
	AssertEqual(0xF0C0040C, Posted[1])
}

/** A layout that is not installed and a refused post are false. */
_KLST_Refusals() {
	global _KLST_HKLS
	Posted := []
	AssertFalse(KLS_Select("00000407", () => _KLST_HKLS, (Hkl) => Posted.Push(Hkl), _KLST_Lookup),
		"German is not installed")
	AssertEqual(0, Posted.Length, "nothing is posted for a missing layout")
	Throwing(Hkl) {
		throw TargetError("no foreground window")
	}
	AssertFalse(KLS_Select("0000040C", () => _KLST_HKLS, Throwing, _KLST_Lookup),
		"an undeliverable request is a refusal")
	AssertThrows(() => KLS_Select("", () => _KLST_HKLS, Throwing, _KLST_Lookup), "an empty id is refused")
}

Test("keyboard layout switch: KLID of standard and custom layouts", _KLST_LayoutIds)
Test("keyboard layout switch: installed choices", _KLST_Choices)
Test("keyboard layout switch: select posts the installed handle", _KLST_Select)
Test("keyboard layout switch: refusals are false", _KLST_Refusals)
