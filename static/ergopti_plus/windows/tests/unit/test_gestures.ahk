; static/ergopti_plus/windows/tests/unit/test_gestures.ahk

; ==============================================================================
; MODULE: Test Gestures
; DESCRIPTION:
; Unit tests for the gestures module configuration and dispatch logic.
; Tests the pure logic parts (config reading, action lookup, assignment
; persistence) without registering actual hotkeys.
; ==============================================================================





; ======================================
; ======================================
; ======= 1/ Configuration Tests =======
; ======================================
; ======================================

TestGestures_DefaultAssignments() {
    AssertTrue(GestureAssignments.Has("tap_3"), "tap_3 should exist")
    for Slot in GESTURE_SLOTS {
        AssertTrue(GestureAssignments.Has(Slot), "every declared gesture must have a default")
        AssertEqual("none", GestureAssignments[Slot], Slot . " starts neutral")
    }
}
Test("Gestures: default assignments are populated", TestGestures_DefaultAssignments)

; Every registry field participates in recognition; a missing modifier or native
; family setting must not masquerade as a correctly configured touchpad.
TestGestures_SystemConfigurationContract() {
	global GESTURE_REG_ACTIONS, GESTURE_REG_KEY_PARAMS_NAMES, GESTURE_REG_KEY_PARAMS
	global GESTURE_REG_ENABLE_NAMES, GESTURE_REG_CUSTOM_TAP_NAMES
	global GESTURE_REG_CUSTOM_VALUE, GESTURE_REG_CUSTOM_TAP_VALUE
	for Slot in GESTURE_SLOTS {
		Family := InStr(Slot, "_3") ? "ThreeFinger" : "FourFinger"
		Family .= SubStr(Slot, 1, 3) == "tap" ? "TapEnabled" : "SlideEnabled"
		Values := Map(Family, GESTURE_REG_CUSTOM_VALUE,
			GESTURE_REG_ACTIONS[Slot], GESTURE_REG_CUSTOM_VALUE,
			GESTURE_REG_KEY_PARAMS_NAMES[Slot], GESTURE_REG_KEY_PARAMS[Slot])
		if GESTURE_REG_ENABLE_NAMES.Has(Slot)
			Values[GESTURE_REG_ENABLE_NAMES[Slot]] := GESTURE_REG_CUSTOM_VALUE
		if GESTURE_REG_CUSTOM_TAP_NAMES.Has(Slot)
			Values[GESTURE_REG_CUSTOM_TAP_NAMES[Slot]] := GESTURE_REG_CUSTOM_TAP_VALUE
		Read := (Name) => Values.Get(Name, "")
		AssertTrue(GestureSystemSlotConfigured(Slot, Read), Slot . " configured")
		for Name, Expected in Values.Clone() {
			Values.Delete(Name)
			AssertFalse(GestureSystemSlotConfigured(Slot, Read), Slot . " requires " . Name)
			Values[Name] := Expected + 1
			AssertFalse(GestureSystemSlotConfigured(Slot, Read), Slot . " rejects wrong " . Name)
			Values[Name] := Expected
		}
	}
	AssertEqual("swipe_3", GestureSystemGroup("swipe_3_left"), "group shares dismissal")
	AssertEqual("swipe_3", GestureSystemGroup("swipe_3_right"), "opposite direction shares dismissal")
	AssertEqual("tap_3", GestureSystemGroup("tap_3"), "tap dismissal remains separate")
}
Test("Gestures: system configuration requires every native registry field", TestGestures_SystemConfigurationContract)

; A failed read invalidates the snapshot and must never publish partial success.
TestGestures_SystemSnapshotRefusal() {
	State := GestureSystemState()
	PreviousSlots := State["slots"]
	PreviousReady := State["ready"]
	try {
		AssertTrue(GestureSystemRefresh(false, (Name) => ""), "absent settings are a complete unconfigured snapshot")
		AssertTrue(State["ready"], "completed snapshot is available")
		for Slot in GESTURE_SLOTS
			AssertFalse(State["slots"][Slot], Slot . " absent is not configured")
		Snapshot := State["slots"]
		AssertFalse(GestureSystemRefresh(false, TestGestures_RefuseSystemRead), "read refusal propagates")
		AssertFalse(State["ready"], "refusal exposes unknown status")
		AssertTrue(State["slots"] == Snapshot, "partial replacement was not published")
	} finally {
		State["slots"] := PreviousSlots
		State["ready"] := PreviousReady
	}
}

TestGestures_RefuseSystemRead(Name) {
	throw Error("native registry read refused")
}
Test("Gestures: system snapshot refusal cannot publish partial success", TestGestures_SystemSnapshotRefusal)

; Close callbacks cannot retire another notice or run a reload callback twice.
TestGestures_SystemNoticeOwnership() {
	State := GestureSystemState()
	Windows := State["windows"]
	Callbacks := State["callbacks"]
	Observed := Map("destroyed", 0, "done", 0)
	Notice := { Destroy: (*) => Observed["destroyed"] += 1 }
	try {
		State["windows"] := Map("swipe_3", Notice)
		State["callbacks"] := Map("swipe_3", [(*) => Observed["done"] += 1])
		AssertFalse(GestureSystemFinishNotice("swipe_3", {}, "close"), "stale owner refused")
		AssertEqual(0, Observed["done"], "stale notice cannot reload")
		AssertTrue(GestureSystemFinishNotice("swipe_3", Notice, "close"), "owned close accepted")
		AssertEqual(1, Observed["destroyed"], "notice destroyed once")
		AssertEqual(1, Observed["done"], "completion delivered once")
		AssertFalse(GestureSystemFinishNotice("swipe_3", Notice, "close"), "duplicate close refused")
		AssertEqual(1, Observed["done"], "duplicate close cannot reload twice")
	} finally {
		State["windows"] := Windows
		State["callbacks"] := Callbacks
	}
}
Test("Gestures: system notices retain exact group ownership", TestGestures_SystemNoticeOwnership)

