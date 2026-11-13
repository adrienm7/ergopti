; tests/unit/hotstrings/engine/catalogue/test_override_global_transaction.ahk

; ==============================================================================
; MODULE: Hotstring Override Global Transaction Tests
; DESCRIPTION:
; Exercises both catalogue mutation siblings through injected durable adapters.
; The suite proves global terminal admission, post-stage path revalidation,
; strict writer/replace results, and coupled Map/generation publication while
; filesystem adapters remain outside Critical.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Transaction test seams =======
; =========================================
; =========================================

global _HSOT_WriteCalls := 0
global _HSOT_ReplaceCalls := 0
global _HSOT_WriterCritical := []
global _HSOT_ReplaceCritical := []
global _HSOT_ReplaceSnapshots := []
global _HSOT_WrittenContents := []
global _HSOT_ParseCalls := 0
global _HSOT_ParseCritical := []

global _HSOT_FixtureRoot := ""

_HSOT_SaveState() {
	global _HotstringsOverridesPath, _HotstringsOverrides, _HSResolveGen, _HSOT_FixtureRoot
	return {
		Path: _HotstringsOverridesPath,
		Overrides: _HotstringsOverrides,
		Generation: _HSResolveGen,
		Root: _HSOT_FixtureRoot
	}
}

_HSOT_RestoreState(Saved) {
	global _HotstringsOverridesPath, _HotstringsOverrides, _HSResolveGen, _HSOT_FixtureRoot
	RetireRoot := _HSOT_FixtureRoot
	_HotstringsOverridesPath := Saved.Path
	_HotstringsOverrides := Saved.Overrides
	_HSResolveGen := Saved.Generation
	_HSOT_ResetFakes()
	if RetireRoot != "" && RetireRoot != Saved.Root
		DirDelete(RetireRoot, true)
	_HSOT_FixtureRoot := Saved.Root
}

_HSOT_ResetFakes() {
	global _HSOT_WriteCalls, _HSOT_ReplaceCalls
	global _HSOT_WriterCritical, _HSOT_ReplaceCritical
	global _HSOT_ReplaceSnapshots, _HSOT_WrittenContents
	global _HSOT_ParseCalls, _HSOT_ParseCritical
	_HSOT_WriteCalls := 0
	_HSOT_ReplaceCalls := 0
	_HSOT_WriterCritical := []
	_HSOT_ReplaceCritical := []
	_HSOT_ReplaceSnapshots := []
	_HSOT_WrittenContents := []
	_HSOT_ParseCalls := 0
	_HSOT_ParseCritical := []
}

_HSOT_Seed(Name) {
	global _HotstringsOverridesPath, _HotstringsOverrides, _HSResolveGen, _HSOT_FixtureRoot
	AssertEqual("", _HSOT_FixtureRoot, "An unretired private transaction fixture must remain owned for cleanup")
	CandidateRoot := A_Temp . "\ergopti_hotstring_override_" . Name . "_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	FSCreateDirectoryExclusiveStrict(CandidateRoot)
	_HSOT_FixtureRoot := CandidateRoot
	_HotstringsOverridesPath := _HSOT_FixtureRoot . "\overrides.toml"
	_HotstringsOverrides := _ParseOverrides(_HotstringsOverridesPath)
	_HotstringsOverrides["rolls"] := {
		Delay: 0.4,
		Color: "#111111",
		ShowTooltip: "",
		Priority: "",
		Sections: Map()
	}
	_HSResolveGen := 100
	_HSOT_ResetFakes()
}

_HSOT_AcceptWriter(StagePath, Content) {
	global _HSOT_WriteCalls, _HSOT_WriterCritical, _HSOT_WrittenContents
	_HSOT_WriteCalls += 1
	_HSOT_WriterCritical.Push(A_IsCritical)
	_HSOT_WrittenContents.Push(Content)
	return FSWriteDurable(StagePath, Content)
}

_HSOT_FalseWriter(StagePath, Content) {
	global _HSOT_WriteCalls, _HSOT_WriterCritical
	_HSOT_WriteCalls += 1
	_HSOT_WriterCritical.Push(A_IsCritical)
	return 0
}

_HSOT_StringWriter(StagePath, Content) {
	global _HSOT_WriteCalls, _HSOT_WriterCritical
	_HSOT_WriteCalls += 1
	_HSOT_WriterCritical.Push(A_IsCritical)
	return "1"
}

_HSOT_RebaseWriter(StagePath, Content) {
	global _HSOT_WriteCalls, _HSOT_WriterCritical
	global _HotstringsOverridesPath
	_HSOT_WriteCalls += 1
	_HSOT_WriterCritical.Push(A_IsCritical)
	; A real path transition needs the terminal barrier. This deliberate bypass
	; models a yielded staging adapter interrupted by stale legacy code
	_HotstringsOverridesPath .= ".rebased"
	return 1
}

_HSOT_RecordReplace() {
	global _HSOT_ReplaceCalls, _HSOT_ReplaceCritical, _HSOT_ReplaceSnapshots
	global _HotstringsOverrides, _HSResolveGen
	_HSOT_ReplaceCalls += 1
	_HSOT_ReplaceCritical.Push(A_IsCritical)
	_HSOT_ReplaceSnapshots.Push({
		Overrides: _HotstringsOverrides,
		Generation: _HSResolveGen
	})
}

