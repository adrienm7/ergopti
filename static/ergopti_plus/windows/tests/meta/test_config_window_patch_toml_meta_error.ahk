; tests/meta/test_config_window_patch_toml_meta_error.ahk

; ==============================================================================
; MODULE: HCW metadata transaction error handling guard
; DESCRIPTION:
; Guards the original "hcw-patch-toml-meta-bare-try" failure after ownership
; and atomic publication moved into shared personal TOML helpers. The HCW
; wrapper must delegate, and the terminal atomic boundary must still catch and
; log injected writer/replacement failures instead of swallowing them. It also
; guards the direct HCW mutation-handler class: native and WebView handlers must
; not close a bulk-reset surface or announce success after any persistence
; backend refuses a write. Close/navigation drainage is guarded separately.
; A refused write must still reconcile the controls with canonical state so the
; rejected candidate does not remain visible.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../../ui/hotstrings_config_window/hcw_helpers.ahk
#Include ../../ui/hotstrings_config_window/hcw_mutations.ahk
#Include ../../ui/hotstrings_config_window/webview.ahk


_PTME_PatchTomlMetaHasCatch() {
	PatcherBody := _DriverFuncBody("_HCW_PatchTomlMeta")
	Assert(InStr(PatcherBody, "_PersonalTomlCommitPatch(") > 0,
		"_HCW_PatchTomlMeta must route failures through the owned transaction helper")
	TransactionBody := _DriverFuncBody("_PersonalTomlCommitPatch")
	Assert(InStr(TransactionBody, "_PersonalTomlWriteAtomic(") > 0,
		"the owned transaction must delegate terminal publication to the atomic writer")
	AtomicBody := _DriverFuncBody("_PersonalTomlWriteAtomic")
	Assert(InStr(AtomicBody, "catch as Err") > 0,
		"the atomic writer must catch injected writer and replacement exceptions")
	Assert(InStr(AtomicBody, "LoggerError") > 0,
		"the atomic writer must log every caught publication failure")
}
Test("hotstrings_config_window: delegated metadata publication logs failures",
	_PTME_PatchTomlMetaHasCatch)

_PTME_InvalidPriorityCannotReachPersonalBackend() {
	for Invalid in [-1, 101, 1.5, "50", 1.0e300] {
		AssertFalse(_HCW_SetOverride({}, "", "priority", Invalid),
			"the HCW boundary must reject an invalid priority before reading its backend entry")
		AssertThrows(() => _HCW_TomlValue("priority", Invalid),
			"the personal TOML formatter must fail closed on an invalid priority")
	}
	AssertEqual("0", _HCW_TomlValue("priority", 0),
		"the lower priority boundary must remain serialisable")
	AssertEqual("100", _HCW_TomlValue("priority", 100),
		"the upper priority boundary must remain serialisable")
}
Test("hotstrings_config_window: invalid priority cannot reach personal persistence",
	_PTME_InvalidPriorityCannotReachPersonalBackend)

_PTME_InvalidTooltipBooleanCannotReachPersonalBackend() {
	for Invalid in ["false", "true", 2, -1, 0.5] {
		AssertFalse(_HCW_SetOverride({}, "", "show_tooltip", Invalid),
			"the HCW boundary must reject an invalid tooltip Boolean before reading its backend entry")
		AssertThrows(() => _HCW_TomlValue("show_tooltip", Invalid),
			"the personal TOML formatter must fail closed on an invalid tooltip Boolean")
	}
	AssertEqual("false", _HCW_TomlValue("show_tooltip", false),
		"the false Boolean must remain serialisable")
	AssertEqual("true", _HCW_TomlValue("show_tooltip", true),
		"the true Boolean must remain serialisable")
}
Test("hotstrings_config_window: tooltip Boolean rejects invalid personal values",
	_PTME_InvalidTooltipBooleanCannotReachPersonalBackend)

_PTME_ColorUsesSharedTomlCodec() {
	AssertFalse(_HCW_SetOverride({}, "", "color", 42),
		"the HCW boundary must reject a non-string color before reading its backend entry")
	Color := '#112233"`n[injected]`ncolor = "#445566'
	AssertEqual(TOML_RenderString(Color), _HCW_TomlValue("color", Color),
		"the personal color formatter must delegate every escape to the shared TOML codec")
}
Test("hotstrings_config_window: color writer uses the shared TOML codec",
	_PTME_ColorUsesSharedTomlCodec)

_PTME_PersonalPatchIdentifiersCannotInjectToml() {
	Path := A_Temp . "\hcw_personal_patch_identifier_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	Original := "[_meta]`ndescription = " . TOML_RenderString("Personal") . "`n"
	InjectedSection := "race]`n[injected"
	InjectedField := "color`n[injected]"
	try {
		try FileDelete(Path)
		FileAppend(Original, Path, "UTF-8")
		AssertFalse(_HCW_PatchTomlMeta(Path, InjectedSection,
			"color", "#112233"),
			"a personal section identifier must not inject a sibling TOML header")
		AssertEqual(Original, FileRead(Path, "UTF-8"),
			"section validation must run before the owned patch publishes")
		AssertFalse(_HCW_PatchTomlMeta(Path, "", InjectedField, "#112233"),
			"a personal metadata field must come from the closed field catalogue")
		AssertEqual(Original, FileRead(Path, "UTF-8"),
			"field validation must preserve the durable source byte-exact")
		AssertThrows(() => _HCW_BuildTomlMetaPatch(
			InjectedSection, "color", "#112233", Original),
			"the pure serializer boundary must reject direct invalid section calls")
		AssertThrows(() => _HCW_BuildTomlMetaPatch(
			"", InjectedField, "#112233", Original),
			"the pure serializer boundary must reject direct invalid field calls")
		Valid := _HCW_BuildTomlMetaPatch(
			"race_one", "color", "#112233", Original)
		AssertTrue(InStr(Valid, "[_meta.sections.race_one]") > 0,
			"a valid personal section identifier must remain serialisable")
	} finally {
		try FileDelete(Path)
	}
}
Test("hotstrings_config_window: personal patch identifiers cannot inject TOML",
	_PTME_PersonalPatchIdentifiersCannotInjectToml)

