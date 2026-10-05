; tests/meta/test_config_persistence_callers.ahk

; ==============================================================================
; MODULE: AHK-15 Persistence Caller Class Guard
; DESCRIPTION:
; Enumerates every direct production TOML/feature/gesture writer call instead
; of pinning the sites named by the audit. A new sibling automatically joins
; the scan and must consume the boolean result. It also guards the transaction
; ordering shared by bulk Map publication, related gesture fields, first-boot
; side effects and Suspend reload hand-off.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================================
; ==========================================
; ======= 1/ Whole-class result scan =======
; ==========================================
; ==========================================

_CPC_CountOccurrences(Haystack, Needle) {
	if (Needle == "")
		return 0
	Count := 0
	Pos := 1
	while (Pos := InStr(Haystack, Needle, true, Pos)) {
		Count += 1
		Pos += StrLen(Needle)
	}
	return Count
}

_CPC_LineConsumesResult(Lines, Index) {
	Line := Lines[Index]
	if RegExMatch(Line,
		"i)^\s*(?:try\s+return\b|return\b|if\b|else\s+if\b)")
		return true
	if !RegExMatch(Line,
		"i)^\s*(?:try\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*:=", &Assignment)
		return false
	; Assignment is consumption only when the status is actually tested. Merely
	; renaming a discarded result must not satisfy this class guard.
	loop Min(20, Lines.Length - Index) {
		Candidate := Lines[Index + A_Index]
		if _CPC_IsFunctionDeclaration(Lines, Index + A_Index)
			break
		if RegExMatch(Candidate,
			"i)^\s*(?:(?:if|else\s+if)\b[^\r\n]*\b|(?:try\s+)?return\b[^\r\n]*\b)"
			. Assignment[1] . "\b")
			return true
	}
	return false
}

; Source declarations may wrap their parameter list over several lines. Treat
; only an unindented identifier as a declaration start, then require the close
; parenthesis and opening brace within a bounded signature. An indented call
; cannot disappear from the writer census merely because a later line has `){`.
_CPC_IsFunctionDeclaration(Lines, Index) {
	if !RegExMatch(Lines[Index], "^[A-Za-z_][A-Za-z0-9_]*\s*\(")
		return false
	loop Min(20, Lines.Length - Index + 1) {
		Candidate := Lines[Index + A_Index - 1]
		if RegExMatch(Candidate, "\)\s*\{\s*$")
			return true
		if InStr(Candidate, "{")
			return false
	}
	return false
}

_CPC_ResultConsumptionRecognizesTestedReturns() {
	Assert(_CPC_LineConsumesResult([
		"Committed := ConfigCommitBuilt(Path, Context, BuildFn)",
		"return (Committed is Integer) && Committed == 1"], 1),
		"a parenthesized strict status return consumes the writer result")
	AssertFalse(_CPC_LineConsumesResult([
		"Committed := ConfigCommitBuilt(Path, Context, BuildFn)",
		"return true"], 1), "an assigned but ignored status must fail")
	AssertFalse(_CPC_LineConsumesResult([
		"Committed := ConfigCommitBuilt(Path, Context, BuildFn)",
		"NextWriter() {", "return Committed"], 1),
		"a later function cannot consume this writer's result")
}
Test("AHK-15-persistence: result scan distinguishes tested and discarded status",
	_CPC_ResultConsumptionRecognizesTestedReturns)