_HSOT_AcceptReplace(StagePath, TargetPath) {
	_HSOT_RecordReplace()
	return FSAtomicMoveReplace(StagePath, TargetPath)
}

_HSOT_FalseReplace(StagePath, TargetPath) {
	_HSOT_RecordReplace()
	return 0
}

_HSOT_StringReplace(StagePath, TargetPath) {
	_HSOT_RecordReplace()
	return "1"
}

_HSOT_AcceptParser(Path) {
	global _HSOT_ParseCalls, _HSOT_ParseCritical
	_HSOT_ParseCalls += 1
	_HSOT_ParseCritical.Push(A_IsCritical)
	Source := "[rolls]`ndelay_offset = " . HotstringsSerialiseDelayOffset(0.75 - HotstringsBaseDelay())
		. '`ncolor = "#333333"`n'
	AssertTrue(FSWriteDurable(Path, Source))
	Candidate := _ParseOverrides(Path)
	return Candidate
}

_HSOT_RebaseParser(Path) {
	global _HSOT_ParseCalls, _HSOT_ParseCritical
	global _HotstringsOverridesPath
	_HSOT_ParseCalls += 1
	_HSOT_ParseCritical.Push(A_IsCritical)
	Source := "[rolls]`ndelay_offset = " . HotstringsSerialiseDelayOffset(0.95 - HotstringsBaseDelay())
		. '`ncolor = "#444444"`n'
	AssertTrue(FSWriteDurable(Path, Source))
	Candidate := _ParseOverrides(Path)
	_HotstringsOverridesPath .= ".rebased"
	return Candidate
}

_HSOT_ThrowingParser(Path) {
	global _HSOT_ParseCalls, _HSOT_ParseCritical
	_HSOT_ParseCalls += 1
	_HSOT_ParseCritical.Push(A_IsCritical)
	throw Error("synthetic parse failure")
}





; ============================================
; ============================================
; ======= 2/ Global terminal admission =======
; ============================================
; ============================================

_HSOT_TerminalBarrierRefusesBothMutatorsBeforeIo() {
	global _HotstringsOverrides, _HSResolveGen
	global _HSOT_WriteCalls, _HSOT_ReplaceCalls
	Saved := _HSOT_SaveState()
	Bundle := false
	try {
		_HSOT_Seed("terminal")
		BeforeOverrides := _HotstringsOverrides
		BeforeGeneration := _HSResolveGen
		Bundle := _ConfigWriteTerminalTryAcquire([
			A_Temp . "\ergopti_hotstring_override_unrelated_terminal.toml"
		])
		AssertTrue(Bundle is Object,
			"the terminal-collision probe must own the global barrier")

		AssertFalse(HotstringsSetOverride("rolls", "", "delay", 0.9,
			_HSOT_AcceptWriter, _HSOT_AcceptReplace))
		AssertFalse(HotstringsClearOverride("rolls", "", "delay",
			_HSOT_AcceptWriter, _HSOT_AcceptReplace))
		AssertEqual(0, _HSOT_WriteCalls,
			"both catalogue mutators must refuse before staging under any terminal transition")
		AssertEqual(0, _HSOT_ReplaceCalls)
		AssertTrue(_HotstringsOverrides == BeforeOverrides,
			"terminal refusal must preserve the live catalogue identity")
		AssertEqual(BeforeGeneration, _HSResolveGen,
			"terminal refusal must not invalidate resolution caches")
	} finally {
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		_HSOT_RestoreState(Saved)
	}
}
Test("hotstring-override-global-transaction-20260813: terminal barrier refuses "
	. "set and clear before I/O", _HSOT_TerminalBarrierRefusesBothMutatorsBeforeIo)





; ===========================================
; ===========================================
; ======= 3/ Post-stage authorization =======
; ===========================================
; ===========================================

_HSOT_PathRebaseRefusesSetAndClearAfterStage() {
	global _HotstringsOverridesPath, _HotstringsOverrides, _HSResolveGen
	global _HSOT_WriteCalls, _HSOT_ReplaceCalls, _HSOT_WriterCritical
	Saved := _HSOT_SaveState()
	try {
		_HSOT_Seed("rebase")
		BoundPath := _HotstringsOverridesPath
		BeforeOverrides := _HotstringsOverrides
		BeforeGeneration := _HSResolveGen

		AssertFalse(HotstringsSetOverride("rolls", "", "delay", 0.9,
			_HSOT_RebaseWriter, _HSOT_AcceptReplace))
		AssertEqual(1, _HSOT_WriteCalls,
			"set must reach the complete-stage authorization boundary")
		AssertEqual(0, _HSOT_ReplaceCalls,
			"set must refuse a rebased target before atomic replacement")
		AssertEqual(0, _HSOT_WriterCritical[1],
			"staging I/O must run outside Critical")
		AssertTrue(_HotstringsOverrides == BeforeOverrides)
		AssertEqual(BeforeGeneration, _HSResolveGen)

		_HotstringsOverridesPath := BoundPath
		_HSOT_ResetFakes()
		AssertFalse(HotstringsClearOverride("rolls", "", "delay",
			_HSOT_RebaseWriter, _HSOT_AcceptReplace))
		AssertEqual(1, _HSOT_WriteCalls,
			"clear must reach the same complete-stage authorization boundary")
		AssertEqual(0, _HSOT_ReplaceCalls,
			"clear must refuse a rebased target before atomic replacement")
		AssertEqual(0, _HSOT_WriterCritical[1])
		AssertTrue(_HotstringsOverrides == BeforeOverrides)
		AssertEqual(BeforeGeneration, _HSResolveGen)
	} finally _HSOT_RestoreState(Saved)
}
Test("hotstring-override-global-transaction-20260813: set and clear revalidate "
	. "the exact owner and path after staging", _HSOT_PathRebaseRefusesSetAndClearAfterStage)





