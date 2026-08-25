; adapters/llm_nav_event_owner.ahk

; ==============================================================================
; MODULE: LLM navigation event owner
; DESCRIPTION:
; Bridges the dedicated native keyboard-hook owner with exact AHK tooltip
; records. The hook decides PASS/SUPPRESS synchronously and stores only POD
; receipts. AHK retains the Record/Surface pair named by each receipt until it
; has mirrored the native commit and acknowledged that exact sequence.
;
; The native owner is deliberately fail-open while a tooltip surface pointer is
; changing. Therefore every event is linearized either against the old token,
; against the new token, or as the untouched Windows event. No HotIf callback is
; part of this ownership protocol.
; ==============================================================================

#Requires AutoHotkey v2.0

global _LLM_NavEventOwnerStarted := false
global _LLM_NavEventOwnerQuarantined := false
global _LLM_NavEventOwnerStarting := false
global _LLM_NavEventOwnerStartCancelled := false
global _LLM_NavEventOwnerStartRollbackPending := false
global _LLM_NavEventOwnerNextStartTicket := 0
global _LLM_NavEventOwnerActiveStartTicket := 0
global _LLM_NavEventOwnerStopping := false
global _LLM_NavEventOwnerStopPending := false
global _LLM_NavEventOwnerPendingStopRecovery := false
global _LLM_NavEventOwnerLifecycleQuiesced := false
global _LLM_NavEventOwnerLifecycleResuming := false
global _LLM_NavEventOwnerPort := 0
global _LLM_NavEventOwnerNextToken := 0
global _LLM_NavEventOwnerRecords := Map()
global _LLM_NavEventOwnerProfileOwners := Map()
global _LLM_NavEventOwnerActiveProfileToken := 0
global _LLM_NavEventOwnerProfileEffectActive := false
global _LLM_NavEventOwnerShutdownFenced := false
global _LLM_NavEventOwnerDrainActive := false
global _LLM_NavEventOwnerClaimedReceipt := 0
global _LLM_NavEventOwnerPendingRepaints := Map()
global _LLM_NavEventOwnerRepaintFailures := Map()
global _LLM_NavEventOwnerWakeMessage := 0x8057
global _LLM_NavEventOwnerWakeFn := 0
global _LLM_NavEventOwnerServiceFn := 0
global _LLM_NavEventOwnerServiceArmed := false
global _LLM_NavEventOwnerModule := 0
global _LLM_NavEventOwnerExports := Map()
global _LLM_NavEventOwnerPreparedPlans := Map()
global _LLM_NavEventOwnerCommittedPlan := 0
global _LLM_NavEventOwnerLifecycleResumePlan := 0
global _LLM_NavEventOwnerLifecycleResumePort := 0
global _LLM_NavEventOwnerRuntimeEpoch := 0
global LLM_NAV_EVENT_OWNER_INPUT_LEVEL := 1
global LLM_NAV_EVENT_OWNER_QUARANTINE_RETRY_MS := 1000
global LLM_NAV_EVENT_OWNER_REPAINT_MAX_ATTEMPTS := 3
global _LLM_NavEventOwnerLastQuarantineStopAttemptTick := 0
global _LLM_NavEventOwnerReportTimes := Map()

_LLM_NavEventOwnerPortFn(Name, Port := 0) {
	global _LLM_NavEventOwnerPort
	if !(Port is Map) && !IsSet(_LLM_NavEventOwnerPort)
		return 0
	Resolved := Port is Map ? Port : _LLM_NavEventOwnerPort
	if !(Resolved is Map)
		return 0
	Fn := Resolved.Get(Name, 0)
	return HasMethod(Fn, "Call") ? Fn : 0
}

_LLM_NavEventOwnerCall(Name, DefaultFn, Args*) {
	Fn := _LLM_NavEventOwnerPortFn(Name)
	return HasMethod(Fn, "Call") ? Fn.Call(Args*) : DefaultFn.Call(Args*)
}

_LLM_NavEventOwnerReport(Message) {
	global _LLM_NavEventOwnerReportTimes
	Detail := RTrim(String(Message), ".")
	Now := A_TickCount
	Last := _LLM_NavEventOwnerReportTimes.Get(Detail, -60000)
	if ((Now - Last) & 0xFFFFFFFF) < 60000
		return
	_LLM_NavEventOwnerReportTimes[Detail] := Now
	if A_IsCritical {
		SetTimer(_LLM_NavEventOwnerReportNow.Bind(Detail), -1)
		return
	}
	_LLM_NavEventOwnerReportNow(Detail)
}

_LLM_NavEventOwnerReportNow(Detail) {
	try LoggerError("LLM.nav",
		"Navigation event owner failure: {1}.", Detail)
}

_LLM_NavEventOwnerSetServiceTimer(Armed) {
	global _LLM_NavEventOwnerServiceFn
	global _LLM_NavEventOwnerServiceArmed
	if !IsObject(_LLM_NavEventOwnerServiceFn) {
		_LLM_NavEventOwnerServiceArmed := false
		return !Armed
	}
	if Armed
		SetTimer(_LLM_NavEventOwnerServiceFn, 100)
	else
		SetTimer(_LLM_NavEventOwnerServiceFn, 0)
	_LLM_NavEventOwnerServiceArmed := Armed
	return true
}

LLM_NavEventOwner_EnsureStarted(Port := 0, AllowLifecycleResume := false) {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerStarting, _LLM_NavEventOwnerStartCancelled
	global _LLM_NavEventOwnerStartRollbackPending
	global _LLM_NavEventOwnerNextStartTicket
	global _LLM_NavEventOwnerActiveStartTicket
	global _LLM_NavEventOwnerStopping
	global _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerPendingStopRecovery
	global _LLM_NavEventOwnerLifecycleQuiesced
	global _LLM_NavEventOwnerRuntimeEpoch
	global _LLM_NavEventOwnerPort
	global _LLM_NavEventOwnerWakeMessage, _LLM_NavEventOwnerWakeFn
	global _LLM_NavEventOwnerServiceFn
	StartTicket := 0
	StartEpoch := 0
	PreviousCritical := Critical("On")
	try {
		if A_IsSuspended
				|| _LLM_NavEventOwnerStarting
				|| _LLM_NavEventOwnerStartRollbackPending
				|| _LLM_NavEventOwnerStopping || _LLM_NavEventOwnerStopPending
				|| (_LLM_NavEventOwnerPendingStopRecovery
					&& !AllowLifecycleResume)
				|| (_LLM_NavEventOwnerLifecycleQuiesced
					&& !AllowLifecycleResume)
			return false
		if _LLM_NavEventOwnerStarted
			return true
		if Port is Map
			_LLM_NavEventOwnerPort := Port
		_LLM_NavEventOwnerNextStartTicket += 1
		if _LLM_NavEventOwnerNextStartTicket <= 0
			_LLM_NavEventOwnerNextStartTicket := 1
		StartTicket := _LLM_NavEventOwnerNextStartTicket
		StartEpoch := _LLM_NavEventOwnerRuntimeEpoch
		_LLM_NavEventOwnerStarting := true
		_LLM_NavEventOwnerStartCancelled := false
		_LLM_NavEventOwnerActiveStartTicket := StartTicket
	} finally Critical(PreviousCritical)
	StartStatus := false
	FailureDetail := ""
	try StartStatus := _LLM_NavEventOwnerCall("start",
		_LLM_NavEventOwnerNativeStart, A_ScriptHwnd,
		_LLM_NavEventOwnerWakeMessage)
	catch as Err
		FailureDetail := "Navigation event owner failed to start: "
			. Err.Message . "."
	if !((StartStatus is Integer) && StartStatus == 1) {
		if FailureDetail == ""
			FailureDetail := "Navigation event owner start was not acknowledged."
		_LLM_NavEventOwnerRollbackStart(
			StartTicket, FailureDetail, AllowLifecycleResume)
		return false
	}
	Published := false
	PublishedEpoch := 0
	PreviousCritical := Critical("On")
	try {
		Valid := !A_IsSuspended
			&& _LLM_NavEventOwnerStarting
			&& _LLM_NavEventOwnerActiveStartTicket == StartTicket
			&& !_LLM_NavEventOwnerStartCancelled
			&& !_LLM_NavEventOwnerStartRollbackPending
			&& !_LLM_NavEventOwnerStopping
			&& !_LLM_NavEventOwnerStopPending
			&& (!_LLM_NavEventOwnerPendingStopRecovery
				|| AllowLifecycleResume)
			&& _LLM_NavEventOwnerRuntimeEpoch == StartEpoch
			&& (!_LLM_NavEventOwnerLifecycleQuiesced
				|| AllowLifecycleResume)
		if Valid {
			_LLM_NavEventOwnerRuntimeEpoch += 1
			PublishedEpoch := _LLM_NavEventOwnerRuntimeEpoch
			_LLM_NavEventOwnerStarted := true
			_LLM_NavEventOwnerQuarantined := false
			_LLM_NavEventOwnerStopPending := false
			_LLM_NavEventOwnerWakeFn := _LLM_NavEventOwnerOnWake
			_LLM_NavEventOwnerServiceFn := _LLM_NavEventOwnerService
			try {
				OnMessage(_LLM_NavEventOwnerWakeMessage,
					_LLM_NavEventOwnerWakeFn)
				_LLM_NavEventOwnerSetServiceTimer(true)
				if !_LLM_NavEventOwnerPublishCurrentSurface(
						AllowLifecycleResume)
					throw Error("Navigation owner rejected the current surface")
				if !_LLM_NavEventOwnerPublishCurrentProfileSurface(
						AllowLifecycleResume)
					throw Error("Navigation owner rejected the current profile surface")
			} catch as Err {
				FailureDetail := "Navigation event owner startup publication failed: "
					. Err.Message . "."
			}
			Published := FailureDetail == ""
				&& !A_IsSuspended
				&& _LLM_NavEventOwnerStarting
				&& _LLM_NavEventOwnerActiveStartTicket == StartTicket
				&& !_LLM_NavEventOwnerStartCancelled
				&& !_LLM_NavEventOwnerStartRollbackPending
				&& !_LLM_NavEventOwnerStopping
				&& !_LLM_NavEventOwnerStopPending
				&& (!_LLM_NavEventOwnerPendingStopRecovery
					|| AllowLifecycleResume)
				&& _LLM_NavEventOwnerRuntimeEpoch == PublishedEpoch
				&& (!_LLM_NavEventOwnerLifecycleQuiesced
					|| AllowLifecycleResume)
		}
		if Published {
			_LLM_NavEventOwnerStarting := false
			_LLM_NavEventOwnerActiveStartTicket := 0
		} else if FailureDetail == "" {
			FailureDetail := "Navigation event owner startup was invalidated."
		}
	} finally Critical(PreviousCritical)
	if Published
		return true
	_LLM_NavEventOwnerRollbackStart(
		StartTicket, FailureDetail, AllowLifecycleResume)
	return false
}

_LLM_NavEventOwnerRollbackStart(StartTicket, FailureDetail,
		PreserveResumeIntent := false) {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerStarting, _LLM_NavEventOwnerStartCancelled
	global _LLM_NavEventOwnerStartRollbackPending
	global _LLM_NavEventOwnerActiveStartTicket
	global _LLM_NavEventOwnerWakeMessage, _LLM_NavEventOwnerWakeFn
	global _LLM_NavEventOwnerServiceFn
	PreviousCritical := Critical("On")
	try {
		if _LLM_NavEventOwnerActiveStartTicket == StartTicket {
			_LLM_NavEventOwnerStarting := false
			_LLM_NavEventOwnerActiveStartTicket := 0
		}
		_LLM_NavEventOwnerStartCancelled := false
		_LLM_NavEventOwnerStartRollbackPending := true
		; Start may have crossed its native ACK even when a seam raised while
		; returning. Publish only the fail-open quarantine needed to drive Stop.
		_LLM_NavEventOwnerStarted := true
		_LLM_NavEventOwnerQuarantined := true
		if !IsObject(_LLM_NavEventOwnerWakeFn)
			_LLM_NavEventOwnerWakeFn := _LLM_NavEventOwnerOnWake
		if !IsObject(_LLM_NavEventOwnerServiceFn)
			_LLM_NavEventOwnerServiceFn := _LLM_NavEventOwnerService
	} finally Critical(PreviousCritical)
	Stopped := false
	try Stopped := LLM_NavEventOwner_Stop(PreserveResumeIntent)
	if !Stopped {
		try OnMessage(_LLM_NavEventOwnerWakeMessage,
			_LLM_NavEventOwnerWakeFn)
		try _LLM_NavEventOwnerSetServiceTimer(true)
	}
	_LLM_NavEventOwnerReport(FailureDetail)
	return false
}

