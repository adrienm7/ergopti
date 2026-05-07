; static/drivers/autohotkey/tests/test_gestures.ahk

; ==============================================================================
; MODULE: Test Gestures
; DESCRIPTION:
; Unit tests for the gestures module configuration and dispatch logic.
; Tests the pure logic parts (config reading, action lookup, assignment
; persistence) without registering actual hotkeys.
; ==============================================================================

; ====================================
; ====================================
; ======= 1/ Configuration Tests =======
; ====================================
; ====================================

TestGestures_DefaultAssignments() {
    AssertTrue(GestureAssignments.Has("tap_3"), "tap_3 should exist")
    AssertEqual("right_click_toggle", GestureAssignments["tap_3"], "tap_3 default")
    AssertEqual("tab_new", GestureAssignments["swipe_3_up"], "swipe_3_up default")
    AssertEqual("tab_close", GestureAssignments["swipe_3_down"], "swipe_3_down default")
    AssertEqual("tab_prev", GestureAssignments["swipe_3_left"], "swipe_3_left default")
    AssertEqual("tab_next", GestureAssignments["swipe_3_right"], "swipe_3_right default")
    AssertEqual("screenshot_window_clipboard", GestureAssignments["tap_4"], "tap_4 default")
    AssertEqual("win_app_next", GestureAssignments["swipe_4_up"], "swipe_4_up default")
    AssertEqual("win_app_prev", GestureAssignments["swipe_4_down"], "swipe_4_down default")
    AssertEqual("desktop_prev", GestureAssignments["swipe_4_left"], "swipe_4_left default")
    AssertEqual("desktop_next", GestureAssignments["swipe_4_right"], "swipe_4_right default")
}
Test("Gestures: default assignments are populated", TestGestures_DefaultAssignments)

TestGestures_AllSlotsHaveLabels() {
    for Slot in GESTURE_SLOTS {
        AssertTrue(GESTURE_SLOT_LABELS.Has(Slot), "missing label for slot: " . Slot)
    }
}
Test("Gestures: all slots have labels", TestGestures_AllSlotsHaveLabels)

TestGestures_AllSlotsHaveShortcutLabels() {
    for Slot in GESTURE_SLOTS {
        AssertTrue(GESTURE_SHORTCUT_LABELS.Has(Slot), "missing shortcut label for slot: " . Slot)
    }
}
Test("Gestures: all slots have shortcut labels", TestGestures_AllSlotsHaveShortcutLabels)

; ==================================
; ==================================
; ======= 2/ Action Registry =======
; ==================================
; ==================================

TestGestures_AllActionNamesInRegistry() {
    for ActionName in GESTURE_ACTION_NAMES {
        AssertTrue(GESTURE_ACTIONS.Has(ActionName), "missing action in registry: " . ActionName)
    }
}
Test("Gestures: all action names exist in registry", TestGestures_AllActionNamesInRegistry)

TestGestures_ActionsHaveProperties() {
    for ActionName in GESTURE_ACTION_NAMES {
        Action := GESTURE_ACTIONS[ActionName]
        AssertTrue(Action.HasOwnProp("Label"), "missing Label for: " . ActionName)
        AssertTrue(Action.HasOwnProp("Fn"), "missing Fn for: " . ActionName)
    }
}
Test("Gestures: every action has Label and Fn properties", TestGestures_ActionsHaveProperties)

TestGestures_NoneReturnsZero() {
    Result := GESTURE_ACTIONS["none"].Fn()
    AssertEqual(0, Result, "none action should return 0")
}
Test("Gestures: none action Fn returns 0", TestGestures_NoneReturnsZero)

TestGestures_RegistrySizeMatchesNames() {
    AssertEqual(GESTURE_ACTION_NAMES.Length, GESTURE_ACTIONS.Count, "registry size mismatch")
}
Test("Gestures: action count matches GESTURE_ACTION_NAMES length", TestGestures_RegistrySizeMatchesNames)

; ===============================================
; ===============================================
; ======= 3/ Right-Click Hold State Machine =====
; ===============================================
; ===============================================

TestGestures_RightClickStartsReleased() {
    AssertFalse(GestureRightClickHeld, "right-click hold should start released")
}
Test("Gestures: right-click hold starts released", TestGestures_RightClickStartsReleased)

TestGestures_ReleaseRightClickSafeWhenIdle() {
    ; Should not throw even when nothing is held
    GestureRightClickHeld := False
    GestureReleaseRightClick()
    AssertFalse(GestureRightClickHeld, "still released after redundant release call")
}
Test("Gestures: GestureReleaseRightClick is safe when already released",
    TestGestures_ReleaseRightClickSafeWhenIdle)

; ====================================
; ====================================
; ======= 4/ Assignment Saving =======
; ====================================
; ====================================

TestGestures_SaveAssignmentUpdatesMap() {
    OldValue := GestureAssignments["tap_4"]
    GestureSaveAssignment("tap_4", "copy")
    AssertEqual("copy", GestureAssignments["tap_4"], "assignment should be updated")
    ; Restore original value
    GestureAssignments["tap_4"] := OldValue
}
Test("Gestures: GestureSaveAssignment updates map", TestGestures_SaveAssignmentUpdatesMap)

TestGestures_DefaultAssignmentsReferenceValidActions() {
    for Slot in GESTURE_SLOTS {
        ActionName := GestureAssignments[Slot]
        AssertTrue(GESTURE_ACTIONS.Has(ActionName),
        "slot " . Slot . " references unknown action: " . ActionName)
    }
}
Test("Gestures: all default assignments reference valid actions", TestGestures_DefaultAssignmentsReferenceValidActions)