; Audit the new caller before admitting it into the whole-class census.
; Mutations use the real return line, so an assigned or discarded native result
; cannot pass merely because this fixture knows the expected caller count.
_CPC_IndentWriterReturnsItsNativeStatus() {
	Body := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_IndentWrite"))
	Assert(Body != "", "the actual indentation writer must be readable")
	Lines := StrSplit(Body, "`n", "`r")
	Calls := 0
	for Index, Line in Lines {
		if !InStr(Line, "TOML_BatchWrite(")
			continue
		Calls += 1
		Assert(_CPC_LineConsumesResult(Lines, Index), "the indentation writer must return its native ACK")
		Assert(InStr(Line, "WriterFn.Call(Path, Owned)") > 0,
			"the injected and production writers must share the same owned leaf and result boundary")
		Discarded := Lines.Clone()
		Discarded[Index] := StrReplace(Line, "return ", "")
		AssertFalse(_CPC_LineConsumesResult(Discarded, Index),
			"discarding the actual native ACK must fail the caller guard")
		Assigned := Lines.Clone()
		Assigned[Index] := StrReplace(Line, "return ", "Ignored := ")
		AssertFalse(_CPC_LineConsumesResult(Assigned, Index),
			"assigning without testing the actual native ACK must fail the caller guard")
	}
	AssertEqual(1, Calls, "one independently audited native writer joins the census")
	Borrowed := _StripFullLineComments(_DriverFuncBody("ConfigCommitBorrowedUpdates"))
	Ack := _StripFullLineComments(_DriverFuncBody("_ConfigInvokeCommitWriter"))
	Assert(InStr(Borrowed, "if !_ConfigInvokeCommitWriter(") > 0,
		"the borrowed lease must classify the native writer before acknowledging the mutation")
	Assert(InStr(Ack, "if !((Written is Integer) && Written == 1)") > 0,
		"only a strict Integer-1 native receipt may acknowledge the owned write")
}
Test("AHK-15-persistence: the indentation caller returns its native ACK and rejects discarded-result mutations",
	_CPC_IndentWriterReturnsItsNativeStatus)

_CPC_EveryDirectTomlWriterConsumesItsBoolean() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for the AHK-15 TOML caller scan")
	Calls := 0
	Lines := StrSplit(Src, "`n", "`r")
	for Index, Line in Lines {
		if !RegExMatch(Line, "\b(?:TOML_(?:Write|BatchWrite)|ConfigCommit(?:Updates|Built))\(")
			continue
		if _CPC_IsFunctionDeclaration(Lines, Index)
			continue
		Calls += 1
		Assert(_CPC_LineConsumesResult(Lines, Index),
			"direct TOML writer result is discarded: '" . Trim(Line) . "'. TOML failures return false rather than throwing, so every production caller must test, assign or return that boolean")
	}
	; Audited inventory: config_io (7), config_shortcuts (2), unused-key cleanup
	; (2), feature_io (2), gestures (4), and one each in i18n, TOML_Write,
	; updater, editors, menu rebuild, personal editor, WPM, the error window and scoped configuration.
	; Both admitted builders and direct-update gateways count. Pin the census so
	; deleting a caller cannot make this class guard progressively vacuous, while
	; every future sibling is still inspected by the loop above before the
	; inventory assertion is reached.
	; SetScriptShortcutChordsOn added the seventh config_io caller: its strict
	; false return precedes reload, covered by the real refused-write case.
	; SetKeyCombinationHold and ClearKeyCombination (infra/key_combinations.ahk)
	; added two: each returns false before its reload when the commit is refused.
	; _LLM_Menu_IndentWrite adds one leaf-owned caller: its native status is
	; returned unchanged to the borrowed lease's strict Integer-1 ACK gate.
	AssertEqual(29, Calls,
		"the production TOML writer/transaction-gateway inventory changed; audit every added or removed caller before updating the expected census")
}
Test("AHK-15-persistence: every TOML writer and transaction gateway consumes its boolean",
	_CPC_EveryDirectTomlWriterConsumesItsBoolean)

