; tests/unit/platform/remap/keys/test_ai_action_gate.ahk

; ==============================================================================
; MODULE: AI Action Gate
; DESCRIPTION:
; With the AI off a key bound to an AI action stays the application's, on every
; key-claiming layer, and the switch-on arms it again with no reload. The bug: only
; the action's own refusal stood there, so the key was claimed and did nothing
; (a Space tap-hold whose tap is an AI action typed no space).
; ==============================================================================

#Requires AutoHotkey v2.0

global AAG_ACTION := "llm_generate_prediction"

; Runs Body(SetAi) with a menu state whose switch SetAi moves.
_AAG_WithAi(Body) {
	global _LLM_Menu
	Saved := _LLM_Menu
	try {
		_LLM_Menu := _LPP_Menu(false)
		Body.Call((On) => _LLM_Menu["enabled"] := On)
	} finally _LLM_Menu := Saved
}

; Runs Body with a function's Call replaced, the original put back after.
_AAG_WithFn(Fn, Replacement, Body) {
	Fn.DefineProp("Call", { Call: Replacement })
	try Body.Call()
	finally Fn.DeleteProp("Call")
}

_AAG_Predicate() {
	_AAG_WithAi(_Body)
	_Body(SetAi) {
		AssertTrue(AiActionIsAi("llm_agent_selection"))
		AssertFalse(AiActionIsAi("copy"))
		AssertFalse(AiActionIsAi(""))
		AssertFalse(AiActionIsAi(0), "a non-string is not an action")
		AssertTrue(AiActionBlocked(AAG_ACTION), "blocked with the AI off")
		AssertFalse(AiActionBlocked("copy"), "another action never is")
		SetAi(true)
		AssertFalse(AiActionBlocked(AAG_ACTION), "armed with the AI on, no reload")
	}
}
Test("AI gate: only an AI action is blocked, only while the AI is off (ai-off-keys)", _AAG_Predicate)

_AAG_TapHold() {
	_AAG_WithAi(_Body)
	_Body(SetAi) {
		TH := Map("keys", Map(
			"space", Map("enabled", true, "tap_action", AAG_ACTION),
			"tab", Map("enabled", true, "tap_action", "copy")))
		AssertEqual("", TapHoldTapAction(TH, "space"), "the blocked tap is the native one")
		AssertEqual(AAG_ACTION, TapHoldConfiguredTapAction(TH, "space"), "the menu still reads what is stored")
		AssertEqual("copy", TapHoldTapAction(TH, "tab"), "another tap is untouched")
		SetAi(true)
		AssertEqual(AAG_ACTION, TapHoldTapAction(TH, "space"), "the switch-on arms it at the next press")
	}
}
Test("AI gate: a blocked tap-hold tap falls back to the key's native tap (ai-off-keys)", _AAG_TapHold)

; The menu rows and the writer keep the stored action: a save with the AI off must
; not erase it, and the row must still name it.
_AAG_TapHoldReaders() {
	global TapHold
	Saved := TapHold
	_AAG_WithAi(_Body)
	_Body(SetAi) {
		global TapHold
		try {
			TapHold := Map("keys", Map("space", Map("enabled", true, "tap_action", AAG_ACTION)))
			AssertTrue(IsTapHoldTapActive("space", AAG_ACTION), "the row of the stored action stays checked")
			AssertFalse(IsTapHoldTapActive("space", ""), "the native row is not")
			AssertEqual(GestureActionDisplayLabel(AAG_ACTION, GestureBindingId("tap_hold", "space")),
				TapHoldCurrentTapLabel("space"), "the label names the stored action")
		} finally TapHold := Saved
	}
}
Test("AI gate: the tap-hold menu keeps the configured AI tap while the AI is off (ai-off-keys)", _AAG_TapHoldReaders)

_AAG_TapKey() {
	global TapKeyAssignments
	Saved := TapKeyAssignments
	_AAG_WithAi(_Body)
	_Body(SetAi) {
		global TapKeyAssignments
		try {
			TapKeyAssignments := Map("a", AAG_ACTION, "b", "copy")
			AssertFalse(TapKeyShouldFire("a"), "the key types as usual")
			AssertTrue(TapKeyShouldFire("b"), "another action fires")
			SetAi(true)
			AssertTrue(TapKeyShouldFire("a"), "armed by the switch-on")
		} finally TapKeyAssignments := Saved
	}
}
Test("AI gate: a tap key bound to an AI action is unarmed (ai-off-keys)", _AAG_TapKey)

_AAG_ScriptSlot() {
	global ScriptShortcutAssignments, ScriptShortcutChordsOn
	SavedSlots := IsSet(ScriptShortcutAssignments) ? ScriptShortcutAssignments : unset
	SavedOn := IsSet(ScriptShortcutChordsOn) ? ScriptShortcutChordsOn : unset
	_AAG_WithAi(_Body)
	_Body(SetAi) {
		global ScriptShortcutAssignments, ScriptShortcutChordsOn
		try {
			ScriptShortcutChordsOn := true
			ScriptShortcutAssignments := Map("slot", AAG_ACTION)
			AssertFalse(ScriptShortcutSlotRunsAction("slot", false), "the chord stays the system's")
			SetAi(true)
			AssertTrue(ScriptShortcutSlotRunsAction("slot", false), "armed by the switch-on")
		} finally {
			ScriptShortcutAssignments := IsSet(SavedSlots) ? SavedSlots : unset
			ScriptShortcutChordsOn := IsSet(SavedOn) ? SavedOn : unset
		}
	}
}
Test("AI gate: a script chord bound to an AI action is unarmed (ai-off-keys)", _AAG_ScriptSlot)

