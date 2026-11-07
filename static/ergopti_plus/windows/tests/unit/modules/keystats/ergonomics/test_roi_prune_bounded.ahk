; tests/unit/modules/keystats/ergonomics/test_roi_prune_bounded.ahk

; ==============================================================================
; MODULE: ROI Bounded-Prune Behaviour Tests
; DESCRIPTION:
; The 501st distinct candidate word used to insertion-sort the complete map
; inside Critical, freezing the keyboard for 203-359 ms. These tests drive the
; production selector and publication transaction: survivors retain the exact
; frequency/insertion-order policy, interpreted work uses bounded passes, and a
; stale snapshot can never overwrite a word recorded while selection was running.
; (AHK-11.)
; ==============================================================================

#Requires AutoHotkey v2.0

_ROIP_AdversarialCounts() {
	Counts := Map()
	loop 501 {
		; Descending distinct frequencies are the insertion sort's quadratic case.
		Counts[Format("word{1:03}", A_Index)] := 503 - A_Index
	}
	return Counts
}

_ROIP_SelectorIsBoundedAndExact() {
	Counts := _ROIP_AdversarialCounts()
	Operations := 0
	Survivors := KL_Roi_SelectWordCountSurvivors(Counts, 250, &Operations)

	AssertEqual(250, Survivors.Count,
		"the selector must shrink a saturated candidate map to the configured target")
	loop 250 {
		AssertTrue(Survivors.Has(Format("word{1:03}", A_Index)),
			"the highest-frequency candidates must survive the prune")
	}
	AssertFalse(Survivors.Has("word251"),
		"the first candidate below the survivor boundary must be evicted")
	Assert(Operations <= 1300,
		"501 entries must stay within three bounded interpreted passes, never quadratic insertion sort; operations=" . Operations)

	; Equal counts preserve Map insertion order in the old stable sort: eviction
	; removes the earliest ties, so later observations survive at the boundary.
	Ties := Map("early", 3, "middle", 3, "late", 3, "noise", 1)
	TieOps := 0
	TieSurvivors := KL_Roi_SelectWordCountSurvivors(Ties, 2, &TieOps)
	AssertFalse(TieSurvivors.Has("early"),
		"the earliest equal-frequency candidate must be evicted at the boundary")
	AssertTrue(TieSurvivors.Has("middle") && TieSurvivors.Has("late"),
		"later equal-frequency candidates must retain the historical tie policy")
	AssertFalse(TieSurvivors.Has("noise"),
		"single-occurrence noise must still be discarded before frequency selection")
}
Test("keystats ROI: survivor selection is exact and bounded (roi-prune-bounded)",
	_ROIP_SelectorIsBoundedAndExact)

_ROIP_StaleSnapshotCannotPublish() {
	State := {word_counts: Map("live", 7), word_counts_generation: 10}
	Stale := Map("stale", 99)

	AssertFalse(KL_Roi_TryPublishPrunedCounts(State, 9, Stale),
		"a snapshot whose generation lost a race must not replace live word counts")
	AssertTrue(State.word_counts.Has("live") && !State.word_counts.Has("stale"),
		"rejecting a stale prune must leave the live map unchanged")
	AssertEqual(10, State.word_counts_generation,
		"rejecting a stale prune must not advance the live generation")

	AssertTrue(KL_Roi_TryPublishPrunedCounts(State, 10, Stale),
		"the current generation must publish its precomputed survivor map")
	AssertTrue(State.word_counts.Has("stale") && !State.word_counts.Has("live"),
		"a current prune must atomically swap the complete survivor map")
	AssertEqual(11, State.word_counts_generation,
		"a successful publication must advance the generation")
}
Test("keystats ROI: stale prune publication is rejected (roi-prune-bounded)",
	_ROIP_StaleSnapshotCannotPublish)

_ROIP_TransactionPublishesBoundedSurvivors() {
	State := {word_counts: _ROIP_AdversarialCounts(), word_counts_generation: 20}
	Generation := 0
	Snapshot := KL_Roi_SnapshotWordCounts(State, &Generation)
	Operations := 0
	Survivors := KL_Roi_SelectWordCountSurvivors(Snapshot, 250, &Operations)

	AssertTrue(KL_Roi_TryPublishPrunedCounts(State, Generation, Survivors),
		"the prune transaction must publish when its snapshot is current")
	AssertEqual(250, State.word_counts.Count,
		"the transaction must publish exactly the requested number of survivors")
	AssertEqual(21, State.word_counts_generation,
		"the prune transaction must advance its publication generation once")
}
Test("keystats ROI: prune transaction swaps bounded survivors (roi-prune-bounded)",
	_ROIP_TransactionPublishesBoundedSurvivors)

