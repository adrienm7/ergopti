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





; ========================================
; ========================================
; ======= 7/ Personal preservation =======
; ========================================
; ========================================

_HSDT_RestorePersonalVectors() {
	global _SharedDir
	Vectors := JsonParse(FSReadUtf8Exact(_SharedDir .
		"\tests\corpus\hotstrings\terminator_restoration_vectors.json"))
	AssertEqual(4, Vectors.Length, "every independent preservation vector executes")
	for Vector in Vectors {
		Result := HSE_TerminatorRestoreDefaults(Vector["current_word"], Vector["current_consumed"])
		AssertEqual(Vector["expected_word"], Result.Word, Vector["id"])
		AssertEqual(Vector["expected_consumed"], Result.Consumed, Vector["id"])
		Again := HSE_TerminatorRestoreDefaults(Result.Word, Result.Consumed)
		AssertEqual(Result.Word, Again.Word, "restoration is idempotent: " . Vector["id"])
		AssertEqual(Result.Consumed, Again.Consumed, "consumption is idempotent: " . Vector["id"])
	}
	; A case-sensitive trigger ownership must not remove the other letter.
	Catalogue := [Map("chars", ["a"], "default_enabled", true, "consume", true)]
	Result := HotstringsTerminatorRestore(Catalogue, "Aa😀😃", "Aa")
	AssertEqual("aA😀😃", Result.Word)
	AssertEqual("aA", Result.Consumed)
}
Test("hotstring delimiters: shared restoration vectors preserve Unicode and personal states", _HSDT_RestorePersonalVectors)

_HSDT_ResetRetainsPersonalAndRefusesAtomically() {
	global _HSDT_WriteCalls, _HSDT_ReplaceCalls, _HSDT_NotifyCalls
	global _HSDT_ObservedDuringWrite, _HSDT_ObservedDuringReplace
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Saved := _HSDT_SaveState()
	try {
		_HSDT_Seed("restore-personal", "/¤😀😃😀", "/¤🔒")
		AssertFalse(_HS_DelimReset(_HSDT_FalseWriter, _HSDT_AcceptReplace, _HSDT_Notify))
		AssertEqual("/¤😀😃😀", _HotstringsWordDelimiters)
		AssertEqual("/¤🔒", _HotstringsConsumedDelimiters)
		AssertEqual("/¤😀😃😀", HSE_WORD_TERMINATORS)
		AssertEqual("/¤🔒", HSE_CONSUMED_DELIMITERS)
		AssertEqual(0, _HSDT_ReplaceCalls)
		AssertEqual(0, _HSDT_NotifyCalls)
		_HSDT_ResetFakes()
		AssertTrue(_HS_DelimReset(_HSDT_AcceptWriter, _HSDT_AcceptReplace, _HSDT_Notify))
		AssertEqual(" `t`r`n★,;.!?:¤😀😃😀", _HotstringsWordDelimiters)
		AssertEqual("★¤🔒", _HotstringsConsumedDelimiters)
		AssertEqual(_HotstringsWordDelimiters, HSE_WORD_TERMINATORS)
		AssertEqual(_HotstringsConsumedDelimiters, HSE_CONSUMED_DELIMITERS)
		AssertEqual(1, _HSDT_WriteCalls, "the pair uses one admitted candidate")
		AssertEqual(1, _HSDT_ReplaceCalls)
		AssertEqual(1, _HSDT_NotifyCalls)
		AssertEqual("/¤😀😃😀", _HSDT_ObservedDuringWrite[1].Word)
		AssertEqual("/¤🔒", _HSDT_ObservedDuringReplace[1].Consumed)
	} finally _HSDT_Restore(Saved)
}
Test("hotstring delimiters: tray restore retains personal strings and refuses without half publication",
	_HSDT_ResetRetainsPersonalAndRefusesAtomically)





; ================================================
; ================================================
; ======= 8/ Shared word-expander commands =======
; ================================================
; ================================================

_HSDT_ControlCorpus() {
	global _SharedDir
	return JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\word_expander_controls.json"))
}

_HSDT_ControlSetAll(Enable, Writer, *) {
	return _HS_DelimSetAll(Enable, Writer, _HSDT_AcceptReplace, _HSDT_Notify)
}

_HSDT_ControlRestore(Writer, *) {
	return _HS_DelimReset(Writer, _HSDT_AcceptReplace, _HSDT_Notify)
}

_HSDT_ControlCommands(Writer) {
	return Map(
		"word_expanders_enable_all", _HSDT_ControlSetAll.Bind(true, Writer),
		"word_expanders_disable_all", _HSDT_ControlSetAll.Bind(false, Writer),
		"word_expanders_restore", _HSDT_ControlRestore.Bind(Writer))
}