_AAG_Pair() {
	Pair := KeyCombinationPairId("left_alt", "caps_lock")
	Down := _KCT_Keys(["left_alt"])
	_AAG_WithAi(_Body)
	_Body(SetAi) {
		_KCT_With(Map(Pair, AAG_ACTION), Map(), _TapOnly)
		_TapOnly() {
			AssertFalse(KeyCombinationOwns("caps_lock", Down), "a pair with only an AI tap leaves the key its own")
			SetAi(true)
			AssertTrue(KeyCombinationOwns("caps_lock", Down), "the switch-on takes it again")
			Events := []
			AssertEqual("tap", KeyCombinationFire("caps_lock", _KCT_Ports(Events)))
			AssertEqual("tap:left_alt>caps_lock:" . AAG_ACTION, Events[Events.Length], "and runs the action")
			SetAi(false)
		}
		_KCT_With(Map(Pair, AAG_ACTION), Map(Pair, "shift"), _WithHold)
		_WithHold() {
			AssertTrue(KeyCombinationOwns("caps_lock", Down), "a hold is never an action: the pair keeps the key")
			Events := []
			AssertEqual("hold", KeyCombinationFire("caps_lock", _KCT_Ports(Events, true)),
				"a release inside the threshold runs no tap")
			for Event in Events
				AssertFalse(InStr(Event, "tap:"), "no AI action ran")
		}
	}
}
Test("AI gate: an ordered pair's AI tap is unarmed, its hold stays (ai-off-keys)", _AAG_Pair)

_AAG_Gesture() {
	global GestureAssignments, Features
	Saved := [GestureAssignments, Features["gestures"]["enabled"]]
	Reached := 0
	_AAG_WithAi(_Body)
	_Body(SetAi) {
		global GestureAssignments, Features
		try {
			GestureAssignments := Map("tap_3", AAG_ACTION)
			Features["gestures"]["enabled"] := true
			_AAG_WithFn(GestureReleaseOwnedCarrierModifiers, (*) => (Reached += 1, false), _Dispatch)
		} finally {
			GestureAssignments := Saved[1]
			Features["gestures"]["enabled"] := Saved[2]
		}
		_Dispatch() {
			GestureDispatch("tap_3")
			AssertEqual(0, Reached, "held back before anything of the dispatch runs")
			SetAi(true)
			GestureDispatch("tap_3")
			AssertEqual(1, Reached, "the switch-on dispatches it again")
		}
	}
}
Test("AI gate: a gesture bound to an AI action is held back (ai-off-keys)", _AAG_Gesture)

_AAG_KeyboardDelivery() {
	global KeyboardShortcutAssignments
	Saved := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	Ran := []
	_AAG_WithAi(_Body)
	_Body(SetAi) {
		global KeyboardShortcutAssignments
		try {
			KeyboardShortcutAssignments := Map("ctrl_x", AAG_ACTION)
			_AAG_WithFn(GestureInvokeAction, (Self, Action, Binding := "", *) => Ran.Push(Action), _Deliver)
		} finally KeyboardShortcutAssignments := IsSet(Saved) ? Saved : unset
		_Deliver() {
			RunKeyboardShortcutAction("ctrl_x")
			AssertEqual(0, Ran.Length, "a press queued across the switch-off runs nothing")
			SetAi(true)
			RunKeyboardShortcutAction("ctrl_x")
			AssertEqual(1, Ran.Length, "the slot runs with the AI on")
		}
	}
}
Test("AI gate: a keyboard slot re-reads the switch at delivery (ai-off-keys)", _AAG_KeyboardDelivery)