; ===================================
; ===================================
; ======= 4/ Durable failures =======
; ===================================
; ===================================

_HSOT_WriterAndReplaceFailuresPublishNothing() {
	global _HotstringsOverrides, _HSResolveGen
	global _HSOT_WriteCalls, _HSOT_ReplaceCalls
	global _HSOT_WriterCritical, _HSOT_ReplaceCritical
	Saved := _HSOT_SaveState()
	try {
		_HSOT_Seed("failure")
		BeforeOverrides := _HotstringsOverrides
		BeforeGeneration := _HSResolveGen

		AssertFalse(HotstringsSetOverride("rolls", "", "delay", 0.9,
			_HSOT_FalseWriter, _HSOT_AcceptReplace))
		AssertEqual(1, _HSOT_WriteCalls)
		AssertEqual(0, _HSOT_ReplaceCalls)
		AssertEqual(0, _HSOT_WriterCritical[1])
		AssertTrue(_HotstringsOverrides == BeforeOverrides)
		AssertEqual(BeforeGeneration, _HSResolveGen)

		_HSOT_ResetFakes()
		AssertFalse(HotstringsSetOverride("rolls", "", "delay", 0.9,
			_HSOT_StringWriter, _HSOT_AcceptReplace),
			"a truthy-looking writer String must not authorize replacement")
		AssertEqual(1, _HSOT_WriteCalls)
		AssertEqual(0, _HSOT_ReplaceCalls)
		AssertTrue(_HotstringsOverrides == BeforeOverrides)
		AssertEqual(BeforeGeneration, _HSResolveGen)

		_HSOT_ResetFakes()
		AssertFalse(HotstringsClearOverride("rolls", "", "delay",
			_HSOT_AcceptWriter, _HSOT_FalseReplace))
		AssertEqual(1, _HSOT_WriteCalls)
		AssertEqual(1, _HSOT_ReplaceCalls)
		AssertEqual(0, _HSOT_WriterCritical[1])
		AssertEqual(0, _HSOT_ReplaceCritical[1],
			"atomic filesystem replacement must run outside Critical even on failure")
		AssertTrue(_HotstringsOverrides == BeforeOverrides,
			"replace refusal must preserve the live catalogue identity")
		AssertEqual(BeforeGeneration, _HSResolveGen,
			"replace refusal must not publish a cache generation")

		_HSOT_ResetFakes()
		AssertFalse(HotstringsClearOverride("rolls", "", "delay",
			_HSOT_AcceptWriter, _HSOT_StringReplace),
			"a truthy-looking replace String must not authorize live publication")
		AssertEqual(1, _HSOT_WriteCalls)
		AssertEqual(1, _HSOT_ReplaceCalls)
		AssertEqual(0, _HSOT_ReplaceCritical[1])
		AssertTrue(_HotstringsOverrides == BeforeOverrides)
		AssertEqual(BeforeGeneration, _HSResolveGen)
	} finally _HSOT_RestoreState(Saved)
}
Test("hotstring-override-global-transaction-20260813: writer and replace "
	. "failures publish neither Map nor generation", _HSOT_WriterAndReplaceFailuresPublishNothing)





; ===========================================
; ===========================================
; ======= 5/ Coupled live publication =======
; ===========================================
; ===========================================

_HSOT_SetAndClearPublishOnlyAfterNonCriticalReplace() {
	global _HotstringsOverrides, _HSResolveGen
	global _HSOT_WriterCritical, _HSOT_ReplaceCritical
	global _HSOT_ReplaceSnapshots
	Saved := _HSOT_SaveState()
	try {
		_HSOT_Seed("publish")
		BeforeSetOverrides := _HotstringsOverrides
		BeforeSetGeneration := _HSResolveGen
		AssertTrue(HotstringsSetOverride("rolls", "", "delay", 0.9,
			_HSOT_AcceptWriter, _HSOT_AcceptReplace))
		AssertEqual(0, _HSOT_WriterCritical[1])
		AssertEqual(0, _HSOT_ReplaceCritical[1],
			"the filesystem seam must never inherit the publication Critical span")
		AssertTrue(_HSOT_ReplaceSnapshots[1].Overrides == BeforeSetOverrides,
			"live Map must remain old through durable replacement")
		AssertEqual(BeforeSetGeneration,
			_HSOT_ReplaceSnapshots[1].Generation,
			"cache generation must remain old through durable replacement")
		AssertTrue(_HotstringsOverrides != BeforeSetOverrides)
		AssertEqual(0.9, _HotstringsOverrides["rolls"].Delay)
		AssertEqual(BeforeSetGeneration + 1, _HSResolveGen,
			"one accepted set must publish exactly one matching generation")

		BeforeClearOverrides := _HotstringsOverrides
		BeforeClearGeneration := _HSResolveGen
		_HSOT_ResetFakes()
		AssertTrue(HotstringsClearOverride("rolls", "", "delay",
			_HSOT_AcceptWriter, _HSOT_AcceptReplace))
		AssertEqual(0, _HSOT_WriterCritical[1])
		AssertEqual(0, _HSOT_ReplaceCritical[1])
		AssertTrue(_HSOT_ReplaceSnapshots[1].Overrides == BeforeClearOverrides)
		AssertEqual(BeforeClearGeneration,
			_HSOT_ReplaceSnapshots[1].Generation)
		AssertTrue(_HotstringsOverrides != BeforeClearOverrides)
		AssertEqual("", _HotstringsOverrides["rolls"].Delay)
		AssertEqual(BeforeClearGeneration + 1, _HSResolveGen,
			"one accepted clear must publish exactly one matching generation")
	} finally _HSOT_RestoreState(Saved)
}
Test("hotstring-override-global-transaction-20260813: set and clear publish "
	. "Map plus generation only after non-Critical replacement",
	_HSOT_SetAndClearPublishOnlyAfterNonCriticalReplace)

