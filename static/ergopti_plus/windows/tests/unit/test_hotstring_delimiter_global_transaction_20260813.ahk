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


_HSDT_CustomAddCorpus() {
	global _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\word_expander_add_controls.json"))
	Assert(Corpus is Map, "the independent Add command corpus must be readable")
	return Corpus
}

_HSDT_DeclaredCustomAddReceipts() {
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global _HSDT_WriteCalls, _HSDT_ReplaceCalls, _HSDT_NotifyCalls
	Corpus := _HSDT_CustomAddCorpus()
	Saved := _HSDT_SaveState()
	try {
		for Mode in ["ack", "refused", "paused"] {
			_HSDT_Seed("declared-custom-add-" . Mode)
			Ready := Map("value", true)
			Writer := Mode == "refused" ? _HSDT_FalseWriter : _HSDT_AcceptWriter
			Command := _HS_DelimAddCustomCommit.Bind(Corpus["target"]["char"], true,
				Writer, _HSDT_AcceptReplace, _HSDT_Notify)
			Row := MenuRenderer_CommandRow(Corpus["section"], Corpus["id"],
				Map(Corpus["id"], Command), Map(Corpus["ready"], (*) => Ready["value"]))
			Assert(Row is Map, "the Add declaration supplies an actual native command row")
			AssertEqual(t(Corpus["i18n"]), Row["label"])
			if Mode == "paused"
				Ready["value"] := false
			Committed := Row["action"].Call()
			AssertEqual(Mode == "ack", Committed)
			AssertEqual(Mode == "ack" ? "A" . Corpus["target"]["char"] : "A", _HotstringsWordDelimiters)
			AssertEqual(_HotstringsWordDelimiters, _HotstringsConsumedDelimiters)
			AssertEqual(Mode == "paused" ? 0 : 1, _HSDT_WriteCalls)
			AssertEqual(Mode == "ack" ? 1 : 0, _HSDT_ReplaceCalls)
			AssertEqual(Mode == "ack" ? 1 : 0, _HSDT_NotifyCalls)
		}
	} finally _HSDT_Restore(Saved)
}
Test("custom word expanders: declared Add retains native ACK, refusal and held pause",
	_HSDT_DeclaredCustomAddReceipts)

_HSDT_PausedNativeAddOpensNoDialog() {
	global _HS_DelimAddGui, _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	Entry := _DriverFuncBody("_HS_DelimAddCustom")
	Assert(Entry != "", "the actual modal owner must exist before native delivery")
	PauseGatePosition := RegExMatch(Entry, "m)^\s*if A_IsSuspended\s*$")
	FirstGui := InStr(Entry, "if IsObject(_HS_DelimAddGui)")
	Assert(PauseGatePosition > 0 && FirstGui > PauseGatePosition,
		"the exact early native admission must precede any existing-dialog access")
	Assert(InStr(Entry, "Gui_Create") > PauseGatePosition,
		"the native owner must refuse before constructing a dialog")
	Saved := _HSDT_SaveState()
	WasSuspended := A_IsSuspended
	PreviousGui := _HS_DelimAddGui
	try {
		_HSDT_Seed("paused-native-add")
		Suspend(true)
		Result := _HS_DelimAddCustom()
		Observed := Map("result", Result, "gui", _HS_DelimAddGui,
			"word", _HotstringsWordDelimiters, "consumed", _HotstringsConsumedDelimiters)
	} finally {
		Suspend(WasSuspended)
		_HSDT_Restore(Saved)
	}
	AssertFalse(Observed["result"])
	AssertEqual(PreviousGui, Observed["gui"], "the paused native owner must not create, present or retire a dialog")
	AssertEqual("A", Observed["word"])
	AssertEqual("A", Observed["consumed"])
	AssertEqual(WasSuspended, A_IsSuspended, "the actual native suspension owner is restored exactly")
}
Test("custom word expanders: actual suspended Add entry keeps its native dialog owner inert",
	_HSDT_PausedNativeAddOpensNoDialog)