; A previous good value cannot suppress a warning after its refresh was refused.
TestGestures_SystemAssignmentReadiness() {
	State := GestureSystemState()
	PreviousSlots := State["slots"]
	PreviousReady := State["ready"]
	try {
		State["slots"] := Map("tap_3", true)
		State["ready"] := false
		AssertTrue(GestureSystemAssignmentNeedsWarning("tap_3"), "unverified old cache cannot suppress warning")
		State["ready"] := true
		AssertFalse(GestureSystemAssignmentNeedsWarning("tap_3"), "confirmed native mapping needs no warning")
		AssertTrue(GestureSystemAssignmentNeedsWarning("tap_4"), "unconfigured sibling still needs warning")
	} finally {
		State["slots"] := PreviousSlots
		State["ready"] := PreviousReady
	}
}
Test("Gestures: system assignment warning requires a current snapshot", TestGestures_SystemAssignmentReadiness)

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





; ================================================
; ================================================
; ======= 2/ Pause and reversal regression =======
; ================================================
; ================================================

; Regression for project_suspend_pause_invariant: gestures must respect pause.
TestGestures_RespectPause() {
    ; Simulate pause (in real code A_IsSuspended or script_control.is_paused)
    ; Here we just assert the config side doesn't assume always-on.
    AssertTrue(IsSet(GESTURE_SLOTS), "slots exist even under pause consideration")
    ; In full driver, dispatch paths must early-return when paused.
}
Test("Gestures: pause invariant skeleton (full guard lives in dispatch)", TestGestures_RespectPause)

; Basic reversal note test (actual reversal logic in engine; here config parity).
TestGestures_ReversalSlotsExist() {
    ; 4-finger swipes have left/right for space navigation (reversal use case)
    AssertTrue(GestureAssignments.Has("swipe_4_left"))
    AssertTrue(GestureAssignments.Has("swipe_4_right"))
}
Test("Gestures: reversal-relevant 4-finger slots are configured", TestGestures_ReversalSlotsExist)







; ==================================
; ==================================
; ======= 2/ Action Registry =======
; ==================================
; ==================================

; The ordered ids the picker lists come from the generated catalogue
; (_generated/action_catalogue.ahk) with the modifier-chord block expanded, so
; every assertion below walks exactly what a user can pick.
TestGestures_AllActionNamesInRegistry() {
    Ids := GestureActionPickerIds()
    Assert(Ids.Length >= 500, "the picker lists only " . Ids.Length . " action(s) — the catalogue walk collapsed")
    for ActionName in Ids
        AssertTrue(GESTURE_ACTIONS.Has(ActionName), "missing action in registry: " . ActionName)
}
Test("Gestures: all action names exist in registry", TestGestures_AllActionNamesInRegistry)

TestGestures_ActionsHaveProperties() {
    for ActionName in GestureActionPickerIds() {
        Action := GESTURE_ACTIONS[ActionName]
        ; Labels are not stored on the action object — they come from
        ; _GestureActionLabel() (i18n), which falls back to the raw key name
        AssertTrue(StrLen(_GestureActionLabel(ActionName)) > 0, "missing Label for: " . ActionName)
        AssertTrue(Action.HasOwnProp("Fn"), "missing Fn for: " . ActionName)
    }
}
Test("Gestures: every action has Label and Fn properties", TestGestures_ActionsHaveProperties)

; The picker headings used to be the literal "#Raccourcis" and
; "##Raccourcis <mods>", French in every locale. They are now locale keys, and
; the group heading places the language-neutral modifier label through {1}.
TestGestures_SharedModifierChordsAreRegisteredAndLabelled() {
    for Name in ["ctrl_a", "ctrl_alt_a", "ctrl_shift_alt_win_enter"]
        AssertTrue(GESTURE_ACTIONS.Has(Name), "missing shared modifier action: " . Name)
    AssertEqual("Ctrl + A", _GestureActionLabel("ctrl_a"), "Ctrl+A label must never expose the internal id")
    AssertEqual("Ctrl + Alt + A", _GestureActionLabel("ctrl_alt_a"), "multi-modifier label must use the shared format")
    AssertEqual("Ctrl + Shift + Alt + Win + Enter", _GestureActionLabel("ctrl_shift_alt_win_enter"), "full modifier matrix must include special keys")
    ChordsTitle := t("sg_actions.sg_order.header.modifier_chords")
    GroupTemplate := t("sg_actions.sg_order.header.modifier_chord_group")
    AssertTrue(ChordsTitle != "sg_actions.sg_order.header.modifier_chords", "the chord heading key must resolve")
    AssertTrue(InStr(GroupTemplate, "{1}") > 0, "the chord group heading must place the modifier label")
    CtrlTitle := StrReplace(GroupTemplate, "{1}", "Ctrl")
    HasShortcutsH1 := false
    HasCtrlH2 := false
    CtrlH2FollowedByCtrlA := false
    Items := GestureActionPickerItems()
    for Index, Item in Items {
        if (Item.Type != "heading")
            continue
        AssertFalse(InStr(Item.Text, "sg_actions.") = 1, "a heading shows its raw key: " . Item.Text)
        HasShortcutsH1 := HasShortcutsH1 || (Item.Level = 1 && Item.Text == ChordsTitle)
        if (Item.Level = 2 && Item.Text == CtrlTitle) {
            HasCtrlH2 := true
            CtrlH2FollowedByCtrlA := Items.Length > Index && Items[Index + 1].Type = "action"
                && Items[Index + 1].Id = "ctrl_a"
        }
    }
    AssertTrue(HasShortcutsH1, "modifier actions must be under the localized shortcuts H1")
    AssertTrue(HasCtrlH2, "Ctrl actions must be under the localized Ctrl H2")
    AssertTrue(CtrlH2FollowedByCtrlA, "the Ctrl H2 must head its own chords")
}
Test("Gestures: shared modifier chords are registered and labelled", TestGestures_SharedModifierChordsAreRegisteredAndLabelled)

TestGestures_NoneReturnsZero() {
    Result := GESTURE_ACTIONS["none"].Fn()
    AssertEqual(0, Result, "none action should return 0")
}
Test("Gestures: none action Fn returns 0", TestGestures_NoneReturnsZero)