LLM_NavEventOwner_Stop(PreserveResumeIntent := false,
		ForceLifecycleReset := false) {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerStarting, _LLM_NavEventOwnerStartCancelled
	global _LLM_NavEventOwnerStartRollbackPending
	global _LLM_NavEventOwnerActiveStartTicket
	global _LLM_NavEventOwnerStopping, _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerRuntimeEpoch
	global _LLM_NavEventOwnerPort
	global _LLM_NavEventOwnerWakeMessage, _LLM_NavEventOwnerWakeFn
	global _LLM_NavEventOwnerServiceFn, _LLM_NavEventOwnerServiceArmed
	global _LLM_NavEventOwnerRecords
	global _LLM_NavEventOwnerProfileOwners
	global _LLM_NavEventOwnerActiveProfileToken
	global _LLM_NavEventOwnerProfileEffectActive
	global _LLM_NavEventOwnerShutdownFenced
	global _LLM_NavEventOwnerClaimedReceipt
	global _LLM_NavEventOwnerPendingRepaints
	global _LLM_NavEventOwnerRepaintFailures
	global _LLM_NavEventOwnerPreparedPlans, _LLM_NavEventOwnerCommittedPlan
	global _LLM_NavEventOwnerLifecycleResumePlan
	global _LLM_NavEventOwnerLifecycleResumePort
	global _LLM_NavEventOwnerLifecycleQuiesced
	global _LLM_NavEventOwnerModule
	global _LLM_NavEventOwnerLastQuarantineStopAttemptTick
	PreserveLifecycle := false
	PreviousCritical := Critical("On")
	try {
		if _LLM_NavEventOwnerStarting {
			_LLM_NavEventOwnerStartCancelled := true
			return false
		}
		if _LLM_NavEventOwnerStopping
			return false
		_LLM_NavEventOwnerStopping := true
		PreserveLifecycle := !ForceLifecycleReset
			&& (PreserveResumeIntent
				|| _LLM_NavEventOwnerLifecycleQuiesced)
		if PreserveLifecycle
				&& !(_LLM_NavEventOwnerLifecycleResumePlan is Array)
				&& _LLM_NavEventOwnerCommittedPlan is Array {
			_LLM_NavEventOwnerLifecycleResumePlan :=
				_LLM_NavEventOwnerCommittedPlan
			_LLM_NavEventOwnerLifecycleResumePort :=
				_LLM_NavEventOwnerPort
		}
		ShouldStop := _LLM_NavEventOwnerStarted
			|| (_LLM_NavEventOwnerPort is Map)
			|| _LLM_NavEventOwnerModule != 0
	} finally Critical(PreviousCritical)
	StopResult := 1
	if ShouldStop {
		try StopResult := _LLM_NavEventOwnerCall("stop",
			_LLM_NavEventOwnerNativeStop)
		catch
			StopResult := 0
	}
	Stopped := ((StopResult is Integer) && StopResult == 1)
		|| (StopResult is Map && StopResult.Get("stopped", false) == true)
	StopPending := StopResult is Map
		&& StopResult.Get("pending", false) == true
		&& StopResult.Get("stopped", false) != true
	if StopPending {
		; The stop signal is committed and native dispatch is draining fail-open.
		; Keep wake/service/records connected until a later nonblocking retry joins
		; the thread; publishing Started here would certify a runtime which can no
		; longer accept new ownership.
		PreviousCritical := Critical("On")
		try {
			_LLM_NavEventOwnerStarted := false
			_LLM_NavEventOwnerQuarantined := true
			_LLM_NavEventOwnerStopPending := true
			_LLM_NavEventOwnerStopping := false
		} finally Critical(PreviousCritical)
		return false
	}
	if !Stopped {
		PreviousCritical := Critical("On")
		try _LLM_NavEventOwnerStopping := false
		finally Critical(PreviousCritical)
		return false
	}
	; Keep the service and wake route alive until the native thread has actually
	; acknowledged Stop. A refused teardown may still own suppressed receipts and
	; must not be published as inert by disconnecting its only drain paths.
	PreviousCritical := Critical("On")
	try {
		_LLM_NavEventOwnerSetServiceTimer(false)
		if IsObject(_LLM_NavEventOwnerWakeFn)
			try OnMessage(_LLM_NavEventOwnerWakeMessage,
				_LLM_NavEventOwnerWakeFn, 0)
		_LLM_NavEventOwnerRuntimeEpoch += 1
		_LLM_NavEventOwnerStarted := false
		_LLM_NavEventOwnerQuarantined := false
		_LLM_NavEventOwnerStarting := false
		_LLM_NavEventOwnerStopPending := false
		_LLM_NavEventOwnerStartCancelled := false
		_LLM_NavEventOwnerStartRollbackPending := false
		_LLM_NavEventOwnerActiveStartTicket := 0
		_LLM_NavEventOwnerPort := 0
		_LLM_NavEventOwnerWakeFn := 0
		_LLM_NavEventOwnerServiceFn := 0
		_LLM_NavEventOwnerServiceArmed := false
		_LLM_NavEventOwnerRecords := Map()
		_LLM_NavEventOwnerProfileOwners := Map()
		_LLM_NavEventOwnerActiveProfileToken := 0
		_LLM_NavEventOwnerProfileEffectActive := false
		_LLM_NavEventOwnerShutdownFenced := false
		_LLM_NavEventOwnerClaimedReceipt := 0
		_LLM_NavEventOwnerPendingRepaints := Map()
		_LLM_NavEventOwnerRepaintFailures := Map()
		_LLM_NavEventOwnerPreparedPlans := Map()
		_LLM_NavEventOwnerCommittedPlan := 0
		_LLM_NavEventOwnerLastQuarantineStopAttemptTick := 0
		if !PreserveLifecycle {
			_LLM_NavEventOwnerLifecycleResumePlan := 0
			_LLM_NavEventOwnerLifecycleResumePort := 0
			_LLM_NavEventOwnerLifecycleQuiesced := false
		}
	} finally {
		_LLM_NavEventOwnerStopping := false
		Critical(PreviousCritical)
	}
	Unloaded := true
	try Unloaded := _LLM_NavEventOwnerNativeUnload()
	catch
		Unloaded := false
	return Unloaded
}

; Callers hold Critical across this check and their terminal-recovery admission
; A claimed receipt still needs its exact native ACK, while a pending repaint
; still needs its exact pixel commit; neither debt may be erased by Stop
_LLM_NavEventOwnerHasTerminalDebt() {
	global _LLM_NavEventOwnerClaimedReceipt
	global _LLM_NavEventOwnerPendingRepaints
	global _LLM_NavEventOwnerProfileEffectActive
	return IsObject(_LLM_NavEventOwnerClaimedReceipt)
		|| _LLM_NavEventOwnerPendingRepaints.Count > 0
		|| _LLM_NavEventOwnerProfileEffectActive
}

_LLM_NavEventOwnerRecoverPendingStop() {
	global _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerPendingStopRecovery
	global _LLM_NavEventOwnerDrainActive
	global _LLM_NavEventOwnerLifecycleQuiesced
	global _LLM_NavEventOwnerLifecycleResumePlan
	global _LLM_NavEventOwnerLifecycleResumePort
	PreviousCritical := Critical("On")
	try {
		if !_LLM_NavEventOwnerStopPending
			return true
		if A_IsSuspended || _LLM_NavEventOwnerLifecycleQuiesced
				|| _LLM_NavEventOwnerPendingStopRecovery
				|| _LLM_NavEventOwnerDrainActive
				|| _LLM_NavEventOwnerHasTerminalDebt()
			return false
		_LLM_NavEventOwnerPendingStopRecovery := true
		ResumePlan := _LLM_NavEventOwnerLifecycleResumePlan
		ResumePort := _LLM_NavEventOwnerLifecycleResumePort
	} finally Critical(PreviousCritical)
	try {
		HasResumeIntent := ResumePlan is Array
		; Finalize exactly the Stop which originally entered the drain. A lifecycle
		; fallback already published its retained plan before returning PENDING; an
		; ordinary quarantine deliberately did not. Inventing preservation here from
		; the still-live committed runtime would resurrect a quarantined owner during
		; an unrelated later suspend/resume cycle.
		if !LLM_NavEventOwner_Stop(HasResumeIntent)
			return false
		if HasResumeIntent
			return _LLM_NavEventOwnerRestartLifecyclePlan(
				ResumePlan, ResumePort, true)
		return true
	} finally {
		PreviousCritical := Critical("On")
		try _LLM_NavEventOwnerPendingStopRecovery := false
		finally Critical(PreviousCritical)
	}
}

_LLM_NavEventOwnerRecoverStartRollback() {
	global _LLM_NavEventOwnerStartRollbackPending
	global _LLM_NavEventOwnerPendingStopRecovery
	global _LLM_NavEventOwnerDrainActive
	global _LLM_NavEventOwnerLifecycleQuiesced
	global _LLM_NavEventOwnerLifecycleResumePlan
	global _LLM_NavEventOwnerLifecycleResumePort
	PreviousCritical := Critical("On")
	try {
		if !_LLM_NavEventOwnerStartRollbackPending
			return true
		if A_IsSuspended || _LLM_NavEventOwnerLifecycleQuiesced
				|| _LLM_NavEventOwnerPendingStopRecovery
				|| _LLM_NavEventOwnerDrainActive
				|| _LLM_NavEventOwnerHasTerminalDebt()
			return false
		_LLM_NavEventOwnerPendingStopRecovery := true
		ResumePlan := _LLM_NavEventOwnerLifecycleResumePlan
		ResumePort := _LLM_NavEventOwnerLifecycleResumePort
	} finally Critical(PreviousCritical)
	try {
		HasResumeIntent := ResumePlan is Array
		if !LLM_NavEventOwner_Stop(HasResumeIntent)
			return false
		if HasResumeIntent
			return _LLM_NavEventOwnerRestartLifecyclePlan(
				ResumePlan, ResumePort, true)
		return true
	} finally {
		PreviousCritical := Critical("On")
		try _LLM_NavEventOwnerPendingStopRecovery := false
		finally Critical(PreviousCritical)
	}
}

_LLM_NavEventOwnerQuarantineNow(RespectBackoff := false) {
	global _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerLifecycleQuiesced
	global _LLM_NavEventOwnerPendingStopRecovery
	global _LLM_NavEventOwnerLifecycleResumePlan
	global _LLM_NavEventOwnerLifecycleResumePort
	global _LLM_NavEventOwnerLastQuarantineStopAttemptTick
	global LLM_NAV_EVENT_OWNER_QUARANTINE_RETRY_MS
	OwnsRecovery := false
	PreviousCritical := Critical("On")
	try {
		if !_LLM_NavEventOwnerQuarantined
			return true
		; A claimed receipt still needs its exact native ACK, while an acknowledged
		; receipt may still need its exact pixels; neither debt can survive Stop
		if _LLM_NavEventOwnerStopPending
				|| _LLM_NavEventOwnerPendingStopRecovery
				|| _LLM_NavEventOwnerHasTerminalDebt()
			return false
		Now := A_TickCount
		Elapsed := (Now
			- _LLM_NavEventOwnerLastQuarantineStopAttemptTick) & 0xFFFFFFFF
		if RespectBackoff
				&& _LLM_NavEventOwnerLastQuarantineStopAttemptTick != 0
				&& Elapsed < LLM_NAV_EVENT_OWNER_QUARANTINE_RETRY_MS
			return false
		_LLM_NavEventOwnerLastQuarantineStopAttemptTick := Now
		ResumePlan := _LLM_NavEventOwnerLifecycleResumePlan
		ResumePort := _LLM_NavEventOwnerLifecycleResumePort
		; Reserve the terminal edge before leaving Critical so a wake cannot claim
		; a queued receipt between this debt check and the native Stop call
		_LLM_NavEventOwnerPendingStopRecovery := true
		OwnsRecovery := true
	} finally Critical(PreviousCritical)
	try {
		HasResumeIntent := ResumePlan is Array
		Stopped := LLM_NavEventOwner_Stop(HasResumeIntent)
		if !Stopped
			_LLM_NavEventOwnerReport(
				"Navigation event owner quarantine stop was not acknowledged.")
		if Stopped && HasResumeIntent {
			PreviousCritical := Critical("On")
			try CanRestart := !A_IsSuspended
				&& !_LLM_NavEventOwnerLifecycleQuiesced
				&& _LLM_NavEventOwnerPendingStopRecovery
			finally Critical(PreviousCritical)
			if CanRestart
				return _LLM_NavEventOwnerRestartLifecyclePlan(
					ResumePlan, ResumePort, true)
		}
		return Stopped
	} finally {
		if OwnsRecovery {
			PreviousCritical := Critical("On")
			try _LLM_NavEventOwnerPendingStopRecovery := false
			finally Critical(PreviousCritical)
		}
	}
}

LLM_NavEventOwner_LifecycleBarrierActive() {
	global _LLM_NavEventOwnerLifecycleQuiesced
	global _LLM_NavEventOwnerPendingStopRecovery
	return _LLM_NavEventOwnerLifecycleQuiesced
		|| _LLM_NavEventOwnerPendingStopRecovery
}

; A refused owner transition is already fail-open in the native dispatch core.
; Publish that quarantine to AHK immediately, then stop the hook only after the
; caller leaves Critical: Stop joins the hook thread and must never block a
; tooltip/keyboard transaction.
_LLM_NavEventOwnerQuarantine(Reason) {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	_LLM_NavEventOwnerStarted := false
	_LLM_NavEventOwnerQuarantined := true
	_LLM_NavEventOwnerReport(Reason)
	if A_IsCritical {
		SetTimer(_LLM_NavEventOwnerQuarantineNow, -1)
		return false
	}
	_LLM_NavEventOwnerQuarantineNow()
	return false
}

LLM_NavEventOwner_SetSuspended(Suspended) {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerStarting
	global _LLM_NavEventOwnerStartRollbackPending
	global _LLM_NavEventOwnerStopping, _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerPendingStopRecovery
	if _LLM_NavEventOwnerStarting
			|| _LLM_NavEventOwnerStartRollbackPending
			|| _LLM_NavEventOwnerStopping || _LLM_NavEventOwnerStopPending
			|| _LLM_NavEventOwnerPendingStopRecovery
			|| _LLM_NavEventOwnerQuarantined
		return false
	if !_LLM_NavEventOwnerStarted
		return true
	Value := Suspended ? 1 : 0
	try Status := _LLM_NavEventOwnerCall("suspend",
		_LLM_NavEventOwnerNativeSuspend, Value)
	catch
		return false
	return (Status is Integer) && Status == 1
}