_HSDT_CustomAddProviderKeepsPostModalAdmission() {
	Provider := _DriverFuncBody("_HS_WordExpanderRows")
	Owner := _DriverFuncBody("_HS_DelimAddCustom")
	RecordCommit := _DriverFuncBody("_HS_DelimAddRecordCommit")
	StringCommit := _DriverFuncBody("_HS_DelimAddCustomCommit")
	Assert(Provider != "" && Owner != "" && RecordCommit != "" && StringCommit != "",
		"the provider, modal owner and both distinct commit owners must exist")
	Assert(InStr(Provider, 'MenuRenderer_CommandRow("word_expander_custom_menu", "word_expander_add"'))
	AssertFalse(InStr(Provider, 'Map("label", t("menu.hotstrings.add_delimiter")'),
		"the native provider must not replace the canonical Add label")
	_HSDT_AssertPostModalRecordAdmission(Owner)
	RecordCode := _DriverMaskNonCode(&RecordCommit)
	Assert(InStr(RecordCode, "HotstringsTerminatorRecordCharacter(Char)")
		&& InStr(RecordCode, "Consume is Integer") && InStr(RecordCode, "A_IsSuspended"),
		"the typed commit must retain scalar, consume-type and suspension admission")
	AssertEqual(1, _HSDT_PostModalCodeCount(RecordCode, "\bHotstringsTerminatorRecordsEdit\("),
		"the typed commit must acquire exactly one actual record transaction")
	StringCode := _DriverMaskNonCode(&StringCommit)
	AssertEqual(1, _HSDT_PostModalCodeCount(StringCode, "\b_HS_DelimCommit\("),
		"historical anonymous strings must retain their distinct transaction owner")
	ClosePosition := InStr(Owner, 'finally _HS_DelimAddGui := ""')
	Assert(ClosePosition > 0, "the real close receipt must exist before deriving mutations")
	ModalPrefix := SubStr(Owner, 1, ClosePosition - 1)
	ModalTail := SubStr(Owner, ClosePosition)
	LatePause := "`tif A_IsSuspended`n`t`treturn false`n"
	NoLatePause := ModalPrefix . StrReplace(ModalTail, LatePause, "", true, &PauseReplacements, 1)
	AssertEqual(1, PauseReplacements, "the mutant removes only the actual post-close pause gate")
	_HSDT_ExpectPostModalRefusal(NoLatePause,
		"a completed native dialog must recheck its actual pause owner before acquiring the transaction")
	Cancel := '`tif (!Result.OK or Result.Char == "") {`n`t`treturn false`n`t}`n'
	NoCancel := StrReplace(Owner, Cancel, "", true, &CancelReplacements, 1)
	AssertEqual(1, CancelReplacements, "the mutant removes only the actual cancelled-result gate")
	_HSDT_ExpectPostModalRefusal(NoCancel, "cancelled and empty native results must remain unpublished")
	TypedCall := "return _HS_DelimAddRecordCommit(Result.Char, Result.Consume)"
	LegacyCall := "return _HS_DelimAddCustomCommit(Result.Char, Result.Consume)"
	WrongOwner := StrReplace(Owner, TypedCall, LegacyCall, true, &CommitReplacements, 1)
	AssertEqual(1, CommitReplacements, "the mutant redirects the actual typed transaction once")
	_HSDT_ExpectPostModalRefusal(WrongOwner, "the modal result must acquire exactly one typed record owner")
	CommentOnly := StrReplace(Owner, TypedCall, "; " . TypedCall, true, &CommentReplacements, 1)
	AssertEqual(1, CommentReplacements, "the comment mutant removes the only executable typed transaction")
	_HSDT_ExpectPostModalRefusal(CommentOnly, "the modal result must acquire exactly one typed record owner")
}

; Native close admission and its typed destination share one ordered source body.
; Code masking prevents prose or a removed call left in a comment from passing.
_HSDT_AssertPostModalRecordAdmission(ModalSource) {
	Assert(ModalSource != "", "the native modal owner must not be empty")
	ModalCode := _DriverMaskNonCode(&ModalSource)
	ClosePattern := "m)^[ `t]*finally[ `t]+_HS_DelimAddGui[ `t]*:=[ `t]*$"
	CommitPattern := "m)^[ `t]*return _HS_DelimAddRecordCommit\(Result\.Char, Result\.Consume\)[ `t]*$"
	AssertEqual(1, _HSDT_PostModalCodeCount(ModalCode, ClosePattern),
		"the native dialog must have one actual close receipt")
	Assert(_HSDT_PostModalCodeCount(ModalCode, CommitPattern) == 1,
		"the modal result must acquire exactly one typed record owner")
	ClosePosition := RegExMatch(ModalCode, ClosePattern)
	CommitPosition := RegExMatch(ModalCode, CommitPattern)
	PausePosition := RegExMatch(ModalCode,
		"m)^[ `t]*if A_IsSuspended[ `t]*`n[ `t]*return false[ `t]*$",, ClosePosition)
	Assert(ClosePosition > 0 && PausePosition > ClosePosition && CommitPosition > PausePosition,
		"a completed native dialog must recheck its actual pause owner before acquiring the transaction")
	CancelPosition := RegExMatch(ModalCode,
		"m)^[ `t]*if \(!Result\.OK or Result\.Char ==[ `t]*\) \{[ `t]*`n[ `t]*return false[ `t]*`n[ `t]*\}")
	Assert(CancelPosition > PausePosition && CommitPosition > CancelPosition,
		"cancelled and empty native results must remain unpublished")
	AssertFalse(InStr(ModalCode, "_HS_DelimAddCustomCommit("),
		"the native record dialog must not publish an anonymous delimiter string")
}

