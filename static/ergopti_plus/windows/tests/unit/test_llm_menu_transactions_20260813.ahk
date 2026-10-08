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

#Include ../support/llm_menu_fixture_state.ahk

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
		"system_multi", "", "batch", false)]
	MenuState["profile_id"] := "user_one"
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
	global Features, _LLM_Menu, ConfigurationFile, LLM_PROFILE_HOTKEY_LIMIT
	global _LMT_WriterResult, _LMT_WriterCalls, _LMT_ApplyCalls
	global _LMT_WriterCritical, _LMT_ApplyCritical, _LMT_LiveAtWrite
	global _LMT_ConfigPath, _LMT_PrepareResult, _LMT_PrepareCalls
	global _LMT_PublishCalls, _LMT_Events
	Previous := Map("features", Features, "menu", _LLM_Menu,
		"path", ConfigurationFile, "test_state", _LMT_CaptureFixtureState(),
		"had_profile_limit", IsSet(LLM_PROFILE_HOTKEY_LIMIT))
	if IsSet(LLM_PROFILE_HOTKEY_LIMIT)
		Previous["profile_limit"] := LLM_PROFILE_HOTKEY_LIMIT
	; The actual profile provider needs the number-row protocol even in a cold fixture.
	LLM_PROFILE_HOTKEY_LIMIT := 9
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
	global Features, _LLM_Menu, ConfigurationFile, LLM_PROFILE_HOTKEY_LIMIT
	Features := Previous["features"]
	_LLM_Menu := Previous["menu"]
	ConfigurationFile := Previous["path"]
	LLM_PROFILE_HOTKEY_LIMIT := Previous["had_profile_limit"] ? Previous["profile_limit"] : unset
	_LMT_RestoreFixtureState(Previous["test_state"])
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
			_LMT_Acquire, _LMT_Settle, _LMT_Collect))
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
				_LMT_Acquire, _LMT_Settle, _LMT_Collect))
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
			_LMT_Acquire, _LMT_Settle, _LMT_Collect,
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
			_LMT_Acquire, _LMT_Settle, _LMT_Collect,
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
			_LMT_Acquire, _LMT_Settle, _LMT_Collect,
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
			_LMT_Acquire, _LMT_Settle, _LMT_Collect))
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
			_LMT_Acquire, _LMT_Settle, _LMT_Collect))
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
			_LMT_Acquire, _LMT_Settle, _LMT_Collect))
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

; The source authority is a complete canonical API entry, so new source admission
; still tests actual second-target refusal and compensation rather than malformed input.
_LMT_ApiOldImage() {
	return '[{"Id":"api_old","Name":"Old","Provider":"openai","BaseUrl":"https://old.invalid","Token":"old","Model":"old-model"}]'
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

_LMT_InstallApiFixture(Dir := "", WriteFn := FSWriteCreateDurable) {
	static Sequence := 0
	global Features, _LLM_Menu, ConfigurationFile, _PathsFile
	global _LMT_ApiPath, _LMT_ApiRefused, _LMT_ApplyCalls
	global _LMT_ApplyCritical, _LMT_Events
	Previous := Map("features", Features, "menu", _LLM_Menu,
		"config", ConfigurationFile, "paths", _PathsFile,
		"test_state", _LMT_CaptureFixtureState())
	if Dir == ""
		Dir := A_Temp . "\ergopti-llm-api-transaction-"
			. A_ScriptHwnd . "-" . A_TickCount . "-" . ++Sequence
	; Idempotent directory creation cannot establish exclusive cleanup ownership.
	if !DllCall("CreateDirectoryW", "Str", Dir, "Ptr", 0, "Int") {
		NativeError := A_LastError
		throw Error("Cannot acquire LLM fixture directory: " . Dir
			. " (Win32 error " . NativeError . ").")
	}
	try {
		ConfigPath := Dir . "\config.toml"
		ApiPath := Dir . "\api_entries.json"
		if WriteFn.Call(ConfigPath,
				'[llm]`nenabled = false`napi_entry_id = "api_old"`n') != 1
			throw Error("Cannot create initial LLM fixture file: " . ConfigPath)
		if WriteFn.Call(ApiPath, _LMT_ApiOldImage()) != 1
			throw Error("Cannot create initial LLM fixture file: " . ApiPath)
		CandidateFeatures := _LMT_Features()
		CandidateMenu := _LMT_Menu()
		CandidateMenu["api_entries"] := [Map("Id", "api_old", "Name", "Old",
			"Provider", "openai", "BaseUrl", "https://old.invalid",
			"Token", "old", "Model", "old-model")]
		CandidateMenu["api_entry_id"] := "api_old"
	} catch Error as Err {
		; Acquisition above proves this directory belongs only to this setup.
		DirDelete(Dir, true)
		throw Err
	}
	; Publish only a complete initial authority; failures leave the outer fixture live.
	ConfigurationFile := ConfigPath
	_PathsFile := Dir . "\paths.toml"
	_LMT_ApiPath := ApiPath
	Features := CandidateFeatures
	_LLM_Menu := CandidateMenu
	_LMT_ApiRefused := false
	_LMT_ApplyCalls := 0
	_LMT_ApplyCritical := -1
	_LMT_Events := []
	Previous["dir"] := Dir
	return Previous
}

_LMT_RestoreApiFixture(Previous) {
	global Features, _LLM_Menu, ConfigurationFile, _PathsFile
	Features := Previous["features"]
	_LLM_Menu := Previous["menu"]
	ConfigurationFile := Previous["config"]
	_PathsFile := Previous["paths"]
	_LMT_RestoreFixtureState(Previous["test_state"])
	try DirDelete(Previous["dir"], true)
}

_LMT_ApiCommit(Port := 0) {
	return LLM_Menu_CommitApiEntriesMutation("the test API entry",
		_LMT_ApiMutate, _LMT_Apply, Port, _LMT_Notify, _LMT_Acquire,
		_LMT_Settle, _LMT_Collect, _LMT_ApiBuildConfig,
		_LMT_ApiSerialize)
}

_LMT_ApiCommitWithSerializer(SerializeFn) {
	return LLM_Menu_CommitApiEntriesMutation("the test API entry",
		_LMT_ApiMutate, _LMT_Apply, ConfigTransitionProductionPort(),
		_LMT_Notify, _LMT_Acquire, _LMT_Settle, _LMT_Collect,
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
		AssertEqual(_LMT_ApiOldImage(), FSReadUtf8Exact(_LMT_ApiPath))
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

; The api_entries.json serializer one encryption fixture commits with. A
; function of its own so the closure reads a parameter: a closure never sees a
; for-loop variable, so built in the loop it threw an UnsetError, and every
; fixture was refused for that error instead of for its encryptor's output.
; @param EncryptFn {Func} The token encryptor under test.
; @returns {Func} A serializer taking the detached menu candidate.
_LMT_SerializerEncryptingWith(EncryptFn) {
	return (MenuState) => _LLM_Menu_SerializeApiEntries(MenuState, EncryptFn)
}

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
			SerializeFn := _LMT_SerializerEncryptingWith(Fixture[2])
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





; ========================================
; ========================================
; ======= 2/ Shared Info Bar Check =======
; ========================================
; ========================================

_LMT_InfoBarCorpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\info_bar_control.json"))
}

_LMT_InfoBarCollect(CandidateFeatures, CandidateMenu) {
	return [{ Section: "llm.display", Key: "show_info_bar", Value: CandidateMenu["show_info_bar"] }]
}

_LMT_InfoBarToggle(*) {
	return LLM_Menu_CommitMutation("the native Info Bar control",
		(Candidate) => _LLM_Menu_ToggleCandidateBool(Candidate, "show_info_bar"),
		_LMT_Apply, _LMT_Writer, _LMT_Notify, _LMT_Acquire, _LMT_Settle, _LMT_InfoBarCollect)
}

_LMT_InfoBarCallback(Built, Position := 0) {
	global _MenuDispatchCallbacks
	Id := DllCall("GetMenuItemID", "ptr", Built.Handle, "int", Position, "uint")
	Assert(_MenuDispatchCallbacks.Has(Id), "the shared check uses the real native dispatcher")
	return _MenuDispatchCallbacks[Id]
}

_LMT_SharedInfoBarNativeOwner() {
	global _LLM_Menu, _LLM_Engine, ConfigurationFile, LLM_MENU_INDENT_OPTIONS, _LMT_WriterResult
	global _LMT_WriterCalls, _LMT_ApplyCalls
	Previous := _LMT_InstallFixture()
	PreviousEngine := _LLM_Engine
	PreviousSuspend := A_IsSuspended
	Suspend(false)
	Path := _LMT_InfoBarPrivatePath()
	ConfigurationFile := Path
	HadIndent := IsSet(LLM_MENU_INDENT_OPTIONS)
	PreviousIndent := HadIndent ? LLM_MENU_INDENT_OPTIONS : 0
	; The unit graph omits _index.ahk; provide its independent accepted range
	; for the unrelated remaining provider without changing its production owner.
	LLM_MENU_INDENT_OPTIONS := [-7, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7]
	try {
		Corpus := _LMT_InfoBarCorpus()
		AssertEqual(2, Corpus["states"].Length)
		for Selected in Corpus["states"] {
			_LLM_Menu["show_info_bar"] := Selected
			_LMT_InfoBarAdmitFixture(Path, Selected)
			_LMT_WriterCalls := 0
			_LMT_ApplyCalls := 0
			Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle)
			try {
				AssertEqual(t(Corpus["row"]["i18n"]), _CTC_LabelAt(Built, 0))
				AssertEqual(Selected, _CTC_IsChecked(Built, 0))
				Callback := _LMT_InfoBarCallback(Built)
				AssertTrue(Callback.Call())
				AssertEqual(!Selected, _LLM_Menu["show_info_bar"])
				AssertEqual(1, _LMT_WriterCalls)
				AssertEqual(1, _LMT_ApplyCalls)
			} finally _CTC_ReleaseMenu(Built)
		}
		Definitions := _MR_GetManifestRoot()["llm_display_menu"]
		SavedDefinitions := Definitions.Clone()
		InfoRow := Definitions[2]
		OriginalLabel := InfoRow["i18n"]
		try {
			InfoRow["i18n"] := Corpus["alternate_i18n"]
			Definitions.RemoveAt(2)
			Definitions.Push(InfoRow)
			_LLM_Menu["show_info_bar"] := true
			_LMT_InfoBarAdmitFixture(Path, true)
			_LMT_WriterResult := false
			_LMT_WriterCalls := 0
			_LMT_ApplyCalls := 0
			Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle)
			try {
				Position := DllCall("GetMenuItemCount", "ptr", Built.Handle, "int") - 1
				Assert(Position > 0, "the native remaining provider precedes the moved check")
				AssertEqual(t(Corpus["alternate_i18n"]), _CTC_LabelAt(Built, Position))
				Callback := _LMT_InfoBarCallback(Built, Position)
				AssertFalse(Callback.Call())
				AssertTrue(_LLM_Menu["show_info_bar"])
				AssertEqual(1, _LMT_WriterCalls)
				AssertEqual(0, _LMT_ApplyCalls)
			} finally _CTC_ReleaseMenu(Built)
		} finally {
			InfoRow["i18n"] := OriginalLabel
			for Index, Row in SavedDefinitions
				Definitions[Index] := Row
		}
	} finally {
		if HadIndent
			LLM_MENU_INDENT_OPTIONS := PreviousIndent
		else
			LLM_MENU_INDENT_OPTIONS := unset
		Suspend(PreviousSuspend)
		_LLM_Engine := PreviousEngine
		if FileExist(Path)
			FileDelete(Path)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM display: shared Info Bar state and labels retain the native transaction owner", _LMT_SharedInfoBarNativeOwner)





; =====================================================
; =====================================================
; ======= 3/ Shared Automatic Temperature Check =======
; =====================================================
; =====================================================

_LMT_AutoTemperatureCorpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\auto_raise_temperature.json"))
}

_LMT_AutoTemperatureValues(*) {
	return [Map("label", t("menu.llm.temperature_label"), "disabled", true)]
}

_LMT_AutoTemperatureCollect(CandidateFeatures, CandidateMenu) {
	return [{ Section: "llm.generation", Key: "auto_raise_temp", Value: CandidateMenu["auto_raise_temp"] }]
}

_LMT_AutoTemperatureToggle(*) {
	return LLM_Menu_CommitMutation("the native automatic temperature control",
		(Candidate) => _LLM_Menu_ToggleCandidateBool(Candidate, "auto_raise_temp"),
		_LMT_Apply, _LMT_Writer, _LMT_Notify, _LMT_Acquire, _LMT_Settle, _LMT_AutoTemperatureCollect)
}

_LMT_SharedAutoTemperatureOwner() {
	global _LLM_Menu, _LMT_WriterResult, _LMT_WriterCalls, _LMT_ApplyCalls
	Previous := _LMT_InstallFixture()
	try {
		Corpus := _LMT_AutoTemperatureCorpus()
		AssertEqual(2, Corpus["states"].Length)
		AssertEqual(2, Corpus["prediction_counts"].Length)
		for Selected in Corpus["states"] {
			for Count in Corpus["prediction_counts"] {
				_LLM_Menu["auto_raise_temp"] := Selected
				_LLM_Menu["n_predictions"] := Count
				_LMT_WriterCalls := 0
				_LMT_ApplyCalls := 0
				Built := LLM_Menu_BuildGenerationMenu(_LMT_AutoTemperatureToggle, _LMT_AutoTemperatureValues)
				try {
					AssertEqual(t(Corpus["row"]["i18n"]), _CTC_LabelAt(Built, 1))
					AssertEqual(Selected, _CTC_IsChecked(Built, 1))
					State := DllCall("GetMenuState", "ptr", Built.Handle, "uint", 1, "uint", 0x400, "uint")
					Assert(State != 0xFFFFFFFF, "the actual native check must exist")
					AssertEqual(Count < 2, !!(State & 0x3))
					Callback := _LMT_InfoBarCallback(Built, 1)
					AssertEqual(Count >= 2, Callback.Call())
					AssertEqual(Count >= 2 ? !Selected : Selected, _LLM_Menu["auto_raise_temp"])
					AssertEqual(Count >= 2 ? 1 : 0, _LMT_WriterCalls)
					AssertEqual(Count >= 2 ? 1 : 0, _LMT_ApplyCalls)
				} finally _CTC_ReleaseMenu(Built)
			}
		}
		_LLM_Menu["auto_raise_temp"] := true
		_LLM_Menu["n_predictions"] := 2
		_LMT_WriterCalls := 0
		_LMT_ApplyCalls := 0
		Built := LLM_Menu_BuildGenerationMenu(_LMT_AutoTemperatureToggle, _LMT_AutoTemperatureValues)
		try {
			Callback := _LMT_InfoBarCallback(Built, 1)
			_LLM_Menu["n_predictions"] := 1
			AssertFalse(Callback.Call(), "a delayed command rereads the actual prediction-count owner")
			AssertTrue(_LLM_Menu["auto_raise_temp"])
			AssertEqual(0, _LMT_WriterCalls)
			AssertEqual(0, _LMT_ApplyCalls)
		} finally _CTC_ReleaseMenu(Built)
		Definitions := _MR_GetManifestRoot()["llm_generation_menu"]
		SavedDefinitions := Definitions.Clone()
		CheckRow := Definitions[2]
		OriginalLabel := CheckRow["i18n"]
		try {
			CheckRow["i18n"] := Corpus["alternate_i18n"]
			Definitions[1] := SavedDefinitions[2]
			Definitions[2] := SavedDefinitions[1]
			_LLM_Menu["n_predictions"] := 2
			_LLM_Menu["auto_raise_temp"] := true
			_LMT_WriterResult := false
			_LMT_WriterCalls := 0
			_LMT_ApplyCalls := 0
			Built := LLM_Menu_BuildGenerationMenu(_LMT_AutoTemperatureToggle, _LMT_AutoTemperatureValues)
			try {
				AssertEqual(t(Corpus["alternate_i18n"]), _CTC_LabelAt(Built, 0))
				AssertEqual(t("menu.llm.temperature_label"), _CTC_LabelAt(Built, 1))
				Callback := _LMT_InfoBarCallback(Built)
				AssertFalse(Callback.Call())
				AssertTrue(_LLM_Menu["auto_raise_temp"])
				AssertEqual(1, _LMT_WriterCalls)
				AssertEqual(0, _LMT_ApplyCalls)
			} finally _CTC_ReleaseMenu(Built)
		} finally {
			CheckRow["i18n"] := OriginalLabel
			for Index, Row in SavedDefinitions
				Definitions[Index] := Row
		}
	} finally _LMT_RestoreFixture(Previous)
}
Test("LLM generation: shared temperature diversity retains native receipts and current count", _LMT_SharedAutoTemperatureOwner)





; ======================================
; ======================================
; ======= 4/ Show-All Projection =======
; ======================================
; ======================================

_LMT_ShowAllCorpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\show_all_control.json"))
}