; The slots a native hotkey owns cannot ask at each press: they release and re-arm
; their exact handle, and only theirs.
_AAG_KeyboardHandles() {
	global KeyboardShortcutAssignments
	SavedAssignments := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	Handles := _KeyboardShortcutAiHandles()
	SavedHandles := Handles.Clone()
	State := MagicEditorState()
	SavedClaim := State["ordinary_claim"], SavedInitialized := State["initialized"]
	_AAG_WithAi(_Body)
	_Body(SetAi) {
		global KeyboardShortcutAssignments
		try {
			Handles.Clear()
			State["initialized"] := false
			KeyboardShortcutAssignments := Map("ctrl_x", AAG_ACTION, "ctrl_y", "copy", "win_z", AAG_ACTION)
			KeyboardShortcutRecordHandle("ctrl_x", AAG_ACTION, "h-ai")
			KeyboardShortcutRecordHandle("ctrl_y", "copy", "h-copy")
			KeyboardShortcutRecordHandle("win_z", AAG_ACTION, "h-broker")
			AssertFalse(Handles.Has("ctrl_y"), "a slot with another action does not follow the switch")
			; The broker took win_z: its native hotkey stays off, its criterion asks.
			State["ordinary_claim"] := Map("slot", "win_z", "slots", ["win_z"])
			State["initialized"] := true
			Calls := []
			Record := (Handle, On) => (Calls.Push(Handle . "=" . (On ? 1 : 0)), true)
			AssertTrue(KeyboardShortcutsFollowAiSwitch(Record), "the switch-off settles")
			AssertEqual(1, Calls.Length, "only the AI slot the broker does not own")
			AssertEqual("h-ai=0", Calls[1], "released while the AI is off")
			SetAi(true)
			Calls.Length := 0
			AssertTrue(KeyboardShortcutsFollowAiSwitch(Record), "the switch-on settles")
			AssertEqual("h-ai=1", Calls[1], "armed by the switch-on")
			AssertFalse(KeyboardShortcutsFollowAiSwitch((*) => false), "a refusal is reported")
			AssertFalse(KeyboardShortcutsFollowAiSwitch(_AAG_Throw), "an exception too, not raised into the commit")
		} finally {
			KeyboardShortcutAssignments := IsSet(SavedAssignments) ? SavedAssignments : unset
			Handles.Clear()
			for Slot, Handle in SavedHandles
				Handles[Slot] := Handle
			State["ordinary_claim"] := SavedClaim
			State["initialized"] := SavedInitialized
		}
	}
}
Test("AI gate: native keyboard slots release and re-arm their exact handle (ai-off-keys)", _AAG_KeyboardHandles)

; The picker greys the two actions the catalogue marks, at each open.
_AAG_Picker() {
	_AAG_WithAi(_Body)
	_Body(SetAi) {
		Off := _AAG_PickerRows()
		for Id in ["llm_agent_selection", "llm_agent_command"] {
			AssertTrue(Off[Id].HasOwnProp("Disabled"), Id . " is greyed while the AI is off")
			AssertEqual(t("dialog.action_picker.requires_ai"), Off[Id].Hint, "with the dedicated reason")
		}
		AssertFalse(Off[AAG_ACTION].HasOwnProp("Disabled"), "an action the catalogue does not mark stays as it was")
		Page := _ActPickWeb_BuildInitJs("Title", "none", [Off["llm_agent_command"]], false)
		AssertContains(Page, '"disabled":true', "the page greys the row")
		AssertContains(Page, JsonStringLiteral(t("dialog.action_picker.requires_ai")), "with its reason")
		SetAi(true)
		On := _AAG_PickerRows()
		AssertFalse(On["llm_agent_selection"].HasOwnProp("Disabled"), "offered again with the AI on, no reload")
		AssertFalse(On["llm_agent_command"].HasOwnProp("Disabled"))
		AssertFalse(InStr(_ActPickWeb_BuildInitJs("Title", "none", [On["llm_agent_command"]], false), '"disabled":true'))
	}
}
Test("AI gate: the picker greys the agent's manual actions with the AI-off hint (ai-off-picker)", _AAG_Picker)

; @returns {Map} The action rows of the picker, by id.
_AAG_PickerRows() {
	Rows := Map()
	for _, Item in GestureActionPickerItems() {
		if (Item.Type == "action")
			Rows[Item.Id] := Item
	}
	return Rows
}

_AAG_Throw(*) {
	throw Error("Controlled native refusal.")
}

_AAG_Broker() {
	global KeyboardShortcutAssignments, CategoryEnabled
	SavedAssignments := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	SavedCategory := CategoryEnabled.Get("Shortcuts", true)
	State := MagicEditorState()
	Saved := State.Clone()
	_AAG_WithAi(_Body)
	_Body(SetAi) {
		global KeyboardShortcutAssignments, CategoryEnabled
		try {
			CategoryEnabled["Shortcuts"] := true
			KeyboardShortcutAssignments := Map("win_sc029", AAG_ACTION)
			State["initialized"] := true
			State["decision"] := 0
			State["legacy"] := Map()
			State["layouts"] := Map()
			State["ordinary_physical"] := Map("SC029", Map("slot", "win_sc029", "action", AAG_ACTION))
			_AAG_WithFn(_MagicEditorAdmission, (*) => Map("master", true, "paused", false, "inhibited", false), _Press)
		} finally {
			KeyboardShortcutAssignments := IsSet(SavedAssignments) ? SavedAssignments : unset
			CategoryEnabled["Shortcuts"] := SavedCategory
			for Key, Value in Saved
				State[Key] := Value
		}
		_Press() {
			AssertFalse(_MagicEditorBrokerWinner("SC029") is Map, "the broker leaves the chord to the system")
			SetAi(true)
			AssertEqual("ordinary", _MagicEditorBrokerWinner("SC029")["kind"], "armed by the switch-on")
			SetAi(false)
			AssertEqual("none", _MagicEditorArmedAction("win_sc029"), "no contextual delivery of an AI action")
		}
	}
}
Test("AI gate: the physical Win broker asks at each press (ai-off-keys)", _AAG_Broker)
