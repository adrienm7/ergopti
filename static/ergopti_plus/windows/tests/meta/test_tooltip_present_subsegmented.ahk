; tests/meta/test_tooltip_present_subsegmented.ahk

; ==============================================================================
; MODULE: Tooltip.Present Sub-segmentation Meta Test
; DESCRIPTION:
; Since the UIA bounded-wait fix, Tooltip.Present is the driver's dominant
; hot-path offender — 102 of 194 slow lines on the first day after that fix,
; ~12.9 ms mean, min 6.14 ms — and every proposal aimed at it was speculation,
; because the segment aggregates six steps and attributes none of them.
;
; The reason attribution was missing is structural, not an oversight: the
; profiler only prints a segment once it exceeds _HOTPATH_SLOW_MS (5 ms), and
; every sub-step of Present measures between 0.02 ms and 4.4 ms. Giving each one
; its own HotPath_LogIfSlow would therefore have produced exactly nothing. The
; sub-steps instead accumulate into a buffer that the PARENT renders into its
; own, already-gated line.
;
; ROOT CAUSE ENCODED: a composite segment whose parts are individually below the
; reporting floor is unmeasurable, and an unmeasurable segment gets optimised by
; guesswork. Two failure modes make it silently unmeasurable again:
;   1. a step added to the sequence without its own mark, so its cost is folded
;      into a neighbour and the breakdown lies rather than being absent;
;   2. a presenting call site that never drains the buffer, which both loses the
;      attribution and leaks stale marks into whichever segment prints next.
;
; SCOPE: source introspection via the move-resilient driver-source helpers.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================================
; ===========================================
; ======= 1/ Every step is attributed =======
; ===========================================
; ===========================================

; Positions of every step _TooltipPresentStack performs, derived from the body
; rather than named here: a step is a call to one of the module's own helpers.
; Derivation is the point — a sixth helper spliced into the sequence joins this
; list automatically and must earn its own mark, instead of silently inflating
; whichever neighbouring mark happens to bracket it.
; @param Body {String} _TooltipPresentStack's body.
; @returns {Array} 1-based positions within Body, in call order.
_TPS_StepPositions(Body) {
	Positions := []
	; Skip the definition line, whose own name would otherwise count as a step.
	Pos := InStr(Body, "{")
	while (Pos := RegExMatch(Body,
		"(?<![A-Za-z0-9_])_Tooltip[_A-Za-z0-9]*\(", , Pos + 1)) {
		Positions.Push(Pos)
	}
	return Positions
}

_TPS_EveryStepCarriesItsOwnMark() {
	Body := _DriverFuncBody("_TooltipPresentStack")
	Assert(Body != "", "_TooltipPresentStack() must exist in the driver source")

	BeginPos := InStr(Body, "HotPath_BreakdownBegin(")
	Assert(BeginPos > 0,
		"_TooltipPresentStack must clear the sub-step accumulator before it starts. Without the reset, marks left by an earlier render — or by the destack rebuild, which presents through the same function — are attributed to this one")

	Steps := _TPS_StepPositions(Body)
	Assert(Steps.Length >= 4,
		"_TooltipPresentStack must still perform its rendering steps (found " . Steps.Length . ") — a derivation that finds none would make this guard vacuous")

	Assert(BeginPos < Steps[1],
		"the accumulator reset must come before the first step, or that step's cost is measured into whatever the previous render left behind")

	; A mark must separate each pair of consecutive steps, and one must follow the
	; last: two steps sharing an interval means one of them is billed to the other.
	Marks := []
	Pos := 1
	while (Pos := InStr(Body, "HotPath_BreakdownMark(", , Pos)) {
		Marks.Push(Pos)
		Pos += 1
	}
	Assert(Marks.Length >= Steps.Length,
		"every step of _TooltipPresentStack must close its own sub-segment: found " . Steps.Length . " step(s) but only " . Marks.Length . " mark(s). An unmarked step is folded into a neighbour, which is worse than no breakdown at all because the number then looks precise and is wrong")

	for Idx, StepPos in Steps {
		Boundary := (Idx < Steps.Length) ? Steps[Idx + 1] : StrLen(Body)
		Separated := false
		for , MarkPos in Marks {
			if (MarkPos > StepPos and MarkPos <= Boundary) {
				Separated := true
				break
			}
		}
		Assert(Separated,
			"step " . Idx . " of _TooltipPresentStack is not followed by its own HotPath_BreakdownMark before the next step. Tooltip.Present aggregates six sub-steps that are each below the profiler's 5 ms reporting floor, so an unattributed step is invisible on its own and silently inflates its neighbour")
	}
}