_LMT_ShowAllCollect(CandidateFeatures, CandidateMenu) {
	return [{ Section: "llm.display", Key: "streaming_multi",
		Value: CandidateFeatures["llm"]["display"]["streaming_multi"] }]
}

_LMT_ShowAllToggle(Writer := 0, *) {
	if !IsObject(Writer)
		Writer := _LMT_Writer
	return LLM_Menu_CommitMutation("the native Show-all control",
		(Candidate) => _LLM_Menu_ToggleCandidateBool(Candidate, "show_all_at_once"),
		_LMT_Apply, Writer, _LMT_Notify, _LMT_Acquire, _LMT_Settle, _LMT_ShowAllCollect)
}

_LMT_ShowAllThrowWriter(Path, Updates) {
	global _LMT_WriterCalls
	_LMT_WriterCalls += 1
	throw Error("The owned Show-all writer refused.")
}

_LMT_ShowAllPosition(Built, Label) {
	Count := DllCall("GetMenuItemCount", "ptr", Built.Handle, "int")
	Loop Count {
		Position := A_Index - 1
		if _CTC_LabelAt(Built, Position) == Label
			return Position
	}
	throw Error("The actual display menu omitted the shared Show-all check.")
}

_LMT_SharedShowAllNativeOwner() {
	global _LLM_Menu, Features, _LMT_WriterResult, _LMT_WriterCalls, _LMT_ApplyCalls
	Previous := _LMT_InstallFixture()
	try {
		_LLM_Menu["enabled"] := true
		Features["llm"]["enabled"] := true
		Corpus := _LMT_ShowAllCorpus()
		AssertEqual(2, Corpus["states"].Length)
		for Expected in Corpus["states"] {
			for Count in Corpus["prediction_counts"] {
				_LLM_Menu["show_all_at_once"] := Expected["show_all"]
				_LLM_Menu["n_predictions"] := Count
				Features["llm"]["display"]["streaming_multi"] := Expected["progressive"]
				Features["llm"]["profiles"]["num_predictions"] := Count
				_LMT_WriterCalls := 0
				_LMT_ApplyCalls := 0
				Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle)
				try {
					Position := _LMT_ShowAllPosition(Built, t(Corpus["row"]["i18n"]))
					AssertEqual(Expected["show_all"], _CTC_IsChecked(Built, Position))
					Flags := DllCall("GetMenuState", "ptr", Built.Handle, "uint", Position, "uint", 0x400, "uint")
					Assert(Flags != 0xFFFFFFFF)
					AssertEqual(Count < 2, !!(Flags & 0x3))
					Callback := _LMT_InfoBarCallback(Built, Position)
					AssertEqual(Count >= 2, Callback.Call())
					AssertEqual(Count >= 2 ? !Expected["show_all"] : Expected["show_all"], _LLM_Menu["show_all_at_once"])
					if Count >= 2
						AssertEqual(!Expected["progressive"], Features["llm"]["display"]["streaming_multi"])
					AssertEqual(Count >= 2 ? 1 : 0, _LMT_WriterCalls)
					AssertEqual(Count >= 2 ? 1 : 0, _LMT_ApplyCalls)
				} finally _CTC_ReleaseMenu(Built)
			}
		}
		_LLM_Menu["n_predictions"] := 2
		_LLM_Menu["show_all_at_once"] := false
		Features["llm"]["display"]["streaming_multi"] := true
		Features["llm"]["profiles"]["num_predictions"] := 2
		_LMT_WriterCalls := 0
		Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle)
		try {
			Callback := _LMT_InfoBarCallback(Built, _LMT_ShowAllPosition(Built, t(Corpus["row"]["i18n"])))
			_LLM_Menu["n_predictions"] := 1
			AssertFalse(Callback.Call(), "a delayed click cannot own a withdrawn second slot")
			AssertFalse(_LLM_Menu["show_all_at_once"])
			AssertEqual(0, _LMT_WriterCalls)
		} finally _CTC_ReleaseMenu(Built)
		_LLM_Menu["n_predictions"] := 2
		SavedSuspend := A_IsSuspended
		Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle)
		try {
			Callback := _LMT_InfoBarCallback(Built, _LMT_ShowAllPosition(Built, t(Corpus["row"]["i18n"])))
			Suspend(true)
			AssertFalse(Callback.Call(), "a held command cannot publish across a native pause")
			AssertEqual(0, _LMT_WriterCalls)
			AssertFalse(_LLM_Menu["show_all_at_once"])
		} finally {
			Suspend(SavedSuspend)
			_CTC_ReleaseMenu(Built)
		}
		for Refusal in [false, "", Map()] {
			_LMT_WriterResult := Refusal
			_LMT_WriterCalls := 0
			_LMT_ApplyCalls := 0
			Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle)
			try {
				Position := _LMT_ShowAllPosition(Built, t(Corpus["row"]["i18n"]))
				AssertFalse(_LMT_InfoBarCallback(Built, Position).Call())
				AssertFalse(_LLM_Menu["show_all_at_once"])
				AssertEqual(1, _LMT_WriterCalls)
				AssertEqual(0, _LMT_ApplyCalls)
			} finally _CTC_ReleaseMenu(Built)
		}
		_LMT_WriterCalls := 0
		_LMT_ApplyCalls := 0
		Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle.Bind(_LMT_ShowAllThrowWriter))
		try {
			Position := _LMT_ShowAllPosition(Built, t(Corpus["row"]["i18n"]))
			AssertFalse(_LMT_InfoBarCallback(Built, Position).Call())
			AssertFalse(_LLM_Menu["show_all_at_once"])
			AssertEqual(1, _LMT_WriterCalls)
			AssertEqual(0, _LMT_ApplyCalls)
		} finally _CTC_ReleaseMenu(Built)
		Definitions := _MR_GetManifestRoot()["llm_display_menu"]
		SavedDefinitions := Definitions.Clone()
		CheckIndex := 0
		for Index, Definition in Definitions {
			if Definition.Get("id", "") == "llm_show_all" {
				CheckIndex := Index
				break
			}
		}
		Assert(CheckIndex > 0, "the shared Show-all declaration must exist before its placement mutation")
		CheckRow := Definitions[CheckIndex]
		OriginalLabel := CheckRow["i18n"]
		try {
			CheckRow["i18n"] := Corpus["alternate_i18n"]
			Definitions.RemoveAt(CheckIndex)
			Definitions.InsertAt(1, CheckRow)
			_LLM_Menu["n_predictions"] := 2
			_LMT_WriterResult := false
			_LMT_WriterCalls := 0
			_LMT_ApplyCalls := 0
			Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle)
			try {
				AssertEqual(t(Corpus["alternate_i18n"]), _CTC_LabelAt(Built, 0))
				AssertFalse(_LMT_InfoBarCallback(Built).Call())
				AssertFalse(_LLM_Menu["show_all_at_once"])
				AssertEqual(1, _LMT_WriterCalls)
				AssertEqual(0, _LMT_ApplyCalls)
			} finally _CTC_ReleaseMenu(Built)
		} finally {
			CheckRow["i18n"] := OriginalLabel
			for Index, Row in SavedDefinitions
				Definitions[Index] := Row
		}
	} finally _LMT_RestoreFixture(Previous)
}
Test("LLM display: shared Show-all checks keep the native receipt and canonical polarity",
	_LMT_SharedShowAllNativeOwner)

/** Captures the real dispatcher's retry without starting an ambient timer. */
_LMT_ShowAllArmRetry(State, Callback, DelayMs) {
	State["timers"].Push(Map("callback", Callback, "delay", DelayMs))
	return true
}

_LMT_ShowAllRetryBusy(State) {
	return State["busy"]
}

_LMT_ShowAllSetMaster(Value) {
	return LLM_Menu_CommitMutation("the Show-all fixture master",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate, "enabled", Value),
		_LMT_Apply, _LMT_Writer, _LMT_Notify, _LMT_Acquire, _LMT_Settle, _LMT_Collect)
}

_LMT_ShowAllMasterRevokesHeldAndDeferred() {
	global _LLM_Menu, Features, _LMT_WriterCalls, _LMT_ApplyCalls
	global MENU_COMMAND_DEFERRAL_RETRY_MS, _MenuStartupCommands
	Previous := _LMT_InstallFixture()
	SavedSuspend := A_IsSuspended
	SavedStartupCommands := _MenuStartupCommands
	try {
		Suspend(false)
		_MenuStartupCommands := 0
		_LLM_Menu["enabled"] := true
		Features["llm"]["enabled"] := true
		_LLM_Menu["n_predictions"] := 2
		Features["llm"]["profiles"]["num_predictions"] := 2
		_LLM_Menu["show_all_at_once"] := false
		Features["llm"]["display"]["streaming_multi"] := true
		for Deferred in [false, true] {
			AssertTrue(_LMT_ShowAllSetMaster(true))
			Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle)
			try {
				Callback := _LMT_InfoBarCallback(Built,
					_LMT_ShowAllPosition(Built, t(_LMT_ShowAllCorpus()["row"]["i18n"])))
				State := Map("busy", true, "timers", [])
				if Deferred {
					Writes := _LMT_WriterCalls
					AssertEqual("", MenuCommandRun(Callback, [], 0,
						_LMT_ShowAllRetryBusy.Bind(State), _LMT_ShowAllArmRetry.Bind(State)))
					AssertEqual(Writes, _LMT_WriterCalls)
					AssertEqual(1, State["timers"].Length)
					AssertEqual(MENU_COMMAND_DEFERRAL_RETRY_MS, State["timers"][1]["delay"])
				}
				AssertTrue(_LMT_ShowAllSetMaster(false), "the real master owner acknowledges withdrawal")
				AssertFalse(_LLM_Menu["enabled"])
				AssertFalse(Features["llm"]["enabled"])
				_LMT_WriterCalls := 0
				_LMT_ApplyCalls := 0
				if Deferred {
					State["busy"] := false
					State["timers"][1]["callback"].Call()
					AssertEqual(1, State["timers"].Length, "no competing retry is armed after the lease releases")
				} else {
					AssertFalse(Callback.Call(), "a retained native callback refuses the disabled master")
				}
				AssertEqual(0, _LMT_WriterCalls, "held and dispatcher-deferred delivery publish no display setting")
				AssertEqual(0, _LMT_ApplyCalls)
				AssertFalse(_LLM_Menu["show_all_at_once"])
				AssertTrue(Features["llm"]["display"]["streaming_multi"])
			} finally _CTC_ReleaseMenu(Built)
		}
	} finally {
		Suspend(SavedSuspend)
		_MenuStartupCommands := SavedStartupCommands
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM display: master withdrawal fences held and real dispatcher-deferred Show-all commands",
	_LMT_ShowAllMasterRevokesHeldAndDeferred)

