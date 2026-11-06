; tests/unit/modules/shortcuts/test_send_input_actions.ahk

; ==============================================================================
; MODULE: send_text, send_key and send_shortcut Actions (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/action_parameters/send_input_vectors.json, which
; the macOS and Linux suites replay too, through SendInputParse and the action
; validator, then fires the three actions from a binding and checks the exact
; synthetic input: the payload SendInput receives, and that it is sent inside
; the hotstring buffers' synthetic transaction (Critical), which is what keeps
; the prefix watcher from reading it back as typing.
;
; ROOT CAUSE ENCODED:
; No action could type a chosen text, press a chosen key or press a chosen
; shortcut; the catalogue had fixed keystrokes only, so a key bound to "type
; bonjour" or "Ctrl+A" had nothing to run.
; ==============================================================================

#Requires AutoHotkey v2.0

_SIA_ReplayCorpus() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\action_parameters\send_input_vectors.json"
	AssertTrue(FileExist(Path) != "", "the send-input corpus must exist at " . Path)
	Corpus := JsonParse(FileRead(Path, "UTF-8"))
	Actions := Map("text", "send_text", "key", "send_key", "shortcut", "send_shortcut")
	for Kind, Action in Actions
		AssertEqual(Kind, GestureActionParameterSpec(Action), Action . " parameter kind")
	Checked := 0
	for _, Vector in Corpus["vectors"] {
		Value := _SIA_Repeat(Vector["value"], Vector.Get("repeat", 1))
		Valid := !Vector.Has("valid") || Vector["valid"]
		Parsed := SendInputParse(Vector["kind"], Value)
		ErrorText := ""
		AssertEqual(Valid, GestureValidateActionParameter(Actions[Vector["kind"]], Value, &ErrorText),
			Vector["id"] . ": validation")
		if !Valid {
			AssertEqual("", Parsed, Vector["id"] . ": an invalid value parses to nothing")
			AssertTrue(ErrorText != "", Vector["id"] . ": a refusal explains itself")
		} else {
			AssertTrue(Parsed is Map, Vector["id"] . ": a valid value parses")
			AssertEqual(_SIA_Repeat(Vector["canonical"], Vector.Get("canonical_repeat", 1)),
				Parsed["canonical"], Vector["id"] . ": canonical form")
			AssertEqual(Vector.Get("named", ""), Parsed.Get("named", ""), Vector["id"] . ": named key")
			AssertEqual(Vector.Get("char", ""), Parsed.Get("char", ""), Vector["id"] . ": character key")
			if (Vector["kind"] == "shortcut")
				AssertEqual(_SIA_Join(Vector["mods"]), _SIA_Join(Parsed["mods"]), Vector["id"] . ": modifiers")
		}
		Checked += 1
	}
	AssertTrue(Checked >= 40, "expected at least 40 send-input vectors, found " . Checked)
}
Test("send input: the text, key and shortcut parameters replay the shared corpus (send-input-actions)", _SIA_ReplayCorpus)

_SIA_Repeat(Text, Count) {
	Out := ""
	loop Count
		Out .= Text
	return Out
}

_SIA_Join(Items) {
	Out := ""
	for _, Item in Items
		Out .= (Out = "" ? "" : ",") . Item
	return Out
}

; Fires one action for a binding holding Value and returns what SendInput
; received, each payload suffixed with "|critical" when it was sent inside the
; synthetic transaction.
_SIA_FireKey(Action, Value) {
	global GestureActionParameters, _AHK_SendInput
	Binding := GestureBindingId("tap_key", "number_row_right_2")
	SavedParameters := GestureActionParameters
	SavedSend := _AHK_SendInput
	Sent := []
	try {
		GestureActionParameters := Map(GestureActionParameterKey(Binding, Action), Value)
		_AHK_SendInput := (Keys) => (Sent.Push(Keys . (A_IsCritical ? "|critical" : "")), 0)
		GestureInvokeAction(Action, Binding)
	} finally {
		GestureActionParameters := SavedParameters
		_AHK_SendInput := SavedSend
	}
	return _SIA_Join(Sent)
}