_HSOT_InheritedCriticalIsSuspendedAcrossWholeTransaction() {
	global _HotstringsOverrides, _HSResolveGen
	global _HSOT_WriterCritical, _HSOT_ReplaceCritical
	Saved := _HSOT_SaveState()
	try {
		_HSOT_Seed("inherited_critical")
		SetOuterCritical := 0
		SetResult := false
		PreviousCritical := Critical("On")
		try {
			SetResult := HotstringsSetOverride("rolls", "", "delay", 0.9,
				_HSOT_AcceptWriter, _HSOT_AcceptReplace)
			SetOuterCritical := A_IsCritical
		} finally Critical(PreviousCritical)

		AssertTrue(SetResult)
		AssertTrue(SetOuterCritical > 0,
			"the public mutator must restore its caller's Critical state")
		AssertEqual(0, _HSOT_WriterCritical[1],
			"an external Critical wrapper must not reach staging I/O")
		AssertEqual(0, _HSOT_ReplaceCritical[1],
			"an external Critical wrapper must not reach replacement I/O")
		AssertEqual(0.9, _HotstringsOverrides["rolls"].Delay)
		AssertEqual(101, _HSResolveGen)

		_HSOT_ResetFakes()
		ClearOuterCritical := 0
		ClearResult := false
		PreviousCritical := Critical("On")
		try {
			ClearResult := HotstringsClearOverride("rolls", "", "delay",
				_HSOT_AcceptWriter, _HSOT_AcceptReplace)
			ClearOuterCritical := A_IsCritical
		} finally Critical(PreviousCritical)
		AssertTrue(ClearResult)
		AssertTrue(ClearOuterCritical > 0)
		AssertEqual(0, _HSOT_WriterCritical[1],
			"the clear sibling must also suspend caller Critical before staging")
		AssertEqual(0, _HSOT_ReplaceCritical[1],
			"the clear sibling must also suspend caller Critical before replacement")
		AssertEqual("", _HotstringsOverrides["rolls"].Delay)
		AssertEqual(102, _HSResolveGen)
	} finally {
		if A_IsCritical
			Critical("Off")
		_HSOT_RestoreState(Saved)
	}
}
Test("hotstring-override-global-transaction-20260813: caller Critical is "
	. "suspended for I/O and restored after publication",
	_HSOT_InheritedCriticalIsSuspendedAcrossWholeTransaction)

_HSOT_ReloadRevalidatesAfterNonCriticalParse() {
	global _HotstringsOverridesPath, _HotstringsOverrides, _HSResolveGen
	global _HSOT_ParseCalls, _HSOT_ParseCritical
	Saved := _HSOT_SaveState()
	try {
		_HSOT_Seed("reload")
		BeforeOverrides := _HotstringsOverrides
		BeforeGeneration := _HSResolveGen
		OuterCritical := 0
		ReloadResult := false
		PreviousCritical := Critical("On")
		try {
			ReloadResult := HotstringsConfigReload(_HSOT_AcceptParser)
			OuterCritical := A_IsCritical
		} finally Critical(PreviousCritical)

		AssertTrue(ReloadResult,
			"an authorized detached reload candidate must publish")
		AssertEqual(1, _HSOT_ParseCalls)
		AssertEqual(0, _HSOT_ParseCritical[1],
			"override FileRead/parsing must not inherit caller Critical")
		AssertTrue(OuterCritical > 0,
			"reload must restore its caller's Critical state")
		AssertTrue(_HotstringsOverrides != BeforeOverrides,
			"reload must swap the detached Map only after parsing completes")
		AssertEqual(0.75, _HotstringsOverrides["rolls"].Delay)
		AssertEqual(BeforeGeneration + 1, _HSResolveGen,
			"the accepted Map and exactly one generation must publish together")

		; Retire the first owned native source before acquiring the second scope.
		_HSOT_RestoreState(Saved)
		_HSOT_Seed("reload_rebase")
		BoundPath := _HotstringsOverridesPath
		BeforeOverrides := _HotstringsOverrides
		BeforeGeneration := _HSResolveGen
		AssertFalse(HotstringsConfigReload(_HSOT_RebaseParser),
			"a parser that yields across a path rebase must lose authorization")
		AssertEqual(0, _HSOT_ParseCritical[1])
		AssertTrue(_HotstringsOverrides == BeforeOverrides,
			"post-parse path refusal must preserve the live Map identity")
		AssertEqual(BeforeGeneration, _HSResolveGen,
			"post-parse path refusal must preserve cache generation")
		_HotstringsOverridesPath := BoundPath

		_HSOT_ResetFakes()
		AssertFalse(HotstringsConfigReload(_HSOT_ThrowingParser),
			"a parser exception must become a loud failed reload")
		AssertEqual(0, _HSOT_ParseCritical[1])
		AssertTrue(_HotstringsOverrides == BeforeOverrides)
		AssertEqual(BeforeGeneration, _HSResolveGen)
	} finally {
		if A_IsCritical
			Critical("Off")
		_HSOT_RestoreState(Saved)
	}
}
Test("hotstring-override-global-transaction-20260813: reload parses outside "
	. "Critical and revalidates path before coupled publication",
	_HSOT_ReloadRevalidatesAfterNonCriticalParse)

