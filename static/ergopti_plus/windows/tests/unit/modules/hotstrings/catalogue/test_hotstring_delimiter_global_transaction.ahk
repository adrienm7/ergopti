; tests/unit/modules/hotstrings/catalogue/test_hotstring_delimiter_global_transaction.ahk

; ==============================================================================
; MODULE: Hotstring Delimiter State Transaction Tests
; DESCRIPTION:
; Drives the real delimiter commands and tray callbacks with an injected durable
; writer. The built-in delimiter states are config.toml leaves written through
; the live configuration writer: the tests pin process-wide terminal admission,
; strict writer results, one write per action, engine strings that change only
; from the writer's own publication, and menu side effects that run only after
; durable success.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../../../../ui/menu/menu_hotstrings.ahk





; =========================================
; =========================================
; ======= 1/ Transaction test seams =======
; =========================================
; =========================================

global _HSDT_BuildCalls := 0
global _HSDT_WriteCalls := 0
global _HSDT_NotifyCalls := 0
global _HSDT_RebuildCalls := 0
global _HSDT_WrittenUpdates := []
global _HSDT_ObservedDuringWrite := []
global _HSDT_WriterCritical := -1
global _HSDT_NotifyCritical := -1
global _HSDT_SetterCritical := -1
global _HSDT_RebuildCritical := -1

; The strings the catalogue ships with, spelled out independently of the code that
; derives them: space, tab, CR, LF, the magic key, then the sentence punctuation.
_HSDT_DefaultWord() {
	return " `t`r`n★,;.!?:"
}

_HSDT_ResetFakes() {
	global _HSDT_BuildCalls, _HSDT_WriteCalls
	global _HSDT_NotifyCalls, _HSDT_RebuildCalls
	global _HSDT_WrittenUpdates, _HSDT_ObservedDuringWrite
	global _HSDT_WriterCritical
	global _HSDT_NotifyCritical, _HSDT_SetterCritical
	global _HSDT_RebuildCritical
	_HSDT_BuildCalls := 0
	_HSDT_WriteCalls := 0
	_HSDT_NotifyCalls := 0
	_HSDT_RebuildCalls := 0
	_HSDT_WrittenUpdates := []
	_HSDT_ObservedDuringWrite := []
	_HSDT_WriterCritical := -1
	_HSDT_NotifyCritical := -1
	_HSDT_SetterCritical := -1
	_HSDT_RebuildCritical := -1
}

_HSDT_SaveState() {
	global ConfigurationFile, _HotstringsTerminatorRecords
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	return {
		Path: ConfigurationFile,
		Owner: _HotstringsTerminatorRecords,
		EngineWord: HSE_WORD_TERMINATORS,
		EngineConsumed: HSE_CONSUMED_DELIMITERS
	}
}

; Seeds a current-schema configuration holding Extra and a fresh delimiter owner
; admitted from it; the engine strings follow. The writer is a seam in these
; tests, so the file only has to exist and be admitted.
_HSDT_Seed(Name, Extra := "") {
	global ConfigurationFile, _HotstringsTerminatorRecords
	Path := A_Temp . "\ergopti_hs_delimiter_" . Name . "_" . A_ScriptHwnd . ".toml"
	if FileExist(Path)
		FileDelete(Path)
	Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n" . Extra
	AssertTrue(FSWriteDurable(Path, Source), "the seed configuration must be durable")
	ConfigurationFile := Path
	ConfigMigrateBoot(Path)
	_HotstringsTerminatorRecords := 0
	AssertTrue(HotstringsTerminatorRecordsInit(FSReadUtf8Exact(Path)))
	_HSDT_ResetFakes()
}

_HSDT_Restore(Saved) {
	global ConfigurationFile, _HotstringsTerminatorRecords
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	try {
		if ConfigurationFile != Saved.Path && FileExist(ConfigurationFile)
			FileDelete(ConfigurationFile)
	}
	ConfigurationFile := Saved.Path
	_HotstringsTerminatorRecords := Saved.Owner
	HSE_WORD_TERMINATORS := Saved.EngineWord
	HSE_CONSUMED_DELIMITERS := Saved.EngineConsumed
	_HSDT_ResetFakes()
}