; Audit the privacy publisher independently before admitting its private call.
_CPC_PrivacyPublisherRetainsSourceAndStrictResult() {
	Writer := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_PrivacyWrite"))
	Action := _StripFullLineComments(_DriverFuncBody("LLM_Menu_SetPrivacy"))
	Command := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_PrivacyCommand"))
	Assert(Writer != "" && Action != "" && Command != "", "the real privacy owners must exist")
	Lines := StrSplit(Writer, "`n", "`r")
	Calls := 0
	for Index, Line in Lines {
		if !InStr(Line, "_TOML_BatchWriteImpl(")
			continue
		Calls += 1
		Assert(_CPC_LineConsumesResult(Lines, Index), "privacy publication must return its native ACK")
		Assert(InStr(Line, 'Path, Owned, [], "write", Content, 1') > 0,
			"the native publisher must receive only the owned leaf and retained source")
		Discarded := Lines.Clone()
		Discarded[Index] := StrReplace(Line, "return ", "")
		AssertFalse(_CPC_LineConsumesResult(Discarded, Index), "discarded privacy ACK must fail")
		Assigned := Lines.Clone()
		Assigned[Index] := StrReplace(Line, "return ", "Ignored := ")
		AssertFalse(_CPC_LineConsumesResult(Assigned, Index), "an untested privacy ACK must fail")
	}
	AssertEqual(1, Calls, "one independently audited privacy publisher joins the private census")
	ReadPos := InStr(Writer, "Content := FSReadUtf8Exact(Path)")
	SourcePos := InStr(Writer, "_LLM_Menu_EnableReadSource()",, ReadPos)
	PublishPos := InStr(Writer, 'return _TOML_BatchWriteImpl(Path, Owned, [], "write", Content, 1)')
	Assert(ReadPos > 0 && SourcePos > ReadPos && PublishPos > SourcePos,
		"the privacy publisher revalidates the retained image after the final native read")
	Assert(InStr(Writer, "return WriterFn.Call(Path, Owned, Content, 1)") > 0,
		"native and injected terminal writers share the retained source and result boundary")
	Assert(InStr(Action, "return LLM_Menu_CommitMutation(") > 0
		&& InStr(Action, "_LLM_Menu_PrivacyWrite.Bind(Expected, Key)") > 0,
		"privacy publication remains under the existing borrowed lease")
	Assert(InStr(Command, 'Command.Call(Key, Decision["value"], Expected) == true') > 0
		&& InStr(Command, 'LLM_Menu_SetPrivacy(Key, Decision["value"], Expected) == true') > 0,
		"neither injected nor production malformed receipts can acknowledge privacy intent")
}
Test("AHK-15-persistence: privacy publication retains its source and rejects discarded-result mutations",
	_CPC_PrivacyPublisherRetainsSourceAndStrictResult)

_CPC_InternalTomlPublishersConsumeResult() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "internal publisher inventory requires actual readable production source")
	Lines := StrSplit(Src, "`n", "`r")
	Calls := 0
	for Index, Line in Lines {
		if !RegExMatch(Line, "\b_TOML_BatchWriteImpl\(") || _CPC_IsFunctionDeclaration(Lines, Index)
			continue
		Calls += 1
		Assert(_CPC_LineConsumesResult(Lines, Index),
			"an internal TOML builder or publisher cannot discard its qualified result: " . Trim(Line))
	}
	; The two canonical TOML gateways retain their result; the Info Bar writer
	; adds one exact-source publication beneath its existing borrowed lease.
	; Privacy adds one more publisher, audited above against actual native source
	; and independently exercised by the retained-source race regression.
	; The configuration-specific build/write gateways and source-bound explicit
	; cleanup add three consumers, independently audited in the semantic cohort.
	AssertEqual(8, Calls, "audit every internal publisher before changing its complete inventory")
	Writer := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_InfoBarWrite"))
	Action := _StripFullLineComments(_DriverFuncBody("LLM_Menu_SetInfoBar"))
	Command := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_InfoBarCommand"))
	Assert(Writer != "" && Action != "" && Command != "", "all source, transaction and result owners must exist")
	ReadPos := InStr(Writer, "Content := FSReadUtf8Exact(Path)")
	SourcePos := InStr(Writer, "_LLM_Menu_EnableReadSource()",, ReadPos)
	PublishPos := InStr(Writer, 'return _TOML_BatchWriteImpl(Path, Owned, [], "write", Content, 1)')
	Assert(ReadPos > 0 && SourcePos > ReadPos && PublishPos > SourcePos,
		"the actual native writer binds the canonical publisher to its revalidated source image")
	Assert(InStr(Action, "return LLM_Menu_CommitMutation(") > 0
		&& InStr(Action, "_LLM_Menu_InfoBarWrite.Bind(Expected)") > 0,
		"the exact-source writer remains beneath the canonical borrowed-lease transaction")
	Assert(InStr(Command, 'return Command.Call(Decision["value"], Expected) == true') > 0,
		"a refused or malformed native setter result cannot acknowledge the command")
}
Test("AHK-15-persistence: every internal publisher retains its exact source and result owner",
	_CPC_InternalTomlPublishersConsumeResult)

