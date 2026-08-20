; tests/unit/test_hotstring_delimiter_global_transaction_20260813.ahk

; ==============================================================================
; MODULE: Hotstring Delimiter Global Transaction Tests
; DESCRIPTION:
; Drives the real delimiter setters and tray callbacks with injected durable
; adapters. The tests pin process-wide terminal admission, detached whole-file
; candidates, strict writer results, one-write paired mutations, unique stages,
; and menu side effects that run only after durable success.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../ui/menu/menu_hotstrings.ahk





; =========================================
; =========================================
; ======= 1/ Transaction test seams =======
; =========================================
; =========================================

global _HSDT_BuildCalls := 0
global _HSDT_WriteCalls := 0
global _HSDT_ReplaceCalls := 0
global _HSDT_NotifyCalls := 0
global _HSDT_RebuildCalls := 0
global _HSDT_StagePaths := []
global _HSDT_WrittenContents := []
global _HSDT_ObservedDuringWrite := []
global _HSDT_ObservedDuringReplace := []
global _HSDT_WriterCritical := -1
global _HSDT_ReplaceCritical := -1
global _HSDT_NotifyCritical := -1
global _HSDT_SetterCritical := -1
global _HSDT_RebuildCritical := -1

_HSDT_ResetFakes() {
	global _HSDT_BuildCalls, _HSDT_WriteCalls, _HSDT_ReplaceCalls
	global _HSDT_NotifyCalls, _HSDT_RebuildCalls, _HSDT_StagePaths
	global _HSDT_WrittenContents, _HSDT_ObservedDuringWrite
	global _HSDT_ObservedDuringReplace
	global _HSDT_WriterCritical, _HSDT_ReplaceCritical
	global _HSDT_NotifyCritical, _HSDT_SetterCritical
	global _HSDT_RebuildCritical
	_HSDT_BuildCalls := 0
	_HSDT_WriteCalls := 0
	_HSDT_ReplaceCalls := 0
	_HSDT_NotifyCalls := 0
	_HSDT_RebuildCalls := 0
	_HSDT_StagePaths := []
	_HSDT_WrittenContents := []
	_HSDT_ObservedDuringWrite := []
	_HSDT_ObservedDuringReplace := []
	_HSDT_WriterCritical := -1
	_HSDT_ReplaceCritical := -1
	_HSDT_NotifyCritical := -1
	_HSDT_SetterCritical := -1
	_HSDT_RebuildCritical := -1
}

_HSDT_SaveState() {
	global _HotstringsOverridesPath, _HotstringsOverrides
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	return {
		Path: _HotstringsOverridesPath,
		Overrides: _HotstringsOverrides,
		Word: _HotstringsWordDelimiters,
		Consumed: _HotstringsConsumedDelimiters,
		EngineWord: HSE_WORD_TERMINATORS,
		EngineConsumed: HSE_CONSUMED_DELIMITERS
	}
}

_HSDT_Seed(Name, Word := "A", Consumed := "A") {
	global _HotstringsOverridesPath, _HotstringsOverrides
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	_HotstringsOverridesPath := A_Temp . "\ergopti_hs_delimiter_" . Name . ".toml"
	_HotstringsOverrides := Map()
	_HotstringsWordDelimiters := Word
	_HotstringsConsumedDelimiters := Consumed
	HSE_WORD_TERMINATORS := Word
	HSE_CONSUMED_DELIMITERS := Consumed
	_HSDT_ResetFakes()
}

_HSDT_Restore(Saved) {
	global _HotstringsOverridesPath, _HotstringsOverrides
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	_HotstringsOverridesPath := Saved.Path
	_HotstringsOverrides := Saved.Overrides
	_HotstringsWordDelimiters := Saved.Word
	_HotstringsConsumedDelimiters := Saved.Consumed
	HSE_WORD_TERMINATORS := Saved.EngineWord
	HSE_CONSUMED_DELIMITERS := Saved.EngineConsumed
	_HSDT_ResetFakes()
}

_HSDT_CountingBuilder(CurrentWord, CurrentConsumed) {
	global _HSDT_BuildCalls
	_HSDT_BuildCalls += 1
	return { Word: CurrentWord . "Z", Consumed: CurrentConsumed . "Z" }
}

_HSDT_AcceptWriter(StagePath, Content) {
	global _HSDT_WriteCalls, _HSDT_StagePaths, _HSDT_WrittenContents
	global _HSDT_ObservedDuringWrite
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	global _HSDT_WriterCritical
	_HSDT_WriteCalls += 1
	_HSDT_WriterCritical := A_IsCritical
	_HSDT_StagePaths.Push(StagePath)
	_HSDT_WrittenContents.Push(Content)
	_HSDT_ObservedDuringWrite.Push({
		Word: _HotstringsWordDelimiters,
		Consumed: _HotstringsConsumedDelimiters,
		EngineWord: HSE_WORD_TERMINATORS,
		EngineConsumed: HSE_CONSUMED_DELIMITERS
	})
	return 1
}