_PTME_WebTooltipPayloadPreservesBooleanType() {
	global _HCW_CATEGORY_LIST, _HCW_GROUP_LIST, _HCW_COLOR_PRESETS
	global _HotstringsOverridesPath, _HotstringsOverrides
	SavedCategories := _HCW_CATEGORY_LIST
	SavedGroups := _HCW_GROUP_LIST
	SavedPresets := _HCW_COLOR_PRESETS
	SavedPath := _HotstringsOverridesPath
	SavedOverrides := _HotstringsOverrides
	Path := A_Temp . "\hcw_web_tooltip_type_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	Entry := {
		Key: "rolls", Label: "Rolls", Group: "common", Path: "",
		IsPersonal: false, IsExtension: false,
	}
	try {
		try FileDelete(Path)
		_HCfgTestReset()
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := Map()
		_HCW_CATEGORY_LIST := [Entry]
		_HCW_GROUP_LIST := []
		_HCW_COLOR_PRESETS := []

		for Invalid in ["true", "false", 2, -1] {
			Result := _HCWWeb_Dispatch(Map(
				"action", "set_tooltip",
				"category", "rolls",
				"show_tooltip", Invalid))
			AssertFalse(Result,
				"the WebView bridge must reject a non-Boolean tooltip payload")
			AssertFalse(FileExist(Path),
				"an invalid bridge payload must not publish an override file")
			AssertFalse(_HotstringsOverrides.Has("rolls"),
				"an invalid bridge payload must not mutate live state")
		}

		AssertTrue(_HCWWeb_Dispatch(Map(
			"action", "set_tooltip", "category", "rolls",
			"show_tooltip", true)),
			"a real true Boolean must remain writable")
		AssertEqual(true, _HotstringsOverrides["rolls"].ShowTooltip)
		AssertTrue(_HCWWeb_Dispatch(Map(
			"action", "set_tooltip", "category", "rolls",
			"show_tooltip", false)),
			"a real false Boolean must remain writable")
		AssertEqual(false, _HotstringsOverrides["rolls"].ShowTooltip)
	} finally {
		try FileDelete(Path)
		_HCW_CATEGORY_LIST := SavedCategories
		_HCW_GROUP_LIST := SavedGroups
		_HCW_COLOR_PRESETS := SavedPresets
		_HotstringsOverridesPath := SavedPath
		_HotstringsOverrides := SavedOverrides
	}
}
Test("hotstrings_config_window: WebView tooltip preserves Boolean type",
	_PTME_WebTooltipPayloadPreservesBooleanType)

_PTME_WebDelayPayloadPreservesIntegerMilliseconds() {
	global _HCW_CATEGORY_LIST, _HCW_GROUP_LIST, _HCW_COLOR_PRESETS
	global _HotstringsOverridesPath, _HotstringsOverrides
	SavedCategories := _HCW_CATEGORY_LIST
	SavedGroups := _HCW_GROUP_LIST
	SavedPresets := _HCW_COLOR_PRESETS
	SavedPath := _HotstringsOverridesPath
	SavedOverrides := _HotstringsOverrides
	Path := A_Temp . "\hcw_web_delay_type_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	Entry := {
		Key: "rolls", Label: "Rolls", Group: "common", Path: "",
		IsPersonal: false, IsExtension: false,
	}
	try {
		try FileDelete(Path)
		_HCfgTestReset()
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := Map()
		_HCW_CATEGORY_LIST := [Entry]
		_HCW_GROUP_LIST := []
		_HCW_COLOR_PRESETS := []

		for Invalid in ["1000", 1000.5, -1] {
			Result := _HCWWeb_Dispatch(Map(
				"action", "set_delay",
				"category", "rolls",
				"ms", Invalid))
			AssertFalse(Result,
				"the WebView bridge must reject a non-domain delay payload")
			AssertFalse(FileExist(Path),
				"an invalid delay payload must not publish an override file")
			AssertFalse(_HotstringsOverrides.Has("rolls"),
				"an invalid delay payload must not mutate live state")
		}

		AssertTrue(_HCWWeb_Dispatch(Map(
			"action", "set_delay", "category", "rolls", "ms", 1000)),
			"an integer millisecond delay must remain writable")
		AssertEqual(1, _HotstringsOverrides["rolls"].Delay,
			"the bridge must convert a valid millisecond integer exactly once")
	} finally {
		try FileDelete(Path)
		_HCW_CATEGORY_LIST := SavedCategories
		_HCW_GROUP_LIST := SavedGroups
		_HCW_COLOR_PRESETS := SavedPresets
		_HotstringsOverridesPath := SavedPath
		_HotstringsOverrides := SavedOverrides
	}
}
Test("hotstrings_config_window: WebView delay preserves millisecond integer type",
	_PTME_WebDelayPayloadPreservesIntegerMilliseconds)