_HSOT_DirectSerializerCompatibilityDoesNotImplyLivePublish() {
	global _HotstringsOverrides, _HotstringsOverridesPath, _HSResolveGen, _HSOT_WrittenContents
	global _HSOT_WriterCritical, _HSOT_ReplaceCritical
	Saved := _HSOT_SaveState()
	try {
		_HSOT_Seed("direct_compatibility")
		BeforeOverrides := _HotstringsOverrides
		BeforeGeneration := _HSResolveGen
		Origin := _HotstringsOverrideSourceFor(_HotstringsOverrides, _HotstringsOverridesPath)
		Candidate := _HotstringsOverrides.Clone()
		CandidateEntry := _HotstringsCloneOverrideCategory(Candidate["rolls"])
		CandidateEntry.Color := "#222222"
		Candidate["rolls"] := CandidateEntry

		AssertTrue(_SaveOverrides(Candidate,
			_HSOT_AcceptWriter, _HSOT_AcceptReplace, _HotstringsOverridesPath, 0, 0, 0, Origin),
			"legacy direct serializers must keep their atomic write-only contract")
		AssertEqual(0, _HSOT_WriterCritical[1])
		AssertEqual(0, _HSOT_ReplaceCritical[1])
		Assert(InStr(_HSOT_WrittenContents[1], 'color = "#222222"') > 0,
			"the direct compatibility path must serialize its explicit candidate")
		AssertTrue(_HotstringsOverrides == BeforeOverrides,
			"omitting PublishFn must not claim a live Map publication")
		AssertEqual(BeforeGeneration, _HSResolveGen,
			"omitting PublishFn must not claim a live generation publication")
	} finally _HSOT_RestoreState(Saved)
}
Test("hotstring-override-global-transaction-20260813: direct _SaveOverrides "
	. "calls retain atomic write-only compatibility",
	_HSOT_DirectSerializerCompatibilityDoesNotImplyLivePublish)