_HSDT_PostModalCodeCount(ModalCode, Pattern) {
	RegExReplace(ModalCode, Pattern, "", &ModalMatches)
	return ModalMatches
}

_HSDT_ExpectPostModalRefusal(ModalSource, ExpectedMessage) {
	try {
		_HSDT_AssertPostModalRecordAdmission(ModalSource)
	} catch as Refusal {
		AssertEqual(ExpectedMessage, Refusal.Message,
			"the actual source mutation must fail at its independent admission assertion")
		return
	}
	Assert(false, "the weakened native modal source must be refused")
}
Test("custom word expanders: actual Add dialog rechecks admission after its native close receipt",
	_HSDT_CustomAddProviderKeepsPostModalAdmission)


_HSDT_DeclaredDelayConfigCommand() {
	global _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\delays_settings_command.json"))
	Assert(Corpus is Map)
	Root := _MR_GetManifestRoot()
	Rows := Root[Corpus["section"]]
	OriginalLabel := Rows[1]["i18n"]
	Observations := Map("opens", 0)
	try {
		Rows[1]["i18n"] := "button.ok"
		Provider := _HS_DelaysColorsRows(_HSDT_ObserveDelayWindow.Bind(Observations))
		Items := Provider[1]["items"]
		AssertEqual(t("button.ok"), Items[1]["label"], "the actual provider owns no fixed command label")
		AssertEqual(true, Items[2]["separator"])
		AssertEqual(8, Items.Length, "the five variable quick-delay rows and separators remain in place")
		Items[1]["action"].Call("native_menu_label", 1, 0)
		AssertEqual(1, Observations["opens"])
	} finally Rows[1]["i18n"] := OriginalLabel
	AssertEqual(OriginalLabel, Rows[1]["i18n"], "the actual shared definition is restored")
}

_HSDT_ObserveDelayWindow(Observations) {
	Observations["opens"] += 1
}
Test("hotstrings delay settings: actual provider consumes its declared command and native window owner",
	_HSDT_DeclaredDelayConfigCommand)

_HSDT_DelayConfigKeepsNativeWindowAndRefreshOwner() {
	Body := _DriverFuncBody("_HS_DelaysColorsRows")
	Assert(Body != "", "the actual delay provider must exist")
	Assert(InStr(Body, 'MenuRenderer_CommandRow("hotstrings_delays_menu", "hotstrings_config_window"'))
	AssertFalse(InStr(Body, 't("menu.hotstrings.config_item")'))
	Source := Body
	Assert(Source != "", "the central driver locator must provide the actual provider signature")
	Assert(InStr(Source, "_HS_DelaysColorsRows(OpenConfigFn := OpenHotstringsConfigWindow)"),
		"ordinary calls retain the existing native singleton window owner")
}
Test("hotstrings delay settings: ordinary entry keeps the existing native config window",
	_HSDT_DelayConfigKeepsNativeWindowAndRefreshOwner)


_HSDT_ColoredPreviewDeclaredCapability() {
	global _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\preview_colored_control.json"))
	Root := _MR_GetManifestRoot()
	Rows := Root[Corpus["section"]]
	AssertEqual(1, Rows.Length)
	Row := Rows[1]
	for Key in ["id", "type", "i18n", "unavailable", "reason_key"]
		AssertEqual(Corpus["row"][Key], Row[Key])
	for Key in ["checked_when", "disabled_when", "platforms"] {
		AssertEqual(Corpus["row"][Key].Length, Row[Key].Length)
		for Index, Value in Corpus["row"][Key]
			AssertEqual(Value, Row[Key][Index])
	}
	AssertFalse(_MR_IsForAhk(Row), "Windows must not publish a Lua preview mutation owner")
	AssertEqual("grey", Row["unavailable"])
	Assert(t(Row["reason_key"]) != Row["reason_key"], "the native unavailable reason is translated")
}
Test("preview coloured checkbox: shared declaration keeps Windows capability truthful",
	_HSDT_ColoredPreviewDeclaredCapability)