; The shared outcome gate is deliberately behavioural. A source token alone
; could be hidden behind `if false`; these callbacks prove that every write is
; actually evaluated and that only one terminal outcome becomes observable.
global _PTME_BatchEvents := []
global _PTME_BatchRefreshes := 0
global _PTME_BatchCloses := 0
global _PTME_BatchSuccessNotices := 0
global _PTME_BatchFailureNotices := 0
global _PTME_LastBatchOutcome := 0
global _PTME_BatchCallbackEvents := []

_PTME_ResetBatchProbe() {
	global _PTME_BatchEvents, _PTME_BatchRefreshes, _PTME_BatchCloses
	global _PTME_BatchSuccessNotices, _PTME_BatchFailureNotices
	global _PTME_LastBatchOutcome, _PTME_BatchCallbackEvents
	_PTME_BatchEvents := []
	_PTME_BatchRefreshes := 0
	_PTME_BatchCloses := 0
	_PTME_BatchSuccessNotices := 0
	_PTME_BatchFailureNotices := 0
	_PTME_LastBatchOutcome := 0
	_PTME_BatchCallbackEvents := []
}

_PTME_BatchWrite(Label, Result) {
	global _PTME_BatchEvents
	_PTME_BatchEvents.Push(Label)
	return Result
}

_PTME_BatchThrow(Label) {
	global _PTME_BatchEvents
	_PTME_BatchEvents.Push(Label)
	throw Error("injected persistence writer failure")
}

_PTME_BatchReconcile(Outcome) {
	global _PTME_BatchRefreshes, _PTME_LastBatchOutcome, _PTME_BatchCallbackEvents
	_PTME_BatchRefreshes += 1
	_PTME_LastBatchOutcome := Outcome
	_PTME_BatchCallbackEvents.Push("reconcile")
}

_PTME_BatchSuccessEffects(Outcome) {
	global _PTME_BatchCloses, _PTME_BatchSuccessNotices, _PTME_BatchCallbackEvents
	_PTME_BatchCloses += 1
	_PTME_BatchSuccessNotices += 1
	_PTME_BatchCallbackEvents.Push("success")
}

_PTME_BatchFailureNotice(Outcome) {
	global _PTME_BatchFailureNotices, _PTME_BatchCallbackEvents
	_PTME_BatchFailureNotices += 1
	_PTME_BatchCallbackEvents.Push("failure")
}

_PTME_RequireWriteBatchRunner() {
	; In AHK v2 Func is the native class, not a string-to-function resolver.
	; Referencing the included function directly gives us its callable object.
	return _HCW_RunWriteBatch
}

_PTME_WriteBatchFailureSuppressesSuccessEffects() {
	global _PTME_BatchEvents, _PTME_BatchRefreshes, _PTME_BatchCloses
	global _PTME_BatchSuccessNotices, _PTME_BatchFailureNotices
	global _PTME_BatchCallbackEvents
	_PTME_ResetBatchProbe()
	Runner := _PTME_RequireWriteBatchRunner()
	Writes := [
		_PTME_BatchWrite.Bind("first", true),
		_PTME_BatchWrite.Bind("refused", false),
		_PTME_BatchWrite.Bind("string-protocol-violation", "1"),
		_PTME_BatchWrite.Bind("deferred-protocol-violation", 2),
		_PTME_BatchWrite.Bind("negative-protocol-violation", -1),
		_PTME_BatchThrow.Bind("throwing-writer"),
		_PTME_BatchWrite.Bind("last", true)
	]
	Outcome := Runner.Call(Writes, _PTME_BatchReconcile.Bind(),
		_PTME_BatchSuccessEffects.Bind(), _PTME_BatchFailureNotice.Bind())
	AssertFalse(Outcome["ok"],
		"one refused persistence result must make the complete action fail")
	AssertEqual(7, Outcome["attempted"])
	AssertEqual(2, Outcome["succeeded"])
	AssertEqual(5, Outcome["failed"])
	AssertEqual(5, Outcome["failed_indices"].Length)
	for Index, Expected in [2, 3, 4, 5, 6]
		AssertEqual(Expected, Outcome["failed_indices"][Index],
			"the outcome must identify each refused writer so its draft can be requeued")
	AssertEqual(7, _PTME_BatchEvents.Length,
		"the batch must evaluate every persistence result instead of short-circuiting and hiding later failures")
	AssertEqual("first", _PTME_BatchEvents[1])
	AssertEqual("refused", _PTME_BatchEvents[2])
	AssertEqual("string-protocol-violation", _PTME_BatchEvents[3])
	AssertEqual("deferred-protocol-violation", _PTME_BatchEvents[4])
	AssertEqual("negative-protocol-violation", _PTME_BatchEvents[5])
	AssertEqual("throwing-writer", _PTME_BatchEvents[6])
	AssertEqual("last", _PTME_BatchEvents[7])
	AssertEqual(1, _PTME_BatchRefreshes,
		"a failed write must reconcile the UI once with canonical durable state")
	AssertEqual(0, _PTME_BatchCloses,
		"a failed bulk action must keep the native window open")
	AssertEqual(0, _PTME_BatchSuccessNotices,
		"a failed bulk action must never announce success")
	AssertEqual(1, _PTME_BatchFailureNotices,
		"the aggregate failure must be reported exactly once")
	AssertEqual(2, _PTME_BatchCallbackEvents.Length)
	AssertEqual("reconcile", _PTME_BatchCallbackEvents[1],
		"canonical reconciliation must precede the terminal failure signal")
	AssertEqual("failure", _PTME_BatchCallbackEvents[2])
}
Test("hotstrings_config_window: one refused write suppresses every success side effect",
	_PTME_WriteBatchFailureSuppressesSuccessEffects)

