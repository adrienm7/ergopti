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
;
; ROOT CAUSE ENCODED:
; A Windows hotstring could only type text: no entry could run an action or a
; workflow, and nothing kept the typed text when the user wanted it kept.
; ==============================================================================

#Requires AutoHotkey v2.0

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