Test("Magic preview: shared checkbox remains truthfully unavailable on Windows", _HSDT_DeclaredMagicPreviewUnavailable)

_HSDT_DeclaredMagicPreviewUnavailable() {
	global _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\preview_magic_control.json"))
	Definition := _MR_GetManifestRoot()[Corpus["section"]]
	AssertEqual(1, Definition.Length, "The presence command has one authoritative row.")
	Row := Definition[1]
	AssertEqual("check", Row["type"], "The shared declaration owns the checkbox type.")
	AssertEqual(Corpus["row"]["id"], Row["id"], "The real flag identity is preserved.")
	AssertEqual(Corpus["row"]["i18n"], Row["i18n"], "All platforms use the canonical existing key.")
	AssertEqual(Corpus["unavailable"]["mode"], Row["unavailable"], "Unsupported Windows previews remain grey.")
	AssertEqual(Corpus["unavailable"]["reason"], Row["reason_key"], "The actual Lua-only reason stays shared.")
	Called := Map("count", 0)
	Commands := Map(Row["id"], (*) => Called["count"] += 1)
	Getters := Map("hotstrings.preview_star_enabled", (*) => true, "preview_magic_ready", (*) => true)
	Native := MenuRenderer_CheckRow(Corpus["section"], Row["id"], Commands, Getters)
	AssertFalse(Native is Map, "The real provider refuses to acquire unsupported native work.")
	_HSDT_AssertDrawnUnsupportedPreview(Corpus["section"], 0, 1, Row,
		Corpus["unavailable"]["reason"], Commands, Getters, Called)
	AssertEqual(0, Called["count"], "Unsupported native work never executes.")
}


Test("Autocorrection and AI previews: shared ordered checkboxes preserve Windows capability", _HSDT_DeclaredPresencePreviewUnavailable)

_HSDT_DeclaredPresencePreviewUnavailable() {
	global _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\preview_presence_controls.json"))
	Definition := _MR_GetManifestRoot()[Corpus["section"]]
	AssertEqual(2, Definition.Length, "The two historical presence flags are declared together.")
	for Index, Row in Definition {
		Expected := Corpus["rows"][Index]
		for Key in ["id", "type", "i18n", "unavailable", "reason_key"]
			AssertEqual(Expected[Key], Row[Key], "The ordered checkbox identity and canonical caption stay shared.")
		for Key in ["checked_when", "disabled_when", "platforms"] {
			AssertEqual(Expected[Key].Length, Row[Key].Length)
			for ValueIndex, Value in Expected[Key]
				AssertEqual(Value, Row[Key][ValueIndex])
		}
		AssertFalse(_MR_IsForAhk(Row), "Windows still has no native preview bubble owner.")
		Called := Map("count", 0)
		Commands := Map(Row["id"], (*) => Called["count"] += 1)
		Getters := Map("hotstrings." . Row["id"], (*) => true, "preview_presence_ready", (*) => true)
		Native := MenuRenderer_CheckRow(Corpus["section"], Row["id"], Commands, Getters)
		AssertFalse(Native is Map, "Unsupported native work cannot be acquired.")
		_HSDT_AssertDrawnUnsupportedPreview(Corpus["section"], Index - 1, 2, Row,
			Expected["reason_key"], Commands, Getters, Called)
		AssertEqual(0, Called["count"], "Unsupported native work never executes.")
		Assert(t(Row["reason_key"]) != Row["reason_key"], "The existing capability reason is translated.")
	}
}

