; tests/unit/test_onboarding_answers.ahk

; ==============================================================================
; MODULE: Onboarding Answers Commit Path Tests
; DESCRIPTION:
; The wizard page answers with manifest paths and values from the generated
; catalogue. These tests follow those answers on Windows from the finish payload
; to the candidate config.toml the commit transaction publishes: the whole
; payload is refused on any answer outside the catalogue, neutral answers become
; deletions, the file the wizard creates is stamped with the schema version, and
; a re-run reads the values in force back through the same paths. The Tap-Holds
; page's checked keys never become config.toml rows: the tap-hold writer renders
; their preset into the tap_hold.toml the same transaction publishes.
; ==============================================================================

#Requires AutoHotkey v2.0





; =======================================
; =======================================
; ======= 1/ Fixtures and helpers =======
; =======================================
; =======================================

; A fresh temporary config.toml path.
_TOAN_NewPath() {
	static Sequence := 0
	Sequence += 1
	return A_Temp . "\ergopti-onboarding-answers-" . A_ScriptHwnd . "-"
		. A_TickCount . "-" . Sequence . ".toml"
}

; One page operation, as the page posts it.
_TOAN_Op(Path, Value) => Map("path", Path, "value", Value)

; A finish payload in the shape the page sends.
_TOAN_Answers(Operations, Locale := "fr", ConfigDir := "") {
	return Map("locale", Locale, "config_dir", ConfigDir, "operations", Operations)
}

; The row a batch writes for a path, or 0.
_TOAN_RowFor(Rows, Section, Key) {
	for Row in Rows {
		if (Row.Section == Section && Row.Key == Key)
			return Row
	}
	return 0
}

; A checklist item of the hotstrings page: a section switch under a file gate.
_TOAN_HotstringItem(Index) {
	for Page in Index["pages"] {
		if (Page["id"] != "hotstrings")
			continue
		for Language in Page["groups"] {
			for FileGroup in Language.Get("groups", []) {
				for Item in FileGroup.Get("items", [])
					return Map("gate", FileGroup["path"], "item", Item["path"])
			}
		}
	}
	throw Error("the Windows hotstrings page lists no section")
}





; ==================================
; ==================================
; ======= 2/ Catalogue index =======
; ==================================
; ==================================

_TOAN_CatalogueIndexesEveryPage() {
	Index := OnboardingCatalogue()
	Masters := 0
	for Page in Index["pages"] {
		if Page.Has("master") {
			Masters += 1
			AssertEqual("switch", Index["entries"][Page["master"]["path"]]["kind"])
		}
	}
	AssertEqual(7, Masters, "every Windows page asks through a category switch")
	AssertTrue(Index["entries"].Count > 20, "the catalogue lists the Windows checklist paths")
	AssertEqual("character", Index["entries"]["hotstrings.trigger_char"]["kind"])
	AssertEqual(1, Index["entries"]["hotstrings.trigger_char"]["max_characters"],
		"the trigger length limit comes from the manifest, as config.schema.json bounds it")
}
Test("onboarding answers: the catalogue indexes every Windows page (onboarding-answers-windows)",
	_TOAN_CatalogueIndexesEveryPage)

_TOAN_DuplicateCatalogueRowsAreRefused() {
	Text := '{"schema_version":1,"platforms":{"windows":{"pages":[{"id":"a","master":{"path":"gestures.enabled","default":false},"groups":[{"items":[{"path":"gestures.enabled","value":true,"default":false}]}]}]}}}'
	AssertThrows(() => OnboardingCatalogueIndex(Text), "one path answered by two rows must be refused")
	AssertThrows(() => OnboardingCatalogueIndex('{"schema_version":2,"platforms":{}}'),
		"an unknown catalogue format must be refused")
}
Test("onboarding answers: a malformed catalogue fails fast (onboarding-answers-windows)",
	_TOAN_DuplicateCatalogueRowsAreRefused)





; ==============================
; ==============================
; ======= 3/ Answer rows =======
; ==============================
; ==============================