_SIA_KeysAndShortcuts() {
	global GESTURE_ACTIONS
	for _, Action in ["send_text", "send_key", "send_shortcut"]
		AssertTrue(GESTURE_ACTIONS.Has(Action), Action . " must be a registered action")
	AssertEqual("^{a}|critical", _SIA_FireKey("send_shortcut", "ctrl+a"), "Ctrl+A")
	AssertEqual("^{a}|critical", _SIA_FireKey("send_shortcut", "primary+a"), "primary is Control on Windows")
	AssertEqual("^{a}|critical", _SIA_FireKey("send_shortcut", "primary+ctrl+A"), "primary and ctrl collapse into one Control")
	AssertEqual("^+{Tab}|critical", _SIA_FireKey("send_shortcut", "shift+ctrl+tab"), "named key with two modifiers")
	AssertEqual("#{e}|critical", _SIA_FireKey("send_shortcut", "super+e"), "super is the Windows key")
	AssertEqual("!{F4}|critical", _SIA_FireKey("send_shortcut", "alt+F4"), "function key")
	AssertEqual("{Enter}|critical", _SIA_FireKey("send_key", "Enter"), "named key")
	AssertEqual("{PgDn}|critical", _SIA_FireKey("send_key", "pgdn"), "alias")
	AssertEqual("{{}|critical", _SIA_FireKey("send_key", "{"), "a brace is braced, not read as a key name")
	AssertEqual("{é}|critical", _SIA_FireKey("send_key", "é"), "a character key")
	AssertEqual("{U+10000}|critical", _SIA_FireKey("send_key", Chr(0x10000)), "the first supplementary scalar uses AHK's explicit Unicode syntax")
	AssertEqual("{U+1F44B}|critical", _SIA_FireKey("send_key", Chr(0x1F44B)), "an accepted emoji cannot become an unknown two-unit braced key name")
	AssertEqual("{U+10FFFF}|critical", _SIA_FireKey("send_key", Chr(0x10FFFF)), "the final Unicode scalar retains every surrogate-pair bit")
	AssertEqual("^{U+1F44B}|critical", _SIA_FireKey("send_shortcut", "ctrl+" . Chr(0x1F44B)), "shortcut character keys share the same scalar adapter")
	AssertEqual("", _SIA_FireKey("send_shortcut", "a"), "an invalid stored value presses nothing")
	AssertEqual("", _SIA_FireKey("send_key", ""), "an empty stored value presses nothing")
}
Test("send input: send_key and send_shortcut press the exact keys inside the synthetic transaction (send-input-actions)", _SIA_KeysAndShortcuts)

_SIA_TypesText() {
	global GestureActionParameters, _SendHook
	Binding := GestureBindingId("tap_key", "number_row_right_1")
	SavedParameters := GestureActionParameters
	SavedHook := _SendHook
	Sent := []
	try {
		GestureActionParameters := Map(GestureActionParameterKey(Binding, "send_text"), "bonjour cela va bien?")
		; OnlyText and A_IsCritical recorded with the payload: {Text} keeps every
		; character literal, and Critical is the synthetic transaction.
		_SendHook := (Fn, Args*) => (Sent.Push(Fn . "|" . Args[1] . "|" . Args[2]
			. (A_IsCritical ? "|critical" : "")), "")
		GestureInvokeAction("send_text", Binding)
		GestureActionParameters := Map(GestureActionParameterKey(Binding, "send_text"), "a`nb")
		GestureInvokeAction("send_text", Binding)
	} finally {
		GestureActionParameters := SavedParameters
		_SendHook := SavedHook
	}
	AssertEqual("SendFinalResult|bonjour cela va bien?|1|critical", _SIA_Join(Sent),
		"one exact {Text} send inside the synthetic transaction, and nothing for an invalid value")
}
Test("send input: send_text types the stored text through the final-result primitive (send-input-actions)", _SIA_TypesText)

