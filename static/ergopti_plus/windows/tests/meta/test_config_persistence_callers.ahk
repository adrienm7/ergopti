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
		"i)^\s*(?:try\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*:=", &Assignment) {
		; Only the adjacent, assigned native dispatch pair is a continuation.
		; The existing scan below must still find consumption of that same result.
		if Index <= 1 || !RegExMatch(Line,
			'^\s*:\s*TOML_BatchWrite\(Path,\s*Updates,\s*\[\],\s*NativeAdmission\)\s*$')
			return false
		if !RegExMatch(Lines[Index - 1],
			'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:=\s*IsConfiguration\s*\?\s*TOML_ConfigBatchWrite\(Path,\s*Updates,\s*\[\],\s*NativeAdmission\)\s*$', &Assignment)
			return false
	}
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

; Include semantic public and exact-source private gateways in the same class.
_CPC_IsQualifiedTomlCaller(Line) {
	return RegExMatch(Line,
		"\b(?:TOML_(?:Write|BatchWrite|ConfigBatchWrite)|_TOML_BatchWriteImpl|ConfigCommit(?:Updates|Built))\(")
}

_CPC_EveryDirectTomlWriterConsumesItsBoolean() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for the AHK-15 TOML caller scan")
	Calls := 0
	Lines := StrSplit(Src, "`n", "`r")
	for Index, Line in Lines {
		if !_CPC_IsQualifiedTomlCaller(Line)
			continue
		if _CPC_IsFunctionDeclaration(Lines, Index)
			continue
		Calls += 1
		Assert(_CPC_LineConsumesResult(Lines, Index),
			"direct TOML writer result is discarded: '" . Trim(Line) . "'. TOML failures return false rather than throwing, so every production caller must test, assign or return that boolean")
	}
	; The complete parent inventory is 37: 28 public and 9 internal calls.
	; SaveFullConfig now consumes its retained-source private writer result;
	; that same production site moves to 27 public + 10 internal calls, still 37.
	; Build-mode results are qualified maps; write-mode results are native ACKs.
	; The independent private-call guard and full-snapshot source audit below
	; retain the exact source/presence and strict Integer-1 receipt boundaries.
	; No production caller disappears when this source-bound gateway moves.
	AssertEqual(37, Calls,
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
	; Scoped build admission adds one qualified-map consumer, audited separately
	; against its captured source, finalizer and status-before-target chain.
	AssertEqual(10, Calls, "audit every internal publisher before changing its complete inventory")
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
	Assert(_CPC_RetiredRootPublisherChain(Cleanup),
		"the exact-source publisher and retained root receipt remain inside the native claimed transaction")
	Ack := _StripFullLineComments(_DriverFuncBody("_ConfigInvokeCommitWriter"))
	Assert(InStr(Ack, "if !((Written is Integer) && Written == 1)") > 0,
		"the claimed transaction refuses every malformed writer receipt")
}
Test("AHK-15-persistence: semantic configuration and explicit cleanup retain exact source/result owners",
	_CPC_SemanticConfigPublishersRetainSource)

_CPC_RetiredRootPublisherChain(Cleanup) {
	; Exact native bindings need line anchors: an unrelated identifier cannot
	; lend its suffix to the callback retained by ConfigCommitBuilt.
	SelectPos := RegExMatch(Cleanup,
		'm)^[ `t]*Publish := HasMethod\(WriterFn, "Call"\) \? WriterFn : WriteUpdates[ `t]*$')
	if !SelectPos
		return false
	WrapperPos := RegExMatch(Cleanup, "m)^[ `t]*Writer\(Path, Updates\) \{[ `t]*$",, SelectPos)
	if !WrapperPos
		return false
	ValidatePos := RegExMatch(Cleanup, "m)^[ `t]*ValidateRootReceipts\(SourceImage\)[ `t]*$",, WrapperPos)
	if !ValidatePos
		return false
	ForwardPos := RegExMatch(Cleanup, "m)^[ `t]*return Publish\.Call\(Path, Updates\)[ `t]*$",, ValidatePos)
	if !ForwardPos
		return false
	CommitPos := RegExMatch(Cleanup,
		'm)^[ `t]*Committed := ConfigCommitBuilt\(FilePath, "the unused configuration key cleanup",[ `t]*$',, ForwardPos)
	if !CommitPos
		return false
	BuilderPos := RegExMatch(Cleanup, "m)^[ `t]*BuildPlan, Writer,",, CommitPos)
	return WrapperPos > SelectPos && ValidatePos > WrapperPos
		&& ForwardPos > ValidatePos && CommitPos > ForwardPos && BuilderPos > CommitPos
		&& RegExMatch(Cleanup, "\bReceipt\.Accepts\(Entry, FilePath, Source\)")
}