class _GTUI_CallRecorder {
	__New(Result := true) {
		this.calls := 0
		this.result := Result
	}

	Call(*) {
		this.calls += 1
		return this.result
	}
}

class _GTUI_ResultSequence {
	__New(Results) {
		this.results := Results
		this.calls := 0
	}

	Call(*) {
		this.calls += 1
		return this.results[Min(this.calls, this.results.Length)]
	}
}

TestGestures_ToggleUIReopensAfterActivationRace() {
	Exists := _GTUI_ResultSequence([true, false])
	Open := _GTUI_CallRecorder()
	Activate := _GTUI_CallRecorder(false)

	Result := _GestureGenericToggleUIWith(
		(*) => 123, Open, (*) => true, Exists, (*) => 456, Activate)

	AssertTrue(Result, "a vanished window must be reopened")
	AssertEqual(1, Activate.calls, "the existing window must first be activated")
	AssertEqual(2, Exists.calls, "a refused activation must revalidate window ownership")
	AssertEqual(1, Open.calls, "the race winner must open one replacement window")
}
Test("Gestures: toggle reopens a window lost during activation (gesture-toggle-activation-race)",
	TestGestures_ToggleUIReopensAfterActivationRace)

TestGestures_ToggleUIRejectsLiveActivationRefusal() {
	Exists := _GTUI_ResultSequence([true, true])
	Open := _GTUI_CallRecorder()
	Activate := _GTUI_CallRecorder(false)
	Message := ""
	try {
		_GestureGenericToggleUIWith(
			(*) => 123, Open, (*) => true, Exists, (*) => 456, Activate)
	} catch as Err {
		Message := Err.Message
	}

	AssertTrue(Message != "", "a live activation refusal must surface as an error")
	AssertEqual(1, Activate.calls, "the live window must receive one activation attempt")
	AssertEqual(2, Exists.calls, "the refusal must be classified against current existence")
	AssertEqual(0, Open.calls, "a still-live window must not be duplicated")
}
Test("Gestures: toggle surfaces a live activation refusal (gesture-toggle-activation-race)",
	TestGestures_ToggleUIRejectsLiveActivationRefusal)

; Catalogue <-> registry parity, both directions. A listed id with no handler
; is a binding that does nothing when it fires; a registered handler the
; catalogue does not list is a feature nobody can bind. The generated catalogue
; is filtered to this platform by the codegen, so the two sets must be equal.
TestGestures_RegistrySizeMatchesNames() {
    Listed := Map()
    for ActionName in GestureActionPickerIds() {
        AssertFalse(Listed.Has(ActionName), "the picker lists '" . ActionName . "' twice")
        Listed[ActionName] := true
    }
    Hidden := []
    for ActionName in GESTURE_ACTIONS {
        if !Listed.Has(ActionName)
            Hidden.Push(ActionName)
    }
    AssertEqual(0, Hidden.Length, "registered but never listed: " . (Hidden.Length ? Hidden[1] : ""))
    AssertEqual(Listed.Count, GESTURE_ACTIONS.Count, "catalogue and registry must be the same set")
    AssertEqual(0, GESTURE_ACTION_CATALOGUE.AxItems.Length,
        "Windows has no axis dispatcher, so its catalogue must offer no axis action")
}
Test("Gestures: the generated catalogue and the registry are the same set (action-catalogue-parity)", TestGestures_RegistrySizeMatchesNames)





; =================================================
; =================================================
; ======= 3/ Right-Click Hold State Machine =======
; =================================================
; =================================================

TestGestures_RightClickStartsReleased() {
    AssertFalse(GestureLeftClickHeld, "right-click hold should start released")
}
Test("Gestures: right-click hold starts released", TestGestures_RightClickStartsReleased)

