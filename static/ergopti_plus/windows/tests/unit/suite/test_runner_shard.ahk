; tests/unit/suite/test_runner_shard.ahk

; ==============================================================================
; MODULE: Test runner module groups
; DESCRIPTION:
; CI splits the canonical suite across runners with run_all.ahk --module=<g>.
; The groups must partition the registered tests by their file: every test
; belongs to exactly one group, keeps its relative order, and unknown groups
; are refused (a file no category declares too). --list replays an exact subset in registry order, and
; --reverse runs the selection backwards to expose order-dependent tests.
; ==============================================================================

#Requires AutoHotkey v2.0

_RSH_Partition() {
	global TEST_REGISTRY, TEST_MODULE_GROUPS
	Seen := 0
	Counts := Map()
	; One identity index instead of a registry scan per selected test: the scan
	; made this check quadratic in the suite size (about 16 s on CI).
	Positions := Map()
	for Index, Candidate in TEST_REGISTRY
		Positions[ObjPtr(Candidate)] := Index
	for Group in TEST_MODULE_GROUPS {
		Selected := _SelectModule(TEST_REGISTRY, Group[1])
		Counts[Group[1]] := Selected.Length
		Seen += Selected.Length
		Previous := 0
		for Entry in Selected {
			Position := Positions.Get(ObjPtr(Entry), 0)
			AssertTrue(Position > Previous, "a module group keeps the registry order")
			Previous := Position
		}
	}
	AssertEqual(TEST_REGISTRY.Length, Seen, "the module groups together hold every registered test once")
	for Name, Count in Counts
		AssertTrue(Count > 0, "module group '" . Name . "' selects at least one test")
	AssertTrue(_SelectModule(TEST_REGISTRY, "") == TEST_REGISTRY, "no module keeps the exact selection")
}
Test("runner module: the module groups partition the suite in order (runner-module)", _RSH_Partition)