_CPC_SemanticCallerInventoryAndRootReceiptMutations() {
	Full := _StripFullLineComments(_DriverFuncBody("SaveFullConfig"))
	Cleanup := _StripFullLineComments(_DriverFuncBody("ConfigUnusedKeysRemove"))
	Calls := 0
	for Body in [Full, Cleanup] {
		Lines := StrSplit(Body, "`n", "`r")
		for Index, Line in Lines {
			if !InStr(Line, "Written := TOML_ConfigBatchWrite(")
					&& !InStr(Line, "Written := _TOML_BatchWriteImpl(")
					&& !InStr(Line, "return _TOML_BatchWriteImpl(")
				continue
			Calls += 1
			AssertTrue(_CPC_IsQualifiedTomlCaller(Line), "the migrated native owner joins the complete inventory")
			AssertTrue(_CPC_LineConsumesResult(Lines, Index), "the actual migrated native status is consumed")
			Discarded := Lines.Clone()
			Discarded[Index] := StrReplace(StrReplace(Line, "Written := ", ""), "return ", "")
			AssertFalse(_CPC_LineConsumesResult(Discarded, Index), "discarded migrated results cannot pass")
			Assigned := Lines.Clone()
			Assigned[Index] := StrReplace(StrReplace(Line, "Written := ", "Ignored := "), "return ", "Ignored := ")
			AssertFalse(_CPC_LineConsumesResult(Assigned, Index), "assigned but untested migrated results cannot pass")
		}
	}
	AssertEqual(2, Calls, "both historically migrated gateway sites are independently audited")
	AssertTrue(_CPC_RetiredRootPublisherChain(Cleanup), "the actual retained-source chain remains admitted")
	AssertFalse(_CPC_RetiredRootPublisherChain(StrReplace(Cleanup,
		"Receipt.Accepts(Entry, FilePath, Source)", "UnrelatedReceipt.Accepts(Entry, FilePath, Source)")),
		"a suffix-sharing receiver cannot lend the retained Receipt source authority")
	AssertFalse(_CPC_RetiredRootPublisherChain(StrReplace(Cleanup,
		"Writer(Path, Updates) {", "UnrelatedWriter(Path, Updates) {")),
		"a suffix-sharing callback declaration cannot lend an unresolved Writer binding")
	AssertFalse(_CPC_RetiredRootPublisherChain(StrReplace(Cleanup,
		'Publish := HasMethod(WriterFn, "Call") ? WriterFn : WriteUpdates',
		'UnrelatedPublish := HasMethod(WriterFn, "Call") ? WriterFn : WriteUpdates')),
		"a suffix-sharing assignment cannot lend an unresolved Publish binding")
	AssertFalse(_CPC_RetiredRootPublisherChain(StrReplace(Cleanup,
		"ValidateRootReceipts(SourceImage)", "ValidateSomethingElse(SourceImage)")), "losing the final root receipt refuses the chain")
	AssertFalse(_CPC_RetiredRootPublisherChain(StrReplace(Cleanup,
		"return Publish.Call(Path, Updates)", "Publish.Call(Path, Updates)")), "discarding the native callback receipt refuses the chain")
	AssertFalse(_CPC_RetiredRootPublisherChain(StrReplace(Cleanup,
		"BuildPlan, Writer,", "BuildPlan, Publish,")), "bypassing the validated wrapper refuses the chain")
	AssertFalse(_CPC_RetiredRootPublisherChain(StrReplace(Cleanup,
		"Receipt.Accepts(Entry, FilePath, Source)", "true")), "bypassing actual source/entry receipt validation refuses the chain")
}
Test("AHK-15-persistence: actual semantic gateways retain census, native ACK and root-receipt mutation controls",
	_CPC_SemanticCallerInventoryAndRootReceiptMutations)


