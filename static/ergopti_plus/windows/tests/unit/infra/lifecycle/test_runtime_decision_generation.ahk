; tests/unit/infra/lifecycle/test_runtime_decision_generation.ahk

; ==============================================================================
; MODULE: Runtime Decision Generation Tests
; DESCRIPTION:
; Exercises the engine-owned epoch that fences canonical tooltip decisions from
; live configuration publishers which do not rebuild the hotstring registry.
;
; ROOT CAUSE ENCODED:
; A visible decision used to retain only the registry generation. Toggling the
; repeat fallback or changing live delimiter sets leaves that registry intact,
; so old pixels could remain claimable even though the next completion key now
; had a different effect. Each durable publisher must advance one shared runtime
; epoch in the same memory transaction as its live state and the renderer must
; reject every decision stamped before that publication.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../../../ui/editors.ahk





; ===============================================
; ===============================================
; ======= 1/ Runtime publisher test seams =======
; ===============================================
; ===============================================

global _RDGE_RepeatWriterSnapshots := []
global _RDGE_DelimiterWriterSnapshots := []

_RDGE_SaveState() {
	global ConfigurationFile, Features, ScriptInformation
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed
	global HSE_RebuildInProgress, HSE_RegistryTransitionDepth
	global HSE_RepeatEnabled, HSE_RuntimeDecisionGeneration
	global _PrefixBuffer, _PrefixContentGeneration
	global _PrefixInputContextGeneration, _PrefixInputHook
	global _PrefixVisibleFireDecisions
	global _HotstringsOverridesPath, _HotstringsOverrides, _HotstringsTerminatorRecords
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Hotstrings := Features["hotstrings"]
	return {
		ConfigurationFile: ConfigurationFile,
		fixture: 0,
		MagicKey: ScriptInformation["MagicKey"],
		RepeatEnabled: HSE_RepeatEnabled,
		RepeatFeatureHad: Hotstrings.Has("repeat_key_enabled"),
		RepeatFeature: Hotstrings.Get("repeat_key_enabled", false),
		RuntimeGeneration: HSE_RuntimeDecisionGeneration,
		EngineBuffer: HSE_Buffer,
		StartBoundary: HSE_StartIsWordBoundary,
		Suppressed: HSE_Suppressed,
		RebuildInProgress: HSE_RebuildInProgress,
		TransitionDepth: HSE_RegistryTransitionDepth,
		PrefixBuffer: _PrefixBuffer,
		PrefixContentGeneration: _PrefixContentGeneration,
		PrefixInputContextGeneration: _PrefixInputContextGeneration,
		PrefixInputHook: _PrefixInputHook,
		VisibleDecisions: _PrefixVisibleFireDecisions,
		OverridesPath: _HotstringsOverridesPath,
		Overrides: _HotstringsOverrides,
		DelimiterOwner: _HotstringsTerminatorRecords,
		WordLive: HSE_WORD_TERMINATORS,
		ConsumedLive: HSE_CONSUMED_DELIMITERS
	}
}

_RDGE_RestoreState(Saved) {
	global ConfigurationFile, Features, ScriptInformation
	global _RDGE_RepeatWriterSnapshots, _RDGE_DelimiterWriterSnapshots
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed
	global HSE_RebuildInProgress, HSE_RegistryTransitionDepth
	global HSE_RepeatEnabled, HSE_RuntimeDecisionGeneration
	global _PrefixBuffer, _PrefixContentGeneration
	global _PrefixInputContextGeneration, _PrefixInputHook
	global _PrefixVisibleFireDecisions
	global _HotstringsOverridesPath, _HotstringsOverrides, _HotstringsTerminatorRecords
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	ConfigurationFile := Saved.ConfigurationFile
	ScriptInformation["MagicKey"] := Saved.MagicKey
	HSE_RepeatEnabled := Saved.RepeatEnabled
	Hotstrings := Features["hotstrings"]
	if Saved.RepeatFeatureHad
		Hotstrings["repeat_key_enabled"] := Saved.RepeatFeature
	else if Hotstrings.Has("repeat_key_enabled")
		Hotstrings.Delete("repeat_key_enabled")
	HSE_RuntimeDecisionGeneration := Saved.RuntimeGeneration
	HSE_Buffer := Saved.EngineBuffer
	HSE_StartIsWordBoundary := Saved.StartBoundary
	HSE_Suppressed := Saved.Suppressed
	HSE_RebuildInProgress := Saved.RebuildInProgress
	HSE_RegistryTransitionDepth := Saved.TransitionDepth
	_PrefixBuffer := Saved.PrefixBuffer
	_PrefixContentGeneration := Saved.PrefixContentGeneration
	_PrefixInputContextGeneration := Saved.PrefixInputContextGeneration
	_PrefixInputHook := Saved.PrefixInputHook
	_PrefixVisibleFireDecisions := Saved.VisibleDecisions
	_HotstringsOverridesPath := Saved.OverridesPath
	_HotstringsOverrides := Saved.Overrides
	_HotstringsTerminatorRecords := Saved.DelimiterOwner
	HSE_WORD_TERMINATORS := Saved.WordLive
	HSE_CONSUMED_DELIMITERS := Saved.ConsumedLive
	_RDGE_RepeatWriterSnapshots := []
	_RDGE_DelimiterWriterSnapshots := []
	if Saved.fixture is Object
		_ScopeOwnerCleanup(Saved.fixture)
}