_PTME_WriteBatchSuccessRunsTerminalEffectsOnce() {
	global _PTME_BatchEvents, _PTME_BatchRefreshes, _PTME_BatchCloses
	global _PTME_BatchSuccessNotices, _PTME_BatchFailureNotices
	global _PTME_BatchCallbackEvents
	_PTME_ResetBatchProbe()
	Runner := _PTME_RequireWriteBatchRunner()
	Writes := [
		_PTME_BatchWrite.Bind("first", true),
		_PTME_BatchWrite.Bind("second", true)
	]
	Outcome := Runner.Call(Writes, _PTME_BatchReconcile.Bind(),
		_PTME_BatchSuccessEffects.Bind(), _PTME_BatchFailureNotice.Bind())
	AssertTrue(Outcome["ok"],
		"an all-success batch must report a durable successful action")
	AssertEqual(2, Outcome["attempted"])
	AssertEqual(2, Outcome["succeeded"])
	AssertEqual(0, Outcome["failed"])
	AssertEqual(2, _PTME_BatchEvents.Length,
		"every successful persistence callback must run")
	AssertEqual(1, _PTME_BatchRefreshes,
		"the UI must refresh once after the complete batch succeeds")
	AssertEqual(1, _PTME_BatchCloses,
		"the native reset success path must close once")
	AssertEqual(1, _PTME_BatchSuccessNotices,
		"the complete batch must announce success once")
	AssertEqual(0, _PTME_BatchFailureNotices,
		"an all-success batch must not emit a failure notice")
	AssertEqual(2, _PTME_BatchCallbackEvents.Length)
	AssertEqual("reconcile", _PTME_BatchCallbackEvents[1],
		"canonical reconciliation must precede terminal success effects")
	AssertEqual("success", _PTME_BatchCallbackEvents[2])
}
Test("hotstrings_config_window: all-success batch runs terminal effects exactly once",
	_PTME_WriteBatchSuccessRunsTerminalEffectsOnce)


global _PTME_NumericWrites := []

_PTME_RecordNumericWrite(Entry, Sec, Field, Value) {
	global _PTME_NumericWrites
	_PTME_NumericWrites.Push({ Entry: Entry, Sec: Sec, Field: Field, Value: Value })
	return true
}

_PTME_NumericQueuePreservesEveryDistinctField() {
	global _PTME_NumericWrites
	Entry := { Key: "magickey" }
	Pending := []
	_HCW_QueueNumericWrite(Pending,
		{ Entry: Entry, Sec: "quotes", Field: "delay", Value: 0.4 })
	_HCW_QueueNumericWrite(Pending,
		{ Entry: { Key: "magickey" }, Sec: "quotes", Field: "delay", Value: 0.5 })
	_HCW_QueueNumericWrite(Pending,
		{ Entry: { Key: "magickey" }, Sec: "quotes", Field: "priority", Value: 9 })
	AssertEqual(2, Pending.Length,
		"retyping one logical entry after its catalogue object is rebuilt must coalesce without evicting another field")
	_PTME_NumericWrites := []
	Outcome := _HCW_RunNumericWriteBatch(Pending, _PTME_RecordNumericWrite)
	AssertTrue(Outcome["ok"])
	AssertEqual(2, Outcome["attempted"])
	AssertEqual(2, _PTME_NumericWrites.Length,
		"delay then priority inside one debounce window must produce two writes")
	AssertEqual("delay", _PTME_NumericWrites[1].Field)
	AssertEqual(0.5, _PTME_NumericWrites[1].Value,
		"the repeated delay edit must keep its latest value")
	AssertEqual("priority", _PTME_NumericWrites[2].Field)
	AssertEqual(9, _PTME_NumericWrites[2].Value)
}
Test("hotstrings_config_window: numeric debounce preserves distinct fields",
	_PTME_NumericQueuePreservesEveryDistinctField)

_PTME_NumericResetRemovesOnlyItsMatchingWrite() {
	Entry := { Key: "magickey" }
	OtherEntry := { Key: "autocorrection" }
	Pending := [
		{ Entry: Entry, Sec: "quotes", Field: "delay", Value: 0.5 },
		{ Entry: Entry, Sec: "quotes", Field: "priority", Value: 9 },
		{ Entry: Entry, Sec: "brackets", Field: "delay", Value: 0.7 },
		{ Entry: OtherEntry, Sec: "quotes", Field: "delay", Value: 0.8 }
	]
	Removed := _HCW_RemoveNumericWrite(Pending,
		{ Key: "magickey" }, "quotes", "delay")
	AssertEqual(1, Removed)
	AssertEqual(3, Pending.Length)
	AssertEqual("priority", Pending[1].Field,
		"resetting delay must preserve the queued priority edit")
	AssertEqual("brackets", Pending[2].Sec,
		"resetting one section must preserve another section's queued delay")
	AssertTrue(Pending[3].Entry == OtherEntry,
		"resetting one entry must preserve another entry's queued delay")
}
Test("hotstrings_config_window: field reset cancels only its matching debounce",
	_PTME_NumericResetRemovesOnlyItsMatchingWrite)