_LMT_ShowAllCanonicalBoundaries() {
	global _LLM_Menu, Features, LLM_Defaults, _LLM_Engine
	Previous := _LMT_InstallFixture()
	SavedDefaults := LLM_Defaults
	SavedEngine := _LLM_Engine
	try {
		for Expected in _LMT_ShowAllCorpus()["states"] {
			LLM_Defaults := Map("llm_streaming_multi", Expected["progressive"])
			_LLM_Engine := SavedEngine.Clone()
			LLM_Engine_ApplySharedDefaults()
			AssertEqual(Expected["show_all"], _LLM_Engine["show_all_at_once"],
				"the real engine default loader projects canonical progressive display")
			Features["llm"]["display"]["streaming_multi"] := Expected["progressive"]
			Opts := LLM_Menu_BuildSavedOpts()
			AssertEqual(Expected["show_all"], Opts["show_all_at_once"],
				"both raw stored polarities load without rewriting historical bytes")
			_LLM_Menu["show_all_at_once"] := Expected["show_all"]
			AssertTrue(_LLM_Menu_SyncToFeatures())
			AssertEqual(Expected["progressive"], Features["llm"]["display"]["streaming_multi"],
				"the acknowledged writer receives canonical progressive display")
		}
	} finally {
		LLM_Defaults := SavedDefaults
		_LLM_Engine := SavedEngine
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM display: shared defaults and saved values invert only at native boundaries",
	_LMT_ShowAllCanonicalBoundaries)






; =====================================
; =====================================
; ======= 8/ Automatic Triggers =======
; =====================================
; =====================================

_LMT_TriggerCorpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\automatic_trigger_controls.json"))
}

_LMT_TriggerCollect(Key, CandidateFeatures, CandidateMenu) {
	return [{ Section: "llm.trigger", Key: Key, Value: CandidateFeatures["llm"]["trigger"][Key] }]
}

_LMT_TriggerToggle(Key, Writer := 0, *) {
	if !IsObject(Writer)
		Writer := _LMT_Writer
	return LLM_Menu_CommitMutation("the native trigger fixture",
		(Candidate) => _LLM_Menu_ToggleCandidateBool(Candidate, Key),
		_LMT_Apply, Writer, _LMT_Notify, _LMT_Acquire, _LMT_Settle,
		_LMT_TriggerCollect.Bind(Key))
}

_LMT_TriggerBuilder(Writer := 0) {
	return LLM_Menu_BuildTriggerMenu(_LMT_TriggerToggle.Bind("instant_on_word_end", Writer),
		_LMT_TriggerToggle.Bind("after_hotstring", Writer))
}