_CPC_EveryFeatureWriterConsumesItsResult() {
	Src := _DriverSourceNoComments()
	Calls := 0
	Lines := StrSplit(Src, "`n", "`r")
	for Index, Line in Lines {
		if !RegExMatch(Line, "\bWriteFeature(?:Batch)?V2\(")
			continue
		if _CPC_IsFunctionDeclaration(Lines, Index)
			continue
		Calls += 1
		Assert(_CPC_LineConsumesResult(Lines, Index),
			"feature writer result is discarded: '" . Trim(Line) . "'. Its TOML commit can return false, so reload/publication must be gated by the returned status")
	}
	Assert(Calls >= 5,
		"the class scan must reach all production feature writer calls (found only " . Calls . ")")
}
Test("AHK-15-persistence: every feature writer gates its side effect",
	_CPC_EveryFeatureWriterConsumesItsResult)

_CPC_LiveFeatureFailureCannotFallThrough() {
	CallerBody := _StripFullLineComments(_DriverFuncBody("ToggleFeatureV2"))
	HelperBody := _StripFullLineComments(_DriverFuncBody("_HS_TryLiveToggleV2"))
	Assert(CallerBody != "" and HelperBody != "",
		"the v2 live-toggle caller and classifier must exist")
	Assert(InStr(CallerBody, "LiveResult := _HS_TryLiveToggleV2(V2Path)") > 0
		and InStr(CallerBody, "if LiveResult.handled") > 0
		and InStr(CallerBody, "if !LiveResult.ok") > 0,
		"ToggleFeatureV2 must distinguish a handled persistence failure from a reload-only path")
	FailurePos := InStr(HelperBody, "return {handled: true, ok: false}")
	RebuildPos := InStr(HelperBody, "RebuildHotstringsLive()")
	Assert(_CPC_CountOccurrences(HelperBody, "return {handled: false, ok: true}") >= 2,
		"only non-live and reload-only classifications may fall through to the reload write")
	Assert(FailurePos > InStr(HelperBody, "WriteFeatureV2(")
		and RebuildPos > FailurePos,
		"a false live writer result must abort before rebuild and must not masquerade as reload-only")
}
Test("AHK-15-persistence: live writer false cannot fall through to a second write",
	_CPC_LiveFeatureFailureCannotFallThrough)

_CPC_RelatedFeatureFieldsUseOneBatch() {
	LetterBody := _StripFullLineComments(_DriverFuncBody("SetFeatureLetter"))
	ToggleBody := _StripFullLineComments(_DriverFuncBody("ToggleFeatureV2"))
	AssertEqual(1, _CPC_CountOccurrences(LetterBody, "WriteFeatureBatchV2("),
		"enabling a letter feature and choosing its letter must share one feature batch")
	Assert(InStr(LetterBody, '"prop", "letter"') > 0
		and InStr(LetterBody, '"value", true') > 0,
		"the shared letter batch must contain both related fields")
	AssertEqual(1, _CPC_CountOccurrences(ToggleBody, "WriteFeatureBatchV2("),
		"a reload-path feature toggle must write one feature batch")
	; The two slots of a key combination, its tap and its hold, are emptied
	; together: one batch, or a refused second write leaves half a pair.
	ClearBody := _StripFullLineComments(_DriverFuncBody("ClearKeyCombination"))
	AssertEqual(1, _CPC_CountOccurrences(ClearBody, "ConfigCommitUpdates("),
		"clearing a key combination must empty its tap and its hold in one batch")
	Assert(InStr(ClearBody, "KEY_COMBINATION_HOLD_SECTION") > 0 and InStr(ClearBody, "KeyCombinationTapClearRow(PairId)") > 0,
		"that batch must carry both slots")
}
Test("AHK-15-persistence: related feature fields share one batch",
	_CPC_RelatedFeatureFieldsUseOneBatch)

_CPC_EveryGestureWriterConsumesItsResult() {
	Src := _DriverSourceNoComments()
	Calls := 0
	Lines := StrSplit(Src, "`n", "`r")
	for Index, Line in Lines {
		if !RegExMatch(Line,
			"\bGesture(?:SaveAssignment|SaveAllAssignments|SetActionParameter|AssignConfiguredAction)\(")
			continue
		if _CPC_IsFunctionDeclaration(Lines, Index)
			continue
		Calls += 1
		Assert(_CPC_LineConsumesResult(Lines, Index),
			"gesture persistence result is discarded: '" . Trim(Line) . "'. A false result must prevent reload and in-memory publication")
	}
	Assert(Calls >= 5,
		"the class scan must reach the production gesture writer calls (found only " . Calls . ")")
}
Test("AHK-15-persistence: every gesture writer gates reload/publication",
	_CPC_EveryGestureWriterConsumesItsResult)