_PTME_FailedNumericDraftsRequeueWithoutOverwritingNewerInput() {
	global _HCW_PendingNumericWrites
	Entry := { Key: "magickey" }
	Snapshot := [
		{ Entry: Entry, Sec: "quotes", Field: "delay", Value: 0.5 },
		{ Entry: Entry, Sec: "quotes", Field: "priority", Value: 9 }
	]
	_HCW_PendingNumericWrites := [
		{ Entry: { Key: "magickey" }, Sec: "quotes", Field: "priority", Value: 12 }
	]
	Outcome := Map("failed_indices", [1, 2])
	Requeued := _HCW_RequeueFailedNumericWrites(Snapshot, Outcome)
	AssertEqual(1, Requeued,
		"only the missing failed draft should be reinserted")
	AssertEqual(2, _HCW_PendingNumericWrites.Length)
	AssertEqual(12, _HCW_PendingNumericWrites[1].Value,
		"a failed older priority write must not overwrite input typed during its I/O")
	AssertEqual("delay", _HCW_PendingNumericWrites[2].Field)
	AssertEqual(0.5, _HCW_PendingNumericWrites[2].Value)
}
Test("hotstrings_config_window: refused numeric drafts remain retryable (hcw-transition-drain-behavior)",
	_PTME_FailedNumericDraftsRequeueWithoutOverwritingNewerInput)

global _PTME_ReentrantDrainWrites := []

_PTME_ReentrantNumericWriter(Entry, Sec, Field, Value) {
	global _PTME_ReentrantDrainWrites, _HCW_PendingNumericWrites
	_PTME_ReentrantDrainWrites.Push(Field . ":" . Value)
	if (_PTME_ReentrantDrainWrites.Length == 1) {
		_HCW_QueueNumericWrite(_HCW_PendingNumericWrites, {
			Entry: { Key: Entry.Key }, Sec: Sec, Field: "priority", Value: 17
		})
	}
	return true
}

_PTME_NoOpOutcome(Outcome) {
}

_PTME_NumericDrainRepeatsUntilReentrantQueueIsEmpty() {
	global _PTME_ReentrantDrainWrites, _HCW_PendingNumericWrites
	global _HCW_NumericDrainActive
	Entry := { Key: "magickey" }
	_PTME_ReentrantDrainWrites := []
	_HCW_NumericDrainActive := false
	_HCW_PendingNumericWrites := [
		{ Entry: Entry, Sec: "quotes", Field: "delay", Value: 0.5 }
	]
	Ok := _HCW_FlushNumericWrite(false,
		_PTME_ReentrantNumericWriter, 0, _PTME_NoOpOutcome)
	AssertTrue(Ok)
	AssertEqual(2, _PTME_ReentrantDrainWrites.Length,
		"a transition drain must persist a draft enqueued while its first writer yields")
	AssertEqual("delay:0.5", _PTME_ReentrantDrainWrites[1])
	AssertEqual("priority:17", _PTME_ReentrantDrainWrites[2])
	AssertEqual(0, _HCW_PendingNumericWrites.Length,
		"a successful transition cannot leave a newer timer payload behind")
	AssertFalse(_HCW_NumericDrainActive,
		"the drain owner flag must be restored on every terminal path")
}
Test("hotstrings_config_window: drain reaches a reentrant stable queue (hcw-transition-drain-reentrant)",
	_PTME_NumericDrainRepeatsUntilReentrantQueueIsEmpty)

_PTME_NumericDrainOwnerBlocksNestedCompletion() {
	global _HCW_NumericDrainActive, _HCW_PendingNumericWrites
	_HCW_NumericDrainActive := true
	_HCW_PendingNumericWrites := [
		{ Entry: { Key: "magickey" }, Sec: "quotes", Field: "delay", Value: 0.5 }
	]
	try {
		Ok := _HCW_FlushNumericWrite(false)
		AssertFalse(Ok,
			"a nested close/navigation callback must not declare an active drain complete")
		AssertEqual(1, _HCW_PendingNumericWrites.Length,
			"the active drain owner must retain exclusive ownership of its queued draft")
	} finally {
		_HCW_NumericDrainActive := false
		_HCW_PendingNumericWrites := []
	}
}
Test("hotstrings_config_window: nested drain cannot complete its owner's transition (hcw-transition-drain-reentrant)",
	_PTME_NumericDrainOwnerBlocksNestedCompletion)

global _PTME_DrainEvents := []

_PTME_DrainResult(Result) {
	global _PTME_DrainEvents
	_PTME_DrainEvents.Push("drain")
	return Result
}

_PTME_DrainRestore() {
	global _PTME_DrainEvents
	_PTME_DrainEvents.Push("restore")
}

_PTME_TransitionGateBlocksAndRestoresOnRefusal() {
	global _PTME_DrainEvents
	_PTME_DrainEvents := []
	Allowed := _HCW_DrainBeforeTransition(
		_PTME_DrainResult.Bind(false), _PTME_DrainRestore)
	AssertFalse(Allowed)
	AssertEqual(2, _PTME_DrainEvents.Length)
	AssertEqual("drain", _PTME_DrainEvents[1])
	AssertEqual("restore", _PTME_DrainEvents[2])

	_PTME_DrainEvents := []
	Allowed := _HCW_DrainBeforeTransition(
		_PTME_DrainResult.Bind(true), _PTME_DrainRestore)
	AssertTrue(Allowed)
	AssertEqual(1, _PTME_DrainEvents.Length,
		"a durable draft must continue without rolling the selection back")
	AssertEqual("drain", _PTME_DrainEvents[1])
}
Test("hotstrings_config_window: transition gate blocks on refused draft (hcw-transition-drain-behavior)",
	_PTME_TransitionGateBlocksAndRestoresOnRefusal)