TestGestures_ReleaseRightClickSafeWhenIdle() {
    global GestureLeftClickHeld
    ; Should not throw even when nothing is held
    GestureLeftClickHeld := False
    GestureReleaseLeftClick()
    AssertFalse(GestureLeftClickHeld, "still released after redundant release call")
}
Test("Gestures: GestureReleaseLeftClick is safe when already released",
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

TestGestures_ParameterizedActionValuesAreBindingScoped() {
    global GestureActionParameters

    AssertEqual("url", GestureActionParameterSpec("open_url"), "open_url parameter metadata")
    AssertEqual("search_url", GestureActionParameterSpec("search_web"), "search_web parameter metadata")

    OriginalParameters := GestureActionParameters
    GestureActionParameters := Map()
    try {
        GestureActionParameters[GestureActionParameterKey("gesture__tap_3", "open_url")] := "https://one.example"
        GestureActionParameters[GestureActionParameterKey("tap_hold__caps_lock", "open_url")] := "https://two.example"
        AssertEqual("https://one.example", GestureGetActionParameter("gesture__tap_3", "open_url"), "gesture URL must remain isolated")
        AssertEqual("https://two.example", GestureGetActionParameter("tap_hold__caps_lock", "open_url"), "tap-hold URL must remain isolated")
        AssertTrue(InStr(GestureActionDisplayLabel("open_url", "gesture__tap_3"), "https://one.example") > 0,
            "menu label must expose the configured URL")
        AssertTrue(GestureValidateActionParameter("open_url", "https://valid.example/path"), "valid URL")
        AssertFalse(GestureValidateActionParameter("open_url", "not-a-url"), "invalid URL rejected")
        AssertTrue(GestureValidateActionParameter("search_web", "https://search.example/?q=%s"), "valid search template")
        AssertFalse(GestureValidateActionParameter("search_web", "https://search.example/?q=%s&again=%s"), "duplicate search placeholder rejected")
		AssertEqual("notes%20%26%20caf%C3%A9%3D2", UriEncode("notes & café=2"), "query text must be UTF-8 percent encoded")
    } finally {
        GestureActionParameters := OriginalParameters
    }
}
Test("Gestures: parameterized action values are isolated and validated", TestGestures_ParameterizedActionValuesAreBindingScoped)

TestGestures_ParameterizedActionValuesPersistToUserToml() {
    global ConfigurationFile, GestureActionParameters, _IniCache

    TempConfig := A_Temp . "\ergopti_gesture_action_parameters_test.toml"
    try FileDelete(TempConfig)
    try FileDelete(TempConfig . ".tmp")
    OriginalConfig := ConfigurationFile
    OriginalParameters := GestureActionParameters
    OriginalIniCache := _IniCache
    ConfigurationFile := TempConfig
    GestureActionParameters := Map()
    try {
        GestureSetActionParameter("gesture__tap_3", "open_url", "https://saved.example/path")

        ; Exercise a real search template too: % and & must survive TOML
        ; serialization verbatim rather than becoming a generic/global setting.
        SearchKey := GestureActionParameterKey("keyboard__cmd_k", "search_web")
        SearchTemplate := "https://search.example/?q=%s&source=ergopti"
        GestureSetActionParameter("keyboard__cmd_k", "search_web", SearchTemplate)
        Parsed := ParseTomlFile(TempConfig)
        AssertTrue(Parsed.Has("action_parameters"), "action parameter section must be persisted")
        Key := GestureActionParameterKey("gesture__tap_3", "open_url")
        AssertEqual("https://saved.example/path", Parsed["action_parameters"][Key], "exact URL must round-trip through TOML")
		AssertEqual(SearchTemplate, Parsed["action_parameters"][SearchKey], "search template must round-trip through TOML")

        ; A config reload must both restore the saved value and drop stale
        ; in-memory values that are no longer in the user TOML.
        GestureActionParameters := Map("stale__open_url", "https://stale.example")
        _IniCache := Parsed
        GesturesReadConfig()
        AssertEqual("https://saved.example/path", GestureGetActionParameter("gesture__tap_3", "open_url"), "saved parameter must reload from TOML")
		AssertEqual(SearchTemplate, GestureGetActionParameter("keyboard__cmd_k", "search_web"), "scoped search template must reload from TOML")
        AssertFalse(GestureActionParameters.Has("stale__open_url"), "reload must not retain stale parameter values")
    } finally {
        ConfigurationFile := OriginalConfig
        GestureActionParameters := OriginalParameters
        _IniCache := OriginalIniCache
        try FileDelete(TempConfig)
        try FileDelete(TempConfig . ".tmp")
    }
}
Test("Gestures: parameterized action values persist to the user TOML", TestGestures_ParameterizedActionValuesPersistToUserToml)

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





; ==========================================================
; ==========================================================
; ======= 5/ New actions (cycle / nav / screenshots) =======
; ==========================================================
; ==========================================================

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





; =======================================================
; =======================================================
; ======= 6/ Registry encoding for auto-configure =======
; =======================================================
; =======================================================

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

; F25 (audit 2026-07-20): GestureInvokeAction is the single choke point shared by all
; three dispatchers (gesture, keyboard-shortcut slot, tap-hold), but only
; GestureDispatch wrapped the call — so a throwing action reached via a shortcut slot
; or a tap-hold propagated uncaught into the error net. Containment must live in the
; shared invoker: a throwing action is logged and swallowed, never propagated.
_GIA_ThrowHelper() {
    throw Error("boom from a gesture action stub")
}
TestGestures_InvokeActionContainsThrows() {
    global GESTURE_ACTIONS
    Threw := false
    GESTURE_ACTIONS["__test_throws"] := { Fn: (*) => _GIA_ThrowHelper() }
    try {
        try {
            GestureInvokeAction("__test_throws")
        } catch {
            Threw := true
        }
    } finally {
        GESTURE_ACTIONS.Delete("__test_throws")
    }
    AssertEqual(false, Threw,
        "GestureInvokeAction must contain a throwing action (all three dispatchers share it), never propagate into the error net")
}
Test("Gestures: GestureInvokeAction contains a throwing action instead of propagating",
    TestGestures_InvokeActionContainsThrows)

TestGestures_AutoConfigureMarkerPreservesBooleanType() {
    AssertTrue(_GestureAutoConfigureFlagEnabled(true))
    AssertFalse(_GestureAutoConfigureFlagEnabled(false))
    AssertFalse(_GestureAutoConfigureFlagEnabled("_"))
    Thrown := false
    try _GestureAutoConfigureFlagEnabled("true")
    catch
        Thrown := true
    AssertTrue(Thrown,
        "a quoted true marker must not schedule elevated touchpad configuration")
}
Test("Gestures: onboarding marker preserves TOML boolean type (AHK-102)",
    TestGestures_AutoConfigureMarkerPreservesBooleanType)


; The actual cached provider must consume the shared fixed command declaration.
; Its native registry refresh still runs only from the existing deferred timer.
TestGestures_SharedSystemRefresh() {
	global _SharedDir, GESTURE_SLOTS
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\gesture_system_refresh.json", "UTF-8"))
	Root := _MR_GetManifestRoot()
	Section := Corpus["section"]
	Definition := Root[Section]
	AssertEqual(1, Definition.Length, "one independently declared fixed control")
	for Field, Expected in Corpus["rows"][1] {
		if Expected is Array {
			AssertEqual(Expected.Length, Definition[1][Field].Length, "exact platform count")
			for Index, Platform in Expected
				AssertEqual(Platform, Definition[1][Field][Index], "exact existing native platform")
		} else
			AssertEqual(Expected, Definition[1][Field], "independent field: " . Field)
	}
	ExpectedSlots := Corpus["cached_children"]["ahk"]
	AssertEqual(GESTURE_SLOTS.Length + 1, ExpectedSlots.Length, "handwritten slot sequence includes only one trailing refresh")
	for Index, Slot in GESTURE_SLOTS
		AssertEqual(ExpectedSlots[Index], Slot, "cached native slot order")
	State := GestureSystemState()
	PreviousReady := State["ready"]
	PreviousSlots := State["slots"]
	Rendered := Menu()
	try {
		State["ready"] := false
		Rows := GestureSystemRows()
		AssertEqual(1, Rows.Length, "one cached system-status submenu")
		Children := Rows[1]["items"]
		AssertEqual(ExpectedSlots.Length, Children.Length, "all existing cached children precede the shared command")
		AssertEqual(t("ui_apps.btn_refresh"), Children[Children.Length]["label"], "existing refresh translation")
		AssertFalse(State["ready"], "building does not perform a registry read")
		AssertEqual(Children.Length, _MR_RenderRows(Rendered, Children, "gesture_system_refresh_test", 1),
			"actual native renderer consumes every cached child and command")
		AssertEqual(Children.Length, DllCall("GetMenuItemCount", "ptr", Rendered.Handle, "int"),
			"actual Win32 menu has the same number of children")
		Flags := DllCall("GetMenuState", "ptr", Rendered.Handle, "uint", Children.Length - 1, "uint", 0x400, "uint")
		Assert(Flags != 0xFFFFFFFF && !(Flags & 0x3), "existing Refresh remains a clickable native command")
		Children[Children.Length]["action"].Call()
		Started := A_TickCount
		while !State["ready"] && A_TickCount - Started < 2000
			Sleep(10)
		AssertTrue(State["ready"], "actual command schedules the original native complete-snapshot refresh")
		for Slot in GESTURE_SLOTS
			AssertTrue(State["slots"].Has(Slot), "actual timer publishes the full native snapshot: " . Slot)
	} finally {
		SetTimer(GestureSystemRefresh, 0)
		State["ready"] := PreviousReady
		State["slots"] := PreviousSlots
		Rendered.Delete()
		MenuDispatcher_PruneMenu(Rendered)
	}
}
Test("Gestures: shared system refresh consumes actual cached provider and native timer", TestGestures_SharedSystemRefresh)

; Mutations prove declaration ownership, while restoring the exact original root.
TestGestures_SharedSystemRefreshDeclaration() {
	Root := _MR_GetManifestRoot()
	Section := "gesture_system_status_controls"
	Original := Root[Section]
	Rendered := Menu()
	try {
		Changed := Original[1].Clone()
		Changed["i18n"] := "menu.gestures.open_settings"
		Root[Section] := [Map("type", "---", "platforms", ["ahk"], "unavailable", "hide"), Changed]
		Rows := GestureSystemRows()
		Children := Rows[1]["items"]
		AssertTrue(Children[Children.Length - 1]["separator"], "actual provider follows declared separator order")
		AssertEqual(t("menu.gestures.open_settings"), Children[Children.Length]["label"], "actual provider follows declared caption")
		AssertEqual(Children.Length - 1, _MR_RenderRows(Rendered, Children, "gesture_system_order_test", 1),
			"actual native renderer counts all labelled rows")
		AssertEqual(Children.Length, DllCall("GetMenuItemCount", "ptr", Rendered.Handle, "int"),
			"actual native renderer retains the interior separator")
		Changed["platforms"] := ["hs"]
		Root[Section] := [Changed]
		Hidden := GestureSystemRows()[1]["items"]
		AssertEqual(Children.Length - 2, Hidden.Length, "platform hiding retains every existing cached Settings child")
		Changed["platforms"] := ["ahk"]
		Changed["id"] := "unknown_native_refresh_owner"
		AssertEqual(0, GestureSystemRows().Length, "missing actual command refuses partial status publication")
	} finally {
		Root[Section] := Original
		Rendered.Delete()
		MenuDispatcher_PruneMenu(Rendered)
	}
}
Test("Gestures: actual system refresh provider follows declaration order caption and platform", TestGestures_SharedSystemRefreshDeclaration)


; The independent three-slot vector crosses the original tap_4 boundary once.
_GTB_WithSlots(Callback) {
	global GESTURE_SLOTS, GestureAssignments, Features
	PreviousSlots := GESTURE_SLOTS, PreviousAssignments := GestureAssignments, PreviousFeatures := Features
	try {
		GESTURE_SLOTS := ["swipe_3_up", "tap_4", "tap_3"]
		GestureAssignments := Map("swipe_3_up", "none", "tap_4", "none", "tap_3", "none")
		Features := Map("gestures", Map("enabled", true))
		return Callback.Call()
	} finally {
		GESTURE_SLOTS := PreviousSlots, GestureAssignments := PreviousAssignments, Features := PreviousFeatures
	}
}

_GTB_Owner() {
	Owner := _MR_FindItemById("gestures_menu", "gesture_slots_ahk")
	Assert(Owner is Map, "the actual flat Windows provider must be declared")
	return Owner
}

_GTB_AssertSlotRows(Rows, ExpectedLength, TapPosition) {
	Assert(Rows is Array)
	AssertEqual(ExpectedLength, Rows.Length)
	for Pair in [[1, "swipe_3_up"], [TapPosition, "tap_4"], [TapPosition + 1, "tap_3"]] {
		Row := Rows[Pair[1]]
		AssertTrue(InStr(Row["label"], t("gesture.slots." . Pair[2]) . " : ") == 1)
		Assert(Row["action"] is Func, "the existing slot action remains its native callback")
		AssertFalse(Row["disabled"])
	}
}

_GTB_DeclaredBoundary() {
	_GTB_WithSlots(() => _GTB_DeclaredBoundaryInner())
}
_GTB_DeclaredBoundaryInner() {
	Owner := _GTB_Owner()
	Assert(Owner.Get("status_rows", false) is Map)
	Boundary := Owner["status_rows"]["tap_group_boundary"]
	Assert(Boundary is Array)
	AssertEqual(1, Boundary.Length)
	AssertEqual(1, Boundary[1].Count)
	AssertEqual("---", Boundary[1]["type"])
	Rows := _GES_SlotRows()
	_GTB_AssertSlotRows(Rows, 4, 3)
	AssertTrue(Rows[2]["separator"])
	AssertFalse(Rows[2].Has("action"), "a fixed separator has no click owner")
	Native := Menu()
	try {
		AssertEqual(3, _MR_RenderRows(Native, Rows, "gesture_slots_ahk", 1), "the renderer receipt counts named rows only")
		AssertEqual(4, DllCall("user32\GetMenuItemCount", "Ptr", Native.Handle, "Int"))
		Flags := DllCall("user32\GetMenuState", "Ptr", Native.Handle, "UInt", 1, "UInt", 0x400, "UInt")
		Assert(Flags != 0xFFFFFFFF, "GetMenuState must acknowledge the actual separator position")
		AssertTrue((Flags & 0x800) != 0, "the actual Win32 item between swipe and tap is a separator")
		AssertEqual(Rows[3]["label"], _CTC_LabelAt(Native, 2), "tap_4 follows the actual separator")
	} finally _CTC_ReleaseMenu(Native)
}
Test("Gestures menu: the actual flat provider materializes its shared tap boundary", _GTB_DeclaredBoundary)

_GTB_PublishedBoundary() {
	_GTB_WithSlots(() => _GTB_PublishedBoundaryInner())
}
_GTB_PublishedBoundaryInner() {
	Owner := _GTB_Owner(), HadStatus := Owner.Has("status_rows"), Previous := Owner.Get("status_rows", false)
	try {
		Owner["status_rows"] := Map("tap_group_boundary", [
			Map("type", "label", "i18n", "common.restore_recommended"), Map("type", "---")])
		Rows := _GES_SlotRows()
		_GTB_AssertSlotRows(Rows, 5, 4)
		AssertEqual(t("common.restore_recommended"), Rows[2]["label"])
		AssertTrue(Rows[2]["disabled"])
		AssertFalse(Rows[2].Has("action"))
		AssertTrue(Rows[3]["separator"])
		AssertFalse(Rows[3].Has("action"))
		Owner["status_rows"]["tap_group_boundary"][1]["i18n"] := "common.clear_to_system"
		AssertEqual(t("common.restore_recommended"), Rows[2]["label"], "held materialized data is detached from later source mutation")
		AssertEqual(t("common.clear_to_system"), _GES_SlotRows()[2]["label"], "a fresh native provider consumes current shared source")
		Owner.Delete("status_rows")
		AssertEqual(0, _GES_SlotRows().Length, "a missing required boundary refuses a rebuilt provider")
		Native := Menu()
		try {
			AssertEqual(4, _MR_RenderRows(Native, Rows, "gesture_slots_ahk", 1), "the renderer receipt counts the inert label and slots")
			AssertEqual(5, DllCall("user32\GetMenuItemCount", "Ptr", Native.Handle, "Int"))
			AssertEqual(t("common.restore_recommended"), _CTC_LabelAt(Native, 1))
			Flags := DllCall("user32\GetMenuState", "Ptr", Native.Handle, "UInt", 1, "UInt", 0x400, "UInt")
			Assert(Flags != 0xFFFFFFFF, "GetMenuState must acknowledge the actual held-label position")
			AssertTrue((Flags & 3) != 0, "the held inert label remains actually disabled")
		} finally _CTC_ReleaseMenu(Native)
	} finally {
		if HadStatus
			Owner["status_rows"] := Previous
		else if Owner.Has("status_rows")
			Owner.Delete("status_rows")
	}
}
Test("Gestures menu: current declared boundary order is consumed and held inert data is detached", _GTB_PublishedBoundary)

_GTB_RefusedBoundary() {
	_GTB_WithSlots(() => _GTB_RefusedBoundaryInner())
}
_GTB_RefusedBoundaryInner() {
	global GESTURE_SLOTS, GestureAssignments, Features
	Owner := _GTB_Owner(), HadStatus := Owner.Has("status_rows"), Previous := Owner.Get("status_rows", false)
	Assignments := GestureAssignments, FeatureOwner := Features
	try {
		for Invalid in [false, Map(), Map("tap_group_boundary", []),
			Map("tap_group_boundary", [Map("type", "command", "id", "foreign_action")]),
			Map("tap_group_boundary", [Map("type", "---", "action", (*) => true)]),
			Map("tap_group_boundary", [Map("type", "label", "i18n", "common.restore_recommended", "checked_when", ["foreign_state"])])] {
			Owner["status_rows"] := Invalid
			AssertEqual(0, _GES_SlotRows().Length, "missing, empty or effect-bearing status cannot publish a partial slot list")
			AssertTrue(GestureAssignments == Assignments)
			AssertEqual("none", GestureAssignments["tap_4"])
			AssertTrue(Features == FeatureOwner)
			AssertTrue(Features["gestures"]["enabled"])
		}
		Owner.Delete("status_rows")
		GESTURE_SLOTS := ["swipe_3_up", "tap_3"]
		Rows := _GES_SlotRows()
		AssertEqual(2, Rows.Length, "an absent tap_4 needs no boundary or invented separator")
		AssertFalse(Rows[1].Get("separator", false))
		AssertFalse(Rows[2].Get("separator", false))
	} finally {
		if HadStatus
			Owner["status_rows"] := Previous
		else if Owner.Has("status_rows")
			Owner.Delete("status_rows")
	}
}
Test("Gestures menu: missing or effect-bearing boundary refuses atomically without changing native assignment owners", _GTB_RefusedBoundary)


; The native equivalent replays the exact hand-authored corpus used by Lua.
; Default case-insensitive Maps deliberately exercise the helper's exact lookup.
TestGestures_PublishedBindingIdentityCorpus() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\config_binding_identity\vectors.json", "UTF-8"))
	AssertEqual(29, Corpus["vectors"].Length, "frozen independent publication corpus")
	for Vector in Corpus["vectors"] {
		if Vector.Get("expects_error", false) {
			AssertThrows(ConfigBindingIdentityGestureStatus.Bind(Vector["binding"], Vector["catalogue"]), Vector["id"])
			continue
		}
		if Vector.Has("published") && !Vector["published"] {
			Status := ConfigBindingIdentityGestureStatus(Vector["binding"])
		} else {
			Slots := Map()
			for Slot in Vector["slots"]
				Slots[Slot] := true
			Status := ConfigBindingIdentityGestureStatus(Vector["binding"], Map("prefix", Vector["prefix"], "slots", Slots))
		}
		AssertEqual(Vector["status"], Status, Vector["id"])
	}
}
Test("Gestures: published binding identity replays shared 29-vector corpus (gesture-binding-identity-corpus)",
	TestGestures_PublishedBindingIdentityCorpus)