_HSDT_NativeControlMenu(Writer) {
	return _HS_WordExpanderRows(_HSDT_ControlCommands(Writer))[1]["submenu"]
}

_HSDT_NativeControlCallback(Built, Position) {
	global _MenuDispatchCallbacks
	Id := DllCall("GetMenuItemID", "ptr", Built.Handle, "int", Position, "uint")
	Assert(_MenuDispatchCallbacks.Has(Id), "the declared control uses the actual native dispatcher")
	return _MenuDispatchCallbacks[Id]
}

_HSDT_SharedControlMatrix() {
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Corpus := _HSDT_ControlCorpus()
	AssertEqual(3, Corpus["rows"].Length, "every independent control must execute")
	Modes := ["enable_all", "disable_all", "restore"]
	Saved := _HSDT_SaveState()
	try {
		for Index, Expected in Corpus["rows"] {
			_HSDT_Seed("shared-control-" . Index, "/¤😀", "¤🔒")
			Built := _HSDT_NativeControlMenu(_HSDT_AcceptWriter)
			try {
				for Position, Row in Corpus["rows"] {
					AssertEqual(t(Row["i18n"]), _CTC_LabelAt(Built, Position - 1))
					AssertFalse(_CTC_IsChecked(Built, Position - 1), "a bulk command is not a switch")
				}
				Callback := _HSDT_NativeControlCallback(Built, Index - 1)
				AssertTrue(Callback.Call(), "the actual owned delimiter transaction must acknowledge")
				State := Corpus["delimiter_states"][Modes[Index]]
				AssertEqual(State["space"], InStr(_HotstringsWordDelimiters, " ") > 0)
				AssertEqual(State["slash"], InStr(_HotstringsWordDelimiters, "/") > 0)
				AssertEqual(State["custom_x"], InStr(_HotstringsWordDelimiters, "x") > 0)
				AssertTrue(InStr(_HotstringsWordDelimiters, "¤😀") > 0, "personal delimiters survive")
				AssertTrue(InStr(_HotstringsConsumedDelimiters, "¤🔒") > 0, "personal consumption survives")
				AssertEqual(_HotstringsWordDelimiters, HSE_WORD_TERMINATORS)
				AssertEqual(_HotstringsConsumedDelimiters, HSE_CONSUMED_DELIMITERS)
			} finally _CTC_ReleaseMenu(Built)
		}
	} finally _HSDT_Restore(Saved)
}
Test("word expanders: shared native controls replay the independent state corpus", _HSDT_SharedControlMatrix)

_HSDT_SharedControlOrderAndRefusal() {
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global _HSDT_WriteCalls, _HSDT_ReplaceCalls, _HSDT_NotifyCalls
	Definitions := _MR_GetManifestRoot()["word_expanders_menu"]
	SavedDefinitions := Definitions.Clone()
	Corpus := _HSDT_ControlCorpus()
	Saved := _HSDT_SaveState()
	try {
		Definitions[1] := SavedDefinitions[3]
		Definitions[3] := SavedDefinitions[1]
		_HSDT_Seed("shared-control-refusal", "/¤😀", "¤🔒")
		Built := _HSDT_NativeControlMenu(_HSDT_FalseWriter)
		try {
			AssertEqual(t(Corpus["rows"][3]["i18n"]), _CTC_LabelAt(Built, 0))
			AssertEqual(t(Corpus["rows"][2]["i18n"]), _CTC_LabelAt(Built, 1))
			AssertEqual(t(Corpus["rows"][1]["i18n"]), _CTC_LabelAt(Built, 2))
			Callback := _HSDT_NativeControlCallback(Built, 0)
			AssertFalse(Callback.Call(), "the reordered restore must retain the real writer refusal")
			AssertEqual("/¤😀", _HotstringsWordDelimiters)
			AssertEqual("¤🔒", _HotstringsConsumedDelimiters)
			AssertEqual(1, _HSDT_WriteCalls)
			AssertEqual(0, _HSDT_ReplaceCalls)
			AssertEqual(0, _HSDT_NotifyCalls)
		} finally _CTC_ReleaseMenu(Built)
	} finally {
		for Index, Row in SavedDefinitions
			Definitions[Index] := Row
		_HSDT_Restore(Saved)
	}
}
Test("word expanders: shared ordering retains the actual native owner refusal", _HSDT_SharedControlOrderAndRefusal)


