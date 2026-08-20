; tests/unit/test_llm_menu_transactions_20260813.ahk

; ==============================================================================
; MODULE: LLM menu persistence transaction regression tests
; DESCRIPTION:
; Proves that scalar and nested menu mutations remain detached until one strict
; config.toml writer succeeds under the global terminal barrier. A refused or
; malformed writer may not leak aliases, run live application, or strand the
; caller's Critical state.
; ==============================================================================

#Requires AutoHotkey v2.0

global _LMT_WriterResult := 1
global _LMT_WriterCalls := 0
global _LMT_ApplyCalls := 0
global _LMT_WriterCritical := -1
global _LMT_ApplyCritical := -1
global _LMT_LiveAtWrite := ""
global _LMT_ConfigPath := ""
global _LMT_ApiPath := ""
global _LMT_ApiRefused := false

_LMT_Features() {
	return _LLMST_Features(false, "live-model", "ollama")
}

_LMT_Menu() {
	MenuState := _LLMST_Menu()
	MenuState["enabled"] := false
	MenuState["model"] := "live-model"
	MenuState["user_profiles"] := [Map("id", "user_one",
		"label", "Live label", "system_single", "Live prompt",
		"batch", false)]
	MenuState["profile_id"] := "user_one"
	MenuState["trigger_shortcut"] := "Ctrl+Space"
	MenuState["nav_modifiers"] := ""
	MenuState["disabled_apps"] := []
	MenuState["ollama_port"] := 11434
	MenuState["api_entries"] := []
	MenuState["api_entry_id"] := ""
	MenuState["app_profile_overrides"] := Map()
	MenuState["onboarding_seen"] := false
	return MenuState
}

_LMT_Acquire(Paths) {
	return _ConfigWriteTerminalTryAcquire(Paths)
}

_LMT_Settle(Bundle) {
	return 1
}

_LMT_Quiesce(Bundle) {
	return 1
}

_LMT_Collect(CandidateFeatures, CandidateMenu) {
	return [{ Section: "llm", Key: "enabled",
		Value: CandidateMenu["enabled"] }]
}

_LMT_MutateNested(Candidate) {
	Candidate["enabled"] := true
	Candidate["user_profiles"][1]["label"] := "Candidate label"
	return true
}

_LMT_Writer(Path, Updates) {
	global _LMT_WriterResult, _LMT_WriterCalls, _LMT_WriterCritical
	global _LMT_LiveAtWrite, _LLM_Menu
	_LMT_WriterCalls += 1
	_LMT_WriterCritical := A_IsCritical
	_LMT_LiveAtWrite := _LLM_Menu["user_profiles"][1]["label"]
	return _LMT_WriterResult
}

_LMT_Apply(Candidate) {
	global _LMT_ApplyCalls, _LMT_ApplyCritical
	_LMT_ApplyCalls += 1
	_LMT_ApplyCritical := A_IsCritical
	return true
}

_LMT_Notify(Message, Options) {
	return true
}

_LMT_InstallFixture() {
	global Features, _LLM_Menu, ConfigurationFile
	global _LMT_WriterResult, _LMT_WriterCalls, _LMT_ApplyCalls
	global _LMT_WriterCritical, _LMT_ApplyCritical, _LMT_LiveAtWrite
	global _LMT_ConfigPath
	Previous := Map("features", Features, "menu", _LLM_Menu,
		"path", ConfigurationFile)
	_LMT_ConfigPath := A_Temp . "\ergopti_llm_menu_transaction.toml"
	ConfigurationFile := _LMT_ConfigPath
	Features := _LMT_Features()
	_LLM_Menu := _LMT_Menu()
	_LMT_WriterResult := 1
	_LMT_WriterCalls := 0
	_LMT_ApplyCalls := 0
	_LMT_WriterCritical := -1
	_LMT_ApplyCritical := -1
	_LMT_LiveAtWrite := ""
	return Previous
}

_LMT_RestoreFixture(Previous) {
	global Features, _LLM_Menu, ConfigurationFile
	Features := Previous["features"]
	_LLM_Menu := Previous["menu"]
	ConfigurationFile := Previous["path"]
}

_LMT_FailedWriterKeepsNestedLiveState() {
	global Features, _LLM_Menu, _LMT_WriterResult
	global _LMT_WriterCalls, _LMT_ApplyCalls
	Previous := _LMT_InstallFixture()
	try {
		OldFeatures := Features
		OldMenu := _LLM_Menu
		_LMT_WriterResult := 0
		AssertFalse(LLM_Menu_CommitMutation("the test LLM setting",
			_LMT_MutateNested, _LMT_Apply, _LMT_Writer, _LMT_Notify,
			_LMT_Acquire, _LMT_Settle, _LMT_Quiesce, _LMT_Collect))
		AssertEqual(1, _LMT_WriterCalls)
		AssertEqual(0, _LMT_ApplyCalls,
			"live application must not run after a refused durable writer")
		AssertTrue(Features == OldFeatures,
			"a failed writer must retain the exact live Features object")
		AssertTrue(_LLM_Menu == OldMenu,
			"a failed writer must retain the exact live menu object")
		AssertFalse(_LLM_Menu["enabled"])
		AssertEqual("Live label", _LLM_Menu["user_profiles"][1]["label"],
			"deep candidate children must not alias the live profile Map")
		AssertFalse(_ConfigWriteTerminalIsActive(),
			"ordinary failure must release global terminal admission")
	} finally _LMT_RestoreFixture(Previous)
}
Test("LLM menu: failed writer keeps nested state detached "
	. "(llm-menu-detached-failed-writer)",
	_LMT_FailedWriterKeepsNestedLiveState)