_TOAN_AnswersBecomeSparseRows() {
	Index := OnboardingCatalogue()
	Hotstring := _TOAN_HotstringItem(Index)
	Rows := OnboardingAnswerRows(Index, [
		_TOAN_Op("gestures.enabled", true),
		_TOAN_Op("metrics.metrics_enabled", false),
		_TOAN_Op("hotstrings.trigger_char", ";"),
		_TOAN_Op(Hotstring["gate"], true),
		_TOAN_Op(Hotstring["item"], true)
	])
	AssertTrue(Rows is Array, "a valid payload must produce rows: " . (Rows is String ? Rows : ""))
	AssertEqual(5, Rows.Length)
	AssertEqual(1, _TOAN_RowFor(Rows, "gestures", "enabled").Value)
	Metrics := _TOAN_RowFor(Rows, "metrics", "metrics_enabled")
	AssertTrue(Metrics.HasOwnProp("Delete") && Metrics.Delete == 1,
		"a declined feature is deleted, so the file stays as empty as a fresh one")
	AssertEqual(";", _TOAN_RowFor(Rows, "hotstrings", "trigger_char").Value)
	Dot := InStr(Hotstring["item"], ".", true, -1)
	Item := _TOAN_RowFor(Rows, SubStr(Hotstring["item"], 1, Dot - 1), SubStr(Hotstring["item"], Dot + 1))
	AssertTrue(Item is Object && Item.Value == 1, "a checked hotstring section is written by its manifest path")
}
Test("onboarding answers: answers become manifest rows, neutral ones deletions (onboarding-answers-windows)",
	_TOAN_AnswersBecomeSparseRows)

_TOAN_AnyInvalidAnswerRefusesTheBatch() {
	Index := OnboardingCatalogue()
	Cases := [
		[[_TOAN_Op("gestures.enabled", "true")], "true or false"],
		[[_TOAN_Op("script.onboarding_done", true)], "names no wizard path"],
		[[_TOAN_Op("gestures.enabled", true), _TOAN_Op("gestures.enabled", false)], "answered twice"],
		[[_TOAN_Op("hotstrings.trigger_char", "ab")], "at most 1"],
		[[_TOAN_Op("hotstrings.trigger_char", " ")], "visible text"],
		[[_TOAN_Op("hotstrings.trigger_char", "a`nb")], "visible text"],
		[[Map("path", "gestures.enabled")], "a path and a value"],
		[["gestures.enabled"], "a path and a value"]
	]
	for Probe in Cases {
		Why := OnboardingAnswerRows(Index, Probe[1])
		AssertTrue(Why is String, "an invalid payload must be refused as a whole: " . Probe[2])
		AssertContains(Why, Probe[2])
	}
	AssertTrue(OnboardingAnswerRows(Index, Map()) is String, "operations must be a list")
}
Test("onboarding answers: any invalid answer refuses the whole batch (onboarding-answers-windows)",
	_TOAN_AnyInvalidAnswerRefusesTheBatch)

_TOAN_TriggerLengthCountsCharacters() {
	Index := OnboardingCatalogue()
	Emoji := Chr(0x1F600)
	AssertTrue(OnboardingAnswerRows(Index, [_TOAN_Op("hotstrings.trigger_char", Emoji)]) is Array,
		"a character outside the BMP is one character, not two UTF-16 units")
	AssertTrue(OnboardingAnswerRows(Index,
		[_TOAN_Op("hotstrings.trigger_char", Emoji . Emoji)]) is String)
}
Test("onboarding answers: the trigger length counts characters (onboarding-answers-windows)",
	_TOAN_TriggerLengthCountsCharacters)

; The Tap-Holds page asked, then imported no key: its answers must reach the
; tap-hold writer, and only the checked ones.
_TOAN_TapHoldKeysGoToTheWriterNeverToConfig() {
	global _SharedDir
	Index := OnboardingCatalogue()
	Listed := 0
	for Path, Entry in Index["entries"] {
		if (Entry["kind"] != "tap_hold_key")
			continue
		Listed += 1
		AssertEqual("tap_holds.keys." . Entry["key"], Path)
		AssertEqual(1, Entry["value"], "a key imports its recommendation")
		AssertEqual(0, Entry["default"], "an unchecked key is its neutral value")
	}
	AssertEqual(LoadTapHoldToml(_SharedDir . "\tap_hold\defaults.toml")["keys"].Count, Listed,
		"the page lists every key the shipped preset recommends")
	Operations := [
		_TOAN_Op("tap_holds.keys.caps_lock", true),
		_TOAN_Op("gestures.enabled", true),
		_TOAN_Op("tap_holds.keys.tab", false),
		_TOAN_Op("tap_holds.keys.left_alt", true)
	]
	Rows := OnboardingAnswerRows(Index, Operations)
	AssertTrue(Rows is Array, "a valid payload must produce rows: " . (Rows is String ? Rows : ""))
	AssertEqual(1, Rows.Length, "no tap-hold key reaches config.toml")
	AssertEqual(1, _TOAN_RowFor(Rows, "gestures", "enabled").Value)
	Keys := OnboardingTapHoldKeys(Index, Operations)
	AssertTrue(Keys is Array)
	AssertEqual(2, Keys.Length, "the checked keys are imported, the unchecked one is not written")
	AssertEqual("caps_lock", Keys[1])
	AssertEqual("left_alt", Keys[2])
	Refused := OnboardingTapHoldKeys(Index, [_TOAN_Op("tap_holds.keys.caps_lock", "yes")])
	AssertTrue(Refused is String, "a key takes its recommendation or its neutral value")
	AssertContains(Refused, "recommendation")
	AssertTrue(OnboardingTapHoldKeys(Index, [_TOAN_Op("tap_holds.keys.caps_lock", true),
		_TOAN_Op("script.onboarding_done", true)]) is String, "a refused payload imports no key either")
	AssertEqual(0, OnboardingTapHoldKeys(Index, [_TOAN_Op("gestures.enabled", false)]).Length)
}
Test("onboarding answers: tap-hold keys go to the tap-hold writer, never to config.toml (onboarding-answers-windows)",
	_TOAN_TapHoldKeysGoToTheWriterNeverToConfig)