_RSH_GroupRules() {
	AssertEqual("meta", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\meta\test_x.ahk"))
	AssertEqual("llm-server-panel", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\modules\llm\servers\test_local_server_panel.ahk"))
	AssertEqual("llm-server-panel", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\modules\llm\servers\test_local_server_panel_view_preparation.ahk"))
	AssertEqual("llm-servers", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\modules\llm\servers\test_local_server_join.ahk"))
	AssertEqual("llm-servers", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\modules\llm\servers\test_local_server_scope_cohort.ahk"))
	AssertEqual("llm-servers", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\modules\llm\servers\test_ollama_runtime_owner.ahk"))
	AssertEqual("llm-terminal", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\modules\llm\nav_event_owner\test_terminal_route_metadata.ahk"))
	AssertEqual("llm", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\modules\llm\prediction\test_llm_live_mode.ahk"))
	AssertEqual("config-transition", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\infra\config\transition\test_config_transition_windows_port.ahk"))
	AssertEqual("config-scope-global", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\infra\config\scope\test_global_config_scope.ahk"))
	AssertEqual("config-scope-global", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\test_config_scope_manifest.ahk"))
	AssertEqual("config-scope-features", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\infra\config\scope\test_hotstrings_scope.ahk"))
	AssertEqual("config-scope-features", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\infra\config\scope\test_personal_file_captions.ahk"))
	AssertEqual("config-updater", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\infra\toml\test_toml_writer_admission.ahk"))
	AssertEqual("config-updater", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\test_updater.ahk"))
	AssertEqual("config-updater", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\modules\updater\test_updater_curl_capture.ahk"))
	AssertEqual("hotstrings-shortcuts", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\modules\hotstrings\personal\test_user_hotstrings.ahk"))
	AssertEqual("hotstrings-shortcuts", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\modules\shortcuts\test_capsword_auto_off.ahk"))
	AssertEqual("keymap-gestures", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\platform\remap\tap_hold\test_tap_hold_loader.ahk"))
	AssertEqual("keymap-gestures", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\modules\gestures\test_gestures.ahk"))
	AssertEqual("keystats", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\modules\keystats\test_keystats_event_id.ahk"))
	AssertEqual("ui", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\ui\menu\test_script_control_submenu.ahk"))
	AssertEqual("core", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\adapters\shell_runner\test_shell_runner_tree_owned.ahk"))
	AssertEqual("core", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\platform\network\test_managed_remote_transport.ahk"))
	AssertEqual("core", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\infra\test_text_utils.ahk"))
	; No catch-all: a file no category declares is refused, never filed under core.
	AssertThrows(() => _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\run_all.ahk"))
	AssertThrows(() => _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\new_area\test_x.ahk"))
	AssertThrows(() => _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\test_unfiled.ahk"))
	AssertThrows(() => _SelectModule([], "no-such-group"))
}
Test("runner module: files map to their product module and unknown groups are refused (runner-module)", _RSH_GroupRules)

_RSH_List() {
	Tests := [{name: "a"}, {name: "b"}, {name: "c"}]
	ListFile := A_Temp . "\ergopti-runner-list-" . A_TickCount . ".txt"
	FileAppend("c`r`na`n", ListFile, "UTF-8")
	try {
		Selected := _SelectListed(Tests, ListFile)
		AssertEqual(2, Selected.Length)
		AssertEqual("a", Selected[1].name, "a listed replay keeps the registry order")
		AssertEqual("c", Selected[2].name)
	} finally FileDelete(ListFile)
	AssertTrue(_SelectListed(Tests, "") == Tests)
}
Test("runner module: --list replays the named tests in registry order (runner-module)", _RSH_List)


; Exact replay admission must account for every requested name, including a
; missing name beside a valid control that would otherwise make the run green.
_RSH_NewReplayDirectory() {
	Directory := A_Temp . "\ergopti-runner-replay-" . A_ScriptHwnd . "-" . A_TickCount . "-" . Random(100000, 999999)
	AssertTrue(DllCall("Kernel32\CreateDirectoryW", "Str", Directory, "Ptr", 0, "Int"),
		"the replay fixture requires an exclusively acquired private root")
	return Directory
}

_RSH_ListRefusesUnknown() {
	Tests := [{name: "retained"}, {name: "other"}]
	Directory := _RSH_NewReplayDirectory()
	ListFile := Directory . "\requested.txt"
	try {
		for Missing in ["missing", "Retained"] {
			if FileExist(ListFile)
				FileDelete(ListFile)
			FileAppend("retained`n" . Missing . "`n", ListFile, "UTF-8")
			Refused := false
			try _SelectListed(Tests, ListFile)
			catch ValueError as Err {
				AssertEqual("Unknown test listed for replay: " . Missing, Err.Message)
				Refused := true
			}
			AssertTrue(Refused, "a retained passing case must not conceal an unknown requested name")
		}
		AssertEqual(2, Tests.Length, "admission never mutates the registry")
	} finally DirDelete(Directory, true)
}
Test("runner list: unknown names refuse an otherwise valid replay (runner-list-contract)", _RSH_ListRefusesUnknown)


_RSH_ListSelectionIntersections() {
	Core := "C:\repo\static\ergopti_plus\windows\tests\unit\infra\test_text_utils.ahk"
	Ui := "C:\repo\static\ergopti_plus\windows\tests\unit\ui\menu\test_menu.ahk"
	Rows := [{name: "alpha", file: Core, interactive: false},
		{name: "beta", file: Ui, interactive: false},
		{name: "gamma", file: Core, interactive: true},
		{name: "alpha", file: Core, interactive: false}]
	Directory := _RSH_NewReplayDirectory()
	ListFile := Directory . "\requested.txt"
	try {
		FileAppend("gamma`nbeta`nalpha`n", ListFile, "UTF-8")
		Selected := _SelectRunTests(Rows, "", "core", ListFile, false, false, &Excluded, &UnmodularCount)
		AssertEqual(2, Selected.Length, "duplicate registered names retain every original occurrence")
		AssertTrue(Selected[1] == Rows[1])
		AssertTrue(Selected[2] == Rows[4])
		AssertEqual(3, UnmodularCount)
		AssertEqual(1, Excluded.Length)
		AssertTrue(Excluded[1] == Rows[3])
		Selected := _SelectRunTests(Rows, "beta", "ui", ListFile, false, false, &Excluded, &UnmodularCount)
		AssertEqual(1, Selected.Length, "known listed names outside an explicit filter remain legal")
		AssertTrue(Selected[1] == Rows[2])
		AssertEqual(0, Excluded.Length)
		AssertEqual(1, UnmodularCount)
		Selected := _SelectRunTests(Rows, "", "core", ListFile, true, true, &Excluded, &UnmodularCount)
		AssertEqual(3, Selected.Length)
		AssertTrue(Selected[1] == Rows[4], "reverse applies after the requested intersections")
		AssertTrue(Selected[2] == Rows[3])
		AssertTrue(Selected[3] == Rows[1])
		AssertEqual(0, Excluded.Length)
		AssertEqual(4, Rows.Length)
		AssertEqual("alpha", Rows[1].name, "selection never reorders the source registry")
		FileDelete(ListFile)
		FileAppend("beta`nmissing`n", ListFile, "UTF-8")
		Refused := false
		try _SelectRunTests(Rows, "alpha", "core", ListFile, false, false, &Excluded, &UnmodularCount)
		catch ValueError as Err {
			AssertEqual("Unknown test listed for replay: missing", Err.Message)
			Refused := true
		}
		AssertTrue(Refused, "explicit filters must not conceal a name missing from the full registry")
	} finally DirDelete(Directory, true)
}
Test("runner list: admission precedes explicit selection intersections (runner-list-contract)", _RSH_ListSelectionIntersections)

_RSH_Reverse() {
	Tests := [{name: "a"}, {name: "b"}, {name: "c"}]
	Reversed := _SelectReversed(Tests, true)
	AssertEqual(3, Reversed.Length)
	AssertEqual("c", Reversed[1].name, "--reverse runs the last selected test first")
	AssertEqual("b", Reversed[2].name)
	AssertEqual("a", Reversed[3].name)
	AssertEqual("a", Tests[1].name, "the registry itself keeps its order")
	AssertTrue(_SelectReversed(Tests, false) == Tests)
	AssertEqual(0, _SelectReversed([], true).Length)
}
Test("runner module: --reverse runs the selection backwards (runner-module)", _RSH_Reverse)


_RSH_DefaultPlanOwner() {
	global TEST_MODULE_GROUPS
	File := "C:\repo\static\ergopti_plus\windows\tests\unit\infra\test_text_utils.ahk"
	Rows := [{file: File, name: "first"}, {file: File, name: "second"}]
	Expected := "core`t" . File . "`tfirst`ncore`t" . File . "`tsecond`n"
	AssertEqual(Expected, _TestBuildPlan(Rows), "the default plan preserves canonical unit classification and order")
	AssertEqual(Expected, _TestBuildPlan(Rows, 0), "only the declared Integer zero chooses the same canonical owner")
	AssertEqual(14, TEST_MODULE_GROUPS.Length, "the E2E owner must not create an empty unit shard")
	for Unowned in ["unit\new_area\test_x.ahk", "e2e\run_e2e.ahk"] {
		AssertThrows(_TestModuleOf.Bind("C:\repo\static\ergopti_plus\windows\tests\" . Unowned))
		AssertThrows(_TestBuildPlan.Bind([{file: "C:\repo\static\ergopti_plus\windows\tests\" . Unowned, name: "unknown"}]))
	}
	AssertThrows(_SelectModule.Bind([], "e2e"), "E2E must remain outside the unit module vocabulary")
}
Test("runner plan: default ownership keeps all unit classification strict (runner-plan-owner)", _RSH_DefaultPlanOwner)

_RSH_ExplicitPlanOwner() {
	Files := []
	Rows := [{file: "owned-entry.ahk", name: "first"}, {file: "owned-include.ahk", name: "second"}]
	Plan := _TestBuildPlan(Rows, (File) => (Files.Push(File), "owned-suite"))
	AssertEqual("owned-suite`towned-entry.ahk`tfirst`nowned-suite`towned-include.ahk`tsecond`n", Plan)
	AssertEqual(2, Files.Length, "the owner must classify every actual registering file")
	AssertEqual(Rows[1].file, Files[1])
	AssertEqual(Rows[2].file, Files[2])
}
Test("runner plan: an explicit owner classifies exact ordered registrations (runner-plan-owner)", _RSH_ExplicitPlanOwner)

_RSH_InvalidPlanOwners() {
	for Invalid in ["0", 0.0, 1, "", "classifier", {}, [], Map()]
		AssertThrows(_TestBuildPlan.Bind([], Invalid), "invalid ownership must refuse even an empty registry")
}
Test("runner plan: invalid classifier values never select the default (runner-plan-owner)", _RSH_InvalidPlanOwners)

_RSH_InvalidPlanLabel(Label) {
	Rows := [{file: "owned.ahk", name: "one"}]
	Owner := (File) => Label
	AssertThrows(_TestBuildPlan.Bind(Rows, Owner), "a classifier must not corrupt the plan's three fields")
}
for _RSH_BadPlanLabel in [
	{Name: "empty", Value: ""}, {Name: "whitespace", Value: " "}, {Name: "integer", Value: 0},
	{Name: "tab", Value: "bad`tfield"}, {Name: "newline", Value: "bad`nfield"},
	{Name: "carriage return", Value: "bad`rfield"}, {Name: "object", Value: {}}
]
	Test("runner plan: " . _RSH_BadPlanLabel.Name . " classifier output is refused (runner-plan-owner)",
		_RSH_InvalidPlanLabel.Bind(_RSH_BadPlanLabel.Value))
