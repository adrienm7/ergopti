; tests/unit/hotstrings/engine/engine/test_action_entry.ahk

; ==============================================================================
; MODULE: Hotstring Action Entries (Windows port)
; DESCRIPTION:
; Replays the fields and plans of
; _shared/tests/corpus/hotstrings/action_entry_vectors.json, which the macOS
; and Linux suites replay through the shared Lua module
; (_shared/tests/lua/hotstrings/action_entry_contract.lua), through
; hotstrings/engine/matcher/action_entry.ahk: the action fields an entry
; carries or the refusal that skips it, then the edit before the action with
; the trigger erased or kept as typed, end character included. Also pins the
; dispatch: a workflow, a plain action, and the refusal of a parameterised one.
; The reader, the matcher and the editor's saves replay the matches and the
; saves of the same corpus: an action entry registered from its TOML line,
; erased or kept as typed, its action scheduled once and never chained, and
; its fields written and read back by the personal writer.
;
; ROOT CAUSE ENCODED:
; A Windows hotstring could only type text: no entry could run an action or a
; workflow, and nothing kept the typed text when the user wanted it kept.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================================
; ==============================================
; ======= 1/ Fields, plans and dispatch ========
; ==============================================
; ==============================================

_TAE_Corpus() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\hotstrings\action_entry_vectors.json"
	AssertTrue(FileExist(Path) != "", "the action entry corpus must exist at " . Path)
	return JsonParseLossless(FileRead(Path, "UTF-8"))
}

; A lossless spec as the matcher hands it: true and false are booleans.
_TAE_Plain(Value) {
	global JSON_TRUE, JSON_FALSE, JSON_NULL
	if IsObject(Value) && Value == JSON_TRUE
		return true
	if IsObject(Value) && Value == JSON_FALSE
		return false
	if Value is Map {
		Out := Map()
		for Key, Item in Value
			if !(IsObject(Item) && Item == JSON_NULL)
				Out[Key] := _TAE_Plain(Item)
		return Out
	}
	return Value
}

_TAE_Fields() {
	global JSON_NULL
	Count := 0
	for Vector in _TAE_Corpus()["fields"] {
		Count += 1
		Id := Vector["id"]
		Fields := HSE_ActionEntryFields(Vector["entry"], &Refusal)
		AssertEqual(Vector.Get("refusal", ""), Refusal, Id . " refusal")
		Wanted := Vector.Get("fields", JSON_NULL)
		if IsObject(Wanted) && Wanted == JSON_NULL {
			AssertEqual(0, Fields, Id . " runs no action")
			continue
		}
		AssertTrue(Fields is Map, Id . " carries action fields")
		Plain := _TAE_Plain(Wanted)
		for Key, Value in Plain
			AssertEqual(Value, Fields[Key], Id . " " . Key)
		AssertEqual(Plain.Get("workflow", ""), Fields.Get("workflow", ""), Id . " workflow")
	}
	AssertTrue(Count >= 10, "the corpus holds the field vectors, got " . Count)
}
Test("hotstring actions: the field vectors replay through the Windows reader (hotstring-actions)", _TAE_Fields)

_TAE_Plans() {
	Count := 0
	for Vector in _TAE_Corpus()["plans"] {
		Count += 1
		Plan := HSE_ActionEntryPlan(_TAE_Plain(Vector["spec"]))
		Wanted := _TAE_Plain(Vector["plan"])
		AssertEqual(Wanted["erase"], Plan["erase"], Vector["id"] . " erase")
		AssertEqual(Wanted["text"], Plan["text"], Vector["id"] . " text")
		AssertEqual(Wanted.Get("tail", ""), Plan["tail"], Vector["id"] . " tail")
	}
	AssertTrue(Count >= 8, "the corpus holds the plan vectors, got " . Count)
}
Test("hotstring actions: the plan vectors replay through the Windows plan (hotstring-actions)", _TAE_Plans)

_TAE_Dispatch() {
	Calls := []
	Ports := Map("run_workflow", (Parameter) => (Calls.Push("wf:" . Parameter["id"]), true),
		"execute", (Action) => (Calls.Push(Action), true),
		"parameter_spec", (Action) => Action == "run_command" ? "command" : "")
	AssertTrue(HSE_ActionEntryDispatch(Map("action", "run_workflow", "workflow", "w"), Ports), "a workflow runs")
	AssertTrue(HSE_ActionEntryDispatch(Map("action", "select_all"), Ports), "a plain action runs")
	AssertFalse(HSE_ActionEntryDispatch(Map("action", "run_command"), Ports, &Refusal), "a parameterised action does not")
	AssertEqual("parameterised_action", Refusal, "and says why")
	AssertEqual("wf:w,select_all", Calls[1] . "," . Calls[2], "each ran through its executor, once")
	AssertEqual(2, Calls.Length, "the refused action reached no executor")
}
Test("hotstring actions: dispatch runs a workflow, a plain action, and refuses a parameter (hotstring-actions)",
	_TAE_Dispatch)