_LMT_SharedTriggerOwner() {
	global _LLM_Menu, Features, _LMT_WriterResult, _LMT_WriterCalls, _LMT_ApplyCalls
	Previous := _LMT_InstallFixture()
	SavedSuspend := A_IsSuspended
	try {
		Suspend(false)
		Corpus := _LMT_TriggerCorpus()
		AssertEqual(4, Corpus["states"].Length)
		_LLM_Menu["enabled"] := true
		Features["llm"]["enabled"] := true
		for States in Corpus["states"] {
			for Count in Corpus["prediction_counts"] {
				for Index, Expected in Corpus["rows"] {
					_LLM_Menu["instant_on_word_end"] := States[1]
					_LLM_Menu["after_hotstring"] := States[2]
					_LLM_Menu["n_predictions"] := Count
					Features["llm"]["trigger"]["instant_on_word_end"] := States[1]
					Features["llm"]["trigger"]["after_hotstring"] := States[2]
					Features["llm"]["profiles"]["num_predictions"] := Count
					_LMT_WriterCalls := 0
					_LMT_ApplyCalls := 0
					_LMT_WriterResult := 1
					Built := _LMT_TriggerBuilder()
					try {
						Position := _LMT_ShowAllPosition(Built, t(Expected["i18n"]))
						AssertEqual(States[Index], _CTC_IsChecked(Built, Position))
						AssertTrue(_LMT_InfoBarCallback(Built, Position).Call())
						AssertEqual(!States[Index], _LLM_Menu[Expected["native"]])
						AssertEqual(!States[Index], Features["llm"]["trigger"][Expected["native"]])
						Sibling := Index == 1 ? 2 : 1
						AssertEqual(States[Sibling], _LLM_Menu[Corpus["rows"][Sibling]["native"]])
						AssertEqual(States[Sibling], Features["llm"]["trigger"][Corpus["rows"][Sibling]["native"]])
						AssertEqual(1, _LMT_WriterCalls)
						AssertEqual(1, _LMT_ApplyCalls)
					} finally _CTC_ReleaseMenu(Built)
				}
			}
		}
		for Expected in Corpus["rows"] {
			_LMT_WriterResult := 1
			_LLM_Menu[Expected["native"]] := false
			Features["llm"]["trigger"][Expected["native"]] := false
			Built := _LMT_TriggerBuilder()
			try {
				Callback := _LMT_InfoBarCallback(Built, _LMT_ShowAllPosition(Built, t(Expected["i18n"])))
				AssertTrue(Callback.Call())
				_LLM_Menu["n_predictions"] := 1
				Features["llm"]["profiles"]["num_predictions"] := 1
				AssertTrue(Callback.Call(), "variant count does not own a trigger switch")
				AssertFalse(_LLM_Menu[Expected["native"]])
				Writes := _LMT_WriterCalls
				Suspend(true)
				AssertFalse(Callback.Call())
				Suspend(false)
				_LLM_Menu["enabled"] := false
				Features["llm"]["enabled"] := false
				AssertFalse(Callback.Call())
				AssertEqual(Writes, _LMT_WriterCalls)
				_LLM_Menu["enabled"] := true
				Features["llm"]["enabled"] := true
			} finally _CTC_ReleaseMenu(Built)
			for Refusal in [false, "", Map()] {
				_LMT_WriterResult := Refusal
				_LMT_WriterCalls := 0
				_LMT_ApplyCalls := 0
				Built := _LMT_TriggerBuilder()
				try {
					AssertFalse(_LMT_InfoBarCallback(Built, _LMT_ShowAllPosition(Built, t(Expected["i18n"]))).Call())
					AssertFalse(_LLM_Menu[Expected["native"]])
					AssertEqual(1, _LMT_WriterCalls)
					AssertEqual(0, _LMT_ApplyCalls)
				} finally _CTC_ReleaseMenu(Built)
			}
			Built := _LMT_TriggerBuilder(_LMT_ShowAllThrowWriter)
			try {
				AssertFalse(_LMT_InfoBarCallback(Built, _LMT_ShowAllPosition(Built, t(Expected["i18n"]))).Call())
				AssertFalse(_LLM_Menu[Expected["native"]])
			} finally _CTC_ReleaseMenu(Built)
		}
	} finally {
		Suspend(SavedSuspend)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM trigger: shared bool pairs preserve native lease refusal and live admission", _LMT_SharedTriggerOwner)

_LMT_SharedTriggerDeclaration() {
	global _LLM_Menu, Features, _LMT_WriterResult
	Previous := _LMT_InstallFixture()
	Definitions := _MR_GetManifestRoot()["llm_trigger_menu"]
	SavedDefinitions := Definitions.Clone()
	Row := Definitions[2]
	SavedLabel := Row["i18n"]
	try {
		_LLM_Menu["enabled"] := true
		Features["llm"]["enabled"] := true
		_LMT_WriterResult := false
		Row["i18n"] := _LMT_TriggerCorpus()["alternate_i18n"]
		Definitions.RemoveAt(2)
		Definitions.InsertAt(1, Row)
		Built := _LMT_TriggerBuilder()
		try {
			AssertEqual(t(Row["i18n"]), _CTC_LabelAt(Built, 0))
			AssertFalse(_LMT_InfoBarCallback(Built).Call())
		} finally _CTC_ReleaseMenu(Built)
	} finally {
		Row["i18n"] := SavedLabel
		for Index, Entry in SavedDefinitions
			Definitions[Index] := Entry
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM trigger: native command placement follows the shared label and order", _LMT_SharedTriggerDeclaration)





; =========================================
; =========================================
; ======= 6/ Shared Token Streaming =======
; =========================================
; =========================================

_LMT_StreamingCorpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\token_streaming_control.json"))
}

_LMT_StreamingPolicyContract() {
	Corpus := _LMT_StreamingCorpus()
	AssertEqual(9, Corpus["capabilities"].Length)
	AssertEqual(15, Corpus["cases"].Length)
	for Vector in Corpus["capabilities"] {
		AssertEqual(Vector["capable"], LLM_DisplayStreamingCapable(Vector["platform"], Vector["backend"]),
			"actual shared capability matches the independent native transport inventory")
	}
	for Vector in Corpus["cases"] {
		Expected := Corpus["base"].Clone()
		Current := Corpus["base"].Clone()
		for Key, Value in Vector.Get("expected", Map())
			Expected[Key] := Value
		for Key, Value in Vector["current"]
			Current[Key] := Value
		Decision := LLM_DisplayStreamingIntent(Expected, Current)
		AssertEqual(Vector["admitted"], Decision["admitted"], Vector["id"])
		if Vector["admitted"]
			AssertEqual(Vector["value"], Decision["value"], Vector["id"])
	}
}
Test("LLM display: shared token streaming replays independent capabilities and stale intents", _LMT_StreamingPolicyContract)

_LMT_StreamingNativeRefusal() {
	global _LLM_Menu, _LMT_WriterCalls, _LMT_ApplyCalls
	Previous := _LMT_InstallFixture()
	SavedSuspend := A_IsSuspended
	try {
		Corpus := _LMT_StreamingCorpus()
		Definitions := _MR_GetManifestRoot()["llm_display_menu"]
		StreamingRow := 0
		for Definition in Definitions {
			if Definition.Get("id", "") == Corpus["row"]["id"]
				StreamingRow := Definition
		}
		Assert(StreamingRow is Map, "the actual shared declaration must own the streaming row")
		AssertEqual("grey", StreamingRow["unavailable"])
		AssertEqual("platform_reason.token_streaming_transport_missing", StreamingRow["reason_key"])
		for Backend in ["ollama", "api", "mlx"] {
			_LLM_Menu["backend"] := Backend
			_LLM_Menu["enabled"] := true
			_LLM_Menu["streaming"] := true
			_LLM_Menu["show_all_at_once"] := false
			State := Map("calls", 0)
			Command := (*) => State["calls"] += 1
			Expected := _LLM_Menu_StreamingSnapshot()
			AssertFalse(LLM_BackendCapabilities(Backend)["streaming"], "Windows has no partial-frame transport")
			AssertFalse(_LLM_Menu_StreamingCommand(Expected, Command), "an unsupported click cannot reach a writer")
			Suspend(true)
			AssertFalse(_LLM_Menu_StreamingCommand(Expected, Command), "a retained click remains refused under native pause")
			Suspend(SavedSuspend)
			_LLM_Menu := _LLM_Menu.Clone()
			AssertFalse(_LLM_Menu_StreamingCommand(Expected, Command), "an old row cannot claim a replacement map owner")
			AssertEqual(0, State["calls"])
			AssertEqual(0, _LMT_WriterCalls)
			AssertEqual(0, _LMT_ApplyCalls)
			AssertTrue(_LLM_Menu["streaming"], "unavailable native rendering does not strip historical stored intent")
			Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle, Command)
			try {
				Count := DllCall("GetMenuItemCount", "ptr", Built.Handle, "int")
				Matches := 0
				Loop Count {
					Position := A_Index - 1
					Label := _CTC_LabelAt(Built, Position)
					if InStr(Label, t(Corpus["row"]["i18n"])) == 1 {
						Matches += 1
						Assert(Label != t(Corpus["row"]["i18n"]), "the disabled native row explains why it cannot stream")
						AssertContains(Label, "Windows")
						NativeState := DllCall("GetMenuState", "ptr", Built.Handle, "uint", Position, "uint", 0x400, "uint")
						Assert(NativeState & 0x3, "the real Win32 row is greyed")
						AssertFalse(_CTC_IsChecked(Built, Position), "a buffered transport never reports effective token streaming")
					}
				}
				AssertEqual(1, Matches, "the native menu projects exactly one shared streaming declaration")
			} finally _CTC_ReleaseMenu(Built)
		}
	} finally {
		Suspend(SavedSuspend)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM display: the real Windows streaming row remains truthful and cannot reach a writer", _LMT_StreamingNativeRefusal)


_LMT_StreamingCountCommand(State) {
	State["calls"] += 1
	return true
}

_LMT_StreamingSparseOwnerRefusal() {
	global _LLM_Menu, _LLM_Engine, _LMT_WriterCalls, _LMT_ApplyCalls
	Previous := _LMT_InstallFixture()
	SavedSuspend := A_IsSuspended
	HadEngine := IsSet(_LLM_Engine)
	SavedEngine := HadEngine ? _LLM_Engine : 0
	try {
		Suspend(false)
		_LLM_Menu["backend"] := "ollama"
		_LLM_Menu["enabled"] := true
		_LLM_Menu["streaming"] := true
		_LLM_Menu["show_all_at_once"] := false
		_LLM_Menu["future_streaming_neighbor"] := "preserve"
		Owners := [Map("id", "unset"), Map("id", "non-map", "owner", 0),
			Map("id", "empty", "owner", Map()),
			Map("id", "retired debounce", "owner", Map("timer_active", false)),
			Map("id", "missing enabled", "owner", Map("backend", "ollama")),
			Map("id", "missing backend", "owner", Map("enabled", true))]
		for Vector in Owners {
			if Vector.Has("owner")
				_LLM_Engine := Vector["owner"]
			else
				_LLM_Engine := unset
			Failure := ""
			Snapshot := 0
			try {
				Snapshot := _LLM_Menu_StreamingSnapshot()
			} catch as Err {
				Failure := Err.Message
			}
			AssertEqual("", Failure, Vector["id"] . ": a missing runtime owner is a refusal, never an exception")
			Assert(Snapshot is Map, Vector["id"] . ": the real owner returns an admission snapshot")
			AssertTrue(Snapshot["blocked"], Vector["id"] . ": incomplete engine state is unavailable")
			AssertFalse(LLM_DisplayStreamingReady(Snapshot), Vector["id"] . ": unavailable state cannot enable a shared row")
			State := Map("calls", 0)
			Command := _LMT_StreamingCountCommand.Bind(State)
			AssertFalse(_LLM_Menu_StreamingCommand(Snapshot, Command), Vector["id"] . ": unavailable state cannot reach the setting owner")
			AssertEqual(0, State["calls"])
			Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle, Command)
			try {
				Matches := 0
				Loop DllCall("GetMenuItemCount", "ptr", Built.Handle, "int") {
					Position := A_Index - 1
					if InStr(_CTC_LabelAt(Built, Position), t("menu.llm.show_streaming")) == 1 {
						Matches += 1
						NativeState := DllCall("GetMenuState", "ptr", Built.Handle, "uint", Position, "uint", 0x400, "uint")
						Assert(NativeState & 0x3, Vector["id"] . ": the actual Win32 row remains disabled")
						AssertFalse(_CTC_IsChecked(Built, Position))
					}
				}
				AssertEqual(1, Matches, Vector["id"] . ": the shared declaration remains visible exactly once")
			} finally _CTC_ReleaseMenu(Built)
			AssertEqual(0, _LMT_WriterCalls)
			AssertEqual(0, _LMT_ApplyCalls)
			AssertTrue(_LLM_Menu["streaming"], "refusal preserves historical stored intent")
			AssertEqual("preserve", _LLM_Menu["future_streaming_neighbor"])
		}
	} finally {
		if HadEngine
			_LLM_Engine := SavedEngine
		else
			_LLM_Engine := unset
		Suspend(SavedSuspend)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM display: sparse or retired engine owners refuse streaming without writes or missing-key exceptions", _LMT_StreamingSparseOwnerRefusal)





; =========================================
; =========================================
; ======= Shared Indentation Choice =======
; =========================================
; =========================================

_LMT_IndentCorpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\indentation_control.json"))
}

; The production writer still owns its lease/source fence; only the terminal
; native write is injected for refusal cases, like the other setting fixtures.
_LMT_IndentCommit(Value, Expected, WriterFn := 0, Seen := 0) {
	if !(Seen is Map)
		return LLM_Menu_CommitMutation("the native indentation regression",
			(Candidate) => _LLM_Menu_SetCandidateValue(Candidate, "pred_indent", Value),
			_LMT_Apply, (Path, Updates) => _LLM_Menu_IndentWrite(Expected, Path, Updates, WriterFn),
			_LMT_Notify, _LMT_Acquire, _LMT_Settle)
	return LLM_Menu_CommitMutation("the native indentation regression",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate, "pred_indent", Value),
		_LMT_Apply, _LMT_IndentObserveWrite.Bind(Seen, Expected, WriterFn),
		_LMT_IndentObserveNotify.Bind(Seen), _LMT_Acquire, _LMT_Settle,
		_LMT_IndentObserveCollect.Bind(Seen))
}

_LMT_IndentObservedCommit(WriterFn, Seen, Value, Expected) {
	return _LMT_IndentCommit(Value, Expected, WriterFn, Seen)
}

; Observers delegate to the unchanged full collector and borrowed writer. Closed
; stage facts distinguish a pre-writer refusal without printing source or errors.
_LMT_IndentObserveCollect(Seen, CandidateFeatures, CandidateMenu) {
	Seen["collector_entered"] := true
	try {
		Updates := _ConfigCollectFullSaveUpdates(CandidateFeatures, CandidateMenu)
		Seen["collector_returned"] := true
		Seen["collector_array"] := Updates is Array
		return Updates
	} catch as Err {
		Seen["collector_threw"] := true
		throw Err
	}
}

_LMT_IndentObserveWrite(Seen, Expected, WriterFn, Path, Updates) {
	Seen["borrowed_writer_entered"] := true
	Current := _LLM_Menu_IndentSnapshot()
	Seen["snapshot_blocked"] := Current["blocked"]
	Seen["source_matches"] := _LLM_Menu_EnableSourceMatches(Expected["source"], Current["source"])
	Seen["intent_admitted"] := LLM_DisplayIndentIntent(Expected, Current,
		Expected["indentation"], LLM_MENU_INDENT_OPTIONS)["admitted"]
	Owned := 0
	for Update in Updates {
		if Update.Section == "llm.display" && Update.Key == "pred_indent"
			Owned += 1
	}
	Seen["single_owned_leaf"] := Owned == 1
	try {
		Result := _LLM_Menu_IndentWrite(Expected, Path, Updates, WriterFn)
		Seen["borrowed_writer_returned"] := true
		Seen["borrowed_writer_ack"] := (Result is Integer) && Result == 1
		return Result
	} catch as Err {
		Seen["borrowed_writer_threw"] := true
		throw Err
	}
}

_LMT_IndentObserveNotify(Seen, Message, Options) {
	Seen["notified"] := true
	return _LMT_Notify(Message, Options)
}

; Values outside the fixed Boolean observation contract are never interpolated.
_LMT_IndentObservation(Seen) {
	Summary := ""
	for Field in ["collector_entered", "collector_returned", "collector_array", "collector_threw",
			"borrowed_writer_entered", "snapshot_blocked", "source_matches", "intent_admitted",
			"single_owned_leaf", "borrowed_writer_returned", "borrowed_writer_ack",
			"borrowed_writer_threw", "notified"] {
		Value := Seen.Get(Field, "")
		Summary .= (Summary == "" ? "" : ";") . Field . "="
			. ((Value is Integer) && (Value == 0 || Value == 1) ? Value : "unobserved")
	}
	return Summary
}

_LMT_IndentChild(Built) {
	Prefix := t("menu.llm.indent_label")
	Count := DllCall("GetMenuItemCount", "ptr", Built.Handle, "int")
	Loop Count {
		Position := A_Index - 1
		if InStr(_CTC_LabelAt(Built, Position), Prefix) == 1 {
			Handle := _MCR_SubMenuAt(Built, Position)
			AssertEqual(15, DllCall("GetMenuItemCount", "ptr", Handle, "int"))
			return {Handle: Handle, Position: Position}
		}
	}
	throw Error("The actual native indentation submenu is absent.")
}

_LMT_IndentWriteMode(Mode, Seen, Path, Updates) {
	return _LMT_IndentWriteObserved(Path, Updates, Mode, Seen)
}

_LMT_IndentWriteObserved(Path, Updates, Mode, Seen) {
	Seen["calls"] += 1
	Seen["updates"] := LLM_Menu_DeepClone(Updates)
	if Mode == "throw"
		throw Error("native indentation writer refused")
	if Mode == "nil"
		return ""
	if Mode == "false"
		return false
	if Mode == "truthy integer"
		return 2
	if Mode == "truthy string"
		return "ack"
	return TOML_BatchWrite(Path, Updates)
}

; Uses the actual Win32 menu, native dispatcher, configuration lease and strict
; TOML writer. Private file ownership is retired in finally, even on assertions.
_LMT_IndentNativeOwners() {
	global ConfigurationFile, _LLM_Menu, _LLM_Engine, _LMT_ApplyCalls, _MenuDispatchCallbacks
	Previous := _LMT_InstallFixture()
	PreviousEngine := _LLM_Engine
	SavedSuspend := A_IsSuspended
	Path := A_Temp . "\ergopti-indent-choice-" . DllCall("GetCurrentProcessId", "uint") . "-" . A_TickCount . ".toml"
	AssertFalse(FileExist(Path), "this fixture must acquire a new private path")
	ConfigurationFile := Path
	try {
		Corpus := _LMT_IndentCorpus()
		AssertEqual(15, Corpus["choices"].Length)
		for Mode in ["false", "nil", "throw", "truthy integer", "truthy string", "ack"] {
			for Position in [0, 7, 14] {
				_LLM_Menu := _LMT_Menu()
				_LLM_Menu["enabled"] := true
				_LLM_Menu["n_predictions"] := 3
				_LLM_Menu["pred_indent"] := 1
				_LLM_Menu["show_all_at_once"] := false
				_LLM_Engine := LLM_Menu_DeepClone(_LLM_Menu)
				Initial := '[llm]`nenabled = true`n[llm.models]`nselected = "ollama"`n'
					. "[llm.profiles]`nnum_predictions = 3`n[llm.display]`npred_indent = 1`nstreaming_multi = true`n"
					. "[llm.generation]`ntemperature = 0.9`n[private]`nfuture = 42`n"
				if FileExist(Path)
					FileDelete(Path)
				FileAppend(Initial, Path, "UTF-8-RAW")
				Seen := Map("calls", 0)
				Writer := _LMT_IndentWriteMode.Bind(Mode, Seen)
				Command := _LMT_IndentObservedCommit.Bind(Writer, Seen)
				Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle, (*) => false, Command)
				try {
					Child := _LMT_IndentChild(Built)
					State := DllCall("GetMenuState", "ptr", Built.Handle, "uint", Child.Position, "uint", 0x400, "uint")
					Assert(State != 0xFFFFFFFF, "the actual native indentation row must exist")
					AssertEqual(0, State & 0x3, "an admitted indentation row is enabled")
					for Index, Choice in Corpus["choices"] {
						AssertEqual(Choice["prefix"] . t(Choice["i18n"]), _CTC_LabelAt(Child, Index - 1))
						AssertEqual(Choice["value"] == 1, _CTC_IsChecked(Child, Index - 1))
					}
					Id := DllCall("GetMenuItemID", "ptr", Child.Handle, "int", Position, "uint")
					Assert(_MenuDispatchCallbacks.Has(Id), "the actual native choice must own its dispatcher callback")
					Callback := _MenuDispatchCallbacks[Id]
					_LMT_ApplyCalls := 0
					AssertEqual(Mode == "ack", Callback.Call())
					AssertEqual(1, Seen["calls"], "closed native stages: " . _LMT_IndentObservation(Seen))
					AssertEqual(1, Seen["updates"].Length, "the native choice may own only one leaf")
					AssertEqual("llm.display", Seen["updates"][1].Section)
					AssertEqual("pred_indent", Seen["updates"][1].Key)
					Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
					AssertEqual(42, Document["private"]["future"])
					AssertEqual(0.9, Document["llm"]["generation"]["temperature"], "one display leaf cannot overwrite a foreign temperature")
					Value := Corpus["choices"][Position + 1]["value"]
					if Mode == "ack" {
						AssertEqual(Value, _LLM_Menu["pred_indent"])
						Read := _TOML_DocumentLookup(Document, ["llm", "display", "pred_indent"])
						AssertEqual(Value, Read["found"] ? Read["value"] : ManifestDefaultFor("llm.display.pred_indent"))
						AssertEqual(1, _LMT_ApplyCalls)
						AssertFalse(Callback.Call(), "published menu identity retires the held choice")
						AssertEqual(1, Seen["calls"])
					} else {
						AssertEqual(1, _LLM_Menu["pred_indent"])
						AssertEqual(Initial, FSReadUtf8Exact(Path))
						AssertEqual(0, _LMT_ApplyCalls)
					}
				} finally _CTC_ReleaseMenu(Built)
			}
		}
	} finally {
		Suspend(SavedSuspend)
		_LLM_Engine := PreviousEngine
		if FileExist(Path)
			FileDelete(Path)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM display: actual native indentation choices retain source, strict ACK and numeric boundaries", _LMT_IndentNativeOwners)


_LMT_IndentPolicyCorpus() {
	Corpus := _LMT_IndentCorpus()
	Owner := Map()
	Other := Map()
	Values := [-7, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7]
	for Vector in Corpus["cases"] {
		Expected := LLM_Menu_DeepClone(Corpus["base"])
		Current := LLM_Menu_DeepClone(Corpus["base"])
		for Field, Value in Vector.Get("expected", Map())
			Expected[Field] := Value
		for Field, Value in Vector["current"]
			Current[Field] := Value
		Expected["owner"] := Expected["owner"] == "owned" ? Owner : Other
		Current["owner"] := Current["owner"] == "owned" ? Owner : Other
		Decision := LLM_DisplayIndentIntent(Expected, Current, Vector["value"], Values)
		AssertEqual(Vector["admitted"], Decision["admitted"], Vector["id"])
		if Vector["admitted"]
			AssertEqual(Vector["value"], Decision["value"], Vector["id"])
	}
}
Test("LLM display: shared indentation policy replays independent admission vectors", _LMT_IndentPolicyCorpus)

_LMT_IndentRetainedOwners() {
	global ConfigurationFile, _LLM_Menu, _LLM_Engine, _LMT_ApplyCalls, _MenuDispatchCallbacks
	Previous := _LMT_InstallFixture()
	PreviousEngine := _LLM_Engine
	SavedSuspend := A_IsSuspended
	Path := A_Temp . "\ergopti-indent-held-" . DllCall("GetCurrentProcessId", "uint") . "-" . A_TickCount . ".toml"
	AssertFalse(FileExist(Path), "this fixture must acquire a new private path")
	ConfigurationFile := Path
	try {
		for Condition in ["paused", "master", "count", "sparse runtime", "runtime mismatch", "source", "retired owner"] {
			_LLM_Menu := _LMT_Menu()
			_LLM_Menu["enabled"] := true
			_LLM_Menu["n_predictions"] := 3
			_LLM_Menu["pred_indent"] := 1
			_LLM_Menu["show_all_at_once"] := false
			_LLM_Engine := LLM_Menu_DeepClone(_LLM_Menu)
			Initial := '[llm]`nenabled = true`n[llm.models]`nselected = "ollama"`n'
				. "[llm.profiles]`nnum_predictions = 3`n[llm.display]`npred_indent = 1`nstreaming_multi = true`n"
				. "[llm.generation]`ntemperature = 0.9`n[private]`nfuture = 42`n"
			if FileExist(Path)
				FileDelete(Path)
			FileAppend(Initial, Path, "UTF-8-RAW")
			Seen := Map("calls", 0)
			Writer := (Target, Updates) => _LMT_IndentWriteObserved(Target, Updates, "ack", Seen)
			Command := (Value, Expected) => _LMT_IndentCommit(Value, Expected, Writer)
			Built := LLM_Menu_BuildDisplayMenu(_LMT_InfoBarToggle, _LMT_ShowAllToggle, (*) => false, Command)
			try {
				Child := _LMT_IndentChild(Built)
				Id := DllCall("GetMenuItemID", "ptr", Child.Handle, "int", 0, "uint")
				Assert(_MenuDispatchCallbacks.Has(Id))
				Callback := _MenuDispatchCallbacks[Id]
				if Condition == "paused"
					Suspend(true)
				if Condition == "master"
					_LLM_Menu["enabled"] := false
				if Condition == "count"
					_LLM_Menu["n_predictions"] := 1
				if Condition == "sparse runtime"
					_LLM_Engine := Map("timer_active", false)
				if Condition == "runtime mismatch"
					_LLM_Engine["pred_indent"] := 2
				if Condition == "source" {
					FileDelete(Path)
					FileAppend(StrReplace(Initial, "temperature = 0.9", "temperature = 0.8"), Path, "UTF-8-RAW")
				}
				if Condition == "retired owner"
					_LLM_Menu := LLM_Menu_DeepClone(_LLM_Menu)
				Physical := FSReadUtf8Exact(Path)
				_LMT_ApplyCalls := 0
				AssertFalse(Callback.Call(), Condition)
				AssertEqual(0, Seen["calls"], Condition . " refuses before the native writer")
				AssertEqual(0, _LMT_ApplyCalls, Condition)
				AssertEqual(Physical, FSReadUtf8Exact(Path), Condition . " preserves exact physical bytes")
			} finally {
				Suspend(SavedSuspend)
				_CTC_ReleaseMenu(Built)
			}
		}
	} finally {
		Suspend(SavedSuspend)
		_LLM_Engine := PreviousEngine
		if FileExist(Path)
			FileDelete(Path)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM display: held native indentation choices refuse withdrawn or stale owners before write", _LMT_IndentRetainedOwners)


_LMT_IndentCanonicalTypes() {
	global ConfigurationFile, _LLM_Menu, _LLM_Engine
	Previous := _LMT_InstallFixture()
	PreviousEngine := _LLM_Engine
	SavedSuspend := A_IsSuspended
	Path := A_Temp . "\ergopti-indent-types-" . DllCall("GetCurrentProcessId", "uint") . "-" . A_TickCount . ".toml"
	AssertFalse(FileExist(Path))
	ConfigurationFile := Path
	try {
		Suspend(false)
		_LLM_Menu["enabled"] := true
		_LLM_Menu["n_predictions"] := 3
		_LLM_Menu["pred_indent"] := 1
		_LLM_Menu["show_all_at_once"] := false
		_LLM_Engine := LLM_Menu_DeepClone(_LLM_Menu)
		Initial := '[llm]`nenabled = true`n[llm.models]`nselected = "ollama"`n'
			. "[llm.profiles]`nnum_predictions = 3`n[llm.display]`npred_indent = 1`nstreaming_multi = true`n"
		for Vector in [
			Map("before", "enabled = true", "after", "enabled = 1", "admitted", false),
			Map("before", "streaming_multi = true", "after", "streaming_multi = 1", "admitted", false),
			Map("before", "num_predictions = 3", "after", 'num_predictions = "3"', "admitted", false),
			Map("before", "pred_indent = 1", "after", 'pred_indent = "1"', "admitted", false),
			Map("before", "pred_indent = 1", "after", "pred_indent = 1.0", "admitted", true)] {
			Physical := StrReplace(Initial, Vector["before"], Vector["after"])
			Assert(Physical != Initial, "each canonical type vector must change the real source")
			if FileExist(Path)
				FileDelete(Path)
			FileAppend(Physical, Path, "UTF-8-RAW")
			Snapshot := _LLM_Menu_IndentSnapshot()
			AssertEqual(Vector["admitted"], LLM_DisplayIndentReady(Snapshot), Vector["after"])
			AssertEqual(Physical, FSReadUtf8Exact(Path), "admission observation never changes source bytes")
		}
	} finally {
		Suspend(SavedSuspend)
		_LLM_Engine := PreviousEngine
		if FileExist(Path)
			FileDelete(Path)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM display: native indentation source requires real scalar types without numeric string coercion", _LMT_IndentCanonicalTypes)


_LMT_IndentObservationIsClosed() {
	Seen := Map("collector_entered", true, "source_matches", false,
		"collector_threw", "private-error-marker", "unknown_future_stage", "private-future-marker")
	Summary := _LMT_IndentObservation(Seen)
	Assert(InStr(Summary, "collector_entered=1") > 0)
	Assert(InStr(Summary, "source_matches=0") > 0)
	Assert(InStr(Summary, "collector_threw=unobserved") > 0)
	AssertFalse(InStr(Summary, "private-error-marker"))
	AssertFalse(InStr(Summary, "private-future-marker"))
	AssertFalse(InStr(Summary, "unknown_future_stage"))
}
Test("LLM display: indentation owner diagnostics retain only closed stage facts", _LMT_IndentObservationIsClosed)


; The full collector serializes stored profiles, not just scalar menu choices.
; Its fixture must satisfy the same required fields as the actual boot owner.
_LMT_FullCollectorOwnsCompleteProfile() {
	global Features, _LLM_Menu
	Previous := _LMT_InstallFixture()
	try {
		Profiles := _LLM_Menu["user_profiles"]
		AssertEqual(1, Profiles.Length)
		AssertTrue(Profiles[1].Has("system_multi"),
			"the common transaction fixture must carry every stored profile prompt")
		AssertEqual("", Profiles[1]["system_multi"])
		Payload := _LLM_Menu_SerializeUserProfiles(Profiles)
		AssertTrue(Payload is String,
			"the actual stored-profile owner must accept the common fixture")
		Parsed := _LLM_Menu_DeserializeUserProfiles(Payload)
		AssertTrue(Parsed is Array,
			"the actual stored-profile decoder must admit the encoded fixture")
		AssertEqual("user_one", Parsed[1]["id"])
		AssertEqual("Live label", Parsed[1]["label"])
		AssertEqual("Live prompt", Parsed[1]["system_single"])
		AssertEqual("", Parsed[1]["system_multi"])
		AssertEqual(false, Parsed[1]["batch"])

		Updates := _ConfigCollectFullSaveUpdates(Features, _LLM_Menu)
		AssertTrue(Updates is Array,
			"the actual full collector must reach its returned update image")
		Found := 0
		for Update in Updates {
			if Update.Section == "llm" && Update.Key == "user_profiles" {
				Found += 1
				AssertEqual(Payload, Update.Value)
			}
		}
		AssertEqual(1, Found,
			"one actual full-save update owns the complete stored profile payload")

		Incomplete := LLM_Menu_DeepClone(_LLM_Menu)
		Incomplete["user_profiles"][1].Delete("system_multi")
		AssertFalse(_LLM_Menu_SerializeUserProfiles(Incomplete["user_profiles"]),
			"an incomplete profile must still be refused by its actual owner")
		AssertFalse(_LLM_Menu_AppendPersistedUpdates([], Incomplete))
		Refused := false
		try _ConfigCollectFullSaveUpdates(Features, Incomplete)
		catch {
			Refused := true
		}
		AssertTrue(Refused,
			"the actual full collector must retain its incomplete-profile refusal")
		AssertTrue(_LLM_Menu["user_profiles"][1].Has("system_multi"))
		AssertEqual(Payload, _LLM_Menu_SerializeUserProfiles(_LLM_Menu["user_profiles"]),
			"the negative detached candidate must not mutate the live fixture")
	} finally _LMT_RestoreFixture(Previous)
}
Test("LLM transaction: actual full collector requires a complete stored profile",
	_LMT_FullCollectorOwnsCompleteProfile)

_LMT_InfoBarPrivatePath() {
	Path := A_Temp . "\ergopti-info-bar-" . DllCall("GetCurrentProcessId", "uint") . "-" . A_TickCount . ".toml"
	AssertFalse(FileExist(Path), "this test must acquire an absent private source")
	return Path
}

_LMT_InfoBarAdmitFixture(Path, Selected) {
	global _LLM_Menu, _LLM_Engine
	_LLM_Menu["enabled"] := true
	_LLM_Menu["n_predictions"] := 1
	_LLM_Engine := LLM_Menu_DeepClone(_LLM_Menu)
	Initial := '[llm]`nenabled = true`n[llm.models]`nselected = "ollama"`n[llm.display]`nshow_info_bar = '
		. (Selected ? "true" : "false") . '`n[llm.generation]`ntemperature = 0.9`n[private]`nfuture = 42`n'
	if FileExist(Path)
		FileDelete(Path)
	FileAppend(Initial, Path, "UTF-8-RAW")
	return Initial
}

_LMT_InfoBarLeaseWrite(Expected, Writer, Path, Updates) {
	return _LLM_Menu_InfoBarWrite(Expected, Path, Updates, Writer)
}

_LMT_InfoBarCommit(Writer, Value, Expected) {
	return LLM_Menu_CommitMutation("the actual retained Info Bar owner",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate, "show_info_bar", Value),
		_LMT_Apply, _LMT_InfoBarLeaseWrite.Bind(Expected, Writer), _LMT_Notify,
		_LMT_Acquire, _LMT_Settle, _LMT_InfoBarCollect)
}

_LMT_InfoBarWriter(Mode, Seen, Path, Updates, Content, Presence) {
	Seen["calls"] += 1
	Seen["updates"] := LLM_Menu_DeepClone(Updates)
	if Mode == "throw"
		throw Error("Info Bar writer refused")
	if Mode == "nil"
		return ""
	if Mode == "false"
		return false
	if Mode == "source race" {
		Foreign := StrReplace(Content, "temperature = 0.9", "temperature = 0.8")
		Seen["source_race_changed"] := Foreign != Content
		Assert(Foreign != Content, "the terminal port must create an actual different valid source")
		FileDelete(Path)
		FileAppend(Foreign, Path, "UTF-8-RAW")
	}
	return _TOML_BatchWriteImpl(Path, Updates, [], "write", Content, Presence)
}

_LMT_InfoBarRetainedReceipts() {
	global ConfigurationFile, _LLM_Menu, _LLM_Engine, _LMT_ApplyCalls
	Previous := _LMT_InstallFixture()
	PreviousEngine := _LLM_Engine
	PreviousSuspend := A_IsSuspended
	Path := _LMT_InfoBarPrivatePath()
	ConfigurationFile := Path
	try {
		for Condition in ["ack", "false", "nil", "throw", "source race", "paused", "master", "source", "runtime", "sparse", "retired"] {
			_LLM_Menu := _LMT_Menu()
			Initial := _LMT_InfoBarAdmitFixture(Path, true)
			Seen := Map("calls", 0)
			Mode := Condition == "false" || Condition == "nil" || Condition == "throw" || Condition == "source race" ? Condition : "ack"
			Command := _LMT_InfoBarCommit.Bind(_LMT_InfoBarWriter.Bind(Mode, Seen))
			Built := LLM_Menu_BuildDisplayMenu(Command)
			try {
				Callback := _LMT_InfoBarCallback(Built)
				if Condition == "paused"
					Suspend(true)
				if Condition == "master"
					_LLM_Menu["enabled"] := false
				if Condition == "source" {
					FileDelete(Path)
					FileAppend(StrReplace(Initial, "temperature = 0.9", "temperature = 0.8"), Path, "UTF-8-RAW")
				}
				if Condition == "runtime"
					_LLM_Engine["show_info_bar"] := false
				if Condition == "sparse"
					_LLM_Engine := Map("timer_active", false)
				if Condition == "retired"
					_LLM_Menu := LLM_Menu_DeepClone(_LLM_Menu)
				Before := FSReadUtf8Exact(Path)
				_LMT_ApplyCalls := 0
				AssertEqual(Condition == "ack", Callback.Call(), Condition)
				if Condition == "source race"
					AssertEqual(true, Seen.Get("source_race_changed", false), "the actual terminal port must change the source outside the production-caught callback")
				AssertEqual(Condition == "ack" || Condition == "false" || Condition == "nil" || Condition == "throw" || Condition == "source race" ? 1 : 0, Seen["calls"], Condition)
				AssertEqual(Condition == "ack" ? 1 : 0, _LMT_ApplyCalls, Condition)
				if Condition == "ack" {
					AssertEqual(1, Seen["updates"].Length)
					AssertEqual("llm.display", Seen["updates"][1].Section)
					AssertEqual("show_info_bar", Seen["updates"][1].Key)
					AssertFalse(_LLM_Menu["show_info_bar"])
					Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
					AssertEqual(42, Document["private"]["future"])
					AssertEqual(0.9, Document["llm"]["generation"]["temperature"])
					AssertFalse(Callback.Call(), "the acknowledged publication retires its old menu identity")
					AssertEqual(1, Seen["calls"])
				} else {
					AssertTrue(_LLM_Menu["show_info_bar"])
					AssertEqual(Condition == "source race" ? StrReplace(Before, "temperature = 0.9", "temperature = 0.8") : Before,
						FSReadUtf8Exact(Path), "refusal preserves exact foreign bytes")
				}
			} finally {
				Suspend(PreviousSuspend)
				_CTC_ReleaseMenu(Built)
			}
		}
	} finally {
		Suspend(PreviousSuspend)
		_LLM_Engine := PreviousEngine
		if FileExist(Path)
			FileDelete(Path)
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM display: real Info Bar commands require retained source and strict leased publication", _LMT_InfoBarRetainedReceipts)

_LMT_InfoBarPolicyCorpus() {
	Corpus := _LMT_InfoBarCorpus()
	Owner := Map()
	Other := Map()
	AssertEqual(15, Corpus["cases"].Length)
	for Vector in Corpus["cases"] {
		Expected := LLM_Menu_DeepClone(Corpus["base"])
		Current := LLM_Menu_DeepClone(Corpus["base"])
		for Field, Value in Vector.Get("expected", Map())
			Expected[Field] := Value
		for Field, Value in Vector["current"]
			Current[Field] := Value
		Expected["owner"] := Expected["owner"] == "owned" ? Owner : Other
		Current["owner"] := Current["owner"] == "owned" ? Owner : Other
		Decision := LLM_DisplayInfoBarIntent(Expected, Current)
		AssertEqual(Vector["admitted"], Decision["admitted"], Vector["id"])
		if Vector["admitted"]
			AssertEqual(Vector["value"], Decision["value"], Vector["id"])
	}
}
Test("LLM display: Info Bar owner policy replays independent source admission vectors", _LMT_InfoBarPolicyCorpus)



/** Reads independently authored privacy states and native identities. */
_LMT_PrivacyCorpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\privacy_trigger_controls.json"))
}

_LMT_PrivacyFixture(States, Body) {
	global _LLM_Menu, _LLM_Engine, Features, ConfigurationFile
	PreviousEngine := _LLM_Engine
	Previous := _LMT_InstallFixture()
	SavedSuspend := A_IsSuspended
	Dir := A_Temp . "\ergopti_privacy_" . A_TickCount . "_" . Random(10000, 99999)
	DirCreate(Dir)
	try {
		Suspend(false)
		ConfigurationFile := Dir . "\config.toml"
		_LLM_Menu["enabled"] := true
		Features["llm"]["enabled"] := true
		_LLM_Menu["disable_url_bars"] := States[1]
		_LLM_Menu["disable_password_fields"] := States[2]
		Features["llm"]["trigger"]["url_bar_filter_enabled"] := States[1]
		Features["llm"]["trigger"]["secure_filter_enabled"] := States[2]
		_LLM_Engine := Map("enabled", true, "backend", "ollama",
			"disable_url_bars", States[1], "disable_password_fields", States[2])
		Image := "# independent native privacy fixture`n[llm]`nenabled = true`n[llm.models]`n"
			. 'selected = "ollama"' . "`n[llm.trigger]`nurl_bar_filter_enabled = "
			. (States[1] ? "true" : "false") . "`nsecure_filter_enabled = "
			. (States[2] ? "true" : "false") . "`n[foreign]`n"
			. 'future = "keep exact" # retained neighbour' . "`n"
		FileAppend(Image, ConfigurationFile, "UTF-8-RAW")
		Body.Call()
	} finally {
		Suspend(SavedSuspend)
		_LLM_Engine := PreviousEngine
		_LMT_RestoreFixture(Previous)
		DirDelete(Dir, true)
	}
}

_LMT_PrivacyPhysicalWrite(Expected, Path, Updates, Content, Presence) {
	global _LMT_WriterResult, _LMT_WriterCalls
	_LMT_WriterCalls += 1
	if _LMT_WriterResult is String && _LMT_WriterResult == "source race" {
		Foreign := StrReplace(Content, '"keep exact"', '"foreign preserved"')
		Expected["observation"]["source_race_changed"] := Foreign != Content
		FileDelete(Path)
		FileAppend(Foreign, Path, "UTF-8-RAW")
	} else if !((_LMT_WriterResult is Integer) && _LMT_WriterResult == 1) {
		return _LMT_WriterResult
	}
	return _TOML_BatchWriteImpl(Path, Updates, [], "write", Content, Presence)
}

_LMT_PrivacyLeaseWrite(Expected, Key, Path, Updates) {
	return _LLM_Menu_PrivacyWrite(Expected, Key, Path, Updates, _LMT_PrivacyPhysicalWrite.Bind(Expected))
}

_LMT_PrivacyApply(Candidate) {
	global _LLM_Engine
	_LLM_Engine["disable_url_bars"] := Candidate["disable_url_bars"]
	_LLM_Engine["disable_password_fields"] := Candidate["disable_password_fields"]
	return _LMT_Apply(Candidate)
}

_LMT_PrivacyCollect(Key, CandidateFeatures, CandidateMenu) {
	NativeKey := Key == "disable_url_bars" ? "url_bar_filter_enabled" : "secure_filter_enabled"
	Owned := ManifestValuesEqual(CandidateMenu[Key], ManifestDefaultFor("llm.trigger." . NativeKey))
		? {Section: "llm.trigger", Key: NativeKey, Delete: true}
		: {Section: "llm.trigger", Key: NativeKey, Value: TOML_Bool(CandidateMenu[Key])}
	return [Owned, {Section: "foreign", Key: "future", Value: "must not publish"}]
}

_LMT_PrivacyRequest(Observed, Key, Value, Expected) {
	Expected["observation"] := Observed
	return LLM_Menu_CommitMutation("the native privacy fixture",
		(Candidate) => _LLM_Menu_SetCandidateValue(Candidate, Key, Value),
		_LMT_PrivacyApply, _LMT_PrivacyLeaseWrite.Bind(Expected, Key), _LMT_Notify,
		_LMT_Acquire, _LMT_Settle, _LMT_PrivacyCollect.Bind(Key))
}

_LMT_PrivacyBuilder(Observed := 0) {
	Observed := Observed is Map ? Observed : Map()
	Command := _LMT_PrivacyRequest.Bind(Observed)
	return LLM_Menu_BuildTriggerMenu(_LMT_TriggerToggle.Bind("instant_on_word_end"),
		_LMT_TriggerToggle.Bind("after_hotstring"), Map("disable_url_bars", Command,
			"disable_password_fields", Command))
}

_LMT_PrivacyReplayBody(Expected, Selected, Neighbor, NeighborSelected) {
	global _LLM_Menu, _LLM_Engine, _LMT_WriterCalls, _LMT_ApplyCalls, ConfigurationFile
	Built := _LMT_PrivacyBuilder()
	try {
		Position := _LMT_ShowAllPosition(Built, t(Expected["i18n"]))
		AssertEqual(Selected, _CTC_IsChecked(Built, Position))
		Callback := _LMT_InfoBarCallback(Built, Position)
		AssertTrue(Callback.Call())
		AssertEqual(!Selected, _LLM_Menu[Expected["ahk"]])
		AssertEqual(!Selected, _LLM_Engine[Expected["ahk"]])
		AssertEqual(NeighborSelected, _LLM_Menu[Neighbor["ahk"]])
		Document := TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))
		Actual := _TOML_DocumentLookup(Document, StrSplit(Expected["path"], "."))
		if (!Selected) == Expected["neutral"] {
			AssertFalse(Actual["found"])
		} else {
			AssertTrue(Actual["value"] is TOML_Bool)
			AssertEqual(!Selected, Actual["value"].Value)
		}
		AssertContains(FSReadUtf8Exact(ConfigurationFile), 'future = "keep exact" # retained neighbour')
		AssertEqual(1, _LMT_WriterCalls)
		AssertEqual(1, _LMT_ApplyCalls)
		AssertFalse(Callback.Call())
		AssertEqual(1, _LMT_WriterCalls)
	} finally _CTC_ReleaseMenu(Built)
}

_LMT_SharedPrivacyReplay() {
	Corpus := _LMT_PrivacyCorpus()
	AssertEqual(4, Corpus["states"].Length)
	for States in Corpus["states"] {
		for Index, Expected in Corpus["rows"] {
			Other := Index == 1 ? 2 : 1
			_LMT_PrivacyFixture(States, _LMT_PrivacyReplayBody.Bind(Expected, States[Index], Corpus["rows"][Other], States[Other]))
		}
	}
}
Test("LLM privacy: shared independent bools publish through exact native source lease", _LMT_SharedPrivacyReplay)

_LMT_PrivacyRefusalBody(Expected, Condition) {
	global _LLM_Menu, _LLM_Engine, _LMT_WriterCalls, _LMT_ApplyCalls, _LMT_WriterResult, ConfigurationFile
	Observed := Map()
	Built := _LMT_PrivacyBuilder(Observed)
	try {
		Position := _LMT_ShowAllPosition(Built, t(Expected["i18n"]))
		Callback := _LMT_InfoBarCallback(Built, Position)
		Before := FSReadUtf8Exact(ConfigurationFile)
		if Condition == "paused"
			Suspend(true)
		if Condition == "master withdrawn" {
			_LLM_Menu["enabled"] := false
			_LLM_Engine["enabled"] := false
		}
		if Condition == "missing runtime" {
			_LLM_Engine := Map()
		}
		if Condition == "runtime disagreement"
			_LLM_Engine[Expected["ahk"]] := true
		if Condition == "foreign source" {
			FileAppend("# independently retained foreign edit`n", ConfigurationFile, "UTF-8-RAW")
			Before := FSReadUtf8Exact(ConfigurationFile)
		}
		if Condition == "writer refused"
			_LMT_WriterResult := false
		if Condition == "writer source race"
			_LMT_WriterResult := "source race"
		AssertFalse(Callback.Call())
		AssertEqual(false, _LLM_Menu[Expected["ahk"]])
		if Condition == "writer source race" {
			AssertTrue(Observed.Get("source_race_changed", false),
				"the actual terminal writer must create a real different source before canonical reading")
			AssertEqual(StrReplace(Before, '"keep exact"', '"foreign preserved"'), FSReadUtf8Exact(ConfigurationFile))
		} else {
			AssertEqual(Before, FSReadUtf8Exact(ConfigurationFile))
		}
		AssertEqual(Condition == "writer refused" || Condition == "writer source race" ? 1 : 0, _LMT_WriterCalls)
		AssertEqual(0, _LMT_ApplyCalls)
	} finally _CTC_ReleaseMenu(Built)
}

_LMT_SharedPrivacyRefusal() {
	for Expected in _LMT_PrivacyCorpus()["rows"] {
		for Condition in ["paused", "master withdrawn", "missing runtime", "runtime disagreement", "foreign source", "writer refused", "writer source race"]
			_LMT_PrivacyFixture([false, false], _LMT_PrivacyRefusalBody.Bind(Expected, Condition))
	}
}
Test("LLM privacy: retained callbacks refuse stale masters pause source runtime and native writer", _LMT_SharedPrivacyRefusal)


_LMT_SharedPrivacyPolicy() {
	Corpus := _LMT_PrivacyCorpus()
	for Vector in Corpus["vectors"] {
		Expected := Corpus["snapshot"].Clone()
		Expected["owner"] := Map()
		Current := Expected.Clone()
		for Key, Value in Vector.Get("current", Map())
			Current[Key] := Value
		for Key in Vector.Get("missing", [])
			Current.Delete(Key)
		if Vector.Get("new_owner", false)
			Current["owner"] := Map()
		Actual := LLM_TriggerPrivacyIntent(Expected, Current)
		AssertEqual(Vector["admitted"], Actual["admitted"], Vector["name"])
		if Vector.Has("value")
			AssertEqual(Vector["value"], Actual["value"], Vector["name"])
		else
			AssertFalse(Actual.Has("value"), Vector["name"])
	}
}
Test("LLM privacy: shared strict source intent rejects malformed booleans and identities", _LMT_SharedPrivacyPolicy)

_LMT_ProfileCreateCorpus() {
	global _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\profile_create_command.json"))
	Assert(Corpus is Map, "the independent profile command corpus must be readable")
	return Corpus
}

_LMT_ProfileCreatePaused(Seen) {
	return Seen["paused"]
}

_LMT_ProfileCreateOpen(Seen) {
	Seen["opens"] += 1
	return Seen["result"]
}

_LMT_SharedCreateProfileCommand() {
	Corpus := _LMT_ProfileCreateCorpus()
	Seen := Map("paused", 0, "opens", 0, "result", 1)
	Row := _LLM_Menu_CreateProfileRow(_LMT_ProfileCreateOpen.Bind(Seen),
		_LMT_ProfileCreatePaused.Bind(Seen))
	Assert(Row is Map, "the native profile owner must consume the declared row")
	AssertEqual(t(Corpus["i18n"]), Row["label"])
	AssertEqual(1, Row["action"].Call())
	AssertEqual(1, Seen["opens"])
	Seen["paused"] := 1
	AssertEqual(false, Row["action"].Call(), "a held callback rechecks the exact pause owner")
	AssertEqual(1, Seen["opens"])
	Seen["paused"] := 0
	Seen["result"] := 0
	AssertEqual(0, Row["action"].Call(), "native editor refusal must remain refusal")
	AssertEqual(2, Seen["opens"])
	for Unknown in ["0", "false", Map(), 2] {
		Seen["paused"] := Unknown
		AssertEqual(false, Row["action"].Call(), "unknown pause receipts cannot open an editor")
		AssertEqual(2, Seen["opens"])
	}
}
Test("LLM profiles: shared Create command keeps native pause and editor refusal", _LMT_SharedCreateProfileCommand)

_LMT_SharedCreateProfileLabelOwner() {
	global _MM_MANIFEST_ROOT_CACHE
	Corpus := _LMT_ProfileCreateCorpus()
	Root := _MM_GetManifestRoot()
	Assert(Root is Map, "the actual manifest must be loaded before mutation")
	Declaration := Root[Corpus["section"]][1]
	AssertEqual(Corpus["id"], Declaration["id"])
	AssertEqual(Corpus["ready"], Declaration["disabled_when"][1])
	SavedKey := Declaration["i18n"]
	try {
		Declaration["i18n"] := "button.cancel"
		Seen := Map("paused", 0, "opens", 0, "result", 1)
		Row := _LLM_Menu_CreateProfileRow(_LMT_ProfileCreateOpen.Bind(Seen),
			_LMT_ProfileCreatePaused.Bind(Seen))
		AssertEqual(t("button.cancel"), Row["label"], "the declaration alone owns the native label")
		AssertEqual(1, Row["action"].Call())
		AssertEqual(1, Seen["opens"])
	} finally Declaration["i18n"] := SavedKey
}
Test("LLM profiles: actual Create provider follows a changed shared label", _LMT_SharedCreateProfileLabelOwner)

_LMT_ProfileCloneCorpus() {
	global _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\profile_clone_command.json"))
	Assert(Corpus is Map, "the independent Clone command corpus must be readable")
	return Corpus
}

_LMT_SharedCloneProfileCommand() {
	Corpus := _LMT_ProfileCloneCorpus()
	Seen := Map("paused", 0, "opens", 0, "result", 1)
	Row := _LLM_Menu_CloneProfileRow(_LMT_ProfileCreateOpen.Bind(Seen),
		_LMT_ProfileCreatePaused.Bind(Seen))
	Assert(Row is Map, "the real native Clone row owner must consume its declaration")
	AssertEqual(t(Corpus["i18n"]), Row["label"])
	AssertEqual(1, Row["action"].Call())
	AssertEqual(1, Seen["opens"])
	Seen["paused"] := 1
	AssertEqual(false, Row["action"].Call(), "held Clone callbacks re-read the exact pause owner")
	AssertEqual(1, Seen["opens"])
	Seen["paused"] := 0
	Seen["result"] := 0
	AssertEqual(0, Row["action"].Call(), "transactional clone refusal stays refusal")
	AssertEqual(2, Seen["opens"])
	for Unknown in ["0", "false", Map(), 2] {
		Seen["paused"] := Unknown
		AssertEqual(false, Row["action"].Call(), "unknown pause receipts cannot reach the clone owner")
		AssertEqual(2, Seen["opens"])
	}
}
Test("LLM profiles: shared Clone command retains native pause and refusal", _LMT_SharedCloneProfileCommand)

_LMT_SharedCloneProfileLabelOwner() {
	Corpus := _LMT_ProfileCloneCorpus()
	Root := _MM_GetManifestRoot()
	Assert(Root is Map, "the actual manifest must be initialized before controlled mutation")
	Declaration := 0
	for Row in Root[Corpus["section"]] {
		if StrCompare(Row["id"], Corpus["id"], true) == 0
			Declaration := Row
	}
	Assert(Declaration is Map, "the native Clone declaration must be present")
	AssertEqual(Corpus["ready"], Declaration["disabled_when"][1])
	SavedKey := Declaration["i18n"]
	try {
		Declaration["i18n"] := "button.cancel"
		Seen := Map("paused", 0, "opens", 0, "result", 1)
		Row := _LLM_Menu_CloneProfileRow(_LMT_ProfileCreateOpen.Bind(Seen),
			_LMT_ProfileCreatePaused.Bind(Seen))
		AssertEqual(t("button.cancel"), Row["label"], "the actual shared declaration owns the native Clone label")
		AssertEqual(1, Row["action"].Call())
		AssertEqual(1, Seen["opens"])
	} finally Declaration["i18n"] := SavedKey
}
Test("LLM profiles: actual Clone row follows a changed shared declaration", _LMT_SharedCloneProfileLabelOwner)

_LMT_SharedApiActiveCommandRows() {
	global _LLM_Menu, _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\api_active_commands.json"))
	Assert(Corpus is Map, "the independent active API commands corpus must be readable")
	Root := _MM_GetManifestRoot()
	Assert(Root is Map, "the real shared menu must be present")
	Declarations := Root[Corpus["section"]]
	AssertEqual(2, Declarations.Length)
	SavedTestKey := Declarations[1]["i18n"]
	Previous := _LMT_InstallFixture()
	try {
		_LLM_Menu["api_entries"] := [_LMT_ApiEntry("active")]
		_LLM_Menu["api_entry_id"] := "active"
		Declarations[1]["i18n"] := "button.cancel"
		Rows := _LLM_Menu_ApiEntriesRows()
		AssertEqual(t("button.cancel"), Rows[Rows.Length - 2]["label"],
			"the actual provider reads the canonical Test caption")
		AssertEqual(t("menu.llm.api_edit_entry"), Rows[Rows.Length - 1]["label"],
			"the existing native Edit action stays immediately before removal")
		AssertEqual(t(Corpus["rows"][2]["i18n"]), Rows[Rows.Length]["label"])
		for Index, Expected in Corpus["rows"] {
			AssertEqual(Expected["id"], Declarations[Index]["id"])
			AssertEqual(Corpus["ready"], Declarations[Index]["disabled_when"][1])
		}
		HeldTest := Rows[Rows.Length - 2]["action"]
		HeldRemove := Rows[Rows.Length]["action"]
		_LLM_Menu["api_entry_id"] := ""
		AssertEqual(false, HeldTest.Call(), "a revoked active owner cannot acquire a test request")
		AssertEqual(false, HeldRemove.Call(), "a revoked active owner cannot open the removal dialog")
		AssertEqual(1, _LLM_Menu["api_entries"].Length)
	} finally {
		Declarations[1]["i18n"] := SavedTestKey
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM API: actual shared active commands preserve Edit and refuse revoked owners",
	_LMT_SharedApiActiveCommandRows)


_LMT_SharedNavigationDeclarationOwner() {
	global _LLM_Menu, _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\llm_navigation_rows.json"))
	Root := _MR_GetManifestRoot()
	SavedDefinitions := Root["llm_navigation_rows"]
	Previous := _LMT_InstallFixture()
	try {
		AssertEqual(2, SavedDefinitions.Length)
		for Index, Expected in Corpus["rows"] {
			AssertEqual(Expected["id"], SavedDefinitions[Index]["id"])
			AssertEqual(Expected["type"], SavedDefinitions[Index]["type"])
			AssertEqual(Expected["i18n"], SavedDefinitions[Index]["i18n"])
		}
		_LLM_Menu["nav_modifiers"] := ""
		_LLM_Menu["val_modifiers"] := ""
		for Vector in Corpus["prediction_ranges"] {
			_LLM_Menu["n_predictions"] := Vector["count"]
			Rows := _LLM_Menu_NavRows()
			AssertEqual(2, Rows.Length)
			AssertEqual(t("menu.llm.nav_label") . " — " . t("menu.llm.arrows_only"), Rows[1]["label"])
			AssertEqual(StrReplace(t("menu.llm.val_label"), "%s", Vector["range"]) . " — " . t("menu.llm.digits_only"), Rows[2]["label"])
			AssertEqual(Vector["disabled"], Rows[1]["disabled"])
			AssertEqual(Vector["disabled"], Rows[2]["disabled"])
			Assert(HasMethod(Rows[1]["action"], "Call"))
			Built := LLM_Menu_BuildNavMenu()
			try {
				AssertEqual(Rows[1]["label"], _CTC_LabelAt(Built, 0))
				AssertEqual(Rows[2]["label"], _CTC_LabelAt(Built, 1))
			} finally _CTC_ReleaseMenu(Built)
		}
		Changed := [SavedDefinitions[2].Clone(), SavedDefinitions[1].Clone()]
		Changed[1]["i18n"] := "button.cancel"
		Root["llm_navigation_rows"] := Changed
		Rows := _LLM_Menu_NavRows()
		AssertEqual(StrReplace(t("button.cancel"), "%s", "1-0") . " — " . t("menu.llm.digits_only"), Rows[1]["label"])
		AssertEqual(t("menu.llm.nav_label") . " — " . t("menu.llm.arrows_only"), Rows[2]["label"])
		Root["llm_navigation_rows"] := []
		AssertEqual(0, _LLM_Menu_NavRows().Length, "absence is never repaired by native fallback rows")
		Changed[1]["i18n"] := 2
		Root["llm_navigation_rows"] := Changed
		AssertEqual(1, _LLM_Menu_NavRows().Length)
	} finally {
		Root["llm_navigation_rows"] := SavedDefinitions
		_LMT_RestoreFixture(Previous)
	}
	AssertTrue(Root["llm_navigation_rows"] == SavedDefinitions, "the exact canonical cache identity is restored")
}
Test("LLM navigation: actual child declaration owns label order presence and native prompts", _LMT_SharedNavigationDeclarationOwner)


; Only the unrelated collector/JSON ports are controlled; configuration rendering
; and both WAL filesystem targets use their actual production implementations.
_LMT_ApiSemanticRows(CandidateFeatures, CandidateMenu) {
	return [
		{ Section: "llm", Key: "enabled", Value: TOML_Bool(CandidateMenu["enabled"]) },
		{ Section: "llm", Key: "api_entry_id", Value: CandidateMenu["api_entry_id"] }
	]
}
_LMT_ApiSemanticDetachedBuilder() {
	global ConfigurationFile, _PathsFile, _LLM_Menu, Features, _LMT_ApiPath
	global _LMT_ApplyCalls, _ConfigBootReadFailed, _ConfigBootRejectedOverrides
	global _ConfigBootOutdatedEntries, _ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots
	Previous := _LMT_InstallApiFixture()
	OldRead := _ConfigBootReadFailed, OldRejected := _ConfigBootRejectedOverrides
	OldOutdated := _ConfigBootOutdatedEntries
	Source := 'llm = {enabled = false, api_entry_id = "api_old", future = "retain"}`n[future]`nold = "retain" # user data`n'
	Expected := Chr(0xFEFF) . 'llm = {enabled = true, api_entry_id = "api_new", future = "retain"}`n[future]`nold = "retain" # user data`n'
	try {
		_ConfigBootReadFailed := false
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		AssertEqual(1, FSWrite(ConfigurationFile, Source))
		BeforeFeatures := Features
		BeforeMenu := _LLM_Menu
		Result := LLM_Menu_CommitApiEntriesMutation("the semantic API entry",
			_LMT_ApiMutate, _LMT_Apply, ConfigTransitionProductionPort(),
			_LMT_Notify, _LMT_Acquire, _LMT_Settle, _LMT_ApiSemanticRows,
			0, _LMT_ApiSerialize)
		AssertTrue((Result is Integer) && Result == 1, "the actual detached builder admits the complete inline source")
		AssertEqual(Expected, FSReadUtf8Exact(ConfigurationFile))
		AssertEqual('[{"Id":"api_new"}]', FSReadUtf8Exact(_LMT_ApiPath))
		AssertEqual("api_new", _LLM_Menu["api_entry_id"])
		AssertTrue(_LLM_Menu["enabled"])
		AssertEqual(1, _LMT_ApplyCalls)
		AssertFalse(BeforeMenu["enabled"], "publication cannot mutate the old detached menu authority")
		AssertFalse(BeforeFeatures["llm"]["enabled"], "publication cannot mutate the old feature authority")
		AssertFalse(FSStrictExists(ConfigTransitionWalPath(_PathsFile)) == 1)
		AssertFalse(_ConfigWriteTerminalIsActive())
		AssertFalse(ConfigWriteLeaseBusy())
		Cache := ParseConfigTomlFile(ConfigurationFile)
		AssertEqual("api_new", IniCacheGet(Cache, "llm", "api_entry_id"))
		AssertEqual("retain", IniCacheGet(Cache, "llm", "future"))
	} finally {
		_ConfigBootReadFailed := OldRead
		_ConfigBootRejectedOverrides := OldRejected
		_ConfigBootOutdatedEntries := OldOutdated
		for Store in [_ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots] {
			if Store.Has(ConfigurationFile)
				Store.Delete(ConfigurationFile)
		}
		_LMT_RestoreApiFixture(Previous)
	}
}
Test("LLM API entries: actual detached config builder preserves inline and future records (config-full-semantic-successor)",
	_LMT_ApiSemanticDetachedBuilder)

; Fixed headings use the real provider, declared row materializer, and Win32 menu.
_LMT_ProfileHeadingsNativeOwner() {
	global _LLM_Menu, _SharedDir, _LMT_WriterCalls, _LMT_ApplyCalls
	Root := _MR_GetManifestRoot()
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\profile_section_headings.json"))
	SavedBuiltin := Root["llm_profile_builtin_heading"]
	SavedCustom := Root["llm_profile_custom_heading"]
	Previous := _LMT_InstallFixture()
	try {
		for Section in ["llm_profile_builtin_heading", "llm_profile_custom_heading"] {
			Expected := Corpus["sections"][Section]
			AssertEqual(Expected.Length, Root[Section].Length)
			for Index, Row in Expected {
				for Key, Value in Row {
					if Value is Array {
						AssertEqual(Value.Length, Root[Section][Index][Key].Length)
						for Position, Platform in Value
							AssertEqual(Platform, Root[Section][Index][Key][Position])
					} else AssertEqual(Value, Root[Section][Index][Key])
				}
			}
		}
		Rows := _LLM_Menu_ProfileRows()
		AssertEqual(t("menu.profiles.header_default_profiles"), Rows[1]["label"])
		AssertTrue(Rows[1]["disabled"])
		AssertFalse(Rows[1].Has("action"))
		Built := LLM_Menu_BuildProfileMenu()
		try {
			AssertEqual(t("menu.profiles.header_default_profiles"), _CTC_LabelAt(Built, 0))
			State := DllCall("GetMenuState", "ptr", Built.Handle, "uint", 0, "uint", 0x400, "uint")
			AssertFalse(State == 0xFFFFFFFF, "the native heading state must be a real Win32 receipt")
			AssertTrue((State & 3) != 0)
			Position := _LMT_ShowAllPosition(Built, t("menu.profiles.header_custom_profiles"))
			AssertTrue(Position > 0)
			AssertTrue((DllCall("GetMenuState", "ptr", Built.Handle, "uint", Position - 1, "uint", 0x400, "uint") & 0x800) != 0)
			AssertTrue((DllCall("GetMenuState", "ptr", Built.Handle, "uint", Position, "uint", 0x400, "uint") & 3) != 0)
			AssertTrue(InStr(_CTC_LabelAt(Built, Position + 1), "Live label") == 1)
		} finally _CTC_ReleaseMenu(Built)
		Changed := []
		for Row in SavedCustom
			Changed.Push(Row.Clone())
		Changed[2]["i18n"] := "button.cancel"
		Separator := Changed[1]
		Changed[1] := Changed[2]
		Changed[2] := Separator
		Root["llm_profile_custom_heading"] := Changed
		Built := LLM_Menu_BuildProfileMenu()
		try {
			Position := _LMT_ShowAllPosition(Built, t("button.cancel"))
			AssertTrue((DllCall("GetMenuState", "ptr", Built.Handle, "uint", Position + 1, "uint", 0x400, "uint") & 0x800) != 0)
			AssertTrue(InStr(_CTC_LabelAt(Built, Position + 2), "Live label") == 1)
		} finally _CTC_ReleaseMenu(Built)
		AssertEqual(0, _LMT_WriterCalls)
		AssertEqual(0, _LMT_ApplyCalls)
	} finally {
		Root["llm_profile_builtin_heading"] := SavedBuiltin
		Root["llm_profile_custom_heading"] := SavedCustom
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM profile headings: real declared source order caption disabled states and native data", _LMT_ProfileHeadingsNativeOwner)

_LMT_ProfileHeadingsMissingDeclaration() {
	global _LLM_Menu, _LMT_WriterCalls, _LMT_ApplyCalls
	Root := _MR_GetManifestRoot()
	SavedBuiltin := Root["llm_profile_builtin_heading"]
	SavedCustom := Root["llm_profile_custom_heading"]
	Previous := _LMT_InstallFixture()
	try {
		OriginalLength := _LLM_Menu_ProfileRows().Length
		for Mode in ["missing", "empty", "invalid caption", "hidden platform"] {
			for Section, Original in Map("llm_profile_builtin_heading", SavedBuiltin, "llm_profile_custom_heading", SavedCustom) {
				if Mode == "missing" {
					Root.Delete(Section)
				} else if Mode == "empty" {
					Root[Section] := []
				} else {
					Changed := []
					for Row in Original {
						Copy := Row.Clone()
						if Mode == "invalid caption" && Copy.Has("i18n")
							Copy["i18n"] := 2
						if Mode == "hidden platform"
							Copy["platforms"] := ["hs"]
						Changed.Push(Copy)
					}
					Root[Section] := Changed
				}
			}
			Rows := _LLM_Menu_ProfileRows()
			AssertEqual(OriginalLength - 3, Rows.Length, Mode . " removes exactly the inert headings and their shared boundary")
			SawCustom := false
			for Row in Rows {
				if Row.Has("label") {
					AssertFalse(Row["label"] == t("menu.profiles.header_default_profiles"))
					AssertFalse(Row["label"] == t("menu.profiles.header_custom_profiles"))
					if InStr(Row["label"], "Live label") == 1 {
						SawCustom := true
						AssertTrue(HasMethod(Row["action"], "Call"))
					}
				}
			}
			AssertTrue(SawCustom, "native selectable profile data survives missing inert presentation")
		}
		AssertEqual(0, _LMT_WriterCalls)
		AssertEqual(0, _LMT_ApplyCalls)
	} finally {
		Root["llm_profile_builtin_heading"] := SavedBuiltin
		Root["llm_profile_custom_heading"] := SavedCustom
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM profile headings: actual provider refuses missing invalid or hidden shared presentation without fallback", _LMT_ProfileHeadingsMissingDeclaration)

_LMT_ProfileHeadingsEmptyRegistry() {
	global _LLM_Menu, _LMT_WriterCalls, _LMT_ApplyCalls
	Root := _MR_GetManifestRoot()
	SavedCustom := Root["llm_profile_custom_heading"]
	Previous := _LMT_InstallFixture()
	try {
		_LLM_Menu["user_profiles"] := []
		Before := _LLM_Menu_ProfileRows()
		Root["llm_profile_custom_heading"] := [Map("type", "label", "id", "empty_registry_probe", "i18n", "button.cancel")]
		After := _LLM_Menu_ProfileRows()
		AssertEqual(Before.Length, After.Length)
		for Index, Row in After {
			if Row.Has("label") {
				AssertEqual(Before[Index]["label"], Row["label"])
				AssertFalse(Row["label"] == t("menu.profiles.header_custom_profiles"))
				AssertFalse(Row["label"] == t("button.cancel"))
			}
		}
		AssertEqual(0, _LMT_WriterCalls)
		AssertEqual(0, _LMT_ApplyCalls)
	} finally {
		Root["llm_profile_custom_heading"] := SavedCustom
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM profile headings: empty native registry never materializes custom heading or boundary", _LMT_ProfileHeadingsEmptyRegistry)

; The two shared frame orders surround actual native profile data and callbacks.
_LMT_FrameAt(Rows, Label) {
	for Index, Row in Rows
		if Row.Has("label") && Row["label"] == Label
			return Index
	return 0
}
_LMT_ProfileFrameNativeOrder(Empty := false) {
	global _LLM_Menu, _SharedDir, LLM_PROFILE_BUILTIN_ORDER, _LMT_WriterCalls, _LMT_ApplyCalls
	Previous := _LMT_InstallFixture()
	Built := false
	try {
		_LLM_Menu["profile_id"] := Empty ? "user_one" : "basic"
		if Empty
			_LLM_Menu["user_profiles"] := []
		Rows := _LLM_Menu_ProfileRows()
		Assert(Rows is Array, "real native profile frame must materialize")
		AssertEqual(t("menu.profiles.header_default_profiles"), Rows[1]["label"])
		AssertTrue(Rows[1]["disabled"])
		AssertFalse(Rows[1].Has("action"))
		for Index, Id in LLM_PROFILE_BUILTIN_ORDER {
			Row := Rows[Index + 1]
			AssertTrue(InStr(Row["label"], LLM_Menu_GetProfileLabel(Id)) == 1, "unchanged native catalogue order and hint ownership")
			AssertEqual(Id == _LLM_Menu["profile_id"], Row["checked"])
			AssertTrue(HasMethod(Row["action"], "Call"))
		}
		Create := _LMT_FrameAt(Rows, t("menu.profiles.create_profile"))
		Clone := _LMT_FrameAt(Rows, t("menu.profiles.clone_builtin"))
		Auto := _LMT_FrameAt(Rows, t("menu.profiles.auto_detect"))
		Apps := _LMT_FrameAt(Rows, t("menu.profiles.per_app_overrides"))
		AssertTrue(Create > 1 && Auto > Create && Apps > Auto, "independent Windows Create/Clone then automatic-profile then per-app order")
		AssertTrue(Rows[Create - 1].Get("separator", false))
		AssertTrue(Rows[Auto - 1].Get("separator", false))
		AssertTrue(Rows[Apps - 1].Get("separator", false))
		AssertTrue(Rows[Apps]["items"] is Array && Rows[Apps]["items"].Length > 0, "actual native per-app child provider is retained")
		if Empty {
			AssertEqual(0, Clone, "custom active profile has no builtin clone")
			AssertEqual(0, _LMT_FrameAt(Rows, t("menu.profiles.header_custom_profiles")))
		} else {
			Custom := _LMT_FrameAt(Rows, t("menu.profiles.header_custom_profiles"))
			AssertEqual(LLM_PROFILE_BUILTIN_ORDER.Length + 3, Custom, "custom heading follows the complete native catalogue and its separator")
			AssertTrue(Rows[Custom - 1]["separator"])
			AssertTrue(InStr(Rows[Custom + 1]["label"], "Live label") == 1)
			AssertEqual(Create + 1, Clone, "Windows clone stays beside Create, without a Lua-only clone boundary")
		}
		AssertEqual(_LLM_Menu["auto_profile_for_model"], Rows[Auto]["checked"])
		Built := LLM_Menu_BuildProfileMenu()
		State := DllCall("GetMenuState", "ptr", Built.Handle, "uint", 0, "uint", 0x400, "uint")
		AssertTrue(State != 0xFFFFFFFF && (State & 3) != 0, "actual Win32 menu consumes the inert frame header")
		AssertTrue(_LMT_ShowAllPosition(Built, t("menu.profiles.per_app_overrides")) > 0)
		AssertEqual(0, _LMT_WriterCalls)
		AssertEqual(0, _LMT_ApplyCalls)
	} finally {
		if Built is Menu
			_CTC_ReleaseMenu(Built)
		_LMT_RestoreFixture(Previous)
	}
}
Test("complete profile frame: actual Windows custom-builtin frame and native menu", _LMT_ProfileFrameNativeOrder.Bind(false))
Test("complete profile frame: actual Windows empty registry and conditional clone", _LMT_ProfileFrameNativeOrder.Bind(true))

_LMT_ProfileFrameMutation(Mode) {
	global _LLM_Menu, _LMT_WriterCalls, _LMT_ApplyCalls
	Root := _MR_GetManifestRoot()
	Saved := Root["llm_profile_windows_frame"]
	Previous := _LMT_InstallFixture()
	try {
		_LLM_Menu["profile_id"] := "basic"
		Changed := []
		for Row in Saved
			Changed.Push(Row.Clone())
		Root["llm_profile_windows_frame"] := Changed
		if Mode == "order" {
			First := Changed[1]
			Changed[1] := Changed[5]
			Changed[5] := First
		} else if Mode == "missing"
			Root.Delete("llm_profile_windows_frame")
		else if Mode == "list"
			Changed[2]["id"] := "unowned_native_slot"
		else if Mode == "presence"
			Changed[3]["present_when"] := "unowned_presence"
		else if Mode == "selector"
			Changed[5]["row_id"] := "missing"
		Rows := _LLM_Menu_ProfileRows()
		if Mode == "order" {
			Assert(Rows is Array)
			AssertEqual(t("menu.profiles.create_profile"), Rows[1]["label"], "actual provider consumes shared frame ordering")
		} else
			AssertEqual(false, Rows, "missing policy/native binding cannot fabricate a valid frame")
		AssertEqual(0, _LMT_WriterCalls)
		AssertEqual(0, _LMT_ApplyCalls)
	} finally {
		Root["llm_profile_windows_frame"] := Saved
		_LMT_RestoreFixture(Previous)
	}
}
for Mode in ["order", "missing", "list", "presence", "selector"]
	Test("complete profile frame: actual source mutation " . Mode, _LMT_ProfileFrameMutation.Bind(Mode))

_LMT_ProfileFrameHeldDeclaration(Command) {
	global _LLM_Menu, _LMT_WriterCalls, _LMT_ApplyCalls
	Root := _MR_GetManifestRoot()
	Previous := _LMT_InstallFixture()
	Section := Command == "auto_detect" ? "llm_profile_auto_detect_control" : "llm_profile_commands"
	Saved := Root[Section]
	try {
		_LLM_Menu["profile_id"] := "basic"
		Rows := _LLM_Menu_ProfileRows()
		Label := Command == "auto_detect" ? "menu.profiles.auto_detect" : Command == "create" ? "menu.profiles.create_profile" : "menu.profiles.clone_builtin"
		Index := _LMT_FrameAt(Rows, t(Label))
		AssertTrue(Index > 0, "actual declared command must be retained before withdrawal")
		Root.Delete(Section)
		AssertEqual(false, Rows[Index]["action"].Call(), "retained action refuses a withdrawn canonical declaration before dialog or publication")
		AssertEqual(0, _LMT_WriterCalls)
		AssertEqual(0, _LMT_ApplyCalls)
	} finally {
		Root[Section] := Saved
		_LMT_RestoreFixture(Previous)
	}
}
for Command in ["create", "clone", "auto_detect"]
	Test("complete profile frame: held native owner declaration withdrawal " . Command, _LMT_ProfileFrameHeldDeclaration.Bind(Command))