TestGestures_PublishedNativeSlotDomain() {
	Catalogue := TomlConfigGestureSlotCatalogue()
	AssertEqual("gesture__", Catalogue["prefix"])
	AssertEqual(10, Catalogue["slots"].Count, "actual complete Windows catalogue")
	AssertEqual("On", Catalogue["slots"].CaseSense)
	for Slot in GestureSlotIds()
		AssertEqual("current", ConfigBindingIdentityGestureStatus(GestureBindingId("gesture", Slot), Catalogue), Slot)
	AssertEqual("retired", ConfigBindingIdentityGestureStatus("gesture__removed_gesture_slot", Catalogue))
	AssertEqual("retired", ConfigBindingIdentityGestureStatus("gesture__TAP_3", Catalogue))
	AssertEqual("unjudged", ConfigBindingIdentityGestureStatus("Gesture__tap_3", Catalogue))
	for Binding in ["keyboard__ctrl_k", "tap_key__a", "script__pause", "tap_hold__caps_lock", "combination__caps_lock_then_space"]
		AssertEqual("unjudged", ConfigBindingIdentityGestureStatus(Binding, Catalogue), Binding)
}
Test("Gestures: native owner publishes its exact ten-slot domain (gesture-binding-identity-native-catalogue)",
	TestGestures_PublishedNativeSlotDomain)