; The action picker's own editor collects the value before the assignment runs:
; the prompt that assignment reaches must take it instead of asking again, and
; only for the action it was collected for. A valid value is used, so this test
; never opens the native InputBox.
_SIA_PickedValueSkipsThePrompt() {
	global _GesturePickedParameter
	Binding := GestureBindingId("tap_key", "number_row_left")
	Left := ""
	try {
		GestureOfferPickedParameter("send_shortcut", "ctrl+shift+t")
		Candidate := GesturePromptActionParameter(Binding, "send_shortcut")
		Left := _GesturePickedParameter
	} finally {
		GestureClearPickedParameter()
	}
	AssertTrue(Candidate is Map && Candidate["has_value"], "the picked value is the parameter")
	AssertEqual(GestureActionParameterKey(Binding, "send_shortcut"), Candidate["key"], "stored under the binding")
	AssertEqual("ctrl+shift+t", Candidate["value"], "stored as the editor collected it")
	AssertFalse(Left is Map, "the value answers one prompt only")
}
Test("send input: a value the picker's editor collected is used without a prompt (send-input-actions)", _SIA_PickedValueSkipsThePrompt)

_SNK_ChildSource() {
	global _DriverDir
	Code := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn VarUnset, Off`n"
	Code .= "#Include " . _DriverDir . "\_generated\config_keys.ahk`n"
	for Symbol in ["SendInputParse", "JsonParse", "HS_RunSyntheticInputTransaction", "_TextCompleteTailScalar"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "The actual scalar producer must have a canonical owner: " . Symbol)
		Code .= "#Include " . Owner . "`n"
	}
	for Name in ["TextPressKey", "_TextSenderNormalizeModifierKey", "_TextSenderModifierPrefix", "_TextSenderKeystroke",
		"_TextSenderModifierWords", "_TextSenderSustainedKey", "_TextSenderSendInput", "_TextSenderAtSendLevel",
		"_SendVerdictSucceeded", "HSE_WordResetFlagCurrent", "HSE_FeedReset", "_PrefixHasIncompleteFragment",
		"_PrefixCommitInputContext", "_PrefixSetBuffer", "_PrefixCaptureTooltipOwner", "_PrefixFinishInputContext",
		"_PrefixInputCommitStillCurrent", "_PrefixTooltipOwnerStillCurrent", "_ResetPrefixBuffer", "_NotifySuggestionDismissed",
		"TapHoldOwnsShortcut", "TapHoldTapInDispatch", "_TH_SyntheticKeyList", "_TH_HoldMakesShortcuts"] {
		Body := _DriverFuncBody(Name)
		AssertTrue(Body != "", "The complete real composition dependency must exist: " . Name)
		Code .= Body . "`n"
	}
	return Code . FSReadStrict(_DriverDir . "\tests\fixtures\send_key_native_scalar_body.ahk")
}
_SNK_Case(Mode) {
	global _SharedDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unretired native sender prevents another probe.")
	Root := A_Temp . "\ergopti_send_key_scalar_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Root)
	Script := Root . "\subject.ahk"
	AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _SNK_ChildSource()))
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}, Handle := 0, Primary := 0, Retired := false
	PreviousCritical := Critical("Off")
	try {
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, "--allow-explicit-owned-edit-send-key", Mode, _SharedDir], _SICS_Complete.Bind(State))
		AssertTrue(Handle.start(), "The exact native scalar child must start.")
		Started := A_TickCount
		while !State.Calls && TickElapsed(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, "The exact native scalar child must settle.")
		_TestPrint("# send-key-native-scalar " . Mode . " stdout=" . State.Output . " stderr=" . State.ErrorText)
		AssertEqual(0, State.Code, "Native send-key scalar emission failed: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText)
		AssertContains(State.Output, "PASS send-key-native-scalar " . Mode)
	} catch as Err {
		Primary := Err
	}
	try {
		if !IsObject(Handle)
			Retired := true
		else {
			Started := A_TickCount
			loop {
				Accepted := Handle.terminate()
				Retired := Accepted is Integer && Accepted == 1
				if Retired || TickElapsed(Started) >= 5000
					break
				_SR_TreePoll()
				Sleep(10)
			}
		}
	} catch as Err {
		if !IsObject(Primary)
			Primary := Err
	}
	try {
		if !Retired
			RetirementDebt := Handle
		else if !IsObject(Primary)
			DirDelete(Root, true)
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The native sender must physically retire.")
}
for _SNK_Mode in ["ascii", "bmp", "astral"]
	Test("Send key native scalar: " . _SNK_Mode . " reaches the receiving Edit (send-key-native-scalar)", _SNK_Case.Bind(_SNK_Mode))