; ====================================
; ====================================
; ======= 4/ Finish and commit =======
; ====================================
; ====================================

_TOAN_FinishPlanValidatesBeforeAnyChange() {
	Plan := _OnbWeb_FinishPlan(_TOAN_Answers([_TOAN_Op("gestures.enabled", true)], "fr", "D:\Ergopti"))
	AssertTrue(Plan is Map, "a valid payload yields a commit plan")
	AssertEqual("fr", Plan["locale"])
	AssertEqual("D:\Ergopti", Plan["config_dir"])
	AssertEqual(1, Plan["rows"].Length)
	AssertEqual(0, Plan["tap_hold_keys"].Length, "no Tap-Holds answer, no import")
	TapHolds := _OnbWeb_FinishPlan(_TOAN_Answers([_TOAN_Op("category_enabled.tap_holds", true),
		_TOAN_Op("tap_holds.keys.right_ctrl", true)]))
	AssertTrue(TapHolds is Map)
	AssertEqual(1, TapHolds["rows"].Length, "the category switch is the only config.toml row")
	AssertEqual(1, TapHolds["tap_hold_keys"].Length)
	AssertEqual("right_ctrl", TapHolds["tap_hold_keys"][1])
	Invalid := [
		_TOAN_Answers([_TOAN_Op("gestures.enabled", true)], "xx"),
		_TOAN_Answers([_TOAN_Op("gestures.enabled", true)], "fr", 7),
		Map("locale", "fr", "config_dir", "", "use_ergopti", true),
		"malformed"
	]
	for Answers in Invalid {
		AssertTrue(_OnbWeb_FinishPlan(Answers) is String,
			"an invalid payload must be refused before persistence")
	}
}
Test("onboarding answers: the finish payload is validated before any change (onboarding-answers-windows)",
	_TOAN_FinishPlanValidatesBeforeAnyChange)

_TOAN_CommitRendersOneStampedCandidate() {
	Path := _TOAN_NewPath()
	Plan := _OnbWeb_FinishPlan(_TOAN_Answers([
		_TOAN_Op("category_enabled.hotstrings", true),
		_TOAN_Op("gestures.enabled", true),
		_TOAN_Op("metrics.metrics_enabled", false),
		_TOAN_Op("hotstrings.trigger_char", ";")
	]))
	AssertTrue(Plan is Map)
	; The same three steps _Onboarding_Commit runs before its transaction.
	Updates := ConfigMigrateStampNewFile(_Onboarding_CommitUpdates(Plan["locale"], Plan["rows"]), Path)
	Updates := _ConfigPrepareTypedUpdates(Updates)
	Candidate := TOML_BuildUpdatedContent(Path, Updates)
	AssertEqual("ok", Candidate["status"])
	Content := Candidate["content"]
	AssertContains(Content, 'locale = "fr"')
	AssertContains(Content, "schema_version = " . ConfigMigrateCurrentVersion(),
		"the config.toml the wizard creates carries this build's schema version")
	AssertTrue(RegExMatch(Content, "\[gestures\]\R(?:[^\[]*\R)?enabled = true") > 0,
		"a Boolean answer is written as a TOML Boolean: " . Content)
	AssertContains(Content, 'trigger_char = ";"')
	AssertFalse(InStr(Content, "metrics_enabled"), "a neutral answer writes nothing")
	AssertFalse(FileExist(Path), "rendering the candidate publishes nothing")
}
Test("onboarding answers: the commit renders one stamped candidate (onboarding-answers-windows)",
	_TOAN_CommitRendersOneStampedCandidate)