_HSTG_ForeignStage(Collision) {
	Root := A_Temp . "\ergopti_override_stage_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := Root . "\overrides.toml", Created := false
	global _HotstringsOverridesPath, _HotstringsOverrides, _HSResolveGen
	SavedPath := _HotstringsOverridesPath, SavedMap := _HotstringsOverrides, SavedGen := _HSResolveGen
	Owner := FSWriteReplaceOwned, HadOwn := Owner.HasOwnProp("Call")
	if HadOwn
		SavedCall := Owner.GetOwnPropDesc("Call")
	Installed := false
	State := {hits: 0, stagePath: "", sentinelBytes: 0, createdSentinel: 0, originalEntered: 0, originalCompleted: 0}
	Source := '[rolls]`ncolor = "#111111"`n'
	Sentinel := "Foreign override stage: é😀 unchanged"
	Observe(This, Target, Content, Suffix, &Detail := "", StageFn := 0,
			BeforePublishFn := 0, AdmissionFn := 0, ReplaceExisting := true,
			&Publication := 0, FlushFn := 0) {
		Mine := (Target is String) && StrCompare(Target, Path, true) == 0
		CreateOriginal(Folder, Name, Attributes) {
			SplitPath(Path, &Leaf)
			AssertEqual(Leaf . Suffix, Name, "the observed factory must create the actual target's exact stage leaf")
			State.hits += 1
			State.stagePath := Path . Suffix
			if Collision {
				State.createdSentinel := FSWriteCreateDurable(State.stagePath, Sentinel)
				AssertEqual(1, State.createdSentinel, "the foreign stage must actually be acquired by CREATE_NEW")
				State.sentinelBytes := FSReadBytesStrict(State.stagePath)
			}
			return StageFn.Call(Folder, Name, Attributes)
		}
		if Mine
			State.originalEntered += 1
		NativeResult := Func.Prototype.Call.Call(This, Target, Content, Suffix, &Detail,
			Mine ? CreateOriginal : StageFn, BeforePublishFn, AdmissionFn, ReplaceExisting, &Publication, FlushFn)
		if Mine
			State.originalCompleted += 1
		return NativeResult
	}
	try {
		AssertFalse(_ConfigFullSaveHasPending(), "a private override target must not detach a foreign full-save obligation")
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created)
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := _ParseOverrides(Path)
		AssertEqual("#111111", _HotstringsOverrides["rolls"].Color)
		OriginalMap := _HotstringsOverrides, OriginalGen := _HSResolveGen
		Before := FSReadBytesStrict(Path)
		Owner.DefineProp("Call", {Call: Observe})
		Installed := true
		Result := HotstringsSetOverride("rolls", "", "color", "#222222")
		After := FSReadBytesStrict(Path)
		StagePresent := State.stagePath != "" && FSStrictExists(State.stagePath)
		StageBytes := StagePresent ? FSReadBytesStrict(State.stagePath) : Buffer(0)
		_TestPrint("# override-stage-ownership collision=" . Collision . " calls=" . State.hits
			. " created_sentinel=" . State.createdSentinel . " original_entered=" . State.originalEntered
			. " original_completed=" . State.originalCompleted
			. " result=" . Result . " stage_present=" . StagePresent
			. " before_bytes=" . Before.Size . " after_bytes=" . After.Size
			. " live_color=" . _HotstringsOverrides["rolls"].Color . " generation_delta=" . (_HSResolveGen - OriginalGen))
		AssertEqual(1, State.hits, "the actual default override publisher must reach its real native staging owner")
		AssertEqual(1, State.originalEntered, "the real staging writer must be delegated exactly once")
		AssertEqual(1, State.originalCompleted, "the real original writer must return before business assertions")
		AssertEqual(Collision ? 1 : 0, State.createdSentinel)
		if Collision {
			AssertTrue(StagePresent, "an override save cannot rename or delete another owner's stage")
			AssertEqual(State.sentinelBytes.Size, StageBytes.Size)
			AssertEqual(StageBytes.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", State.sentinelBytes,
				"Ptr", StageBytes, "UPtr", StageBytes.Size, "UPtr"), "foreign bytes must remain exact")
			AssertFalse(Result)
			AssertTrue(_HotstringsOverrides == OriginalMap, "a rejected durable operation retains the original live Map owner")
			AssertEqual(OriginalGen, _HSResolveGen)
			AssertEqual("#111111", _HotstringsOverrides["rolls"].Color)
			AssertEqual(Before.Size, After.Size)
			AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", Before,
				"Ptr", After, "UPtr", Before.Size, "UPtr"), "collision refuses all target publication")
		} else {
			AssertTrue(Result)
			AssertEqual(OriginalGen + 1, _HSResolveGen)
			AssertEqual("#222222", _HotstringsOverrides["rolls"].Color)
			AssertFalse(StagePresent)
			Actual := TOML_ParseDocument(FSReadUtf8Exact(Path))
			AssertEqual("#222222", Actual["rolls"]["color"])
		}
	} finally {
		if Installed {
			if HadOwn
				Owner.DefineProp("Call", SavedCall)
			else
				Owner.DeleteProp("Call")
		}
		_HotstringsOverridesPath := SavedPath
		_HotstringsOverrides := SavedMap
		_HSResolveGen := SavedGen
		if Created {
			_TOML_InvalidateParseCache(Path)
			Refusals := _TOML_WriteRefusals(), RefusalKey := _TOML_WriteRefusalKey(Path)
			if Refusals.Has(RefusalKey)
				Refusals.Delete(RefusalKey)
			DirDelete(Root, true)
		}
	}
}
for _HSTG_Collision in [true, false]
	Test("override stage: foreign collision=" . _HSTG_Collision . " (override-stage-ownership)", _HSTG_ForeignStage.Bind(_HSTG_Collision))