_PTME_ResetCancellationDropsEveryPendingWrite() {
	global _HCW_PendingNumericWrites
	_HCW_PendingNumericWrites := [
		{ Entry: { Key: "magickey" }, Sec: "quotes", Field: "delay", Value: 0.5 },
		{ Entry: { Key: "magickey" }, Sec: "quotes", Field: "priority", Value: 9 }
	]
	Removed := _HCW_CancelAllNumericWrites()
	AssertEqual(2, Removed,
		"Reset All must invalidate the complete debounce queue without persisting it")
	AssertEqual(0, _HCW_PendingNumericWrites.Length,
		"no timer payload may survive to restore an override after Reset All")
}
Test("hotstrings_config_window: reset cancels pending numeric writes without flushing",
	_PTME_ResetCancellationDropsEveryPendingWrite)

_PTME_ResetSections(Entry) {
	return [{ Name: "alpha" }]
}

_PTME_ResetPlanCoversPersonalAndOverrideBackends() {
	Categories := [
		{ Key: "personal:mine", Path: "mine.toml", IsPersonal: true,
			IsExtension: false, ExtId: "" },
		{ Key: "ext:demo:file", Path: "", IsPersonal: false,
			IsExtension: true, ExtId: "demo" },
		{ Key: "magickey", Path: "", IsPersonal: false,
			IsExtension: false, ExtId: "" }
	]
	Fields := ["delay", "color", "priority", "show_tooltip"]
	Plan := _HCW_BuildResetAllPlan(Categories, _PTME_ResetSections, Fields)
	AssertEqual(12, Plan.Length,
		"personal file+section need four writes each; extension and common need one all-fields clear at both levels")
	for Index, Field in Fields {
		AssertEqual("personal", Plan[Index].Kind)
		AssertEqual("", Plan[Index].Sec)
		AssertEqual(Field, Plan[Index].Field)
		SectionItem := Plan[Fields.Length + Index]
		AssertEqual("personal", SectionItem.Kind)
		AssertEqual("alpha", SectionItem.Sec)
		AssertEqual(Field, SectionItem.Field)
	}
	AssertEqual("override", Plan[9].Kind)
	AssertEqual("ext.demo", Plan[9].Category)
	AssertEqual("", Plan[9].Field,
		"extension reset must use the backend's all-fields clear")
	AssertEqual("alpha", Plan[10].Sec)
	AssertEqual("magickey", Plan[11].Category)
	AssertEqual("alpha", Plan[12].Sec)
}
Test("hotstrings_config_window: reset plan clears every personal metadata field (hcw-reset-personal-plan-behavior)",
	_PTME_ResetPlanCoversPersonalAndOverrideBackends)

_PTME_ExistingEditorsRefreshBeforeTheyAreShown() {
	Native := _DriverFuncBody("OpenHotstringsConfigWindow")
	CapturePos := InStr(Native, "_HCW_CaptureSelection()")
	BuildPos := InStr(Native, "_HCW_BuildCategoryList()")
	RefreshPos := InStr(Native, "_HCW_RefreshExistingControls(")
	ShowPos := InStr(Native, "_HCWGui.Show()")
	Assert(CapturePos > 0 and BuildPos > CapturePos and RefreshPos > BuildPos
		and ShowPos > RefreshPos,
		"the native singleton must capture stable keys, rebuild its catalogue, repopulate controls, and only then show — stale dropdown indexes can otherwise retarget an edit to another file")

	Web := _DriverFuncBody("_HCWWeb_TryOpen")
	WebBuildPos := InStr(Web, "_HCW_BuildCategoryList()")
	WebPushPos := InStr(Web, "_HCWWeb_PushState()")
	ActivatePos := InStr(Web, "WinActivate(")
	Assert(WebBuildPos > 0 and WebPushPos > WebBuildPos
		and ActivatePos > WebPushPos,
		"the WebView singleton must rebuild and push canonical state before activation")
}
Test("hotstrings_config_window: live singletons refresh before reopen (hcw-singleton-refresh)",
	_PTME_ExistingEditorsRefreshBeforeTheyAreShown)

_PTME_StableSelectionSurvivesCatalogueInsertion() {
	Before := [{ Key: "personal:b" }, { Key: "personal:c" }]
	SelectedKey := Before[2].Key
	After := [
		{ Key: "personal:a" },
		{ Key: "personal:b" },
		{ Key: "personal:c" }
	]
	Restored := _HCW_FindItemIndexByProperty(After, "Key", SelectedKey)
	AssertEqual(3, Restored,
		"adding a file before the selected entry must preserve its logical key instead of reusing the old index and targeting another file")
	Sections := [{ Name: "alpha" }, { Name: "gamma" }, { Name: "omega" }]
	AssertEqual(3,
		_HCW_FindItemIndexByProperty(Sections, "Name", "omega", 0),
		"section restoration must use its stable name")
	AssertEqual(0,
		_HCW_FindItemIndexByProperty(Sections, "Name", "deleted", 0),
		"a deleted section must be reported missing so the UI can fall back to file level")
}
Test("hotstrings_config_window: singleton selection follows stable keys (hcw-singleton-stable-selection)",
	_PTME_StableSelectionSurvivesCatalogueInsertion)