_HSDT_FalseWriter(StagePath, Content) {
	global _HSDT_WriteCalls
	_HSDT_WriteCalls += 1
	return 0
}

_HSDT_StringWriter(StagePath, Content) {
	global _HSDT_WriteCalls
	_HSDT_WriteCalls += 1
	return "1"
}

_HSDT_RebaseWriter(StagePath, Content) {
	global _HSDT_WriteCalls, _HotstringsOverridesPath
	_HSDT_WriteCalls += 1
	; Simulates a yielded stage writer interrupted by a path/config rebase that
	; bypassed this store. Final authorization must catch the stale target.
	_HotstringsOverridesPath .= ".rebased"
	return 1
}

_HSDT_AcceptReplace(StagePath, TargetPath) {
	global _HSDT_ReplaceCalls, _HSDT_ObservedDuringReplace
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	global _HSDT_ReplaceCritical
	_HSDT_ReplaceCalls += 1
	_HSDT_ReplaceCritical := A_IsCritical
	_HSDT_ObservedDuringReplace.Push({
		Word: _HotstringsWordDelimiters,
		Consumed: _HotstringsConsumedDelimiters,
		EngineWord: HSE_WORD_TERMINATORS,
		EngineConsumed: HSE_CONSUMED_DELIMITERS
	})
	return 1
}

_HSDT_Notify(*) {
	global _HSDT_NotifyCalls, _HSDT_NotifyCritical
	_HSDT_NotifyCalls += 1
	_HSDT_NotifyCritical := A_IsCritical
	return 1
}

_HSDT_FalseDelaySetter(*) {
	return 0
}

_HSDT_StringDelaySetter(*) {
	return "1"
}

_HSDT_TrueDelaySetter(*) {
	global _HSDT_SetterCritical
	_HSDT_SetterCritical := A_IsCritical
	return 1
}

_HSDT_Rebuild() {
	global _HSDT_RebuildCalls, _HSDT_RebuildCritical
	_HSDT_RebuildCalls += 1
	_HSDT_RebuildCritical := A_IsCritical
	return 1
}

_HSDT_RefusingRebuild() {
	global _HSDT_RebuildCalls
	_HSDT_RebuildCalls += 1
	return 0
}





; ===========================================
; ===========================================
; ======= 2/ Global barrier admission =======
; ===========================================
; ===========================================

_HSDT_UnrelatedTerminalRefusesBeforeBuilderAndMenuEffects() {
	global _HSDT_BuildCalls, _HSDT_WriteCalls, _HSDT_ReplaceCalls
	global _HSDT_NotifyCalls
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Saved := _HSDT_SaveState()
	Bundle := false
	try {
		_HSDT_Seed("terminal")
		Bundle := _ConfigWriteTerminalTryAcquire(
			[A_Temp . "\ergopti_hs_unrelated_terminal.toml"])
		AssertTrue(Bundle is Object)

		AssertFalse(HotstringsCommitDelimiterUpdate(_HSDT_CountingBuilder,
			_HSDT_AcceptWriter, _HSDT_AcceptReplace))
		AssertEqual(0, _HSDT_BuildCalls,
			"terminal refusal must precede candidate construction")
		AssertEqual(0, _HSDT_WriteCalls)
		AssertEqual(0, _HSDT_ReplaceCalls)

		AssertFalse(_HS_DelimAddCustomCommit("Z", true,
			_HSDT_AcceptWriter, _HSDT_AcceptReplace, _HSDT_Notify))
		AssertEqual(0, _HSDT_WriteCalls,
			"a refused menu action must never reach durable I/O")
		AssertEqual(0, _HSDT_NotifyCalls,
			"a refused menu action must not display the success notice")
		AssertEqual("A", _HotstringsWordDelimiters)
		AssertEqual("A", _HotstringsConsumedDelimiters)
		AssertEqual("A", HSE_WORD_TERMINATORS)
		AssertEqual("A", HSE_CONSUMED_DELIMITERS)
	} finally {
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		_HSDT_Restore(Saved)
	}
}
Test("hotstring-delimiter-global-transaction-20260813: unrelated terminal "
	. "refuses before builder, writer, live state and success notice",
	_HSDT_UnrelatedTerminalRefusesBeforeBuilderAndMenuEffects)





; ========================================
; ========================================
; ======= 3/ Strict durable result =======
; ========================================
; ========================================