; ====================================================
; ====================================================
; ======= 2/ Reader, matcher and editor saves ========
; ====================================================
; ====================================================

; Registers one TOML line as the section loader does, the action fields
; included. @returns {Boolean} Whether the loader registers it.
_TAE_RegisterLine(Line) {
	global _HOTSTRING_ENTRY_PATTERN
	if !RegExMatch(Line, _HOTSTRING_ENTRY_PATTERN, &Match)
		return false
	Flags := (Match[4] == "true" ? "*" : "") . (Match[3] == "true" ? "" : "?") . (Match[7] == "true" ? "C" : "")
	Options := Map("TimeActivationSeconds", 0, "FinalResult", Match[6] == "true", "Priority", 50)
	if !HS_EntryApplyAction(Line, Options, "test")
		return false
	HSE_RegisterFromTomlFlags(Match[5] == "true", Flags, UnescapeTomlString(Match[1]),
		UnescapeTomlString(Match[2]), Options)
	return true
}

; Types Text, then the terminator, into a clean engine holding Line.
; @returns {Object} { Bursts: the injected bursts, Actions: the scheduled fields }.
_TAE_Replay(Line, Text, Terminator) {
	global _AHK_SendInput, _SendHook, _HotstringRegistrar, _HSE_EntryActionHook, HSE_LastEndChar
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Saved := [_AHK_SendInput, _SendHook, _HotstringRegistrar, _HSE_EntryActionHook, HSE_WORD_TERMINATORS,
		HSE_CONSUMED_DELIMITERS]
	World := { Bursts: [], Actions: [] }
	_AHK_SendInput := (Keys) => (World.Bursts.Push(Keys), 1)
	_SendHook := 0
	_HotstringRegistrar := 0
	_HSE_EntryActionHook := (Fields) => World.Actions.Push(Fields)
	HSE_WORD_TERMINATORS := " `t`n"
	HSE_CONSUMED_DELIMITERS := ""
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_FeedReset(true)
	try {
		AssertTrue(_TAE_RegisterLine(Line), "the reader registers " . Line)
		for Char in StrSplit(Text . Terminator) {
			AppState_TouchLastSentKey(Char)
			Match := HSE_FeedChar(Char, true)
			if IsObject(Match) {
				Effect := 0
				HSE_DispatchMatch(Match, HSE_LastEndChar, &Effect)
			}
		}
		return World
	} finally {
		_AHK_SendInput := Saved[1], _SendHook := Saved[2], _HotstringRegistrar := Saved[3]
		_HSE_EntryActionHook := Saved[4], HSE_WORD_TERMINATORS := Saved[5], HSE_CONSUMED_DELIMITERS := Saved[6]
		HSE_RegistryClear()
		HSE_HardReset()
	}
}

_TAE_Matches() {
	global JSON_NULL
	Count := 0
	for Vector in _TAE_Corpus()["matches"] {
		Count += 1
		Id := Vector["id"]
		Wanted := Vector["expected"]
		Terminator := Vector.Get("terminator", "")
		World := _TAE_Replay(Vector["line"], Vector["typed"], Terminator)
		AssertEqual(1, World.Bursts.Length, Id . " fires once")
		AssertTrue(RegExMatch(World.Bursts[1], "s)^\{BackSpace (\d+)\}\{Text\}(.*)$", &Burst), Id . " burst shape")
		AssertEqual(Wanted["backspace_count"], Integer(Burst[1]), Id . " backspace_count")
		Replay := Wanted.Get("replay_terminator", JSON_NULL)
		Tail := (IsObject(Replay) && Replay == JSON_NULL) ? "" : Replay
		; A kept text replays nothing: the end character is already on screen.
		AssertEqual(Wanted["replacement"] . Tail, Burst[2], Id . " replacement then replayed end character")
		Action := Wanted["action"]
		if IsObject(Action) && Action == JSON_NULL {
			AssertEqual(0, World.Actions.Length, Id . " runs no action")
			continue
		}
		AssertEqual(1, World.Actions.Length, Id . " schedules its action once")
		AssertEqual(Action, World.Actions[1]["action"], Id . " action")
		AssertEqual(_TAE_Plain(Wanted).Get("workflow", ""), World.Actions[1].Get("workflow", ""), Id . " workflow")
		if Wanted.Has("erase_trigger")
			AssertEqual(_TAE_Plain(Wanted)["erase_trigger"], World.Actions[1]["erase_trigger"], Id . " erase_trigger")
	}
	AssertTrue(Count >= 5, "the corpus holds the match vectors, got " . Count)
}
Test("hotstring actions: the match vectors replay through the Windows reader and matcher (hotstring-actions)",
	_TAE_Matches)