_HSGP_Outcome(Denied) {
	Root := A_Temp . "\ergopti_override_partial_owner_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := Root . "\overrides.toml", Created := false
	global _HotstringsOverridesPath, _HotstringsOverrides, _HSResolveGen
	SavedPath := _HotstringsOverridesPath, SavedMap := _HotstringsOverrides, SavedGen := _HSResolveGen
	Owner := FSWriteReplaceOwned, HadOwn := Owner.HasOwnProp("Call"), Installed := false
	if HadOwn
		SavedCall := Owner.GetOwnPropDesc("Call")
	State := {calls: 0, completed: 0, publishedFlushes: 0, nativeFlushAck: 0, handle: -1, handleQuery: -1, handleError: 0}
	Source := '[rolls]`ncolor = "#111111"`n'
	FlushNative(Handle, Phase) {
		NativeAck := DllCall("kernel32\FlushFileBuffers", "Ptr", Handle, "Int")
		if Phase == "published" {
			State.publishedFlushes += 1
			State.nativeFlushAck := NativeAck
			State.handle := Handle
		}
		if !NativeAck
			throw OSError(A_LastError, "fixture actual private override flush")
		; The native flush happened; only its typed durable acknowledgement is
		; declined at the published boundary. This is not a claim of OS failure.
		return Denied && Phase == "published" ? 0 : 1
	}
	Observe(This, Target, Content, Suffix, &Detail := "", StageFn := 0,
			BeforePublishFn := 0, AdmissionFn := 0, ReplaceExisting := true,
			&Publication := 0, FlushFn := 0) {
		Mine := (Target is String) && StrCompare(Target, Path, true) == 0
		if Mine {
			State.calls += 1
			AssertTrue((FlushFn is Integer) && FlushFn == 0)
		}
		Result := Func.Prototype.Call.Call(This, Target, Content, Suffix, &Detail,
			StageFn, BeforePublishFn, AdmissionFn, ReplaceExisting, &Publication, Mine ? FlushNative : FlushFn)
		if Mine {
			State.completed += 1
			if State.handle != -1 {
				Info := Buffer(52, 0)
				DllCall("kernel32\SetLastError", "UInt", 0)
				State.handleQuery := DllCall("kernel32\GetFileInformationByHandle", "Ptr", State.handle, "Ptr", Info, "Int")
				State.handleError := A_LastError
			}
		}
		return Result
	}
	try {
		AssertFalse(_ConfigFullSaveHasPending())
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created)
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := _ParseOverrides(Path)
		AssertEqual("#111111", _HotstringsOverrides["rolls"].Color)
		BeforeGen := _HSResolveGen
		Owner.DefineProp("Call", {Call: Observe})
		Installed := true
		Result := HotstringsSetOverride("rolls", "", "color", "#222222")
		Disk := TOML_ParseDocument(FSReadUtf8Exact(Path))
		Receipt := _HotstringsOverrideSourceFor(_HotstringsOverrides, Path)
		SourceCurrent := IsObject(Receipt) && _FSSourceIsUnchanged(Path, Receipt.Source)
		_TestPrint("# hotstrings-override-partial denied_ack=" . Denied . " calls=" . State.calls
			. " completed=" . State.completed . " native_flush_ack=" . State.nativeFlushAck
			. " published_flushes=" . State.publishedFlushes . " handle_query=" . State.handleQuery
			. " handle_error=" . State.handleError . " result=" . Result
			. " source_current=" . SourceCurrent . " disk_color=" . Disk["rolls"]["color"]
			. " live_color=" . _HotstringsOverrides["rolls"].Color . " generation_delta=" . (_HSResolveGen - BeforeGen))
		AssertEqual(1, State.calls)
		AssertEqual(1, State.completed)
		AssertEqual(1, State.publishedFlushes)
		AssertEqual(1, State.nativeFlushAck)
		AssertEqual(0, State.handleQuery, "the exact stage handle must be retired immediately on helper return, before caller diagnostics")
		AssertEqual(6, State.handleError)
		AssertEqual("#222222", Disk["rolls"]["color"])
		AssertEqual(Denied ? 0 : 1, Result)
		AssertEqual(!Denied, SourceCurrent)
		AssertEqual(Denied ? "#111111" : "#222222", _HotstringsOverrides["rolls"].Color)
		AssertEqual(BeforeGen + (Denied ? 0 : 1), _HSResolveGen)
		; Remove only the fixture's typed refusal; all retries use real native I/O.
		if HadOwn
			Owner.DefineProp("Call", SavedCall)
		else
			Owner.DeleteProp("Call")
		Installed := false
		if Denied {
			BeforeRetry := FSReadBytesStrict(Path)
			AssertFalse(HotstringsSetOverride("rolls", "", "color", "#333333"), "a genuinely changed source cannot be rebased from the old live receipt")
			AfterRetry := FSReadBytesStrict(Path)
			AssertEqual(BeforeRetry.Size, AfterRetry.Size)
			AssertEqual(BeforeRetry.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", BeforeRetry,
				"Ptr", AfterRetry, "UPtr", BeforeRetry.Size, "UPtr"))
			AssertTrue(HotstringsConfigReload(), "the actual reload reconciles the complete native image")
			AssertEqual("#222222", _HotstringsOverrides["rolls"].Color)
		}
		AssertTrue(HotstringsSetOverride("rolls", "", "color", "#333333"), "a current source receipt accepts a new fully native durable write")
		AssertEqual("#333333", _HotstringsOverrides["rolls"].Color)
		AssertEqual("#333333", TOML_ParseDocument(FSReadUtf8Exact(Path))["rolls"]["color"])
	} finally {
		if Installed {
			if HadOwn
				Owner.DefineProp("Call", SavedCall)
			else
				Owner.DeleteProp("Call")
		}
		_HotstringsOverridesPath := SavedPath
		_HotstringsOverrides := SavedMap
		_HSResolveGen := SavedGen
		if Created {
			_TOML_InvalidateParseCache(Path)
			Refusals := _TOML_WriteRefusals(), Key := _TOML_WriteRefusalKey(Path)
			if Refusals.Has(Key)
				Refusals.Delete(Key)
			DirDelete(Root, true)
		}
	}
}
for _HSGP_Denied in [true, false]
	Test("hotstring override partial: actual rename declined durable ack=" . _HSGP_Denied
		. " (hotstring-override-partial-publication)", _HSGP_Outcome.Bind(_HSGP_Denied))