TestGestures_RetiredParameterSettersRefuseBeforePorts() {
	global GestureActionParameters
	Previous := GestureActionParameters
	Calls := []
	Writer := (*) => (Calls.Push("writer"), false)
	Notify := (*) => Calls.Push("notify")
	try {
		GestureActionParameters := Map()
		GestureActionParameters.CaseSense := "On"
		GestureActionParameters["Gesture__tap_3__open_url"] := "https://unjudged.example"
		AssertFalse(GestureSetActionParameter("gesture__removed_gesture_slot", "open_url", "https://must-not-write.example", Writer, Notify))
		AssertEqual(0, Calls.Length, "ordinary refusal precedes writer and native notification")
		AssertEqual(1, GestureActionParameters.Count)
		AssertEqual("On", GestureActionParameters.CaseSense)
		Assignments := Map("tap_3", "none")
		Parameters := GestureActionParameters.Clone()
		Candidate := Map("has_value", true, "key", "gesture__removed_gesture_slot__open_url", "value", "https://must-not-write.example")
		AssertFalse(_GestureCommitAssignment(&Assignments, &Parameters, "gestures", "tap_3", "open_url", Candidate, Writer, Notify))
		AssertEqual(0, Calls.Length, "combined assignment also refuses before persistence")
		AssertEqual("none", Assignments["tap_3"])
		AssertEqual(1, Parameters.Count)
		AssertEqual("On", Parameters.CaseSense)
	} finally GestureActionParameters := Previous
}
Test("Gestures: proven retired parameters refuse both ordinary setter paths before ports (gesture-binding-identity-refusal)",
	TestGestures_RetiredParameterSettersRefuseBeforePorts)

