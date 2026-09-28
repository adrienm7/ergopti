; tests/unit/test_gesture_recommended_actions.ahk

; ==============================================================================
; MODULE: Recommended Gesture Actions Come From The Manifest
; DESCRIPTION:
; « Restaurer les valeurs conseillées » under Gestures writes
; GESTURE_FACTORY_DEFAULTS to every slot. That map was a hand copy of the
; manifest's Windows values, with a comment promising it mirrored them and
; nothing holding it to the promise; the macOS twin had already drifted. It is
; built from the manifest now, and this checks every slot against the generated
; manifest entry directly.
; ==============================================================================

#Requires AutoHotkey v2.0

_GRA_EverySlotIsTheManifestValue() {
	global GESTURE_FACTORY_DEFAULTS, FEATURES_MANIFEST
	Expected := Map()
	for Entry in FEATURES_MANIFEST["features"] {
		if (Entry["section"] == "gestures" and Entry["type"] == "action")
			Expected[Entry["id"]] := Entry["recommended"]
	}
	Slots := GestureSlotIds()
	Assert(Slots.Length >= 10, "GestureSlotIds() must list every Windows slot, got " . Slots.Length)
	AssertEqual(Slots.Length, GESTURE_FACTORY_DEFAULTS.Count,
		"GESTURE_FACTORY_DEFAULTS must hold exactly the Windows slots")
	for Slot in Slots {
		Assert(Expected.Has(Slot), "the manifest must declare a Windows default for gestures." . Slot)
		Assert(GESTURE_FACTORY_DEFAULTS.Has(Slot), "GESTURE_FACTORY_DEFAULTS must cover " . Slot)
		AssertEqual(Expected[Slot], GESTURE_FACTORY_DEFAULTS[Slot],
			"gestures." . Slot . " must be the manifest's Windows recommended action")
	}
	AssertEqual("none", ManifestDefaultFor("gestures.tap_3"), "startup stays neutral")
	AssertEqual("left_click_toggle", GESTURE_FACTORY_DEFAULTS["tap_3"], "explicit restore remains useful")
}
Test("gestures: the recommended actions are the manifest's Windows values (gesture-defaults-single-source)",
	_GRA_EverySlotIsTheManifestValue)