_RDGE_SeedDecisionState(Name, Saved) {
	global ConfigurationFile, Features, ScriptInformation
	global _RDGE_RepeatWriterSnapshots, _RDGE_DelimiterWriterSnapshots
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed
	global HSE_RebuildInProgress, HSE_RegistryTransitionDepth
	global HSE_RepeatEnabled, _PrefixInputHook
	global _PrefixVisibleFireDecisions
	global _HotstringsOverridesPath, _HotstringsOverrides, _HotstringsTerminatorRecords
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Saved.fixture := _ScopeOwnerFixture()
	ConfigurationFile := Saved.fixture.path
	_HotstringsOverridesPath := A_Temp . "\ergopti_runtime_decision_override_"
		. Name . ".toml"
	_HotstringsOverrides := Map()
	ScriptInformation["MagicKey"] := "★"
	HSE_RepeatEnabled := true
	Features["hotstrings"]["repeat_key_enabled"] := true
	HSE_Suppressed := 0
	HSE_RebuildInProgress := false
	HSE_RegistryTransitionDepth := 0
	HSE_StartIsWordBoundary := true
	_PrefixInputHook := false
	_PrefixVisibleFireDecisions := []
	; A fresh delimiter owner admitted from the fixture configuration, then the
	; two strings the decision scenarios were authored against.
	_HotstringsTerminatorRecords := 0
	HotstringsTerminatorRecordsInit(FSReadUtf8Exact(ConfigurationFile))
	HSE_WORD_TERMINATORS := " "
	HSE_CONSUMED_DELIMITERS := "!"
	HSE_Buffer := ""
	_RDGE_RepeatWriterSnapshots := []
	_RDGE_DelimiterWriterSnapshots := []
}

_RDGE_RepeatWriter(Path, Updates) {
	global Features, HSE_RepeatEnabled, HSE_RuntimeDecisionGeneration
	global _RDGE_RepeatWriterSnapshots
	_RDGE_RepeatWriterSnapshots.Push({
		RepeatEnabled: HSE_RepeatEnabled,
		FeatureEnabled: Features["hotstrings"].Get(
			"repeat_key_enabled", false),
		RuntimeGeneration: HSE_RuntimeDecisionGeneration,
		Critical: A_IsCritical
	})
	return 1
}

_RDGE_DelimiterWriter(Path, Updates) {
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	global HSE_RuntimeDecisionGeneration
	global _RDGE_DelimiterWriterSnapshots
	_RDGE_DelimiterWriterSnapshots.Push({
		WordLive: HSE_WORD_TERMINATORS,
		ConsumedLive: HSE_CONSUMED_DELIMITERS,
		RuntimeGeneration: HSE_RuntimeDecisionGeneration,
		Critical: A_IsCritical
	})
	return 1
}

_RDGE_AcceptPostCommit(*) {
	return 1
}