TestGestures_ParameterSnapshotsKeepCaseTwins() {
	Known := "gesture__tap_3__open_url"
	Twin := "Gesture__tap_3__open_url"
	Source := Map()
	Source.CaseSense := "On"
	Source[Known] := "https://known.example"
	Source[Twin] := "https://unjudged.example"
	Snapshot := _GestureCloneActionParameters(Source)
	AssertEqual("On", Snapshot.CaseSense)
	AssertEqual(2, Snapshot.Count)
	AssertEqual("https://known.example", Snapshot[Known])
	AssertEqual("https://unjudged.example", Snapshot[Twin])
	Revert := Snapshot.Clone()
	AssertEqual("On", Revert.CaseSense, "native Clone preserves the exact compensation domain")
	AssertEqual(2, Revert.Count)
	AssertEqual("https://known.example", Revert[Known])
	AssertEqual("https://unjudged.example", Revert[Twin])
	Legacy := Map()
	Legacy.CaseSense := "Off"
	Legacy[Known] := "https://legacy.example"
	AssertEqual("Off", Legacy.CaseSense, "the fixture supplies a populated case-insensitive legacy Map")
	Upgraded := _GestureCloneActionParameters(Legacy)
	AssertEqual("On", Upgraded.CaseSense)
	AssertEqual("https://legacy.example", Upgraded[Known])
	AssertEqual("Off", Legacy.CaseSense, "populated legacy Map was never switched in place")
}
Test("Gestures: detached snapshots and exact native clones retain both case twins (gesture-binding-identity-snapshots)",
	TestGestures_ParameterSnapshotsKeepCaseTwins)


; Keeps compiled publication identity outside runtime assignment fixtures.
_GSBP_WithPublication(Body) {
	global SCRIPT_SHORTCUT_SLOTS, _ScriptShortcutBindingPublication
	PreviousSlots := IsSet(SCRIPT_SHORTCUT_SLOTS) ? SCRIPT_SHORTCUT_SLOTS : unset
	PreviousPublication := IsSet(_ScriptShortcutBindingPublication) ? _ScriptShortcutBindingPublication : unset
	try {
		SCRIPT_SHORTCUT_SLOTS := ["script_altgr_enter", "script_altgr_backspace", "script_altgr_delete", "script_altgr_escape"]
		_ScriptShortcutBindingPublication := ConfigBindingIdentityScriptPublication(SCRIPT_SHORTCUT_SLOTS)
		Body.Call()
	} finally {
		SCRIPT_SHORTCUT_SLOTS := IsSet(PreviousSlots) ? PreviousSlots : unset
		_ScriptShortcutBindingPublication := IsSet(PreviousPublication) ? PreviousPublication : unset
	}
}

