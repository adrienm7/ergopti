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
			"i)^\s*(?:(?:if|else\s+if)\b[^\r\n]*\b|(?:try\s+)?return\s+)"
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

_CPC_EveryDirectTomlWriterConsumesItsBoolean() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for the AHK-15 TOML caller scan")
	Calls := 0
	Lines := StrSplit(Src, "`n", "`r")
	for Index, Line in Lines {
		if !RegExMatch(Line, "\b(?:TOML_(?:Write|BatchWrite)|ConfigCommitUpdates)\(")
			continue
		if _CPC_IsFunctionDeclaration(Lines, Index)
			continue
		Calls += 1
		Assert(_CPC_LineConsumesResult(Lines, Index),
			"direct TOML writer result is discarded: '" . Trim(Line) . "'. TOML failures return false rather than throwing, so every production caller must test, assign or return that boolean")
	}
	; Audited inventory: config_shortcuts (1), config_io (9), gestures (4),
	; i18n (1), TOML_Write (1), personal editor (1), trigger journal (1),
	; and menu rebuild (1). Pin the exact census so deleting a caller cannot make
	; this class guard progressively vacuous, while every future sibling is still
	; inspected by the loop above before the inventory assertion is reached.
	AssertEqual(19, Calls,
		"the production TOML writer/transaction-gateway inventory changed; audit every added or removed caller before updating the expected census")
}
Test("AHK-15-persistence: every TOML writer and transaction gateway consumes its boolean",
	_CPC_EveryDirectTomlWriterConsumesItsBoolean)

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
		"a reload-path feature toggle and its mutex siblings must share one feature batch")
	Assert(InStr(ToggleBody, "_MutexSiblingPathsForV2(V2Path)") > 0,
		"the shared toggle batch must still enumerate every mutually exclusive sibling")
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
	Assert(Body != "", Name . " must exist for the AHK-15 bulk transaction guard")
	PersistPos := InStr(Body, "ConfigCommitUpdates(")
	ReloadPos := InStr(Body, "ReloadPreservingSuspend()")
	Assert(InStr(Body, "Candidate") > 0,
		Name . " must build detached candidate state instead of mutating live Maps before persistence")
	Assert(PersistPos > 0, Name . " must commit through the single boolean-consuming helper")
	Assert(ReloadPos == 0 or PersistPos < ReloadPos,
		Name . " must not reload before its durable commit succeeds")
	Prefix := SubStr(Body, 1, PersistPos - 1)
	Assert(!RegExMatch(Prefix,
		"m)^\s*(?:Features|CategoryEnabled|TapHold|GestureAssignments|KeyboardShortcutAssignments|ScriptShortcutAssignments)\s*(?:\[|:=)"),
		Name . " must not publish or mutate a live shared Map before ConfigCommitUpdates returns true")
	Assert(!RegExMatch(Prefix, "m)^\s*WPMWidget\.[A-Za-z_][A-Za-z0-9_]*\s*:="),
		Name . " must not publish WPM state before ConfigCommitUpdates returns true")
	Assert(InStr(Body, "TOML_Write(") = 0 and InStr(Body, "TOML_BatchWrite(") = 0
		and InStr(Body, "WriteFeatureV2(") = 0 and InStr(Body, "WriteFeatureBatchV2(") = 0,
		Name . " must use one ConfigCommitUpdates batch per branch, not sibling read-modify-write calls")
	ExpectedCommits := (Name == "ToggleCategoryAllFeatures") ? 2 : 1
	AssertEqual(ExpectedCommits, _CPC_CountOccurrences(Body, "ConfigCommitUpdates("),
		Name . " must keep exactly one config.toml batch on each mutually exclusive mutation branch")
	if (Name == "ToggleAllFeatures") {
		GatePos := InStr(Body, "ApplyMasterGatesToFeatures(")
		PublishPos := InStr(Body, "Features := CandidateFeatures")
		TapHoldPublishPos := InStr(Body, "TapHold := CandidateTapHold")
		CriticalPos := InStr(Body, 'Critical("On")')
		CriticalReleasePos := InStr(Body, "Critical(PreviousCritical)")
		Assert(InStr(Body, "CandidateTapHold := _HSDeepCloneMap(TapHold)") > 0
			and GatePos > 0 and GatePos < PersistPos,
			"the detached TapHold candidate must be master-gated before the config.toml commit")
		Assert(InStr(Body, "_TH_PersistTapHoldDisabled") = 0
			and InStr(Body, "_TH_WriteTapHoldToml") = 0,
			"the bulk toggle must not mutate a second durable store outside its config.toml transaction")
		Assert(TapHoldPublishPos > PublishPos and TapHoldPublishPos > CriticalPos
			and TapHoldPublishPos < CriticalReleasePos,
			"the master-gated TapHold candidate must publish in the same Critical window as every sibling Map")
	}
	if (Name == "ToggleAllHotstrings") {
		Assert(InStr(Body, "_CollectAllHotstringsV2Paths(CandidateFeatures)") > 0,
			"personal hotstring discovery must seed only the detached candidate before persistence")
		CollectorBody := _DriverFuncBody("_CollectAllHotstringsV2Paths")
		Assert(InStr(CollectorBody, "_ConfigSeedPersonalHotstring(FeaturesTarget") > 0
			and InStr(CollectorBody, "EnsurePersonalHotstringFeature(") = 0,
			"the hotstring path collector must not mutate the live Features global")
	}
}

_CPC_BulkMutationsStageBeforePublishing() {
	for Name in ["ToggleAllFeatures", "ToggleAllHotstrings", "ToggleCategoryAllFeatures",
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
		"_ReloadPreservingSuspendNonCritical(SuccessFn, ExistingBundle)") > 0
		and InStr(ReloadWrapper, "Reload()") = 0,
		"ReloadPreservingSuspend must only drop inherited Critical and delegate")
	Assert(InStr(ReloadBody, "SuspendHandoffReload(") > 0
		and InStr(ReloadBody, "ReloadTerminalInvoke.Bind(") > 0
		and InStr(ReloadBody, "Reload()") = 0,
		"ReloadPreservingSuspend must let the tested helper gate the real Reload call")
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
