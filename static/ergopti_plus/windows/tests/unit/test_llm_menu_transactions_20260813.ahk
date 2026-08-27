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
global _LMT_PrepareResult := 1
global _LMT_PrepareCalls := 0
global _LMT_PublishCalls := 0
global _LMT_Events := []
global _LMT_ApiLoadReports := []
global _LMT_StableEncryptedTokens := Map()

_LMT_StableEncryptToken(Token) {
	global _LMT_StableEncryptedTokens
	if !_LMT_StableEncryptedTokens.Has(Token) {
		Encrypted := LLM_ApiToken_Encrypt(Token)
		if !(Encrypted is String)
			throw Error("test DPAPI encryption failed")
		_LMT_StableEncryptedTokens[Token] := Encrypted
	}
	return _LMT_StableEncryptedTokens[Token]
}

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
	global _LMT_LiveAtWrite, _LLM_Menu, _LMT_Events
	_LMT_WriterCalls += 1
	_LMT_Events.Push("writer")
	_LMT_WriterCritical := A_IsCritical
	_LMT_LiveAtWrite := _LLM_Menu["user_profiles"][1]["label"]
	return _LMT_WriterResult
}

_LMT_Apply(Candidate) {
	global _LMT_ApplyCalls, _LMT_ApplyCritical, _LMT_Events
	_LMT_ApplyCalls += 1
	_LMT_Events.Push("apply")
	_LMT_ApplyCritical := A_IsCritical
	return true
}

_LMT_Prepare(Candidate) {
	global _LMT_PrepareResult, _LMT_PrepareCalls, _LMT_Events
	_LMT_PrepareCalls += 1
	_LMT_Events.Push("prepare")
	return _LMT_PrepareResult ? Map("candidate", Candidate) : false
}

_LMT_Publish(CandidateFeatures, CandidateMenu, Owner) {
	global _LMT_PublishCalls, _LMT_Events
	_LMT_PublishCalls += 1
	_LMT_Events.Push("publish")
	if !(Owner is Map)
		return false
	return _LLM_Menu_PublishCandidate(CandidateFeatures, CandidateMenu)
}

_LMT_Notify(Message, Options) {
	return true
}