#Include test_roi_halflife_native64_owner.ahk


_KRCTX_ChildSource() {
	global _DriverDir
	Source := _KSD_ChildSource()
	Footer := "#Include " . _DriverDir . "\tests\fixtures\switch_destination_privacy_owner_body.ahk`n"
	AssertEqual(Footer, SubStr(Source, StrLen(Source) - StrLen(Footer) + 1))
	Source := SubStr(Source, 1, StrLen(Source) - StrLen(Footer))
	Common := RTrim(FileRead(_DriverDir . "\tests\fixtures\switch_destination_privacy_owner_body.ahk", "UTF-8"), "`r`n")
	Entry := "_KSD_Main()"
	AssertEqual(Entry, SubStr(Common, StrLen(Common) - StrLen(Entry) + 1))
	Source .= SubStr(Common, 1, StrLen(Common) - StrLen(Entry)) . "`n"
	Owner := _DriverProductionFileForSymbol("KL_Roi_OnChar", _DriverDir)
	OwnerSource := FileRead(Owner, "UTF-8")
	for ClassName in ["KLRoiConst", "KLRoi"] {
		AssertTrue(RegExMatch(OwnerSource, "ms)^class " . ClassName . " \{.*?^\}", &Definition) > 0)
		Source .= Definition[0] . "`n"
	}
	PruneOwner := _DriverProductionFileForSymbol("KL_Roi_IncrementWordCount", _DriverDir)
	AssertTrue(PruneOwner != "")
	Source .= "#Include " . PruneOwner . "`n"
	; _TextCodepointWidth arrives with its whole owner through _KSD_ChildSource;
	; a second copy of its body is a duplicate declaration the child refuses.
	for Symbol in ["KL_MarkSynthetic", "KL_ClearSynthetic", "KL_Roi_RequireInit", "KL_Roi_DiscardWord", "KL_Roi_AdmitWordContext", "KL_Roi_OnChar", "KL_Roi_ProcessWord", "KL_Roi_PruneWordCounts"] {
		Body := _DriverFuncBody(Symbol)
		AssertTrue(Body != "", "The complete real ROI path must resolve: " . Symbol)
		Source .= Body . "`n"
	}
	return Source . "#Include " . _DriverDir . "\tests\fixtures\roi_context_word_owner_body.ahk`n"
}

_KRCTX_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unresolved old child cannot be replaced")
	Directory := A_Temp . "\ergopti_roi_context_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Creation := FSCreateDirectoryExclusiveStrict(Directory)
	AssertTrue(Creation is Integer && Creation == 1, "The child must exclusively acquire its directory before writing or recursive cleanup.")
	Script := Directory . "\subject.ahk"
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _KRCTX_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _KSD_Complete.Bind(State))
		AssertTrue(Handle.start(), "The real private child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The exact switch-destination child did not settle within its 15000 ms deadline.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
			if Retired
				DirDelete(Directory, true)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := {Handle: Handle, Directory: Directory}
			Critical(PreviousCritical)
		}
	}
	try {
		if State.Calls == 1 {
			; The tree adapter combines its native stdout/stderr captures. This is
			; not an independently measured stderr channel.
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# roi-context-child " . Line)
		}
	} catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired)
	AssertEqual(1, AtDeadline.Calls)
	AssertEqual("", AtDeadline.ErrorText, AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, AtDeadline.Output)
	AssertContains(AtDeadline.Output, "PASS roi-context-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
	return AtDeadline.Output
}

for _KRCTX_Mode in ["same-app", "cross-app", "same-context-refresh", "cross-window", "cross-title"]
	Test("Keystats ROI word context: " . _KRCTX_Mode . " proposes only complete typed words (roi-context-word-owner)",
		_KRCTX_Case.Bind(_KRCTX_Mode))

Test("Keystats ROI word context: synthetic marker without hook callbacks retires the fragment (roi-context-word-owner)",
	_KRCTX_Case.Bind("synthetic-gap"))
