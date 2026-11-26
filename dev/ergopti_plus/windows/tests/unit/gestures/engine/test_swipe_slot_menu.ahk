; tests/unit/gestures/engine/test_swipe_slot_menu.ahk

; ==============================================================================
; MODULE: Windows Swipe Slot Menu (modes and steps)
; DESCRIPTION:
; Each Windows swipe slot opens the shared gesture_swipe_slot_menu template,
; as on macOS: its action picker, its mode (x1 or incremental) and its step in
; millimetres, which only an incremental slot uses. The rows come from the
; shared templates, the steps from the shared choices, and a choice persists
; through the real configuration transaction (an injected writer, no file).
;
; ROOT CAUSE ENCODED:
; The Windows rows were greyed with
; platform_reason.gesture_modes_and_steps_need_finger_travel: the driver saw
; no finger travel. The raw touchpad reader now follows the fingers.
; ==============================================================================

#Requires AutoHotkey v2.0

; Runs Body with a gestures configuration that has modes and steps.
_GSSM_With(Body) {
	global Features
	Saved := Features["gestures"]
	Features["gestures"] := Map("enabled", true,
		"modes", Map("swipe_3_left", "incremental", "swipe_3_up", "x1"),
		"sensitivities", Map("swipe_3_left", 5.0, "swipe_3_up", 25))
	try Body.Call()
	finally Features["gestures"] := Saved
}

_GSSM_IncrementalSlot() {
	Picked := []
	Items := _GES_SwipeSlotItems("swipe_3_left", (*) => Picked.Push("picker"), true)
	AssertTrue(Items is Array, "the swipe template renders for Windows")
	AssertEqual(4, Items.Length, "change action, separator, mode, step")
	AssertEqual(t("menu.gestures.change_action"), Items[1]["label"], "the action picker comes first")
	AssertFalse(Items[1].Get("disabled", false), "gestures on: the picker is available")
	Items[1]["action"].Call()
	AssertEqual(1, Picked.Length, "the row opens the slot's own picker")
	AssertTrue(Items[2].Get("separator", false), "then the separator")
	AssertTrue(InStr(Items[3]["label"], t("menu.gestures.mode_incremental")) > 0, "the mode caption names the mode")
	Modes := Items[3]["items"]
	AssertEqual(2, Modes.Length, "x1 and incremental")
	AssertEqual(0, Modes[1]["checked"], "x1 unchecked")
	AssertEqual(1, Modes[2]["checked"], "incremental checked")
	AssertTrue(InStr(Items[4]["label"], "5.0") > 0, "the step caption names the step")
	AssertFalse(Items[4].Get("disabled", false), "an incremental slot's step is editable")
	Steps := Items[4]["items"]
	AssertEqual(3 + GESTURE_SENSITIVITY_OPTIONS.Length, Steps.Length, "the shared head, then every shared step")
	Checked := ""
	for Row in Steps {
		if Row.Get("checked", 0)
			Checked .= Row["label"]
	}
	AssertEqual("5.0", Checked, "exactly the configured step is checked")
	AssertTrue(InStr(Steps[3 + 6]["label"], t("menu.gestures.default_sensitivity")) > 0,
		"3.5, the manifest default of swipe_3_left, says so")
}
Test("gesture menu: a Windows swipe slot offers its mode and its step (gesture-swipe-slot-menu)",
	() => _GSSM_With(_GSSM_IncrementalSlot))

_GSSM_SingleSlot() {
	Items := _GES_SwipeSlotItems("swipe_3_up", (*) => 0, true)
	AssertTrue(InStr(Items[3]["label"], t("menu.gestures.mode_single")) > 0, "x1 slot")
	AssertTrue(Items[4].Get("disabled", false), "an x1 slot's step is greyed: it does not step")
	; The manifest default of swipe_3_up is 25 mm.
	AssertTrue(InStr(Items[4]["items"][3 + 17]["label"], t("menu.gestures.default_sensitivity")) > 0, "its own default")
	Off := _GES_SwipeSlotItems("swipe_3_up", (*) => 0, false)
	AssertTrue(Off[1].Get("disabled", false), "gestures off: the picker is greyed")
	; A tap has no mode: its row opens the picker at once.
	AssertEqual("", GestureSlotMode("tap_3"), "a tap has no mode")
}
Test("gesture menu: an x1 slot greys its step and a tap keeps its picker (gesture-swipe-slot-menu)",
	() => _GSSM_With(_GSSM_SingleSlot))

_GSSM_ChoicesPersist() {
	global Features
	Observed := []
	Writer(Path, Updates) {
		Observed.Push(Updates)
		return true
	}
	AssertTrue(GestureSetSlotMode("swipe_3_up", "incremental", Writer, (*) => 0), "a mode choice commits")
	AssertEqual("incremental", Features["gestures"]["modes"]["swipe_3_up"], "and applies at once")
	AssertTrue(GestureSetSlotSensitivity("swipe_3_up", 7, Writer, (*) => 0), "a step choice commits")
	AssertEqual(7, Features["gestures"]["sensitivities"]["swipe_3_up"], "and applies at once")
	AssertEqual(2, Observed.Length, "each choice crosses the configuration transaction")
	AssertFalse(GestureSetSlotMode("swipe_3_up", "twice", Writer, (*) => 0), "an unknown mode is refused")
	AssertFalse(GestureSetSlotSensitivity("swipe_3_up", 0.5, Writer, (*) => 0), "a step out of range is refused")
	AssertFalse(GestureSetSlotMode("tap_3", "x1", Writer, (*) => 0), "a tap has no mode")
	AssertEqual(2, Observed.Length, "a refusal writes nothing")
}
; The choice crosses the real configuration transaction against a private,
; absent config.toml, as the master-gate fixtures do; the writer is injected.
_GSSM_WithPrivateConfig(Body) {
	global ConfigurationFile
	SavedPath := ConfigurationFile
	Directory := A_Temp . "\ergopti-gesture-modes-" . A_TickCount . "-" . Random(10000, 99999)
	DirCreate(Directory)
	try {
		ConfigurationFile := Directory . "\config.toml"
		Boot := ConfigMigrateBoot(ConfigurationFile)
		AssertEqual("absent", Boot["status"], "a private absent configuration")
		_GSSM_With(Body)
	} finally {
		ConfigurationFile := SavedPath
		if DirExist(Directory)
			DirDelete(Directory, true)
	}
}
Test("gesture menu: a mode or step choice persists and applies (gesture-swipe-slot-menu)",
	() => _GSSM_WithPrivateConfig(_GSSM_ChoicesPersist))
