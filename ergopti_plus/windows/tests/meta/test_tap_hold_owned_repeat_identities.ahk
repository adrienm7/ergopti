; tests/meta/test_tap_hold_owned_repeat_identities.ahk

; ==============================================================================
; MODULE: An owned press swallows its auto-repeat under every modifier chord
; DESCRIPTION:
; Tab, Space, Enter, Escape, Backspace and Delete fire their tap-hold only with
; no modifier held, so their own auto-repeat arrives under the modifier the
; hold owns. A * swallower gated on the owned press was meant to catch it, but
; AutoHotkey prefers a hotkey whose modifiers match exactly to a wildcard one:
; Space held as Shift repeated the layout emulation's Shift+Space hotkey and
; typed « ------ » (owned-repeat-exact-chord-2026-10-01). Under a layer hold
; the repeat is the bare key, which the emulation's own bare hotkey typed.
; Each of the six keys therefore declares, under its owned-press gate, the bare
; key and every chord of Ctrl, Alt, Shift and Win beside the wildcard: a
; static variant is created before every Hotkey() one, and AutoHotkey fires the
; first eligible variant of an identity (measured with AutoHotkey 2.0, F20:
; the static variant fired while its criterion was true, the dynamic one
; otherwise).
; ==============================================================================

#Requires AutoHotkey v2.0

; Scan code and tap-hold id of the six keys that stay native under a modifier.
global _THOR_NATIVE_KEYS := Map("SC00F", "tab", "SC039", "space", "SC01C", "enter",
	"SC001", "escape", "SC00E", "backspace", "SC153", "delete")

; A hotkey's modifier symbols in one canonical order, so "+^" and "^+" are one
; identity, as they are for AutoHotkey. "*" stays apart: it is the wildcard.
_THOR_Chord(Prefix) {
	Chord := ""
	for _, Symbol in ["*", "^", "!", "+", "#"] {
		if InStr(Prefix, Symbol)
			Chord .= Symbol
	}
	return Chord
}

; Every chord of Ctrl, Alt, Shift and Win, the bare key included.
_THOR_AllChords() {
	Chords := []
	loop 16 {
		Mask := A_Index - 1
		Chord := ""
		for Bit, Symbol in ["^", "!", "+", "#"] {
			if (Mask & (1 << (Bit - 1)))
				Chord .= Symbol
		}
		Chords.Push(Chord)
	}
	return Chords
}

; The chords Src declares for ScanCode under KeyId's owned-press gate.
; @return {Map} Canonical chord -> true.
_THOR_OwnedChords(Src, ScanCode, KeyId) {
	Gate := '#HotIf TapHoldPressIsOwned("' . KeyId . '")'
	Declared := Map()
	for _, Variant in _THAM_Variants(Src, ScanCode) {
		if (Variant.HotIf == Gate)
			Declared[_THOR_Chord(Variant.Prefix)] := true
	}
	return Declared
}

_THOR_ScannerReadsStackedLabels() {
	Fixture := '#HotIf TapHoldPressIsOwned("space")`n*SC039::`nSC039::`n+^SC039::`n{`n`treturn`n}`n#HotIf`n'
		. "#HotIf Other()`n!SC039:: return`n"
	Declared := _THOR_OwnedChords(Fixture, "SC039", "space")
	AssertEqual(3, Declared.Count, "only the labels under the owned-press gate count")
	Assert(Declared.Has("*") and Declared.Has("") and Declared.Has("^+"),
		"stacked labels are read, and a chord's symbols in any order are one identity")
}
Test("tap-hold owned repeat: the scanner reads stacked labels as canonical chords (owned-repeat-exact-chord-2026-10-01)",
	_THOR_ScannerReadsStackedLabels)

_THOR_NativeKeysSwallowEveryChord() {
	global _THOR_NATIVE_KEYS
	Src := _StripFullLineComments(_DriverDirConcat("platform/remap"))
	Assert(Src != "", "the tap-hold sources must be readable")
	Missing := ""
	for ScanCode, KeyId in _THOR_NATIVE_KEYS {
		Declared := _THOR_OwnedChords(Src, ScanCode, KeyId)
		Assert(Declared.Has("*"), KeyId . " must keep its wildcard swallower")
		for _, Chord in _THOR_AllChords() {
			if !Declared.Has(Chord)
				Missing .= (Missing = "" ? "" : ", ") . Chord . ScanCode
		}
	}
	AssertEqual("", Missing,
		"an owned press must swallow its auto-repeat under these exact chords too: a hotkey whose modifiers match exactly beats the wildcard swallower")
}
Test("tap-hold owned repeat: the six native keys swallow their repeat under every chord (owned-repeat-exact-chord-2026-10-01)",
	_THOR_NativeKeysSwallowEveryChord)

; The root cause, from the registrants' side: every exact hotkey the layout
; emulation and the Ergopti Shift layer register on a tap-hold key's scan code
; has an owned-press variant of the same identity.
_THOR_EmulationHotkeysAreCovered() {
	global KLE_Registered, _TH_TapHoldScToKeyId, SHIFT_SYMBOLS, SHIFTED_LETTERS
	Src := _StripFullLineComments(_DriverDirConcat("platform/remap"))
	Assert(Src != "", "the tap-hold sources must be readable")
	Names := []
	Saved := KLE_Registered
	KLE_Registered := false
	try KeylayoutEmulation_Register(LayoutRegistry_Keycodes(), (Name, *) => Names.Push(Name), (*) => 0)
	finally KLE_Registered := Saved
	if !IsObject(SHIFT_SYMBOLS)
		_BuildShiftCapsTables()
	for _, Table in [SHIFT_SYMBOLS, SHIFTED_LETTERS] {
		for ScanCode in Table
			Names.Push("+" . ScanCode)
	}
	Checked := 0
	Uncovered := ""
	for _, Name in Names {
		; A custom combination ("A & B") needs its prefix key physically down,
		; which a synthetic hold is not: it is no exact-chord hotkey.
		if InStr(Name, "&") or !RegExMatch(Name, "^([~$*#!^+<>]*)(SC[0-9A-F]{3})$", &Parts)
			continue
		Sc := Integer("0x" . SubStr(Parts[2], 3))
		if !_TH_TapHoldScToKeyId.Has(Sc)
			continue
		Checked++
		Declared := _THOR_OwnedChords(Src, Parts[2], _TH_TapHoldScToKeyId[Sc])
		if !Declared.Has(_THOR_Chord(Parts[1]))
			Uncovered .= (Uncovered = "" ? "" : ", ") . Name
	}
	AssertEqual("", Uncovered,
		"these layout hotkeys fire on a tap-hold key's own auto-repeat while its hold is owned (Space held as Shift typed the layout's Shift+Space)")
	Assert(Checked >= 3, "the emulation's Space, Shift+Space and the Shift layer's Shift+Space must be checked, got " . Checked)
}
Test("tap-hold owned repeat: every layout hotkey on a tap-hold key has an owned-press variant (owned-repeat-exact-chord-2026-10-01)",
	_THOR_EmulationHotkeysAreCovered)
