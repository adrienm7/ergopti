; tests/meta/test_nav_layer_admits_held_modifiers.ahk

; ==============================================================================
; MODULE: The navigation layer maps its keys under a held modifier
; DESCRIPTION:
; A hotkey without the * wildcard does not fire while any extra modifier is
; down. Every navigation-layer hotkey lacked it, so with Shift (or a tap-hold's
; synthetic Ctrl) held while the layer was on, the physical key ran its native
; function instead of its layer mapping: the layer's CapsLock toggled Caps Lock
; under Shift instead of deleting a character (measured with AutoHotkey 2.0.26).
; The Linux engine maps a layer key whatever is held and the held modifiers
; combine with its chord (tap_hold_engine.lua press_layer_key): Shift held and
; the layer's Left select. ActionLayer therefore sends under {Blind} whenever a
; modifier is held, and keeps the bare payload otherwise, which the hotstring
; buffers recognize exactly (nav-layer-held-modifier-2026-09-25).
; ==============================================================================

#Requires AutoHotkey v2.0

; Static hotkey labels governed by a #HotIf that requires the layer on, without
; the * wildcard. Custom combinations ("A & B") act as wildcards.
_NLHM_Offenders(Src, &Subjects) {
	Subjects := 0
	Offenders := ""
	HotIf := ""
	Depth := 0
	Loop Parse, Src, "`n", "`r" {
		Line := Trim(A_LoopField)
		if (Depth > 0) {
			HotIf .= " " . Line
			Depth += _NLHM_ParenBalance(Line)
			continue
		}
		if (SubStr(Line, 1, 6) = "#HotIf") {
			HotIf := Line
			Depth := _NLHM_ParenBalance(Line)
			continue
		}
		if !RegExMatch(Line, "^([~$*#!^+<>]*)([A-Za-z][A-Za-z0-9_]*)(?: Up)?::", &Label)
			continue
		if !InStr(HotIf, "LayerEnabled") or InStr(HotIf, "not LayerEnabled")
			continue
		Subjects++
		if !InStr(Label[1], "*")
			Offenders .= (Offenders = "" ? "" : ", ") . Label[0]
	}
	return Offenders
}

_NLHM_ParenBalance(Line) {
	return StrLen(Line) - StrLen(StrReplace(Line, "(")) - (StrLen(Line) - StrLen(StrReplace(Line, ")")))
}

_NLHM_ScannerFindsTheExactMatchShape() {
	Fixture := "#HotIf LayerEnabled`n" . 'SC025:: ActionLayer("{Left}")' . "`n*SC026:: return`n"
		. "SC01D & ~SC138::`n*WheelUp:: return`n"
		. "#HotIf (`n`tLayerEnabled`n`tand x`n)`nSC03A:: return`n"
		. '#HotIf TapHoldHoldLayer(TapHold, "tab") != "" and not LayerEnabled' . "`n$SC00F:: return`n"
	Offenders := _NLHM_Offenders(Fixture, &Subjects)
	AssertEqual("SC025::, SC03A::", Offenders,
		"the scanner must flag a layer hotkey that needs an exact modifier match, including under a multi-line #HotIf")
	AssertEqual(4, Subjects, "tap-hold variants that require the layer off are not layer hotkeys")
}
Test("nav layer: the scanner flags a layer hotkey without the wildcard (nav-layer-held-modifier-2026-09-25)",
	_NLHM_ScannerFindsTheExactMatchShape)

_NLHM_EveryLayerHotkeyFiresUnderAHeldModifier() {
	Src := _StripFullLineComments(_DriverDirConcat("platform/remap"))
	Assert(Src != "", "the tap-hold sources must be readable")
	; Scan both the remaining static special cases and the dynamic labels the
	; recommended file actually registers. The source alone now has only two.
	SharedDir := A_ScriptDir . "\..\..\_shared"
	Ctx := KeymapLayers_LoadContext(SharedDir)
	Result := KeymapLayers_Load("windows", Ctx, FileRead(SharedDir . "\keymap\layers.recommended.toml", "UTF-8"))
	Assert(Result["ok"], "the recommended navigation layer must resolve")
	Src .= "`n#HotIf LayerEnabled`n"
	for Row in NavLayer_BuildTable(Result["layers"][NAV_LAYER_ID], Ctx)
		Src .= Row["hotkey"] . ":: return`n"
	Offenders := _NLHM_Offenders(Src, &Subjects)
	AssertEqual("", Offenders,
		"under a held modifier these layer keys run their native function instead of their layer mapping")
	Assert(Subjects >= 40, "every navigation-layer hotkey must be scanned, got " . Subjects)
}
Test("nav layer: every layer hotkey maps its key under a held modifier (nav-layer-held-modifier-2026-09-25)",
	_NLHM_EveryLayerHotkeyFiresUnderAHeldModifier)

global _NLHM_Sent := []
global _NLHM_Held := Map()

_NLHM_WithStubs(Held, Body) {
	global _AHK_SendInput, _TapHoldModifierIsHeld, _NLHM_Sent, _NLHM_Held
	SavedSend := _AHK_SendInput
	SavedHeld := _TapHoldModifierIsHeld
	_NLHM_Sent := []
	_NLHM_Held := Held
	_AHK_SendInput := (Keys) => _NLHM_Sent.Push(Keys)
	_TapHoldModifierIsHeld := (Name) => _NLHM_Held.Has(Name)
	try
		Body.Call()
	finally {
		_AHK_SendInput := SavedSend
		_TapHoldModifierIsHeld := SavedHeld
	}
}

_NLHM_ActionLayerKeepsAHeldModifier() {
	global _NLHM_Sent
	_NLHM_WithStubs(Map("LShift", true), () => ActionLayer("{Left 2}"))
	AssertEqual(1, _NLHM_Sent.Length, "one layer action must send once")
	AssertEqual("{Blind}{Left 2}", _NLHM_Sent[1],
		"Shift held and the layer's Left must select, as on Linux: the held modifier combines with the layer chord")
	_NLHM_WithStubs(Map("RCtrl", true), () => ActionLayer("+{Home}"))
	AssertEqual("{Blind}+{Home}", _NLHM_Sent[1],
		"a layer chord keeps its own modifiers and adds the held ones")
}
Test("nav layer: a layer action keeps the modifiers held around it (nav-layer-held-modifier-2026-09-25)",
	_NLHM_ActionLayerKeepsAHeldModifier)

_NLHM_ActionLayerBareWithoutModifier() {
	global _NLHM_Sent
	_NLHM_WithStubs(Map(), () => ActionLayer("{BackSpace 3}"))
	AssertEqual(1, _NLHM_Sent.Length, "one layer action must send once")
	AssertEqual("{BackSpace 3}", _NLHM_Sent[1],
		"with nothing held the payload stays bare, the exact shape the hotstring buffers track as a deletion")
}
Test("nav layer: a layer action stays bare with no modifier held (nav-layer-held-modifier-2026-09-25)",
	_NLHM_ActionLayerBareWithoutModifier)
