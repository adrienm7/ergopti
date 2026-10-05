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
; their preset into the tap_hold.toml the same transaction publishes. A re-run
; reads that file too, shows a key of the user's as kept, and never imports
; over it; the file an import replaces is backed up first.
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

; A fresh temporary configuration folder: the tap_hold.toml beside a
; config.toml there is the test's own, never one another test left in A_Temp.
_TOAN_NewFolder() {
	Folder := SubStr(_TOAN_NewPath(), 1, -5)
	DirCreate(Folder)
	return Folder
}

; Removes a folder _TOAN_NewFolder created, with every file in it.
_TOAN_DeleteFolder(Folder) {
	try FileDelete(Folder . "\*.*")
	try DirDelete(Folder)
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

; The key combinations follow only their own switch, which the Shortcuts master
; no longer reaches: the Shortcuts answer writes it, or a re-run answered No
; would leave the AltGr / LAlt / CapsLock families on.
_TOAN_ShortcutsAnswerWritesTheKeyCombinationsSwitch() {
	Index := OnboardingCatalogue()
	AssertTrue(Index["entries"].Has("category_enabled.key_combinations"),
		"the Shortcuts page writes the key-combinations switch")
	AssertEqual("switch", Index["entries"]["category_enabled.key_combinations"]["kind"])
	Off := OnboardingAnswerRows(Index, [_TOAN_Op("category_enabled.shortcuts", false),
		_TOAN_Op("category_enabled.key_combinations", false)])
	AssertTrue(Off is Array, "a No is a valid answer: " . (Off is String ? Off : ""))
	Row := _TOAN_RowFor(Off, "category_enabled", "key_combinations")
	AssertTrue(Row is Object && Row.HasOwnProp("Value") && Row.Value == 0,
		"a No writes the switch off, as the Shortcuts master once turned the families off")
	On := OnboardingAnswerRows(Index, [_TOAN_Op("category_enabled.key_combinations", true)])
	AssertTrue(On is Array)
	Row := _TOAN_RowFor(On, "category_enabled", "key_combinations")
	AssertTrue(Row is Object && Row.HasOwnProp("Delete") && Row.Delete == 1,
		"on is the neutral value: the key is removed, and absent is on")
	AssertTrue(OnboardingAnswerRows(Index, [_TOAN_Op("category_enabled.key_combinations", "off")]) is String,
		"the switch takes true or false")
}
Test("onboarding answers: the Shortcuts answer writes the key-combinations switch (onboarding-answers-windows)",
	_TOAN_ShortcutsAnswerWritesTheKeyCombinationsSwitch)

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
	Source := '[tap_hold]`ninherit_defaults = false`n'
		. '[tap_hold.keys.left_shift]`ntap_action = "paste"`n[private]`nnote = "keep"`n'
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

; A re-run answered Yes imported over the keys the user had set.
_TOAN_TapHoldImportKeepsTheUsersKeysAndBacksUp() {
	global _SharedDir
	Defaults := _SharedDir . "\tap_hold\defaults.toml"
	Folder := _TOAN_NewFolder()
	Path := Folder . "\tap_hold.toml"
	Source := '[tap_hold.keys.left_alt]`ntap_action = "escape"`n'
	try {
		AssertTrue(FSWriteDurable(Path, Source))
		AssertThrows(() => TapHoldImportImage(Path, Defaults, ["caps_lock", "left_alt"]),
			"a key holding the user's own setting refuses the whole import")
		Image := TapHoldImportImage(Path, Defaults, ["caps_lock"])
		Backup := TapHoldImportBackup(Path, Image)
		AssertTrue(Backup != "" && FileExist(Backup), "the file an import replaces is backed up first")
		SplitPath(Backup, , &BackupFolder)
		AssertEqual(Folder, BackupFolder, "the backup sits beside the file it protects")
		AssertTrue(FSUtf8ExactMatches(Backup, Source), "the backup holds the exact bytes the import replaces")
		AssertEqual(Source, FSReadUtf8Exact(Path), "backing up publishes nothing")
		Created := Folder . "\created.toml"
		AssertEqual("", TapHoldImportBackup(Created, TapHoldImportImage(Created, Defaults, ["tab"])),
			"a file the import creates has nothing to back up")
	} finally {
		_TOAN_DeleteFolder(Folder)
	}
}
Test("onboarding answers: the tap-hold import keeps the user's keys and backs up (onboarding-answers-windows)",
	_TOAN_TapHoldImportKeepsTheUsersKeysAndBacksUp)

; A tap_hold.toml that could not take the import threw out of the commit, which
; then saved none of the other answers: the target now says why instead.
_TOAN_TapHoldTargetNeverCostsTheOtherAnswers() {
	Folder := _TOAN_NewFolder()
	Path := Folder . "\tap_hold.toml"
	Source := '[tap_hold.keys.left_alt]`ntap_action = "escape"`n'
	try {
		AssertTrue(FSWriteDurable(Path, Source))
		Refused := _Onboarding_TapHoldTarget(Path, ["caps_lock", "left_alt"])
		AssertTrue(Refused is String, "a file that cannot take the import is reported, never thrown")
		AssertContains(Refused, "left_alt")
		AssertEqual(Source, FSReadUtf8Exact(Path), "the user's file is left as it was")
		Target := _Onboarding_TapHoldTarget(Path, ["caps_lock"])
		AssertTrue(Target is Map, "a free key becomes the transition's tap-hold target")
		AssertEqual(Path, Target["path"])
		AssertContains(Target["new_content"], "[tap_hold.keys.caps_lock]")
		AssertTrue(Target["expected_old"] is Map, "the transition replaces only the bytes the import read")
		AssertEqual(Source, FSReadUtf8Exact(Path), "preparing the target publishes nothing")
	} finally {
		_TOAN_DeleteFolder(Folder)
	}
}
Test("onboarding answers: a tap-hold file that cannot take the import never costs the other answers (onboarding-answers-windows)",
	_TOAN_TapHoldTargetNeverCostsTheOtherAnswers)

; A fresh install has no layers.toml, which binds no key: the imported left_alt
; entered an empty navigation layer. The key now brings Ergopti's recommended
; layer into the commit, never over a layers.toml the user has.
_TOAN_NavLayerComesWithItsKey() {
	global _SharedDir
	Folder := _TOAN_NewFolder()
	LayersPath := Folder . "\layers.toml"
	try {
		Preset := TapHoldRecommendedLayer(_SharedDir)
		AssertEqual(FSReadUtf8Exact(_SharedDir . "\keymap\layers.recommended.toml"), Preset["text"])
		AssertEqual("nav", Preset["layer_id"], "the layer the recommended left_alt holds")
		AssertEqual(LayersPath, _Onboarding_NavLayerPath(Folder, ["caps_lock", "left_alt"]),
			"the key holding the layer brings the folder's layers.toml into the commit")
		AssertEqual("", _Onboarding_NavLayerPath(Folder, ["caps_lock", "tab"]),
			"keys that do not hold the layer import no layer file")
		Target := _Onboarding_NavLayerTarget(LayersPath)
		AssertTrue(Target is Map, "a folder without layers.toml gets the recommended layer")
		AssertEqual(LayersPath, Target["path"])
		AssertEqual(Preset["text"], Target["new_content"], "the preset's exact bytes")
		AssertEqual(0, Target["expected_old"]["present"], "the transition creates the file only while it is absent")
		AssertFalse(FileExist(LayersPath), "preparing the target publishes nothing")
		Loaded := KeymapLayers_Load("windows", KeymapLayers_LoadContext(_SharedDir), Target["new_content"])
		AssertTrue(Loaded["ok"] && Loaded["layers"].Has("nav") && Loaded["layers"]["nav"].Count > 0,
			"the imported layer binds keys on Windows")
		Own := '[_meta]`nschema_version = 1`n`n[layers.nav.all]`n"KeyJ" = "keystroke:ArrowDown"`n'
		AssertTrue(FSWriteDurable(LayersPath, Own))
		AssertEqual(0, _Onboarding_NavLayerTarget(LayersPath), "an existing layers.toml is never replaced")
		AssertEqual(Own, FSReadUtf8Exact(LayersPath))
	} finally {
		_TOAN_DeleteFolder(Folder)
	}
}
Test("onboarding answers: the key holding the navigation layer brings the recommended layer (nav-layer-fresh-install-default)",
	_TOAN_NavLayerComesWithItsKey)





; ==================================
; ==================================
; ======= 5/ Values in force =======
; ==================================
; ==================================

_TOAN_RerunReadsTheValuesInForce() {
	Index := OnboardingCatalogue()
	Folder := _TOAN_NewFolder()
	Path := Folder . "\config.toml"
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
		FileDelete(Path)
		Absent := OnboardingReadCurrentValues(Index, Path)
		AssertTrue(Absent is Map && Absent.Count == 0, "an absent file starts every page neutral")
		AssertEqual("{}", OnboardingValuesJson(Absent))
	} finally {
		_TOAN_DeleteFolder(Folder)
	}
}
Test("onboarding answers: a re-run reads the values in force (onboarding-answers-windows)",
	_TOAN_RerunReadsTheValuesInForce)