_TPS_BreakdownCapRetainsEveryMark() {
	Body := _DriverFuncBody("_TooltipPresentStack")
	MarkCount := 0
	Pos := 1
	while (Pos := InStr(Body, "HotPath_BreakdownMark(", true, Pos)) {
		MarkCount += 1
		Pos += 1
	}
	Infra := _DriverDirConcat("infra")
	Assert(RegExMatch(Infra,
		"global\s+_HOTPATH_BREAKDOWN_CAP\s*:=\s*(\d+)", &CapMatch) > 0,
		"hot-path breakdown cap must remain a literal, auditable bound")
	Cap := Integer(CapMatch[1])
	Assert(Cap >= MarkCount,
		"breakdown cap " . Cap . " drops the tail of " . MarkCount
		. " Tooltip.Present marks while still paying their QPC cost")
}





; ====================================================
; ====================================================
; ======= 2/ Every presenter drains the buffer =======
; ====================================================
; ====================================================

; Every driver function that presents a tooltip stack. Verified complete by the
; call-site count below, so a fourth presenter cannot join without being noticed.
_TPS_Presenters() {
	return ["_TooltipShowNow", "_TooltipDequeueRebuild", "_TooltipBuildGuiLlm"]
}

_TPS_EveryPresenterIsMeasuredAndDrains() {
	Src := _DriverSourceNoComments()
	Calls := 0
	Pos := 1
	while (Pos := InStr(Src, "_TooltipPresentStack(", , Pos)) {
		Calls += 1
		Pos += 1
	}
	; One occurrence is the definition itself; the rest are the call sites.
	Assert(Calls - 1 == _TPS_Presenters().Length,
		"the presenter list is out of date: the driver has " . (Calls - 1) . " _TooltipPresentStack call site(s) but _TPS_Presenters() names " . _TPS_Presenters().Length . ". A presenting path with no segment renders exactly the same pixels at exactly the same cost and reports nothing")

	for Name in _TPS_Presenters() {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist in the driver source")
		Assert(InStr(Body, "_TooltipPresentStack(") > 0,
			Name . " no longer presents a stack — remove it from _TPS_Presenters() rather than leaving an entry the guard cannot check")
		Assert(InStr(Body, "HotPath_LogIfSlow(") > 0,
			Name . " must wrap its present in a HotPath segment, or the dominant slow segment in the driver has a path that never reports")
		Assert(InStr(Body, "HotPath_BreakdownDetail()") > 0,
			Name . " must drain the sub-step accumulator into its own log line. A presenter that never drains loses the attribution AND leaves stale marks in the buffer, which the next segment to print would then report as its own")
	}
}


