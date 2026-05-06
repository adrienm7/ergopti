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
    AssertEqual("selection_toggle", GestureAssignments["tap_3"], "tap_3 default")
    AssertEqual("task_view", GestureAssignments["swipe_3_up"], "swipe_3_up default")
    AssertEqual("minimize_all", GestureAssignments["swipe_3_down"], "swipe_3_down default")
    AssertEqual("tab_prev", GestureAssignments["swipe_3_left"], "swipe_3_left default")
    AssertEqual("tab_next", GestureAssignments["swipe_3_right"], "swipe_3_right default")
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

; ===========================================
; ===========================================
; ======= 3/ Selection State Machine =======
; ===========================================
; ===========================================

TestGestures_DragStartsDisabled() {
    AssertFalse(GestureDragEnabled, "drag should start disabled")
}
Test("Gestures: drag starts disabled", TestGestures_DragStartsDisabled)

TestGestures_StopSelectionSafeWhenDisabled() {
    ; Should not throw even when nothing is active
    GestureDragEnabled := False
    GestureStopSelection()
    AssertFalse(GestureDragEnabled, "still disabled after redundant stop")
}
Test("Gestures: GestureStopSelection is safe when already stopped", TestGestures_StopSelectionSafeWhenDisabled)

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