_HSDT_SharedControlRefusesDelayedPause() {
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global _HSDT_WriteCalls, _HSDT_ReplaceCalls, _HSDT_NotifyCalls
	Saved := _HSDT_SaveState()
	WasSuspended := A_IsSuspended
	Built := 0
	try {
		Suspend(false)
		_HSDT_Seed("shared-control-delayed-pause", "/¤😀", "¤🔒")
		Built := _HSDT_NativeControlMenu(_HSDT_AcceptWriter)
		Callbacks := []
		loop 3
			Callbacks.Push(_HSDT_NativeControlCallback(Built, A_Index - 1))
		Suspend(true)
		Receipts := []
		for Callback in Callbacks
			Receipts.Push(Callback.Call())
		AssertEqual(3, Receipts.Length, "every captured control must refuse actual suspended delivery")
		AssertEqual(0, _HSDT_WriteCalls)
		AssertEqual(0, _HSDT_ReplaceCalls)
		AssertEqual(0, _HSDT_NotifyCalls)
		AssertEqual("/¤😀", _HotstringsWordDelimiters)
		AssertEqual("¤🔒", _HotstringsConsumedDelimiters)
		for Receipt in Receipts
			AssertFalse(Receipt, "the current readiness owner refuses before the durable owner")
	} finally {
		Suspend(WasSuspended)
		if Built is Menu
			_CTC_ReleaseMenu(Built)
		_HSDT_Restore(Saved)
	}
}
Test("word expanders: shared native controls refuse delayed delivery after pause", _HSDT_SharedControlRefusesDelayedPause)


_HSDT_CustomDeleteCorpus() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\menus\word_expander_custom_controls.json"
	Corpus := JsonParse(FSReadUtf8Exact(Path))
	Assert(Corpus is Map, "the independent custom-delimiter corpus must be readable")
	AssertEqual(1, Corpus["rows"].Length)
	return Corpus
}

_HSDT_DeclaredCustomDeleteReceipts() {
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global _HSDT_WriteCalls, _HSDT_ReplaceCalls, _HSDT_NotifyCalls
	Corpus := _HSDT_CustomDeleteCorpus()
	Saved := _HSDT_SaveState()
	try {
		for Mode in ["ack", "refused", "paused"] {
			_HSDT_Seed("declared-custom-delete-" . Mode,
				Corpus["native_membership"]["before"], Corpus["native_membership"]["before"])
			Seen := Map("ready", true)
			Expected := Corpus["rows"][1]
			Writer := Mode == "refused" ? _HSDT_FalseWriter : _HSDT_AcceptWriter
			Command := _HS_DelimRemoveCustomCommit.Bind(Corpus["target"]["char"], Writer,
				_HSDT_AcceptReplace, _HSDT_Notify)
			Row := MenuRenderer_CommandRow(Corpus["section"], Expected["id"],
				Map(Expected["id"], Command), Map(Expected["ready"], (*) => Seen["ready"]))
			Assert(Row is Map, "the declared provider supplies the actual native row")
			AssertEqual(t(Expected["i18n"]), Row["label"])
			if Mode == "paused"
				Seen["ready"] := false
			; Native callbacks collect through the real delimiter transaction;
			; assertions follow delivery and any production-caught refusal.
			Committed := Row["action"].Call()
			AssertEqual(Mode == "ack", Committed)
			AssertEqual(Mode == "ack" ? Corpus["native_membership"]["ack"]
				: Corpus["native_membership"]["refused"], _HotstringsWordDelimiters)
			AssertEqual(_HotstringsWordDelimiters, _HotstringsConsumedDelimiters)
			AssertEqual(Mode == "paused" ? 0 : 1, _HSDT_WriteCalls)
			AssertEqual(Mode == "ack" ? 1 : 0, _HSDT_ReplaceCalls)
			AssertEqual(Mode == "ack" ? 1 : 0, _HSDT_NotifyCalls)
		}
	} finally _HSDT_Restore(Saved)
}
Test("custom word expanders: declared Delete retains native ACK, refusal and delayed pause",
	_HSDT_DeclaredCustomDeleteReceipts)

_HSDT_CustomProviderOwnsDeclaredDelete() {
	Body := _DriverFuncBody("_HS_WordExpanderRows")
	Assert(Body != "", "the actual custom-delimiter provider must exist")
	Assert(InStr(Body, 'MenuRenderer_CommandRow("word_expander_custom_menu", "word_expander_delete"'))
	Assert(InStr(Body, "_HS_DelimRemoveCustom(C)"), "the shared row retains its captured native target owner")
	AssertFalse(InStr(Body, 't("menu.hotstrings.delete_delimiter")'),
		"a native fixed label cannot override the canonical command declaration")
}
Test("custom word expanders: actual provider consumes its shared Delete declaration",
	_HSDT_CustomProviderOwnsDeclaredDelete)