; A visible hotstring decision and its pixels are one publication. The three
; renderers share _TooltipPresentStack, so pin the invariant there rather than
; testing only the ordinary TooltipShow caller and leaving the destack/LLM
; siblings free to replace the surface without retiring the old decision.
_TPS_VisibleDecisionCommitHasOneTransitiveOwner() {
	Present := _StripFullLineComments(_DriverFuncBody("_TooltipPresentStack"))
	Assert(Present != "", "_TooltipPresentStack() must exist in the driver source")
	CriticalOn := InStr(Present, 'Critical("On")')
	OwnerCheck := InStr(Present, "_TooltipChoosePreparedSurface(", true,
		CriticalOn)
	DecisionCheck := InStr(Present, "_TooltipDecisionItemsStillCurrent(", true,
		OwnerCheck)
	DeadlineCheck := InStr(Present, "_TooltipAbsoluteDeadlinesStillLive(", true,
		DecisionCheck)
	LifecycleDeadline := InStr(Present,
		"_TooltipLifecycleDeadlineBounds(", true, DeadlineCheck)
	Retire := InStr(Present, "_TooltipHideSurfaceObjects(", true,
		LifecycleDeadline)
	TimerArm := InStr(Present, "SetTimer(_TooltipTimerFn", true, Retire)
	Reveal := InStr(Present, "_TooltipRevealPreparedSurfaces(", true, Retire)
	Publish := InStr(Present, "_TooltipPublishVisibleDecisions(", true, Reveal)
	CriticalOff := InStr(Present, "Critical(PreviousCritical)", true, Publish)
	PostPresent := InStr(Present, "_TooltipNotifySurfacePresented(", true,
		CriticalOff)
	Assert(CriticalOn > 0 and OwnerCheck > CriticalOn
		and DecisionCheck > OwnerCheck and DeadlineCheck > DecisionCheck
		and LifecycleDeadline > DeadlineCheck and Retire > LifecycleDeadline
		and TimerArm > Retire and Reveal > TimerArm
		and Publish > Reveal and CriticalOff > Publish,
		"the common presenter must atomically recheck owner/context/current deadline, arm the lifecycle owner, reveal pixels, publish exactly their decision items, then restore interruptibility")
	Assert(PostPresent > CriticalOff,
		"metrics and LLM follow-up must run only after the pixel/oracle Critical commit; scheduling from the transaction can stall the keyboard thread and scheduling from TooltipShow creates phantom events for renders UIA later rejects")
	Assert(InStr(Present, "PublishItems := IsObject(Items) ? Items : []") > 0,
		"a direct non-hotstring presenter must publish [] so replacing the shared surface retires any older hotstring decision")
	Assert(InStr(Present, "_TooltipActiveSurface := PreparedSurface") > 0,
		"the common commit must publish one complete surface record instead of exposing content, border, trackers and position through separate globals")

	Show := _StripFullLineComments(_DriverFuncBody("_TooltipShowNow"))
	Destack := _StripFullLineComments(_DriverFuncBody("_TooltipDequeueRebuild"))
	Llm := _StripFullLineComments(_DriverFuncBody("_TooltipBuildGuiLlm"))
	NormalizedShow := RegExReplace(Show, "\s+", " ")
	Assert(InStr(NormalizedShow,
		"_TooltipPresentStack(Pos, Row, ArmSafety, OwnedPresentation ? [] : Items, RenderGeneration, OwnedPresentation, RequestSerial, LifecyclePlan, CommitFn)") > 0,
		"the ordinary/owned presenter must give the common commit the exact rows and semantic tuple it reveals")
	Assert(RegExMatch(Destack,
		"_TooltipPresentStack\(Pos, Row, false, Items,\s*RenderGeneration, false, RebuildRequestSerial,\s*LifecyclePlan\)") > 0,
		"the destack presenter must publish only its surviving rows")
	Assert(RegExMatch(Llm,
		"_TooltipPresentStack\(Pos, Row, false, \[\],\s*RenderGeneration, true, -1, 0, StateCommit\)") > 0,
		"the direct rich LLM presenter must fence its generation and publish [] so replacing the shared surface retires the old hotstring decision")

	Build := _StripFullLineComments(_DriverFuncBody("_TooltipBuildGui"))
	Assert(InStr(Build, "_TooltipActiveSurface :=") == 0,
		"ordinary GUI build must return a detached candidate and never replace or destroy the active surface before the final owner fence")
	Assert(InStr(Llm, "_TooltipSuspendSurfaces(") == 0
		and InStr(Llm, "_TooltipTeardownBorder(") == 0
		and InStr(Llm, "_TooltipActiveSurface :=") == 0
		and InStr(Llm, "G.Destroy(") == 0,
		"rich LLM build must leave the active surface untouched while its detached candidate pumps GUI/UIA messages")

	Hide := _StripFullLineComments(_DriverFuncBody("TooltipHide"))
	HideCriticalOn := InStr(Hide, 'Critical("On")')
	OwnershipGuard := InStr(Hide, "and _llm_was_visible", true,
		HideCriticalOn)
	DequeueGuard := InStr(Hide, "if (!Force and _TooltipDequeueActive)",
		true, OwnershipGuard)
	Clear := InStr(Hide,
		"HotstringPrefixWatcherClearVisibleDecisions(false)", true,
		HideCriticalOn)
	HideCriticalOff := InStr(Hide, "Critical(PreviousCritical)", true,
		Clear)
	DismissEmit := InStr(Hide,
		"HotstringPrefixWatcherEmitDismissedRecord(DismissedRecord)", true,
		HideCriticalOff)
	Assert(HideCriticalOn > 0 and OwnershipGuard > HideCriticalOn
		and DequeueGuard > OwnershipGuard and Clear > DequeueGuard,
		"surface/dequeue ownership refusal and visible-decision detach must share the pure hide transaction")
	Assert(HideCriticalOff > Clear and DismissEmit > HideCriticalOff,
		"TooltipHide must detach decision/metric state in its pixel transaction but defer privacy/keylogger dismissal work until Critical is restored")
}