; ==============================================
; ==============================================
; ======= 2/ Candidate publication order =======
; ==============================================
; ==============================================

_CPC_AssertBulkFunctionStagesBeforePublishing(Name) {
	Body := _StripFullLineComments(_DriverFuncBody(Name))
	Assert(Body != "", Name . " must exist")
	Category := Name == "ToggleCategoryAllFeatures"
	Owner := Category ? Body : _StripFullLineComments(_DriverFuncBody("_ConfigCommitHotstringIntent"))
	BuilderName := Category ? "_ConfigBuildCategoryIntentPlan" : "_ConfigBuildHotstringIntentPlan"
	Builder := _StripFullLineComments(_DriverFuncBody(BuilderName))
	Assert(Owner != "" && Builder != "", "admission and candidate phases must exist")
	if !Category
		Assert(InStr(Body, "return _ConfigCommitHotstringIntent(") > 0, Name . " must consume the common commit result")
	PersistPos := InStr(Owner, "if !ConfigCommitBuilt(")
	ReloadPos := InStr(Owner, "ReloadPreservingSuspend(")
	Assert(PersistPos > 0 && ReloadPos > PersistPos, "durable commit must precede reload")
	AssertEqual(1, _CPC_CountOccurrences(Owner, "ConfigCommitBuilt("), "one logical edit has one admitted config batch")
	Assert(InStr(Owner, BuilderName . ".Bind(") > 0, "candidate construction must occur under the config lease")
	Assert(InStr(Builder, "MasterGateDesiredFeatures(") > 0 && InStr(Builder, "_ConfigPublishDesiredState.Bind(") > 0,
		"the candidate retains intent and delegates atomic publication to the gateway")
	for Source in [Body, Builder] {
		Assert(!RegExMatch(Source, "m)^\s*(?:Features|CategoryEnabled|TapHold)\s*(?:\[|:=)"),
			Name . " cannot publish shared state before the durable gateway accepts it")
	}
	if Name == "ToggleAllHotstrings" {
		Collector := _DriverFuncBody("_CollectAllHotstringsV2Paths")
		Assert(Collector != "" && InStr(Builder, "_CollectAllHotstringsV2Paths(Desired)") > 0,
			"personal discovery must run on a detached desired candidate")
		Assert(InStr(Collector, "_ConfigSeedPersonalHotstring(FeaturesTarget") > 0 && InStr(Collector, "EnsurePersonalHotstringFeature(") == 0,
			"discovery cannot mutate the live feature tree")
	}
}

_CPC_BulkMutationsStageBeforePublishing() {
	for Name in ["ToggleAllHotstrings", "ToggleCategoryAllFeatures",
		"ToggleCategoryAllSections", "HS_TogglePersonalAllSections"]
		_CPC_AssertBulkFunctionStagesBeforePublishing(Name)
}
Test("AHK-15-persistence: bulk mutations publish candidates only after commit",
	_CPC_BulkMutationsStageBeforePublishing)

_CPC_GestureAssignmentIsOneRelatedFieldBatch() {
	Body := _StripFullLineComments(_DriverFuncBody("_GestureCommitAssignment"))
	Assert(Body != "", "_GestureCommitAssignment must exist")
	PersistPos := InStr(Body, "ConfigCommitUpdates(")
	AssignmentPublish := InStr(Body, "AssignmentsTarget := CandidateAssignments")
	ParameterPublish := InStr(Body, "ParametersTarget := CandidateParameters")
	Assert(InStr(Body, "Section: AssignmentSection") > 0,
		"the assignment update must be in the shared batch")
	Assert(InStr(Body, 'Section: "action_parameters"') > 0,
		"the related parameter update must be in the same shared batch")
	AssertEqual(1, _CPC_CountOccurrences(Body, "ConfigCommitUpdates("),
		"one logical assignment must perform one TOML batch")
	Assert(PersistPos > 0 and PersistPos < AssignmentPublish and PersistPos < ParameterPublish,
		"both detached Maps must be published only after the shared batch succeeds")
	CriticalPos := InStr(Body, 'Critical("On")')
	ReleasePos := InStr(Body, "Critical(PreviousCritical)")
	Assert(CriticalPos > PersistPos and CriticalPos < AssignmentPublish
		and ParameterPublish < ReleasePos,
		"the two related Maps must be published in one short non-yielding window")
}
Test("AHK-15-persistence: parameter and assignment share one commit",
	_CPC_GestureAssignmentIsOneRelatedFieldBatch)