_HSDT_FalseAndStringWritersPublishNothing() {
	global _HSDT_WriteCalls, _HSDT_ReplaceCalls, _HSDT_NotifyCalls
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Saved := _HSDT_SaveState()
	try {
		_HSDT_Seed("refused")
		AssertFalse(_HS_DelimAddCustomCommit("Z", true,
			_HSDT_FalseWriter, _HSDT_AcceptReplace, _HSDT_Notify))
		AssertEqual(1, _HSDT_WriteCalls)
		AssertEqual(0, _HSDT_ReplaceCalls)
		AssertEqual(0, _HSDT_NotifyCalls)
		AssertEqual("A", _HotstringsWordDelimiters)
		AssertEqual("A", _HotstringsConsumedDelimiters)
		AssertEqual("A", HSE_WORD_TERMINATORS)
		AssertEqual("A", HSE_CONSUMED_DELIMITERS)

		_HSDT_ResetFakes()
		AssertFalse(_HS_DelimAddCustomCommit("Z", true,
			_HSDT_StringWriter, _HSDT_AcceptReplace, _HSDT_Notify),
			"a string that looks truthy must not satisfy the writer contract")
		AssertEqual(1, _HSDT_WriteCalls)
		AssertEqual(0, _HSDT_ReplaceCalls)
		AssertEqual(0, _HSDT_NotifyCalls)
		AssertEqual("A", _HotstringsWordDelimiters)
		AssertEqual("A", _HotstringsConsumedDelimiters)
		AssertEqual("A", HSE_WORD_TERMINATORS)
		AssertEqual("A", HSE_CONSUMED_DELIMITERS)
	} finally _HSDT_Restore(Saved)
}
Test("hotstring-delimiter-global-transaction-20260813: false and string writers "
	. "leave disk publication, live state and success notice untouched",
	_HSDT_FalseAndStringWritersPublishNothing)

_HSDT_RevalidatesExactTargetAfterStage() {
	global _HSDT_BuildCalls, _HSDT_WriteCalls, _HSDT_ReplaceCalls
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Saved := _HSDT_SaveState()
	try {
		_HSDT_Seed("revalidate")
		AssertFalse(HotstringsCommitDelimiterUpdate(_HSDT_CountingBuilder,
			_HSDT_RebaseWriter, _HSDT_AcceptReplace))
		AssertEqual(1, _HSDT_BuildCalls)
		AssertEqual(1, _HSDT_WriteCalls,
			"the revalidation probe must reach the complete-stage boundary")
		AssertEqual(0, _HSDT_ReplaceCalls,
			"a path rebase during the yielded stage write must refuse before rename")
		AssertEqual("A", _HotstringsWordDelimiters)
		AssertEqual("A", _HotstringsConsumedDelimiters)
		AssertEqual("A", HSE_WORD_TERMINATORS)
		AssertEqual("A", HSE_CONSUMED_DELIMITERS)
	} finally _HSDT_Restore(Saved)
}
Test("hotstring-delimiter-global-transaction-20260813: exact owner and target "
	. "are revalidated after staging and before atomic replacement",
	_HSDT_RevalidatesExactTargetAfterStage)





; ===============================================
; ===============================================
; ======= 4/ One-write paired publication =======
; ===============================================
; ===============================================

_HSDT_PairedMenuActionWritesOnceThenPublishesBoth() {
	global _HSDT_WriteCalls, _HSDT_ReplaceCalls, _HSDT_NotifyCalls
	global _HSDT_StagePaths, _HSDT_WrittenContents
	global _HSDT_ObservedDuringWrite, _HSDT_ObservedDuringReplace
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Saved := _HSDT_SaveState()
	try {
		_HSDT_Seed("paired")
		AssertTrue(_HS_DelimAddCustomCommit("Z", true,
			_HSDT_AcceptWriter, _HSDT_AcceptReplace, _HSDT_Notify))
		AssertEqual(1, _HSDT_WriteCalls,
			"adding one consumed custom delimiter must serialize one whole-file candidate")
		AssertEqual(1, _HSDT_ReplaceCalls)
		AssertEqual(1, _HSDT_NotifyCalls)
		AssertEqual("A", _HSDT_ObservedDuringWrite[1].Word)
		AssertEqual("A", _HSDT_ObservedDuringWrite[1].Consumed)
		AssertEqual("A", _HSDT_ObservedDuringWrite[1].EngineWord)
		AssertEqual("A", _HSDT_ObservedDuringWrite[1].EngineConsumed)
		AssertEqual("A", _HSDT_ObservedDuringReplace[1].Word,
			"live caches must remain old through atomic replacement")
		AssertEqual("A", _HSDT_ObservedDuringReplace[1].Consumed)
		Assert(InStr(_HSDT_WrittenContents[1], 'word_delimiters = "AZ"') > 0)
		Assert(InStr(_HSDT_WrittenContents[1], 'consumed_delimiters = "AZ"') > 0)
		AssertEqual("AZ", _HotstringsWordDelimiters)
		AssertEqual("AZ", _HotstringsConsumedDelimiters)
		AssertEqual("AZ", HSE_WORD_TERMINATORS)
		AssertEqual("AZ", HSE_CONSUMED_DELIMITERS)

		AssertTrue(_HS_DelimRemoveCustomCommit("Z",
			_HSDT_AcceptWriter, _HSDT_AcceptReplace, _HSDT_Notify))
		AssertEqual(2, _HSDT_WriteCalls,
			"removing both memberships must add exactly one writer call")
		AssertEqual(2, _HSDT_ReplaceCalls)
		Assert(_HSDT_StagePaths[1] != _HSDT_StagePaths[2],
			"consecutive delimiter transactions must never reuse a live stage path")
		AssertEqual("A", _HotstringsWordDelimiters)
		AssertEqual("A", _HotstringsConsumedDelimiters)
	} finally _HSDT_Restore(Saved)
}
Test("hotstring-delimiter-global-transaction-20260813: paired menu actions use "
	. "one unique stage and publish both sets only after replacement",
	_HSDT_PairedMenuActionWritesOnceThenPublishesBoth)