; The scoped builder returns a qualified image, not a write-mode Boolean.
; Audit its exact captured-source chain before adding that real call to the census.
_CPC_ScopeBuildUsesCapturedQualifiedImage(Body) {
	Patterns := [
		'm)^[ \t]*Image := TOML_BuildConfigUpdatedContent\(Path, \[\]\)',
		'm)^[ \t]*if !\(Image is Map\) \|\| Image\.Get\("status", ""\) != "ok" \|\| Image\.Get\("kind", ""\) != "rendered"',
		'm)^[ \t]*Rows := _ConfigPrepareTypedUpdates\(ConfigScopePreserveObsoleteSource\([ \t]*\n[ \t]*Image\["source_content"\], OperationsFn\.Call\(\)\)\)',
		'm)^[ \t]*Rendered := _TOML_BatchWriteImpl\(Path, Rows, \[\], "build",[ \t]*\n[ \t]*Image\["source_content"\], Image\["source_present"\], true\)',
		'm)^[ \t]*Image := _TOML_FinalizeBuildResult\(Rendered, Image\["source_present"\], Image\["source_content"\]\)',
		'm)^[ \t]*if Image\.Get\("status", ""\) != "ok" \|\| Image\.Get\("kind", ""\) != "rendered"',
		'm)^[ \t]*Expected := ConfigTransitionExpectedOld\(Image\["source_present"\], Image\["source_content"\], Port\)',
		'm)^[ \t]*Targets := \[ConfigTransitionPresentTarget\(Path, Image\["content"\], Expected\)\]'
	]
	Tokens := ["Image", "if", "Rows", "Rendered", "Image", "if", "Expected", "Targets"]
	Code := _DriverMaskNonCode(&Body)
	Cursor := 1
	for Index, Pattern in Patterns {
		Position := RegExMatch(Body, Pattern, &Matched, Cursor)
		if !Position
			return false
		Offset := InStr(Matched[0], Tokens[Index], true)
		if !Offset || SubStr(Code, Position + Offset - 1, StrLen(Tokens[Index])) != Tokens[Index]
			return false
		Cursor := Position + 1
	}
	return _CPC_CountOccurrences(Code, "_TOML_BatchWriteImpl(") == 1
		&& _CPC_CountOccurrences(Code, "_TOML_FinalizeBuildResult(") == 1
}

_CPC_ScopeBuildRetainsItsResultAndCapturedSource() {
	Body := _StripFullLineComments(_DriverFuncBody("ConfigScopeCommitOperations"))
	Assert(Body != "", "the new scoped build call must come from the real production owner")
	AssertTrue(_CPC_ScopeBuildUsesCapturedQualifiedImage(Body),
		"the new build-only caller classifies its actual result before creating any publication target")
	AssertEqual(1, _CPC_CountOccurrences(Body, "_TOML_BatchWriteImpl("),
		"exactly one independently audited scope builder joins the closed caller inventory")
	Mutations := [
		["Rendered := _TOML_BatchWriteImpl(", "UnrelatedRendered := _TOML_BatchWriteImpl("],
		["Rendered := _TOML_BatchWriteImpl(", "_TOML_BatchWriteImpl("],
		['_TOML_FinalizeBuildResult(Rendered,', '_TOML_FinalizeBuildResult(Ignored,'],
		['Image := _TOML_FinalizeBuildResult(', 'UnrelatedImage := _TOML_FinalizeBuildResult('],
		['Path, Rows, [], "build",', 'Path, Rows, [], "write",'],
		['Image["source_content"], Image["source_present"], true)', 'FSReadUtf8Exact(Path), Image["source_present"], true)'],
		['if Image.Get("status", "") != "ok" || Image.Get("kind", "") != "rendered"', 'if false'],
		['ConfigTransitionPresentTarget(Path, Image["content"], Expected)', 'ConfigTransitionPresentTarget(Path, Ignored["content"], Expected)']
	]
	for Mutation in Mutations {
		Changed := StrReplace(Body, Mutation[1], Mutation[2], true)
		AssertFalse(Changed == Body, "each counterexample must change the actual scoped build body")
		AssertFalse(_CPC_ScopeBuildUsesCapturedQualifiedImage(Changed),
			"discarded results, successor bindings, write mode and reread sources must not join the inventory")
	}
	Finalizer := _StripFullLineComments(_DriverFuncBody("_TOML_FinalizeBuildResult"))
	Assert(Finalizer != "", "the real qualified-map finalizer must exist")
	Assert(InStr(Finalizer, 'Result["status"] == "ok"') > 0
		&& InStr(Finalizer, 'Result["kind"] == "rendered"') > 0
		&& InStr(Finalizer, 'Result["content"] is String') > 0,
		"the finalizer must require the actual typed successful build receipt")
	Ack := _StripFullLineComments(_DriverFuncBody("_ConfigInvokeCommitWriter"))
	Assert(InStr(Ack, 'if !((Written is Integer) && Written == 1)') > 0,
		"build admission does not relax the existing strict native publication acknowledgement")
}
Test("AHK-15-persistence: scoped build admission retains its actual qualified result and captured source",
	_CPC_ScopeBuildRetainsItsResultAndCapturedSource)


