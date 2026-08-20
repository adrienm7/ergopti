; tests/unit/test_hotstring_override_global_transaction_20260813.ahk

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

_HSOT_SaveState() {
	global _HotstringsOverridesPath, _HotstringsOverrides, _HSResolveGen
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	return {
		Path: _HotstringsOverridesPath,
		Overrides: _HotstringsOverrides,
		Generation: _HSResolveGen,
		Word: _HotstringsWordDelimiters,
		Consumed: _HotstringsConsumedDelimiters
	}
}

_HSOT_RestoreState(Saved) {
	global _HotstringsOverridesPath, _HotstringsOverrides, _HSResolveGen
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	_HotstringsOverridesPath := Saved.Path
	_HotstringsOverrides := Saved.Overrides
	_HSResolveGen := Saved.Generation
	_HotstringsWordDelimiters := Saved.Word
	_HotstringsConsumedDelimiters := Saved.Consumed
	_HSOT_ResetFakes()
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
	global _HotstringsOverridesPath, _HotstringsOverrides, _HSResolveGen
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	_HotstringsOverridesPath := A_Temp . "\ergopti_hotstring_override_"
		. Name . "_" . A_TickCount . ".toml"
	_HotstringsOverrides := Map("rolls", {
		Delay: 0.4,
		Color: "#111111",
		ShowTooltip: "",
		Priority: "",
		Sections: Map()
	})
	_HSResolveGen := 100
	_HotstringsWordDelimiters := "word-old"
	_HotstringsConsumedDelimiters := "consumed-old"
	_HSOT_ResetFakes()
}

_HSOT_AcceptWriter(StagePath, Content) {
	global _HSOT_WriteCalls, _HSOT_WriterCritical, _HSOT_WrittenContents
	_HSOT_WriteCalls += 1
	_HSOT_WriterCritical.Push(A_IsCritical)
	_HSOT_WrittenContents.Push(Content)
	return 1
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
	return 1
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
	return Map("rolls", {
		Delay: 0.75,
		Color: "#333333",
		ShowTooltip: "",
		Priority: "",
		Sections: Map()
	})
}

_HSOT_RebaseParser(Path) {
	global _HSOT_ParseCalls, _HSOT_ParseCritical
	global _HotstringsOverridesPath
	_HSOT_ParseCalls += 1
	_HSOT_ParseCritical.Push(A_IsCritical)
	_HotstringsOverridesPath .= ".rebased"
	return Map("rolls", {
		Delay: 0.95,
		Color: "#444444",
		ShowTooltip: "",
		Priority: "",
		Sections: Map()
	})
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
	global _HotstringsOverrides, _HSResolveGen, _HSOT_WrittenContents
	global _HSOT_WriterCritical, _HSOT_ReplaceCritical
	Saved := _HSOT_SaveState()
	try {
		_HSOT_Seed("direct_compatibility")
		BeforeOverrides := _HotstringsOverrides
		BeforeGeneration := _HSResolveGen
		Candidate := _HotstringsOverrides.Clone()
		CandidateEntry := _HotstringsCloneOverrideCategory(Candidate["rolls"])
		CandidateEntry.Color := "#222222"
		Candidate["rolls"] := CandidateEntry

		AssertTrue(_SaveOverrides(Candidate,
			_HSOT_AcceptWriter, _HSOT_AcceptReplace),
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