_LLM_NavEventOwnerCanStop(Port := 0) {
	Fn := _LLM_NavEventOwnerPortFn("can_stop", Port)
	try Status := HasMethod(Fn, "Call")
		? Fn.Call() : _LLM_NavEventOwnerNativeCanStop()
	catch
		return false
	return (Status is Integer) && Status == 1
}

LLM_NavEventOwner_PrepareShutdown(ProfileSelectFn := 0, Port := 0) {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerShutdownFenced
	if !_LLM_NavEventOwnerStarted {
		_LLM_NavEventOwnerShutdownFenced := false
		return !_LLM_NavEventOwnerQuarantined
	}
	if _LLM_NavEventOwnerQuarantined
		return false
	if !LLM_NavEventOwner_SetSuspended(true)
		return false
	_LLM_NavEventOwnerShutdownFenced := true
	Drained := false
	try Drained := _LLM_NavEventOwnerDrain(0, 0, ProfileSelectFn)
	catch as Err
		_LLM_NavEventOwnerReport(
			"Shutdown receipt drain raised an error: " . Err.Message . ".")
	Ready := Drained && !_LLM_NavEventOwnerHasTerminalDebt()
		&& _LLM_NavEventOwnerCanStop(Port)
	if Ready
		return true
	LLM_NavEventOwner_CancelShutdown()
	return false
}

LLM_NavEventOwner_CancelShutdown() {
	global _LLM_NavEventOwnerShutdownFenced
	if !_LLM_NavEventOwnerShutdownFenced
		return true
	Resumed := LLM_NavEventOwner_SetSuspended(false)
	if Resumed {
		_LLM_NavEventOwnerShutdownFenced := false
		try _LLM_NavEventOwnerSetServiceTimer(true)
		return true
	}
	_LLM_NavEventOwnerReport(
		"Refused shutdown could not resume the native event owner.")
	return false
}

_LLM_NavEventOwnerApplyExternalSuspendTransition(Suspended,
		EnterFn, ResumeFn, SuspendFn, IconFn) {
	global _LastSuspendState
	if !HasMethod(EnterFn, "Call") || !HasMethod(ResumeFn, "Call")
			|| !HasMethod(SuspendFn, "Call") || !HasMethod(IconFn, "Call")
		return false
	_LastSuspendState := Suspended
	IconFn.Call()
	if Suspended {
		if EnterFn.Call()
			return true
		; A raw AHK/OS transition can precede this independent hook's boundary.
		; Teardown did not start, so compensate Suspend directly without inventing
		; a resume lifecycle against subsystems which never left their running state.
		SuspendFn.Call(0)
		_LastSuspendState := false
		IconFn.Call()
		return false
	}
	ResumeFn.Call()
	return true
}

; AHK Suspend cannot pause this independent hook thread. The lifecycle may
; proceed only after either the native suspended bit or a complete Stop is
; proved; otherwise it must leave the application transition untouched.
LLM_NavEventOwner_QuiesceForLifecycle(Suspended) {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerStopping
	global _LLM_NavEventOwnerPort
	global _LLM_NavEventOwnerCommittedPlan
	global _LLM_NavEventOwnerLifecycleResumePlan
	global _LLM_NavEventOwnerLifecycleResumePort
	global _LLM_NavEventOwnerLifecycleQuiesced
	global _LLM_NavEventOwnerLifecycleResuming
	global _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerPendingStopRecovery
	global _LLM_NavEventOwnerRuntimeEpoch
	global _LLM_NavEventOwnerProfileEffectActive
	RuntimePlan := 0
	RuntimePort := 0
	RuntimeEpoch := 0
	ResumePlan := 0
	ResumePort := 0
	HasResumeIntent := false
	PendingStopAtResume := false
	QuarantinedAtResume := false
	AlreadyQuiesced := false
	OwnsResumeTransition := false
	PreviousCritical := Critical("On")
	try {
		if _LLM_NavEventOwnerPendingStopRecovery
				|| _LLM_NavEventOwnerLifecycleResuming
				|| _LLM_NavEventOwnerProfileEffectActive
			return false
		if Suspended && _LLM_NavEventOwnerLifecycleQuiesced {
			AlreadyQuiesced := true
			return true
		}
		if !Suspended {
			_LLM_NavEventOwnerLifecycleResuming := true
			OwnsResumeTransition := true
		}
		; This fence begins before native suspension/Stop and remains published for
		; the whole AHK pause. Only the exact retained-plan replay below receives
		; an explicit bypass during resume.
		_LLM_NavEventOwnerLifecycleQuiesced := true
		Started := _LLM_NavEventOwnerStarted
		RuntimeEpoch := _LLM_NavEventOwnerRuntimeEpoch
		if _LLM_NavEventOwnerCommittedPlan is Array
			RuntimePlan := _LLM_NavEventOwnerCommittedPlan
		if _LLM_NavEventOwnerPort is Map
			RuntimePort := _LLM_NavEventOwnerPort
		if !Suspended {
			PendingStopAtResume := _LLM_NavEventOwnerStopPending
			QuarantinedAtResume := _LLM_NavEventOwnerQuarantined
			if _LLM_NavEventOwnerLifecycleResumePlan is Array {
				HasResumeIntent := true
				ResumePlan := _LLM_NavEventOwnerLifecycleResumePlan
				ResumePort := _LLM_NavEventOwnerLifecycleResumePort
			} else {
				ResumePlan := RuntimePlan
				ResumePort := RuntimePort
			}
		}
	} finally Critical(PreviousCritical)
	if AlreadyQuiesced
		return true
	KeepQuiesced := false
	try {
	if !Suspended && (PendingStopAtResume || QuarantinedAtResume) {
		; Stop either committed its fail-open drain or failed to prove teardown
		; before the AHK pause ended. Resume must first let the retained service
		; finish receipts/repaints and the exact Stop/replay debt. Never unsuspend
		; the ambiguous native runtime in between.
		TimerReady := false
		try TimerReady := _LLM_NavEventOwnerSetServiceTimer(true)
		catch as Err
			_LLM_NavEventOwnerReport(
				"Quarantined navigation-owner service could not resume: "
				. Err.Message . ".")
		if !TimerReady
			_LLM_NavEventOwnerReport(
				"Quarantined navigation-owner service was not re-armed on resume.")
		return TimerReady
	}
	; A Stop used as the suspend fallback intentionally clears live runtime state.
	; Its exact committed plan survives only in the lifecycle snapshot and must be
	; rebuilt before a later resume can claim success.
	if !Suspended && HasResumeIntent {
		if Started {
			StoppedPendingOwner := false
			try StoppedPendingOwner := LLM_NavEventOwner_Stop(true)
			catch
				return false
			if !StoppedPendingOwner
				return false
		}
		return _LLM_NavEventOwnerRestartLifecyclePlan(ResumePlan, ResumePort)
	}
	Succeeded := false
	try Succeeded := LLM_NavEventOwner_SetSuspended(Suspended)
	catch as Err
		_LLM_NavEventOwnerReport(
			"Suspend transition raised an error: " . Err.Message . ".")
	; A raw Suspend can win while the native resume call is interruptible. Its ACK
	; is stale in that order and must never arm an unsuspended hook under AHK pause.
	if !Suspended && A_IsSuspended
		Succeeded := false
	if Succeeded && Started {
		TimerReady := false
		try TimerReady := _LLM_NavEventOwnerSetServiceTimer(!Suspended)
		catch as Err
			_LLM_NavEventOwnerReport(
				"Receipt service timer transition failed: " . Err.Message . ".")
		Succeeded := TimerReady
	}
	if Succeeded && Started {
		PreviousCritical := Critical("On")
		try Succeeded := !A_IsSuspended
			&& _LLM_NavEventOwnerStarted
			&& !_LLM_NavEventOwnerQuarantined
			&& !_LLM_NavEventOwnerStopping
			&& !_LLM_NavEventOwnerStopPending
			&& !_LLM_NavEventOwnerPendingStopRecovery
			&& _LLM_NavEventOwnerRuntimeEpoch == RuntimeEpoch
		finally Critical(PreviousCritical)
	}
	if Succeeded {
		if Suspended {
			KeepQuiesced := true
		} else {
			PreviousCritical := Critical("On")
			try {
				_LLM_NavEventOwnerLifecycleResumePlan := 0
				_LLM_NavEventOwnerLifecycleResumePort := 0
			} finally Critical(PreviousCritical)
		}
		return true
	}
	_LLM_NavEventOwnerReport(
		"Suspend transition could not be proved; stopping the hook.")
	try Stopped := LLM_NavEventOwner_Stop(true)
	catch
		return false
	if !Stopped {
		if _LLM_NavEventOwnerStopPending {
			PendingPlan := Suspended ? RuntimePlan : ResumePlan
			PendingPort := Suspended ? RuntimePort : ResumePort
			if PendingPlan is Array {
				PreviousCritical := Critical("On")
				try {
					_LLM_NavEventOwnerLifecycleResumePlan := PendingPlan
					_LLM_NavEventOwnerLifecycleResumePort := PendingPort
				} finally Critical(PreviousCritical)
			}
		}
		return false
	}
	if Suspended {
		if RuntimePlan is Array {
			PreviousCritical := Critical("On")
			try {
				_LLM_NavEventOwnerLifecycleResumePlan := RuntimePlan
				_LLM_NavEventOwnerLifecycleResumePort := RuntimePort
			} finally Critical(PreviousCritical)
		}
		KeepQuiesced := true
		return true
	}
	if !(ResumePlan is Array)
		return true
	return _LLM_NavEventOwnerRestartLifecyclePlan(ResumePlan, ResumePort)
	} finally {
		PreviousCritical := Critical("On")
		try {
			if OwnsResumeTransition
				_LLM_NavEventOwnerLifecycleResuming := false
			if !KeepQuiesced
				_LLM_NavEventOwnerLifecycleQuiesced := false
		} finally Critical(PreviousCritical)
	}
}

_LLM_NavEventOwnerRestartLifecyclePlan(Plan, Port := 0,
		RecoveryAlreadyOwned := false) {
	global _LLM_NavEventOwnerLifecycleResumePlan
	global _LLM_NavEventOwnerLifecycleResumePort
	global _LLM_NavEventOwnerPendingStopRecovery
	OwnsRecovery := false
	Admitted := false
	PreviousCritical := Critical("On")
	try {
		if !A_IsSuspended {
			if RecoveryAlreadyOwned {
				Admitted := _LLM_NavEventOwnerPendingStopRecovery
			} else if !_LLM_NavEventOwnerPendingStopRecovery {
				_LLM_NavEventOwnerPendingStopRecovery := true
				OwnsRecovery := true
				Admitted := true
			}
		}
		if Admitted {
			; Publish the exact intent before any interruptible native call. Every
			; rollback below therefore preserves the same object and port.
			_LLM_NavEventOwnerLifecycleResumePlan := Plan
			_LLM_NavEventOwnerLifecycleResumePort := Port
		}
	} finally Critical(PreviousCritical)
	if !Admitted
		return false
	try {
		Generation := LLM_NavEventOwner_PreparePlan(Plan, Port, true)
		if (Generation is Integer) && Generation > 0
				&& LLM_NavEventOwner_CommitPlan(Generation, true) {
			CanPublish := false
			PreviousCritical := Critical("On")
			try {
				CanPublish := !A_IsSuspended
					&& _LLM_NavEventOwnerPendingStopRecovery
					&& _LLM_NavEventOwnerLifecycleResumePlan is Array
					&& _LLM_NavEventOwnerLifecycleResumePlan == Plan
				if CanPublish {
					_LLM_NavEventOwnerLifecycleResumePlan := 0
					_LLM_NavEventOwnerLifecycleResumePort := 0
				}
			} finally Critical(PreviousCritical)
			if CanPublish
				return true
			try LLM_NavEventOwner_Stop(true)
			PreviousCritical := Critical("On")
			try {
				_LLM_NavEventOwnerLifecycleResumePlan := Plan
				_LLM_NavEventOwnerLifecycleResumePort := Port
			} finally Critical(PreviousCritical)
			return false
		}
		_LLM_NavEventOwnerReport(
			"Resume fallback stopped the hook but could not restore its committed plan.")
		; A restarted hook without the proven plan is fail-open, but it is not a
		; successful resume owner. Preserve the exact intent across its cleanup so a
		; later lifecycle retry starts from one explicit empty boundary.
		try LLM_NavEventOwner_Stop(true)
		PreviousCritical := Critical("On")
		try {
			_LLM_NavEventOwnerLifecycleResumePlan := Plan
			_LLM_NavEventOwnerLifecycleResumePort := Port
		} finally Critical(PreviousCritical)
		return false
	} finally {
		if OwnsRecovery {
			PreviousCritical := Critical("On")
			try _LLM_NavEventOwnerPendingStopRecovery := false
			finally Critical(PreviousCritical)
		}
	}
}