; TooltipShow and its deferred callback share one mutable slot. All tuple fields
; must therefore travel in one immutable record, and a resumed old request must
; carry a serial to the common pixel commit instead of relying on timer cancel.
_TPS_DeferredRequestTupleHasOneOwner() {
	Show := _StripFullLineComments(_DriverFuncBody("TooltipShow"))
	Deferred := _StripFullLineComments(
		_DriverFuncBody("_TooltipDeferredShowFn"))
	Now := _StripFullLineComments(_DriverFuncBody("_TooltipShowNow"))
	Present := _StripFullLineComments(_DriverFuncBody("_TooltipPresentStack"))
	Timer := _StripFullLineComments(_DriverFuncBody("_TooltipTimerFn"))
	TimerRetry := _StripFullLineComments(
		_DriverFuncBody("_TooltipTimerHideOrRetry"))
	DeadlineTimer := _StripFullLineComments(
		_DriverFuncBody("_TooltipDequeueDeadlineFn"))
	Poll := _StripFullLineComments(_DriverFuncBody("_TooltipDequeuePollFn"))
	Assert(InStr(Show, "Request := {") > 0
		and InStr(Show, "_TooltipPendingRequest := Request") > 0,
		"TooltipShow must publish Items/Duration/ArmSafety/Origin/Serial as one immutable record")
	ShowCritical := InStr(Show, 'Critical("On")')
	CancelOld := InStr(Show, "SetTimer(OldRequest.TimerFn, 0)", true,
		ShowCritical)
	Publish := InStr(Show, "_TooltipPendingRequest := Request", true,
		ShowCritical)
	Token := InStr(Show,
		"Request.TimerFn := _TooltipDeferredShowFn.Bind(Request.Serial)",
		true, ShowCritical)
	Arm := InStr(Show, "SetTimer(Request.TimerFn", true, Publish)
	ShowOff := InStr(Show, "Critical(PreviousCritical)", true, Arm)
	Assert(ShowCritical > 0 and CancelOld > ShowCritical
		and Token > CancelOld
		and Publish > Token and Arm > Publish
		and ShowOff > Arm,
		"pending tuple publication and its exact bound timer token must be one short transaction")
	TakeCritical := InStr(Deferred, 'Critical("On")')
	Take := InStr(Deferred, "Request := _TooltipPendingRequest", true,
		TakeCritical)
	SerialGuard := InStr(Deferred,
		"_TooltipPendingRequest.Serial != ExpectedSerial", true,
		TakeCritical)
	TakeOff := InStr(Deferred, "Critical(PreviousCritical)", true, Take)
	Call := InStr(Deferred, "Request.Serial", true, TakeOff)
	ExactClearGuard := InStr(Deferred,
		"ObjPtr(_TooltipPendingRequest) == ObjPtr(Request)", true, Call)
	Clear := InStr(Deferred, "_TooltipPendingRequest := 0", true,
		ExactClearGuard)
	Assert(TakeCritical > 0 and SerialGuard > TakeCritical
		and Take > SerialGuard and TakeOff > Take
		and Call > TakeOff and ExactClearGuard > Call and Clear > ExactClearGuard,
		"the callback must snapshot one complete record, render outside Critical, then clear only that exact tuple so resumed A cannot erase pending B")
	Assert(InStr(Now, "_TooltipRequestOwnerMatches(") > 0
		and InStr(Present, "ExpectedRequestSerial") > 0
		and InStr(Present, "_TooltipRequestOwnerMatches(") > 0
		and InStr(Present, "_TooltipPendingRequest := 0") > 0,
		"request serial A must be rechecked before reservation and again at the common pixel commit after GUI/UIA yields")
	Assert(InStr(Timer, "_TooltipTimerHideOrRetry(") > 0
		and InStr(Timer, "_TooltipPendingRequest") == 0,
		"a due one-shot must delegate to a liveness-preserving exact-owner retry instead of being consumed by a blind pending-request return")
	HideAttempt := InStr(TimerRetry,
		'TooltipHide("TimerFn", true, ExpectedGeneration, ExpectedSurface)')
	RetryArm := InStr(TimerRetry,
		"SetTimer(_TooltipTimerHideOrRetry.Bind(", true, HideAttempt)
	Assert(HideAttempt > 0 and RetryArm > HideAttempt
		and InStr(Poll, "if IsObject(_TooltipPendingRequest)") > 0,
		"the exact old surface must be retried if B temporarily blocks its due hide; a refused B may not leave A immortal")
	DeadlinePending := InStr(DeadlineTimer,
		"if IsObject(_TooltipPendingRequest)")
	DeadlineRetry := InStr(DeadlineTimer,
		"SetTimer(_TooltipDequeueDeadlineTimer", true, DeadlinePending)
	Assert(DeadlinePending > 0 and DeadlineRetry > DeadlinePending,
		"the canonical one-shot sibling must also rearm its exact owner while B is pending instead of falling back to a 100 ms stale-pixel watchdog gap")
}