_LMT_DurabilityPrecedesPublicationAndDefusesCritical() {
	global _LLM_Menu, _LMT_WriterCalls, _LMT_ApplyCalls
	global _LMT_WriterCritical, _LMT_ApplyCritical, _LMT_LiveAtWrite
	Previous := _LMT_InstallFixture()
	try {
		PriorCritical := Critical("On")
		try {
			AssertTrue(LLM_Menu_CommitMutation("the test LLM setting",
				_LMT_MutateNested, _LMT_Apply, _LMT_Writer, _LMT_Notify,
				_LMT_Acquire, _LMT_Settle, _LMT_Quiesce, _LMT_Collect))
			AssertTrue(A_IsCritical,
				"the transaction must restore its caller's Critical state")
		} finally Critical(PriorCritical)
		AssertEqual(1, _LMT_WriterCalls)
		AssertEqual("Live label", _LMT_LiveAtWrite,
			"the writer must observe old RAM until durability succeeds")
		AssertEqual("Candidate label",
			_LLM_Menu["user_profiles"][1]["label"])
		AssertTrue(_LLM_Menu["enabled"])
		AssertEqual(1, _LMT_ApplyCalls)
		AssertEqual(0, _LMT_WriterCritical,
			"durable I/O must never inherit Critical")
		AssertEqual(0, _LMT_ApplyCritical,
			"post-commit engine/menu work must remain interruptible")
		AssertFalse(_ConfigWriteTerminalIsActive())
	} finally _LMT_RestoreFixture(Previous)
}
Test("LLM menu: durable write precedes publication outside inherited Critical "
	. "(llm-menu-durable-before-publish)",
	_LMT_DurabilityPrecedesPublicationAndDefusesCritical)