; A re-run pre-checked every key and imported over the user's own settings:
; the page now shows each key the tap_hold.toml beside config.toml configures.
_TOAN_TapHoldReportTellsImportedFromCustomised() {
	global _SharedDir
	Defaults := _SharedDir . "\tap_hold\defaults.toml"
	Index := OnboardingCatalogue()
	Folder := _TOAN_NewFolder()
	Path := Folder . "\tap_hold.toml"
	try {
		Empty := TapHoldKeyReport(Path, Defaults)
		AssertTrue(Empty is Map && Empty.Count == 0, "a folder without tap_hold.toml configures no key")
		AssertTrue(FSWriteDurable(Path, '[tap_hold]`ninherit_defaults = false`n'
			. '[tap_hold.keys.caps_lock]`ntime_activation_seconds = 0.35`ntap_action = "enter"`n'
			. 'hold_modifier = "ctrl"`n[tap_hold.keys.left_alt]`ntap_action = "escape"`n'))
		Report := TapHoldKeyReport(Path, Defaults)
		AssertTrue(Report is Map, "a readable file is reported")
		AssertEqual(2, Report.Count, "a key the file leaves out stays free")
		AssertEqual("recommended", Report.Get("caps_lock", ""), "a key set to its recommendation reads as imported")
		AssertEqual("customised", Report.Get("left_alt", ""), "any other setting is the user's own")
		Values := OnboardingReadCurrentValues(Index, Folder . "\config.toml")
		AssertTrue(Values is Map, "a folder without config.toml still reads its tap-hold keys")
		AssertEqual(2, Values.Count)
		Json := OnboardingValuesJson(Values)
		AssertContains(Json, '"tap_holds.keys.caps_lock":true', "an imported key shows checked")
		AssertContains(Json, '"tap_holds.keys.left_alt":"customised"', "a customised key shows as kept")
		FileDelete(Path)
		AssertTrue(FSWriteDurable(Path, '[tap_hold]`ninherit_defaults = true`n'
			. '[tap_hold.keys.tab]`ntap_action = "enter"`n'))
		Inherited := TapHoldKeyReport(Path, Defaults)
		AssertEqual(LoadTapHoldToml(Defaults)["keys"].Count, Inherited.Count,
			"a file that inherits the preset configures every key it recommends")
		AssertEqual("recommended", Inherited["caps_lock"])
		AssertEqual("customised", Inherited["tab"])
		FileDelete(Path)
		AssertTrue(FSWriteDurable(Path, '[tap_hold.keys.left_alt]`ntap_action = [`n  "escape",`n'))
		AssertTrue(OnboardingReadCurrentValues(Index, Folder . "\config.toml") is String,
			"an unreadable tap-hold file never opens a neutral page")
	} finally {
		_TOAN_DeleteFolder(Folder)
	}
}
Test("onboarding answers: a re-run reads the tap-hold keys beside config.toml (onboarding-answers-windows)",
	_TOAN_TapHoldReportTellsImportedFromCustomised)