_TPS_DequeuePollCarriesExactSurfaceOwner() {
	Poll := _StripFullLineComments(_DriverFuncBody("_TooltipDequeuePollFn"))
	Rebuild := _StripFullLineComments(_DriverFuncBody("_TooltipDequeueRebuild"))
	Present := _StripFullLineComments(_DriverFuncBody("_TooltipPresentStack"))
	Snapshot := InStr(Poll, "ExpectedSurface := _TooltipActiveSurface")
	Call := InStr(Poll,
		"_TooltipDequeueRebuild(RebuildItems, ExpectedGeneration, ExpectedSurface)",
		true, Snapshot)
	FirstOwner := InStr(Rebuild, "_TooltipSurfaceOwnerMatches(")
	FirstHide := InStr(Rebuild, "TooltipHide(")
	Reserve := InStr(Rebuild, 'Critical("On")')
	SecondOwner := InStr(Rebuild, "_TooltipSurfaceOwnerMatches(", true,
		Reserve)
	SerialCapture := InStr(Rebuild,
		"RebuildRequestSerial := _TooltipRequestSerial", true, Reserve)
	Plan := InStr(Rebuild, "_TooltipCreateLifecyclePlan(")
	PresentFence := InStr(Rebuild,
		"RenderGeneration, false, RebuildRequestSerial", true,
		SerialCapture)
	LifecycleCarry := InStr(Rebuild, "LifecyclePlan", true, PresentFence)
	CommonSerialFence := InStr(Present, "_TooltipRequestOwnerMatches(")
	CommonDeadline := InStr(Present, "_TooltipLifecycleDeadlineBounds(", true,
		CommonSerialFence)
	CommonTimer := InStr(Present, "SetTimer(_TooltipTimerFn", true,
		CommonDeadline)
	PostPresent := InStr(Present, "_TooltipNotifySurfacePresented(", true,
		CommonTimer)
	Assert(Snapshot > 0 and Call > Snapshot,
		"the poll must pass its captured generation and surface identity through every yielded selection step")
	Assert(InStr(Poll,
		'TooltipHide("PollEmpty", true, ExpectedGeneration, ExpectedSurface)') > 0,
		"even the empty-stack force-hide must require the exact polled surface owner, not generation alone")
	Assert(FirstOwner > 0 and (FirstHide == 0 or FirstOwner < FirstHide)
		and Reserve > FirstOwner and SecondOwner > Reserve
		and Plan > FirstOwner and SerialCapture > SecondOwner
		and PresentFence > SerialCapture and LifecycleCarry > PresentFence
		and CommonSerialFence > 0 and CommonDeadline > CommonSerialFence
		and CommonTimer > CommonDeadline and PostPresent > CommonTimer,
		"a resumed poll must lose before any force-hide and carry request/deadline ownership into the common pixel+timer transaction before post-present work")
	Assert(InStr(Rebuild, "SetTimer(_TooltipTimerFn", true,
		PresentFence) == 0,
		"destack must not arm a timer after the common pixel commit, where its sampled remainder can go stale")
}