LLM_NavEventOwner_PreparePlan(Plan, Port := 0,
		AllowLifecycleResume := false) {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerStopping
	global _LLM_NavEventOwnerLifecycleQuiesced
	global _LLM_NavEventOwnerPendingStopRecovery
	global _LLM_NavEventOwnerPreparedPlans
	if !LLM_NavEventOwner_EnsureStarted(Port, AllowLifecycleResume)
		return 0
	Generation := 0
	PreviousCritical := Critical("On")
	try {
		if A_IsSuspended || !_LLM_NavEventOwnerStarted
				|| _LLM_NavEventOwnerStopping
				|| (_LLM_NavEventOwnerPendingStopRecovery
					&& !AllowLifecycleResume)
				|| (_LLM_NavEventOwnerLifecycleQuiesced
					&& !AllowLifecycleResume)
			return 0
		try Generation := _LLM_NavEventOwnerCall("prepare_plan",
			_LLM_NavEventOwnerNativePreparePlan, Plan)
		catch as Err {
			_LLM_NavEventOwnerReport(
				"Navigation event-owner plan preparation failed: "
				. Err.Message . ".")
			return 0
		}
		if !(Generation is Integer) || Generation <= 0
			return 0
		_LLM_NavEventOwnerPreparedPlans[Generation] := Plan
	} finally Critical(PreviousCritical)
	return Generation
}

LLM_NavEventOwner_CommitPlan(Generation, AllowLifecycleResume := false) {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerPreparedPlans
	global _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerStarting
	global _LLM_NavEventOwnerStartRollbackPending
	global _LLM_NavEventOwnerStopping, _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerLifecycleQuiesced
	global _LLM_NavEventOwnerPendingStopRecovery
	global _LLM_NavEventOwnerCommittedPlan
	global _LLM_NavEventOwnerLifecycleResumePlan
	global _LLM_NavEventOwnerLifecycleResumePort
	global _LLM_NavEventOwnerPort
	global _LLM_NavEventOwnerRuntimeEpoch
	Succeeded := false
	RollbackForSuspend := false
	PreviousCritical := Critical("On")
	try {
		if !A_IsSuspended
				&& _LLM_NavEventOwnerStarted && !_LLM_NavEventOwnerQuarantined
				&& !_LLM_NavEventOwnerStarting
				&& !_LLM_NavEventOwnerStartRollbackPending
				&& !_LLM_NavEventOwnerStopping
				&& !_LLM_NavEventOwnerStopPending
				&& (!_LLM_NavEventOwnerPendingStopRecovery
					|| AllowLifecycleResume)
				&& (!_LLM_NavEventOwnerLifecycleQuiesced
					|| AllowLifecycleResume) {
			Plan := _LLM_NavEventOwnerPreparedPlans.Get(Generation, 0)
			if Plan is Array {
				RuntimeEpoch := _LLM_NavEventOwnerRuntimeEpoch
				try Status := _LLM_NavEventOwnerCall("commit_plan",
					_LLM_NavEventOwnerNativeCommitPlan, Generation)
				catch
					Status := 0
				Acknowledged := (Status is Integer) && Status == 1
				StillOwnsPlan := !A_IsSuspended
					&& _LLM_NavEventOwnerStarted
					&& _LLM_NavEventOwnerRuntimeEpoch == RuntimeEpoch
					&& _LLM_NavEventOwnerPreparedPlans.Has(Generation)
					&& _LLM_NavEventOwnerPreparedPlans[Generation] == Plan
				RollbackForSuspend := Acknowledged && A_IsSuspended
				if StillOwnsPlan {
					_LLM_NavEventOwnerPreparedPlans.Delete(Generation)
					if Acknowledged {
						_LLM_NavEventOwnerCommittedPlan := Plan
						Succeeded := true
					}
				}
			}
		}
	} finally Critical(PreviousCritical)
	if RollbackForSuspend {
		Stopped := false
		try Stopped := LLM_NavEventOwner_Stop(AllowLifecycleResume)
		if !Stopped {
			; The raw AHK Suspend already won, so a refused Stop must still prove
			; that the independent hook is fail-open. Preserve the exact ACKed plan
			; for a later Stop/restart instead of publishing it into this runtime.
			PreviousCritical := Critical("On")
			try {
				_LLM_NavEventOwnerLifecycleResumePlan := Plan
				_LLM_NavEventOwnerLifecycleResumePort := _LLM_NavEventOwnerPort
				_LLM_NavEventOwnerLifecycleQuiesced := true
			} finally Critical(PreviousCritical)
			SafeBoundary := _LLM_NavEventOwnerStopPending
			if !SafeBoundary {
				try SafeBoundary := LLM_NavEventOwner_SetSuspended(true)
			}
			if SafeBoundary {
				try _LLM_NavEventOwnerSetServiceTimer(false)
			} else {
				; Two independent native teardown barriers failed. Keep AHK running so
				; its service can surface/retry the quarantine rather than leaving an
				; unsuspended hook beneath a paused script.
				if A_IsSuspended
					Suspend(0)
				_LLM_NavEventOwnerQuarantine(
					"Navigation plan rollback could not prove a fail-open native boundary")
			}
		}
		return false
	}
	return Succeeded
}

; Test-only public seam over the production dispatch core. A fake/native port
; can drive the same PASS/SUPPRESS decision without installing a system hook;
; callers must still prepare/commit a plan and publish an owner first.
LLM_NavEventOwner_TestDispatch(Event, Port := 0) {
	global _LLM_NavEventOwnerStarted
	if !_LLM_NavEventOwnerStarted || !(Event is Map)
		return 0
	Fn := _LLM_NavEventOwnerPortFn("test_dispatch", Port)
	try return HasMethod(Fn, "Call")
		? Fn.Call(Event) : _LLM_NavEventOwnerNativeTestDispatch(Event)
	catch
		return 0
}

LLM_NavEventOwner_BeginTerminalCapture(Token, Port := 0) {
	if !(Token is Integer) || Token <= 0
		return false
	if !LLM_NavEventOwner_EnsureStarted(Port)
		return false
	Fn := _LLM_NavEventOwnerPortFn("begin_terminal", Port)
	try Status := HasMethod(Fn, "Call")
		? Fn.Call(Token) : _LLM_NavEventOwnerNativeBeginTerminalCapture(Token)
	catch as Err {
		_LLM_NavEventOwnerReport(
			"Terminal keyboard capture admission failed: " . Err.Message . ".")
		return false
	}
	return (Status is Integer) && Status == 1
}

LLM_NavEventOwner_ReleaseTerminalCapture(Token, Committed, Port := 0) {
	if !(Token is Integer) || Token <= 0
		return false
	Name := Committed ? "commit_terminal" : "abort_terminal"
	DefaultFn := Committed
		? _LLM_NavEventOwnerNativeCommitTerminalCapture
		: _LLM_NavEventOwnerNativeAbortTerminalCapture
	Fn := _LLM_NavEventOwnerPortFn(Name, Port)
	try Status := HasMethod(Fn, "Call")
		? Fn.Call(Token) : DefaultFn.Call(Token)
	catch as Err {
		_LLM_NavEventOwnerReport(
			"Terminal keyboard replay failed: " . Err.Message . ".")
		return false
	}
	return (Status is Integer) && Status == 1
}

LLM_NavEventOwner_GetTerminalCapture(Token, Port := 0) {
	if !(Token is Integer) || Token <= 0
		return 0
	Fn := _LLM_NavEventOwnerPortFn("get_terminal", Port)
	try return HasMethod(Fn, "Call")
		? Fn.Call(Token) : _LLM_NavEventOwnerNativeGetTerminalCapture(Token)
	catch
		return 0
}

_LLM_NavEventOwnerRecordFromSurface(Surface) {
	if !IsObject(Surface) || !IsSet(_LLM_TooltipPresentedFromSurface)
		return 0
	try return _LLM_TooltipPresentedFromSurface(Surface)
	catch
		return 0
}

_LLM_NavEventOwnerTokenFromSurface(Surface) {
	Record := _LLM_NavEventOwnerRecordFromSurface(Surface)
	if !IsObject(Record) || !Record.HasOwnProp("NavOwnerToken")
		return 0
	Token := Record.NavOwnerToken
	return (Token is Integer) && Token > 0 ? Token : 0
}

_LLM_NavEventOwnerAllocateToken() {
	global _LLM_NavEventOwnerNextToken
	PreviousCritical := Critical("On")
	try {
		_LLM_NavEventOwnerNextToken += 1
		if _LLM_NavEventOwnerNextToken <= 0
			_LLM_NavEventOwnerNextToken := 1
		return _LLM_NavEventOwnerNextToken
	} finally Critical(PreviousCritical)
}

_LLM_NavEventOwnerProfilePlanIsValid(Plan) {
	if !(Plan is Array) || Plan.Length != 9
		return false
	Seen := Map()
	Loop 9 {
		if !Plan.Has(A_Index)
			return false
		Entry := Plan[A_Index]
		if !(Entry is Map) || Entry.Get("profile_idx", 0) != A_Index
				|| !(Entry.Get("physical_id", "") is String)
				|| Entry.Get("physical_id", "") == ""
			return false
		Identity := Entry["physical_id"]
		if Seen.Has(Identity)
			return false
		Seen[Identity] := true
	}
	return true
}

_LLM_NavEventOwnerProfileOrderClone(Order) {
	if !(Order is Array) || Order.Length > 9
		return 0
	Copy := []
	Seen := Map()
	for Id in Order {
		if !(Id is String) || Id == "" || Seen.Has(Id)
			return 0
		Seen[Id] := true
		Copy.Push(Id)
	}
	return Copy
}

_LLM_NavEventOwnerProfileIdSet(CandidateIds) {
	if CandidateIds is Map
		return CandidateIds.Clone()
	if !(CandidateIds is Array)
		return 0
	Ids := Map()
	for Id in CandidateIds {
		if !(Id is String) || Id == "" || Ids.Has(Id)
			return 0
		Ids[Id] := true
	}
	return Ids
}

LLM_NavEventOwner_ProfileSurfaceMatches(Order, Enabled) {
	global _LLM_NavEventOwnerActiveProfileToken
	global _LLM_NavEventOwnerProfileOwners
	NormalizedOrder := _LLM_NavEventOwnerProfileOrderClone(Order)
	if !(NormalizedOrder is Array)
		return false
	ExpectedEnabled := (Enabled is Integer) && Enabled == 1
	Token := _LLM_NavEventOwnerActiveProfileToken
	if !ExpectedEnabled
		return Token == 0
	if Token <= 0 || !_LLM_NavEventOwnerProfileOwners.Has(Token)
		return false
	Entry := _LLM_NavEventOwnerProfileOwners[Token]
	if !IsObject(Entry) || !Entry.Active || Entry.Retired
			|| !(Entry.Order is Array)
		return false
	if Entry.Order.Length != NormalizedOrder.Length
		return false
	for Index, Id in NormalizedOrder
		if Entry.Order[Index] != Id
			return false
	return true
}

_LLM_NavEventOwnerProfilePendingMask(Token, Port := 0) {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	if !(Token is Integer) || Token <= 0
		return -1
	if _LLM_NavEventOwnerQuarantined
		return -1
	if !_LLM_NavEventOwnerStarted
		return 0
	Fn := _LLM_NavEventOwnerPortFn("profile_pending_mask", Port)
	try Mask := HasMethod(Fn, "Call")
		? Fn.Call(Token) : _LLM_NavEventOwnerNativeProfilePendingMask(Token)
	catch
		return -1
	return (Mask is Integer) && Mask >= 0 && Mask <= 0x1FF ? Mask : -1
}

_LLM_NavEventOwnerProfileMaskIsAdmissible(Entry, Mask, CandidateIds) {
	if !IsObject(Entry) || !(Entry.Order is Array)
			|| !(Mask is Integer) || Mask < 0 || Mask > 0x1FF
			|| !(CandidateIds is Map)
		return false
	Loop 9 {
		Bit := 1 << (A_Index - 1)
		if !(Mask & Bit)
			continue
		if A_Index > Entry.Order.Length
			return false
		if !CandidateIds.Has(Entry.Order[A_Index])
			return false
	}
	return true
}

LLM_NavEventOwner_ProfileCandidateIsAdmissible(CandidateIds, Port := 0,
		FencedToken := 0, FencedMask := -1) {
	global _LLM_NavEventOwnerProfileOwners
	NormalizedIds := _LLM_NavEventOwnerProfileIdSet(CandidateIds)
	if !(NormalizedIds is Map)
		return false
	Owners := []
	PreviousCritical := Critical("On")
	try {
		for Token, Entry in _LLM_NavEventOwnerProfileOwners
			Owners.Push(Map("token", Token, "entry", Entry))
	} finally Critical(PreviousCritical)
	for Owner in Owners {
		Token := Owner["token"]
		Mask := Token == FencedToken
			&& (FencedMask is Integer) && FencedMask >= 0
			&& FencedMask <= 0x1FF
			? FencedMask : _LLM_NavEventOwnerProfilePendingMask(Token, Port)
		if !_LLM_NavEventOwnerProfileMaskIsAdmissible(
				Owner["entry"], Mask, NormalizedIds)
			return false
	}
	return true
}