TestGestures_SlotCountMatchesExpected() {
    AssertEqual(10, GESTURE_SLOTS.Length, "expected 10 gesture slots")
}
Test("Gestures: slot count is 10", TestGestures_SlotCountMatchesExpected)




; =====================================================
; =====================================================
; ======= 5/ New actions (cycle / nav / screenshots) =======
; =====================================================
; =====================================================

TestGestures_NewActionsRegistered() {
    for Name in ["win_prev", "win_next", "win_app_prev", "win_app_next",
                  "nav_back", "nav_forward",
                  "screenshot_window_clipboard", "screenshot_window_save",
                  "screenshot_region_clipboard", "screenshot_region_save",
                  "screenshot_fullscreen_clipboard", "screenshot_fullscreen_save",
                  "screen_record"] {
        AssertTrue(GESTURE_ACTIONS.Has(Name), "missing action: " . Name)
    }
}
Test("Gestures: new actions (cycle, nav, screenshots) are registered",
    TestGestures_NewActionsRegistered)

TestGestures_NextIndexForwardWrap() {
    ; At the end of a 3-element list, forward should wrap to index 1
    AssertEqual(1, GestureNextIndex(3, 3, true), "forward at end should wrap to 1")
    AssertEqual(2, GestureNextIndex(1, 3, true), "forward from 1 should go to 2")
    AssertEqual(3, GestureNextIndex(2, 3, true), "forward from 2 should go to 3")
}
Test("Gestures: GestureNextIndex wraps forward correctly", TestGestures_NextIndexForwardWrap)

TestGestures_NextIndexBackwardWrap() {
    ; At index 1, backward should wrap to the last index
    AssertEqual(3, GestureNextIndex(1, 3, false), "backward at 1 should wrap to N")
    AssertEqual(1, GestureNextIndex(2, 3, false), "backward from 2 should go to 1")
    AssertEqual(2, GestureNextIndex(3, 3, false), "backward from 3 should go to 2")
}
Test("Gestures: GestureNextIndex wraps backward correctly", TestGestures_NextIndexBackwardWrap)

TestGestures_NextIndexFromZero() {
    ; Special case: when the active window isn't in the list, Index = 0.
    ; Forward should produce idx 1 (first element), backward should produce N.
    AssertEqual(1, GestureNextIndex(0, 5, true), "forward from 0 should go to 1")
    AssertEqual(5, GestureNextIndex(0, 5, false), "backward from 0 should go to N")
}
Test("Gestures: GestureNextIndex handles index=0 (active not in list)",
    TestGestures_NextIndexFromZero)


; ===========================================================
; ===========================================================
; ======= 6/ Registry encoding for auto-configure =======
; ===========================================================
; ===========================================================

TestGestures_KeyParamsEncodingF1() {
    ; F1 = VK 0x70, modifiers Ctrl+Win+Shift = 0x07. The registry layout
    ; confirmed by reading Windows after a manual touchpad-shortcut config
    ; is (VK << 16) | mods, so the encoding here mirrors that.
    Expected := (0x70 << 16) | 0x07  ; = 0x700007 = 7 340 039
    AssertEqual(Expected, GESTURE_REG_KEY_PARAMS["tap_3"],
        "tap_3 KeyParams should encode Ctrl+Win+Shift+F1")
}
Test("Gestures: KeyParams for tap_3 encodes Ctrl+Win+Shift+F1",
    TestGestures_KeyParamsEncodingF1)

TestGestures_KeyParamsEncodingF10() {
    ; F10 = VK 0x79
    Expected := (0x79 << 16) | 0x07
    AssertEqual(Expected, GESTURE_REG_KEY_PARAMS["swipe_4_right"],
        "swipe_4_right KeyParams should encode Ctrl+Win+Shift+F10")
}
Test("Gestures: KeyParams for swipe_4_right encodes Ctrl+Win+Shift+F10",
    TestGestures_KeyParamsEncodingF10)

TestGestures_KeyParamsAllSlotsCovered() {
    for Slot in GESTURE_SLOTS {
        AssertTrue(GESTURE_REG_KEY_PARAMS.Has(Slot),
            "missing KeyParams encoding for slot: " . Slot)
        AssertTrue(GESTURE_REG_KEY_PARAMS_NAMES.Has(Slot),
            "missing KeyParams name for slot: " . Slot)
    }
}
Test("Gestures: every slot has a KeyParams encoding and registry name",
    TestGestures_KeyParamsAllSlotsCovered)

TestGestures_TapSlotsHaveCustomTapName() {
    ; Tap slots use a CustomXxxTap=7 sentinel; swipe slots use direction-enable.
    AssertTrue(GESTURE_REG_CUSTOM_TAP_NAMES.Has("tap_3"))
    AssertTrue(GESTURE_REG_CUSTOM_TAP_NAMES.Has("tap_4"))
    AssertFalse(GESTURE_REG_CUSTOM_TAP_NAMES.Has("swipe_3_up"),
        "swipes should not have a CustomTap name")
}
Test("Gestures: tap slots map to CustomTap registry names",
    TestGestures_TapSlotsHaveCustomTapName)

TestGestures_SwipeSlotsHaveEnableName() {
    ; Swipe slots have ThreeFingerXxx / FourFingerXxx direction-enable keys.
    AssertTrue(GESTURE_REG_ENABLE_NAMES.Has("swipe_3_up"))
    AssertTrue(GESTURE_REG_ENABLE_NAMES.Has("swipe_4_right"))
    AssertFalse(GESTURE_REG_ENABLE_NAMES.Has("tap_3"),
        "taps should not have a direction-enable name")
}
Test("Gestures: swipe slots map to direction-enable registry names",
    TestGestures_SwipeSlotsHaveEnableName)