_LMT_GlobalAdmissionRefusalDoesNotBuildCandidate() {
	global _LMT_ConfigPath, _LMT_WriterCalls, _LMT_ApplyCalls
	Previous := _LMT_InstallFixture()
	OuterBundle := _ConfigWriteTerminalTryAcquire([_LMT_ConfigPath])
	try {
		AssertTrue(OuterBundle is Object)
		AssertFalse(LLM_Menu_CommitMutation("the contended LLM setting",
			_LMT_MutateNested, _LMT_Apply, _LMT_Writer, _LMT_Notify,
			_LMT_Acquire, _LMT_Settle, _LMT_Quiesce, _LMT_Collect))
		AssertEqual(0, _LMT_WriterCalls)
		AssertEqual(0, _LMT_ApplyCalls)
	} finally {
		if OuterBundle is Object
			_ConfigWriteTerminalRelease(OuterBundle)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM menu: process-wide terminal admission rejects overlapping actions "
	. "(llm-menu-global-terminal-admission)",
	_LMT_GlobalAdmissionRefusalDoesNotBuildCandidate)

_LMT_ApiBuildConfig(Path, Updates) {
	OldContent := FSReadUtf8Exact(Path)
	if !(OldContent is String)
		return Map("status", "error", "kind", "source_unreadable",
			"content", "")
	return Map("status", "ok", "kind", "rendered",
		"content", '[llm]`nenabled = true`napi_entry_id = "api_new"`n',
		"source_present", 1, "source_content", OldContent)
}

_LMT_ApiSerialize(CandidateMenu) {
	return CandidateMenu["api_entry_id"] == "api_new"
		? '[{"Id":"api_new"}]' : "[]"
}

_LMT_ApiMutate(Candidate) {
	Candidate["enabled"] := true
	return _LLM_Menu_UpsertApiEntryCandidate(Candidate,
		Map("Id", "api_new", "Name", "New", "Provider", "openai",
			"BaseUrl", "https://example.invalid", "Token", "secret",
			"Model", "model"), "")
}

_LMT_ApiMoveReplace(Source, Destination) {
	global _LMT_ApiPath, _LMT_ApiRefused
	if !_LMT_ApiRefused
			&& _ConfigWriteLeaseKey(Destination)
				== _ConfigWriteLeaseKey(_LMT_ApiPath) {
		_LMT_ApiRefused := true
		return 0
	}
	return FSAtomicMoveReplace(Source, Destination) ? 1 : 0
}

_LMT_ApiFailingPort() {
	Port := ConfigTransitionProductionPort()
	Port["move_replace"] := _LMT_ApiMoveReplace
	return Port
}

_LMT_InstallApiFixture() {
	global Features, _LLM_Menu, ConfigurationFile, _PathsFile
	global _LMT_ApiPath, _LMT_ApiRefused, _LMT_ApplyCalls
	Previous := Map("features", Features, "menu", _LLM_Menu,
		"config", ConfigurationFile, "paths", _PathsFile)
	Dir := A_Temp . "\ergopti-llm-api-transaction-"
		. A_ScriptHwnd . "-" . A_TickCount
	DirCreate(Dir)
	ConfigurationFile := Dir . "\config.toml"
	_PathsFile := Dir . "\paths.toml"
	_LMT_ApiPath := Dir . "\api_entries.json"
	FSWriteCreateDurable(ConfigurationFile,
		'[llm]`nenabled = false`napi_entry_id = "api_old"`n')
	FSWriteCreateDurable(_LMT_ApiPath, '[{"Id":"api_old"}]')
	Features := _LMT_Features()
	_LLM_Menu := _LMT_Menu()
	_LLM_Menu["api_entries"] := [Map("Id", "api_old", "Name", "Old",
		"Provider", "openai", "BaseUrl", "https://old.invalid",
		"Token", "old", "Model", "old-model")]
	_LLM_Menu["api_entry_id"] := "api_old"
	_LMT_ApiRefused := false
	_LMT_ApplyCalls := 0
	Previous["dir"] := Dir
	return Previous
}

_LMT_RestoreApiFixture(Previous) {
	global Features, _LLM_Menu, ConfigurationFile, _PathsFile
	Features := Previous["features"]
	_LLM_Menu := Previous["menu"]
	ConfigurationFile := Previous["config"]
	_PathsFile := Previous["paths"]
	try DirDelete(Previous["dir"], true)
}

_LMT_ApiCommit(Port := 0) {
	return LLM_Menu_CommitApiEntriesMutation("the test API entry",
		_LMT_ApiMutate, _LMT_Apply, Port, _LMT_Notify, _LMT_Acquire,
		_LMT_Settle, _LMT_Quiesce, _LMT_Collect, _LMT_ApiBuildConfig,
		_LMT_ApiSerialize)
}

_LMT_ApiSuccessPublishesOnlyAfterBothFiles() {
	global _LLM_Menu, ConfigurationFile, _PathsFile, _LMT_ApiPath
	global _LMT_ApplyCalls
	Previous := _LMT_InstallApiFixture()
	try {
		AssertTrue(_LMT_ApiCommit(ConfigTransitionProductionPort()))
		AssertContains(FSReadUtf8Exact(ConfigurationFile),
			'api_entry_id = "api_new"')
		AssertEqual('[{"Id":"api_new"}]', FSReadUtf8Exact(_LMT_ApiPath))
		AssertEqual("api_new", _LLM_Menu["api_entry_id"])
		AssertTrue(_LLM_Menu["enabled"])
		AssertEqual(1, _LMT_ApplyCalls)
		AssertFalse(FSStrictExists(ConfigTransitionWalPath(_PathsFile)) == 1,
			"successful live CRUD must clean its committed-new WAL before release")
		AssertFalse(_ConfigWriteTerminalIsActive())
	} finally _LMT_RestoreApiFixture(Previous)
}
Test("LLM API entries: both durable targets precede live publication "
	. "(llm-api-two-target-durable-publish)",
	_LMT_ApiSuccessPublishesOnlyAfterBothFiles)

_LMT_ApiSecondTargetFailureRollsEverythingOld() {
	global _LLM_Menu, ConfigurationFile, _PathsFile, _LMT_ApiPath
	global _LMT_ApiRefused, _LMT_ApplyCalls
	Previous := _LMT_InstallApiFixture()
	try {
		AssertFalse(_LMT_ApiCommit(_LMT_ApiFailingPort()))
		AssertTrue(_LMT_ApiRefused,
			"the adversarial port must refuse publication of api_entries.json")
		AssertContains(FSReadUtf8Exact(ConfigurationFile),
			'api_entry_id = "api_old"',
			"the first target must roll back when the second target fails")
		AssertEqual('[{"Id":"api_old"}]', FSReadUtf8Exact(_LMT_ApiPath))
		AssertEqual("api_old", _LLM_Menu["api_entry_id"],
			"failed multi-target durability must leave live authority old")
		AssertFalse(_LLM_Menu["enabled"])
		AssertEqual(0, _LMT_ApplyCalls)
		AssertFalse(FSStrictExists(ConfigTransitionWalPath(_PathsFile)) == 1,
			"verified all-old rollback must remove its WAL")
		AssertFalse(_ConfigWriteTerminalIsActive())
	} finally _LMT_RestoreApiFixture(Previous)
}
Test("LLM API entries: second-target refusal restores both old authorities "
	. "(llm-api-two-target-failure-rollback)",
	_LMT_ApiSecondTargetFailureRollsEverythingOld)