_PTME_EveryNativeTransitionConsumesTheDraftDrain() {
	CloseButtonBody := _DriverFuncBody("OpenHotstringsConfigWindow")
	Assert(InStr(CloseButtonBody,
		'BtnClose.OnEvent("Click", (*) => _HCW_RequestHide())') > 0,
		"the Close button must use the same persistence gate as X/Alt+F4 instead of hiding directly")
	for Name in ["_HCW_RequestHide", "_HCW_OnClose", "_HCW_OnGroupChanged",
		"_HCW_OnFileChanged", "_HCW_OnSectionChanged"] {
		Body := _DriverFuncBody(Name)
		Assert(InStr(Body, "_HCW_DrainBeforeTransition(") > 0,
			Name . " must consume the draft drain result before continuing")
	}
	for Name in ["_HCW_OnGroupChanged", "_HCW_OnFileChanged", "_HCW_OnSectionChanged"] {
		Body := _DriverFuncBody(Name)
		SnapshotPos := InStr(Body, "Selection := _HCW_LastSelection")
		RestorePos := InStr(Body, "_HCW_RestoreSelectionControl.Bind(")
		Assert(SnapshotPos > 0 and RestorePos > SnapshotPos
			and InStr(Body, ", Selection)") > RestorePos,
			Name . " must bind the prior stable selection before I/O instead of reading a mutable global during rollback")
	}
	CloseBody := _DriverFuncBody("_HCW_OnClose")
	GuardPos := InStr(CloseBody, "if !_HCW_DrainBeforeTransition(")
	ClearPos := InStr(CloseBody, "_HCWGui := 0")
	Assert(GuardPos > 0 and ClearPos > GuardPos,
		"X/Alt+F4 must keep the live editor context until the draft is durable")
	FlushBody := _DriverFuncBody("_HCW_FlushNumericWrite")
	Assert(InStr(FlushBody, "_HCW_RequeueFailedNumericWrites(") > 0,
		"a refused drain must requeue the failed draft instead of deleting its only copy")
	Assert(InStr(FlushBody, "loop {") > 0
		and InStr(FlushBody, "_HCW_NumericDrainActive") > 0,
		"a successful drain must own and repeat snapshots until re-entrant input leaves the queue stable")
}
Test("hotstrings_config_window: every native transition gates on draft persistence (hcw-transition-drain)",
	_PTME_EveryNativeTransitionConsumesTheDraftDrain)



