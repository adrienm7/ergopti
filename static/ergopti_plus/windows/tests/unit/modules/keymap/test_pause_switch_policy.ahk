; tests/unit/modules/keymap/test_pause_switch_policy.ahk

; ==============================================================================
; MODULE: Pause Switch Policy
; DESCRIPTION:
; Replays tests/corpus/layouts/pause_switch_vectors.json through the AHK twin
; of the shared pause switch policy; the macOS and Linux suites replay the same
; vectors through _shared/lua/layout/pause_switch_policy.lua.
; ==============================================================================

#Requires AutoHotkey v2.0




_PSP_Corpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\layouts\pause_switch_vectors.json"))
}

/** A layout id or "" is a target; any other stored value is not. */
_PSP_Targets() {
	Corpus := _PSP_Corpus()
	AssertEqual(6, Corpus["targets"].Length, "complete target vectors")
	for Row in Corpus["targets"] {
		AssertEqual(Row["valid"] ? true : false, PauseSwitchPolicyValidTarget(Row["value"]) ? true : false, Row["id"])
		AssertEqual(Row.Get("target", ""), PauseSwitchPolicyTargetId(Row["value"]), Row["id"] . " id")
	}
}

/** Only an exact true switches, to the event's non-empty target. */
_PSP_Events() {
	Corpus := _PSP_Corpus()
	AssertEqual(14, Corpus["vectors"].Length, "complete event vectors")
	for Row in Corpus["vectors"]
		AssertEqual(Row.Get("target", ""), PauseSwitchPolicyTarget(Row["settings"], Row["event"]), Row["id"])
}

; One refusal per call: the closure reads a parameter, never a loop variable.
_PSP_AssertUnknownEvent(Event) {
	AssertThrows(() => PauseSwitchPolicyTarget(Map("enabled", true, "on_pause", "x"), Event),
		"unknown event " . Event)
}

_PSP_AssertNoSettings(Event) {
	AssertThrows(() => PauseSwitchPolicyTarget("", Event), "no settings for " . Event)
}

/** An unknown event and settings that are no Map are refused. */
_PSP_Refusals() {
	Corpus := _PSP_Corpus()
	for Event in Corpus["invalid_events"]
		_PSP_AssertUnknownEvent(Event)
	for Event in Corpus["events"]
		_PSP_AssertNoSettings(Event)
}

/** The policy reads the paths the manifest declares, with the types it expects. */
_PSP_Manifest() {
	global PAUSE_SWITCH_POLICY_PATHS
	Toggle := ManifestFindEntryByPath(PAUSE_SWITCH_POLICY_PATHS["enabled"])
	AssertEqual("boolean", Toggle["type"], "the switch is a boolean")
	for Role in ["on_pause", "on_resume"] {
		Entry := ManifestFindEntryByPath(PAUSE_SWITCH_POLICY_PATHS[Role])
		AssertEqual("string", Entry["type"], Role . " holds a layout id")
		AssertEqual("", Entry["default"], Role . " defaults to no change")
	}
}

Test("pause switch policy: targets are layout ids or no change", _PSP_Targets)
Test("pause switch policy: the shared event vectors", _PSP_Events)
Test("pause switch policy: unknown events and settings are refused", _PSP_Refusals)
Test("pause switch policy: the manifest declares the settings it reads", _PSP_Manifest)