LLM_NavEventOwner_BeginProfileSwap(Plan, Order, Enabled, CandidateIds,
		Port := 0, AllowLifecycleResume := false) {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerStopping, _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerLifecycleQuiesced
	global _LLM_NavEventOwnerPendingStopRecovery
	global _LLM_NavEventOwnerProfileOwners
	global _LLM_NavEventOwnerActiveProfileToken
	if !_LLM_NavEventOwnerProfilePlanIsValid(Plan)
		return 0
	NormalizedOrder := _LLM_NavEventOwnerProfileOrderClone(Order)
	NormalizedIds := _LLM_NavEventOwnerProfileIdSet(CandidateIds)
	if !(NormalizedOrder is Array) || !(NormalizedIds is Map)
		return 0
	for Id in NormalizedOrder
		if !NormalizedIds.Has(Id)
			return 0
	if !((Enabled is Integer) && (Enabled == 0 || Enabled == 1))
		return 0
	if Enabled == 1 && NormalizedOrder.Length == 0
		return 0
	if !LLM_NavEventOwner_EnsureStarted(Port, AllowLifecycleResume)
		return 0
	ExpectedToken := _LLM_NavEventOwnerActiveProfileToken
	NewToken := Enabled == 1 ? _LLM_NavEventOwnerAllocateToken() : 0
	NewEntry := NewToken > 0 ? {
		Order: NormalizedOrder, Active: false, Retired: false
	} : 0
	PreviousCritical := Critical("On")
	try {
		if A_IsSuspended || !_LLM_NavEventOwnerStarted
				|| _LLM_NavEventOwnerQuarantined
				|| _LLM_NavEventOwnerStopping || _LLM_NavEventOwnerStopPending
				|| (_LLM_NavEventOwnerPendingStopRecovery
					&& !AllowLifecycleResume)
				|| (_LLM_NavEventOwnerLifecycleQuiesced
					&& !AllowLifecycleResume)
			return 0
	} finally Critical(PreviousCritical)
	Fn := _LLM_NavEventOwnerPortFn("begin_profile_swap", Port)
	try Result := HasMethod(Fn, "Call")
		? Fn.Call(ExpectedToken, Plan, NewToken, NormalizedOrder.Length)
		: _LLM_NavEventOwnerNativeBeginProfileSwap(
			ExpectedToken, Plan, NewToken, NormalizedOrder.Length)
	catch as Err
		return _LLM_NavEventOwnerQuarantine(
			"Profile hotkey owner preparation raised an ambiguous error: "
			. Err.Message . ".")
	; Integer zero is the only explicit pre-fence refusal. Every other malformed
	; result is ambiguous because the native call may already have armed the
	; transition before its return boundary failed.
	if (Result is Integer) && Result == 0
		return 0
	if !(Result is Map)
		return _LLM_NavEventOwnerQuarantine(
			"Profile hotkey owner preparation returned a malformed result.")
	Ticket := Result.Get("ticket", 0)
	CurrentMask := Result.Get("pending_mask", -1)
	if !(Ticket is Integer) || Ticket <= 0
		return _LLM_NavEventOwnerQuarantine(
			"Profile hotkey owner preparation returned no abortable ticket.")
	if !(CurrentMask is Integer) || CurrentMask < 0
			|| CurrentMask > 0x1FF {
		MalformedTransaction := Map("native", true, "ticket", Ticket,
			"old_token", ExpectedToken, "new_token", 0,
			"port", Port, "committed", false)
		if !LLM_NavEventOwner_AbortProfileSwap(MalformedTransaction)
			return false
		_LLM_NavEventOwnerReport(
			"Profile hotkey owner preparation returned an invalid pending mask.")
		return 0
	}
	Admissible := LLM_NavEventOwner_ProfileCandidateIsAdmissible(
		NormalizedIds, Port, ExpectedToken, CurrentMask)
	Transaction := Map("native", true, "ticket", Ticket,
		"old_token", ExpectedToken, "new_token", NewToken,
		"port", Port, "committed", false)
	if Admissible {
		if NewToken > 0
			_LLM_NavEventOwnerProfileOwners[NewToken] := NewEntry
		return Transaction
	}
	LLM_NavEventOwner_AbortProfileSwap(Transaction)
	return 0
}

LLM_NavEventOwner_CommitProfileSwap(Transaction) {
	global _LLM_NavEventOwnerProfileOwners
	global _LLM_NavEventOwnerActiveProfileToken
	if !(Transaction is Map) || !Transaction.Get("native", false)
			|| Transaction.Get("committed", false)
		return false
	Port := Transaction.Get("port", 0)
	Fn := _LLM_NavEventOwnerPortFn("commit_profile_swap", Port)
	try Status := HasMethod(Fn, "Call")
		? Fn.Call(Transaction.Get("ticket", 0))
		: _LLM_NavEventOwnerNativeCommitProfileSwap(
			Transaction.Get("ticket", 0))
	catch as Err
		return _LLM_NavEventOwnerQuarantine(
			"Profile hotkey owner commit raised an error: "
			. Err.Message . ".")
	if !((Status is Integer) && Status == 1)
		return _LLM_NavEventOwnerQuarantine(
			"Profile hotkey owner commit was not acknowledged.")
	OldToken := Transaction.Get("old_token", 0)
	NewToken := Transaction.Get("new_token", 0)
	if OldToken > 0 && _LLM_NavEventOwnerProfileOwners.Has(OldToken) {
		Old := _LLM_NavEventOwnerProfileOwners[OldToken]
		Old.Active := false
		Old.Retired := true
	}
	if NewToken > 0 && _LLM_NavEventOwnerProfileOwners.Has(NewToken) {
		New := _LLM_NavEventOwnerProfileOwners[NewToken]
		New.Active := true
		New.Retired := false
	}
	_LLM_NavEventOwnerActiveProfileToken := NewToken
	Transaction["committed"] := true
	_LLM_NavEventOwnerCollectProfileToken(OldToken, Port)
	return true
}

LLM_NavEventOwner_AbortProfileSwap(Transaction) {
	global _LLM_NavEventOwnerProfileOwners
	if !(Transaction is Map) || !Transaction.Get("native", false)
		return false
	if Transaction.Get("committed", false)
		return true
	Port := Transaction.Get("port", 0)
	Fn := _LLM_NavEventOwnerPortFn("abort_profile_swap", Port)
	try Status := HasMethod(Fn, "Call")
		? Fn.Call(Transaction.Get("ticket", 0))
		: _LLM_NavEventOwnerNativeAbortProfileSwap(
			Transaction.Get("ticket", 0))
	catch as Err
		return _LLM_NavEventOwnerQuarantine(
			"Profile hotkey owner abort raised an error: "
			. Err.Message . ".")
	if !((Status is Integer) && Status == 1)
		return _LLM_NavEventOwnerQuarantine(
			"Profile hotkey owner abort was not acknowledged.")
	NewToken := Transaction.Get("new_token", 0)
	if NewToken > 0 && _LLM_NavEventOwnerProfileOwners.Has(NewToken)
		_LLM_NavEventOwnerProfileOwners.Delete(NewToken)
	return true
}

_LLM_NavEventOwnerCollectProfileToken(Token, Port := 0) {
	global _LLM_NavEventOwnerProfileOwners
	if !(Token is Integer) || Token <= 0
		return true
	if !_LLM_NavEventOwnerProfileOwners.Has(Token)
		return true
	Entry := _LLM_NavEventOwnerProfileOwners[Token]
	if Entry.Active || !Entry.Retired
		return false
	if _LLM_NavEventOwnerProfilePendingMask(Token, Port) != 0
		return false
	_LLM_NavEventOwnerProfileOwners.Delete(Token)
	return true
}

LLM_NavEventOwner_AttachRecord(Record, Surface) {
	global _LLM_NavEventOwnerRecords
	if !IsObject(Record) || !IsObject(Surface)
		return 0
	PreviousCritical := Critical("On")
	try {
		if Record.HasOwnProp("NavOwnerToken") {
			ExistingToken := Record.NavOwnerToken
			if (ExistingToken is Integer) && ExistingToken > 0
					&& _LLM_NavEventOwnerRecords.Has(ExistingToken) {
				Existing := _LLM_NavEventOwnerRecords[ExistingToken]
				return ObjPtr(Existing.Record) == ObjPtr(Record)
					&& ObjPtr(Existing.Surface) == ObjPtr(Surface)
					? ExistingToken : 0
			}
		}
		Token := _LLM_NavEventOwnerAllocateToken()
		Record.NavOwnerToken := Token
		_LLM_NavEventOwnerRecords[Token] := {
			Record: Record, Surface: Surface,
			Active: false, Retired: false, NativeDetached: false
		}
		return Token
	} finally Critical(PreviousCritical)
}

LLM_NavEventOwner_BeginSurfaceSwap(RetiredSurface, PreparedSurface,
		AllowLifecycleResume := false) {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerRecords
	global _LLM_NavEventOwnerLifecycleQuiesced
	global _LLM_NavEventOwnerPendingStopRecovery
	OldToken := _LLM_NavEventOwnerTokenFromSurface(RetiredSurface)
	NewRecord := _LLM_NavEventOwnerRecordFromSurface(PreparedSurface)
	NewToken := _LLM_NavEventOwnerTokenFromSurface(PreparedSurface)
	SlotCount := 0
	ActiveIdx := 0
	RequireIndexMatch := 0
	if IsObject(NewRecord) && NewRecord.Kind == "prediction"
			&& NewRecord.Slots is Array {
		SlotCount := NewRecord.Slots.Length
		ActiveIdx := NewRecord.ActiveIdx
		if NewRecord.HasOwnProp("NavOwnerRequireExactIndex")
				&& (NewRecord.NavOwnerRequireExactIndex is Integer)
				&& NewRecord.NavOwnerRequireExactIndex == true
			RequireIndexMatch := 1
	}
	Transaction := Map("native", false, "ticket", 0,
		"retry", false,
		"old_token", OldToken, "new_token", NewToken,
		"prepared", PreparedSurface,
		"allow_lifecycle_resume", AllowLifecycleResume)
	; A detached renderer may finish after the lifecycle fence was published.
	; Reject only a new owner: the suspend teardown must still be able to hide
	; the current surface with a NewToken=0 transaction.
	if IsObject(NewRecord)
			&& (A_IsSuspended
				|| ((_LLM_NavEventOwnerLifecycleQuiesced
						|| _LLM_NavEventOwnerPendingStopRecovery)
					&& !AllowLifecycleResume)) {
		Transaction["retry"] := true
		return Transaction
	}
	NativeOldToken := OldToken
	if OldToken > 0 && _LLM_NavEventOwnerRecords.Has(OldToken) {
		OldEntry := _LLM_NavEventOwnerRecords[OldToken]
		if OldEntry.NativeDetached {
			NativeOldToken := 0
			; A successful acceptance CAS already cleared native A. Hiding its
			; pixels is a logical retirement only and must not open a 0-to-0 fence.
			if NewToken == 0
				return Transaction
		}
	}
	if !_LLM_NavEventOwnerStarted
		return Transaction
	try Ticket := _LLM_NavEventOwnerCall("begin_swap",
		_LLM_NavEventOwnerNativeBeginSwap, NativeOldToken, NewToken,
		SlotCount, ActiveIdx, RequireIndexMatch)
	catch as Err
		return _LLM_NavEventOwnerQuarantine(
			"Navigation owner surface preparation raised an error: "
			. Err.Message . ".")
	if (Ticket is Integer) && Ticket == -1 {
		Transaction["retry"] := true
		return Transaction
	}
	if !(Ticket is Integer) || Ticket <= 0
		return _LLM_NavEventOwnerQuarantine(
			"Navigation owner surface preparation was not acknowledged.")
	Transaction["native"] := true
	Transaction["ticket"] := Ticket
	return Transaction
}

LLM_NavEventOwner_CommitSurfaceSwap(Transaction) {
	global _LLM_NavEventOwnerRecords
	if !(Transaction is Map)
		return false
	if Transaction.Get("retry", false)
		return false
	if Transaction.Get("native", false) {
		try Status := _LLM_NavEventOwnerCall("commit_swap",
			_LLM_NavEventOwnerNativeCommitSwap,
			Transaction.Get("ticket", 0))
		catch as Err
			return _LLM_NavEventOwnerQuarantine(
				"Navigation owner surface commit raised an error: "
				. Err.Message . ".")
		if !((Status is Integer) && Status == 1)
			return _LLM_NavEventOwnerQuarantine(
				"Navigation owner surface commit was not acknowledged.")
	}
	OldToken := Transaction.Get("old_token", 0)
	NewToken := Transaction.Get("new_token", 0)
	if Transaction.Get("native", false) && NewToken > 0
			&& _LLM_NavEventOwnerRecords.Has(NewToken) {
		New := _LLM_NavEventOwnerRecords[NewToken]
		if !LLM_NavEventOwner_SyncRecord(New.Record,
				Transaction.Get("allow_lifecycle_resume", false))
			return _LLM_NavEventOwnerQuarantine(
				"Navigation owner surface inheritance could not be verified.")
	}
	if OldToken > 0 && _LLM_NavEventOwnerRecords.Has(OldToken) {
		Old := _LLM_NavEventOwnerRecords[OldToken]
		Old.Active := false
		Old.Retired := true
	}
	if NewToken > 0 && _LLM_NavEventOwnerRecords.Has(NewToken) {
		New := _LLM_NavEventOwnerRecords[NewToken]
		New.Active := true
		New.Retired := false
	}
	_LLM_NavEventOwnerCollectToken(OldToken)
	return true
}

LLM_NavEventOwner_AbortSurfaceSwap(Transaction) {
	if !(Transaction is Map)
		return false
	if Transaction.Get("retry", false) {
		LLM_NavEventOwner_ReleaseSurface(Transaction.Get("prepared", 0))
		return true
	}
	if Transaction.Get("native", false) {
		try Status := _LLM_NavEventOwnerCall("abort_swap",
			_LLM_NavEventOwnerNativeAbortSwap,
			Transaction.Get("ticket", 0))
		catch as Err
			return _LLM_NavEventOwnerQuarantine(
				"Navigation owner surface abort raised an error: "
				. Err.Message . ".")
		if !((Status is Integer) && Status == 1)
			return _LLM_NavEventOwnerQuarantine(
				"Navigation owner surface abort was not acknowledged.")
	}
	LLM_NavEventOwner_ReleaseSurface(Transaction.Get("prepared", 0))
	return true
}