; ========================================
; ========================================
; ======= 3/ Deferred side effects =======
; ========================================
; ========================================

_CPC_FirstBootSideEffectsFollowMarkerClear() {
	Body := _DriverFuncBody("GestureConsumeAutoConfigureFlag")
	Assert(Body != "", "GestureConsumeAutoConfigureFlag must exist")
	PersistPos := InStr(Body, "ConfigCommitUpdates(")
	TimerPos := InStr(Body, "SetTimer(")
	SuccessPos := InStr(Body, "LoggerSuccess(")
	Assert(PersistPos > 0 and TimerPos > PersistPos and SuccessPos > PersistPos,
		"UAC/PnP scheduling and SUCCESS must be reachable only after the marker-clear commit succeeds")
}
Test("AHK-15-persistence: first-boot effects follow marker consumption",
	_CPC_FirstBootSideEffectsFollowMarkerClear)

_CPC_LifecycleRoutesThroughAtomicHandoff() {
	ReloadWrapper := _DriverFuncBody("ReloadPreservingSuspend")
	ReloadBody := _DriverFuncBody("_ReloadPreservingSuspendNonCritical")
	RestoreBody := _DriverFuncBody("_SuspendRestoreFromMarker")
	Assert(ReloadWrapper != "" and ReloadBody != "" and RestoreBody != "",
		"the Critical wrapper, lifecycle core, and restore entry must exist")
	Assert(InStr(ReloadWrapper,
		"_ReloadPreservingSuspendNonCritical(SuccessFn, ExistingBundle,") > 0
		and InStr(ReloadWrapper, "RefusedFn, StageFailureFn)") > 0
		and InStr(ReloadWrapper, "Reload()") = 0,
		"ReloadPreservingSuspend must only drop inherited Critical and delegate")
	Assert(InStr(ReloadBody, "SuspendHandoffReload(") > 0
		and InStr(ReloadBody, "ReloadTerminalInvoke.Bind(") > 0
		and InStr(ReloadBody, "LifecycleLaunchSuccessor") > 0
		and InStr(ReloadBody, "Reload()") = 0,
		"ReloadPreservingSuspend must let the tested helper launch the owned successor")
	Assert(InStr(RestoreBody, "SuspendHandoffConsume(") > 0,
		"marker restoration must route through the atomic rename/delete/toggle helper")
	Assert(InStr(RestoreBody, "A_ScriptHwnd") = 0,
		"the lifecycle wrapper must not derive a process-owned claim that cannot be retried after restart")
	ConsumeBody := _DriverFuncBody("SuspendHandoffConsume")
	Assert(InStr(ConsumeBody, 'ClaimPath := Path . ".claim"') > 0,
		"the behavior-tested core must own the stable claim name")
	CoalescePos := InStr(ConsumeBody, "else if SourceExists")
	SourceDeletePos := InStr(ConsumeBody, "DeleteFn.Call(Path)",, CoalescePos)
	ClaimDeletePos := InStr(ConsumeBody, "DeleteFn.Call(ClaimPath)",, CoalescePos)
	Assert(CoalescePos > 0 and SourceDeletePos > CoalescePos
		and ClaimDeletePos > SourceDeletePos,
		"a retained claim plus a new source must coalesce before the one pause restore")
}
Test("AHK-15-persistence: lifecycle uses the atomic tested hand-off",
	_CPC_LifecycleRoutesThroughAtomicHandoff)


