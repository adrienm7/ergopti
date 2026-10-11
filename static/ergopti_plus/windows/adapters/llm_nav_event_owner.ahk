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
global _LLM_NavEventOwnerProfileFailures := Map()
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
; The DLL's plan contract (NavPlanIsValid) still demands one Up and one Down
; cycle route that passes its key on, and changing it means rebuilding the DLL
; with MSVC. The cycle is AutoHotkey's instead (menu_llm/tab_accept.ahk):
; Windows calls the most recently installed keyboard hook first, and AutoHotkey
; reinstalls its own around every SendInput, so a native cycle ran before the
; hotkey that consumes the chord, or never when that hotkey swallowed the key
; first (llm-nav-cycle-windows). Both routes are parked on extended scan code
; zero, which no key produces and AutoHotkey never sends, while any other
; injection is ineligible (NavInputIsEligible): the native owner never cycles.
; Their modifier masks only keep them distinct, as the contract requires.
global LLM_NAV_EVENT_OWNER_PARKED_CYCLE_ROUTES := [
	Map("axis", 2, "code", 0x100, "modifiers", 0x0F),
	Map("axis", 2, "code", 0x100, "modifiers", 0x0E)]
global LLM_NAV_EVENT_OWNER_QUARANTINE_RETRY_MS := 1000
global LLM_NAV_EVENT_OWNER_REPAINT_MAX_ATTEMPTS := 3
; A profile receipt owns a SUPPRESSED physical key. Unlike a repaint, refusing to
; retire it costs the user their keystroke, so the budget exists for the same
; reason and is deliberately as small (llm-profile-receipt-retry-livelock).
global LLM_NAV_EVENT_OWNER_PROFILE_MAX_ATTEMPTS := 3
global _LLM_NavEventOwnerLastQuarantineStopAttemptTick := 0
global _LLM_NavEventOwnerReportTimes := Map()
global _LLM_NavEventOwnerTerminalRouteOwner := A_ScriptHwnd
global _LLM_NavEventOwnerTerminalRouteGeneration := 0
global _LLM_NavEventOwnerTerminalRouteNextRecipe := 0
global _LLM_NavEventOwnerTerminalRouteNextLayout := 1
global _LLM_NavEventOwnerTerminalRouteRefreshing := false
global _LLM_NavEventOwnerTerminalRouteRecipes := Map()
global _LLM_NavEventOwnerTerminalRouteModels := Map()
global _LLM_NavEventOwnerTerminalRouteCoverage := Map(
	"generation", 0, "layout_id", 0, "registered", 0,
	"cohort_complete", false, "transformed_output_enabled", false,
	"unconverted", ["unregistered terminal route cohorts"])

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