_RDGE_CreateRepeatCandidate(Buffer) {
	global ScriptInformation, HSE_Buffer, HSE_StartIsWordBoundary
	global HSE_RuntimeDecisionGeneration
	global _PrefixContentGeneration, _PrefixInputContextGeneration
	HSE_Buffer := Buffer
	HSE_StartIsWordBoundary := true
	_PrefixSetBuffer(Buffer)
	Decision := HSE_PreviewNextDecision(
		Buffer, ScriptInformation["MagicKey"])
	AssertTrue(Decision is Object,
		"sanity: the engine must produce a canonical repeat decision")
	AssertTrue(Decision.HasOwnProp("RuntimeDecisionGeneration"),
		"every canonical preview must carry the runtime decision epoch")
	AssertEqual(HSE_RuntimeDecisionGeneration,
		Decision.RuntimeDecisionGeneration,
		"the preview stamp must equal the live epoch it evaluated")
	Candidate := _PrefixCandidateFromDecision(Decision,
		_PrefixContentGeneration, _PrefixInputContextGeneration)
	AssertTrue(Candidate is Object,
		"sanity: the canonical repeat decision must produce a visible row")
	AssertTrue(_PrefixFireDecisionStillCurrent(Candidate.FireDecision),
		"sanity: the freshly stamped row must be current before publication")
	AssertTrue(HotstringPrefixWatcherDecisionItemsStillCurrent([Candidate]),
		"sanity: the renderer must accept the freshly stamped row")
	return Candidate
}





; ====================================================
; ====================================================
; ======= 2/ Repeat publisher retires old rows =======
; ====================================================
; ====================================================

_RDGE_RepeatPublisherInvalidatesCanonicalDecision() {
	global Features, HSE_RepeatEnabled, HSE_RuntimeDecisionGeneration
	global HSE_RegistryGeneration, HSE_Buffer
	global _PrefixContentGeneration, _PrefixInputContextGeneration
	global _RDGE_RepeatWriterSnapshots
	Saved := _RDGE_SaveState()
	try {
		_RDGE_SeedDecisionState("repeat", Saved)
		Candidate := _RDGE_CreateRepeatCandidate("runtimeepochx")
		BeforeRuntime := HSE_RuntimeDecisionGeneration
		BeforeRegistry := HSE_RegistryGeneration
		BeforeContent := _PrefixContentGeneration
		BeforeContext := _PrefixInputContextGeneration

		AssertTrue(ToggleRepeatKeyEnabled(_RDGE_RepeatWriter,
			_RDGE_AcceptPostCommit, _RDGE_AcceptPostCommit))
		AssertEqual(1, _RDGE_RepeatWriterSnapshots.Length)
		Observed := _RDGE_RepeatWriterSnapshots[1]
		AssertTrue(Observed.RepeatEnabled
			and Observed.FeatureEnabled,
			"durable writing must observe the old repeat projection")
		AssertEqual(BeforeRuntime, Observed.RuntimeGeneration,
			"the epoch must remain old until durable writing succeeds")
		AssertEqual(0, Observed.Critical,
			"the durable repeat writer must remain outside Critical")

		AssertFalse(HSE_RepeatEnabled,
			"the repeat publisher must still update the live engine flag")
		AssertFalse(Features["hotstrings"]["repeat_key_enabled"],
			"the repeat publisher must still update the live feature projection")
		AssertEqual(BeforeRuntime + 1, HSE_RuntimeDecisionGeneration,
			"one repeat publication must advance the runtime epoch exactly once")
		AssertEqual(BeforeRegistry, HSE_RegistryGeneration,
			"a runtime toggle must not masquerade as a registry rebuild")
		AssertEqual(BeforeContent, _PrefixContentGeneration,
			"the rejection must not depend on a coincidental prefix mutation")
		AssertEqual(BeforeContext, _PrefixInputContextGeneration,
			"the rejection must not depend on a coincidental context mutation")
		AssertEqual("runtimeepochx", HSE_Buffer)
		AssertFalse(_PrefixFireDecisionStillCurrent(
			Candidate.FireDecision),
			"the old repeat decision must become stale when its live flag flips")
		AssertFalse(HotstringPrefixWatcherDecisionItemsStillCurrent(
			[Candidate]),
			"the renderer must reject pixels from the pre-toggle runtime epoch")
		AssertFalse(HSE_PreviewNextDecision("runtimeepochx", "★") is Object,
			"the disabled live repeat fallback must no longer produce a decision")
	} finally _RDGE_RestoreState(Saved)
}
Test("hotstrings runtime epoch: repeat publication retires its canonical preview",
	_RDGE_RepeatPublisherInvalidatesCanonicalDecision)





