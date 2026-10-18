; tests/unit/modules/llm/menu/test_llm_menu_transactions.ahk

; ==============================================================================
; MODULE: LLM menu persistence transaction regression tests
; DESCRIPTION:
; Proves that scalar and nested menu mutations remain detached until one strict
; config.toml writer succeeds under the global terminal barrier. A refused or
; malformed writer may not leak aliases, run live application, or strand the
; caller's Critical state.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../../../support/llm_menu_fixture_state.ahk
global _LMT_WriterResult := 1
global _LMT_WriterCalls := 0
global _LMT_ApplyCalls := 0
global _LMT_WriterCritical := -1
global _LMT_ApplyCritical := -1
global _LMT_LiveAtWrite := ""
global _LMT_ConfigPath := ""
global _LMT_ApiPath := ""
global _LMT_ApiRefused := false
global _LMT_ApiFault := 0
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

_LMT_InstallFixture(SelectedPath := unset) {
	static Sequence := 0
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
	if IsSet(SelectedPath) {
		if !(SelectedPath is String) || InStr(SelectedPath, A_Temp . "\") != 1
				|| FSStrictExists(SelectedPath) != 0
			throw ValueError("The selected transaction fixture requires a fresh private configuration path.")
		_LMT_ConfigPath := SelectedPath
	} else
		_LMT_ConfigPath := A_Temp . "\ergopti_llm_menu_transaction_" . A_ScriptHwnd . "_" . ++Sequence . ".toml"
	ConfigurationFile := _LMT_ConfigPath
	AssertEqual("absent", ConfigMigrateBoot(ConfigurationFile)["status"], "the genuine native transaction fixture constructs strict fresh absence")
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





_LMT_ObservationLine(Lines, Line) {
	if InStr(Line, "[LLMObservation.")
		Lines.Push(Line)
}

_LMT_RealTransactionObservation() {
	global _LOGGER_TEST_SINK, _LOGGER_INFO_ENABLED, _LOGGER_FLUSH_ACTIVE
	global _LOGGER_FORCE_FLUSH_PENDING, _LOGGER_PENDING, _LOGGER_PENDING_ERRORS
	Saved := [_LOGGER_TEST_SINK, _LOGGER_INFO_ENABLED, _LOGGER_FLUSH_ACTIVE,
		_LOGGER_FORCE_FLUSH_PENDING, _LOGGER_PENDING, _LOGGER_PENDING_ERRORS]
	Previous := _LMT_InstallFixture()
	Lines := []
	try {
		_LOGGER_TEST_SINK := _LMT_ObservationLine.Bind(Lines)
		_LOGGER_INFO_ENABLED := true
		; Observe the real logger without admitting an external file append.
		_LOGGER_FLUSH_ACTIVE := true
		_LOGGER_PENDING := [], _LOGGER_PENDING_ERRORS := []
		AssertTrue(LLM_Menu_CommitMutation("private-observation-context-sentinel",
			_LMT_MutateNested, _LMT_Apply, _LMT_Writer, _LMT_Notify,
			_LMT_Acquire, _LMT_Settle, _LMT_Collect))
		Text := ""
		for Line in Lines
			Text .= Line "`n"
		for Stage in ["schema-admission", "bundle-admission", "pending-settlement",
			"candidate-clone", "candidate-collector", "durable-writer",
			"live-publication", "live-application", "mutation-return"] {
			AssertContains(Text, "[LLMObservation." Stage ".enter]")
			AssertContains(Text, "[LLMObservation." Stage ".returned]")
		}
		AssertContains(Text, "status=confirmed")
		AssertFalse(InStr(Text, "private-observation-context-sentinel"), "operation context must not enter observation metadata")
		AssertFalse(InStr(Text, "Candidate label"), "candidate content must not enter observation metadata")
		AssertFalse(InStr(Text, "Live prompt"), "prompt content must not enter observation metadata")
		AssertFalse(InStr(Text, "[SUCCESS]"), "observations never claim a successful operation from an unknown result")
	} finally {
		_LMT_RestoreFixture(Previous)
		_LOGGER_TEST_SINK := Saved[1], _LOGGER_INFO_ENABLED := Saved[2]
		_LOGGER_FLUSH_ACTIVE := Saved[3], _LOGGER_FORCE_FLUSH_PENDING := Saved[4]
		_LOGGER_PENDING := Saved[5], _LOGGER_PENDING_ERRORS := Saved[6]
	}
}
Test("LLM menu: actual transaction emits closed observation milestones (llm-transaction-observation)",
	_LMT_RealTransactionObservation)





_LMT_ObservationReentry() {
	static Retained := []
	Directory := A_Temp "\ergopti-toggle-observation-" A_ScriptHwnd "-" A_TickCount "-" Random(100000, 999999)
	AssertTrue(DllCall("Kernel32\CreateDirectoryW", "Str", Directory, "Ptr", 0, "Int"))
	State := {done: false, exit: -1, errors: "", output: ""}
	Done(ExitCode, Output, Errors) {
		State.done := true, State.exit := ExitCode, State.output := Output, State.errors := Errors
	}
	Task := 0, Quiesced := true
	try {
		Subject := ""
		for Name in ["LLM_Menu_OnToggle", "_LLM_Menu_ObservationBegin", "_LLM_Menu_ObservationEnd"] {
			Body := _DriverFuncBody(Name)
			AssertTrue(Body != "", "the observation reentry subject must be actual production code")
			Subject .= Body "`n"
		}
		Program := '
(
#Requires AutoHotkey v2.0
#Warn All, StdOut
#NoTrayIcon
#SingleInstance Off
global _LLM_Menu := Map("enabled", true, "backend", "ollama")
global Mode := "", Triggered := false, Nested := 1, Commits := 0, FlushCalls := 0
LoggerInfo(Tag, Message, Values*) {
 global Mode, Triggered, Nested
 if !Triggered && ((Mode == "enter" && Tag == "LLMObservation.toggle-entry.enter")
  || (Mode == "returned" && Tag == "LLMObservation.toggle-entry.returned"
   && Values.Length > 0 && Values[1] == "confirmed")) {
  Triggered := true
  Nested := LLM_Menu_OnToggle()
 }
}
_LoggerFlush(*) {
 global FlushCalls
 FlushCalls += 1
 return true
}
TickElapsed(Started) => (A_TickCount - Started) & 0xFFFFFFFF
LLM_EnableRequiresProbe(*) => false
LLM_Menu_RequestEnableAdmission(*) => false
LLM_Menu_CancelEnableAdmission() => true
_LLM_Menu_ToggleCandidateBool(*) => true
_LLM_Menu_ApplyToggleCommitted(*) => true
LLM_Menu_CommitMutation(*) {
 global Commits
 Commits += 1
 return true
}
SUBJECT
for SelectedMode in ["enter", "returned"] {
 Mode := SelectedMode, Triggered := false, Nested := 1, Commits := 0
 if !LLM_Menu_OnToggle() || !Triggered || Nested != 0 || Commits != 1
  ExitApp(1)
 if !LLM_Menu_OnToggle() || Commits != 2
  ExitApp(2)
}
if FlushCalls != 0
 ExitApp(3)
FileAppend("observation-reentry: enter and returned refused; next call admitted; informational events stay buffered", "*", "UTF-8-RAW")
ExitApp(0)
)'
		Script := Directory "\observer.ahk"
		AssertTrue(FSWriteCreateDurable(Script, StrReplace(Program, "SUBJECT", Subject)))
		Task := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut", Script], Done, , , 65536)
		Quiesced := false
		AssertTrue(Task.start())
		Started := A_TickCount
		while !State.done && TickElapsed(Started) < 5000
			Sleep(10)
		AssertTrue(State.done, "the exact inert observation child must exit naturally")
		AssertEqual(0, State.exit, State.output)
		AssertEqual("", State.errors)
		AssertContains(State.output, "observation-reentry: enter and returned refused; next call admitted")
	} finally {
		if IsObject(Task) {
			try Quiesced := Task.requestTerminate() == true
			catch
				Quiesced := false
		}
		if Quiesced
			DirDelete(Directory, true)
		else {
			Retained.Push({task: Task, directory: Directory, state: State})
			throw Error("The exact observation child retains retirement debt.")
		}
	}
}
Test("LLM menu: actual toggle refuses observer reentry until return and releases its guard (llm-observation-reentry)",
	_LMT_ObservationReentry)





; Genuine narrow defaults must preserve legal namespaces under their held lease.
_LMT_NarrowSemanticDefault(Kind) {
	global ConfigurationFile, _LLM_Menu, _LLM_Engine, LLM_MENU_INDENT_OPTIONS
	Path := _LMT_InfoBarPrivatePath()
	Previous := _LMT_InstallFixture(Path), PreviousEngine := _LLM_Engine
	Bundle := 0
	try {
		_LLM_Menu["enabled"] := true
		_LLM_Menu["n_predictions"] := 3
		_LLM_Menu["pred_indent"] := 1
		_LLM_Menu["show_all_at_once"] := false
		_LLM_Menu["show_info_bar"] := true
		_LLM_Menu["disable_url_bars"] := false
		_LLM_Menu["disable_password_fields"] := false
		_LLM_Engine := LLM_Menu_DeepClone(_LLM_Menu)
		Initial := _CMJFixtureCurrentSource('[llm]`nenabled = true`n[llm.models]`nselected = "ollama"`n'
			. '[llm.profiles]`nnum_predictions = 3`n[llm.display]`npred_indent = 1`nstreaming_multi = true`nshow_info_bar = true`n'
			. '[llm.trigger]`nurl_bar_filter_enabled = false`nsecure_filter_enabled = false`n[private]`nfuture = 42`n')
		Assert(FSWriteDurable(Path, Initial))
		Expected := Kind == "info" ? _LLM_Menu_InfoBarSnapshot()
			: Kind == "indent" ? _LLM_Menu_IndentSnapshot() : _LLM_Menu_PrivacySnapshot("disable_url_bars")
		AssertFalse(Expected["blocked"], "the actual canonical source admits this narrow default")
		Section := Kind == "privacy" ? "llm.trigger" : "llm.display"
		Key := Kind == "info" ? "show_info_bar" : Kind == "indent" ? "pred_indent" : "url_bar_filter_enabled"
		Value := Kind == "indent" ? 0 : TOML_Bool(Kind == "privacy")
		Updates := [{ Section: Section, Key: Key, Value: Value }]
		Bundle := _ConfigWriteTerminalTryAcquire([Path])
		Assert(Bundle is Object)
		Written := Kind == "info" ? _LLM_Menu_InfoBarWrite(Expected, Path, Updates)
			: Kind == "indent" ? _LLM_Menu_IndentWrite(Expected, Path, Updates)
			: _LLM_Menu_PrivacyWrite(Expected, "disable_url_bars", Path, Updates)
		AssertTrue(Written, "the actual narrow default must acknowledge semantic publication")
		Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertEqual(ConfigMigrateCurrentVersion(), Document["_meta"]["schema_version"])
		AssertEqual(42, Document["private"]["future"])
		AssertTrue(TOML_SameValue(Value, Document["llm"][Kind == "privacy" ? "trigger" : "display"][Key]))
		Assert(InStr(FSReadUtf8Exact(Path), "[private]`nfuture = 42`n"), "the foreign physical record remains byte-exact")
	} finally {
		try {
			if Bundle is Object
				Assert(_ConfigWriteTerminalRelease(Bundle))
		} finally {
			_LLM_Engine := PreviousEngine
			_LMT_RestoreFixture(Previous)
		}
	}
}
Test("LLM narrow semantic default: Info Bar preserves dotted schema and foreign bytes", _LMT_NarrowSemanticDefault.Bind("info"))
Test("LLM narrow semantic default: indentation preserves dotted schema and foreign bytes", _LMT_NarrowSemanticDefault.Bind("indent"))
Test("LLM narrow semantic default: privacy preserves dotted schema and foreign bytes", _LMT_NarrowSemanticDefault.Bind("privacy"))