_CPC_ScopeBuildRejectsQuotedSourceAuthority() {
	Body := _StripFullLineComments(_DriverFuncBody("ConfigScopeCommitOperations"))
	AssertTrue(_CPC_ScopeBuildUsesCapturedQualifiedImage(Body), "the executable scope source is the positive control")
	Call := 'Rendered := _TOML_BatchWriteImpl(Path, Rows, [], "build",`n'
		. '`t`t`tImage["source_content"], Image["source_present"], true)'
	Assert(InStr(Body, Call, true) > 0, "the decoy must replace the actual native build call")
	Quoted := "AuditText := " . Chr(39) . "`n(`n`t`t" . Call . "`n)" . Chr(39)
	Changed := StrReplace(Body, Call, Quoted . '`n`t`tRendered := Map("status", "refused", "kind", "none")', true)
	AssertFalse(Changed == Body, "the actual build call must be moved into continuation data")
	AssertFalse(_CPC_ScopeBuildUsesCapturedQualifiedImage(Changed),
		"quoted continuation data cannot authorize a discarded or absent native builder")
	Commented := StrReplace(Body, Call, "/*`n" . Call . "`n*/", true)
	AssertFalse(_CPC_ScopeBuildUsesCapturedQualifiedImage(Commented),
		"an actual call moved into a block comment is not executable source authority")
}
Test("AHK-15-persistence: copied quoted and commented scope calls cannot certify publication authority",
	_CPC_ScopeBuildRejectsQuotedSourceAuthority)