; The commit publishes this image beside config.toml in its own transition.
_TOAN_TapHoldImportRendersOnlyTheCheckedKeys() {
	global _SharedDir
	Defaults := _SharedDir . "\tap_hold\defaults.toml"
	Path := _TOAN_NewPath()
	Rendered := _TOAN_NewPath()
	Source := '[tap_hold]`ninherit_defaults = false`n[tap_hold.keys.caps_lock]`ntap_action = "copy"`n'
		. 'hold_layer = "nav"`n[tap_hold.keys.left_shift]`ntap_action = "paste"`n[private]`nnote = "keep"`n'
	try {
		AssertTrue(FSWriteDurable(Path, Source))
		Image := TapHoldImportImage(Path, Defaults, ["caps_lock"])
		AssertEqual(1, Image["source_present"])
		AssertEqual(Source, Image["source_content"], "the transition checks the exact bytes it replaces")
		AssertEqual(Source, FSReadUtf8Exact(Path), "rendering publishes nothing")
		AssertTrue(FSWriteDurable(Rendered, Image["content"]))
		Loaded := LoadTapHoldToml(Rendered)
		Preset := LoadTapHoldToml(Defaults)
		for Field, Value in Preset["keys"]["caps_lock"]
			AssertEqual(Value, Loaded["keys"]["caps_lock"][Field], "caps_lock." . Field . " is the preset's")
		AssertFalse(Loaded["keys"]["caps_lock"].Has("hold_layer"), "the old hold does not survive the preset's")
		AssertEqual("paste", Loaded["keys"]["left_shift"]["tap_action"], "an unchecked key keeps what it had")
		AssertFalse(Loaded["keys"].Has("left_alt"), "a key nobody checked is not written")
		AssertEqual("keep", TOML_ParseFreshFile(Rendered)["private"]["note"])
		AssertContains(Image["content"], "inherit_defaults = false")
		Absent := TapHoldImportImage(_TOAN_NewPath(), Defaults, ["tab"])
		AssertEqual(0, Absent["source_present"], "a folder without tap_hold.toml gets one")
		AssertContains(Absent["content"], "[tap_hold.keys.tab]")
		AssertThrows(() => TapHoldImportImage(Path, Defaults, ["escape"]),
			"a key the preset does not recommend is refused")
		AssertThrows(() => TapHoldImportImage(Path, Defaults, ["tab", "tab"]), "a key is imported once")
		AssertThrows(() => TapHoldImportImage(Path, Defaults, []), "an import names at least one key")
	} finally {
		try FileDelete(Path)
		try FileDelete(Rendered)
	}
}
Test("onboarding answers: the tap-hold import renders only the checked keys' preset (onboarding-answers-windows)",
	_TOAN_TapHoldImportRendersOnlyTheCheckedKeys)





; ==================================
; ==================================
; ======= 5/ Values in force =======
; ==================================
; ==================================

_TOAN_RerunReadsTheValuesInForce() {
	Index := OnboardingCatalogue()
	Path := _TOAN_NewPath()
	try {
		AssertTrue(FSWrite(Path, '[gestures]`nenabled = false`n[hotstrings]`ntrigger_char = ";"`n'
			. '[unrelated]`nenabled = true`n'))
		Values := OnboardingReadCurrentValues(Index, Path)
		AssertTrue(Values is Map)
		AssertEqual(2, Values.Count, "only wizard paths are read")
		Json := OnboardingValuesJson(Values)
		AssertContains(Json, '"gestures.enabled":false',
			"an explicit false is a configured value the page shows")
		AssertContains(Json, '"hotstrings.trigger_char":";"')
	} finally {
		try FileDelete(Path)
	}
	Absent := OnboardingReadCurrentValues(Index, _TOAN_NewPath())
	AssertTrue(Absent is Map && Absent.Count == 0, "an absent file starts every page neutral")
	AssertEqual("{}", OnboardingValuesJson(Absent))
}
Test("onboarding answers: a re-run reads the values in force (onboarding-answers-windows)",
	_TOAN_RerunReadsTheValuesInForce)

_TOAN_UnreadableConfigurationIsNeverShownNeutral() {
	Index := OnboardingCatalogue()
	Path := _TOAN_NewPath()
	try {
		AssertTrue(FSWrite(Path, "[gestures]`nenabled = [`n  true,`n"))
		AssertTrue(OnboardingReadCurrentValues(Index, Path) is String,
			"neutral pages over a damaged file would overwrite answers the user gave")
	} finally {
		try FileDelete(Path)
	}
}
Test("onboarding answers: a damaged configuration is refused, not shown neutral (onboarding-answers-windows)",
	_TOAN_UnreadableConfigurationIsNeverShownNeutral)
