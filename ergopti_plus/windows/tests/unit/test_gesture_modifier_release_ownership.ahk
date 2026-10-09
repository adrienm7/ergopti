; tests/unit/test_gesture_modifier_release_ownership.ahk

; ==============================================================================
; MODULE: Gesture Modifier Release Ownership Tests
; DESCRIPTION:
; Proves gesture cleanup releases only synthetic carrier modifiers and preserves
; every physically held user modifier, including modifiers outside the carrier.
; ==============================================================================

#Requires AutoHotkey v2.0

global _GMRO_Logical := Map()
global _GMRO_Physical := Map()
global _GMRO_Emissions := []

_GMRO_State(Key, Mode := "") {
		global _GMRO_Logical, _GMRO_Physical
		return Mode == "P"
				? _GMRO_Physical.Get(Key, false)
				: _GMRO_Logical.Get(Key, false)
}

_GMRO_Emit(Payload) {
		global _GMRO_Emissions
		_GMRO_Emissions.Push(Payload)
}

_GMRO_PreservesPhysicalOwnership() {
		global _GMRO_Logical, _GMRO_Physical, _GMRO_Emissions
		_GMRO_Logical := Map("RShift", true, "LShift", true, "RAlt", true)
		_GMRO_Physical := Map("RShift", true, "LShift", false, "RAlt", true)
		_GMRO_Emissions := []

		AssertTrue(GestureReleaseOwnedCarrierModifiers(_GMRO_State, _GMRO_Emit))
		AssertEqual(1, _GMRO_Emissions.Length,
				"one owned synthetic release batch must be emitted")
		AssertEqual("{Blind}{LShift Up}", _GMRO_Emissions[1],
				"physically held RShift and non-carrier RAlt must remain untouched")
}
Test("gestures: modifier cleanup preserves physical ownership", _GMRO_PreservesPhysicalOwnership)

_GMRO_NoOwnedModifierNeedsRelease() {
		global _GMRO_Logical, _GMRO_Physical, _GMRO_Emissions
		_GMRO_Logical := Map("RShift", true)
		_GMRO_Physical := Map("RShift", true)
		_GMRO_Emissions := []

		AssertTrue(GestureReleaseOwnedCarrierModifiers(_GMRO_State, _GMRO_Emit))
		AssertEqual(0, _GMRO_Emissions.Length,
				"no synthetic input is needed when every logical modifier is physical")
}
Test("gestures: physical-only carrier state emits no release", _GMRO_NoOwnedModifierNeedsRelease)