_LMT_InstallFixture() {
	global Features, _LLM_Menu, ConfigurationFile
	global _LMT_WriterResult, _LMT_WriterCalls, _LMT_ApplyCalls
	global _LMT_WriterCritical, _LMT_ApplyCritical, _LMT_LiveAtWrite
	global _LMT_ConfigPath, _LMT_PrepareResult, _LMT_PrepareCalls
	global _LMT_PublishCalls, _LMT_Events
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
	_LMT_PrepareResult := 1
	_LMT_PrepareCalls := 0
	_LMT_PublishCalls := 0
	_LMT_Events := []
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

_LMT_PrepareRefusalPrecedesDurability() {
	global _LMT_PrepareResult, _LMT_PrepareCalls, _LMT_PublishCalls
	global _LMT_WriterCalls, _LMT_ApplyCalls, _LMT_Events
	Previous := _LMT_InstallFixture()
	try {
		_LMT_PrepareResult := 0
		AssertFalse(LLM_Menu_CommitMutation("the prepared LLM setting",
			_LMT_MutateNested, _LMT_Apply, _LMT_Writer, _LMT_Notify,
			_LMT_Acquire, _LMT_Settle, _LMT_Quiesce, _LMT_Collect,
			_LMT_Prepare, _LMT_Publish))
		AssertEqual(1, _LMT_PrepareCalls)
		AssertEqual(0, _LMT_WriterCalls,
			"native preparation refusal must happen before durable I/O")
		AssertEqual(0, _LMT_ApplyCalls)
		AssertEqual(0, _LMT_PublishCalls)
		AssertEqual(1, _LMT_Events.Length)
		AssertEqual("prepare", _LMT_Events[1])
	} finally _LMT_RestoreFixture(Previous)
}
Test("LLM menu: native preparation refusal precedes durable write "
	. "(llm-menu-prepare-before-durability)",
	_LMT_PrepareRefusalPrecedesDurability)

_LMT_FailedWriterKeepsPreparedSurfaceInert() {
	global _LMT_WriterResult, _LMT_PrepareCalls, _LMT_PublishCalls
	global _LMT_WriterCalls, _LMT_ApplyCalls, _LMT_Events
	Previous := _LMT_InstallFixture()
	try {
		_LMT_WriterResult := 0
		AssertFalse(LLM_Menu_CommitMutation("the prepared LLM setting",
			_LMT_MutateNested, _LMT_Apply, _LMT_Writer, _LMT_Notify,
			_LMT_Acquire, _LMT_Settle, _LMT_Quiesce, _LMT_Collect,
			_LMT_Prepare, _LMT_Publish))
		AssertEqual(1, _LMT_PrepareCalls)
		AssertEqual(1, _LMT_WriterCalls)
		AssertEqual(0, _LMT_PublishCalls,
			"a failed writer must never activate the prepared native surface")
		AssertEqual(0, _LMT_ApplyCalls)
		AssertEqual(2, _LMT_Events.Length)
		AssertEqual("prepare", _LMT_Events[1])
		AssertEqual("writer", _LMT_Events[2])
	} finally _LMT_RestoreFixture(Previous)
}
Test("LLM menu: failed writer never activates the prepared native surface "
	. "(llm-menu-prepared-surface-inert)",
	_LMT_FailedWriterKeepsPreparedSurfaceInert)

_LMT_SuccessPublishesPreparedSurfaceOnce() {
	global _LMT_PrepareCalls, _LMT_PublishCalls, _LMT_WriterCalls
	global _LMT_ApplyCalls, _LMT_Events
	Previous := _LMT_InstallFixture()
	try {
		AssertTrue(LLM_Menu_CommitMutation("the prepared LLM setting",
			_LMT_MutateNested, _LMT_Apply, _LMT_Writer, _LMT_Notify,
			_LMT_Acquire, _LMT_Settle, _LMT_Quiesce, _LMT_Collect,
			_LMT_Prepare, _LMT_Publish))
		AssertEqual(1, _LMT_PrepareCalls)
		AssertEqual(1, _LMT_WriterCalls)
		AssertEqual(1, _LMT_PublishCalls)
		AssertEqual(1, _LMT_ApplyCalls)
		AssertEqual(4, _LMT_Events.Length)
		AssertEqual("prepare", _LMT_Events[1])
		AssertEqual("writer", _LMT_Events[2])
		AssertEqual("publish", _LMT_Events[3])
		AssertEqual("apply", _LMT_Events[4])
	} finally _LMT_RestoreFixture(Previous)
}
Test("LLM menu: publication atomically activates the prepared native surface "
	. "(llm-menu-prepared-surface-publish)",
	_LMT_SuccessPublishesPreparedSurfaceOnce)

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

_LMT_Profile(Id, Label := "Profile") {
	return Map("id", Id, "label", Label,
		"system_single", "Single " . Id,
		"system_multi", "Multi " . Id,
		"batch", false)
}


_LMT_DuplicateProfileDeleteIsMutationFree() {
	global _LLM_Menu, _LMT_WriterCalls, _LMT_ApplyCalls
	Previous := _LMT_InstallFixture()
	try {
		_LLM_Menu["user_profiles"] := [
			_LMT_Profile("profile_p", "First P"),
			_LMT_Profile("profile_p", "Second P"),
			_LMT_Profile("profile_q", "Profile Q")]
		_LLM_Menu["profile_id"] := "profile_p"
		_LLM_Menu["app_profile_overrides"] := Map(
			"app_one", "profile_p", "app_two", "profile_p",
			"app_q", "profile_q")
		OldMenu := _LLM_Menu

		AssertFalse(LLM_Menu_CommitMutation("the duplicate profile removal",
			(Candidate) => _LLM_Menu_DeleteProfileCandidate(
				Candidate, "profile_p"),
			_LMT_Apply, _LMT_Writer, _LMT_Notify,
			_LMT_Acquire, _LMT_Settle, _LMT_Quiesce, _LMT_Collect))
		AssertEqual(0, _LMT_WriterCalls,
			"ambiguous identity must be rejected before durable mutation")
		AssertEqual(0, _LMT_ApplyCalls)
		AssertTrue(_LLM_Menu == OldMenu,
			"ambiguous deletion must preserve the exact published menu owner")
		AssertEqual(3, _LLM_Menu["user_profiles"].Length)
		AssertEqual("profile_p", _LLM_Menu["profile_id"])
		AssertEqual(3, _LLM_Menu["app_profile_overrides"].Count)
	} finally _LMT_RestoreFixture(Previous)
}
Test("LLM profiles: duplicate delete is refused before mutation or persistence "
	. "(ahk-015-duplicate-delete-no-mutation)",
	_LMT_DuplicateProfileDeleteIsMutationFree)


_LMT_ProfileDeleteRemovesEveryExactOverride() {
	global _LLM_Menu, _LMT_WriterCalls, _LMT_ApplyCalls
	Previous := _LMT_InstallFixture()
	try {
		_LLM_Menu["user_profiles"] := [
			_LMT_Profile("profile_p", "Profile P"),
			_LMT_Profile("profile_q", "Profile Q")]
		_LLM_Menu["profile_id"] := "profile_p"
		_LLM_Menu["app_profile_overrides"] := Map(
			"app_one", "profile_p", "app_two", "profile_p",
			"app_q", "profile_q")

		AssertTrue(LLM_Menu_CommitMutation("the exact profile removal",
			(Candidate) => _LLM_Menu_DeleteProfileCandidate(
				Candidate, "profile_p"),
			_LMT_Apply, _LMT_Writer, _LMT_Notify,
			_LMT_Acquire, _LMT_Settle, _LMT_Quiesce, _LMT_Collect))
		AssertEqual(1, _LMT_WriterCalls)
		AssertEqual(1, _LMT_ApplyCalls)
		AssertEqual(1, _LLM_Menu["user_profiles"].Length)
		AssertEqual("profile_q", _LLM_Menu["user_profiles"][1]["id"])
		AssertEqual("basic", _LLM_Menu["profile_id"],
			"only deletion of the active profile may reset the global selection")
		AssertEqual(1, _LLM_Menu["app_profile_overrides"].Count)
		AssertFalse(_LLM_Menu["app_profile_overrides"].Has("app_one"))
		AssertFalse(_LLM_Menu["app_profile_overrides"].Has("app_two"))
		AssertEqual("profile_q",
			_LLM_Menu["app_profile_overrides"]["app_q"])

		Candidate := _LMT_Menu()
		Candidate["user_profiles"] := [
			_LMT_Profile("profile_p"), _LMT_Profile("profile_q")]
		Candidate["profile_id"] := "advanced"
		Candidate["app_profile_overrides"] := Map("app_one", "profile_p")
		AssertTrue(_LLM_Menu_DeleteProfileCandidate(Candidate, "profile_p"))
		AssertEqual("advanced", Candidate["profile_id"],
			"deleting an inactive profile must preserve the active selection")
	} finally _LMT_RestoreFixture(Previous)
}
Test("LLM profiles: delete removes all and only exact override references "
	. "(ahk-015-delete-exact-reference-class)",
	_LMT_ProfileDeleteRemovesEveryExactOverride)


_LMT_ProfileBootPruneRemovesEveryOrphan() {
	MenuState := _LMT_Menu()
	MenuState["user_profiles"] := [_LMT_Profile("profile_q")]
	MenuState["app_profile_overrides"] := Map(
		"orphan_one", "missing_one",
		"valid_builtin", "advanced",
		"orphan_two", "missing_two",
		"valid_custom", "profile_q",
		"orphan_three", "missing_three")
	AssertTrue(_LLM_Menu_PruneOrphanProfileOverrides(MenuState))
	AssertEqual(2, MenuState["app_profile_overrides"].Count)
	AssertEqual("advanced",
		MenuState["app_profile_overrides"]["valid_builtin"])
	AssertEqual("profile_q",
		MenuState["app_profile_overrides"]["valid_custom"])
	AssertFalse(_LLM_Menu_PruneOrphanProfileOverrides(MenuState),
		"a fully-pruned image must be idempotent")
}
Test("LLM profiles: boot prune removes every orphan without skipping siblings "
	. "(ahk-015-boot-prune-all-orphans)",
	_LMT_ProfileBootPruneRemovesEveryOrphan)

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

_LMT_ApiCommitWithSerializer(SerializeFn) {
	return LLM_Menu_CommitApiEntriesMutation("the test API entry",
		_LMT_ApiMutate, _LMT_Apply, ConfigTransitionProductionPort(),
		_LMT_Notify, _LMT_Acquire, _LMT_Settle, _LMT_Quiesce, _LMT_Collect,
		_LMT_ApiBuildConfig, SerializeFn)
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

_LMT_ApiTokenEncryptionFailurePreservesOldImage() {
	global _LLM_Menu, ConfigurationFile, _PathsFile, _LMT_ApiPath
	global _LMT_ApplyCalls
	Previous := _LMT_InstallApiFixture()
	OldApiImage := '[{"Id":"api_old","Token":"dpapi:preserved-ciphertext"}]'
	try {
		FileDelete(_LMT_ApiPath)
		FSWriteCreateDurable(_LMT_ApiPath, OldApiImage)
		OldConfigImage := FSReadUtf8Exact(ConfigurationFile)
		OldMenu := _LLM_Menu
		Encrypted := LLM_ApiToken_Encrypt("audit-secret")
		AssertTrue(Encrypted is String)
		AssertTrue(LLM_ApiToken_IsValidEnvelope(Encrypted),
			"a successful encryption must produce a usable DPAPI envelope")
		AssertEqual("audit-secret", LLM_ApiToken_Decrypt(Encrypted),
			"the strict envelope contract must retain DPAPI round-trip behavior")
		AssertFalse(InStr(Encrypted, "audit-secret") > 0,
			"the persisted envelope must not contain the raw token")
		AssertFalse(LLM_ApiToken_Encrypt("audit-secret", (*) => ""),
			"DPAPI failure must not degrade an API token to plaintext")
		AssertFalse(LLM_ApiToken_Encrypt("dpapi:"),
			"a prefix-shaped raw token must not impersonate an encrypted envelope")
		for Fixture in [
			["identity", (Token) => Token],
			["empty envelope", (*) => "dpapi:"],
			["malformed envelope", (*) => "dpapi:not-base64!"]
		] {
			SerializeFn := (MenuState) => _LLM_Menu_SerializeApiEntries(
				MenuState, Fixture[2])
			AssertFalse(_LMT_ApiCommitWithSerializer(SerializeFn),
				Fixture[1] . " token encryption must refuse the complete transition")
			AssertEqual(OldApiImage, FSReadUtf8Exact(_LMT_ApiPath),
				Fixture[1] . " failure must preserve the previous encrypted image")
			AssertEqual(OldConfigImage, FSReadUtf8Exact(ConfigurationFile),
				Fixture[1] . " failure must preserve the sibling config image")
			AssertTrue(_LLM_Menu == OldMenu,
				Fixture[1] . " failure must not publish the detached candidate")
			AssertEqual(0, _LMT_ApplyCalls,
				Fixture[1] . " failure must not invoke runtime application")
			AssertFalse(FSStrictExists(ConfigTransitionWalPath(_PathsFile)) == 1,
				Fixture[1] . " failure must settle without a transition WAL")
		}
	} finally _LMT_RestoreApiFixture(Previous)
}
Test("LLM API entries: token encryption failure preserves old authority "
	. "(audit-ahk-007)",
	_LMT_ApiTokenEncryptionFailurePreservesOldImage)


_LMT_ApiEntry(Id, Name := "Entry", Provider := "openai") {
	return Map("Id", Id, "Name", Name, "Provider", Provider,
		"BaseUrl", "https://example.invalid", "Token", "secret",
		"Model", "model")
}


_LMT_ApiLoadReport(Reason) {
	global _LMT_ApiLoadReports
	_LMT_ApiLoadReports.Push(Reason)
	return true
}


_LMT_DuplicateApiImageIsRejectedWithoutPublication() {
	global _LLM_Menu, ConfigurationFile, LLM_API_PROVIDERS
	global _LMT_ApiLoadReports
	Previous := _LMT_InstallFixture()
	PreviousProviders := LLM_API_PROVIDERS
	Dir := A_Temp . "\ergopti-api-identity-load-"
		. A_ScriptHwnd . "-" . A_TickCount
	DirCreate(Dir)
	ConfigurationFile := Dir . "\config.toml"
	Raw := '[{"Id":"duplicate","Name":"First","Provider":"openai",'
		. '"BaseUrl":"https://first.invalid","Token":"one","Model":"m1"},'
		. '{"Id":"duplicate","Name":"Second","Provider":"openai",'
		. '"BaseUrl":"https://second.invalid","Token":"two","Model":"m2"}]'
	Path := Dir . "\api_entries.json"
	FSWriteCreateDurable(Path, Raw)
	SentinelEntries := [_LMT_ApiEntry("live", "Live")]
	_LLM_Menu["api_entries"] := SentinelEntries
	_LLM_Menu["api_entry_id"] := "live"
	LLM_API_PROVIDERS := Map("openai", Map())
	_LMT_ApiLoadReports := []
	try {
		AssertFalse(_LLM_Menu_LoadApiEntries(0, _LMT_ApiLoadReport,
			(Token) => Token, LLM_API_PROVIDERS),
			"a duplicate persisted identity must reject the complete image")
		AssertTrue(_LLM_Menu["api_entries"] == SentinelEntries,
			"a rejected persisted image must not publish any detached row")
		AssertEqual("live", _LLM_Menu["api_entry_id"],
			"a rejected persisted image must preserve the active identity")
		AssertEqual(Raw, FSReadUtf8Exact(Path),
			"load rejection must never rewrite or quarantine user credentials")
		AssertEqual(1, _LMT_ApiLoadReports.Length,
			"one corrupt persisted image must produce one terminal diagnostic")
		AssertContains(_LMT_ApiLoadReports[1], "duplicate API entry id 'duplicate'",
			"the diagnostic must identify the ambiguous stable identity")
	} finally {
		LLM_API_PROVIDERS := PreviousProviders
		try DirDelete(Dir, true)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM API entries: duplicate persisted ids reject the whole image "
	. "(api-entry-identity-cardinality)",
	_LMT_DuplicateApiImageIsRejectedWithoutPublication)


_LMT_AssertApiImageRejected(Raw, CaseName) {
	global _LLM_Menu, ConfigurationFile
	Dir := A_Temp . "\ergopti-api-schema-load-"
		. A_ScriptHwnd . "-" . A_TickCount
	DirCreate(Dir)
	ConfigurationFile := Dir . "\config.toml"
	Path := Dir . "\api_entries.json"
	FSWriteCreateDurable(Path, Raw)
	SentinelEntries := [_LMT_ApiEntry("live", "Live")]
	_LLM_Menu["api_entries"] := SentinelEntries
	_LLM_Menu["api_entry_id"] := "live"
	try {
		_LLM_Menu_LoadApiEntries()
		AssertTrue(_LLM_Menu["api_entries"] == SentinelEntries,
			CaseName . " must reject the complete image before publication")
		AssertEqual("live", _LLM_Menu["api_entry_id"],
			CaseName . " must preserve the exact active identity")
		AssertEqual(Raw, FSReadUtf8Exact(Path),
			CaseName . " rejection must preserve the persisted bytes")
	} finally try DirDelete(Dir, true)
}


_LMT_ApiImageWithFieldValue(Field, JsonValue) {
	Values := Map(
		"Id", '"one"',
		"Name", '"One"',
		"Provider", '"openai"',
		"BaseUrl", '"https://one.invalid"',
		"Token", '"secret"',
		"Model", '"m1"')
	Values[Field] := JsonValue
	Parts := []
	for Key in ["Id", "Name", "Provider", "BaseUrl", "Token", "Model"]
		Parts.Push('"' . Key . '":' . Values[Key])
	return "[{" . _LLM_MenuJoin(Parts, ",") . "}]"
}


_LMT_ApiLoaderRejectsMalformedSchemaAsOneImage() {
	global LLM_API_PROVIDERS
	Previous := _LMT_InstallFixture()
	PreviousProviders := LLM_API_PROVIDERS
	LLM_API_PROVIDERS := Map("openai", Map())
	ValidObject := '{"Id":"one","Name":"One","Provider":"openai",'
		. '"BaseUrl":"https://one.invalid","Token":"secret","Model":"m1"}'
	try {
		_LMT_AssertApiImageRejected(ValidObject, "non-array top-level JSON")
		_LMT_AssertApiImageRejected("[" . ValidObject . "] trailing",
			"JSON with trailing data")
		for Field in ["Id", "Name", "Provider", "BaseUrl", "Token", "Model"]
			_LMT_AssertApiImageRejected(_LMT_ApiImageWithFieldValue(Field, "42"),
				"non-string required field " . Field)
		_LMT_AssertApiImageRejected('[{"Id":"one","Name":"One",'
			. '"Provider":"unknown","BaseUrl":"https://one.invalid",'
			. '"Token":"secret","Model":"m1"}]', "unknown provider")
		_LMT_AssertApiImageRejected('[{"Id":"one","Name":"One",'
			. '"Provider":"openai","BaseUrl":"https://one.invalid",'
			. '"Token":"secret"}]', "missing required field")
	} finally {
		LLM_API_PROVIDERS := PreviousProviders
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM API entries: loader rejects malformed schema as one image "
	. "(api-entry-identity-cardinality)",
	_LMT_ApiLoaderRejectsMalformedSchemaAsOneImage)


_LMT_ApiParserPreservesEscapedStrings() {
	Providers := Map("openai", Map())
	Parsed := _LLM_Menu_ParseAndValidateApiEntries(
		'[{"Id":"one","Name":"Quoted \"name\"","Provider":"openai",'
		. '"BaseUrl":"https://one.invalid/{path}",'
		. '"Token":"brace{token}\\tail","Model":"m1"}]',
		Providers, (Token) => Token)
	AssertTrue(Parsed["ok"],
		"the strict parser must retain valid escaped strings and literal braces")
	AssertEqual('Quoted "name"', Parsed["entries"][1]["Name"])
	AssertEqual("https://one.invalid/{path}", Parsed["entries"][1]["BaseUrl"])
	AssertEqual("brace{token}\tail", Parsed["entries"][1]["Token"])
}
Test("LLM API entries: strict parser preserves escaped strings and braces "
	. "(api-entry-identity-cardinality)",
	_LMT_ApiParserPreservesEscapedStrings)


_LMT_ApiEntryControlCharactersNeverPublish() {
	Providers := Map("openai", Map())
	for Field in ["Id", "Name", "BaseUrl", "Token", "Model"] {
		Raw := _LMT_ApiImageWithFieldValue(Field, '"bad\noutput = injected"')
		Parsed := _LLM_Menu_ParseAndValidateApiEntries(
			Raw, Providers, (Token) => Token)
		AssertFalse(Parsed["ok"],
			"(ahk2-12-curl-config-boundary) persisted control-bearing " . Field
			. " must reject the complete image")

		Candidate := Map("api_entries", [_LMT_ApiEntry("live", "Live")],
			"api_entry_id", "live")
		Before := _LLM_Menu_SerializeApiEntries(Candidate, _LMT_StableEncryptToken)
		NewEntry := _LMT_ApiEntry("new", "New")
		NewEntry[Field] .= "`noutput = injected"
		AssertFalse(_LLM_Menu_UpsertApiEntryCandidate(Candidate, NewEntry, ""),
			"(ahk2-12-curl-config-boundary) interactive control-bearing " . Field
			. " must be refused before candidate mutation")
		AssertEqual(Before,
			_LLM_Menu_SerializeApiEntries(Candidate, _LMT_StableEncryptToken),
			"a refused API entry must preserve the detached graph byte-for-byte")
	}
	EncryptedImage := _LMT_ApiImageWithFieldValue("Token", '"encrypted"')
	DecryptedControl := _LLM_Menu_ParseAndValidateApiEntries(
		EncryptedImage, Providers, (*) => "secret`nheader = injected")
	AssertFalse(DecryptedControl["ok"],
		"(ahk2-12-curl-config-boundary) controls revealed by token decryption must fail closed")
}
Test("LLM API entries: control characters never publish from disk or CRUD "
	. "(ahk2-12-curl-config-boundary)",
	_LMT_ApiEntryControlCharactersNeverPublish)


_LMT_DuplicateApiCandidatesRefuseEveryCrudMutation() {
	DuplicateA := _LMT_ApiEntry("duplicate", "First")
	DuplicateB := _LMT_ApiEntry("duplicate", "Second")

	SelectCandidate := Map("api_entries", [DuplicateA, DuplicateB],
		"api_entry_id", "before")
	AssertFalse(_LLM_Menu_SelectApiEntryCandidate(SelectCandidate, "duplicate"))
	AssertEqual("before", SelectCandidate["api_entry_id"])

	EditCandidate := Map("api_entries", [DuplicateA, DuplicateB],
		"api_entry_id", "duplicate")
	BeforeEdit := _LLM_Menu_SerializeApiEntries(EditCandidate, _LMT_StableEncryptToken)
	AssertFalse(_LLM_Menu_UpsertApiEntryCandidate(EditCandidate,
		_LMT_ApiEntry("duplicate", "Replacement"), "duplicate"),
		"editing an ambiguous identity must refuse instead of replacing the first row")
	AssertEqual(BeforeEdit,
		_LLM_Menu_SerializeApiEntries(EditCandidate, _LMT_StableEncryptToken),
		"a refused ambiguous edit must leave every credential byte unchanged")

	RemoveCandidate := Map("api_entries", [DuplicateA, DuplicateB],
		"api_entry_id", "duplicate")
	BeforeRemove := _LLM_Menu_SerializeApiEntries(RemoveCandidate, _LMT_StableEncryptToken)
	AssertFalse(_LLM_Menu_RemoveApiEntryCandidate(RemoveCandidate, "duplicate"))
	AssertEqual(BeforeRemove,
		_LLM_Menu_SerializeApiEntries(RemoveCandidate, _LMT_StableEncryptToken),
		"a refused ambiguous removal must leave every credential byte unchanged")

	CorruptSiblingCandidate := Map("api_entries", [
		_LMT_ApiEntry("duplicate", "First"),
		_LMT_ApiEntry("duplicate", "Second"),
		_LMT_ApiEntry("unique", "Unique")], "api_entry_id", "unique")
	BeforeSiblingEdit := _LLM_Menu_SerializeApiEntries(
		CorruptSiblingCandidate, _LMT_StableEncryptToken)
	AssertFalse(_LLM_Menu_UpsertApiEntryCandidate(CorruptSiblingCandidate,
		_LMT_ApiEntry("unique", "Replacement"), "unique"),
		"CRUD must refuse a corrupt sibling identity outside the selected target")
	AssertEqual(BeforeSiblingEdit, _LLM_Menu_SerializeApiEntries(
		CorruptSiblingCandidate, _LMT_StableEncryptToken))
}
Test("LLM API entries: duplicate candidate ids refuse select edit and remove "
	. "(api-entry-identity-cardinality)",
	_LMT_DuplicateApiCandidatesRefuseEveryCrudMutation)


_LMT_UniqueApiCandidatesMutateExactlyOneRow() {
	First := _LMT_ApiEntry("first", "First")
	Second := _LMT_ApiEntry("second", "Second")

	SelectCandidate := Map("api_entries", [First, Second],
		"api_entry_id", "first")
	AssertTrue(_LLM_Menu_SelectApiEntryCandidate(SelectCandidate, "second"))
	AssertEqual("second", SelectCandidate["api_entry_id"])

	EditCandidate := Map("api_entries", [First, Second],
		"api_entry_id", "first")
	AssertTrue(_LLM_Menu_UpsertApiEntryCandidate(EditCandidate,
		_LMT_ApiEntry("second", "Replacement"), "second"))
	AssertEqual("First", EditCandidate["api_entries"][1]["Name"])
	AssertEqual("Replacement", EditCandidate["api_entries"][2]["Name"])

	RemoveCandidate := Map("api_entries", [First, Second],
		"api_entry_id", "second")
	AssertTrue(_LLM_Menu_RemoveApiEntryCandidate(RemoveCandidate, "second"))
	AssertEqual(1, RemoveCandidate["api_entries"].Length)
	AssertEqual("first", RemoveCandidate["api_entries"][1]["Id"])
}
Test("LLM API entries: unique candidate ids mutate exactly one row "
	. "(api-entry-identity-cardinality)",
	_LMT_UniqueApiCandidatesMutateExactlyOneRow)