; ==============================================
; ==============================================
; ======= 5/ Delay menu failure ordering =======
; ==============================================
; ==============================================

_HSDT_DelayHelperRebuildsOnlyAfterStrictSuccess() {
	global _HSDT_RebuildCalls
	_HSDT_ResetFakes()
	AssertFalse(_HS_CommitDelayOverride("magickey", 0.5,
		_HSDT_FalseDelaySetter, _HSDT_Rebuild))
	AssertEqual(0, _HSDT_RebuildCalls,
		"a refused delay writer must not rebuild registered hotstrings")
	AssertFalse(_HS_CommitDelayOverride("magickey", 0.5,
		_HSDT_StringDelaySetter, _HSDT_Rebuild))
	AssertEqual(0, _HSDT_RebuildCalls,
		"a truthy string is not a successful delay transaction")
	AssertTrue(_HS_CommitDelayOverride("magickey", 0.5,
		_HSDT_TrueDelaySetter, _HSDT_Rebuild))
	AssertEqual(1, _HSDT_RebuildCalls)
	AssertFalse(_HS_CommitDelayOverride("magickey", 0.5,
		_HSDT_TrueDelaySetter, _HSDT_RefusingRebuild),
		"a durable delay with a refused live rebuild must surface failure")
	AssertEqual(2, _HSDT_RebuildCalls)
	_HSDT_ResetFakes()
}
Test("hotstring-delimiter-global-transaction-20260813: delay prompts rebuild "
	. "only after a strict successful persist",
	_HSDT_DelayHelperRebuildsOnlyAfterStrictSuccess)

_HSDT_InheritedCriticalCannotWrapAdaptersOrMenuEffects() {
	global _HSDT_WriterCritical, _HSDT_ReplaceCritical
	global _HSDT_NotifyCritical, _HSDT_SetterCritical
	global _HSDT_RebuildCritical
	Saved := _HSDT_SaveState()
	try {
		_HSDT_Seed("critical")
		PreviousCritical := Critical("On")
		try {
			AssertTrue(_HS_DelimAddCustomCommit("Z", true,
				_HSDT_AcceptWriter, _HSDT_AcceptReplace, _HSDT_Notify))
			AssertTrue(A_IsCritical,
				"the delimiter action must restore its caller's Critical state")
		} finally Critical(PreviousCritical)
		AssertEqual(0, _HSDT_WriterCritical,
			"override staging must remain interruptible")
		AssertEqual(0, _HSDT_ReplaceCritical,
			"atomic filesystem replacement must remain interruptible")
		AssertEqual(0, _HSDT_NotifyCritical,
			"tray feedback must never inherit caller Critical")

		_HSDT_ResetFakes()
		PreviousCritical := Critical("On")
		try {
			AssertTrue(_HS_CommitDelayOverride("magickey", 0.5,
				_HSDT_TrueDelaySetter, _HSDT_Rebuild))
			AssertTrue(A_IsCritical,
				"the delay action must restore its caller's Critical state")
		} finally Critical(PreviousCritical)
		AssertEqual(0, _HSDT_SetterCritical,
			"the persistence gateway must be called outside caller Critical")
		AssertEqual(0, _HSDT_RebuildCritical,
			"live hotstring registration must remain interruptible")
	} finally _HSDT_Restore(Saved)
}
Test("hotstring-delimiter-global-transaction-20260813: inherited Critical "
	. "cannot wrap disk adapters notifications or live rebuild "
	. "(hotstring-delimiter-inherited-critical)",
	_HSDT_InheritedCriticalCannotWrapAdaptersOrMenuEffects)