; Enumerate the whole class so fixing one native handler cannot leave its
; WebView twin, debounce callback or sibling control silently dropping `false`.
_PTME_EveryMutationEntrypointUsesTheOutcomeGate() {
	OutcomeGateSites := [
		{ Name: "_HCW_FlushNumericWrite", Gate: "_HCW_RunNumericWriteBatch(" },
		{ Name: "_HCW_RunNumericWriteBatch", Gate: "_HCW_RunWriteBatch(" },
		{ Name: "_HCW_OnColorChanged", Gate: "_HCW_RunWriteBatch(" },
		{ Name: "_HCW_OnTooltipChanged", Gate: "_HCW_RunWriteBatch(" },
		{ Name: "_HCW_ClearField", Gate: "_HCW_RunWriteBatch(" },
		{ Name: "_HCW_ResetAll", Gate: "_HCW_RunWriteBatch(" },
		{ Name: "_HCW_SetAllGrey", Gate: "_HCW_RunWriteBatch(" },
		{ Name: "_HCWWeb_Dispatch", Gate: "_HCW_RunWriteBatch(" },
		{ Name: "_HCWWeb_ResetAll", Gate: "_HCW_RunWriteBatch(" },
		{ Name: "_HCWWeb_SetAllGrey", Gate: "_HCW_RunWriteBatch(" }
	]
	for Site in OutcomeGateSites {
		Body := _DriverFuncBody(Site.Name)
		Assert(InStr(Body, Site.Gate) > 0,
			Site.Name . " must route persistence through the shared behavioural outcome gate")
		Assert(!RegExMatch(Body, "i)\bif\s*\(?\s*(?:false|0)\b"),
			Site.Name . " must not satisfy the outcome contract through dead `if false` code")
	}
	NativeCurrentPattern := "s)_HCW_RunWriteBatch\(.*?"
		. "_HCW_ReconcileNativeCurrent\.Bind\(\)\s*,\s*0\s*,\s*"
		. "_HCW_ReportWriteFailure\.Bind\(\)\s*\)"
	for Name in ["_HCW_OnColorChanged", "_HCW_OnTooltipChanged",
		"_HCW_ClearField", "_HCW_SetAllGrey"] {
		Assert(RegExMatch(_DriverFuncBody(Name), NativeCurrentPattern),
			Name . " must wire canonical refresh as reconciliation, no success effect, and the failure reporter in the terminal-failure slot")
	}
	FlushBody := _DriverFuncBody("_HCW_FlushNumericWrite")
	Assert(InStr(FlushBody, "WriterFn := _HCW_SetOverride") > 0,
		"_HCW_FlushNumericWrite must default production writes to _HCW_SetOverride")
	Assert(InStr(FlushBody, "FailureFn := _HCW_ReportWriteFailure.Bind()") > 0,
		"_HCW_FlushNumericWrite must default terminal failures to the shared reporter")
	NumericFlushPattern := "s)_HCW_RunNumericWriteBatch\(\s*"
		. "PendingWrites\s*,\s*WriterFn\s*,\s*0\s*,\s*FailureFn\s*\)"
	Assert(RegExMatch(FlushBody, NumericFlushPattern),
		"_HCW_FlushNumericWrite must propagate its writer and failure reporter without a success-side refresh")
	FailureGatePos := InStr(FlushBody, 'if !Outcome["ok"]')
	RefreshPos := InStr(FlushBody, "RefreshFn.Call()")
	RequeuePos := InStr(FlushBody, "_HCW_RequeueFailedNumericWrites(")
	Assert(FailureGatePos > 0 and RequeuePos > FailureGatePos
		and RefreshPos > RequeuePos,
		"numeric flush must requeue refused drafts before returning and refresh only after the stable success path")
	NativeResetPattern := "s)_HCW_RunWriteBatch\(.*?"
		. "_HCW_ReconcileNativeReset\.Bind\(\)\s*,\s*"
		. "_HCW_CompleteNativeReset\.Bind\(\)\s*,\s*"
		. "_HCW_ReportWriteFailure\.Bind\(\)\s*\)"
	Assert(RegExMatch(_DriverFuncBody("_HCW_ResetAll"), NativeResetPattern),
		"_HCW_ResetAll must close and announce success only from the success slot, with failure reporting in the failure slot")
	WebDispatchPattern := "s)_HCW_RunWriteBatch\(.*?"
		. "_HCWWeb_ReconcileState\.Bind\(\)\s*,\s*0\s*,\s*"
		. "_HCW_ReportWriteFailure\.Bind\(\)\s*\)"
	Assert(RegExMatch(_DriverFuncBody("_HCWWeb_Dispatch"), WebDispatchPattern),
		"_HCWWeb_Dispatch must push canonical state before its terminal failure report")
	WebResetPattern := "s)_HCW_RunWriteBatch\(\s*Writes\s*,\s*"
		. "_HCWWeb_ReconcileReset\.Bind\(\)\s*,\s*"
		. "_HCWWeb_ReportResetSuccess\.Bind\(\)\s*\)"
	Assert(RegExMatch(_DriverFuncBody("_HCWWeb_ResetAll"), WebResetPattern),
		"_HCWWeb_ResetAll must put the positive reset notification in the success slot")
	WebGreyPattern := "s)_HCW_RunWriteBatch\(\s*Writes\s*,\s*"
		. "_HCWWeb_ReconcileState\.Bind\(\)\s*\)"
	Assert(RegExMatch(_DriverFuncBody("_HCWWeb_SetAllGrey"), WebGreyPattern),
		"_HCWWeb_SetAllGrey must reconcile once and leave terminal failure reporting to its dispatcher")
	UserFacingEntrypoints := [
		"_HCW_FlushNumericWrite",
		"_HCW_OnColorChanged",
		"_HCW_OnTooltipChanged",
		"_HCW_ClearField",
		"_HCW_ResetAll",
		"_HCW_SetAllGrey",
		"_HCWWeb_Dispatch"
	]
	for Name in UserFacingEntrypoints {
		Body := _DriverFuncBody(Name)
		Assert(InStr(Body, "_HCW_ReportWriteFailure") > 0,
			Name . " must provide an explicit user-visible failure path")
	}
}
Test("hotstrings_config_window: every native and WebView mutation entrypoint gates its outcome",
	_PTME_EveryMutationEntrypointUsesTheOutcomeGate)

_PTME_NoMutationSiteDropsAResultOrRunsBareSuccessEffects() {
	Sites := [
		"_HCW_FlushNumericWrite",
		"_HCW_OnColorChanged",
		"_HCW_OnTooltipChanged",
		"_HCW_ClearField",
		"_HCW_ResetAll",
		"_HCW_SetAllGrey",
		"_HCW_SetOverride",
		"_HCW_ClearOverride",
		"_HCWWeb_Dispatch",
		"_HCWWeb_ResetAll",
		"_HCWWeb_SetAllGrey"
	]
	BareWrite := "m)^[ \t]*(?:_HCW_(?:FlushNumericWrite|SetOverride|ClearOverride|PatchTomlMeta)"
		. "|_HCWWeb_(?:ResetAll|SetAllGrey)|Hotstrings(?:SetOverride|ClearOverride))\s*\("
	BareSuccessEffect := "m)^[ \t]*(?:try[ \t]+)?TrayTip\s*\("
	for Name in Sites {
		Body := _DriverFuncBody(Name)
		SearchBody := RegExReplace(Body, "s)^[^{]*\{", "",, 1)
		Assert(!RegExMatch(Body, "i)\bif\s*\(?\s*(?:false|0)\b"),
			Name . " must not hide an outcome guard in unreachable code")
		Assert(!RegExMatch(SearchBody, BareWrite),
			Name . " must consume every Boolean persistence result instead of invoking a write as a bare statement")
		Assert(!RegExMatch(SearchBody, BareSuccessEffect),
			Name . " must put success notification behind the successful outcome callback")
	}
	ResetBody := _DriverFuncBody("_HCW_ResetAll")
	Assert(InStr(ResetBody, "_HCWGui.Destroy(") == 0,
		"_HCW_ResetAll must move Gui destruction into the success callback so a failed write keeps the editor open")
	Assert(InStr(ResetBody, "_HCWGui := 0") == 0,
		"_HCW_ResetAll must not clear the live Gui handle before the complete batch succeeds")
}
Test("hotstrings_config_window: no mutation site drops a result or runs bare success effects",
	_PTME_NoMutationSiteDropsAResultOrRunsBareSuccessEffects)