; Read the actual unsupported branch, which renders before command admission.
_HSDT_AssertDrawnUnsupportedPreview(Section, Position, Count, Row, Reason, Commands, Getters, Called) {
	global _MenuDispatchCallbacks
	Built := MenuRenderer_Build(Section, "Hotstrings", Map(), Map(), Map(), Commands, Getters)
	try {
		Assert(Built is Menu, "The public renderer supplies the actual grey stand-in menu.")
		AssertEqual(Count, TrayMenuItemCount(Built), "Every declared unsupported row is drawn exactly once.")
		ReasonText := t(Reason)
		Assert(ReasonText != Reason, "The actual capability reason is translated.")
		Head := Trim(RegExReplace(ReasonText, "[:：].*$", ""))
		Assert(Head != "", "The stand-in retains a nonempty translated reason.")
		ExpectedLabel := t(Row["i18n"]) . " — " . Head
		AssertEqual(ExpectedLabel, _HSDT_NativePreviewLabelAt(Built, Position),
			"The drawn caption includes the actual canonical label and translated reason.")
		Flags := DllCall("GetMenuState", "ptr", Built.Handle, "uint", Position, "uint", 0x400, "uint")
		Assert(Flags != 0xFFFFFFFF, "The actual native row must exist.")
		; GetMenuState packs submenu counts above the low byte; only native state flags belong here.
		Assert((Flags & 0xFF & 0x3) != 0, "The stand-in is natively disabled.")
		AssertEqual(0, DllCall("GetSubMenu", "ptr", Built.Handle, "int", Position, "ptr"),
			"The unsupported preview is a leaf, not a borrowed native submenu.")
		Id := DllCall("GetMenuItemID", "ptr", Built.Handle, "int", Position, "uint")
		Assert(Id != 0xFFFFFFFF, "The actual native leaf has an item identity.")
		AssertFalse(_MenuDispatchCallbacks.Has(Id), "The stand-in has no native mutation callback.")
		AssertEqual(0, Called["count"], "Drawing unsupported native work never executes its supplied command.")
	} finally {
		Built.Delete()
		MenuDispatcher_PruneMenu(Built)
	}
}

_HSDT_NativePreviewLabelAt(TargetMenu, Position) {
	Length := DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", 0, "int", 0, "uint", 0x400, "int")
	Assert(Length > 0, "The actual native caption must be nonempty.")
	Text := Buffer((Length + 1) * 2, 0)
	Read := DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", Text, "int", Length + 1, "uint", 0x400, "int")
	AssertEqual(Length, Read, "The native caption read must be complete.")
	return StrGet(Text, "UTF-16")
}

_HSDT_ObservePreviewCommand(Called, *) {
	Called["count"] += 1
}

_HSDT_NativePreviewCallbackPositiveControl() {
	global _MenuDispatchCallbacks
	Key := "_test_preview_native_callback_control"
	Root := _MR_GetManifestRoot()
	AssertFalse(Root.Has(Key), "The control owns a fresh temporary declaration.")
	Called := Map("count", 0)
	Root[Key] := [Map("type", "command", "id", "preview_control", "i18n", "button.ok")]
	Built := 0
	try {
		Built := MenuRenderer_Build(Key, "Hotstrings", Map(), Map(), Map(),
			Map("preview_control", _HSDT_ObservePreviewCommand.Bind(Called)), Map())
		AssertEqual(1, TrayMenuItemCount(Built))
		AssertEqual(t("button.ok"), _HSDT_NativePreviewLabelAt(Built, 0))
		Flags := DllCall("GetMenuState", "ptr", Built.Handle, "uint", 0, "uint", 0x400, "uint")
		Assert(Flags != 0xFFFFFFFF)
		AssertEqual(0, Flags & 0xFF & 0x3, "A supported control is natively enabled.")
		Id := DllCall("GetMenuItemID", "ptr", Built.Handle, "int", 0, "uint")
		Assert(_MenuDispatchCallbacks.Has(Id), "The positive control observes its actual native registration.")
		AssertEqual(0, Called["count"], "Rendering a supported control does not invoke it.")
		_MenuDispatchCallbacks[Id].Call()
		AssertEqual(1, Called["count"], "The real registered callback makes command effects observable.")
	} finally {
		Root.Delete(Key)
		if Built is Menu {
			Built.Delete()
			MenuDispatcher_PruneMenu(Built)
		}
	}
	AssertFalse(Root.Has(Key), "The original manifest is restored.")
}
Test("preview unavailable fixture: actual native callback and enabled-state positive control",
	_HSDT_NativePreviewCallbackPositiveControl)