LLM_NavEventOwner_ClaimAcceptance(Record, Surface, ExpectedActiveIdx) {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerPendingStopRecovery
	global _LLM_NavEventOwnerLifecycleQuiesced
	global _LLM_NavEventOwnerRecords
	if A_IsSuspended || _LLM_NavEventOwnerQuarantined
			|| _LLM_NavEventOwnerPendingStopRecovery
			|| _LLM_NavEventOwnerLifecycleQuiesced
		return false
	if !_LLM_NavEventOwnerStarted
		return true
	if !IsObject(Record) || !IsObject(Surface)
			|| !(ExpectedActiveIdx is Integer)
			|| ExpectedActiveIdx < 1 || ExpectedActiveIdx > 10
		return false
	Token := _LLM_NavEventOwnerTokenFromSurface(Surface)
	if Token <= 0 || !_LLM_NavEventOwnerRecords.Has(Token)
		return false
	Entry := _LLM_NavEventOwnerRecords[Token]
	if ObjPtr(Entry.Record) != ObjPtr(Record)
			|| ObjPtr(Entry.Surface) != ObjPtr(Surface)
			|| !Entry.Active || Entry.Retired || Entry.NativeDetached
		return false
	try Status := _LLM_NavEventOwnerCall("claim_owner",
		_LLM_NavEventOwnerNativeClaimOwner, Token, ExpectedActiveIdx)
	catch as Err
		return _LLM_NavEventOwnerQuarantine(
			"Navigation owner acceptance claim raised an error: "
			. Err.Message . ".")
	if (Status is Integer) && Status == 0
		return false
	if !((Status is Integer) && Status == 1)
		return _LLM_NavEventOwnerQuarantine(
			"Navigation owner acceptance claim was not acknowledged.")
	Entry.Active := false
	Entry.NativeDetached := true
	return true
}

LLM_NavEventOwner_ReleaseSurface(Surface) {
	global _LLM_NavEventOwnerRecords
	Token := _LLM_NavEventOwnerTokenFromSurface(Surface)
	if Token <= 0 || !_LLM_NavEventOwnerRecords.Has(Token)
		return true
	Entry := _LLM_NavEventOwnerRecords[Token]
	if Entry.Active
		return false
	Entry.Retired := true
	return _LLM_NavEventOwnerCollectToken(Token)
}

_LLM_NavEventOwnerPendingForToken(Token) {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	if Token <= 0
		return 0
	if _LLM_NavEventOwnerQuarantined
		return 1
	if !_LLM_NavEventOwnerStarted
		return 0
	try Pending := _LLM_NavEventOwnerCall("pending",
		_LLM_NavEventOwnerNativePendingForToken, Token)
	catch
		return 1
	return Pending is Integer && Pending >= 0 ? Pending : 1
}

_LLM_NavEventOwnerCollectToken(Token) {
	global _LLM_NavEventOwnerRecords
	if Token <= 0 || !_LLM_NavEventOwnerRecords.Has(Token)
		return true
	Entry := _LLM_NavEventOwnerRecords[Token]
	if Entry.Active || !Entry.Retired
		return false
	if _LLM_NavEventOwnerPendingForToken(Token) != 0
		return false
	_LLM_NavEventOwnerRecords.Delete(Token)
	return true
}

_LLM_NavEventOwnerApplyReceipt(Receipt) {
	global _LLM_NavEventOwnerRecords
	if !(Receipt is Map)
		return 0
	Action := Receipt.Get("action", 0)
	if !(Action is Integer) || (Action != 1 && Action != 2)
		return 0
	Token := Receipt.Get("owner_token", 0)
	TargetIdx := Receipt.Get("target_idx", 0)
	if !(Token is Integer) || Token <= 0
			|| !_LLM_NavEventOwnerRecords.Has(Token)
		return 0
	Entry := _LLM_NavEventOwnerRecords[Token]
	Record := Entry.Record
	if !IsObject(Record) || !(Record.Slots is Array)
			|| !(TargetIdx is Integer) || TargetIdx < 1
			|| TargetIdx > Record.Slots.Length
		return 0
	Record.ActiveIdx := TargetIdx
	return Entry
}

_LLM_NavEventOwnerProfileEntryFromReceipt(Receipt) {
	global _LLM_NavEventOwnerProfileOwners
	if !(Receipt is Map) || Receipt.Get("action", 0) != 3
		return 0
	Token := Receipt.Get("owner_token", 0)
	Epoch := Receipt.Get("owner_epoch", 0)
	TargetIdx := Receipt.Get("target_idx", 0)
	if !(Token is Integer) || Token <= 0 || Epoch != Token
			|| !_LLM_NavEventOwnerProfileOwners.Has(Token)
		return 0
	Entry := _LLM_NavEventOwnerProfileOwners[Token]
	if !IsObject(Entry) || !(Entry.Order is Array)
			|| !(TargetIdx is Integer) || TargetIdx < 1
			|| TargetIdx > Entry.Order.Length
		return 0
	return Entry
}

_LLM_NavEventOwnerApplyProfileReceipt(Receipt, SelectFn := 0) {
	global _LLM_NavEventOwnerClaimedReceipt
	global _LLM_NavEventOwnerLifecycleQuiesced
	global _LLM_NavEventOwnerProfileEffectActive
	if !(Receipt is Map)
		return false
	Entry := _LLM_NavEventOwnerProfileEntryFromReceipt(Receipt)
	if !IsObject(Entry)
		return false
	Sequence := Receipt.Get("seq", 0)
	Token := Receipt.Get("owner_token", 0)
	TargetIdx := Receipt.Get("target_idx", 0)
	if !Receipt.Get("profile_effect_done", false) {
		PreviousCritical := Critical("On")
		try {
			if A_IsSuspended || _LLM_NavEventOwnerLifecycleQuiesced
				return false
			_LLM_NavEventOwnerProfileEffectActive := true
			ProfileId := Entry.Order[TargetIdx]
		} finally Critical(PreviousCritical)
		Applied := false
		FailureDetail := ""
		try {
			if !HasMethod(SelectFn, "Call") {
				if !IsSet(LLM_Menu_SetProfile)
					throw Error("Profile selection callback is unavailable")
				SelectFn := LLM_Menu_SetProfile
			}
			Status := SelectFn.Call(ProfileId)
			Applied := (Status is Integer) && Status == 1
			if !Applied
				FailureDetail := "Profile hotkey selection was refused."
		} catch as Err
			FailureDetail := "Profile hotkey selection raised an error: "
				. Err.Message . "."
		PreviousCritical := Critical("On")
		try {
			_LLM_NavEventOwnerProfileEffectActive := false
			if Applied
				Receipt["profile_effect_done"] := true
		} finally Critical(PreviousCritical)
		if !Applied {
			_LLM_NavEventOwnerReport(FailureDetail)
			return false
		}
	}
	PreviousCritical := Critical("On")
	try {
		if A_IsSuspended || _LLM_NavEventOwnerLifecycleQuiesced
			return false
		if !_LLM_NavEventOwnerCompleteReceipt(
				Sequence, Token, TargetIdx) {
			_LLM_NavEventOwnerReport(
				"Profile hotkey receipt completion was not acknowledged.")
			return false
		}
		_LLM_NavEventOwnerClaimedReceipt := 0
		_LLM_NavEventOwnerCollectProfileToken(Token)
		return true
	} finally Critical(PreviousCritical)
}

_LLM_NavEventOwnerCompleteReceipt(Sequence, OwnerToken, AppliedIndex) {
	try Status := _LLM_NavEventOwnerCall("complete",
		_LLM_NavEventOwnerNativeCompleteReceipt,
		Sequence, OwnerToken, AppliedIndex)
	catch
		return false
	return (Status is Integer) && Status == 1
}

_LLM_NavEventOwnerPollReceipt() {
	try return _LLM_NavEventOwnerCall("poll",
		_LLM_NavEventOwnerNativePollReceipt)
	catch
		return 0
}

_LLM_NavEventOwnerDrain(RenderFn := 0, DegradeFn := 0, ProfileSelectFn := 0) {
	global _LLM_NavEventOwnerDrainActive
	global _LLM_NavEventOwnerPendingStopRecovery
	global _LLM_NavEventOwnerClaimedReceipt
	global _LLM_NavEventOwnerPendingRepaints
	global _LLM_NavEventOwnerRepaintFailures
	global _LLM_NavEventOwnerRecords
	global _LLM_NavEventOwnerLifecycleQuiesced
	global LLM_NAV_EVENT_OWNER_REPAINT_MAX_ATTEMPTS
	; Suspend is a hard UI boundary. Native suspension prevents new decisions,
	; while receipts committed just before it remain queued for the next resume;
	; no asynchronous wake/timer may mutate records or pixels during the pause.
	if A_IsSuspended || _LLM_NavEventOwnerLifecycleQuiesced
			|| _LLM_NavEventOwnerPendingStopRecovery
		return false
	if _LLM_NavEventOwnerDrainActive
		return false
	Renderer := HasMethod(RenderFn, "Call") ? RenderFn : 0
	if !HasMethod(Renderer, "Call")
			&& IsSet(_LLM_TooltipRenderOwnedNavigation)
		Renderer := _LLM_TooltipRenderOwnedNavigation
	Degrader := HasMethod(DegradeFn, "Call") ? DegradeFn : 0
	if !HasMethod(Degrader, "Call") && IsSet(LLM_Tooltip_HideExact)
		Degrader := LLM_Tooltip_HideExact
	_LLM_NavEventOwnerDrainActive := true
	try {
		Loop 64 {
			Receipt := _LLM_NavEventOwnerClaimedReceipt is Map
				? _LLM_NavEventOwnerClaimedReceipt
				: _LLM_NavEventOwnerPollReceipt()
			if !(Receipt is Map)
				break
			if Receipt.Get("action", 0) == 3 {
				PreviousCritical := Critical("On")
				try _LLM_NavEventOwnerClaimedReceipt := Receipt
				finally Critical(PreviousCritical)
				if !_LLM_NavEventOwnerApplyProfileReceipt(
						Receipt, ProfileSelectFn)
					break
				continue
			}
			BreakDrain := false
			FailureDetail := ""
			PreviousCritical := Critical("On")
			try {
				; Poll irrevocably changes QUEUED to CLAIMED. Publish that exact
				; receipt before the pause recheck so a winning Suspend retains it.
				_LLM_NavEventOwnerClaimedReceipt := Receipt
				if A_IsSuspended || _LLM_NavEventOwnerLifecycleQuiesced {
					BreakDrain := true
				} else {
					Sequence := Receipt.Get("seq", 0)
					Token := Receipt.Get("owner_token", 0)
					TargetIdx := Receipt.Get("target_idx", 0)
					Entry := _LLM_NavEventOwnerApplyReceipt(Receipt)
					if !IsObject(Entry) {
						FailureDetail :=
							"Navigation receipt could not be applied to its exact owner."
						BreakDrain := true
					} else if !_LLM_NavEventOwnerCompleteReceipt(
							Sequence, Token, TargetIdx) {
						FailureDetail :=
							"Navigation receipt completion was not acknowledged."
						BreakDrain := true
					} else {
						_LLM_NavEventOwnerClaimedReceipt := 0
						if Entry.Active {
							_LLM_NavEventOwnerPendingRepaints[Token] := Entry
							if !_LLM_NavEventOwnerRepaintFailures.Has(Token)
								_LLM_NavEventOwnerRepaintFailures[Token] := 0
						}
						_LLM_NavEventOwnerCollectToken(Token)
					}
				}
			} finally Critical(PreviousCritical)
			if FailureDetail != ""
				_LLM_NavEventOwnerReport(FailureDetail)
			if BreakDrain
				break
		}
		Candidates := []
		PreviousCritical := Critical("On")
		try {
			for Token, Entry in _LLM_NavEventOwnerPendingRepaints
				Candidates.Push(Map("token", Token, "entry", Entry))
		} finally Critical(PreviousCritical)
		for Candidate in Candidates {
			Token := Candidate["token"]
			Entry := Candidate["entry"]
			RepaintFailure := ""
			PauseWon := false
			Ready := false
			DegradeNeeded := false
			PreviousCritical := Critical("On")
			try {
				if A_IsSuspended || _LLM_NavEventOwnerLifecycleQuiesced {
					PauseWon := true
				} else if !_LLM_NavEventOwnerPendingRepaints.Has(Token)
						|| ObjPtr(_LLM_NavEventOwnerPendingRepaints[Token])
							!= ObjPtr(Entry) {
					continue
				} else if !_LLM_NavEventOwnerRecords.Has(Token)
						|| ObjPtr(_LLM_NavEventOwnerRecords[Token]) != ObjPtr(Entry)
						|| !Entry.Active {
					_LLM_NavEventOwnerPendingRepaints.Delete(Token)
					_LLM_NavEventOwnerRepaintFailures.Delete(Token)
				} else {
					Ready := true
				}
			} finally Critical(PreviousCritical)
			if PauseWon
				break
			if !Ready
				continue
			RenderResult := 0
			try {
				if HasMethod(Renderer, "Call")
					RenderResult := Renderer.Call(Entry.Record, Entry.Surface)
			} catch as Err {
				RepaintFailure := "Navigation receipt repaint failed: "
					. Err.Message . "."
			}
			RepaintSucceeded := (RenderResult is Integer) && RenderResult > 0
			PreviousCritical := Critical("On")
			try {
				PauseWon := A_IsSuspended
					|| _LLM_NavEventOwnerLifecycleQuiesced
				if _LLM_NavEventOwnerPendingRepaints.Has(Token)
						&& ObjPtr(_LLM_NavEventOwnerPendingRepaints[Token])
							== ObjPtr(Entry) {
					if RepaintSucceeded {
						_LLM_NavEventOwnerPendingRepaints.Delete(Token)
						_LLM_NavEventOwnerRepaintFailures.Delete(Token)
					} else if !_LLM_NavEventOwnerRecords.Has(Token)
							|| ObjPtr(_LLM_NavEventOwnerRecords[Token])
								!= ObjPtr(Entry)
							|| !Entry.Active {
						_LLM_NavEventOwnerPendingRepaints.Delete(Token)
						_LLM_NavEventOwnerRepaintFailures.Delete(Token)
					} else {
						Attempts := _LLM_NavEventOwnerRepaintFailures.Get(Token, 0) + 1
						_LLM_NavEventOwnerRepaintFailures[Token] := Attempts
						if Attempts >= LLM_NAV_EVENT_OWNER_REPAINT_MAX_ATTEMPTS {
							; Retire the expensive GUI debt before crossing the hide
							; boundary. A refusing/throwing exact hide is reported, but
							; can never resurrect a 10 Hz rebuild loop.
							_LLM_NavEventOwnerPendingRepaints.Delete(Token)
							_LLM_NavEventOwnerRepaintFailures.Delete(Token)
							DegradeNeeded := true
						}
					}
				}
			} finally Critical(PreviousCritical)
			if RepaintFailure != "" && !DegradeNeeded
				_LLM_NavEventOwnerReport(RepaintFailure)
			if DegradeNeeded {
				_LLM_NavEventOwnerReport(
					"Navigation receipt repaint retry budget was exhausted; hiding its exact tooltip owner.")
				Degraded := false
				try {
					if HasMethod(Degrader, "Call")
						Degraded := Degrader.Call(Entry.Record)
				} catch as Err {
					_LLM_NavEventOwnerReport(
						"Navigation repaint degradation failed: " . Err.Message . ".")
				}
				if !Degraded
					_LLM_NavEventOwnerReport(
						"Navigation repaint degradation was not acknowledged.")
			}
			if PauseWon
				break
		}
		return true
	} finally _LLM_NavEventOwnerDrainActive := false
}

