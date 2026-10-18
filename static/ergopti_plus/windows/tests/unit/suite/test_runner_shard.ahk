; tests/unit/suite/test_runner_shard.ahk

; ==============================================================================
; MODULE: Test runner module groups
; DESCRIPTION:
; CI splits the canonical suite across runners with run_all.ahk --module=<g>.
; The groups must partition the registered tests by their file: every test
; belongs to exactly one group, keeps its relative order, and unknown groups
; are refused. --list replays an exact subset in registry order, and
; --reverse runs the selection backwards to expose order-dependent tests.
; ==============================================================================

#Requires AutoHotkey v2.0

_RSH_Partition() {
	global TEST_REGISTRY, TEST_MODULE_GROUPS
	Seen := 0
	Counts := Map()
	for Group in TEST_MODULE_GROUPS {
		Selected := _SelectModule(TEST_REGISTRY, Group[1])
		Counts[Group[1]] := Selected.Length
		Seen += Selected.Length
		Previous := 0
		for Entry in Selected {
			Position := 0
			for Index, Candidate in TEST_REGISTRY {
				if Candidate == Entry {
					Position := Index
					break
				}
			}
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
	AssertEqual("llm-servers-a", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\test_local_server_panel.ahk"))
	AssertEqual("llm-servers-b", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\test_local_server_join.ahk"))
	AssertEqual("llm-terminal", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\llm_nav_event_owner\test_terminal_route_metadata.ahk"))
	AssertEqual("config-transition", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\infra\config\transition\test_config_transition_windows_port.ahk"))
	AssertEqual("config-scope-a", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\infra\config\scope\test_global_config_scope.ahk"))
	AssertEqual("hotstrings", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\unit\test_user_hotstrings.ahk"))
	AssertEqual("core", _TestModuleOf("C:\repo\static\ergopti_plus\windows\tests\run_all.ahk"))
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