_LLM_NavEventOwnerStopExceptionDetail(Err) {
	NativeStatus := "unavailable"
	NativeError := "unavailable"
	if Err is Error {
		if Err.HasOwnProp("NativeStatus") && Err.NativeStatus is Integer
			NativeStatus := Err.NativeStatus
		if Err.HasOwnProp("NativeErrorCode") && Err.NativeErrorCode is Integer
			NativeError := Err.NativeErrorCode
		else if Err is OSError
			NativeError := Err.Number
	}
	return "stage=native_stop outcome=exception error_type=" . Type(Err)
		. " native_status=" . NativeStatus . " native_error=" . NativeError
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
	global _LLM_NavEventOwnerProfileFailures
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
		WasPending := _LLM_NavEventOwnerStopPending
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
	StopFailure := ""
	if ShouldStop {
		try StopResult := _LLM_NavEventOwnerCall("stop",
			_LLM_NavEventOwnerNativeStop)
		catch as Err {
			StopResult := 0
			StopFailure := _LLM_NavEventOwnerStopExceptionDetail(Err)
		}
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
		if !WasPending
			try LoggerDebug("LLM.nav", "stage=native_stop outcome=pending.")
		return false
	}
	if !Stopped {
		PreviousCritical := Critical("On")
		try _LLM_NavEventOwnerStopping := false
		finally Critical(PreviousCritical)
		if StopFailure == ""
			StopFailure := "stage=native_stop outcome=refused result_type="
				. Type(StopResult) . " result_code="
				. (StopResult is Integer ? StopResult : "unavailable")
		_LLM_NavEventOwnerReport(StopFailure)
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
		_LLM_NavEventOwnerProfileFailures := Map()
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
	if ShouldStop && Unloaded
		try LoggerDebug("LLM.nav", "stage=native_stop outcome=stopped.")
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
	global _LLM_NavEventOwnerLifecycleQuiesced
	if !_LLM_NavEventOwnerStarted {
		_LLM_NavEventOwnerShutdownFenced := false
		return !_LLM_NavEventOwnerQuarantined
	}
	if _LLM_NavEventOwnerQuarantined
		return false
	; A pause has already suspended the native owner, and its fence is the
	; pause's: this preflight neither suspends it again nor, on a refusal,
	; resumes its hook under a paused driver. The receipt drain refuses to run
	; under a pause (its receipts wait for a resume an exit never gives), and
	; that refusal is not a debt: taking it for one refused every reload asked
	; while paused (reload-refused-while-paused). The native proof below still
	; refuses an exit that would strand a suppressed key or a queued receipt.
	Paused := A_IsSuspended || _LLM_NavEventOwnerLifecycleQuiesced
	if !_LLM_NavEventOwnerLifecycleQuiesced {
		if !LLM_NavEventOwner_SetSuspended(true)
			return false
		_LLM_NavEventOwnerShutdownFenced := true
	}
	Drained := Paused
	if !Paused {
		try Drained := _LLM_NavEventOwnerDrain(0, 0, ProfileSelectFn)
		catch as Err
			_LLM_NavEventOwnerReport(
				"Shutdown receipt drain raised an error: " . Err.Message . ".")
	}
	TerminalDebt := _LLM_NavEventOwnerHasTerminalDebt()
	Ready := Drained && !TerminalDebt && _LLM_NavEventOwnerCanStop(Port)
	if Ready
		return true
	; The lifecycle only says that the owner refused: name what did.
	_LLM_NavEventOwnerReport("Shutdown preflight refused (paused="
		. (Paused ? 1 : 0) . ", receipts_drained=" . (Drained ? 1 : 0)
		. ", terminal_debt=" . (TerminalDebt ? 1 : 0)
		. (Drained && !TerminalDebt ? ", native_can_stop=0" : "") . ").")
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
		EnterFn, ResumeFn, SuspendFn, IconFn, NeedsCompensationFn := 0) {
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
		; Lift native Suspend first. A failed preflight needs no further work, while
		; a transaction that accumulated debt after teardown began must run the
		; resume reactor to restore every owner it may already have stopped.
		NeedsCompensation := HasMethod(NeedsCompensationFn, "Call")
			and NeedsCompensationFn.Call()
		SuspendFn.Call(0)
		_LastSuspendState := false
		if NeedsCompensation
			ResumeFn.Call()
		IconFn.Call()
		return false
	}
	return ResumeFn.Call()
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
	; A disable publishes the empty owner: token 0 carries no profile count. The
	; order still lists the defined profiles, and passing its length with token 0
	; made the adapter refuse every disable (llm-profile-disable-count).
	ProfileCount := NewToken > 0 ? NormalizedOrder.Length : 0
	Fn := _LLM_NavEventOwnerPortFn("begin_profile_swap", Port)
	try Result := HasMethod(Fn, "Call")
		? Fn.Call(ExpectedToken, Plan, NewToken, ProfileCount)
		: _LLM_NavEventOwnerNativeBeginProfileSwap(
			ExpectedToken, Plan, NewToken, ProfileCount)
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
	global _LLM_NavEventOwnerProfileFailures
	global LLM_NAV_EVENT_OWNER_PROFILE_MAX_ATTEMPTS
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
		; Map.Delete raises on a key that was never inserted, and the common case
		; here is a first attempt that succeeded and therefore never recorded one
		; (project-ahk-map-delete-raises-on-missing-key).
		FailureKey := Sequence . ":" . Token . ":" . TargetIdx
		if Applied {
			if _LLM_NavEventOwnerProfileFailures.Has(FailureKey)
				_LLM_NavEventOwnerProfileFailures.Delete(FailureKey)
		} else {
			; A refused effect used to return here with the receipt still CLAIMED.
			; Nothing ever retired it, so the 100 ms service timer re-attempted the
			; same doomed selection forever while the receipt kept its suppressed
			; physical key: the digit never reached the focused app, the error log
			; grew at ~10 Hz, and OnExit stayed vetoed because a native receipt was
			; still owned. Bound the attempts exactly like the repaint budget above
			; (llm-profile-receipt-retry-livelock).
			Attempts := _LLM_NavEventOwnerProfileFailures.Get(FailureKey, 0) + 1
			_LLM_NavEventOwnerProfileFailures[FailureKey] := Attempts
			if Attempts < LLM_NAV_EVENT_OWNER_PROFILE_MAX_ATTEMPTS {
				_LLM_NavEventOwnerReport(FailureDetail)
				return false
			}
			; Budget exhausted: retire the debt by falling through to completion.
			; The profile stays unchanged -- that effect has proven unavailable --
			; but the key is released and the owner can quiesce. Losing one
			; deliberate hotkey press beats swallowing every subsequent keystroke.
			_LLM_NavEventOwnerProfileFailures.Delete(FailureKey)
			_LLM_NavEventOwnerReport(FailureDetail
				. " Retiring the receipt after " . Attempts
				. " attempts; the profile is unchanged and the key is released.")
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

_LLM_NavEventOwnerDrain(RenderFn := 0, DegradeFn := 0, ProfileSelectFn := 0,
		SlotAcceptFn := 0) {
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
	; A consumed validation chord (a jump receipt) also inserts its slot once the
	; modifiers are released; Up/Down cycle receipts only move the active slot
	; (llm-val-chord-inserts).
	SlotAccepter := HasMethod(SlotAcceptFn, "Call") ? SlotAcceptFn : 0
	if !HasMethod(SlotAccepter, "Call")
			&& IsSet(LLM_Tooltip_ScheduleSlotAcceptance)
		SlotAccepter := LLM_Tooltip_ScheduleSlotAcceptance
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
			SlotAcceptEntry := 0
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
							if Receipt.Get("action", 0) == 2
								SlotAcceptEntry := Entry
						}
						_LLM_NavEventOwnerCollectToken(Token)
					}
				}
			} finally Critical(PreviousCritical)
			if FailureDetail != ""
				_LLM_NavEventOwnerReport(FailureDetail)
			if IsObject(SlotAcceptEntry) && HasMethod(SlotAccepter, "Call") {
				try SlotAccepter.Call(SlotAcceptEntry.Record,
					SlotAcceptEntry.Surface, TargetIdx)
				catch as Err
					_LLM_NavEventOwnerReport(
						"Validation chord insertion could not be armed: "
						. Err.Message . ".")
			}
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
		ProfileSelectFn := 0, SlotAcceptFn := 0) {
	return _LLM_NavEventOwnerDrain(RenderFn, DegradeFn, ProfileSelectFn,
		SlotAcceptFn)
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

; Whether the native owner routes navigation for Record right now: started,
; not quarantined or fenced, holding a committed plan, and naming Record's token
; as its active owner. Unlike LLM_NavEventOwner_SyncRecord, an owner that is not
; running answers false: its validation chords are then the application's, and
; the navigation chord must not be consumed either (llm-tooltip-nav-consumed).
; @param {Object} Record - Presented prediction record.
; @returns {Boolean}
LLM_NavEventOwner_RoutesRecord(Record) {
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerCommittedPlan
	; A parse-time #HotIf reaches this before the adapter's initializers run.
	if !IsSet(_LLM_NavEventOwnerStarted)
			|| !IsSet(_LLM_NavEventOwnerQuarantined)
			|| !IsSet(_LLM_NavEventOwnerCommittedPlan)
		return false
	if !_LLM_NavEventOwnerStarted || _LLM_NavEventOwnerQuarantined
			|| !(_LLM_NavEventOwnerCommittedPlan is Array)
		return false
	if !IsObject(Record) || !Record.HasOwnProp("NavOwnerToken")
			|| !(Record.NavOwnerToken is Integer) || Record.NavOwnerToken <= 0
		return false
	return LLM_NavEventOwner_SyncRecord(Record)
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

/**
 * Refreshes authoritative terminal-route metadata without enabling typed replay.
 * @param {Map|Integer} Port - Optional source and native-registration boundaries.
 * @returns {Boolean} True only after the exact native registration ACK.
 */
LLM_NavEventOwner_RefreshTerminalRoutes(Port := 0) {
	global _LLM_NavEventOwnerTerminalRouteRefreshing
	global _LLM_NavEventOwnerTerminalRouteGeneration
	global _LLM_NavEventOwnerTerminalRouteOwner
	global _LLM_NavEventOwnerTerminalRouteRecipes
	global _LLM_NavEventOwnerTerminalRouteCoverage
	PreviousCritical := Critical("On")
	try {
		if _LLM_NavEventOwnerTerminalRouteRefreshing
			return false
		_LLM_NavEventOwnerTerminalRouteRefreshing := true
		try {
			SourceFn := _LLM_NavEventOwnerPortFn("terminal_route_source", Port)
			Source := HasMethod(SourceFn, "Call")
				? SourceFn.Call() : _LLM_NavEventOwnerTerminalRouteSource()
			_LLM_NavEventOwnerTerminalRouteGeneration += 1
			if _LLM_NavEventOwnerTerminalRouteGeneration <= 0
				throw Error("Terminal route registration generation overflowed.")
			Generation := _LLM_NavEventOwnerTerminalRouteGeneration
			Candidate := _LLM_NavEventOwnerTerminalRouteBuild(Source, Generation)
			Bindings := _LLM_NavEventOwnerTerminalRouteMarshal(Candidate["routes"])
			RegisterFn := _LLM_NavEventOwnerPortFn("register_terminal_routes", Port)
			Status := HasMethod(RegisterFn, "Call")
				? RegisterFn.Call(_LLM_NavEventOwnerTerminalRouteOwner,
					Generation, Candidate["layout_id"], Bindings, Candidate["routes"].Length)
				: _LLM_NavEventOwnerNativeRegisterTerminalRoutes(
					_LLM_NavEventOwnerTerminalRouteOwner, Generation,
					Candidate["layout_id"], Bindings, Candidate["routes"].Length)
			if !(Status is Integer)
				throw Error("Terminal route registration returned a malformed ACK.")
			if Status == -11
				return false
			_LLM_NavEventOwnerNativeRequireOk(Status, "Terminal route registration")
			for RecipeId, Admission in Candidate["recipes"]
				_LLM_NavEventOwnerTerminalRouteRecipes[RecipeId] := Admission
			_LLM_NavEventOwnerTerminalRouteCoverage := Map(
				"generation", Generation, "layout_id", Candidate["layout_id"],
				"registered", Candidate["routes"].Length,
				"cohort_complete", false, "transformed_output_enabled", false,
				"unconverted", Candidate["unconverted"])
			_LLM_NavEventOwnerTerminalRoutePrune(Candidate, Source, Port)
			return true
		} finally _LLM_NavEventOwnerTerminalRouteRefreshing := false
	} finally Critical(PreviousCritical)
}

/**
 * Retains current registrations and exact native held identities only. The
 * registration ACK establishes a debt-free boundary; Critical prevents this
 * script from starting capture between publication and the held-identity query.
 * A failed or malformed query retains every reference for a later safe retry.
 */
_LLM_NavEventOwnerTerminalRoutePrune(Candidate, Source, Port) {
	global _LLM_NavEventOwnerTerminalRouteOwner
	global _LLM_NavEventOwnerTerminalRouteRecipes, _LLM_NavEventOwnerTerminalRouteModels
	try {
		HeldFn := _LLM_NavEventOwnerPortFn("list_terminal_held_recipes", Port)
		; An injected registration without a held-reference boundary cannot prove
		; retirement. Do not reach the real DLL through an incomplete test port.
		if !HasMethod(HeldFn, "Call")
				&& HasMethod(_LLM_NavEventOwnerPortFn("register_terminal_routes", Port), "Call")
			return false
		HeldBuffer := Buffer(64 * 8, 0)
		Reply := HasMethod(HeldFn, "Call")
			? HeldFn.Call(_LLM_NavEventOwnerTerminalRouteOwner, HeldBuffer, 64)
			: _LLM_NavEventOwnerNativeListTerminalHeldRecipes(
				_LLM_NavEventOwnerTerminalRouteOwner, HeldBuffer, 64)
		if !(Reply is Map) || !(Reply.Get("status", "") is Integer)
			throw Error("Held terminal recipe query returned a malformed ACK.")
		if Reply["status"] != 0
			throw Error("Held terminal recipe query refused with status " . Reply["status"] . ".")
		if !(Reply.Get("count", "") is Integer) || Reply["count"] < 0 || Reply["count"] > 64
			throw Error("Held terminal recipe query returned an invalid count.")
		Keep := Map()
		for RecipeId in Candidate["recipes"]
			Keep[RecipeId] := true
		Held := Map()
		Loop Reply["count"] {
			RecipeId := NumGet(HeldBuffer, (A_Index - 1) * 8, "UInt64")
			if RecipeId <= 0 || Held.Has(RecipeId)
					|| !_LLM_NavEventOwnerTerminalRouteRecipes.Has(RecipeId)
				throw Error("Held terminal recipe query returned an unknown or duplicate identity.")
			Held[RecipeId] := true
			Keep[RecipeId] := true
		}
		; Compute both retirement sets before mutating either ownership map.
		KeepModels := Map()
		if Source.Get("model", 0) is Map
			KeepModels[ObjPtr(Source["model"])] := true
		RetireRecipes := []
		for RecipeId, Admission in _LLM_NavEventOwnerTerminalRouteRecipes {
			if !Keep.Has(RecipeId) {
				RetireRecipes.Push(RecipeId)
				continue
			}
			Recipe := Admission.Get("recipe", 0)
			if Recipe is Map && Recipe.Get("model", 0) is Map
				KeepModels[ObjPtr(Recipe["model"])] := true
		}
		RetireModels := []
		for Identity in _LLM_NavEventOwnerTerminalRouteModels {
			if !KeepModels.Has(Identity)
				RetireModels.Push(Identity)
		}
		for RecipeId in RetireRecipes
			_LLM_NavEventOwnerTerminalRouteRecipes.Delete(RecipeId)
		for Identity in RetireModels
			_LLM_NavEventOwnerTerminalRouteModels.Delete(Identity)
		return true
	} catch Error as Err {
		_LLM_NavEventOwnerReport("Terminal route recipe retirement deferred: " . Err.Message)
		return false
	}
}

/** Returns diagnostic coverage, never permission for partial transformed output. */
LLM_NavEventOwner_TerminalRouteCoverage() {
	global _LLM_NavEventOwnerTerminalRouteCoverage
	Coverage := _LLM_NavEventOwnerTerminalRouteCoverage.Clone()
	Coverage["unconverted"] := Coverage["unconverted"].Clone()
	return Coverage
}

_LLM_NavEventOwnerTerminalRouteSource() {
	global KLE_Model, KLE_Id, KLE_KeyCodes, KLE_State
	Caps := GetKeyState("CapsLock", "T") ? 1 : 0
	if !IsSet(KLE_Model) || !(KLE_Model is Map)
		return Map("active", false, "caps", Caps)
	return Map("active", KeylayoutEmulation_LayerIsActive("ergopti_base") ? 1 : 0,
		"caps", Caps, "model", KLE_Model, "layout_name", KLE_Id,
		"keys", KLE_KeyCodes.Clone(), "composition_state", KLE_State,
		"capture", KeylayoutEmulation_CaptureReplayRoute,
		"eligible", _KLE_BaseCriterion)
}

_LLM_NavEventOwnerTerminalRouteNextRecipeId() {
	global _LLM_NavEventOwnerTerminalRouteNextRecipe
	_LLM_NavEventOwnerTerminalRouteNextRecipe += 1
	if _LLM_NavEventOwnerTerminalRouteNextRecipe <= 0
		throw Error("Terminal route recipe identity overflowed.")
	return _LLM_NavEventOwnerTerminalRouteNextRecipe
}

_LLM_NavEventOwnerTerminalRouteLayoutId(Model) {
	global _LLM_NavEventOwnerTerminalRouteNextLayout
	global _LLM_NavEventOwnerTerminalRouteModels
	Identity := ObjPtr(Model)
	if _LLM_NavEventOwnerTerminalRouteModels.Has(Identity)
		return _LLM_NavEventOwnerTerminalRouteModels[Identity]["id"]
	_LLM_NavEventOwnerTerminalRouteNextLayout += 1
	if _LLM_NavEventOwnerTerminalRouteNextLayout <= 1
		throw Error("Terminal route layout identity overflowed.")
	Id := _LLM_NavEventOwnerTerminalRouteNextLayout
	; Retaining the model also prevents an object pointer from being reused for
	; another layout while old native snapshots still name its recipes.
	_LLM_NavEventOwnerTerminalRouteModels[Identity] := Map("model", Model, "id", Id)
	return Id
}

_LLM_NavEventOwnerTerminalRouteDescriptor(RecipeId, RouteId, Axis, Code,
		Kind, Modifiers := 0, EffectiveLR := 0, TargetVk := 0, TargetScan := 0) {
	return Map("recipe_id", RecipeId, "route_id", RouteId,
		"required_prefixes", 0, "prefix_bit", 0,
		"required_dead_key_id", 0, "next_dead_key_id", 0,
		"code", Code, "target_vk", TargetVk, "target_scan", TargetScan,
		"axis", Axis, "kind", Kind, "required_modifiers", Modifiers,
		"effective_modifiers_lr", EffectiveLR)
}

_LLM_NavEventOwnerTerminalRouteBuild(Source, Generation) {
	global KEYLAYOUT_NEUTRAL_STATE
	if !(Source is Map) || !Source.Has("active") || !Source.Has("caps")
			|| !(Source["active"] is Integer) || Source["active"] < 0 || Source["active"] > 1
			|| !(Source["caps"] is Integer) || Source["caps"] < 0 || Source["caps"] > 1
			|| !(Generation is Integer) || Generation <= 0
		throw ValueError("Terminal route source ownership is invalid.")
	LayoutId := Source["active"] && Source.Has("model") && Source["model"] is Map
		? _LLM_NavEventOwnerTerminalRouteLayoutId(Source["model"]) : 1
	Routes := []
	Recipes := Map()
	Unconverted := ["CapsLock", "AltGr", "dead-key sequences", "tap-hold transforms",
		"shortcut chords", "prefix layers", "direct-digit overrides", "pre-registration holds"]
	NaturalScans := Map()
	for Modifier in [[0xA2, 0x01, 0x01D], [0xA3, 0x02, 0x11D],
			[0xA4, 0x04, 0x038], [0xA5, 0x08, 0x138], [0xA0, 0x10, 0x02A],
			[0xA1, 0x20, 0x036], [0x5B, 0x40, 0x15B], [0x5C, 0x80, 0x15C]] {
		NaturalScans[Modifier[3]] := true
		for Axis in [2, 1] {
			Id := _LLM_NavEventOwnerTerminalRouteNextRecipeId()
			Route := _LLM_NavEventOwnerTerminalRouteDescriptor(
				Id, Routes.Length + 1, Axis, Axis == 2 ? Modifier[3] : Modifier[1],
				4, 0, Modifier[2], Axis == 1 ? Modifier[1] : 0, Axis == 2 ? Modifier[3] : 0)
			Routes.Push(Route)
			Recipes[Id] := Map("recipe", 0, "route", Route.Clone(),
				"generation", Generation, "layout_id", LayoutId)
		}
	}
	if !Source["active"] || Source["caps"] {
		Unconverted.Push(Source["caps"] ? "CapsLock active at registration" : "KLE base inactive")
		return Map("layout_id", LayoutId, "routes", Routes,
			"recipes", Recipes, "unconverted", Unconverted)
	}
	for Name in ["model", "layout_name", "keys", "composition_state", "capture", "eligible"]
		if !Source.Has(Name)
			throw ValueError("The authoritative KLE source is incomplete.")
	if !(Source["model"] is Map) || !(Source["keys"] is Map)
			|| !(Source["layout_name"] is String) || Source["layout_name"] == ""
			|| !(Source["composition_state"] is String)
			|| !HasMethod(Source["capture"], "Call") || !HasMethod(Source["eligible"], "Call")
		throw ValueError("The authoritative KLE source is malformed.")
	if Source["composition_state"] != KEYLAYOUT_NEUTRAL_STATE {
		Unconverted.Push("KLE composition active at registration")
		return Map("layout_id", LayoutId, "routes", Routes,
			"recipes", Recipes, "unconverted", Unconverted)
	}
	Names := ""
	for Sc, _ in Source["keys"] {
		if !(Sc is String) || !RegExMatch(Sc, "i)^SC[0-9A-F]{3}$")
			throw ValueError("The authoritative KLE scan identity is malformed.")
		Names .= Sc . "`n"
	}
	Loop Parse, Sort(RTrim(Names, "`n")), "`n" {
		Sc := A_LoopField
		if Sc == ""
			continue
		if NaturalScans.Has(Integer("0x" . SubStr(Sc, 3))) {
			Unconverted.Push(Sc . ":natural modifier identity")
			continue
		}
		for Shift in [0, 1] {
			if !Source["eligible"].Call(Sc, Shift) {
				Unconverted.Push(Sc . (Shift ? ":Shift" : ":base") . ":another owner")
				continue
			}
			Recipe := Source["capture"].Call(Sc, Shift, false, false)
			if !(Recipe is Map) || !Recipe.Has("model") || !(Recipe["model"] is Map)
					|| ObjPtr(Recipe["model"]) != ObjPtr(Source["model"])
					|| Recipe.Get("layout_id", 0) != Source["layout_name"]
					|| Recipe.Get("scan", 0) != Sc
				throw ValueError("KLE registration changed its model during capture.")
			Resolved := Keylayout_Resolve(Recipe["model"], Recipe["index"], Recipe["keycode"])
			if Resolved["Kind"] != "text" {
				Unconverted.Push(Sc . (Shift ? ":Shift" : ":base") . ":" . Resolved["Kind"])
				continue
			}
			if Routes.Length >= 128 {
				Unconverted.Push(Sc . (Shift ? ":Shift" : ":base") . ":registration capacity")
				continue
			}
			Id := _LLM_NavEventOwnerTerminalRouteNextRecipeId()
			Kind := RegExMatch(Resolved["Text"], "^[0-9]$") ? 2 : 1
			Route := _LLM_NavEventOwnerTerminalRouteDescriptor(
				Id, Routes.Length + 1, 2, Integer("0x" . SubStr(Sc, 3)), Kind, Shift ? 4 : 0)
			Routes.Push(Route)
			Recipes[Id] := Map("recipe", Recipe.Clone(), "route", Route.Clone(),
				"generation", Generation, "layout_id", LayoutId)
		}
	}
	return Map("layout_id", LayoutId, "routes", Routes,
		"recipes", Recipes, "unconverted", Unconverted)
}

_LLM_NavEventOwnerTerminalRouteValidate(Route) {
	if !(Route is Map)
		throw ValueError("A typed terminal route is required.")
	Limits := Map("recipe_id", 0x7FFFFFFFFFFFFFFF, "route_id", 0xFFFFFFFF,
		"required_prefixes", 0xFFFFFFFF, "prefix_bit", 0xFFFFFFFF,
		"required_dead_key_id", 0xFFFFFFFF, "next_dead_key_id", 0xFFFFFFFF,
		"code", 0x1FF, "target_vk", 0xFF, "target_scan", 0x1FF,
		"axis", 2, "kind", 5, "required_modifiers", 15, "effective_modifiers_lr", 255)
	for Name, Maximum in Limits
		if !Route.Has(Name) || !(Route[Name] is Integer)
				|| Route[Name] < 0 || Route[Name] > Maximum
			throw ValueError("The terminal route contains an invalid typed field.")
	if Route["recipe_id"] == 0 || Route["route_id"] == 0 || Route["code"] == 0
			|| Route["axis"] == 0 || Route["kind"] == 0
			|| (Route["axis"] == 1 && Route["code"] > 255)
			|| (Route["target_vk"] != 0 && Route["target_scan"] != 0)
		throw ValueError("The terminal route key identity is invalid.")
	Transform := Route["kind"] == 4 || Route["kind"] == 5
	if Transform {
		if Route["required_modifiers"] || Route["required_prefixes"]
				|| Route["required_dead_key_id"] || Route["next_dead_key_id"]
			throw ValueError("A held terminal transform cannot depend on a chord.")
		if Route["kind"] == 4 {
			if !Route["effective_modifiers_lr"] || Route["prefix_bit"]
				throw ValueError("The terminal modifier transform is invalid.")
		} else if Route["effective_modifiers_lr"] || !Route["prefix_bit"]
				|| (Route["prefix_bit"] & (Route["prefix_bit"] - 1))
			throw ValueError("The terminal prefix transform is invalid.")
	} else if Route["effective_modifiers_lr"] || Route["prefix_bit"]
			|| (Route["kind"] == 3 && !Route["required_dead_key_id"] && !Route["next_dead_key_id"])
		throw ValueError("The terminal character transition is invalid.")
	return true
}

_LLM_NavEventOwnerTerminalRouteMarshal(Routes) {
	if !(Routes is Array) || Routes.Length > 128
		throw ValueError("The terminal route registry exceeds its supported subset.")
	Loop Routes.Length
		if !Routes.Has(A_Index)
			throw ValueError("The terminal route registry contains a missing entry.")
	Bindings := Buffer(Routes.Length * 40, 0)
	Ids := Map()
	Families := Map()
	Selectors := Map()
	for Index, Route in Routes {
		if !Routes.Has(Index)
			throw ValueError("The terminal route registry contains a missing entry.")
		_LLM_NavEventOwnerTerminalRouteValidate(Route)
		if Ids.Has(Route["route_id"])
			throw ValueError("The terminal route registry repeats an identity.")
		Ids[Route["route_id"]] := true
		Family := Route["axis"] . "|" . Route["code"]
		Transform := Route["kind"] == 4 || Route["kind"] == 5
		if Families.Has(Family) && (Families[Family] || Transform)
			throw ValueError("The terminal route registry overlaps a held transform.")
		Families[Family] := Transform
		Selector := Family . "|" . Route["required_modifiers"] . "|"
			. Route["required_prefixes"] . "|" . Route["required_dead_key_id"]
		if Selectors.Has(Selector)
			throw ValueError("The terminal route registry repeats an event selector.")
		Selectors[Selector] := true
		Offset := (Index - 1) * 40
		NumPut("UInt64", Route["recipe_id"], "UInt", Route["route_id"],
			"UInt", Route["required_prefixes"], "UInt", Route["prefix_bit"],
			"UInt", Route["required_dead_key_id"], "UInt", Route["next_dead_key_id"],
			"UShort", Route["code"], "UShort", Route["target_vk"],
			"UShort", Route["target_scan"], "UChar", Route["axis"],
			"UChar", Route["kind"], "UChar", Route["required_modifiers"],
			"UChar", Route["effective_modifiers_lr"], Bindings, Offset)
	}
	return Bindings
}

_LLM_NavEventOwnerTerminalRouteRead(BufferSource, Offset) {
	Route := Map("recipe_id", NumGet(BufferSource, Offset, "UInt64"),
		"route_id", NumGet(BufferSource, Offset + 8, "UInt"),
		"required_prefixes", NumGet(BufferSource, Offset + 12, "UInt"),
		"prefix_bit", NumGet(BufferSource, Offset + 16, "UInt"),
		"required_dead_key_id", NumGet(BufferSource, Offset + 20, "UInt"),
		"next_dead_key_id", NumGet(BufferSource, Offset + 24, "UInt"),
		"code", NumGet(BufferSource, Offset + 28, "UShort"),
		"target_vk", NumGet(BufferSource, Offset + 30, "UShort"),
		"target_scan", NumGet(BufferSource, Offset + 32, "UShort"),
		"axis", NumGet(BufferSource, Offset + 34, "UChar"),
		"kind", NumGet(BufferSource, Offset + 35, "UChar"),
		"required_modifiers", NumGet(BufferSource, Offset + 36, "UChar"),
		"effective_modifiers_lr", NumGet(BufferSource, Offset + 37, "UChar"))
	_LLM_NavEventOwnerTerminalRouteValidate(Route)
	return Route
}

_LLM_NavEventOwnerTerminalRouteComposition(BufferSource, Offset) {
	return Map("generation", NumGet(BufferSource, Offset, "UInt64"),
		"layout_id", NumGet(BufferSource, Offset + 8, "UInt64"),
		"dead_key_id", NumGet(BufferSource, Offset + 16, "UInt"))
}

/** Decodes the exact native FIFO metadata ABI without authorizing output. */
_LLM_NavEventOwnerTerminalRouteDecode(Receipt, ExpectedToken := 0) {
	if !(Receipt is Buffer) || Receipt.Size != 184
		throw ValueError("The terminal route receipt ABI size is invalid.")
	Token := NumGet(Receipt, 0, "UInt64")
	Sequence := NumGet(Receipt, 8, "UInt64")
	Status := NumGet(Receipt, 64, "Int")
	if Token <= 0 || Sequence <= 0 || (ExpectedToken != 0 && Token != ExpectedToken)
			|| Status < -10 || Status > 2
		throw ValueError("The terminal route receipt identity is invalid.")
	Event := Map("timestamp", NumGet(Receipt, 120, "UInt64"),
		"source_id", NumGet(Receipt, 128, "UInt64"),
		"vk", NumGet(Receipt, 136, "UShort"), "scan", NumGet(Receipt, 138, "UShort"),
		"origin", NumGet(Receipt, 140, "UChar"), "key_up", NumGet(Receipt, 141, "UChar"),
		"repeat", NumGet(Receipt, 142, "UChar"))
	if Event["timestamp"] < 0 || Event["source_id"] < 0
			|| Event["vk"] > 255 || Event["scan"] > 511 || (!Event["vk"] && !Event["scan"])
			|| Event["origin"] < 1 || Event["origin"] > 4
			|| Event["key_up"] > 1 || Event["repeat"] > 1
			|| (Event["key_up"] && Event["repeat"])
		throw ValueError("The terminal route event provenance is invalid.")
	Snapshot := Map("token", Token, "sequence", Sequence, "status", Status,
		"owner", NumGet(Receipt, 16, "UInt64"),
		"observed_generation", NumGet(Receipt, 24, "UInt64"),
		"observed_layout_id", NumGet(Receipt, 32, "UInt64"),
		"route_generation", NumGet(Receipt, 40, "UInt64"),
		"route_layout_id", NumGet(Receipt, 48, "UInt64"),
		"prefixes_before", NumGet(Receipt, 56, "UInt"),
		"prefixes_after", NumGet(Receipt, 60, "UInt"),
		"modifiers_lr_before", NumGet(Receipt, 68, "UChar"),
		"modifiers_lr_after", NumGet(Receipt, 69, "UChar"),
		"composition_before", _LLM_NavEventOwnerTerminalRouteComposition(Receipt, 72),
		"composition_after", _LLM_NavEventOwnerTerminalRouteComposition(Receipt, 96),
		"event", Event, "metadata_only", true,
		"cohort_complete", false, "transformed_output_enabled", false)
	for Name in ["owner", "observed_generation", "observed_layout_id",
			"route_generation", "route_layout_id"]
		if Snapshot[Name] < 0
			throw ValueError("The terminal route registration identity overflowed.")
	for Name in ["composition_before", "composition_after"] {
		Composition := Snapshot[Name]
		if Composition["generation"] < 0 || Composition["layout_id"] < 0
				|| (Composition["dead_key_id"] == 0
					&& (Composition["generation"] != 0 || Composition["layout_id"] != 0))
				|| (Composition["dead_key_id"] != 0
					&& (Composition["generation"] <= 0 || Composition["layout_id"] <= 0))
			throw ValueError("The terminal route composition ownership is invalid.")
	}
	RecipeId := NumGet(Receipt, 144, "UInt64")
	if Status == 0 || RecipeId != 0 {
		if Snapshot["owner"] <= 0 || Snapshot["route_generation"] <= 0
				|| Snapshot["route_layout_id"] <= 0
				|| Snapshot["observed_generation"] < Snapshot["route_generation"]
				|| (Status == 0 && Event["origin"] > 2) || Status == 1
			throw ValueError("The terminal route admission ownership is invalid.")
		Snapshot["route"] := _LLM_NavEventOwnerTerminalRouteRead(Receipt, 144)
	} else
		Snapshot["route"] := 0
	return Snapshot
}

/** Peeks one zero-based FIFO metadata entry without consuming native ACK debt. */
LLM_NavEventOwner_PeekTerminalRoute(Token, Index, Port := 0) {
	if !(Token is Integer) || Token <= 0 || !(Index is Integer) || Index < 0
		throw ValueError("A terminal route token and zero-based index are required.")
	Receipt := Buffer(184, 0)
	Fn := _LLM_NavEventOwnerPortFn("peek_terminal_route", Port)
	Status := HasMethod(Fn, "Call") ? Fn.Call(Token, Index, Receipt)
		: _LLM_NavEventOwnerNativePeekTerminalRoute(Token, Index, Receipt)
	if !(Status is Integer)
		throw Error("Terminal route peek returned a malformed ACK.")
	if Status == 4 || Status == 8
		return 0
	_LLM_NavEventOwnerNativeRequireOk(Status, "Terminal route metadata peek")
	return _LLM_NavEventOwnerTerminalRouteDecode(Receipt, Token)
}

/**
 * Resolves an admitted metadata recipe through its retained KLE model only.
 * @param {Map} Snapshot - Decoded FIFO receipt while its queue or hold still owns
 *   the recipe. Retired diagnostic copies intentionally lose stepping permission.
 * @param {String} State - Explicit neutral composition state of this subset.
 * @returns {Map} Canonical diagnostic Next/Output, never a delivery permission.
 */
LLM_NavEventOwner_StepTerminalRoute(Snapshot, State) {
	global _LLM_NavEventOwnerTerminalRouteOwner
	global _LLM_NavEventOwnerTerminalRouteRecipes, KEYLAYOUT_NEUTRAL_STATE
	if !(Snapshot is Map) || !(State is String) || State != KEYLAYOUT_NEUTRAL_STATE
			|| Snapshot.Get("status", -1) != 0
			|| Snapshot.Get("owner", 0) != _LLM_NavEventOwnerTerminalRouteOwner
			|| !(Snapshot.Get("route", 0) is Map) || !(Snapshot.Get("event", 0) is Map)
			|| Snapshot["event"].Get("key_up", 1) != 0
			|| !(Snapshot.Get("composition_before", 0) is Map)
			|| Snapshot["composition_before"].Get("dead_key_id", -1) != 0
		throw ValueError("The terminal recipe is outside the admitted neutral subset.")
	for Name in ["owner", "route_generation", "route_layout_id", "status"]
		if !Snapshot.Has(Name) || !(Snapshot[Name] is Integer)
			throw ValueError("The terminal recipe receipt has an invalid typed identity.")
	Event := Snapshot["event"]
	for Name in ["origin", "key_up", "repeat", "vk", "scan"]
		if !Event.Has(Name) || !(Event[Name] is Integer)
			throw ValueError("The terminal recipe event is malformed.")
	if Event["origin"] < 1 || Event["origin"] > 2 || Event["repeat"] < 0 || Event["repeat"] > 1
		throw ValueError("The terminal recipe event provenance is unsupported.")
	Route := Snapshot["route"]
	_LLM_NavEventOwnerTerminalRouteValidate(Route)
	if (Route["axis"] == 2 && Event["scan"] != Route["code"])
			|| (Route["axis"] == 1 && Event["vk"] != Route["code"])
		throw ValueError("The terminal recipe no longer describes its captured key.")
	Id := Route["recipe_id"]
	if !_LLM_NavEventOwnerTerminalRouteRecipes.Has(Id)
		throw ValueError("The terminal recipe identity is not retained.")
	Admission := _LLM_NavEventOwnerTerminalRouteRecipes[Id]
	if Admission["generation"] != Snapshot.Get("route_generation", 0)
			|| Admission["layout_id"] != Snapshot.Get("route_layout_id", 0)
			|| !(Admission["recipe"] is Map)
			|| (Route["kind"] != 1 && Route["kind"] != 2)
		throw ValueError("The terminal recipe registration ownership is invalid.")
	for Name, Value in Admission["route"]
		if !Route.Has(Name) || Route[Name] != Value
			throw ValueError("The terminal recipe differs from its admitted descriptor.")
	Step := KeylayoutEmulation_StepReplayRoute(Admission["recipe"], State)
	if Step["Next"] != KEYLAYOUT_NEUTRAL_STATE
		throw ValueError("The terminal recipe unexpectedly entered composition.")
	return Map("Next", Step["Next"], "Output", Step["Output"],
		"metadata_only", true, "cohort_complete", false, "transformed_output_enabled", false)
}

_LLM_NavEventOwnerNativeRegisterTerminalRoutes(Owner, Generation, LayoutId, Bindings, Count) {
	if !(Owner is Integer) || Owner <= 0 || !(Generation is Integer) || Generation <= 0
			|| !(LayoutId is Integer) || LayoutId <= 0 || !(Count is Integer) || Count < 0
			|| Count > 128 || !(Bindings is Buffer) || Bindings.Size != Count * 40
		throw ValueError("The terminal route native registration ABI is invalid.")
	return DllCall(_LLM_NavEventOwnerNativeExport("ErgoptiNav_RegisterTerminalRoutes"),
		"UInt64", Owner, "UInt64", Generation, "UInt64", LayoutId,
		"Ptr", Bindings, "UInt", Count, "Int")
}

_LLM_NavEventOwnerNativeListTerminalHeldRecipes(Owner, Ids, Capacity) {
	if !(Owner is Integer) || Owner <= 0 || !(Capacity is Integer)
			|| Capacity < 0 || Capacity > 64 || !(Ids is Buffer) || Ids.Size != Capacity * 8
		throw ValueError("The held terminal recipe output buffer is invalid.")
	Count := 0
	Status := DllCall(_LLM_NavEventOwnerNativeExport("ErgoptiNav_ListTerminalHeldRecipes"),
		"UInt64", Owner, "Ptr", Ids.Ptr, "UInt", Capacity, "UInt*", &Count, "Int")
	return Map("status", Status, "count", Count)
}

_LLM_NavEventOwnerNativePeekTerminalRoute(Token, Index, Receipt) {
	return DllCall(_LLM_NavEventOwnerNativeExport("ErgoptiNav_PeekTerminalRoute"),
		"UInt64", Token, "UInt", Index, "Ptr", Receipt, "Int")
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
	if !LLM_NavEventOwner_RefreshTerminalRoutes()
		throw Error("Terminal route metadata registration was not admitted at startup.")
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
	if !LLM_NavEventOwner_RefreshTerminalRoutes()
		return 0
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

; The native routes of a navigation plan, in plan order. A validation digit is
; its physical identity, consumed; the Up and Down cycle routes are parked
; (LLM_NAV_EVENT_OWNER_PARKED_CYCLE_ROUTES), since the chord's own hotkeys
; cycle. Every entry must still carry a valid physical identity.
; @param {Array} Plan - The twelve entries of a navigation plan.
; @returns {Array|Integer} One Map per route, or 0 for a malformed plan.
_LLM_NavEventOwnerNativeBindings(Plan) {
	global LLM_NAV_EVENT_OWNER_INPUT_LEVEL
	global LLM_NAV_EVENT_OWNER_PARKED_CYCLE_ROUTES
	if !(Plan is Array) || Plan.Length != 12
		return 0
	Bindings := []
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
		if A_Index <= 2 {
			Parked := LLM_NAV_EVENT_OWNER_PARKED_CYCLE_ROUTES[A_Index]
			Axis := Parked["axis"]
			Code := Parked["code"]
			Modifiers := Parked["modifiers"]
		} else {
			Modifiers := 0
			Loop Parse, Match[2] {
				Modifiers |= A_LoopField == "^" ? 0x01
					: A_LoopField == "!" ? 0x02
					: A_LoopField == "+" ? 0x04
					: A_LoopField == "#" ? 0x08 : 0
			}
			Axis := StrLower(Match[3]) == "vk" ? 1 : 2
			Code := Integer("0x" . Match[4])
		}
		Target := A_Index <= 2 ? 0 : Entry.Get("jump_idx", 0)
		if !(Target is Integer) || Target < 0 || Target > 10
			return 0
		Bindings.Push(Map("axis", Axis, "action", A_Index <= 2 ? 1 : 2,
			"modifiers", Modifiers, "pass_through", A_Index <= 2 ? 1 : 0,
			"code", Code, "delta", A_Index == 1 ? -1 : A_Index == 2 ? 1 : 0,
			"target", Target, "input_level", LLM_NAV_EVENT_OWNER_INPUT_LEVEL))
	}
	return Bindings
}

_LLM_NavEventOwnerNativePreparePlan(Plan) {
	Routes := _LLM_NavEventOwnerNativeBindings(Plan)
	if !(Routes is Array)
		return 0
	Bindings := Buffer(12 * 12, 0)
	for Index, Route in Routes {
		NumPut("UChar", Route["axis"], "UChar", Route["action"],
			"UChar", Route["modifiers"], "UChar", Route["pass_through"],
			"UShort", Route["code"], "Char", Route["delta"],
			"UChar", Route["target"], "UChar", Route["input_level"],
			Bindings, (Index - 1) * 12)
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
			|| ProfileCount > 9 || (NewToken == 0) != (ProfileCount == 0) {
		; A caller bug, not a native refusal: name it, or the log blames the DLL
		; (llm-profile-disable-count).
		_LLM_NavEventOwnerReport("Profile hotkey owner preparation received "
			. "an invalid argument set (new_token="
			. (NewToken is Integer ? NewToken : Type(NewToken))
			. ", profile_count="
			. (ProfileCount is Integer ? ProfileCount : Type(ProfileCount)) . ").")
		return 0
	}
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
		"ErgoptiEditor_Begin", "ErgoptiEditor_Poll",
		"ErgoptiEditor_Decide", "ErgoptiEditor_Close",
		"ErgoptiNav_Start", "ErgoptiNav_Stop",
		"ErgoptiNav_PreparePlan", "ErgoptiNav_CommitPlan",
		"ErgoptiNav_SetSuspended", "ErgoptiNav_CanStop",
		"ErgoptiNav_BeginTerminalCapture",
		"ErgoptiNav_CommitTerminalCapture",
		"ErgoptiNav_AbortTerminalCapture",
		"ErgoptiNav_GetTerminalCapture",
		"ErgoptiNav_RegisterTerminalRoutes", "ErgoptiNav_PeekTerminalRoute",
		"ErgoptiNav_ListTerminalHeldRecipes", "ErgoptiNav_PreviewTerminalOutput",
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
	Failure := Error(Operation . " failed with status " . Status . Suffix)
	; Catchers can preserve native evidence without logging arbitrary operation text.
	Failure.NativeStatus := Status
	Failure.NativeErrorCode := NativeErrorCode
	throw Failure
}