_TOAN_UnreadableConfigurationIsNeverShownNeutral() {
	Index := OnboardingCatalogue()
	Folder := _TOAN_NewFolder()
	Path := Folder . "\config.toml"
	try {
		AssertTrue(FSWrite(Path, "[gestures]`nenabled = [`n  true,`n"))
		AssertTrue(OnboardingReadCurrentValues(Index, Path) is String,
			"neutral pages over a damaged file would overwrite answers the user gave")
	} finally {
		_TOAN_DeleteFolder(Folder)
	}
}
Test("onboarding answers: a damaged configuration is refused, not shown neutral (onboarding-answers-windows)",
	_TOAN_UnreadableConfigurationIsNeverShownNeutral)


; The actual wizard transaction publishes before its unit-owned reload hand-off.
; The hand-off is a runner stub; this does not claim an installed-driver reload.
_TOAN_FullSemanticCommit() {
	global _ConfigDir, _DefaultConfigDir, _DefaultLogsDir, _AhkSubDir
	global _PathsFile, ConfigurationFile, _Stub_SentText
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries
	global _ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	Previous := Map("dir_set", IsSet(_ConfigDir), "dir", IsSet(_ConfigDir) ? _ConfigDir : "",
		"default_set", IsSet(_DefaultConfigDir), "default", IsSet(_DefaultConfigDir) ? _DefaultConfigDir : "",
		"logs_set", IsSet(_DefaultLogsDir), "logs", IsSet(_DefaultLogsDir) ? _DefaultLogsDir : "",
		"subdir_set", IsSet(_AhkSubDir), "subdir", IsSet(_AhkSubDir) ? _AhkSubDir : "",
		"paths_set", IsSet(_PathsFile), "paths", IsSet(_PathsFile) ? _PathsFile : "",
		"sent", _Stub_SentText, "rejected", _ConfigBootRejectedOverrides,
		"outdated", _ConfigBootOutdatedEntries)
	Folder := SubStr(_TOAN_NewPath(), 1, -5), Path := Folder . "\config.toml"
	AssertTrue(DllCall("CreateDirectoryW", "Str", Folder, "Ptr", 0, "Int"),
		"the wizard transaction fixture must exclusively own its directory")
	Source := 'script = {locale = "en", future = "retain"}`n[future]`nold = "retain" # user data`n'
	Expected := Chr(0xFEFF) . 'script = {locale = "fr", future = "retain"}`n[future]`nold = "retain" # user data`n'
	Seen := Map("calls", 0)
	Observe() {
		Seen["calls"] += 1
		Seen["content"] := FSReadUtf8Exact(ConfigurationFile)
		Seen["path"] := ConfigurationFile
		Seen["terminal"] := _ConfigWriteTerminalIsActive()
		Seen["lease"] := ConfigWriteLeaseBusy()
		Seen["wal"] := FSStrictExists(ConfigTransitionWalPath(_PathsFile))
		Seen["journal"] := ConfigTransitionInspect(_PathsFile, ConfigTransitionProductionPort())
	}
	try {
		_ConfigDir := Folder . "\"
		_DefaultConfigDir := _ConfigDir
		_DefaultLogsDir := Folder . "\logs"
		_AhkSubDir := ""
		_PathsFile := Folder . "\paths.toml"
		_Stub_SentText := []
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		Plan := _OnbWeb_FinishPlan(_TOAN_Answers([], "fr", Folder))
		AssertTrue(Plan is Map)
		Result := _Onboarding_Commit(Plan["locale"], Plan["config_dir"],
			Plan["rows"], Plan["tap_hold_keys"], Observe)
		AssertTrue((Result is Integer) && Result == 1, "the actual wizard can update an inline-owned locale")
		AssertEqual(1, Seen["calls"], "only an accepted hand-off observes the committed image")
		AssertEqual(Expected, Seen["content"])
		AssertEqual(Path, Seen["path"])
		AssertTrue(Seen["terminal"], "the actual transaction retains terminal authority through hand-off")
		AssertTrue(Seen["lease"], "the actual transaction retains source ownership through hand-off")
		AssertEqual(1, Seen["wal"], "the accepted hand-off retains its journal for refused-reload rollback")
		AssertTrue(ConfigTransitionResultIs(Seen["journal"], "ready"))
		AssertEqual("committed_new", Seen["journal"]["record"]["phase"])
		AssertEqual(Expected, FSReadUtf8Exact(Path))
		AssertEqual(1, _Stub_SentText.Length)
		AssertEqual("reload_preserving_suspend", _Stub_SentText[1].kind)
		AssertFalse(_ConfigWriteTerminalIsActive())
		AssertFalse(ConfigWriteLeaseBusy())
		Cache := ParseConfigTomlFile(Path)
		AssertEqual("fr", IniCacheGet(Cache, "script", "locale"))
		AssertEqual("retain", IniCacheGet(Cache, "script", "future"))
	} finally {
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
		_ConfigDir := Previous["dir_set"] ? Previous["dir"] : unset
		_DefaultConfigDir := Previous["default_set"] ? Previous["default"] : unset
		_DefaultLogsDir := Previous["logs_set"] ? Previous["logs"] : unset
		_AhkSubDir := Previous["subdir_set"] ? Previous["subdir"] : unset
		_PathsFile := Previous["paths_set"] ? Previous["paths"] : unset
		_Stub_SentText := Previous["sent"]
		_ConfigBootRejectedOverrides := Previous["rejected"]
		_ConfigBootOutdatedEntries := Previous["outdated"]
		for Store in [_ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots] {
			if Store.Has(Path)
				Store.Delete(Path)
		}
		_TOAN_DeleteFolder(Folder)
	}
}
Test("onboarding answers: actual WAL commit changes inline settings before owned reload hand-off (config-full-semantic-successor)",
	_TOAN_FullSemanticCommit)