TestGestures_ScriptBindingCorpus() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\config_binding_identity\script_vectors.json", "UTF-8"))
	Catalogue := ConfigBindingIdentityScriptPublication([
		"script_altgr_enter", "script_altgr_backspace", "script_altgr_delete", "script_altgr_escape"
	]).Catalogue
	AssertEqual(14, Corpus.Length, "independent handwritten script identity corpus")
	for Row in Corpus {
		Expected := Type(Row["expected"]) == "String" ? Row["expected"] : Row["expected"] ? "current" : "retired"
		AssertEqual(Expected, ConfigBindingIdentityScriptStatus(Row["binding"], Catalogue), Row["name"])
		AssertEqual("unjudged", ConfigBindingIdentityScriptStatus(Row["binding"]), Row["name"] . ": unpublished")
	}
}
Test("Gestures: script bindings replay an independent fourteen-vector corpus (script-binding-identity)",
	TestGestures_ScriptBindingCorpus)

TestGestures_ScriptPublicationIdentity() {
	_GSBP_WithPublication(_GSBP_PublicationIdentityBody)
}
_GSBP_PublicationIdentityBody() {
	global SCRIPT_SHORTCUT_SLOTS, _ScriptShortcutBindingPublication
	OriginalSlots := SCRIPT_SHORTCUT_SLOTS
	OriginalPublication := _ScriptShortcutBindingPublication
	Received := TomlConfigScriptSlotCatalogue()
	AssertEqual("script__", Received["prefix"])
	AssertEqual(4, Received["slots"].Count)
	AssertEqual("On", Received["slots"].CaseSense)
	Received["slots"].Delete("script_altgr_enter")
	Received["slots"]["removed_script_slot"] := true
	AssertEqual("current", TomlConfigParameterBindingStatus("script__script_altgr_enter"))
	AssertEqual("retired", TomlConfigParameterBindingStatus("script__removed_script_slot"))
	SCRIPT_SHORTCUT_SLOTS := OriginalSlots.Clone()
	AssertEqual("unjudged", TomlConfigParameterBindingStatus("script__removed_script_slot"), "foreign declaration identity withdraws authority")
	SCRIPT_SHORTCUT_SLOTS := OriginalSlots
	SCRIPT_SHORTCUT_SLOTS[1] := "foreign_slot"
	AssertEqual("unjudged", TomlConfigParameterBindingStatus("script__removed_script_slot"), "changed declaration withdraws authority")
	SCRIPT_SHORTCUT_SLOTS[1] := "script_altgr_enter"
	_ScriptShortcutBindingPublication := unset
	AssertEqual("unjudged", TomlConfigParameterBindingStatus("script__removed_script_slot"))
	_ScriptShortcutBindingPublication := OriginalPublication
	AssertEqual("retired", TomlConfigParameterBindingStatus("script__removed_script_slot"))
	for Binding in ["keyboard__removed_key", "tap_key__removed_key", "tap_hold__removed_key", "combination__removed_pair", "Script__removed_script_slot"]
		AssertEqual("unjudged", TomlConfigParameterBindingStatus(Binding), Binding)
}
Test("Gestures: script publication is detached, pure and bound to the compiled declaration (script-binding-identity)",
	TestGestures_ScriptPublicationIdentity)

TestGestures_ScriptPublicationRefusesMalformed() {
	for Ids in [[], [""], ["same", "same"], ["nested__id"], [false]]
		AssertThrows(ConfigBindingIdentityScriptPublication.Bind(Ids), "invalid compiled script declaration refuses")
	Sparse := Array()
	Sparse.Length := 2
	Sparse[1] := "script_altgr_enter"
	AssertThrows(ConfigBindingIdentityScriptPublication.Bind(Sparse), "a sparse declaration is not complete")
	for Catalogue in [Map(), Map("prefix", "script__", "slots", Map()), Map("prefix", "keyboard__", "slots", Map("key", true))]
		AssertThrows(ConfigBindingIdentityScriptStatus.Bind("script__removed", Catalogue), "malformed script publication refuses")
}
Test("Gestures: malformed script publication cannot invent retirement (script-binding-identity)",
	TestGestures_ScriptPublicationRefusesMalformed)

TestGestures_RetiredScriptSettersRefuse() {
	_GSBP_WithPublication(_GSBP_RetiredSettersBody)
}
_GSBP_RetiredSettersBody() {
	global GestureActionParameters
	Previous := GestureActionParameters
	Calls := []
	Writer := (*) => (Calls.Push("writer"), false)
	Notify := (*) => Calls.Push("notify")
	try {
		GestureActionParameters := Map()
		GestureActionParameters.CaseSense := "On"
		GestureActionParameters["Script__removed_script_slot__open_url"] := "https://unjudged.example"
		AssertFalse(GestureSetActionParameter("script__removed_script_slot", "open_url", "https://must-not-write.example", Writer, Notify))
		AssertEqual(0, Calls.Length)
		AssertEqual(1, GestureActionParameters.Count)
		Assignments := Map("script_altgr_enter", "none")
		Parameters := _GestureCloneActionParameters(GestureActionParameters)
		Candidate := Map("has_value", true, "key", "script__removed_script_slot__open_url", "value", "https://must-not-write.example")
		AssertFalse(_GestureCommitAssignment(&Assignments, &Parameters, "shortcuts.script_control", "script_altgr_enter", "open_url", Candidate, Writer, Notify))
		AssertEqual(0, Calls.Length)
		AssertEqual("none", Assignments["script_altgr_enter"])
		AssertEqual("https://unjudged.example", Parameters["Script__removed_script_slot__open_url"])
		Snapshot := _GestureCloneActionParameters(Map("script__removed_script_slot__open_url", "https://inverse.example"))
		AssertEqual("https://inverse.example", Snapshot["script__removed_script_slot__open_url"], "exact inverse is separate from setter admission")
	} finally GestureActionParameters := Previous
}
Test("Gestures: retired script parameter refuses both setter paths before ports (script-binding-identity)",
	TestGestures_RetiredScriptSettersRefuse)