LLM_NavEventOwner_Drain(RenderFn := 0, DegradeFn := 0,
		ProfileSelectFn := 0) {
	return _LLM_NavEventOwnerDrain(RenderFn, DegradeFn, ProfileSelectFn)
}

_LLM_NavEventOwnerRecoverNativeHealth(NativeErrorCode, RuntimeEpoch) {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerStarting, _LLM_NavEventOwnerStopping
	global _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerPendingStopRecovery
	global _LLM_NavEventOwnerRuntimeEpoch
	global _LLM_NavEventOwnerPort
	global _LLM_NavEventOwnerCommittedPlan
	global _LLM_NavEventOwnerLifecycleResumePlan
	global _LLM_NavEventOwnerLifecycleResumePort
	PreviousCritical := Critical("On")
	try {
		if !_LLM_NavEventOwnerStarted
				|| _LLM_NavEventOwnerQuarantined
				|| _LLM_NavEventOwnerStarting || _LLM_NavEventOwnerStopping
				|| _LLM_NavEventOwnerStopPending
				|| _LLM_NavEventOwnerPendingStopRecovery
				|| _LLM_NavEventOwnerRuntimeEpoch != RuntimeEpoch
			return false
		ResumePlan := _LLM_NavEventOwnerCommittedPlan
		ResumePort := _LLM_NavEventOwnerPort
		if ResumePlan is Array {
			; A native delivery fault is fail-open but may have suspended the hook.
			; Freeze the exact committed plan before publishing quarantine so every
			; refused or pending Stop retains one explicit recovery intent.
			_LLM_NavEventOwnerLifecycleResumePlan := ResumePlan
			_LLM_NavEventOwnerLifecycleResumePort := ResumePort
		}
		_LLM_NavEventOwnerStarted := false
		_LLM_NavEventOwnerQuarantined := true
	} finally Critical(PreviousCritical)
	Detail := NativeErrorCode is Integer && NativeErrorCode > 0
		? "Navigation event owner reported Win32 " . NativeErrorCode
		: "Navigation event owner health query was not acknowledged"
	_LLM_NavEventOwnerReport(Detail . "; restarting its exact plan.")
	return _LLM_NavEventOwnerQuarantineNow()
}

_LLM_NavEventOwnerCheckNativeHealth() {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerStarting, _LLM_NavEventOwnerStopping
	global _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerPendingStopRecovery
	global _LLM_NavEventOwnerRuntimeEpoch
	PreviousCritical := Critical("On")
	try {
		if !_LLM_NavEventOwnerStarted
				|| _LLM_NavEventOwnerQuarantined
				|| _LLM_NavEventOwnerStarting || _LLM_NavEventOwnerStopping
				|| _LLM_NavEventOwnerStopPending
				|| _LLM_NavEventOwnerPendingStopRecovery
			return true
		RuntimeEpoch := _LLM_NavEventOwnerRuntimeEpoch
	} finally Critical(PreviousCritical)
	HealthReadFailed := false
	NativeErrorCode := 0
	try NativeErrorCode := _LLM_NavEventOwnerCall("last_error",
		_LLM_NavEventOwnerNativeGetLastOsError)
	catch
		HealthReadFailed := true
	if !HealthReadFailed
			&& NativeErrorCode is Integer && NativeErrorCode == 0
		return true
	if HealthReadFailed || !(NativeErrorCode is Integer)
		NativeErrorCode := -1
	return _LLM_NavEventOwnerRecoverNativeHealth(
		NativeErrorCode, RuntimeEpoch)
}

_LLM_NavEventOwnerOnWake(*) {
	_LLM_NavEventOwnerService()
	return 0
}

_LLM_NavEventOwnerService(RenderFn := 0, DegradeFn := 0) {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerStartRollbackPending
	global _LLM_NavEventOwnerStopPending
	if IsSet(_HSE_RetryTerminalReplay)
		try _HSE_RetryTerminalReplay()
	; A refused quarantine Stop deliberately retains the only service route for
	; receipts which were already suppressed. Drain them while fail-open
	; quarantine blocks new decisions; a proved Stop disarms this timer instead.
	if _LLM_NavEventOwnerStarted || _LLM_NavEventOwnerQuarantined
		_LLM_NavEventOwnerDrain(RenderFn, DegradeFn)
	if _LLM_NavEventOwnerStarted && !_LLM_NavEventOwnerQuarantined
		_LLM_NavEventOwnerCheckNativeHealth()
	if _LLM_NavEventOwnerStopPending {
		_LLM_NavEventOwnerRecoverPendingStop()
		return
	}
	if _LLM_NavEventOwnerStartRollbackPending {
		_LLM_NavEventOwnerRecoverStartRollback()
		return
	}
	; A non-pending Stop refusal keeps the only wake/watchdog route alive. Retry
	; terminal cleanup at a throttled boundary after every receipt and repaint debt
	; has converged; otherwise quarantine would remain permanent until unrelated UI.
	if _LLM_NavEventOwnerQuarantined
		_LLM_NavEventOwnerQuarantineNow(true)
}

LLM_NavEventOwner_ScheduleDrain() {
	SetTimer(_LLM_NavEventOwnerRetryDrain, -1)
	return true
}

_LLM_NavEventOwnerRetryDrain(*) {
	_LLM_NavEventOwnerDrain()
}

LLM_NavEventOwner_SyncRecord(Record, AllowLifecycleResume := false) {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerPendingStopRecovery
	global _LLM_NavEventOwnerLifecycleQuiesced
	; A parse-time #HotIf can reach this helper before the adapter's top-level
	; initializers run. Partial lifecycle state cannot certify a visible record.
	if !IsSet(_LLM_NavEventOwnerStarted)
			|| !IsSet(_LLM_NavEventOwnerQuarantined)
			|| !IsSet(_LLM_NavEventOwnerPendingStopRecovery)
			|| !IsSet(_LLM_NavEventOwnerLifecycleQuiesced)
		return false
	if A_IsSuspended || _LLM_NavEventOwnerQuarantined
			|| ((_LLM_NavEventOwnerPendingStopRecovery
					|| _LLM_NavEventOwnerLifecycleQuiesced)
				&& !AllowLifecycleResume)
		return false
	if !_LLM_NavEventOwnerStarted
		return true
	if !IsObject(Record)
			|| !Record.HasOwnProp("NavOwnerToken")
		return true
	try ActiveIdx := _LLM_NavEventOwnerCall("get_owner",
		_LLM_NavEventOwnerNativeGetOwner, Record.NavOwnerToken)
	catch
		return false
	if !(ActiveIdx is Integer) || ActiveIdx <= 0
		return false
	if !(Record.Slots is Array) || ActiveIdx > Record.Slots.Length
		return false
	Record.ActiveIdx := ActiveIdx
	return true
}

_LLM_NavEventOwnerPublishCurrentSurface(AllowLifecycleResume := false) {
	global _TooltipActiveSurface, _LLM_NavEventOwnerRecords
	Surface := IsSet(_TooltipActiveSurface) ? _TooltipActiveSurface : 0
	Record := _LLM_NavEventOwnerRecordFromSurface(Surface)
	if IsObject(Record) && Record.Kind == "prediction" {
		; Acceptance is the native linearization point. A lifecycle replay may
		; rebuild the routing plan, but it must never attach the still-visible
		; terminal pixels as a fresh owner while their deferred hide completes.
		if Record.HasOwnProp("Lifecycle") && IsObject(Record.Lifecycle)
				&& Record.Lifecycle.HasOwnProp("Outcome")
				&& Record.Lifecycle.Outcome != ""
			return true
		Token := _LLM_NavEventOwnerTokenFromSurface(Surface)
		if Token <= 0 || !_LLM_NavEventOwnerRecords.Has(Token) {
			if LLM_NavEventOwner_AttachRecord(Record, Surface) <= 0
				return false
		}
	}
	Transaction := LLM_NavEventOwner_BeginSurfaceSwap(
		0, Surface, AllowLifecycleResume)
	return Transaction is Map
		&& LLM_NavEventOwner_CommitSurfaceSwap(Transaction)
}

_LLM_NavEventOwnerPublishCurrentProfileSurface(
		AllowLifecycleResume := false) {
	if !IsSet(_LLM_Menu_PublishCurrentNativeProfileOwner)
		return true
	try Status := _LLM_Menu_PublishCurrentNativeProfileOwner(
		AllowLifecycleResume)
	catch as Err {
		_LLM_NavEventOwnerReport(
			"Current profile hotkey owner publication raised an error: "
			. Err.Message . ".")
		return false
	}
	return (Status is Integer) && Status == 1
}

; Native adapter functions are implemented below the domain-facing bridge so
; unit tests can replace each boundary through a Map port without loading the
; DLL or installing a hook.
_LLM_NavEventOwnerNativeStart(Hwnd, WakeMessage) {
	_LLM_NavEventOwnerNativeEnsureLoaded()
	Status := DllCall(_LLM_NavEventOwnerNativeExport("ErgoptiNav_Start"),
		"UInt64", Hwnd, "UInt", WakeMessage, "Int")
	if Status != 0 {
		DllCall(_LLM_NavEventOwnerNativeExport(
			"ErgoptiNav_Stop"), "Int")
	}
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Navigation owner start")
	return 1
}

_LLM_NavEventOwnerNativeStop() {
	global _LLM_NavEventOwnerModule
	if !_LLM_NavEventOwnerModule
		return 1
	Status := DllCall(_LLM_NavEventOwnerNativeExport("ErgoptiNav_Stop"),
		"Int")
	if Status == 9
		return Map("stopped", false, "pending", true)
	if Status == 10 {
		NativeErrorCode := 0
		try NativeErrorCode := DllCall(_LLM_NavEventOwnerNativeExport(
			"ErgoptiNav_GetLastOsError"), "UInt")
		Suffix := NativeErrorCode ? " (Win32 " . NativeErrorCode . ")" : ""
		_LLM_NavEventOwnerReport(
			"Navigation owner stopped with a teardown diagnostic" . Suffix . ".")
		return 1
	}
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Navigation owner stop")
	return 1
}

_LLM_NavEventOwnerNativeGetLastOsError() {
	global _LLM_NavEventOwnerModule
	if !_LLM_NavEventOwnerModule
		return 0
	return DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_GetLastOsError"), "UInt")
}

_LLM_NavEventOwnerNativeUnload() {
	; The DLL owns an InitOnce-initialized CRITICAL_SECTION and is intentionally
	; process-resident. Stop resets semantic/thread state; the OS unloads the
	; module at process exit. This also prevents a timed-out hook thread from ever
	; executing code after FreeLibrary.
	return true
}

_LLM_NavEventOwnerNativeSuspend(Value) {
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_SetSuspended"), "UChar", Value, "Int")
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Navigation owner suspend transition")
	return 1
}

_LLM_NavEventOwnerNativeCanStop() {
	CanStop := 0
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_CanStop"), "UChar*", &CanStop, "Int")
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Navigation owner terminal-debt query")
	return CanStop == 1 ? 1 : 0
}

_LLM_NavEventOwnerNativeBeginTerminalCapture(Token) {
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_BeginTerminalCapture"), "UInt64", Token, "Int")
	if Status == 5
		return 0
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Terminal keyboard capture admission")
	return 1
}

_LLM_NavEventOwnerNativeCommitTerminalCapture(Token) {
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_CommitTerminalCapture"), "UInt64", Token, "Int")
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Terminal keyboard capture commit")
	return 1
}

