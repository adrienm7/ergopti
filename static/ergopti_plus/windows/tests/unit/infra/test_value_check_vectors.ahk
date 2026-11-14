; tests/unit/infra/test_value_check_vectors.ahk

; ==============================================================================
; MODULE: User Value Check Vector Tests
; DESCRIPTION:
; Replays the shared _shared/settings/data/value_schema/value_check_vectors.json
; through the AHK port (infra/value_check.ahk). The JavaScript check and the
; Lua port replay the same file, so Windows accepts and refuses the same
; stored values and typed text as macOS, Linux and the web pages. A vector
; marked ahk_skip needs a boolean type AutoHotkey does not have.
; ==============================================================================

; The headless suite records refusals instead of opening a native message box,
; which would block the run; a test reads the record to prove a refusal was shown.
global _ValueCheckTest_Refusals := []
_ValueCheckTest_RecordRefusal(Key, Result) {
	global _ValueCheckTest_Refusals
	_ValueCheckTest_Refusals.Push(Map("key", Key, "reason", Result["reason"]))
}
ValueCheckSetRefusalPresenter(_ValueCheckTest_RecordRefusal)

_ValueCheckTest_Corpus() {
	Path := A_ScriptDir . "\..\..\_shared\settings\data\value_schema\value_check_vectors.json"
	AssertTrue(FileExist(Path) != "", "value check vectors must exist at: " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

; Values JSON cannot spell, built from float overflow: inf - inf is NaN.
_ValueCheckTest_Decode(Declaration, Value) {
	if (Declaration["type"] != "integer" && Declaration["type"] != "decimal") || !(Value is String)
		return Value
	Infinity := 1.0e308 * 10
	switch Value, true {
		case "inf": return Infinity
		case "-inf": return -Infinity
		case "nan": return Infinity - Infinity
	}
	return Value
}

_ValueCheckTest_Stored() {
	Corpus := _ValueCheckTest_Corpus()
	AssertTrue(Corpus["stored"].Length >= 30, "stored vectors: >=30 expected")
	for Row in Corpus["stored"] {
		if Row.Has("ahk_skip")
			continue
		Declaration := Corpus["declarations"][Row["declaration"]]
		Result := ValueCheckValue(Declaration, _ValueCheckTest_Decode(Declaration, Row["value"]))
		AssertEqual(Row["ok"] ? true : false, Result["ok"] ? true : false, "stored " . Row["id"] . " ok")
		if !Row["ok"]
			AssertEqual(Row["reason"], Result["reason"], "stored " . Row["id"] . " reason")
	}
}
Test("Value check: stored values match the shared vectors", _ValueCheckTest_Stored)

_ValueCheckTest_Entry() {
	Corpus := _ValueCheckTest_Corpus()
	AssertTrue(Corpus["entry"].Length >= 25, "entry vectors: >=25 expected")
	for Row in Corpus["entry"] {
		if Row.Has("ahk_skip")
			continue
		Result := ValueCheckParseEntry(Corpus["declarations"][Row["declaration"]], Row["text"])
		AssertEqual(Row["ok"] ? true : false, Result["ok"] ? true : false, "entry " . Row["id"] . " ok")
		if Row["ok"]
			AssertEqual(Row["value"], Result["value"], "entry " . Row["id"] . " value")
		else
			AssertEqual(Row["reason"], Result["reason"], "entry " . Row["id"] . " reason")
		if Row.Has("min") {
			AssertEqual(Row["min"], Result["min"], "entry " . Row["id"] . " min")
			AssertEqual(Row["max"], Result["max"], "entry " . Row["id"] . " max")
		}
	}
}
Test("Value check: typed text matches the shared vectors", _ValueCheckTest_Entry)

_ValueCheckTest_Messages() {
	Corpus := _ValueCheckTest_Corpus()
	for Row in Corpus["messages"] {
		Declaration := Corpus["declarations"][Row["declaration"]]
		Parts := ValueCheckMessageParts(Declaration, ValueCheckParseEntry(Declaration, Row["text"]))
		AssertEqual(Row["parts"].Length, Parts.Length, "message " . Row["id"] . " part count")
		for Index, Expected in Row["parts"] {
			AssertEqual(Expected["key"], Parts[Index]["key"], "message " . Row["id"] . " key")
			AssertEqual(Expected["args"].Length, Parts[Index]["args"].Length, "message " . Row["id"] . " arg count")
			for Position, Arg in Expected["args"] {
				Actual := Parts[Index]["args"][Position]
				if (Arg is Map)
					AssertEqual(Arg["key"], Actual["key"], "message " . Row["id"] . " key arg")
				else
					AssertEqual(Arg, Actual, "message " . Row["id"] . " arg " . Position)
			}
		}
	}
	Templates := Map(
		"dialog.value_check.range_integer_unit", "From {1} to {2} {3}.",
		"value_check.unit.ms", "ms",
		"dialog.value_check.range_integer", "From {1} to {2}.",
		"dialog.value_check.special", "{1} = {2}.",
		"value_check.special.no_time_limit", "no limit")
	Translate := (Key) => Templates[Key]
	Delay := Corpus["declarations"]["delay_seconds"]
	AssertEqual("From 1 to 10000 ms.",
		ValueCheckRenderMessage(ValueCheckMessageParts(Delay, ValueCheckParseEntry(Delay, "0")), Translate))
	Timeout := Corpus["declarations"]["timeout_ms"]
	AssertEqual("From 1 to 600000. 0 = no limit.",
		ValueCheckRenderMessage(ValueCheckMessageParts(Timeout, ValueCheckParseEntry(Timeout, "-3")), Translate))
	AssertEqual("0.001", ValueCheckFormatNumber(0.001))
	AssertEqual("2", ValueCheckFormatNumber(2.0))
}
Test("Value check: refusal messages match the shared vectors", _ValueCheckTest_Messages)

_ValueCheckTest_Boundary() {
	Corpus := _ValueCheckTest_Corpus()
	Schema := Map("settings", Map("a.b", Corpus["declarations"]["timeout_ms"]))
	AssertEqual(42, ValueCheckRequire("a.b", 42, Schema))
	try {
		ValueCheckRequire("a.b", "42", Schema)
		AssertTrue(false, "a string must be refused at the boundary")
	} catch ValueError as Err {
		AssertTrue(InStr(Err.Message, "a.b refused (wrong_type)") > 0, Err.Message)
	}
	AssertThrows(() => ValueCheckEntryFor("no.such", Schema), "an unknown setting must throw")
	Patterned := Map("settings", Map("hotstrings.*.delay", Corpus["declarations"]["seconds"]))
	AssertEqual("decimal", ValueCheckEntryFor("hotstrings.rolls.delay", Patterned)["type"])
	AssertThrows(() => ValueCheckEntryFor("hotstrings.a.b.delay", Patterned), "a pattern matches one segment")
}
Test("Value check: the boundary throws with the setting name", _ValueCheckTest_Boundary)

_ValueCheckTest_GeneratedSchema() {
	Settings := ValueSchemaData()["settings"]
	AssertTrue(Settings.Count > 0, "the generated schema declares settings")
	for Name, Entry in Settings {
		if (Entry["type"] == "integer" || Entry["type"] == "decimal")
			AssertTrue(Entry.Has("min") && Entry.Has("max"), Name . " declares both bounds")
	}
	Delay := ValueCheckEntryFor("tap_hold.keys.a_key.time_activation_seconds")
	AssertEqual("ms", Delay["entry_unit"])
}
Test("Value check: the generated schema is complete", _ValueCheckTest_GeneratedSchema)

; Regression: a stored negative or oversized base delay used to reach the engine,
; where a value at or under 0 silently meant « no limit ».
_ValueCheckTest_BaseDelayLoadAndSetter() {
	global Features, GLOBAL_DEFAULT_DELAY
	if !Features.Has("hotstrings")
		Features["hotstrings"] := Map()
	Section := Features["hotstrings"]
	Leaf := ConfigLeaf.EXPANSION_DELAY
	Had := Section.Has(Leaf), Saved := Had ? Section[Leaf] : ""
	try {
		for Bad in [-1, 3601, "0.5"] {
			Section[Leaf] := Bad
			AssertEqual(GLOBAL_DEFAULT_DELAY, HotstringsBaseDelay(), "a refused stored delay reads as the default")
		}
		Section[Leaf] := 0.5
		AssertEqual(0.5, HotstringsBaseDelay(), "an admitted stored delay is kept")
		Section[Leaf] := 0
		AssertEqual(0, HotstringsBaseDelay(), "0 (no time limit) is a declared special value")
		for Bad in [-1, 3601, "2"]
			AssertFalse(HotstringsSetBaseDelay(Bad), "the setter refuses what the schema refuses")
	} finally {
		if Had
			Section[Leaf] := Saved
		else
			Section.Delete(Leaf)
	}
}
Test("Value check: the hotstring base delay is checked at load and at its setter", _ValueCheckTest_BaseDelayLoadAndSetter)

; Regression: the base and category delay prompts and the personal-file fields
; refused silently or without the range; the refusal now goes through the
; presenter with the setting's declaration.
_ValueCheckTest_HotstringPromptsShowRefusal() {
	global _ValueCheckTest_Refusals
	Before := _ValueCheckTest_Refusals.Length
	Typed := ValueCheckParseEntry(ValueCheckEntryFor("hotstrings.expansion_delay"), "3600001")
	AssertFalse(Typed["ok"])
	ValueCheckShowRefusal("hotstrings.expansion_delay", Typed, "3600001")
	AssertEqual(Before + 1, _ValueCheckTest_Refusals.Length)
	AssertEqual("above_maximum", _ValueCheckTest_Refusals[-1]["reason"])
	AssertEqual(3600000, Typed["max"], "the range is given in the typed unit (ms)")
}
Test("Value check: a refused hotstring delay is shown with its range", _ValueCheckTest_HotstringPromptsShowRefusal)

; Regression: the ChatGPT link editor wrote any text, and the opener ran any
; non-empty string; the search actions launched whatever config.toml held.
; The link editor now refuses a non-web address with the shared message and
; writes nothing; the openers refuse it before the launch.
global _ValueCheckTest_LinkWrites := 0
_ValueCheckTest_LinkWriter(*) {
	global _ValueCheckTest_LinkWrites
	_ValueCheckTest_LinkWrites += 1
	return false
}
_ValueCheckTest_WebAddresses() {
	global _ValueCheckTest_Refusals, _ValueCheckTest_LinkWrites, Features
	for Refused in ["file:///C:/Windows/System32/calc.exe", "javascript:alert(1)", "https://bad url", "chat.example"] {
		Before := _ValueCheckTest_Refusals.Length
		_ValueCheckTest_LinkWrites := 0
		AssertFalse(ModifyLink(0, Refused, _ValueCheckTest_LinkWriter), Refused)
		AssertEqual(0, _ValueCheckTest_LinkWrites, "nothing is written for " . Refused)
		AssertEqual(Before + 1, _ValueCheckTest_Refusals.Length)
		AssertEqual(ConfigKey.SHORTCUTS_CHATGPT_URL, _ValueCheckTest_Refusals[-1]["key"])
	}
	Saved := Features
	Launches := []
	Launch := (Target, *) => Launches.Push(Target)
	try {
		Features := Map("shortcuts", Map(ConfigLeaf.SEARCH, Map(
			ConfigLeaf.SEARCH_ENGINE, "file:///C:/Windows/System32/calc.exe",
			ConfigLeaf.SEARCH_ENGINE_URL_QUERY, "cmd /c start ")))
		SearchPath("", Launch)
		SearchPath("ergopti", Launch)
		AssertEqual(0, Launches.Length, "a refused search address is never launched")
	} finally Features := Saved
}
Test("Value check: the ChatGPT link and the search addresses must be web addresses", _ValueCheckTest_WebAddresses)

; Regression: the programmable hotstrings handed config.toml's activation delay
; to the engine unchecked; a refused one now declines the expansion with a log.
_ValueCheckTest_UserCodeDelay() {
	global Features
	Saved := Features
	try {
		for Case in [[0.5, 0.5], [0, 0], [3600, 3600], ["0.5", ""], [-1, ""], [3601, ""]] {
			Features := Map("hotstrings", Map("dynamic", Map(ConfigLeaf.USER_CODE,
				Map(ConfigLeaf.TIME_ACTIVATION_SECONDS, Case[1]))))
			AssertEqual(Case[2], _UserHotstringsDelay(), "user-code delay " . String(Case[1]))
		}
	} finally Features := Saved
}
Test("Value check: the programmable hotstring delay is checked where it reaches the engine", _ValueCheckTest_UserCodeDelay)