_HSDT_ParameterFrameCaptionAuthority() {
	global _HSDT_WriteCalls
	Root := _MR_GetManifestRoot()
	Original := Root["hotstrings_delay_captions"]
	Saved := _HSDT_SaveState()
	try {
		_HSDT_Seed("parameter-caption-frame")
		Root["hotstrings_delay_captions"] := Map("default", "button.ok", "magic_key", "button.ok",
			"autocorrection", "button.ok", "ai_acceptance", "button.ok", "autocompletion", "button.ok")
		Rows := _HS_DelaysColorsRows(_HSDT_ObserveDelayWindow.Bind(Map("opens", 0)))
		Assert(Rows is Array && Rows.Length == 1, "the actual complete delay parent must be returned")
		AssertEqual(t("menu.hotstrings.delays_colors"), Rows[1]["label"])
		Items := Rows[1]["items"]
		AssertEqual(8, Items.Length)
		AssertEqual(t("menu.hotstrings.config_item"), Items[1]["label"])
		AssertEqual(true, Items[2]["separator"])
		AssertEqual(true, Items[6]["separator"])
		for Index in [3, 4, 5, 7, 8]
			AssertEqual(t("button.ok"), SubStr(Items[Index]["label"], 1, StrLen(t("button.ok"))))
		AssertEqual(0, _HSDT_WriteCalls, "rendering the complete frame performs no persistent callback")
		for Mode in ["missing", "foreign", "wrong_type", "wrong_case"] {
			Captions := Root["hotstrings_delay_captions"].Clone()
			if Mode == "missing"
				Captions.Delete("default")
			else if Mode == "foreign"
				Captions["unrelated"] := "button.ok"
			else if Mode == "wrong_case" {
				Captions := Map()
				Captions.CaseSense := "On"
				for Key, Value in Root["hotstrings_delay_captions"]
					Captions[Key == "default" ? "Default" : Key] := Value
			} else
				Captions["default"] := false
			Root["hotstrings_delay_captions"] := Captions
			AssertEqual(0, _HS_DelaysColorsRows().Length, "invalid named caption data refuses its native provider")
			Root["hotstrings_delay_captions"] := Map("default", "button.ok", "magic_key", "button.ok",
				"autocorrection", "button.ok", "ai_acceptance", "button.ok", "autocompletion", "button.ok")
		}
	} finally {
		Root["hotstrings_delay_captions"] := Original
		_HSDT_Restore(Saved)
	}
}
Test("hotstrings parameter frames: every caption field is current and malformed maps refuse",
	_HSDT_ParameterFrameCaptionAuthority)

_HSDT_ParameterFrameNativeMenuContract() {
	Root := _MR_GetManifestRoot()
	Saved := _HSDT_SaveState()
	Original := Root["hotstrings_word_expander_frame"]
	OwnedMenus := []
	try {
		_HSDT_Seed("parameter-native-word-frame")
		Rows := _HS_WordExpanderRows(_HSDT_ControlCommands(_HSDT_AcceptWriter))
		if Rows is Array {
			for Row in Rows {
				if Row is Map && Row.Has("submenu") && Row["submenu"] is Menu
					OwnedMenus.Push(Row["submenu"])
			}
		}
		Assert(Rows is Array && Rows.Length == 1)
		AssertEqual(t("menu.hotstrings.word_expanders"), Rows[1]["label"])
		Assert(Rows[1]["submenu"] is Menu, "the original native child Menu contract remains real")
		AssertFalse(Rows[1].Has("items"), "the existing native child is not duplicated as detached row data")
		Assert(DllCall("GetMenuItemCount", "Ptr", Rows[1]["submenu"].Handle, "Int") > 4,
			"the canonical controls and genuine catalogue have materialized into the Win32 child")
		Root.Delete("hotstrings_word_expander_frame")
		AssertEqual(0, _HS_WordExpanderRows(_HSDT_ControlCommands(_HSDT_AcceptWriter)).Length)
		Root["hotstrings_word_expander_frame"] := Original
		RepairedRows := _HS_WordExpanderRows(_HSDT_ControlCommands(_HSDT_AcceptWriter))
		if RepairedRows is Array {
			for Row in RepairedRows {
				if Row is Map && Row.Has("submenu") && Row["submenu"] is Menu
					OwnedMenus.Push(Row["submenu"])
			}
		}
		AssertEqual(1, RepairedRows.Length)
	} finally {
		try {
			ReleaseError := false
			for Built in OwnedMenus {
				try {
					try Built.Delete()
					finally MenuDispatcher_PruneMenu(Built)
				} catch as e {
					if !IsObject(ReleaseError)
						ReleaseError := e
				}
			}
			if IsObject(ReleaseError)
				throw ReleaseError
		} finally {
			Root["hotstrings_word_expander_frame"] := Original
			_HSDT_Restore(Saved)
		}
	}
}
Test("hotstrings parameter frames: genuine native child Menu and withdrawal retain the original contract",
	_HSDT_ParameterFrameNativeMenuContract)