_LLM_NavEventOwnerNativeAbortTerminalCapture(Token) {
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_AbortTerminalCapture"), "UInt64", Token, "Int")
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Terminal keyboard capture abort")
	return 1
}

_LLM_NavEventOwnerNativeGetTerminalCapture(Token) {
	Snapshot := Buffer(28, 0)
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_GetTerminalCapture"), "UInt64", Token,
		"Ptr", Snapshot, "Int")
	if Status == 8
		return 0
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Terminal keyboard capture snapshot")
	return Map(
		"token", NumGet(Snapshot, 0, "UInt64"),
		"phase", NumGet(Snapshot, 8, "UInt"),
		"queued", NumGet(Snapshot, 12, "UInt"),
		"replayed", NumGet(Snapshot, 16, "UInt"),
		"last_os_error", NumGet(Snapshot, 20, "UInt"),
		"release_kind", NumGet(Snapshot, 24, "UInt"))
}

_LLM_NavEventOwnerNativePreparePlan(Plan) {
	global LLM_NAV_EVENT_OWNER_INPUT_LEVEL
	if !(Plan is Array) || Plan.Length != 12
		return 0
	Bindings := Buffer(12 * 12, 0)
	Loop 12 {
		if !Plan.Has(A_Index)
			return 0
		Entry := Plan[A_Index]
		if !(Entry is Map)
			return 0
		Identity := Entry.Get("physical_id", "")
		if !RegExMatch(Identity,
				"i)^([*]?)([\^!+#]*)(vk|sc)([0-9a-f]{4})$", &Match)
			return 0
		if Match[1] != ""
			return 0
		Modifiers := 0
		Loop Parse, Match[2] {
			Modifiers |= A_LoopField == "^" ? 0x01
				: A_LoopField == "!" ? 0x02
				: A_LoopField == "+" ? 0x04
				: A_LoopField == "#" ? 0x08 : 0
		}
		Axis := StrLower(Match[3]) == "vk" ? 1 : 2
		Code := Integer("0x" . Match[4])
		Action := A_Index <= 2 ? 1 : 2
		PassThrough := A_Index <= 2 ? 1 : 0
		Delta := A_Index == 1 ? -1 : A_Index == 2 ? 1 : 0
		Target := A_Index <= 2 ? 0 : Entry.Get("jump_idx", 0)
		if !(Target is Integer) || Target < 0 || Target > 10
			return 0
		Offset := (A_Index - 1) * 12
		NumPut("UChar", Axis, "UChar", Action,
			"UChar", Modifiers, "UChar", PassThrough,
			"UShort", Code, "Char", Delta,
			"UChar", Target,
			"UChar", LLM_NAV_EVENT_OWNER_INPUT_LEVEL,
			Bindings, Offset)
	}
	Generation := 0
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_PreparePlan"), "Ptr", Bindings,
		"UInt", 12, "UInt64*", &Generation, "Int")
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Navigation owner plan preparation")
	return Generation
}

_LLM_NavEventOwnerNativeCommitPlan(Generation) {
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_CommitPlan"), "UInt64", Generation, "Int")
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Navigation owner plan commit")
	return 1
}

_LLM_NavEventOwnerNativeBeginProfileSwap(ExpectedToken, Plan, NewToken,
		ProfileCount) {
	global LLM_NAV_EVENT_OWNER_INPUT_LEVEL
	if !_LLM_NavEventOwnerProfilePlanIsValid(Plan)
			|| !(ExpectedToken is Integer) || ExpectedToken < 0
			|| !(NewToken is Integer) || NewToken < 0
			|| !(ProfileCount is Integer) || ProfileCount < 0
			|| ProfileCount > 9 || (NewToken == 0) != (ProfileCount == 0)
		return 0
	Bindings := Buffer(9 * 12, 0)
	Loop 9 {
		Entry := Plan[A_Index]
		Identity := Entry["physical_id"]
		if !RegExMatch(Identity,
				"i)^([*]?)([\^!+#]*)(vk|sc)([0-9a-f]{4})$", &Match)
			return 0
		if Match[1] != ""
			return 0
		Modifiers := 0
		Loop Parse, Match[2] {
			Modifiers |= A_LoopField == "^" ? 0x01
				: A_LoopField == "!" ? 0x02
				: A_LoopField == "+" ? 0x04
				: A_LoopField == "#" ? 0x08 : 0
		}
		Axis := StrLower(Match[3]) == "vk" ? 1 : 2
		Code := Integer("0x" . Match[4])
		Offset := (A_Index - 1) * 12
		NumPut("UChar", Axis, "UChar", 3,
			"UChar", Modifiers, "UChar", 0,
			"UShort", Code, "Char", 0,
			"UChar", A_Index,
			"UChar", LLM_NAV_EVENT_OWNER_INPUT_LEVEL,
			Bindings, Offset)
	}
	Owner := Buffer(24, 0)
	if NewToken > 0
		NumPut("UInt64", NewToken, "UInt64", NewToken,
			"UChar", ProfileCount, Owner, 0)
	Ticket := 0
	PendingMask := 0
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_BeginProfileSwap"), "UInt64", ExpectedToken,
		"Ptr", Bindings, "UInt", 9, "Ptr", Owner,
		"UInt64*", &Ticket, "UShort*", &PendingMask, "Int")
	if Status == 5 || Status == 8
		return 0
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Profile hotkey owner preparation")
	return Map("ticket", Ticket, "pending_mask", PendingMask)
}

_LLM_NavEventOwnerNativeCommitProfileSwap(Ticket) {
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_CommitProfileSwap"), "UInt64", Ticket, "Int")
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Profile hotkey owner commit")
	return 1
}

_LLM_NavEventOwnerNativeAbortProfileSwap(Ticket) {
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_AbortProfileSwap"), "UInt64", Ticket, "Int")
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Profile hotkey owner abort")
	return 1
}

_LLM_NavEventOwnerNativeProfilePendingMask(Token) {
	PendingMask := 0
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_ProfilePendingMask"), "UInt64", Token,
		"UShort*", &PendingMask, "Int")
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Profile hotkey receipt retention query")
	return PendingMask
}

_LLM_NavEventOwnerNativeBeginSwap(OldToken, NewToken, SlotCount, ActiveIdx,
		RequireIndexMatch := 0) {
	Owner := Buffer(24, 0)
	if NewToken > 0 {
		NumPut("UInt64", NewToken, "UInt64", NewToken,
			"UChar", SlotCount, "UChar", ActiveIdx,
			"UChar", RequireIndexMatch, Owner, 0)
	}
	Ticket := 0
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_BeginOwnerSwap"), "UInt64", OldToken,
		"Ptr", Owner, "UInt64*", &Ticket, "Int")
	; A repaint whose old token or rendered index went stale is a normal retry.
	; The native side returned before publishing a transition fence.
	if Status == 8 && RequireIndexMatch == 1
		return -1
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Navigation owner surface preparation")
	return Ticket
}

_LLM_NavEventOwnerNativeCommitSwap(Ticket) {
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_CommitOwnerSwap"), "UInt64", Ticket, "Int")
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Navigation owner surface commit")
	return 1
}

_LLM_NavEventOwnerNativeAbortSwap(Ticket) {
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_AbortOwnerSwap"), "UInt64", Ticket, "Int")
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Navigation owner surface abort")
	return 1
}

_LLM_NavEventOwnerNativeClaimOwner(Token, ExpectedActiveIdx) {
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_ClaimOwner"), "UInt64", Token,
		"UChar", ExpectedActiveIdx, "Int")
	if Status == 5 || Status == 8
		return 0
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Navigation owner acceptance claim")
	return 1
}

_LLM_NavEventOwnerNativePollReceipt() {
	Receipt := Buffer(40, 0)
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_PollReceipt"), "Ptr", Receipt, "Int")
	if Status == 4
		return 0
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Navigation receipt poll")
	return Map(
		"seq", NumGet(Receipt, 0, "UInt64"),
		"owner_token", NumGet(Receipt, 8, "UInt64"),
		"owner_epoch", NumGet(Receipt, 16, "UInt64"),
		"plan_generation", NumGet(Receipt, 24, "UInt64"),
		"route_idx", NumGet(Receipt, 32, "UChar"),
		"action", NumGet(Receipt, 33, "UChar"),
		"delta", NumGet(Receipt, 34, "Char"),
		"from_idx", NumGet(Receipt, 35, "UChar"),
		"target_idx", NumGet(Receipt, 36, "UChar"),
		"pass_through", NumGet(Receipt, 37, "UChar"))
}

_LLM_NavEventOwnerNativeCompleteReceipt(Sequence, OwnerToken, AppliedIndex) {
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_CompleteReceipt"), "UInt64", Sequence,
		"UInt64", OwnerToken, "UChar", AppliedIndex, "Int")
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Navigation receipt completion")
	return 1
}

_LLM_NavEventOwnerNativePendingForToken(Token) {
	Pending := 0
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_PendingForToken"), "UInt64", Token,
		"UInt*", &Pending, "Int")
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Navigation receipt retention query")
	return Pending
}

_LLM_NavEventOwnerNativeGetOwner(Token) {
	Owner := Buffer(24, 0)
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_GetOwner"), "Ptr", Owner, "Int")
	if Status == 5
		return 0
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Navigation owner snapshot")
	return NumGet(Owner, 0, "UInt64") == Token
		? NumGet(Owner, 17, "UChar") : 0
}

_LLM_NavEventOwnerNativeTestDispatch(Event) {
	if !(Event is Map)
		return 0
	NativeEvent := Buffer(16, 0)
	NumPut("UShort", Event.Get("vk", 0),
		"UShort", Event.Get("sc", 0),
		"UChar", Event.Get("modifiers", 0),
		"UChar", Event.Get("kind", 0),
		"UChar", Event.Get("injected", 0),
		"UChar", 0,
		"UInt64", Event.Get("extra_info", 0), NativeEvent, 0)
	Result := Buffer(12, 0)
	Status := DllCall(_LLM_NavEventOwnerNativeExport(
		"ErgoptiNav_TestDispatch"), "Ptr", NativeEvent,
		"Ptr", Result, "Int")
	_LLM_NavEventOwnerNativeRequireOk(Status,
		"Navigation test dispatch")
	return Map(
		"disposition", NumGet(Result, 0, "UChar"),
		"receipt_created", NumGet(Result, 1, "UChar"),
		"route_idx", NumGet(Result, 2, "UChar"),
		"seq", NumGet(Result, 4, "UInt64"))
}

_LLM_NavEventOwnerNativeEnsureLoaded() {
	global _LLM_NavEventOwnerModule, _LLM_NavEventOwnerExports, _VendorDir
	if _LLM_NavEventOwnerModule
		return true
	if A_PtrSize != 8
		throw Error("Navigation owner requires a 64-bit process")
	Path := _VendorDir . "\ergopti_nav_owner.dll"
	Module := DllCall("Kernel32\LoadLibraryW", "Str", Path, "Ptr")
	if !Module
		throw Error("Navigation owner DLL could not be loaded")
	Names := [
		"ErgoptiNav_Start", "ErgoptiNav_Stop",
		"ErgoptiNav_PreparePlan", "ErgoptiNav_CommitPlan",
		"ErgoptiNav_SetSuspended", "ErgoptiNav_CanStop",
		"ErgoptiNav_BeginTerminalCapture",
		"ErgoptiNav_CommitTerminalCapture",
		"ErgoptiNav_AbortTerminalCapture",
		"ErgoptiNav_GetTerminalCapture",
		"ErgoptiNav_BeginOwnerSwap",
		"ErgoptiNav_CommitOwnerSwap", "ErgoptiNav_AbortOwnerSwap",
		"ErgoptiNav_ClaimOwner",
		"ErgoptiNav_GetOwner", "ErgoptiNav_PollReceipt",
		"ErgoptiNav_BeginProfileSwap",
		"ErgoptiNav_CommitProfileSwap",
		"ErgoptiNav_AbortProfileSwap",
		"ErgoptiNav_ProfilePendingMask",
		"ErgoptiNav_CompleteReceipt", "ErgoptiNav_PendingForToken",
		"ErgoptiNav_GetLastOsError", "ErgoptiNav_TestDispatch"
	]
	Exports := Map()
	try {
		for Name in Names {
			Address := DllCall("Kernel32\GetProcAddress", "Ptr", Module,
				"AStr", Name, "Ptr")
			if !Address
				throw Error("Navigation owner DLL export is missing")
			Exports[Name] := Address
		}
	} catch as Err {
		DllCall("Kernel32\FreeLibrary", "Ptr", Module, "Int")
		throw Err
	}
	_LLM_NavEventOwnerModule := Module
	_LLM_NavEventOwnerExports := Exports
	return true
}

_LLM_NavEventOwnerNativeExport(Name) {
	global _LLM_NavEventOwnerExports
	_LLM_NavEventOwnerNativeEnsureLoaded()
	if !_LLM_NavEventOwnerExports.Has(Name)
		throw Error("Navigation owner DLL export is unavailable")
	return _LLM_NavEventOwnerExports[Name]
}

_LLM_NavEventOwnerNativeRequireOk(Status, Operation) {
	if Status == 0
		return true
	NativeErrorCode := 0
	if Status == 6 {
		try NativeErrorCode := DllCall(_LLM_NavEventOwnerNativeExport(
			"ErgoptiNav_GetLastOsError"), "UInt")
	}
	Suffix := NativeErrorCode ? ", Win32 " . NativeErrorCode : ""
	throw Error(Operation . " failed with status " . Status . Suffix)
}