_TPS_DeadlineTimerSharesPixelCommit() {
	Now := _StripFullLineComments(_DriverFuncBody("_TooltipShowNow"))
	Present := _StripFullLineComments(_DriverFuncBody("_TooltipPresentStack"))
	Plan := InStr(Now, "_TooltipCreateLifecyclePlan(")
	Call := InStr(Now, "_TooltipPresentStack(", true, Plan)
	CriticalOn := InStr(Present, 'Critical("On")')
	Resolve := InStr(Present, "_TooltipLifecycleDeadlineBounds(", true,
		CriticalOn)
	ExpiredRefusal := InStr(Present, "if DeadlineBounds.Expired", true,
		Resolve)
	SurfaceSwap := InStr(Present,
		"_TooltipActiveSurface := PreparedSurface", true, ExpiredRefusal)
	Timer := InStr(Present, "SetTimer(_TooltipTimerFn", true, SurfaceSwap)
	Reveal := InStr(Present, "_TooltipRevealPreparedSurfaces(", true, Timer)
	CriticalOff := InStr(Present, "Critical(PreviousCritical)", true, Reveal)
	PostPresent := InStr(Present, "_TooltipNotifySurfacePresented(", true,
		CriticalOff)
	Assert(Plan > 0 and Call > Plan and CriticalOn > 0
		and Resolve > CriticalOn and ExpiredRefusal > Resolve
		and SurfaceSwap > ExpiredRefusal and Timer > SurfaceSwap
		and Reveal > Timer and CriticalOff > Reveal
		and PostPresent > CriticalOff,
		"canonical expiry must be recomputed at the pixel fence; an expired row is refused, while a live row publishes its exact timer before reveal and interruptible post-present work")
	Assert(InStr(Now, "SetTimer(_TooltipTimerFn", true, Call) == 0,
		"_TooltipShowNow must not arm a stale remainder after _TooltipPresentStack and its post-present callback return")
}

_TPS_LlmFailureAndTimerKeepExactSurfaceOwner() {
	Show := _StripFullLineComments(_DriverFuncBody("LLM_TooltipShow"))
	Hide := _StripFullLineComments(_DriverFuncBody("LLM_TooltipHide"))
	Build := _StripFullLineComments(_DriverFuncBody("_TooltipBuildGuiLlm"))
	Present := _StripFullLineComments(_DriverFuncBody("_TooltipPresentStack"))
	FailedBuild := InStr(Show,
		"LLM_TooltipHide(false, RenderGeneration, RenderRequestSerial)")
	Resolve := InStr(Show, 'HotstringsResolve("llm_prediction"')
	BuildCall := InStr(Show, "_TooltipBuildGuiLlm(", true, Resolve)
	Assert(Resolve > 0 and BuildCall > Resolve and FailedBuild > BuildCall,
		"prediction timeout must resolve before GUI/UIA work, and every build-failure cleanup must carry its generation/request owner")
	Assert(InStr(Show, "SetTimer(_TooltipTimerFn", true, BuildCall) == 0
		and InStr(Present, "LlmPresented.TimeoutRemainingMs") > 0,
		"only the common exact-surface commit may arm a prediction timeout; the pre-build zero-delay call may only cancel the retired owner")
	StateCommit := InStr(Build,
		"_LLM_TooltipCommitSurfaceState.Bind(")
	PresentCall := InStr(Build, "_TooltipPresentStack(", true,
		StateCommit)
	Assert(StateCommit > 0 and PresentCall > StateCommit,
		"the detached builder must carry its record into the common surface transaction")
	Snapshot := InStr(Hide, "_LLM_TooltipGetCurrentPresentation()")
	Identity := InStr(Hide, "SameRecord := ObjPtr(Record) == ObjPtr(ExpectedRecord)",
		true, Snapshot)
	SurfaceHide := InStr(Hide,
		'TooltipHide("LLM", true, Record.Generation,', true, Identity)
	ChainReset := InStr(Hide, "_LLM_TooltipResetChain()", true,
		SurfaceHide)
	Log := InStr(Hide, "LoggerDebug(", true, ChainReset)
	Assert(Snapshot > 0 and Identity > Snapshot and SurfaceHide > Identity
		and ChainReset > SurfaceHide and Log > ChainReset,
		"LLM hide must revalidate and retire the exact record/surface before resetting its chain or logging")
	Assert(InStr(Build, 'TooltipHide("LlmPresentFail"') == 0,
		"the detached builder must not run an under-fenced sibling hide before its caller can apply the captured request serial")
}

