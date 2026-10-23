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