; A full-snapshot gateway may filter only actual neutral source collisions; its
; admitted source/presence must remain the writer's publication precondition.
_CPC_FullSnapshotSourceChain(Body) {
	Patterns := [
		'm)^[ \t]*SourceImage := 0',
		'm)^[ \t]*if !HasMethod\(WriterFn, "Call"\) \{',
		'm)^[ \t]*SourceImage := TOML_BuildConfigUpdatedContent\(BoundPath, \[\]\)',
		'm)^[ \t]*if !\(SourceImage is Map\) \|\| SourceImage\.Get\("status", ""\) != "ok"[ \t]*\n[ \t]*\|\| SourceImage\.Get\("kind", ""\) != "rendered"',
		'm)^[ \t]*ObsoleteSource := ConfigFullSnapshotCaptureObsoleteSource\(SourceImage\["source_content"\]\)',
		'm)^[ \t]*Updates := HasMethod\(CollectFn, "Call"\)[ \t]*\n[ \t]*\? CollectFn\.Call\(\)',
		'm)^[ \t]*Updates := _ConfigKeepOutdatedEntries\(Updates\)',
		'm)^[ \t]*if SourceImage is Map[ \t]*\n[ \t]*Updates := ConfigFullSnapshotPreserveObsoleteSource\(ObsoleteSource, Updates\)',
		'm)^[ \t]*Updates := _ConfigPrepareTypedUpdates\(Updates\)',
		'm)^[ \t]*if HasMethod\(WriterFn, "Call"\)[ \t]*\n[ \t]*Written := WriterFn\.Call\(BoundPath, Updates\)',
		'm)^[ \t]*Written := _TOML_BatchWriteImpl\(BoundPath, Updates, \[\], "write",[ \t]*\n[ \t]*SourceImage\["source_content"\], SourceImage\["source_present"\], true\)',
		'm)^[ \t]*if \(\(Written is Integer\) && Written == 1\)',
		'm)^[ \t]*_ConfigFullSaveAcknowledge\(TargetGeneration\)'
	]
	Tokens := ["SourceImage", "if", "SourceImage", "if", "ObsoleteSource", "Updates", "Updates", "if", "Updates", "if", "Written", "if", "_ConfigFullSaveAcknowledge"]
	Code := _DriverMaskNonCode(&Body)
	Cursor := 1
	for Index, Pattern in Patterns {
		Position := RegExMatch(Body, Pattern, &Matched, Cursor)
		if !Position
			return false
		Offset := InStr(Matched[0], Tokens[Index], true)
		if !Offset || SubStr(Code, Position + Offset - 1, StrLen(Tokens[Index])) != Tokens[Index]
			return false
		Cursor := Position + 1
	}
	return _CPC_CountOccurrences(Code, "_TOML_BatchWriteImpl(") == 1
}

_CPC_FullSnapshotRetainsSourcePolicyAndStrictAck() {
	Full := _StripFullLineComments(_DriverFuncBody("SaveFullConfig"))
	Policy := _StripFullLineComments(_DriverFuncBody("ConfigFullSnapshotPreserveObsoleteSource"))
	Scope := _StripFullLineComments(_DriverFuncBody("ConfigScopePreserveObsoleteSource"))
	Assert(Full != "" && Policy != "" && Scope != "", "the real full-state and scope source owners must exist")
	Assert(_CPC_FullSnapshotSourceChain(Full), "current source admission, neutral filtering, exact-source publication and strict generation ACK remain one native chain")
	Assert(InStr(Policy, "for Operation in ConfigObsoleteSourceOperations(Updates)") > 0
		&& InStr(Policy, "ConfigObsoleteParentsPreserve([Operation], Obsolete)") > 0,
		"every ordered snapshot occurrence uses the same unchanged shared policy and obsolete source")
	Assert(InStr(Scope, "ConfigObsoleteParentsPreserve(ConfigObsoleteSourceOperations(Updates), Obsolete)") > 0,
		"ordinary scope duplicate refusal remains the complete-batch shared contract")
	Capture := _StripFullLineComments(_DriverFuncBody("ConfigFullSnapshotCaptureObsoleteSource"))
	Classifier := _StripFullLineComments(_DriverFuncBody("ConfigObsoleteSnapshotEntries"))
	Assert(Capture != "" && Classifier != "", "current typed source admission and native classification owners must exist")
	AssertEqual(1, _CPC_CountOccurrences(Capture, "ConfigTomlDecodeSnapshot(Source)"), "fresh full-state admission decodes its captured source once")
	Assert(InStr(Capture, "ConfigMigrateClassify(Snapshot.Document, ConfigMigrateShippedRegistry(), &Version)") > 0
		&& InStr(Capture, 'if Outcome != "current"') > 0
		&& InStr(Capture, "return ConfigObsoleteSnapshotEntries(Snapshot)") > 0,
		"the typed semantic schema owner and obsolete classifier share the exact admitted generation")
	Assert(InStr(Classifier, "TomlConfigOutdatedReason(") > 0 && InStr(Classifier, "for Row in Snapshot.Rows") > 0,
		"native published metadata, rather than a boot warning cache, classifies the actual source rows")

	AssertFalse(_CPC_FullSnapshotSourceChain(StrReplace(Full,
		'SourceImage["source_content"], SourceImage["source_present"], true)',
		'SourceImage["content"], SourceImage["source_present"], true)')), "rendered candidate bytes cannot replace captured source authority")
	AssertFalse(_CPC_FullSnapshotSourceChain(StrReplace(Full,
		'Written := _TOML_BatchWriteImpl(BoundPath, Updates, [], "write",',
		'TOML_ConfigBatchWrite(BoundPath, Updates)')), "rereading a later source cannot replace the admitted generation")
	AssertFalse(_CPC_FullSnapshotSourceChain(StrReplace(Full,
		"if ((Written is Integer) && Written == 1)", "if Written")), "truthy malformed writer receipts never authorize acknowledgment")
	AssertFalse(_CPC_FullSnapshotSourceChain(StrReplace(Full,
		"Updates := ConfigFullSnapshotPreserveObsoleteSource(", "Updates := IgnoreObsoleteSource(")), "missing neutral preservation invalidates the full-snapshot owner")
	Call := 'Written := _TOML_BatchWriteImpl(BoundPath, Updates, [], "write",`n'
		. '`t`t`t`t`t`tSourceImage["source_content"], SourceImage["source_present"], true)'
	Assert(InStr(Full, Call, true) > 0, "the decoy must replace the actual native writer call")
	Quoted := "AuditText := " . Chr(39) . "`n(`n`t`t" . Call . "`n)" . Chr(39)
	AssertFalse(_CPC_FullSnapshotSourceChain(StrReplace(Full, Call, Quoted, true)),
		"a copied writer call in continuation data cannot authorize publication")
	AssertFalse(_CPC_FullSnapshotSourceChain(StrReplace(Full, Call, "/*`n" . Call . "`n*/", true)),
		"a copied writer call in a block comment cannot authorize publication")
	AssertFalse(_CPC_FullSnapshotSourceChain(StrReplace(Full, "Written := _TOML_BatchWriteImpl(", "UnrelatedWritten := _TOML_BatchWriteImpl(")),
		"a suffix-sharing output name cannot authorize the actual Written acknowledgment")
	AssertFalse(_CPC_FullSnapshotSourceChain(StrReplace(Full, "SourceImage := TOML_BuildConfigUpdatedContent(", "UnrelatedSourceImage := TOML_BuildConfigUpdatedContent(")),
		"a suffix-sharing source variable cannot lend its unrelated capture")

}
Test("AHK-15-persistence: actual full snapshot retains shared source policy and exact native ACK", _CPC_FullSnapshotRetainsSourcePolicyAndStrictAck)