; The post-present hook runs after Critical by design because metrics and LLM
; preparation may perform privacy/focus work. Its immutable surface token must
; consequently survive every hop and be checked again at the exact state/log/
; timer mutation, not merely once at callback entry.
_TPS_PostPresentTokenGuardsEveryMutation() {
	Present := _StripFullLineComments(_DriverFuncBody("_TooltipPresentStack"))
	Notify := _StripFullLineComments(
		_DriverFuncBody("_TooltipNotifySurfacePresented"))
	Watcher := _StripFullLineComments(
		_DriverFuncBody("HotstringPrefixWatcherOnSurfacePresented"))
	Metric := _StripFullLineComments(
		_DriverFuncBody("_NotifySuggestionShownForSurface"))
	ReplacementDismiss := _StripFullLineComments(
		_DriverFuncBody("_NotifySuggestionDismissedForSurfaceReplacement"))
	Append := _StripFullLineComments(_DriverFuncBody("KL_AppendLog"))
	Bridge := _StripFullLineComments(
		_DriverFuncBody("LLM_Bridge_ScheduleAfterHotstring"))
	StartTimer := _StripFullLineComments(_DriverFuncBody("LLM_Engine_StartTimer"))
	Assert(Present != "" and Notify != "" and Watcher != "" and Metric != ""
		and ReplacementDismiss != ""
		and Append != "" and Bridge != "" and StartTimer != "",
		"the complete post-present token chain must be discoverable before checking its mutation fences")

	Assert(InStr(Present,
		"_TooltipNotifySurfacePresented(PublishItems, PreparedSurface)") > 0
		and InStr(Notify,
			"HotstringPrefixWatcherOnSurfacePresented(Items, SurfaceToken)") > 0,
		"the exact surface record atomically installed with the pixels must cross the renderer-to-watcher async boundary")
	Assert(InStr(Watcher,
		"_NotifySuggestionShownForSurface(PrimaryItem.Trigger") > 0
		and InStr(Watcher,
			"LLM_Bridge_ScheduleAfterHotstring(Items, SurfaceToken)") > 0,
		"the watcher must pass the same token to both post-commit mutation owners")
	Assert(InStr(Watcher,
		"_NotifySuggestionDismissedForSurfaceReplacement(SurfaceToken)") > 0,
		"a direct/LLM surface that publishes zero FireDecisions must close the old hotstring metric owner instead of leaving a phantom shown suggestion")
	ReplacementCritical := InStr(ReplacementDismiss, 'Critical("On")')
	ReplacementGuard := InStr(ReplacementDismiss,
		"TooltipSurfaceTokenIsCurrent(SurfaceToken)", true,
		ReplacementCritical)
	ReplacementDetach := InStr(ReplacementDismiss,
		'_KLLastShownSuggestion := ""', true, ReplacementGuard)
	ReplacementOff := InStr(ReplacementDismiss,
		"Critical(PreviousCritical)", true, ReplacementDetach)
	ReplacementEmit := InStr(ReplacementDismiss,
		"_PrefixEmitDetachedSuggestionDismissal(Prev)", true,
		ReplacementOff)
	Assert(ReplacementCritical > 0 and ReplacementGuard > ReplacementCritical
		and ReplacementDetach > ReplacementGuard
		and ReplacementOff > ReplacementDetach
		and ReplacementEmit > ReplacementOff,
		"hotstring-to-direct replacement must token-fence the pure state detach and emit its dismissal only after Critical")

	MetricCritical := InStr(Metric, 'Critical("On")')
	MetricGuard := InStr(Metric,
		"TooltipSurfaceTokenIsCurrent(SurfaceToken)", true, MetricCritical)
	MetricState := InStr(Metric, "_KLLastShownSuggestion := Record", true,
		MetricGuard)
	GuardedLog := InStr(Metric, "KL_LogHotstringSuggestedGuarded(", true,
		MetricState)
	Assert(MetricCritical > 0 and MetricGuard > MetricCritical
		and MetricState > MetricGuard and GuardedLog > MetricState,
		"suggestion state must be token-validated in its short Critical mutation, while privacy/log preparation stays outside that span")
	AppendCritical := InStr(Append, 'AppendCritical := Critical("On")')
	AppendGuard := InStr(Append, "PublishGuard.Call()", true, AppendCritical)
	AppendPush := InStr(Append, "Keylogger._pending_entries.Push(entry)", true,
		AppendGuard)
	AppendCommit := InStr(Append, "PublishCommit.Call()", true, AppendPush)
	Assert(AppendCritical > 0 and AppendGuard > AppendCritical
		and AppendPush > AppendGuard and AppendCommit > AppendPush,
		"the suggested log queue push and its published-state marker must share the final token guard after all privacy/context work")

	Assert(InStr(Bridge,
		"TooltipSurfaceTokenIsCurrent.Bind(SurfaceToken)") > 0,
		"the LLM bridge must carry the surface token into the timer owner's final mutation")
	Capture := InStr(StartTimer, "_LLM_Engine_CaptureAcceptSource()")
	TimerCritical := InStr(StartTimer, 'Critical("On")', true, Capture)
	TimerGuard := InStr(StartTimer, "PublishGuard.Call()", true,
		TimerCritical)
	TimerCancel := InStr(StartTimer, "LLM_Engine_CancelTimer()", true,
		TimerGuard)
	TimerArm := InStr(StartTimer, "SetTimer(_LLM_Engine", true, TimerCancel)
	Assert(Capture > 0 and TimerCritical > Capture and TimerGuard > TimerCritical
		and TimerCancel > TimerGuard and TimerArm > TimerCancel,
		"focus capture must stay outside Critical, then the surface token must be rechecked atomically with cancel + timer re-arm so a stale callback cannot evict newer LLM work")
}