_TAE_ReaderRefuses() {
	AssertFalse(_TAE_RegisterLine('"a" = { action = "Bad Action", output = "x" }'), "a bad action id is skipped")
	AssertFalse(_TAE_RegisterLine('"a" = { action = "run_workflow" }'), "run_workflow without a workflow is skipped")
	AssertFalse(_TAE_RegisterLine('"a" = { output = "x", workflow = "w" }'), "a workflow without an action is skipped")
	AssertFalse(_TAE_RegisterLine('"a" = { erase_trigger = false }'), "an entry that types and runs nothing is skipped")
	Fields := HS_EntryLineAction('"a" = { output = "action = x" }', &Refusal)
	AssertEqual(0, Fields, "a key spelled inside the output is no action")
	AssertEqual("", Refusal, "and no refusal")
}
Test("hotstring actions: the reader skips refused action fields (hotstring-actions)", _TAE_ReaderRefuses)

_TAE_NeverChains() {
	Link := { Replacement: "x", Trigger: "a", OnlyText: true, EntryAction: Map("action", "select_all") }
	AssertFalse(_HSE_IsCascadeLink(Link), "an action entry is never a cascade link")
}
Test("hotstring actions: an action entry never chains (hotstring-actions)", _TAE_NeverChains)

_TAE_Saves() {
	global ScriptInformation, _ReadPersonalTomlCache, _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\hotstrings\action_entry_vectors.json", "UTF-8"))
	Count := 0
	for Vector in Corpus["saves"] {
		Count += 1
		Path := A_Temp . "\ergopti_action_entry_save_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Count . ".toml"
		OldPath := ScriptInformation["PersonalTomlPath"], OldCache := _ReadPersonalTomlCache
		try {
			ScriptInformation["PersonalTomlPath"] := Path
			_ReadPersonalTomlCache := false
			AssertTrue(FSWriteDurable(Path, Vector["source"]))
			Data := Vector["model"]
			; The editor always sends each section's description.
			for Name, Section in Data["sections"]
				if !Section.Has("description")
					Section["description"] := Name
			if Vector.Has("refusal") {
				Order := _PersonalTomlCanonicalSectionOrder(Data, &Detail)
				AssertFalse(_PersonalTomlModelFieldsAreValid(Data, Order, &Detail), Vector["name"])
				AssertContains(Detail, Vector["refusal"])
				AssertFalse(WritePersonalToml(Data), Vector["name"] . ": the writer refuses")
				AssertEqual(Vector["source"], FSReadUtf8Exact(Path), "the refusal keeps the source")
				continue
			}
			AssertTrue(WritePersonalToml(Data), Vector["name"])
			Actual := FSReadUtf8Exact(Path)
			for Text in Vector.Get("contains", [])
				AssertContains(Actual, Text)
			for Text in Vector.Get("absent", [])
				AssertFalse(InStr(Actual, Text, true), Vector["name"] . ": " . Text . " is absent")
			; The written entry reads back with the same action fields.
			Wanted := Data["sections"]["words"]["entries"][1]
			Read := ReadPersonalToml(true)["sections"]["words"]["entries"][1]
			AssertEqual(Wanted.Get("action", ""), Read.Get("action", ""), Vector["name"] . ": action reads back")
			AssertEqual(Wanted.Get("workflow", ""), Read.Get("workflow", ""), Vector["name"] . ": workflow reads back")
			AssertEqual(Wanted.Get("erase_trigger", true), Read.Get("erase_trigger", true),
				Vector["name"] . ": erase_trigger reads back")
		} finally {
			try FileDelete(Path)
			_PersonalTomlInvalidateCaches(Path)
			ScriptInformation["PersonalTomlPath"] := OldPath
			_ReadPersonalTomlCache := OldCache
		}
	}
	AssertTrue(Count >= 4, "the corpus holds the save vectors, got " . Count)
}
Test("hotstring actions: the save vectors replay through the Windows personal writer (hotstring-actions)", _TAE_Saves)

_TAE_Runner() {
	Calls := []
	Ports := Map("run_workflow", (Parameter) => (Calls.Push("wf:" . Parameter["id"]), true),
		"execute", (Action) => (Calls.Push(Action), true),
		"parameter_spec", (Action) => Action == "run_command" ? "command" : "")
	AssertTrue(WorkflowsRunEntryAction(Map("action", "run_workflow", "workflow", "wf_a"), Ports), "a workflow runs")
	AssertTrue(WorkflowsRunEntryAction(Map("action", "select_all"), Ports), "a plain action runs")
	AssertFalse(WorkflowsRunEntryAction(Map("action", "run_command"), Ports), "a parameterised action is refused")
	AssertEqual("wf:wf_a,select_all", Calls[1] . "," . Calls[2], "each through its executor")
	for Choice in GestureHotstringActionChoices()
		AssertEqual("", GestureActionParameterSpec(Choice["value"]), Choice["value"] . " takes no value")
}
Test("hotstring actions: the Windows runner and the editor's action list (hotstring-actions)", _TAE_Runner)