_CPC_NativeTernaryRequiresTestedStatus() {
	Body := _StripFullLineComments(_DriverFuncBody("_ConfigInvokeCommitWriter"))
	Assert(Body != "", "the native writer dispatch must be readable")
	Lines := StrSplit(Body, "`n", "`r"), Calls := 0
	for Index, Line in Lines {
		if !RegExMatch(Line, '^\s*:\s*TOML_BatchWrite\(')
			continue
		Calls += 1
		AssertTrue(_CPC_LineConsumesResult(Lines, Index), "both actual assigned native branches consume the same status")
		Unchecked := StrSplit(StrReplace(Body, "if !((Written is Integer) && Written == 1)", "if true"), "`n", "`r")
		AssertFalse(_CPC_LineConsumesResult(Unchecked, Index), "omitting the real result check refuses the continuation")
		OtherStatus := Lines.Clone()
		OtherStatus[Index - 1] := StrReplace(OtherStatus[Index - 1], "Written :=", "Ignored :=")
		AssertFalse(_CPC_LineConsumesResult(OtherStatus, Index), "checking another variable cannot acknowledge this branch")
		Commented := Lines.Clone()
		Commented[Index - 1] := "; " . Commented[Index - 1]
		AssertFalse(_CPC_LineConsumesResult(Commented, Index), "a commented assignment grants no result owner")
		Unqualified := Lines.Clone()
		Unqualified[Index] := StrReplace(Line, ", NativeAdmission)", ")")
		AssertFalse(_CPC_LineConsumesResult(Unqualified, Index), "an unreviewed continuation is not silently admitted")
	}
	AssertEqual(2, Calls, "the two actual guarded and default native dispatch branches remain enrolled")
}
Test("AHK-15-persistence: adjacent native ternary branches retain tested result ownership", _CPC_NativeTernaryRequiresTestedStatus)
