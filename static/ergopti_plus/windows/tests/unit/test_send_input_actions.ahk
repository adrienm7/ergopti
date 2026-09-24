; tests/unit/test_send_input_actions.ahk

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