Test("meta tooltip-present: every sub-step of the present sequence carries its own mark",
	_TPS_EveryStepCarriesItsOwnMark)
Test("meta tooltip-present: breakdown cap retains every emitted mark",
	_TPS_BreakdownCapRetainsEveryMark)
Test("meta tooltip-present: every presenting path is profiled and drains its sub-step attribution",
	_TPS_EveryPresenterIsMeasuredAndDrains)
Test("meta tooltip-present: pixels and visible decisions share one transitive commit owner",
	_TPS_VisibleDecisionCommitHasOneTransitiveOwner)
Test("meta tooltip-present: post-present surface token guards state, log and timer mutations",
	_TPS_PostPresentTokenGuardsEveryMutation)
Test("meta tooltip-present: deferred request tuple and serial share one owner",
	_TPS_DeferredRequestTupleHasOneOwner)
Test("meta tooltip-present: dequeue poll carries generation plus surface identity",
	_TPS_DequeuePollCarriesExactSurfaceOwner)
Test("meta tooltip-present: canonical deadline and pixels share one commit",
	_TPS_DeadlineTimerSharesPixelCommit)
Test("meta tooltip-present: LLM cleanup and timer retain exact surface ownership",
	_TPS_LlmFailureAndTimerKeepExactSurfaceOwner)