_CPC_NumberRowRetainsSourceAndStrictAck() {
	Writer := _StripFullLineComments(_DriverFuncBody("_LAY_NumberRowWrite"))
	Commit := _StripFullLineComments(_DriverFuncBody("_LAY_NumberRowCommit"))
	Assert(Writer != "" && Commit != "", "number-row production owners must resolve")
	Lines := StrSplit(Writer, "`n", "`r")
	Calls := 0
	for Index, Line in Lines {
		if !InStr(Line, "_TOML_BatchWriteImpl(")
			continue
		Calls += 1
		Assert(_CPC_LineConsumesResult(Lines, Index), "the actual publisher must return its strict result")
		AssertContains(Line, 'Expected["content"], Expected["presence"]', "exact retained bytes and absence reach the canonical owner")
		Discarded := Lines.Clone()
		Discarded[Index] := StrReplace(Line, "return ", "")
		AssertFalse(_CPC_LineConsumesResult(Discarded, Index), "discarding native publication must fail")
		Assigned := Lines.Clone()
		Assigned[Index] := StrReplace(Line, "return ", "Ignored := ")
		AssertFalse(_CPC_LineConsumesResult(Assigned, Index), "an untested native ACK must fail")
	}
	AssertEqual(1, Calls)
	AssertContains(Writer, '_LAY_NumberRowSnapshot()', "physical source is revalidated inside the borrowed feature transaction")
	AssertContains(Writer, 'Updates.Length != 1', "only the declared leaf may be published")
	AssertContains(Commit, '_LAY_NumberRowWrite.Bind(Expected, Value, WriterFn)')
	AssertContains(Commit, 'if !(Written is Integer) || Written != true')
}
Test("AHK-15-persistence: number-row choice consumes its exact-source leased publisher", _CPC_NumberRowRetainsSourceAndStrictAck)


_CPC_SemanticConfigPublishersRetainSource() {
	Build := _StripFullLineComments(_DriverFuncBody("TOML_BuildConfigUpdatedContent"))
	Publish := _StripFullLineComments(_DriverFuncBody("TOML_ConfigBatchWrite"))
	Cleanup := _StripFullLineComments(_DriverFuncBody("ConfigUnusedKeysRemove"))
	Assert(Build != "" && Publish != "" && Cleanup != "", "all three new source/result owners must exist")
	Assert(InStr(Build, 'SourceBytes := SourcePresent ? FSReadUtf8Exact(Path) : ""') > 0
		&& InStr(Build, 'Result := _TOML_BatchWriteImpl(Path, Updates, ExactSectionPrefixes, "build",') > 0
		&& InStr(Build, "SourceBytes, SourcePresent, true)") > 0
		&& InStr(Build, "return _TOML_FinalizeBuildResult(Result, SourcePresent, SourceBytes)") > 0,
		"semantic preparation retains its exact source through final admission")
	Assert(InStr(Publish,
		'return _TOML_BatchWriteImpl(Path, Updates, ExactSectionPrefixes, "write", , , true)') > 0,
		"semantic publication retains the canonical writer result and its fresh source owner")
	ReadPos := InStr(Cleanup, "Source := FSReadUtf8Exact(FilePath)")
	OwnPos := InStr(Cleanup, "SourceImage := Source",, ReadPos)
	BackupPos := InStr(Cleanup, "Written := WriteBackup.Call(BackupPath, Source)",, OwnPos)
	VerifyPos := InStr(Cleanup, "FSUtf8ExactMatches(BackupPath, Source)",, BackupPos)
	Assert(ReadPos > 0 && OwnPos > ReadPos && BackupPos > OwnPos && VerifyPos > BackupPos,
		"explicit cleanup owns and verifies the backup of the exact publication source")
	Assert(InStr(Cleanup, 'return _TOML_BatchWriteImpl(Path, Updates, DropSections, "write",') > 0
		&& InStr(Cleanup, "SourceImage, 1, true)") > 0,
		"explicit cleanup cannot reread a successor as its backed-up source")
	Assert(InStr(Cleanup, 'Writer := HasMethod(WriterFn, "Call") ? WriterFn : WriteUpdates') > 0
		&& InStr(Cleanup, 'Committed := ConfigCommitBuilt(FilePath, "the unused configuration key cleanup",') > 0
		&& InStr(Cleanup, "BuildPlan, Writer,") > 0,
		"the exact-source publisher remains inside the native claimed transaction")
}
Test("AHK-15-persistence: semantic configuration and explicit cleanup retain exact source/result owners",
	_CPC_SemanticConfigPublishersRetainSource)