_HSDT_AcceptWriter(Path, Updates) {
	global _HSDT_WriteCalls, _HSDT_WrittenUpdates, _HSDT_ObservedDuringWrite
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	global _HSDT_WriterCritical
	_HSDT_WriteCalls += 1
	_HSDT_WriterCritical := A_IsCritical
	_HSDT_WrittenUpdates.Push(Updates)
	_HSDT_ObservedDuringWrite.Push({
		EngineWord: HSE_WORD_TERMINATORS,
		EngineConsumed: HSE_CONSUMED_DELIMITERS
	})
	return 1
}

_HSDT_FalseWriter(Path, Updates) {
	global _HSDT_WriteCalls
	_HSDT_WriteCalls += 1
	return 0
}

_HSDT_StringWriter(Path, Updates) {
	global _HSDT_WriteCalls
	_HSDT_WriteCalls += 1
	return "1"
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

_HSDT_UnrelatedTerminalRefusesBeforeWriterAndMenuEffects() {
	global _HSDT_WriteCalls, _HSDT_NotifyCalls
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Saved := _HSDT_SaveState()
	Bundle := false
	try {
		_HSDT_Seed("terminal")
		Before := HSE_WORD_TERMINATORS
		Bundle := _ConfigWriteTerminalTryAcquire(
			[A_Temp . "\ergopti_hs_unrelated_terminal.toml"])
		AssertTrue(Bundle is Object)

		AssertFalse(_HS_DelimToggleEntry("comma", _HSDT_AcceptWriter, _HSDT_Notify),
			"a process-wide terminal transition refuses the delimiter write")
		AssertEqual(0, _HSDT_WriteCalls,
			"a refused menu action must never reach durable I/O")
		AssertEqual(0, _HSDT_NotifyCalls,
			"a refused menu action must not display the success notice")
		AssertEqual(Before, HSE_WORD_TERMINATORS)
		AssertEqual(Before, HotstringsGetWordDelimiters())
	} finally {
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		_HSDT_Restore(Saved)
	}
}
Test("hotstring-delimiter-global-transaction-20260813: unrelated terminal "
	. "refuses before writer, live state and success notice",
	_HSDT_UnrelatedTerminalRefusesBeforeWriterAndMenuEffects)





; ========================================
; ========================================
; ======= 3/ Strict durable result =======
; ========================================
; ========================================

_HSDT_FalseAndStringWritersPublishNothing() {
	global _HSDT_WriteCalls, _HSDT_NotifyCalls
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Saved := _HSDT_SaveState()
	try {
		_HSDT_Seed("refused")
		Before := HSE_WORD_TERMINATORS
		AssertFalse(_HS_DelimToggleEntry("comma", _HSDT_FalseWriter, _HSDT_Notify))
		AssertEqual(1, _HSDT_WriteCalls)
		AssertEqual(0, _HSDT_NotifyCalls)
		AssertEqual(Before, HSE_WORD_TERMINATORS)
		AssertEqual(Before, HotstringsGetWordDelimiters())
		AssertEqual(true, _HotstringsTerminatorRecords.Builtin["comma"].Enabled,
			"a refused write leaves the owner as it was")

		_HSDT_ResetFakes()
		AssertFalse(_HS_DelimToggleEntry("comma", _HSDT_StringWriter, _HSDT_Notify),
			"a string that looks truthy must not satisfy the writer contract")
		AssertEqual(1, _HSDT_WriteCalls)
		AssertEqual(0, _HSDT_NotifyCalls)
		AssertEqual(Before, HSE_WORD_TERMINATORS)
		AssertEqual(Before, HotstringsGetWordDelimiters())
	} finally _HSDT_Restore(Saved)
}
Test("hotstring-delimiter-global-transaction-20260813: false and string writers "
	. "leave the stored state, live state and success notice untouched",
	_HSDT_FalseAndStringWritersPublishNothing)





; ===============================================
; ===============================================
; ======= 4/ One-write publication ==============
; ===============================================
; ===============================================

_HSDT_ToggleWritesOnceThenPublishes() {
	global _HSDT_WriteCalls, _HSDT_NotifyCalls
	global _HSDT_WrittenUpdates, _HSDT_ObservedDuringWrite
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Saved := _HSDT_SaveState()
	try {
		_HSDT_Seed("single")
		AssertTrue(_HS_DelimToggleEntry("question", _HSDT_AcceptWriter, _HSDT_Notify))
		AssertEqual(1, _HSDT_WriteCalls, "one click is one write")
		AssertEqual(1, _HSDT_NotifyCalls)
		AssertEqual(_HSDT_DefaultWord(), _HSDT_ObservedDuringWrite[1].EngineWord,
			"the engine strings stay old while the writer runs")
		Updates := _HSDT_WrittenUpdates[1]
		AssertEqual(1, Updates.Length)
		AssertEqual("hotstrings.terminator_states", Updates[1].Section)
		AssertEqual("question", Updates[1].Key)
		AssertEqual(false, Updates[1].Value.Value, "a state off its default is a leaf")
		AssertEqual(" `t`r`n★,;.!:", HSE_WORD_TERMINATORS)
		AssertEqual(HSE_WORD_TERMINATORS, HotstringsGetWordDelimiters())
		AssertEqual("★", HSE_CONSUMED_DELIMITERS)

		; Back on its default the leaf is deleted, never stored as a default.
		AssertTrue(_HS_DelimToggleEntry("question", _HSDT_AcceptWriter, _HSDT_Notify))
		Updates := _HSDT_WrittenUpdates[2]
		AssertEqual(1, Updates.Length)
		AssertEqual(1, Updates[1].Delete, "a state back on its default deletes its leaf")
		AssertEqual(_HSDT_DefaultWord(), HSE_WORD_TERMINATORS)
	} finally _HSDT_Restore(Saved)
}
Test("hotstring-delimiter-global-transaction-20260813: a toggle writes one leaf "
	. "and publishes the strings after the writer",
	_HSDT_ToggleWritesOnceThenPublishes)

_HSDT_BulkActionsWriteOnceSparsely() {
	global _HSDT_WriteCalls, _HSDT_WrittenUpdates
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Saved := _HSDT_SaveState()
	try {
		_HSDT_Seed("bulk", '[hotstrings.terminator_states]`nspace = false`nslash = true`n'
			. '[hotstrings.terminator_consume]`ncomma = true`n')
		AssertTrue(_HS_DelimSetAll(false, _HSDT_AcceptWriter, _HSDT_Notify))
		AssertEqual(1, _HSDT_WriteCalls, "a bulk action is one write")
		Keys := Map()
		for Update in _HSDT_WrittenUpdates[1]
			Keys[Update.Key] := Update
		AssertEqual(1, Keys["slash"].Delete, "slash goes off, which is its default: its leaf is deleted")
		AssertEqual(false, Keys["comma"].Value.Value, "a default-on delimiter off is a leaf")
		AssertFalse(Keys.Has("minus"), "a delimiter already on its default is not written")
		AssertEqual("", HSE_CONSUMED_DELIMITERS, "a delimiter that is off consumes nothing")
		AssertEqual("", HSE_WORD_TERMINATORS, "every shipped delimiter is off and no record exists")

		_HSDT_ResetFakes()
		AssertTrue(_HS_DelimSetAll(true, _HSDT_AcceptWriter, _HSDT_Notify))
		AssertEqual(1, _HSDT_WriteCalls)
		AssertTrue(InStr(HSE_WORD_TERMINATORS, "/") > 0 and InStr(HSE_WORD_TERMINATORS, "-") > 0,
			"every shipped delimiter is on, the optional ones included")
	} finally _HSDT_Restore(Saved)
}
Test("hotstring-delimiter-global-transaction-20260813: bulk actions write once, "
	. "sparsely against the catalogue",
	_HSDT_BulkActionsWriteOnceSparsely)

_HSDT_NoChangeWritesNothing() {
	global _HSDT_WriteCalls, _HSDT_NotifyCalls
	Saved := _HSDT_SaveState()
	try {
		_HSDT_Seed("noop")
		AssertEqual(1, HotstringsTerminatorBuiltinCommit(Map("comma", Map("enabled", 1)), _HSDT_AcceptWriter),
			"a state already stored (here: the default) is acknowledged")
		AssertEqual(0, _HSDT_WriteCalls, "and nothing is written")
	} finally _HSDT_Restore(Saved)
}
Test("hotstring-delimiter-global-transaction-20260813: an unchanged state writes nothing",
	_HSDT_NoChangeWritesNothing)

_HSDT_ConsumeLeafChangesOnlyTheConsumedString() {
	global _HSDT_WrittenUpdates
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Saved := _HSDT_SaveState()
	try {
		_HSDT_Seed("consume")
		AssertEqual(1, HotstringsTerminatorBuiltinCommit(Map("comma", Map("consume", 1)), _HSDT_AcceptWriter))
		Update := _HSDT_WrittenUpdates[1][1]
		AssertEqual("hotstrings.terminator_consume", Update.Section)
		AssertEqual("comma", Update.Key)
		AssertEqual(true, Update.Value.Value)
		AssertEqual(_HSDT_DefaultWord(), HSE_WORD_TERMINATORS)
		AssertEqual("★,", HSE_CONSUMED_DELIMITERS)
		AssertThrows(HotstringsTerminatorBuiltinCommit.Bind(Map("not_a_delimiter", Map("enabled", 1)), _HSDT_AcceptWriter),
			"only shipped keys are addressed here")
		AssertThrows(HotstringsTerminatorBuiltinCommit.Bind(Map("comma", Map("enabled", "yes")), _HSDT_AcceptWriter),
			"a state is a strict Boolean")
	} finally _HSDT_Restore(Saved)
}
Test("hotstring-delimiter-global-transaction-20260813: the consume leaf of a shipped "
	. "delimiter changes only the consumed string",
	_HSDT_ConsumeLeafChangesOnlyTheConsumedString)





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
	global _HSDT_WriterCritical
	global _HSDT_NotifyCritical, _HSDT_SetterCritical
	global _HSDT_RebuildCritical
	Saved := _HSDT_SaveState()
	try {
		_HSDT_Seed("critical")
		PreviousCritical := Critical("On")
		try {
			AssertTrue(_HS_DelimToggleEntry("comma", _HSDT_AcceptWriter, _HSDT_Notify))
			AssertTrue(A_IsCritical,
				"the delimiter action must restore its caller's Critical state")
		} finally Critical(PreviousCritical)
		AssertEqual(0, _HSDT_WriterCritical,
			"the configuration write must remain interruptible")
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
; ======= 6/ Restore keeps records =======
; ========================================
; ========================================

_HSDT_ResetRetainsRecordsAndRefusesAtomically() {
	global _HSDT_WriteCalls, _HSDT_NotifyCalls, _HSDT_WrittenUpdates
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	Saved := _HSDT_SaveState()
	try {
		Extra := '[hotstrings.terminator_states]`nspace = false`nslash = true`ncustom_x = false`n'
			. '[hotstrings.terminator_consume]`ncomma = true`nstar = false`n'
			. '[[hotstrings.terminators]]`nkey = "custom_x"`nchar = "x"`nlabel = "x"`nconsume = false`n'
			. '[[hotstrings.terminators]]`nkey = "keep"`nchar = "¤"`nlabel = "Keep"`nconsume = true`n'
		_HSDT_Seed("restore-personal", Extra)
		SeededWord := HSE_WORD_TERMINATORS, SeededConsumed := HSE_CONSUMED_DELIMITERS
		AssertEqual("`t`r`n★,;.!?:/¤", SeededWord, "the seeded configuration is what the test then restores")
		AssertEqual(",¤", SeededConsumed)
		AssertFalse(_HS_DelimReset(_HSDT_FalseWriter, _HSDT_Notify))
		AssertEqual(SeededWord, HSE_WORD_TERMINATORS)
		AssertEqual(SeededConsumed, HSE_CONSUMED_DELIMITERS)
		AssertEqual(0, _HSDT_NotifyCalls)
		_HSDT_ResetFakes()
		AssertTrue(_HS_DelimReset(_HSDT_AcceptWriter, _HSDT_Notify))
		AssertEqual(_HSDT_DefaultWord() . "¤", HSE_WORD_TERMINATORS,
			"the shipped delimiters return, the disabled record stays out and the enabled one stays in")
		AssertEqual("★¤", HSE_CONSUMED_DELIMITERS)
		AssertEqual(1, _HSDT_WriteCalls, "the restore is one write")
		AssertEqual(1, _HSDT_NotifyCalls)
		Touched := Map()
		for Update in _HSDT_WrittenUpdates[1]
			Touched[Update.Section . "/" . Update.Key] := Update
		AssertTrue(Touched.Has("hotstrings.terminator_states/space") and Touched.Has("hotstrings.terminator_states/slash")
			and Touched.Has("hotstrings.terminator_consume/comma") and Touched.Has("hotstrings.terminator_consume/star"),
			"every shipped leaf that differed is deleted")
		AssertFalse(Touched.Has("hotstrings.terminator_states/custom_x"), "a personal state is never touched")
		for Update in _HSDT_WrittenUpdates[1]
			AssertEqual(1, Update.Delete, "a restore deletes leaves, it never writes a default")
	} finally _HSDT_Restore(Saved)
}
Test("hotstring delimiters: tray restore retains records and refuses without half publication",
	_HSDT_ResetRetainsRecordsAndRefusesAtomically)