_HSPA_PostAckFailure(Mode) {
	global _HotstringsOverridesPath, _HotstringsOverrides, _HSResolveGen
	SavedPath := _HotstringsOverridesPath, SavedMap := _HotstringsOverrides, SavedGen := _HSResolveGen
	Root := A_Temp . "\ergopti_override_post_ack_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := Root . "\overrides.toml", Created := false
	Native := FSWriteReplaceOwned, Reporter := ConfigReportPersistenceFailure
	HadNative := Native.HasOwnProp("Call"), HadReporter := Reporter.HasOwnProp("Call")
	if HadNative
		SavedNative := Native.GetOwnPropDesc("Call")
	if HadReporter
		SavedReporter := Reporter.GetOwnPropDesc("Call")
	InstalledNative := false, InstalledReporter := false
	State := {nativeCalls: 0, nativeAck: 0, lock: 0, reports: 0, unchanged: "unset", publisherCalls: 0}
	ObserveNative(This, Target, Content, Suffix, &Detail := "", StageFn := 0,
			BeforePublishFn := 0, AdmissionFn := 0, ReplaceExisting := true,
			&Publication := 0, FlushFn := 0) {
		Result := Func.Prototype.Call.Call(This, Target, Content, Suffix, &Detail,
			StageFn, BeforePublishFn, AdmissionFn, ReplaceExisting, &Publication, FlushFn)
		if (Target is String) && StrCompare(Target, Path, true) == 0 {
			State.nativeCalls += 1
			State.nativeAck := Result
			if Mode == "readback" && Result == 1 {
				State.lock := FileOpen(Path, "r-rwd")
				AssertTrue(IsObject(State.lock), "the real post-ACK readback must be denied by an acquired private native handle")
			}
		}
		return Result
	}
	ObserveReport(This, Context, NotifyFn := 0, Detail := "", StateUnchanged := true) {
		State.reports += 1
		State.unchanged := StateUnchanged
		return Func.Prototype.Call.Call(This, Context, NotifyFn, Detail, StateUnchanged)
	}
	RefusePublisher() {
		State.publisherCalls += 1
		return 0
	}
	try {
		AssertFalse(_ConfigFullSaveHasPending())
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created)
		AssertEqual(1, FSWriteCreateDurable(Path, '[rolls]`ncolor = "#111111"`n'))
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := _ParseOverrides(Path)
		Origin := _HotstringsOverrideSourceFor(_HotstringsOverrides, Path)
		OriginalMap := _HotstringsOverrides, BeforeGen := _HSResolveGen
		Candidate := _HotstringsOverrides.Clone()
		Candidate["rolls"] := _HotstringsCloneOverrideCategory(Candidate["rolls"])
		Candidate["rolls"].Color := "#222222"
		Native.DefineProp("Call", {Call: ObserveNative}), InstalledNative := true
		Reporter.DefineProp("Call", {Call: ObserveReport}), InstalledReporter := true
		Result := _SaveOverrides(Candidate, 0, 0, Path, 0, RefusePublisher, 0, Origin)
		HeldReadback := IsObject(State.lock)
		if HeldReadback {
			State.lock.Close()
			State.lock := 0
		}
		Disk := TOML_ParseDocument(FSReadUtf8Exact(Path))
		_TestPrint("# override-post-ack mode=" . Mode . " native_calls=" . State.nativeCalls
			. " native_ack=" . State.nativeAck . " readback_lock=" . HeldReadback . " result=" . Result
			. " reports=" . State.reports . " state_unchanged=" . State.unchanged
			. " publisher_calls=" . State.publisherCalls . " disk_color=" . Disk["rolls"]["color"])
		AssertEqual(1, State.nativeCalls)
		AssertEqual(1, State.nativeAck, "the genuine writer must fully acknowledge its real rename/durability before the later refusal")
		AssertEqual(Mode == "readback", HeldReadback)
		AssertEqual(Mode == "publisher" ? 1 : 0, State.publisherCalls)
		AssertFalse(Result)
		AssertEqual("#222222", Disk["rolls"]["color"])
		AssertTrue(_HotstringsOverrides == OriginalMap)
		AssertEqual("#111111", _HotstringsOverrides["rolls"].Color)
		AssertEqual(BeforeGen, _HSResolveGen)
		AssertEqual(1, State.reports)
		AssertTrue((State.unchanged is Integer) && State.unchanged == 0,
			"a post-ACK refusal must not report that the durable file was left unchanged")
	} finally {
		if IsObject(State.lock)
			State.lock.Close()
		if InstalledReporter {
			if HadReporter
				Reporter.DefineProp("Call", SavedReporter)
			else
				Reporter.DeleteProp("Call")
		}
		if InstalledNative {
			if HadNative
				Native.DefineProp("Call", SavedNative)
			else
				Native.DeleteProp("Call")
		}
		_HotstringsOverridesPath := SavedPath, _HotstringsOverrides := SavedMap, _HSResolveGen := SavedGen
		if Created {
			_TOML_InvalidateParseCache(Path)
			Refusals := _TOML_WriteRefusals(), Key := _TOML_WriteRefusalKey(Path)
			if Refusals.Has(Key)
				Refusals.Delete(Key)
			DirDelete(Root, true)
		}
	}
}
for _HSPA_Mode in ["readback", "publisher"]
	Test("hotstring override post-ACK failure: " . _HSPA_Mode
		. " (override-post-ack-truthful-feedback)", _HSPA_PostAckFailure.Bind(_HSPA_Mode))