; =======================================================
; =======================================================
; ======= 3/ Delimiter publishers share the epoch =======
; =======================================================
; =======================================================

_RDGE_DelimiterPublishersInvalidateCanonicalDecision() {
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	global HSE_RuntimeDecisionGeneration, HSE_RegistryGeneration
	global _PrefixContentGeneration, _PrefixInputContextGeneration
	global _RDGE_DelimiterWriterSnapshots
	Saved := _RDGE_SaveState()
	try {
		_RDGE_SeedDecisionState("delimiters", Saved)
		WordCandidate := _RDGE_CreateRepeatCandidate("runtimeepochx")
		BeforeWordRuntime := HSE_RuntimeDecisionGeneration
		BeforeRegistry := HSE_RegistryGeneration
		BeforeContent := _PrefixContentGeneration
		BeforeContext := _PrefixInputContextGeneration

		AssertEqual(1, HotstringsTerminatorToggle("comma", _RDGE_DelimiterWriter))
		AssertEqual(1, _RDGE_DelimiterWriterSnapshots.Length)
		Snapshot := _RDGE_DelimiterWriterSnapshots[1]
		AssertEqual(" ", Snapshot.WordLive,
			"word publication must remain detached through the durable write")
		AssertEqual("!", Snapshot.ConsumedLive)
		AssertEqual(BeforeWordRuntime, Snapshot.RuntimeGeneration,
			"the epoch must remain old through the durable write")
		AssertEqual(0, Snapshot.Critical,
			"the configuration write must remain outside Critical")
		AssertEqual(" `t`r`n★;.!?:", HSE_WORD_TERMINATORS,
			"a word-set mutation publishes the strings derived from the leaves")
		AssertEqual("★", HSE_CONSUMED_DELIMITERS)
		AssertEqual(BeforeWordRuntime + 1,
			HSE_RuntimeDecisionGeneration,
			"word publication must advance the shared runtime epoch once")
		AssertEqual(BeforeRegistry, HSE_RegistryGeneration)
		AssertEqual(BeforeContent, _PrefixContentGeneration)
		AssertEqual(BeforeContext, _PrefixInputContextGeneration)
		AssertFalse(HotstringPrefixWatcherDecisionItemsStillCurrent(
			[WordCandidate]),
			"a word-set mutation must reject a visible pre-mutation decision")

		ConsumedCandidate := _RDGE_CreateRepeatCandidate("runtimeepochx")
		BeforeConsumedRuntime := HSE_RuntimeDecisionGeneration
		BeforeRegistry := HSE_RegistryGeneration
		BeforeContent := _PrefixContentGeneration
		BeforeContext := _PrefixInputContextGeneration

		AssertEqual(1, HotstringsTerminatorBuiltinCommit(
			Map("semicolon", Map("consume", 1)), _RDGE_DelimiterWriter))
		AssertEqual(" `t`r`n★;.!?:", HSE_WORD_TERMINATORS,
			"a consumed-only update must preserve the word engine value")
		AssertEqual("★;", HSE_CONSUMED_DELIMITERS)
		AssertEqual(BeforeConsumedRuntime + 1,
			HSE_RuntimeDecisionGeneration,
			"consumed publication must advance the same runtime epoch once")
		AssertEqual(BeforeRegistry, HSE_RegistryGeneration)
		AssertEqual(BeforeContent, _PrefixContentGeneration)
		AssertEqual(BeforeContext, _PrefixInputContextGeneration)
		AssertFalse(HotstringPrefixWatcherDecisionItemsStillCurrent(
			[ConsumedCandidate]),
			"a consumed-set mutation must reject a visible pre-mutation decision")
		AssertEqual(2, _RDGE_DelimiterWriterSnapshots.Length,
			"the word mutation and the consumed mutation must each write once")
	} finally _RDGE_RestoreState(Saved)
}
Test("hotstrings runtime epoch: word and consumed publishers reject old rows",
	_RDGE_DelimiterPublishersInvalidateCanonicalDecision)
