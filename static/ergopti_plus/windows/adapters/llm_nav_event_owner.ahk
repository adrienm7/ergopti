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
; An uncertain native registration retains its original candidate and owner.
; No current-registration readback/settlement contract exists yet.
global _LLM_NavEventOwnerTerminalRouteUnknown := 0
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
	try LoggerError("KeyboardArbiter",
		"Keyboard arbiter failure: {1}.", Detail)
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
	static OriginalLoader := _LLM_NavEventOwnerNativeEnsureLoaded
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
				; The routes registered during this start join the published epoch.
				if _LLM_NavEventOwnerNativeEnsureLoaded != OriginalLoader
						|| Object.Prototype.HasOwnProp.Call(OriginalLoader, "Call")
					throw Error("The original start epoch owner was withdrawn.")
				OriginalLoader.Call("publish_start_epoch",
					Map("from", StartEpoch, "to", PublishedEpoch))
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

LLM_NavEventOwner_Stop(PreserveResumeIntent := false, ForceLifecycleReset := false) {
	global _LLM_NavEventOwnerProfileFailures
	global _LLM_NavEventOwnerStarted, _LLM_NavEventOwnerQuarantined
	global _LLM_NavEventOwnerStarting, _LLM_NavEventOwnerStartCancelled
	global _LLM_NavEventOwnerStartRollbackPending, _LLM_NavEventOwnerActiveStartTicket
	global _LLM_NavEventOwnerStopping, _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerTerminalRouteRefreshing, _LLM_NavEventOwnerTerminalRouteUnknown
	global _LLM_NavEventOwnerRuntimeEpoch, _LLM_NavEventOwnerPort
	global _LLM_NavEventOwnerWakeMessage, _LLM_NavEventOwnerWakeFn
	global _LLM_NavEventOwnerServiceFn, _LLM_NavEventOwnerServiceArmed
	global _LLM_NavEventOwnerRecords, _LLM_NavEventOwnerProfileOwners
	global _LLM_NavEventOwnerActiveProfileToken, _LLM_NavEventOwnerProfileEffectActive
	global _LLM_NavEventOwnerShutdownFenced, _LLM_NavEventOwnerClaimedReceipt
	global _LLM_NavEventOwnerPendingRepaints, _LLM_NavEventOwnerRepaintFailures
	global _LLM_NavEventOwnerPreparedPlans, _LLM_NavEventOwnerCommittedPlan
	global _LLM_NavEventOwnerLifecycleResumePlan, _LLM_NavEventOwnerLifecycleResumePort
	global _LLM_NavEventOwnerLifecycleQuiesced, _LLM_NavEventOwnerModule
	global _LLM_NavEventOwnerLastQuarantineStopAttemptTick
	static OriginalLoader := _LLM_NavEventOwnerNativeEnsureLoaded
	static OriginalNativeStop := _LLM_NavEventOwnerNativeStop
	StopScope := 0, PreserveLifecycle := false, AdmissionFailure := ""

	GuardScope() {
		if _LLM_NavEventOwnerNativeEnsureLoaded != OriginalLoader
				|| Object.Prototype.HasOwnProp.Call(OriginalLoader, "Call")
			throw Error("The original native stop constructor was withdrawn.")
		if !OriginalLoader.Call("owns_scope", StopScope)
			throw Error("The native stop scope was not genuinely issued.")
	}

	try {
		PreviousCritical := Critical("On")
		try {
			if _LLM_NavEventOwnerStarting {
				_LLM_NavEventOwnerStartCancelled := true
				return false
			}
			if _LLM_NavEventOwnerStopping || _LLM_NavEventOwnerTerminalRouteRefreshing
				return false
			_LLM_NavEventOwnerStopping := true
			try {
				if _LLM_NavEventOwnerNativeEnsureLoaded != OriginalLoader
						|| Object.Prototype.HasOwnProp.Call(OriginalLoader, "Call")
					throw Error("The original native stop constructor was withdrawn.")
				RetirementFrame := _LLM_NavEventOwnerTerminalRouteUnknown
				StopScope := OriginalLoader.Call("begin_stop", RetirementFrame)
				GuardScope()
				WasPending := _LLM_NavEventOwnerStopPending
				PreserveLifecycle := !ForceLifecycleReset
					&& (PreserveResumeIntent || _LLM_NavEventOwnerLifecycleQuiesced)
				if PreserveLifecycle && !(_LLM_NavEventOwnerLifecycleResumePlan is Array)
						&& _LLM_NavEventOwnerCommittedPlan is Array {
					_LLM_NavEventOwnerLifecycleResumePlan := _LLM_NavEventOwnerCommittedPlan
					_LLM_NavEventOwnerLifecycleResumePort := _LLM_NavEventOwnerPort
				}
				ShouldStop := _LLM_NavEventOwnerStarted || (_LLM_NavEventOwnerPort is Map)
					|| _LLM_NavEventOwnerModule != 0 || StopScope["requires_native"].Call()
			} catch as Err {
				_LLM_NavEventOwnerStopping := false
				AdmissionFailure := _LLM_NavEventOwnerStopExceptionDetail(Err)
			}
		} finally Critical(PreviousCritical)
		if AdmissionFailure != "" {
			_LLM_NavEventOwnerReport(AdmissionFailure)
			return false
		}
		StopResult := 1, StopFailure := ""
		if ShouldStop {
			try {
				; Snapshot and construction already precede this first Port.Get.
				SelectionCritical := Critical("On")
				try {
					GuardScope()
					StopFn := _LLM_NavEventOwnerPortFn("stop")
					GuardScope()
					UseCustomStop := HasMethod(StopFn, "Call")
					if UseCustomStop
						StopScope["custom"].Call()
				} finally Critical(SelectionCritical)
				if UseCustomStop {
					StopResult := StopFn.Call()
				} else {
					DispatchCritical := Critical("On")
					try {
						GuardScope()
						if _LLM_NavEventOwnerNativeStop != OriginalNativeStop
								|| Object.Prototype.HasOwnProp.Call(OriginalNativeStop, "Call")
							throw Error("The original native stop helper was withdrawn.")
						StopResult := OriginalNativeStop.Call(StopScope["native"])
					} finally Critical(DispatchCritical)
				}
			} catch as Err {
				StopResult := 0
				StopFailure := _LLM_NavEventOwnerStopExceptionDetail(Err)
			}
		}
		try {
			Stopped := ((StopResult is Integer) && StopResult == 1)
				|| (StopResult is Map && StopResult.Get("stopped", false) == true)
			StopPending := StopResult is Map && StopResult.Get("pending", false) == true
				&& StopResult.Get("stopped", false) != true
		} catch as Err {
			PreviousCritical := Critical("On")
			try _LLM_NavEventOwnerStopping := false
			finally Critical(PreviousCritical)
			_LLM_NavEventOwnerReport(_LLM_NavEventOwnerStopExceptionDetail(Err))
			return false
		}
		if StopPending {
			PreviousCritical := Critical("On")
			try {
				_LLM_NavEventOwnerStarted := false
				_LLM_NavEventOwnerQuarantined := true
				_LLM_NavEventOwnerStopPending := true
				_LLM_NavEventOwnerStopping := false
			} finally Critical(PreviousCritical)
			if !WasPending
				try LoggerDebug("KeyboardArbiter", "stage=native_stop outcome=pending.")
			return false
		}
		if !Stopped {
			PreviousCritical := Critical("On")
			try _LLM_NavEventOwnerStopping := false
			finally Critical(PreviousCritical)
			if StopFailure == ""
				StopFailure := "stage=native_stop outcome=refused result_type=" . Type(StopResult)
					. " result_code=" . (StopResult is Integer ? StopResult : "unavailable")
			_LLM_NavEventOwnerReport(StopFailure)
			return false
		}
		PreviousCritical := Critical("On")
		try {
			try {
				GuardScope()
				if !StopScope["accept"].Call()
					throw Error("Genuine retained registration requires an actual native stop receipt.")
				GuardScope()
				if !StopScope["settle"].Call()
					throw Error("The retained terminal source could not be retired.")
			} catch as Err {
				_LLM_NavEventOwnerReport(_LLM_NavEventOwnerStopExceptionDetail(Err))
				return false
			}
			_LLM_NavEventOwnerSetServiceTimer(false)
			if IsObject(_LLM_NavEventOwnerWakeFn)
				try OnMessage(_LLM_NavEventOwnerWakeMessage, _LLM_NavEventOwnerWakeFn, 0)
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
		if ShouldStop && Unloaded {
			try LoggerDebug("KeyboardArbiter", "stage=native_stop outcome=stopped.")
			_LLM_NavEventOwnerLogHookOrder()
		}
		return Unloaded
	} finally {
		if StopScope is Map
			; Original issuer cleanup only; no public own.Call or mutable scope method.
			Func.Prototype.Call.Call(OriginalLoader, "close_scope", StopScope)
	}
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
	global _LLM_NavEventOwnerStopping, _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerTerminalRouteGeneration
	global _LLM_NavEventOwnerTerminalRouteRecipes, _LLM_NavEventOwnerTerminalRouteCoverage
	global _LLM_NavEventOwnerTerminalRouteUnknown
	static OriginalLoader := _LLM_NavEventOwnerNativeEnsureLoaded
	static OriginalNativeRegister := _LLM_NavEventOwnerNativeRegisterTerminalRoutes
	static OriginalUnknown := _LLM_NavEventOwnerTerminalRegistrationUnknown

	GuardScope() {
		if _LLM_NavEventOwnerNativeEnsureLoaded != OriginalLoader
				|| Object.Prototype.HasOwnProp.Call(OriginalLoader, "Call")
			throw Error("The original registration constructor was withdrawn.")
		if !OriginalLoader.Call("owns_scope", NativeScope)
			throw Error("The registration scope was not genuinely issued.")
		NativeScope["guard"].Call()
	}

	RetainUnknown() {
		; Retention is mandatory cleanup, not native admission. Skip foreign own.Call.
		Func.Prototype.Call.Call(OriginalLoader, "retain_frame", Frame)
		Func.Prototype.Call.Call(OriginalUnknown, Frame)
	}

	CheckCurrent(CheckModels := true, CheckIds := true) {
		try {
			GuardScope()
			Current := _LLM_NavEventOwnerTerminalRegistrationCurrent(Frame, CheckModels, CheckIds)
		} catch as Err {
			RetainUnknown()
			throw Err
		}
		if !Current
			RetainUnknown()
		return Current
	}

	PreviousCritical := Critical("On")
	try {
		if _LLM_NavEventOwnerTerminalRouteRefreshing || _LLM_NavEventOwnerStopping || _LLM_NavEventOwnerStopPending
			return false
		if IsObject(_LLM_NavEventOwnerTerminalRouteUnknown)
			throw Error("Uncertain terminal registration retains its original native owner.")
		_LLM_NavEventOwnerTerminalRouteRefreshing := true
		try {
			if _LLM_NavEventOwnerNativeEnsureLoaded != OriginalLoader
					|| Object.Prototype.HasOwnProp.Call(OriginalLoader, "Call")
				throw Error("The original registration constructor was withdrawn.")
			NativeScope := OriginalLoader.Call("begin_frame")
			GuardScope()
			Frame := NativeScope["frame"]
			try {
				GuardScope()
				NativeScope["capture_digit_source"].Call()
				GuardScope()
				_LLM_NavEventOwnerTerminalRegistrationRequire(Frame)
				SourceFn := _LLM_NavEventOwnerPortFn("terminal_route_source", Port)
				GuardScope()
				Source := HasMethod(SourceFn, "Call") ? SourceFn.Call() : _LLM_NavEventOwnerTerminalRouteSource()
				GuardScope()
				if !(Source is Map) || ObjGetBase(Source) != Map.Prototype
					throw ValueError("The terminal source must be an original plain Map.")
				for Name in ObjOwnProps(Source)
					throw ValueError("The terminal source cannot invoke a map observer.")
				GuardScope()
				_LLM_NavEventOwnerTerminalRegistrationRequire(Frame)
			} catch as Err {
				CheckCurrent()
				throw Err
			}
			_LLM_NavEventOwnerTerminalRouteGeneration += 1
			if _LLM_NavEventOwnerTerminalRouteGeneration <= 0
				throw Error("Terminal route registration generation overflowed.")
			Generation := _LLM_NavEventOwnerTerminalRouteGeneration
			Frame["generation"] := Generation
			try {
				GuardScope()
				Candidate := _LLM_NavEventOwnerTerminalRouteBuild(Source, Generation, Frame, NativeScope["guard"])
			} catch as Err {
				CheckCurrent(false, false)
				throw Err
			}
			Frame["candidate"] := Candidate
			NativeScope["seal_candidate"].Call()
			GuardScope()
			_LLM_NavEventOwnerTerminalRegistrationAdvance(Frame, Candidate, Source)
			if !CheckCurrent(false)
				throw ValueError("The terminal source changed during recipe capture.")
			GuardScope()
			_LLM_NavEventOwnerTerminalRegistrationRetain(Frame)
			GuardScope()
			Bindings := _LLM_NavEventOwnerTerminalRouteMarshal(Candidate["routes"])
			GuardScope()
			Witness := _LLM_NavEventOwnerTerminalRouteMarshal(Candidate["routes"])
			Frame["bindings"] := Witness
			try {
				GuardScope()
				RegisterFn := _LLM_NavEventOwnerPortFn("register_terminal_routes", Port)
				GuardScope()
				_LLM_NavEventOwnerTerminalRegistrationRequire(Frame)
			} catch as Err {
				CheckCurrent()
				throw Err
			}
			Frame["native_attempted"] := true
			try {
				GuardScope()
				if HasMethod(RegisterFn, "Call") {
					NativeScope["custom"].Call()
					Status := RegisterFn.Call(Frame["owner"], Generation, Candidate["layout_id"], Bindings, Candidate["routes"].Length)
				} else {
					GuardScope()
					if _LLM_NavEventOwnerNativeRegisterTerminalRoutes != OriginalNativeRegister
							|| Object.Prototype.HasOwnProp.Call(OriginalNativeRegister, "Call")
						throw Error("The original native registration helper was withdrawn.")
					Status := OriginalNativeRegister.Call(Frame["owner"], Generation,
						Candidate["layout_id"], Bindings, Candidate["routes"].Length, NativeScope["native"])
				}
			} catch as Err {
				RetainUnknown()
				throw Err
			}
			try {
				GuardScope()
				_LLM_NavEventOwnerTerminalRegistrationRequire(Frame)
				GuardScope()
				if !_LLM_NavEventOwnerTerminalRegistrationBytesCurrent(Bindings, Witness)
					throw ValueError("The registration callback changed the native descriptor bytes.")
			} catch as Err {
				RetainUnknown()
				throw Err
			}
			GuardScope()
			if !(Status is Integer) || !_LLM_NavEventOwnerTerminalRegistrationStatusKnown(Status) {
				RetainUnknown()
				throw Error("Terminal route registration returned an unknown ACK.")
			}
			if Status == -11
				return false
			GuardScope()
			_LLM_NavEventOwnerNativeRequireOk(Status, "Terminal route registration")
			for RecipeId, Admission in Candidate["recipes"]
				Frame["recipes"][RecipeId] := Admission
			_LLM_NavEventOwnerTerminalRouteCoverage := Map(
				"generation", Generation, "layout_id", Candidate["layout_id"], "registered", Candidate["routes"].Length,
				"cohort_complete", false, "transformed_output_enabled", false, "unconverted", Candidate["unconverted"])
			Frame["coverage"] := _LLM_NavEventOwnerTerminalRouteCoverage
			GuardScope()
			_LLM_NavEventOwnerTerminalRegistrationRetain(Frame)
			GuardScope()
			_LLM_NavEventOwnerTerminalRoutePrune(Candidate, Source, Port, Frame)
			if !CheckCurrent()
				throw ValueError("The original registration owner changed during retirement.")
			GuardScope()
			NativeScope["complete"].Call()
			return true
		} finally {
			try {
				if IsSet(NativeScope)
					Func.Prototype.Call.Call(OriginalLoader, "close_scope", NativeScope)
			} finally _LLM_NavEventOwnerTerminalRouteRefreshing := false
		}
	} finally Critical(PreviousCritical)
}

/** Exact private authority retained before source/registration callbacks. */
_LLM_NavEventOwnerTerminalRegistrationCapture() {
	global _LLM_NavEventOwnerTerminalRouteOwner, _LLM_NavEventOwnerTerminalRouteGeneration
	global _LLM_NavEventOwnerTerminalRouteRecipes, _LLM_NavEventOwnerTerminalRouteModels
	global _LLM_NavEventOwnerTerminalRouteCoverage
	global _LLM_NavEventOwnerTerminalRouteNextRecipe, _LLM_NavEventOwnerTerminalRouteNextLayout
	Owner := _LLM_NavEventOwnerTerminalRouteOwner
	Generation := _LLM_NavEventOwnerTerminalRouteGeneration
	Recipes := _LLM_NavEventOwnerTerminalRouteRecipes, Models := _LLM_NavEventOwnerTerminalRouteModels
	Coverage := _LLM_NavEventOwnerTerminalRouteCoverage
	NextRecipe := _LLM_NavEventOwnerTerminalRouteNextRecipe, NextLayout := _LLM_NavEventOwnerTerminalRouteNextLayout
	if !(NextRecipe is Integer) || NextRecipe < 0 || !(NextLayout is Integer) || NextLayout <= 0
			|| !(Owner is Integer) || Owner <= 0 || !(Generation is Integer) || Generation < 0
			|| !_LLM_NavEventOwnerTerminalRegistrationPlainMap(Recipes)
			|| !_LLM_NavEventOwnerTerminalRegistrationPlainMap(Models)
			|| !_LLM_NavEventOwnerTerminalRegistrationPlainMap(Coverage)
		throw ValueError("The terminal registration authority is malformed.")
	for RecipeId in Recipes
		if !(RecipeId is Integer) || RecipeId <= 0 || RecipeId > NextRecipe
			throw ValueError("The terminal recipe identity owner precedes its retained references.")
	Frame := Map("digit_source", 0, "owner", Owner, "generation", Generation, "recipes", Recipes,
		"models", Models, "coverage", Coverage, "recipe_refs", Recipes.Clone(),
		"model_refs", Models.Clone(), "candidate", 0, "bindings", 0, "native_attempted", false,
		"next_recipe", NextRecipe, "next_layout", NextLayout)
	_LLM_NavEventOwnerTerminalRegistrationRetain(Frame)
	return Frame
}

_LLM_NavEventOwnerTerminalRegistrationPlainMap(Value) {
	if !(Value is Map) || ObjGetBase(Value) != Map.Prototype
		return false
	for Name in ["Get", "Has", "Clone", "__Item", "__Enum", "Count"]
		if Object.Prototype.HasOwnProp.Call(Value, Name)
			return false
	return true
}

/** No callback may exchange dictionary cells and still retire their old holders. */
_LLM_NavEventOwnerTerminalRegistrationRefsCurrent(Owned, Snapshot) {
	if !_LLM_NavEventOwnerTerminalRegistrationPlainMap(Owned) || Owned.Count != Snapshot.Count
		return false
	for Id, Value in Snapshot
		if !Owned.Has(Id) || Type(Owned[Id]) != Type(Value) || !(Owned[Id] == Value)
			return false
	return true
}

_LLM_NavEventOwnerTerminalRegistrationCurrent(Frame, CheckModels := true, CheckIds := true) {
	static OriginalLoader := _LLM_NavEventOwnerNativeEnsureLoaded
	if _LLM_NavEventOwnerNativeEnsureLoaded != OriginalLoader
			|| Object.Prototype.HasOwnProp.Call(OriginalLoader, "Call")
			|| !OriginalLoader.Call("digit_current", Frame)
		return false
	global _LLM_NavEventOwnerTerminalRouteOwner, _LLM_NavEventOwnerTerminalRouteGeneration
	global _LLM_NavEventOwnerTerminalRouteRecipes, _LLM_NavEventOwnerTerminalRouteModels
	global _LLM_NavEventOwnerTerminalRouteCoverage
	global _LLM_NavEventOwnerTerminalRouteNextRecipe, _LLM_NavEventOwnerTerminalRouteNextLayout
	return _LLM_NavEventOwnerTerminalRouteOwner is Integer
		&& _LLM_NavEventOwnerTerminalRouteOwner == Frame["owner"]
		&& _LLM_NavEventOwnerTerminalRouteGeneration is Integer
		&& _LLM_NavEventOwnerTerminalRouteGeneration == Frame["generation"]
		&& _LLM_NavEventOwnerTerminalRouteRecipes == Frame["recipes"]
		&& _LLM_NavEventOwnerTerminalRouteModels == Frame["models"]
		&& _LLM_NavEventOwnerTerminalRouteCoverage == Frame["coverage"]
		&& (!CheckIds || (_LLM_NavEventOwnerTerminalRouteNextRecipe is Integer
			&& _LLM_NavEventOwnerTerminalRouteNextRecipe == Frame["next_recipe"]
			&& _LLM_NavEventOwnerTerminalRouteNextLayout is Integer
			&& _LLM_NavEventOwnerTerminalRouteNextLayout == Frame["next_layout"]))
		&& _LLM_NavEventOwnerTerminalRegistrationPlainMap(Frame["models"])
		&& _LLM_NavEventOwnerTerminalRegistrationRefsCurrent(Frame["recipes"], Frame["recipe_refs"])
		&& (!CheckModels || _LLM_NavEventOwnerTerminalRegistrationRefsCurrent(Frame["models"], Frame["model_refs"]))
		&& _LLM_NavEventOwnerTerminalRegistrationObjectsCurrent(Frame, CheckModels)
}

/** Only this build's contiguous recipe IDs and one new model may advance owners. */
_LLM_NavEventOwnerTerminalRegistrationAdvance(Frame, Candidate, Source) {
	global _LLM_NavEventOwnerTerminalRouteNextRecipe, _LLM_NavEventOwnerTerminalRouteNextLayout
	ExpectedRecipe := Frame["next_recipe"] + Candidate["routes"].Length
	NewModel := Source["active"] && Source.Get("model", 0) is Map
		&& !Frame["model_refs"].Has(ObjPtr(Source["model"]))
	ExpectedLayout := Frame["next_layout"] + (NewModel ? 1 : 0)
	Valid := _LLM_NavEventOwnerTerminalRouteNextRecipe is Integer
		&& _LLM_NavEventOwnerTerminalRouteNextRecipe == ExpectedRecipe
		&& _LLM_NavEventOwnerTerminalRouteNextLayout is Integer
		&& _LLM_NavEventOwnerTerminalRouteNextLayout == ExpectedLayout
	for Index, Route in Candidate["routes"]
		if Route["recipe_id"] != Frame["next_recipe"] + Index
			Valid := false
	if !Valid {
		_LLM_NavEventOwnerTerminalRegistrationUnknown(Frame)
		throw ValueError("A callback changed the terminal registration identity owners.")
	}
	Frame["next_recipe"] := ExpectedRecipe, Frame["next_layout"] := ExpectedLayout
}

/** Keep selected original object references even if a callback mutates a cell. */
_LLM_NavEventOwnerTerminalRegistrationRetain(Frame) {
	Frame["recipe_refs"] := Frame["recipes"].Clone()
	Frame["model_refs"] := Frame["models"].Clone()
	Routes := Map(), Models := Map()
	for Id, Admission in Frame["recipes"] {
		if !_LLM_NavEventOwnerTerminalRegistrationPlainMap(Admission)
			throw ValueError("A retained terminal recipe cell is malformed.")
		Recipe := Admission["recipe"]
		if !_LLM_NavEventOwnerTerminalRegistrationPlainMap(Admission["route"])
			throw ValueError("A retained terminal route is not a plain Map.")
		Binding := Admission.Get("binding", 0)
		if (Admission["route"]["kind"] == 6) != (Binding is Map)
				|| (Binding is Map && !_LLM_NavEventOwnerTerminalRegistrationPlainMap(Binding))
			throw ValueError("A direct-digit admission lost its retained binding fields.")
		if !_LLM_NavEventOwnerTerminalRegistrationPlainMap(Admission["route"])
				|| (Recipe is Map && !_LLM_NavEventOwnerTerminalRegistrationPlainMap(Recipe))
			throw ValueError("The retained terminal route/model recipe is malformed.")
		Routes[Id] := Map("binding", Binding, "binding_fields", Binding is Map ? Binding.Clone() : 0,
			"route", Admission["route"], "recipe", Recipe,
			"model", Recipe is Map ? Recipe.Get("model", 0) : 0,
			"route_fields", Admission["route"].Clone(),
			"recipe_fields", Recipe is Map ? Recipe.Clone() : 0,
			"generation", Admission["generation"], "layout_id", Admission["layout_id"])
	}
	for Id, Identity in Frame["models"] {
		if !_LLM_NavEventOwnerTerminalRegistrationPlainMap(Identity)
				|| !(Identity.Get("id", 0) is Integer) || Identity["id"] <= 1
				|| Identity["id"] > Frame["next_layout"]
			throw ValueError("A retained terminal model cell is malformed.")
		Models[Id] := Map("model", Identity["model"], "id", Identity["id"])
	}
	Frame["route_objects"] := Routes, Frame["model_objects"] := Models
}

_LLM_NavEventOwnerTerminalRegistrationObjectsCurrent(Frame, CheckModels) {
	if !CheckModels && !_LLM_NavEventOwnerTerminalRegistrationBuildModelsCurrent(Frame)
		return false
	for Id, Expected in Frame["route_objects"] {
		if !Frame["recipes"].Has(Id)
			return false
		Admission := Frame["recipes"][Id]
		if !_LLM_NavEventOwnerTerminalRegistrationPlainMap(Admission)
			return false
		for Name in ["route", "recipe", "generation", "layout_id"]
			if Type(Admission.Get(Name, "")) != Type(Expected[Name]) || !(Admission.Get(Name, "") == Expected[Name])
				return false
		if !_LLM_NavEventOwnerTerminalRegistrationRefsCurrent(Expected["route"], Expected["route_fields"])
			return false
		Binding := Expected["binding"]
		if Binding is Map {
			if Admission.Get("binding", 0) != Binding
					|| !_LLM_NavEventOwnerTerminalRegistrationRefsCurrent(Binding, Expected["binding_fields"])
				return false
		} else if Admission.Has("binding")
			return false
		Recipe := Expected["recipe"]
		if Recipe is Map && (!_LLM_NavEventOwnerTerminalRegistrationPlainMap(Recipe)
				|| Recipe.Get("model", 0) != Expected["model"]
				|| !_LLM_NavEventOwnerTerminalRegistrationRefsCurrent(Recipe, Expected["recipe_fields"]))
			return false
	}
	; A partial builder may add its captured identity, but cannot mutate old cells.
	for Id, Expected in Frame["model_objects"] {
		if !Frame["models"].Has(Id)
			return false
		Identity := Frame["models"][Id]
		if !_LLM_NavEventOwnerTerminalRegistrationPlainMap(Identity)
				|| Identity.Get("model", 0) != Expected["model"]
				|| !(Identity.Get("id", 0) is Integer) || Identity["id"] != Expected["id"]
			return false
	}
	return true
}

/** Preserve old cells and the one actual allocation before recapturing snapshots. */
_LLM_NavEventOwnerTerminalRegistrationBuildModelsCurrent(Frame) {
	Models := Frame["models"], Original := Frame["model_refs"]
	for Id, Identity in Original
		if !Models.Has(Id) || Models[Id] != Identity
			return false
	Key := Frame.Get("build_model_key", 0)
	NewModel := Key != 0 && !Original.Has(Key)
	if Models.Count != Original.Count + (NewModel ? 1 : 0)
		return false
	if Key != 0 {
		if !Models.Has(Key) || Models[Key] != Frame["build_model_cell"]
			return false
		if !_LLM_NavEventOwnerTerminalRegistrationRefsCurrent(Models[Key], Frame["build_model_fields"])
			return false
	}
	return true
}

_LLM_NavEventOwnerTerminalRegistrationRequire(Frame) {
	if !_LLM_NavEventOwnerTerminalRegistrationCurrent(Frame)
		throw ValueError("A callback withdrew the original terminal registration authority.")
}

_LLM_NavEventOwnerTerminalRegistrationBytesCurrent(Actual, Expected) {
	if !(Actual is Buffer) || Actual.Size != Expected.Size
		return false
	Loop Expected.Size
		if NumGet(Actual, A_Index - 1, "UChar") != NumGet(Expected, A_Index - 1, "UChar")
			return false
	return true
}

/** Only documented native registration refusals prove no candidate was accepted. */
_LLM_NavEventOwnerTerminalRegistrationStatusKnown(Status) {
	return Status == 0 || Status == -1 || Status == -2 || Status == -3
		|| Status == -4 || Status == -5 || Status == -6 || Status == -9 || Status == -11
}

/** Retains original references without restoring a foreign dictionary or guessing ACK. */
_LLM_NavEventOwnerTerminalRegistrationUnknown(Frame) {
	global _LLM_NavEventOwnerTerminalRouteUnknown
	if !IsObject(_LLM_NavEventOwnerTerminalRouteUnknown)
		_LLM_NavEventOwnerTerminalRouteUnknown := Frame
	return false
}

/**
 * Retains current registrations and exact native held identities only. The
 * registration ACK establishes a debt-free boundary; Critical prevents this
 * script from starting capture between publication and the held-identity query.
 * A failed or malformed query retains every reference for a later safe retry.
 */
_LLM_NavEventOwnerTerminalRoutePrune(Candidate, Source, Port, Frame := 0) {
	global _LLM_NavEventOwnerTerminalRouteOwner
	global _LLM_NavEventOwnerTerminalRouteRecipes, _LLM_NavEventOwnerTerminalRouteModels
	static OriginalLoader := _LLM_NavEventOwnerNativeEnsureLoaded
	static OriginalUnknown := _LLM_NavEventOwnerTerminalRegistrationUnknown
	GuardFrame() {
		if _LLM_NavEventOwnerNativeEnsureLoaded != OriginalLoader
				|| Object.Prototype.HasOwnProp.Call(OriginalLoader, "Call")
			throw Error("The original held-query constructor was withdrawn.")
		if !OriginalLoader.Call("guard_frame", Frame)
			throw Error("The original held-query Frame was withdrawn.")
		if !(Source is Map) || ObjGetBase(Source) != Map.Prototype
			throw Error("The held-query source is not a plain Map.")
		for Name in ObjOwnProps(Source)
			throw Error("The held-query source cannot invoke a map observer.")
	}
	RetainUnknown() {
		Func.Prototype.Call.Call(OriginalUnknown, Frame)
	}
	if !(Frame is Map)
		throw ValueError("Held-query pruning requires its already issued Frame.")
	try {
		GuardFrame()
		_LLM_NavEventOwnerTerminalRegistrationRequire(Frame)
		GuardFrame()
		HeldFn := _LLM_NavEventOwnerPortFn("list_terminal_held_recipes", Port)
		GuardFrame()
		if !HasMethod(HeldFn, "Call") {
			GuardFrame()
			RegisterFn := _LLM_NavEventOwnerPortFn("register_terminal_routes", Port)
			GuardFrame()
			if HasMethod(RegisterFn, "Call")
				return false
		}
		HeldBuffer := Buffer(64 * 8, 0)
		GuardFrame()
		Reply := HasMethod(HeldFn, "Call") ? HeldFn.Call(Frame["owner"], HeldBuffer, 64)
			: OriginalLoader.Call("frame_held", Map("frame", Frame, "buffer", HeldBuffer))
		GuardFrame()
		if !_LLM_NavEventOwnerTerminalRegistrationCurrent(Frame) {
			RetainUnknown()
			throw ValueError("Held-query callback withdrew the original registration authority.")
		}
		if !(Reply is Map) || ObjGetBase(Reply) != Map.Prototype
			throw Error("Held terminal recipe query returned a malformed ACK.")
		for Name in ObjOwnProps(Reply)
			throw Error("Held terminal recipe query cannot invoke a map observer.")
		if !(Reply.Get("status", "") is Integer)
			throw Error("Held terminal recipe query returned a malformed ACK.")
		if Reply["status"] != 0
			throw Error("Held terminal recipe query refused with status " . Reply["status"] . ".")
		if !(Reply.Get("count", "") is Integer) || Reply["count"] < 0 || Reply["count"] > 64
			throw Error("Held terminal recipe query returned an invalid count.")
		GuardFrame()
		Keep := Map(), Held := Map()
		for RecipeId in Candidate["recipes"]
			Keep[RecipeId] := true
		Loop Reply["count"] {
			RecipeId := NumGet(HeldBuffer, (A_Index - 1) * 8, "UInt64")
			if RecipeId <= 0 || Held.Has(RecipeId) || !_LLM_NavEventOwnerTerminalRouteRecipes.Has(RecipeId)
				throw Error("Held terminal recipe query returned an unknown or duplicate identity.")
			Held[RecipeId] := true, Keep[RecipeId] := true
		}
		GuardFrame()
		Protected := OriginalLoader.Call("protected_historical", Map("frame", Frame))
		for RecipeId in Protected["recipes"]
			Keep[RecipeId] := true
		KeepModels := Protected["models"]
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
		for Identity in _LLM_NavEventOwnerTerminalRouteModels
			if !KeepModels.Has(Identity)
				RetireModels.Push(Identity)
		GuardFrame()
		if !_LLM_NavEventOwnerTerminalRegistrationCurrent(Frame) {
			RetainUnknown()
			throw ValueError("Retirement cannot borrow a successor registration owner.")
		}
		OriginalLoader.Call("prune_historical", Map("frame", Frame, "keep", Keep, "models", KeepModels))
		for RecipeId in RetireRecipes
			_LLM_NavEventOwnerTerminalRouteRecipes.Delete(RecipeId)
		for Identity in RetireModels
			_LLM_NavEventOwnerTerminalRouteModels.Delete(Identity)
		GuardFrame()
		_LLM_NavEventOwnerTerminalRegistrationRetain(Frame)
		return true
	} catch Error as Err {
		try {
			GuardFrame()
			if !_LLM_NavEventOwnerTerminalRegistrationCurrent(Frame)
				RetainUnknown()
		} catch {
			RetainUnknown()
		}
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

/** Captures a diagnostic binding lease and an independent private current check. */
_LLM_NavEventOwnerCaptureDigitSource() {
	static OriginalSource := DigitRow_BindingSource
	static OriginalCapture := DigitRow_CaptureBinding
	static OriginalMode := NumberRowEffectiveMode
	static OriginalSelf := _LLM_NavEventOwnerCaptureDigitSource
	static NativeCall := Func.Prototype.Call
	static NativeBind := Func.Prototype.Bind
	static OriginalPlainMap := _LLM_NavEventOwnerTerminalRegistrationPlainMap
	static OriginalRefsCurrent := _LLM_NavEventOwnerTerminalRegistrationRefsCurrent

	FunctionsCurrent() {
		for Pair in [[OriginalSource, DigitRow_BindingSource],
			[OriginalCapture, DigitRow_CaptureBinding], [OriginalMode, NumberRowEffectiveMode],
			[OriginalSelf, _LLM_NavEventOwnerCaptureDigitSource],
			[OriginalPlainMap, _LLM_NavEventOwnerTerminalRegistrationPlainMap],
			[OriginalRefsCurrent, _LLM_NavEventOwnerTerminalRegistrationRefsCurrent],
			[NativeCall, Func.Prototype.Call], [NativeBind, Func.Prototype.Bind]]
			if !(Pair[1] is Func) || Pair[1] != Pair[2]
					|| Object.Prototype.HasOwnProp.Call(Pair[1], "Call")
				return false
		return true
	}

	RequireFunctions() {
		if !FunctionsCurrent()
			throw Error("The original direct-digit source accessor was withdrawn.")
	}

	ReadMode() {
		RequireFunctions()
		Value := NativeCall.Call(OriginalMode)
		RequireFunctions()
		if !(Value is String) || !(Value == "native" || Value == "symbols" || Value == "digits")
			throw ValueError("The direct-digit source mode is invalid.")
		return Value
	}

	Mode := ReadMode(), Factory := 0, Rows := Map(), Images := Map()
	if Mode == "digits" {
		RequireFunctions()
		Factory := NativeCall.Call(OriginalSource)
		RequireFunctions()
		if !((Factory is Integer && Factory == 0) || Factory is BoundFunc)
			throw ValueError("The direct-digit source factory is invalid.")
		if Factory is BoundFunc {
			Loop 10 {
				Scan := A_Index + 1
				RequireFunctions()
				Row := NativeCall.Call(OriginalCapture, Factory, Scan)
				RequireFunctions()
				if !NativeCall.Call(OriginalPlainMap, Row) || Row.Count != 8
						|| Row.Get("source", 0) != Factory
						|| !(Row.Get("scan", "") is Integer) || Row["scan"] != Scan
						|| !(Row.Get("digit", 0) is String) || !RegExMatch(Row["digit"], "^[0-9]$")
						|| !(Row.Get("down", 0) is BoundFunc) || !(Row.Get("up", 0) is BoundFunc)
						|| !(Row.Get("criterion", 0) is String) || Row["criterion"] == ""
						|| !(Row.Get("input_level", "") is Integer) || Row["input_level"] != 2
						|| !(Row.Get("metadata_only", "") is Integer) || Row["metadata_only"] != true
					throw ValueError("The original direct-digit binding was not captured completely.")
				Rows[Scan] := Row
				Images[Scan] := Row.Clone()
			}
		}
	}
	Cell := Map("mode", Mode, "factory", Factory, "rows", Rows)
	CellImage := Cell.Clone()
	RowRefs := Rows.Clone()

	Current() {
		if !FunctionsCurrent()
			return false
		if !NativeCall.Call(OriginalRefsCurrent, Cell, CellImage)
				|| !NativeCall.Call(OriginalRefsCurrent, Rows, RowRefs)
			return false
		if !NativeCall.Call(OriginalPlainMap, Rows) || !NativeCall.Call(OriginalPlainMap, Images)
			return false
		if Mode != "digits"
			return Rows.Count == 0 && Images.Count == 0
		if NativeCall.Call(OriginalSource) != Factory || !FunctionsCurrent()
			return false
		if Factory is Integer
			return Factory == 0 && Rows.Count == 0 && Images.Count == 0
		if Rows.Count != 10 || Images.Count != 10
			return false
		Loop 10 {
			Scan := A_Index + 1
			if !Rows.Has(Scan) || !Images.Has(Scan)
					|| !NativeCall.Call(OriginalRefsCurrent, Rows[Scan], Images[Scan])
				return false
			Observed := NativeCall.Call(OriginalCapture, Factory, Scan)
			if !FunctionsCurrent() || !NativeCall.Call(OriginalRefsCurrent, Observed, Images[Scan])
				return false
		}
		return FunctionsCurrent() && NativeCall.Call(OriginalRefsCurrent, Cell, CellImage)
			&& NativeCall.Call(OriginalRefsCurrent, Rows, RowRefs)
	}

	ModeCurrent() {
		; Policy Maps may run an observer. Complete that observation before the
		; source-only witnesses and the caller's complete registration checks.
		return FunctionsCurrent() && ReadMode() == Mode && Current()
	}

	RequireFunctions()
	Guard := NativeCall.Call(NativeBind, Current)
	ModeGuard := NativeCall.Call(NativeBind, ModeCurrent)
	RequireFunctions()
	if !ModeGuard.Call()
		throw Error("The direct-digit source changed during capture.")
	; The loader retains this exact guard privately. The public Frame receives
	; only Cell; copying or replacing that Map cannot replace its private witness.
	return Map("source", Cell, "current", Guard, "mode_current", ModeGuard)
}

/** Freezes pending admissions before any registration callback can observe them. */
_LLM_NavEventOwnerCaptureTerminalCandidate(Candidate, DigitCell, CanonicalSource := 0) {
	global KEYLAYOUT_NEUTRAL_STATE
	static OriginalPlain := _LLM_NavEventOwnerTerminalRegistrationPlainMap
	static OriginalRefs := _LLM_NavEventOwnerTerminalRegistrationRefsCurrent
	static OriginalSelf := _LLM_NavEventOwnerCaptureTerminalCandidate
	static NativeCall := Func.Prototype.Call, NativeBind := Func.Prototype.Bind

	FunctionsCurrent() {
		for Pair in [[OriginalPlain, _LLM_NavEventOwnerTerminalRegistrationPlainMap],
			[OriginalRefs, _LLM_NavEventOwnerTerminalRegistrationRefsCurrent],
			[OriginalSelf, _LLM_NavEventOwnerCaptureTerminalCandidate],
			[NativeCall, Func.Prototype.Call], [NativeBind, Func.Prototype.Bind]]
			if !(Pair[1] is Func) || Pair[1] != Pair[2]
					|| Object.Prototype.HasOwnProp.Call(Pair[1], "Call")
				return false
		return true
	}

	PlainArray(Value) {
		if !(Value is Array) || ObjGetBase(Value) != Array.Prototype
			return false
		for Name in ObjOwnProps(Value)
			return false
		return true
	}

	RequireCanonicalRecipe(Recipe, Route) {
		; Only the original frame supplies this private loader-issued witness.
		; Digit bindings and natural modifiers have their own non-KLE sources.
		if !NativeCall.Call(OriginalPlain, CanonicalSource)
				|| !(CanonicalSource.Get("active", 0) is Integer) || CanonicalSource["active"] != 1
				|| !(CanonicalSource.Get("model", 0) is Map)
				|| Recipe.Get("model", 0) != CanonicalSource["model"]
				|| !(Recipe.Get("layout_id", 0) is String)
				|| !(Recipe["layout_id"] == CanonicalSource.Get("layout_name", 0))
				|| !(Recipe.Get("scan", 0) is String) || !RegExMatch(Recipe["scan"], "^SC[0-9A-F]{3}$")
				|| !(Recipe.Get("index", "") is Integer) || !(Recipe.Get("keycode", "") is Integer)
			throw ValueError("The pending recipe does not belong to the captured canonical source.")
		Reader := CanonicalSource.Get("read", 0)
		if !(Reader is BoundFunc) || Object.Prototype.HasOwnProp.Call(Reader, "Call")
			throw ValueError("The original canonical graph reader was withdrawn.")
		Modifiers := Route.Get("required_modifiers", -1)
		if !(Modifiers is Integer) || (Modifiers != 0 && Modifiers != 4)
			throw ValueError("The pending canonical recipe has an unsupported modifier family.")
		Row := NativeCall.Call(Reader, "find", KEYLAYOUT_NEUTRAL_STATE, Recipe["scan"], Modifiers == 4 ? 1 : 0)
		if !NativeCall.Call(OriginalPlain, Row) || Row["before_id"] != 0 || Row["after_id"] != 0
				|| (Row["kind"] != 1 && Row["kind"] != 2) || !(Row["output"] is String)
				|| Row["index"] != Recipe["index"] || Row["keycode"] != Recipe["keycode"]
				|| Route.Get("kind", 0) != Row["kind"] || Route.Get("axis", 0) != 2
				|| Route.Get("code", 0) != Integer("0x" . SubStr(Row["scan"], 3))
			throw ValueError("The pending recipe differs from its exact canonical graph row.")
		for Name in ["required_prefixes", "prefix_bit", "effective_modifiers_lr", "target_vk", "target_scan",
			"required_dead_key_id", "next_dead_key_id"]
			if !Route.Has(Name) || !(Route[Name] is Integer) || Route[Name] != 0
				throw ValueError("The pending canonical recipe changed its neutral descriptor.")
	}

	if !FunctionsCurrent() || !NativeCall.Call(OriginalPlain, Candidate)
			|| !NativeCall.Call(OriginalPlain, DigitCell)
			|| !PlainArray(Candidate.Get("routes", 0))
			|| !PlainArray(Candidate.Get("unconverted", 0))
			|| !NativeCall.Call(OriginalPlain, Candidate.Get("recipes", 0))
		throw ValueError("The pending terminal candidate has an invalid shape.")
	Routes := Candidate["routes"], Recipes := Candidate["recipes"], Reasons := Candidate["unconverted"]
	if Routes.Length < 1 || Recipes.Count != Routes.Length
		throw ValueError("The pending terminal candidate is incomplete.")
	RouteRefs := Routes.Clone(), RecipeRefs := Recipes.Clone(), ReasonImage := Reasons.Clone()
	CandidateImage := Candidate.Clone(), Records := Map(), RouteImages := [], Digits := Map()
	for Index, Route in Routes {
		if !NativeCall.Call(OriginalPlain, Route)
			throw ValueError("A pending native descriptor is not a plain Map.")
		Id := Route.Get("recipe_id", 0)
		if !(Id is Integer) || Id <= 0 || !Recipes.Has(Id) || Records.Has(Id)
			throw ValueError("A pending recipe identity is invalid or duplicated.")
		Admission := Recipes[Id]
		if !NativeCall.Call(OriginalPlain, Admission)
				|| !NativeCall.Call(OriginalPlain, Admission.Get("route", 0))
				|| !NativeCall.Call(OriginalRefs, Admission["route"], Route)
			throw ValueError("A pending admission does not retain its exact native descriptor.")
		Recipe := Admission.Get("recipe", 0), Binding := Admission.Get("binding", 0)
		if Recipe is Map && !NativeCall.Call(OriginalPlain, Recipe)
			throw ValueError("A pending model recipe is not a plain Map.")
		Kind := Route.Get("kind", 0)
		if !(Kind is Integer) || Kind < 1 || Kind > 6
			throw ValueError("A pending canonical admission has an invalid route kind.")
		if Kind <= 3 {
			if !(Recipe is Map)
				throw ValueError("A pending canonical model descriptor requires its original recipe.")
			RequireCanonicalRecipe(Recipe, Route)
		} else if !(Recipe is Integer) || Recipe != 0
			throw ValueError("A natural or digit admission cannot borrow a canonical model recipe.")
		if Route.Get("kind", 0) == 6 {
			Scan := Route.Get("code", 0)
			if !(Scan is Integer) || Scan < 0x02 || Scan > 0x0B || Digits.Has(Scan)
					|| !(Recipe is Integer) || Recipe != 0
					|| DigitCell.Get("mode", "") != "digits"
					|| !(DigitCell.Get("factory", 0) is BoundFunc)
					|| !NativeCall.Call(OriginalPlain, DigitCell.Get("rows", 0))
					|| !DigitCell["rows"].Has(Scan)
					|| !NativeCall.Call(OriginalRefs, Binding, DigitCell["rows"][Scan])
				throw ValueError("A pending digit admission lost its canonical binding source.")
			Digits[Scan] := true
		} else if Admission.Has("binding")
			throw ValueError("Only direct-digit admissions may retain binding metadata.")
		RouteImages.Push(Route.Clone())
		Records[Id] := Map("admission", Admission, "fields", Admission.Clone(),
			"route", Admission["route"], "route_fields", Admission["route"].Clone(),
			"recipe", Recipe, "recipe_fields", Recipe is Map ? Recipe.Clone() : 0,
			"binding", Binding, "binding_fields", Binding is Map ? Binding.Clone() : 0)
	}
	ExpectedDigits := DigitCell["mode"] == "digits" && DigitCell["factory"] is BoundFunc ? 10 : 0
	if Digits.Count != ExpectedDigits
		throw ValueError("The pending direct-digit source family is incomplete.")
	for Reason in Reasons
		if !(Reason is String)
			throw ValueError("A pending coverage explanation is not text.")

	Current() {
		if !FunctionsCurrent() || !NativeCall.Call(OriginalRefs, Candidate, CandidateImage)
				|| !NativeCall.Call(OriginalRefs, Recipes, RecipeRefs)
				|| !PlainArray(Routes) || Routes.Length != RouteRefs.Length
				|| !PlainArray(Reasons) || Reasons.Length != ReasonImage.Length
			return false
		for Index, Expected in RouteRefs
			if !Routes.Has(Index) || Routes[Index] != Expected
					|| !NativeCall.Call(OriginalRefs, Routes[Index], RouteImages[Index])
				return false
		for Index, Reason in ReasonImage
			if !Reasons.Has(Index) || !(Reasons[Index] is String) || !(Reasons[Index] == Reason)
				return false
		for Id, Record in Records {
			Admission := Recipes[Id]
			if Admission != Record["admission"]
					|| !NativeCall.Call(OriginalRefs, Admission, Record["fields"])
					|| !NativeCall.Call(OriginalRefs, Record["route"], Record["route_fields"])
				return false
			if Record["recipe"] is Map
					&& !NativeCall.Call(OriginalRefs, Record["recipe"], Record["recipe_fields"])
				return false
			if Record["binding"] is Map
					&& !NativeCall.Call(OriginalRefs, Record["binding"], Record["binding_fields"])
				return false
		}
		return FunctionsCurrent()
	}

	if !FunctionsCurrent()
		throw Error("The original terminal candidate witness constructor was withdrawn.")
	Guard := NativeCall.Call(NativeBind, Current)
	if !FunctionsCurrent() || !Guard.Call()
		throw Error("The pending terminal candidate changed during witness capture.")
	return Guard
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

_LLM_NavEventOwnerTerminalRouteBuild(Source, Generation, Frame := 0, ScopeGuard := unset) {
	global KEYLAYOUT_NEUTRAL_STATE
	global _LLM_NavEventOwnerTerminalRouteModels
	Guard() {
		if IsSet(ScopeGuard)
			ScopeGuard.Call()
	}
	Guard()
	if !(Source is Map) || !Source.Has("active") || !Source.Has("caps")
			|| !(Source["active"] is Integer) || Source["active"] < 0 || Source["active"] > 1
			|| !(Source["caps"] is Integer) || Source["caps"] < 0 || Source["caps"] > 1
			|| !(Generation is Integer) || Generation <= 0
		throw ValueError("Terminal route source ownership is invalid.")
	Guard()
	LayoutId := Source["active"] && Source.Has("model") && Source["model"] is Map
		? _LLM_NavEventOwnerTerminalRouteLayoutId(Source["model"]) : 1
	if Frame is Map {
		Frame["build_model_key"] := 0
		if Source["active"] && Source.Has("model") && Source["model"] is Map {
			Key := ObjPtr(Source["model"]), Identity := _LLM_NavEventOwnerTerminalRouteModels[Key]
			Guard()
			if !_LLM_NavEventOwnerTerminalRegistrationPlainMap(Identity)
				throw ValueError("The allocated terminal model identity is malformed.")
			Frame["build_model_key"] := Key
			Frame["build_model_cell"] := Identity
			Frame["build_model_fields"] := Identity.Clone()
		}
	}
	Routes := []
	Recipes := Map()
	Unconverted := ["CapsLock", "AltGr", "dead-key sequences", "tap-hold transforms",
		"shortcut chords", "prefix layers", "direct-digit overrides", "pre-registration holds"]
	DigitRows := 0
	if Frame is Map && IsSet(ScopeGuard) {
		Guard()
		Cell := Frame["digit_source"]
		if Cell["mode"] == "digits" && Cell["factory"] is BoundFunc
			DigitRows := Cell["rows"]
	}
	AppendDirectDigits() {
		if !(DigitRows is Map)
			return
		Guard()
		; Marshal rejects an oversized composed registry before either registration boundary.
		Loop 10 {
			Guard()
			Scan := A_Index + 1
			Binding := DigitRows[Scan].Clone()
			Id := _LLM_NavEventOwnerTerminalRouteNextRecipeId()
			Guard()
			Route := _LLM_NavEventOwnerTerminalRouteDescriptor(Id, Routes.Length + 1, 2, Scan, 6)
			Routes.Push(Route)
			Recipes[Id] := Map("recipe", 0, "binding", Binding, "route", Route.Clone(),
				"generation", Generation, "layout_id", LayoutId)
		}
	}
	NaturalScans := Map()
	for Modifier in [[0xA2, 0x01, 0x01D], [0xA3, 0x02, 0x11D],
			[0xA4, 0x04, 0x038], [0xA5, 0x08, 0x138], [0xA0, 0x10, 0x02A],
			[0xA1, 0x20, 0x036], [0x5B, 0x40, 0x15B], [0x5C, 0x80, 0x15C]] {
		NaturalScans[Modifier[3]] := true
		for Axis in [2, 1] {
			Guard()
			Id := _LLM_NavEventOwnerTerminalRouteNextRecipeId()
			Guard()
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
		AppendDirectDigits()
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
		AppendDirectDigits()
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
			Guard()
			Scan := Integer("0x" . SubStr(Sc, 3))
			if DigitRows is Map && !Shift && Scan >= 0x02 && Scan <= 0x0B {
				Unconverted.Push(Sc . ":base:direct-digit source, output unconverted")
				continue
			}
			Eligible := Source["eligible"].Call(Sc, Shift)
			Guard()
			if !Eligible {
				Unconverted.Push(Sc . (Shift ? ":Shift" : ":base") . ":another owner")
				continue
			}
			Guard()
			Recipe := Source["capture"].Call(Sc, Shift, false, false)
			Guard()
			if !(Recipe is Map) || !Recipe.Has("model") || !(Recipe["model"] is Map)
					|| ObjPtr(Recipe["model"]) != ObjPtr(Source["model"])
					|| Recipe.Get("layout_id", 0) != Source["layout_name"]
					|| Recipe.Get("scan", 0) != Sc
				throw ValueError("KLE registration changed its model during capture.")
			; A borrowed recipe can observe Has/Get/__Item; authenticate after those reads.
			RecipeModel := Recipe["model"], RecipeIndex := Recipe["index"], RecipeCode := Recipe["keycode"]
			Guard()
			Resolved := Keylayout_Resolve(RecipeModel, RecipeIndex, RecipeCode)
			Guard()
			if Resolved["Kind"] != "text" {
				Unconverted.Push(Sc . (Shift ? ":Shift" : ":base") . ":" . Resolved["Kind"])
				continue
			}
			Guard()
			Id := _LLM_NavEventOwnerTerminalRouteNextRecipeId()
			Kind := RegExMatch(Resolved["Text"], "^[0-9]$") ? 2 : 1
			Guard()
			Route := _LLM_NavEventOwnerTerminalRouteDescriptor(
				Id, Routes.Length + 1, 2, Integer("0x" . SubStr(Sc, 3)), Kind, Shift ? 4 : 0)
			Routes.Push(Route)
			Recipes[Id] := Map("recipe", Recipe.Clone(), "route", Route.Clone(),
				"generation", Generation, "layout_id", LayoutId)
		}
	}
	Guard()
	AppendDirectDigits()
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
		"axis", 2, "kind", 6, "required_modifiers", 15, "effective_modifiers_lr", 255)
	for Name, Maximum in Limits
		if !Route.Has(Name) || !(Route[Name] is Integer)
				|| Route[Name] < 0 || Route[Name] > Maximum
			throw ValueError("The terminal route contains an invalid typed field.")
	if Route["recipe_id"] == 0 || Route["route_id"] == 0 || Route["code"] == 0
			|| Route["axis"] == 0 || Route["kind"] == 0
			|| (Route["axis"] == 1 && Route["code"] > 255)
			|| (Route["target_vk"] != 0 && Route["target_scan"] != 0)
		throw ValueError("The terminal route key identity is invalid.")
	if Route["kind"] == 6 {
		; Source intent cannot inherit KLE text or guess a host output identity.
		if Route["axis"] != 2 || Route["code"] < 0x02 || Route["code"] > 0x0B
				|| Route["target_vk"] || Route["target_scan"]
				|| Route["required_modifiers"] || Route["required_prefixes"]
				|| Route["prefix_bit"] || Route["effective_modifiers_lr"]
				|| Route["required_dead_key_id"] || Route["next_dead_key_id"]
			throw ValueError("The direct-digit source descriptor is invalid.")
		return true
	}
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
	static OriginalLoader := _LLM_NavEventOwnerNativeEnsureLoaded
	if _LLM_NavEventOwnerNativeEnsureLoaded != OriginalLoader
			|| Object.Prototype.HasOwnProp.Call(OriginalLoader, "Call")
		throw Error("The original terminal route storage owner was withdrawn.")
	if !(Routes is Array)
		throw ValueError("A typed terminal route registry is required.")
	Loop Routes.Length
		if !Routes.Has(A_Index)
			throw ValueError("The terminal route registry contains a missing entry.")
	StorageBytes := OriginalLoader.Call("route_storage_size", Routes.Length)
	Bindings := Buffer(StorageBytes, 0)
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
	static OriginalLoader := _LLM_NavEventOwnerNativeEnsureLoaded
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
	if _LLM_NavEventOwnerNativeEnsureLoaded != OriginalLoader
			|| Object.Prototype.HasOwnProp.Call(OriginalLoader, "Call")
		throw Error("The original historical metadata owner was withdrawn.")
	; A derived stamp binds decoded diagnostic copies to one admitted lifetime.
	Snapshot["admission_stamp"] := OriginalLoader.Call("stamp_historical", Snapshot)
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
 * Resolves admitted metadata through its original retained canonical graph row.
 * @param {Map} Snapshot - Decoded FIFO receipt while its queue or hold still owns
 *   the recipe. Retired diagnostic copies intentionally lose stepping permission.
 * @param {String} State - Explicit neutral composition state of this subset.
 * @returns {Map} Canonical diagnostic Next/Output, never a delivery permission.
 */
LLM_NavEventOwner_StepTerminalRoute(Snapshot, State) {
	static OriginalLoader := _LLM_NavEventOwnerNativeEnsureLoaded
	if _LLM_NavEventOwnerNativeEnsureLoaded != OriginalLoader
			|| Object.Prototype.HasOwnProp.Call(OriginalLoader, "Call")
		throw Error("The original historical row owner was withdrawn.")
	Step := OriginalLoader.Call("step_historical", Map("snapshot", Snapshot, "state", State))
	return Map("Next", Step["Next"], "Output", Step["Output"],
		"metadata_only", true, "cohort_complete", false, "transformed_output_enabled", false)
}

_LLM_NavEventOwnerNativeRegisterTerminalRoutes(Owner, Generation, LayoutId, Bindings, Count,
		NativeOperation := unset) {
	global _LLM_NavEventOwnerStopping, _LLM_NavEventOwnerStopPending
	static OriginalLoader := _LLM_NavEventOwnerNativeEnsureLoaded
	if _LLM_NavEventOwnerStopping || _LLM_NavEventOwnerStopPending
		throw Error("Native terminal registration cannot cross stop admission.")
	if _LLM_NavEventOwnerNativeEnsureLoaded != OriginalLoader
			|| Object.Prototype.HasOwnProp.Call(OriginalLoader, "Call")
		throw Error("The original native registration constructor was withdrawn.")
	if !OriginalLoader.Call("allows_native_admission")
		throw Error("Native terminal registration cannot cross private stop admission.")
	if !(Owner is Integer) || Owner <= 0 || !(Generation is Integer) || Generation <= 0
			|| !(LayoutId is Integer) || LayoutId <= 0 || !(Bindings is Buffer)
			|| Bindings.Size != OriginalLoader.Call("route_storage_size", Count)
		throw ValueError("The terminal route native registration ABI is invalid.")
	if IsSet(NativeOperation)
		return NativeOperation.Call(Owner, Generation, LayoutId, Bindings, Count)
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
	global _LLM_NavEventOwnerStopping, _LLM_NavEventOwnerStopPending
	static OriginalLoader := _LLM_NavEventOwnerNativeEnsureLoaded
	if _LLM_NavEventOwnerStopping || _LLM_NavEventOwnerStopPending
		throw Error("Native start cannot cross stop admission.")
	if _LLM_NavEventOwnerNativeEnsureLoaded != OriginalLoader
			|| Object.Prototype.HasOwnProp.Call(OriginalLoader, "Call")
		throw Error("The original native start constructor was withdrawn.")
	if !OriginalLoader.Call("allows_native_admission")
		throw Error("Native start cannot cross private stop admission.")
	_LLM_NavEventOwnerNativeEnsureLoaded()
	Status := DllCall(_LLM_NavEventOwnerNativeExport("ErgoptiNav_Start"),
		"UInt64", Hwnd, "UInt", WakeMessage, "Int")
	; Read the original Win32 error before Stop resets native semantic state.
	try _LLM_NavEventOwnerNativeRequireOk(Status,
		"Navigation owner start")
	catch as StartError {
		try DllCall(_LLM_NavEventOwnerNativeExport(
			"ErgoptiNav_Stop"), "Int")
		catch as CleanupError {
			StartError.NativeCleanupError := CleanupError
			StartError.Message .= "; native stop cleanup failed: " . CleanupError.Message
		}
		throw StartError
	}
	if !LLM_NavEventOwner_RefreshTerminalRoutes()
		throw Error("Terminal route metadata registration was not admitted at startup.")
	return 1
}

_LLM_NavEventOwnerNativeStop(NativeOperation := unset) {
	global _LLM_NavEventOwnerModule
	if !_LLM_NavEventOwnerModule
		return 1
	Status := IsSet(NativeOperation) ? NativeOperation.Call()
		: DllCall(_LLM_NavEventOwnerNativeExport("ErgoptiNav_Stop"), "Int")
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

; Reads the counters of the native front-position reassertion. AutoHotkey puts
; its own hook ahead of the owner's at every SendInput; the owner reinstalls
; itself after each foreign Send burst, and these counters prove it did.
; @returns {Map} keys_seen, injected_armed, reinstalls, reinstall_failures,
;   last_failure_error, timer_high_resolution.
LLM_NavEventOwner_HookOrderStats() {
	Stats := Buffer(48, 0)
	NumPut("UInt", 48, Stats, 0)
	Status := DllCall(_LLM_NavEventOwnerNativeExport("ErgoptiNav_GetHookOrderStats"),
		"Ptr", Stats, "Int")
	_LLM_NavEventOwnerNativeRequireOk(Status, "Navigation owner hook order stats")
	return Map("timer_high_resolution", NumGet(Stats, 4, "UInt"),
		"keys_seen", NumGet(Stats, 8, "UInt64"), "injected_armed", NumGet(Stats, 16, "UInt64"),
		"reinstalls", NumGet(Stats, 24, "UInt64"), "reinstall_failures", NumGet(Stats, 32, "UInt64"),
		"last_failure_error", NumGet(Stats, 40, "UInt"))
}

; One counters-only record per native session: no key identity, no text.
_LLM_NavEventOwnerLogHookOrder() {
	try {
		Counts := LLM_NavEventOwner_HookOrderStats()
	} catch as Failure {
		try LoggerWarn("KeyboardArbiter", "stage=hook_order outcome=unreadable detail={1}.", Failure.Message)
		return
	}
	try LoggerDebug("KeyboardArbiter",
		"stage=hook_order keys={1} injected_armed={2} reinstalls={3} failures={4} last_error={5} hires={6}.",
		Counts["keys_seen"], Counts["injected_armed"], Counts["reinstalls"],
		Counts["reinstall_failures"], Counts["last_failure_error"], Counts["timer_high_resolution"])
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

/**
 * Admits native capture for one terminal hotstring transaction.
 * Admission runs synchronously inside the completing key's OnChar callback, so it
 * must stay a constant-time native call. It deliberately does not refresh the
 * terminal routes: a custody-checked registration rebuild re-validates the whole
 * canonical layout source and cost 300 ms to 900 ms per expansion, long enough
 * for keys typed meanwhile to interleave with the paced output. Captured edges
 * are replayed untransformed, so no hotstring transaction reads those routes;
 * Start registers them, and a future route reader owns refreshing them off the
 * keystroke path.
 * @param {Integer} Token Terminal transaction identity.
 * @returns {Integer} 1 when admitted, 0 when the owner is busy or registering.
 */
_LLM_NavEventOwnerNativeBeginTerminalCapture(Token) {
	global _LLM_NavEventOwnerTerminalRouteRefreshing, _LLM_NavEventOwnerTerminalRouteUnknown
	; A registration in progress or of uncertain native custody still refuses the
	; capture, exactly as the former inline refresh did.
	if _LLM_NavEventOwnerTerminalRouteRefreshing
		return 0
	if IsObject(_LLM_NavEventOwnerTerminalRouteUnknown)
		throw Error("Uncertain terminal registration retains its original native owner.")
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

_LLM_NavEventOwnerNativeEnsureLoaded(Request := "load", Payload := 0) {
	global _LLM_NavEventOwnerModule, _LLM_NavEventOwnerExports, _VendorDir
	global _LLM_NavEventOwnerRuntimeEpoch, _LLM_NavEventOwnerStarting
	global _LLM_NavEventOwnerStopping, _LLM_NavEventOwnerStopPending
	global _LLM_NavEventOwnerTerminalRouteRefreshing, _LLM_NavEventOwnerTerminalRouteUnknown
	global _LLM_NavEventOwnerTerminalRouteGeneration, _LLM_NavEventOwnerTerminalRouteNextRecipe
	global _LLM_NavEventOwnerTerminalRouteNextLayout, _LLM_NavEventOwnerTerminalRouteCoverage
	global _LLM_NavEventOwnerTerminalRouteRecipes, _LLM_NavEventOwnerTerminalRouteModels
	global _LLM_NavEventOwnerTerminalRouteOwner, KEYLAYOUT_NEUTRAL_STATE
	static IssuedModule := 0, IssuedExports := 0, OriginalExports := 0
	static ActiveFrame := 0, RetainedFrame := 0, ActiveStop := 0, Constructing := false
	static Scopes := Map(), NativeRegistrationDebt := false
	static HistoricalRows := Map(), HighestNativeRecipe := 0
	static NativeRegistrationSerial := 0, NextHistoricalStamp := 0
	static OriginalHistoricalValidate := _LLM_NavEventOwnerTerminalRouteValidate
	static OriginalDigitCapture := _LLM_NavEventOwnerCaptureDigitSource
	static OriginalCandidateCapture := _LLM_NavEventOwnerCaptureTerminalCandidate
	static OriginalCanonicalCapture := KeylayoutEmulation_CaptureCanonicalSource
	static OriginalCanonicalOwner := _KLE_CanonicalSourceOwner
	static CanonicalCall := Func.Prototype.Call
	static OriginalOwners := [
		_LLM_NavEventOwnerNativeEnsureLoaded, _LLM_NavEventOwnerNativeExport,
		_LLM_NavEventOwnerNativeRegisterTerminalRoutes, _LLM_NavEventOwnerNativeStop,
		_LLM_NavEventOwnerNativeStart,
		_LLM_NavEventOwnerNativeRequireOk, _LLM_NavEventOwnerPortFn,
		_LLM_NavEventOwnerTerminalRegistrationCapture, _LLM_NavEventOwnerTerminalRegistrationRetain,
		_LLM_NavEventOwnerTerminalRegistrationPlainMap, _LLM_NavEventOwnerTerminalRegistrationCurrent,
		_LLM_NavEventOwnerTerminalRegistrationRequire, _LLM_NavEventOwnerTerminalRegistrationUnknown,
		_LLM_NavEventOwnerTerminalRegistrationRefsCurrent, _LLM_NavEventOwnerTerminalRegistrationObjectsCurrent,
		_LLM_NavEventOwnerTerminalRegistrationBuildModelsCurrent, _LLM_NavEventOwnerTerminalRegistrationBytesCurrent,
		_LLM_NavEventOwnerTerminalRegistrationStatusKnown, _LLM_NavEventOwnerTerminalRoutePrune,
		_LLM_NavEventOwnerTerminalRegistrationAdvance, _LLM_NavEventOwnerTerminalRouteBuild,
		_LLM_NavEventOwnerTerminalRouteMarshal,
		_LLM_NavEventOwnerTerminalRouteSource, _LLM_NavEventOwnerTerminalRouteValidate,
		_LLM_NavEventOwnerTerminalRouteNextRecipeId, _LLM_NavEventOwnerTerminalRouteDescriptor,
		_LLM_NavEventOwnerTerminalRouteLayoutId, Keylayout_Resolve,
		_LLM_NavEventOwnerNativeListTerminalHeldRecipes,
		LLM_NavEventOwner_RefreshTerminalRoutes, LLM_NavEventOwner_Stop]

	OwnersCurrent() {
		Current := [_LLM_NavEventOwnerNativeEnsureLoaded, _LLM_NavEventOwnerNativeExport,
			_LLM_NavEventOwnerNativeRegisterTerminalRoutes, _LLM_NavEventOwnerNativeStop,
			_LLM_NavEventOwnerNativeStart,
			_LLM_NavEventOwnerNativeRequireOk, _LLM_NavEventOwnerPortFn,
			_LLM_NavEventOwnerTerminalRegistrationCapture, _LLM_NavEventOwnerTerminalRegistrationRetain,
			_LLM_NavEventOwnerTerminalRegistrationPlainMap, _LLM_NavEventOwnerTerminalRegistrationCurrent,
			_LLM_NavEventOwnerTerminalRegistrationRequire, _LLM_NavEventOwnerTerminalRegistrationUnknown,
			_LLM_NavEventOwnerTerminalRegistrationRefsCurrent, _LLM_NavEventOwnerTerminalRegistrationObjectsCurrent,
			_LLM_NavEventOwnerTerminalRegistrationBuildModelsCurrent, _LLM_NavEventOwnerTerminalRegistrationBytesCurrent,
			_LLM_NavEventOwnerTerminalRegistrationStatusKnown, _LLM_NavEventOwnerTerminalRoutePrune,
			_LLM_NavEventOwnerTerminalRegistrationAdvance, _LLM_NavEventOwnerTerminalRouteBuild,
			_LLM_NavEventOwnerTerminalRouteMarshal,
			_LLM_NavEventOwnerTerminalRouteSource, _LLM_NavEventOwnerTerminalRouteValidate,
			_LLM_NavEventOwnerTerminalRouteNextRecipeId, _LLM_NavEventOwnerTerminalRouteDescriptor,
			_LLM_NavEventOwnerTerminalRouteLayoutId, Keylayout_Resolve,
			_LLM_NavEventOwnerNativeListTerminalHeldRecipes,
			LLM_NavEventOwner_RefreshTerminalRoutes, LLM_NavEventOwner_Stop]
		for Index, Owner in OriginalOwners
			if Owner != Current[Index] || !(Owner is Func)
					|| Object.Prototype.HasOwnProp.Call(Owner, "Call")
				return false
		return true
	}

	PlainMap(Value) {
		if !(Value is Map) || ObjGetBase(Value) != Map.Prototype
			return false
		for Name in ObjOwnProps(Value)
			return false
		return true
	}

	EpochCurrent(Value) {
		return Value is Integer && Value >= 0 && _LLM_NavEventOwnerRuntimeEpoch is Integer
			&& _LLM_NavEventOwnerRuntimeEpoch >= 0 && Value == _LLM_NavEventOwnerRuntimeEpoch
	}

	ExportsCurrent() {
		if !OwnersCurrent() || !(IssuedModule is Integer) || IssuedModule <= 0
				|| !(_LLM_NavEventOwnerModule is Integer) || _LLM_NavEventOwnerModule <= 0
				|| _LLM_NavEventOwnerModule != IssuedModule
				|| !PlainMap(IssuedExports) || _LLM_NavEventOwnerExports != IssuedExports
			return false
		if IssuedExports.Count != OriginalExports.Count || IssuedExports.CaseSense != OriginalExports.CaseSense
			return false
		for Name, Address in OriginalExports
			if !(Address is Integer) || Address <= 0 || !IssuedExports.Has(Name)
					|| !(IssuedExports[Name] is Integer) || IssuedExports[Name] != Address
				return false
		return true
	}

	CountersCurrent(State) {
		return _LLM_NavEventOwnerTerminalRouteGeneration is Integer
			&& _LLM_NavEventOwnerTerminalRouteGeneration >= State.Generation
			&& _LLM_NavEventOwnerTerminalRouteNextRecipe is Integer
			&& _LLM_NavEventOwnerTerminalRouteNextRecipe >= State.NextRecipe
			&& _LLM_NavEventOwnerTerminalRouteNextLayout is Integer
			&& _LLM_NavEventOwnerTerminalRouteNextLayout >= State.NextLayout
	}

	FrameNativeCurrent(State) {
		return IsObject(State) && State.Genuine && ExportsCurrent()
			&& State.Module is Integer && State.Module > 0 && State.Module == IssuedModule
			&& State.Exports == IssuedExports && EpochCurrent(State.Epoch) && CountersCurrent(State)
	}

	RequiresNativeReceipt(State) {
		return State.Genuine || State.Module > 0 || IssuedModule > 0
	}

	FrameCustodyCurrent(State) {
		if !IsObject(State)
			return false
		; Unissued controlled ports own no C lifetime. Their validated Stop ACK
		; retires local references even after a source invalidated its old epoch.
		if !RequiresNativeReceipt(State)
			return State.Module is Integer && State.Module == 0
				&& State.Exports is Integer && State.Exports == 0
		if !EpochCurrent(State.Epoch) || !CountersCurrent(State)
			return false
		if State.Genuine
			return FrameNativeCurrent(State)
		return State.Module is Integer && State.Module >= 0
			&& (State.Module == 0 ? State.Exports is Integer && State.Exports == 0
				: ExportsCurrent() && State.Module == IssuedModule && State.Exports == IssuedExports)
	}

	ScopeCurrent(Operations) {
		if !PlainMap(Operations) || !Scopes.Has(Operations)
			return false
		Image := Scopes[Operations].Image
		if Operations.Count != Image.Count || Operations.CaseSense != Image.CaseSense
			return false
		for Name, Value in Image {
			if !Operations.Has(Name) || Type(Operations[Name]) != Type(Value) || Operations[Name] != Value
				return false
			if Name != "frame" && (!(Value is Func) || Object.Prototype.HasOwnProp.Call(Value, "Call"))
				return false
		}
		return true
	}



	StampHistorical(Snapshot) {
		if !OwnersCurrent() || !PlainMap(Snapshot)
			throw ValueError("The historical metadata owner was withdrawn.")
		Route := Snapshot.Get("route", 0)
		if Snapshot.Get("status", -1) != 0 || !PlainMap(Route)
				|| !PlainMap(_LLM_NavEventOwnerTerminalRouteRecipes)
				|| !HistoricalRows.Has(_LLM_NavEventOwnerTerminalRouteRecipes)
			return 0
		Registry := HistoricalRows[_LLM_NavEventOwnerTerminalRouteRecipes]
		Id := Route.Get("recipe_id", 0)
		if !(Id is Integer) || !Registry.Records.Has(Id)
			return 0
		Record := Registry.Records[Id]
		if !Record.CommitCell.Committed || !EpochCurrent(Record.Epoch)
				|| Record.Owner != _LLM_NavEventOwnerTerminalRouteOwner || Snapshot.Get("owner", 0) != Record.Owner
				|| Snapshot.Get("route_generation", 0) != Record.Generation || Snapshot.Get("route_layout_id", 0) != Record.Layout
				|| !_LLM_NavEventOwnerTerminalRouteRecipes.Has(Id) || _LLM_NavEventOwnerTerminalRouteRecipes[Id] != Record.Admission
				|| (Record.NativeCustody && !ExportsCurrent())
				|| Object.Prototype.HasOwnProp.Call(Record.Guard, "Call") || !Record.Guard.Call()
				|| !_LLM_NavEventOwnerTerminalRegistrationRefsCurrent(Route, Record.Descriptor)
			return 0
		return Record.Stamp
	}

	HistoricalStep(Payload) {
		if !OwnersCurrent() || !PlainMap(Payload) || !PlainMap(Payload.Get("snapshot", 0))
			throw ValueError("The historical terminal step has no original owner.")
		Snapshot := Payload["snapshot"], State := Payload.Get("state", 0)
		if !(State is String) || State != KEYLAYOUT_NEUTRAL_STATE
				|| !(Snapshot.Get("status", -1) is Integer) || Snapshot["status"] != 0
				|| !PlainMap(Snapshot.Get("event", 0)) || !PlainMap(Snapshot.Get("composition_before", 0))
				|| !(Snapshot["composition_before"].Get("dead_key_id", -1) is Integer)
				|| Snapshot["composition_before"]["dead_key_id"] != 0
			throw ValueError("The terminal recipe is outside the admitted neutral subset.")
		for Name in ["owner", "route_generation", "route_layout_id", "status"]
			if !Snapshot.Has(Name) || !(Snapshot[Name] is Integer)
				throw ValueError("The terminal recipe receipt has an invalid typed identity.")
		Event := Snapshot["event"]
		for Name in ["origin", "key_up", "repeat", "vk", "scan"]
			if !Event.Has(Name) || !(Event[Name] is Integer)
				throw ValueError("The terminal recipe event is malformed.")
		if Event["origin"] < 1 || Event["origin"] > 2 || Event["key_up"] != 0
				|| Event["repeat"] < 0 || Event["repeat"] > 1
			throw ValueError("The terminal recipe event provenance is unsupported.")
		Route := Snapshot.Get("route", 0)
		if !PlainMap(Route) || _LLM_NavEventOwnerTerminalRouteValidate != OriginalHistoricalValidate
				|| Object.Prototype.HasOwnProp.Call(OriginalHistoricalValidate, "Call")
			throw ValueError("The original terminal descriptor validator was withdrawn.")
		OriginalHistoricalValidate.Call(Route)
		if (Route["axis"] == 2 && Event["scan"] != Route["code"])
				|| (Route["axis"] == 1 && Event["vk"] != Route["code"])
			throw ValueError("The terminal recipe no longer describes its captured key.")
		if !PlainMap(Route) || !PlainMap(_LLM_NavEventOwnerTerminalRouteRecipes)
				|| !HistoricalRows.Has(_LLM_NavEventOwnerTerminalRouteRecipes)
			throw ValueError("The historical terminal dictionary was not issued.")
		Registry := HistoricalRows[_LLM_NavEventOwnerTerminalRouteRecipes]
		Id := Route.Get("recipe_id", 0)
		if !(Id is Integer) || !Registry.Records.Has(Id)
			throw ValueError("The historical terminal row is not retained.")
		Record := Registry.Records[Id]
		if !(Snapshot.Get("admission_stamp", 0) is Integer) || Snapshot["admission_stamp"] != Record.Stamp
				|| !Record.CommitCell.Committed || !EpochCurrent(Record.Epoch) || Record.Owner != _LLM_NavEventOwnerTerminalRouteOwner
				|| Snapshot.Get("owner", 0) != Record.Owner || Snapshot.Get("route_generation", 0) != Record.Generation
				|| Snapshot.Get("route_layout_id", 0) != Record.Layout || Payload.Get("state", 0) != Record.Neutral
				|| !PlainMap(_LLM_NavEventOwnerTerminalRouteModels) || Registry.Models != _LLM_NavEventOwnerTerminalRouteModels
				|| !_LLM_NavEventOwnerTerminalRouteRecipes.Has(Id)
				|| _LLM_NavEventOwnerTerminalRouteRecipes[Id] != Record.Admission
				|| !PlainMap(Record.Row) || (Record.NativeCustody && !ExportsCurrent())
				|| Object.Prototype.HasOwnProp.Call(Record.Guard, "Call") || !Record.Guard.Call()
				|| !_LLM_NavEventOwnerTerminalRegistrationRefsCurrent(Route, Record.Descriptor)
			throw ValueError("The historical terminal admission was withdrawn.")
		return Map("Next", Record.Neutral, "Output", Record.Row["output"])
	}

	HistoricalCustodyCurrent(Frame) {
		if !NativeRegistrationDebt
			return true
		if !ExportsCurrent() || Frame["next_recipe"] < HighestNativeRecipe
			return false
		for Dictionary, Registry in HistoricalRows
			for Id, Record in Registry.Records
				if Record.NativeCustody && (Dictionary != Frame["recipes"] || Registry.Models != Frame["models"]
						|| !EpochCurrent(Record.Epoch) || Frame["owner"] != Record.Owner
						|| Frame["generation"] < Record.Generation || Frame["next_layout"] < Record.Layout)
					return false
		return true
	}

	; Native start registers the terminal routes after ErgoptiNav_Start but before
	; Start publishes its runtime epoch. Those rows belong to the lifetime being
	; published, so they move with it; every other epoch change is a Stop, which
	; retires all rows. Without this, the first capture after a start reads its
	; own startup rows as a withdrawn historical owner.
	PublishStartEpoch(Payload) {
		if !OwnersCurrent() || !A_IsCritical || !_LLM_NavEventOwnerStarting
				|| _LLM_NavEventOwnerStopping || _LLM_NavEventOwnerStopPending
				|| _LLM_NavEventOwnerTerminalRouteRefreshing || Constructing
				|| IsObject(ActiveFrame) || IsObject(RetainedFrame) || IsObject(ActiveStop)
				|| IsObject(_LLM_NavEventOwnerTerminalRouteUnknown)
			throw Error("The start epoch cannot be published over an open registration.")
		if !PlainMap(Payload) || !(Payload.Get("from", "") is Integer) || !(Payload.Get("to", "") is Integer)
				|| Payload["from"] < 0 || Payload["to"] != Payload["from"] + 1 || !EpochCurrent(Payload["to"])
			throw ValueError("The published start epoch is invalid.")
		for Dictionary, Registry in HistoricalRows
			for Id, Record in Registry.Records
				if Record.Epoch == Payload["from"]
					Record.Epoch := Payload["to"]
		return true
	}

	CanonicalOwnersCurrent() {
		; Source admission is deliberately separate from native retirement custody.
		for Pair in [[OriginalCanonicalCapture, KeylayoutEmulation_CaptureCanonicalSource],
			[OriginalCanonicalOwner, _KLE_CanonicalSourceOwner], [CanonicalCall, Func.Prototype.Call]]
			if !(Pair[1] is Func) || Pair[1] != Pair[2]
					|| Object.Prototype.HasOwnProp.Call(Pair[1], "Call")
				return false
		return true
	}

	CanonicalCurrent(State) {
		if !CanonicalOwnersCurrent() || !IsObject(State) || !PlainMap(State.CanonicalSource)
			return false
		Guard := State.CanonicalSource.Get("current", 0)
		return Guard is BoundFunc && !Object.Prototype.HasOwnProp.Call(Guard, "Call")
			&& CanonicalCall.Call(Guard) && CanonicalOwnersCurrent()
	}

	BuildFrame() {
		if Constructing || !OwnersCurrent() || !A_IsCritical
				|| !_LLM_NavEventOwnerTerminalRouteRefreshing || _LLM_NavEventOwnerStopping
				|| _LLM_NavEventOwnerStopPending || IsObject(_LLM_NavEventOwnerTerminalRouteUnknown)
				|| IsObject(ActiveFrame) || IsObject(RetainedFrame) || IsObject(ActiveStop)
			throw Error("The native registration scope cannot be issued.")
		Constructing := true
		try {
			if !CanonicalOwnersCurrent()
				throw Error("The original canonical source capture owner was withdrawn.")
			; Capture even the inactive cell before any borrowed registration callout.
			CanonicalSource := CanonicalCall.Call(OriginalCanonicalCapture)
			if !CanonicalOwnersCurrent() || !PlainMap(CanonicalSource)
				throw Error("The original canonical source capture was not issued.")
			; Capture is invoked here, after the original-callable guard, never supplied.
			if !OwnersCurrent()
				throw Error("The original registration capture owner was withdrawn.")
			Frame := _LLM_NavEventOwnerTerminalRegistrationCapture()
			if !OwnersCurrent() || !PlainMap(Frame) || !EpochCurrent(_LLM_NavEventOwnerRuntimeEpoch)
				throw Error("The original registration capture is invalid.")
			if !HistoricalCustodyCurrent(Frame)
				throw Error("The retained historical native owner was withdrawn.")
			CapturedNative := ExportsCurrent()
			State := {DigitTried: false, DigitCaptured: false, DigitCell: 0, DigitGuard: 0, DigitModeGuard: 0,
				CandidateTried: false, CandidateCell: 0, CandidateGuard: 0,
				NativeSerial: NativeRegistrationSerial,
				CanonicalSource: CanonicalSource, RecordSet: Map(), CommitCell: {Committed: false}, HeldTried: false,
				HeldAuthentic: false, HeldKeep: 0, Pruned: false,
				Frame: Frame, Epoch: _LLM_NavEventOwnerRuntimeEpoch,
				Recipes: Frame["recipes"], Models: Frame["models"], Mode: "unselected",
				Genuine: false, Uncertain: false, Completed: false, Raw: "unobserved", Closed: false, Operations: 0,
				Module: CapturedNative ? IssuedModule : 0, Exports: CapturedNative ? IssuedExports : 0,
				Generation: Frame["generation"], NextRecipe: Frame["next_recipe"], NextLayout: Frame["next_layout"]}
			if !CanonicalCurrent(State)
				throw Error("The original canonical source changed during frame issuance.")
			Operations := Map("capture_digit_source", CaptureDigitSource, "seal_candidate", SealCandidate,
				"frame", Frame, "guard", GuardFrame, "custom", CustomRegistration,
				"native", NativeRegistration, "held", QueryFrameHeld, "protected", ProtectedHistorical,
				"prune", PrepareHistoricalPrune, "complete", CompleteFrame, "close", CloseFrame)
			Image := Operations.Clone()
			Scopes[Operations] := {Image: Image, Close: CloseFrame}
			State.Operations := Operations
			; All closure/image allocation succeeds before the active identity publishes.
			ActiveFrame := State
			return Operations
		} finally Constructing := false

		GuardFrame() {
			if ActiveFrame != State || State.Closed || !OwnersCurrent() || !ScopeCurrent(State.Operations)
				throw Error("The original registration dispatcher was withdrawn.")
			if !CanonicalCurrent(State) {
				if State.Mode != "unselected" || Frame["native_attempted"]
					State.Uncertain := true
				throw Error("The original canonical source changed during registration.")
			}
			if State.DigitCaptured && !DigitCurrent(State, false) {
				if State.Mode != "unselected" || Frame["native_attempted"]
					State.Uncertain := true
				throw Error("The original direct-digit source changed during registration.")
			}
		}

		CaptureDigitSource() {
			GuardFrame()
			if State.DigitTried
				throw Error("The registration frame already attempted source capture.")
			State.DigitTried := true
			if _LLM_NavEventOwnerCaptureDigitSource != OriginalDigitCapture
					|| Object.Prototype.HasOwnProp.Call(OriginalDigitCapture, "Call")
				throw Error("The original direct-digit capture helper was withdrawn.")
			Issued := OriginalDigitCapture.Call()
			GuardFrame()
			if _LLM_NavEventOwnerCaptureDigitSource != OriginalDigitCapture
					|| Object.Prototype.HasOwnProp.Call(OriginalDigitCapture, "Call")
					|| !PlainMap(Issued) || Issued.Count != 3
					|| !PlainMap(Issued.Get("source", 0))
					|| !(Issued.Get("current", 0) is BoundFunc)
					|| Object.Prototype.HasOwnProp.Call(Issued["current"], "Call")
					|| !(Issued.Get("mode_current", 0) is BoundFunc)
					|| Object.Prototype.HasOwnProp.Call(Issued["mode_current"], "Call")
				throw Error("The original direct-digit source capture was not issued.")
			; Private witnesses publish together only after complete pure capture.
			State.DigitCell := Issued["source"], State.DigitGuard := Issued["current"]
			State.DigitModeGuard := Issued["mode_current"]
			if !State.DigitModeGuard.Call()
				throw Error("The direct-digit source changed before issuance.")
			GuardFrame()
			Frame["digit_source"] := State.DigitCell
			State.DigitCaptured := true
			return State.DigitCell
		}

		SealCandidate() {
			GuardFrame()
			if !State.DigitCaptured || State.CandidateTried || State.Mode != "unselected"
				throw Error("The original candidate witness cannot be issued twice.")
			State.CandidateTried := true
			if _LLM_NavEventOwnerCaptureTerminalCandidate != OriginalCandidateCapture
					|| Object.Prototype.HasOwnProp.Call(OriginalCandidateCapture, "Call")
				throw Error("The original candidate witness constructor was withdrawn.")
			Candidate := Frame["candidate"]
			Witness := OriginalCandidateCapture.Call(Candidate, State.DigitCell, State.CanonicalSource)
			GuardFrame()
			if _LLM_NavEventOwnerCaptureTerminalCandidate != OriginalCandidateCapture
					|| Object.Prototype.HasOwnProp.Call(OriginalCandidateCapture, "Call")
					|| !(Witness is BoundFunc) || Object.Prototype.HasOwnProp.Call(Witness, "Call")
					|| !Witness.Call()
				throw Error("The original terminal candidate changed before witness issuance.")
			State.CandidateCell := Candidate, State.CandidateGuard := Witness
			Registry := HistoricalRows.Has(State.Recipes) ? HistoricalRows[State.Recipes] : 0
			for Id, Admission in Candidate["recipes"] {
				if (IsObject(Registry) && Id <= Registry.Highest) || (NativeRegistrationDebt && Id <= HighestNativeRecipe)
					throw ValueError("A historical terminal recipe identity cannot be reissued.")
				Recipe := Admission["recipe"], Row := 0, Model := 0
				if Recipe is Map {
					Row := CanonicalCall.Call(State.CanonicalSource["read"], "find", KEYLAYOUT_NEUTRAL_STATE,
						Recipe["scan"], Admission["route"]["required_modifiers"] == 4 ? 1 : 0)
					Model := Recipe["model"]
				}
				NextHistoricalStamp += 1
				if NextHistoricalStamp <= 0
					throw Error("The historical admission stamp overflowed.")
				State.RecordSet[Id] := {Stamp: NextHistoricalStamp, NativeCustody: false, Admission: Admission, Descriptor: Admission["route"].Clone(),
					Guard: Witness, CommitCell: State.CommitCell, Row: Row, Model: Model, Neutral: KEYLAYOUT_NEUTRAL_STATE,
					Epoch: State.Epoch, Owner: Frame["owner"], Generation: Admission["generation"],
					Layout: Admission["layout_id"], Genuine: false}
			}
			GuardFrame()
			if !Witness.Call()
				throw Error("The candidate changed during historical row capture.")
			return true
		}

		CustomRegistration() {
			GuardFrame()
			if !State.DigitCaptured || !(State.CandidateGuard is BoundFunc) || State.Mode != "unselected"
				throw Error("The registration scope already selected its boundary or lacks source capture.")
			State.Mode := "custom"
		}

		NativeRegistration(Owner, Generation, LayoutId, Bindings, Count) {
			GuardFrame()
			if !State.DigitCaptured || !(State.CandidateGuard is BoundFunc)
					|| State.Mode != "unselected" || !EpochCurrent(State.Epoch)
					|| !_LLM_NavEventOwnerTerminalRouteRefreshing
				throw Error("The original native registration scope was withdrawn.")
			State.Mode := "default"
			; Never repair or downgrade a revoked genuine issuance through public exports.
			if IssuedModule && !ExportsCurrent()
				throw Error("The issued native registration export image was withdrawn.")
			if !OwnersCurrent()
				throw Error("The original native loader owner was withdrawn.")
			_LLM_NavEventOwnerNativeEnsureLoaded()
			GenuineCall := ExportsCurrent()
			if GenuineCall {
				State.Module := IssuedModule, State.Exports := IssuedExports
				if !(_LLM_NavEventOwnerTerminalRouteGeneration is Integer)
						|| !(_LLM_NavEventOwnerTerminalRouteNextRecipe is Integer)
						|| !(_LLM_NavEventOwnerTerminalRouteNextLayout is Integer)
					throw Error("The native registration counter owners are invalid.")
				State.Generation := _LLM_NavEventOwnerTerminalRouteGeneration
				State.NextRecipe := _LLM_NavEventOwnerTerminalRouteNextRecipe
				State.NextLayout := _LLM_NavEventOwnerTerminalRouteNextLayout
				Address := OriginalExports["ErgoptiNav_RegisterTerminalRoutes"]
			} else {
				if IssuedModule || !OwnersCurrent()
					throw Error("The issued native registration export image changed.")
				Address := _LLM_NavEventOwnerNativeExport("ErgoptiNav_RegisterTerminalRoutes")
			}
			if !EpochCurrent(State.Epoch) || (IssuedModule && !ExportsCurrent())
				throw Error("The registration lifetime changed before its native call.")
			GuardFrame()
			State.Genuine := GenuineCall
			if GenuineCall {
				NativeRegistrationDebt := true
				NativeRegistrationSerial += 1
				if NativeRegistrationSerial <= 0
					throw Error("The native registration serial overflowed.")
				for Id in State.RecordSet
					HighestNativeRecipe := Max(HighestNativeRecipe, Id)
			}
			State.Raw := DllCall(Address, "UInt64", Owner, "UInt64", Generation,
				"UInt64", LayoutId, "Ptr", Bindings, "UInt", Count, "Int")
			return State.Raw
		}

		CompleteFrame() {
			GuardFrame()
			if !EpochCurrent(State.Epoch) || IsObject(_LLM_NavEventOwnerTerminalRouteUnknown)
					|| (State.Genuine && (!(State.Raw is Integer) || State.Raw != 0))
				throw Error("The registration scope cannot certify its final closure.")
			if !HistoricalRows.Has(State.Recipes)
				HistoricalRows[State.Recipes] := {Records: Map(), Models: State.Models, Highest: 0}
			Registry := HistoricalRows[State.Recipes]
			if Registry.Models != State.Models
				throw ValueError("The historical model dictionary was replaced.")
			for Id, Record in State.RecordSet {
				if Id <= Registry.Highest
					throw ValueError("A retired historical row cannot be admitted again.")
				Record.Genuine := State.Genuine
				Record.NativeCustody := State.Genuine || NativeRegistrationDebt
				if Record.NativeCustody
					HighestNativeRecipe := Max(HighestNativeRecipe, Id)
				Registry.Records[Id] := Record
				Registry.Highest := Id
			}
			State.Completed := true
			State.CommitCell.Committed := true
		}


		QueryFrameHeld(OutputBuffer) {
			GuardFrame()
			if !A_IsCritical || State.HeldTried || !(OutputBuffer is Buffer)
					|| ObjGetBase(OutputBuffer) != Buffer.Prototype || OutputBuffer.Size != 512
				throw ValueError("The original held-query output lifetime is invalid.")
			for Name in ObjOwnProps(OutputBuffer)
				throw ValueError("The held-query output cannot invoke an observer.")
			State.HeldTried := true
			if !ExportsCurrent()
				return _LLM_NavEventOwnerNativeListTerminalHeldRecipes(Frame["owner"], OutputBuffer, 64)
			NativeFrame := State.Genuine && State.Raw is Integer && State.Raw == 0 && FrameNativeCurrent(State)
			Count := 0
			Raw := DllCall(OriginalExports["ErgoptiNav_ListTerminalHeldRecipes"],
				"UInt64", Frame["owner"], "Ptr", OutputBuffer.Ptr, "UInt", 64, "UInt*", &Count, "Int")
			GuardFrame()
			if NativeFrame && !FrameNativeCurrent(State)
				throw Error("The genuine held-query lifetime was withdrawn.")
			if Raw == 0 && NativeFrame {
				if !(Count is Integer) || Count < 0 || Count > 64
					throw ValueError("The genuine held-query count is invalid.")
				Held := Map()
				Loop Count {
					Id := NumGet(OutputBuffer, (A_Index - 1) * 8, "UInt64")
					if Id <= 0 || Held.Has(Id) || !State.Recipes.Has(Id)
						throw ValueError("The genuine held-query row is unknown or duplicated.")
					Held[Id] := true
				}
				State.HeldKeep := Held, State.HeldAuthentic := true
			}
			return Map("status", Raw, "count", Count)
		}

		ProtectedHistorical() {
			GuardFrame()
			Recipes := [], Models := Map()
			if HistoricalRows.Has(State.Recipes) && !State.HeldAuthentic {
				for Id, Record in HistoricalRows[State.Recipes].Records {
					if !Record.NativeCustody
						continue
					Recipes.Push(Id)
					if Record.Model is Map
						Models[ObjPtr(Record.Model)] := true
				}
			}
			return Map("recipes", Recipes, "models", Models)
		}

		PrepareHistoricalPrune(Keep, KeepModels) {
			GuardFrame()
			if !A_IsCritical || State.Pruned || !PlainMap(Keep) || !PlainMap(KeepModels)
				throw ValueError("The historical prune request is invalid or duplicated.")
			if State.HeldAuthentic {
				if !State.Genuine || !(State.Raw is Integer) || State.Raw != 0 || !FrameNativeCurrent(State)
					throw Error("The genuine registration and held-query receipts changed.")
				Expected := State.HeldKeep.Clone()
				for Id in State.RecordSet
					Expected[Id] := true
				if !_LLM_NavEventOwnerTerminalRegistrationRefsCurrent(Keep, Expected)
					throw ValueError("The prune set differs from the genuine held-query receipt.")
			}
			Retire := []
			if HistoricalRows.Has(State.Recipes) {
				Registry := HistoricalRows[State.Recipes]
				for Id, Record in Registry.Records {
					if Record.NativeCustody && !State.HeldAuthentic && !Keep.Has(Id)
						throw ValueError("A supplied held reply cannot retire a genuine row.")
					if Keep.Has(Id) {
						if Record.NativeCustody && Record.Model is Map && !KeepModels.Has(ObjPtr(Record.Model))
							throw ValueError("The retained genuine model was omitted from pruning custody.")
					} else
						Retire.Push(Id)
				}
				; Eligibility retires before public deletion or any later publication callback.
				for Id in Retire
					Registry.Records.Delete(Id)
			}
			State.Pruned := true
			return true
		}

		KnownRefusal() {
			return State.Raw is Integer && (State.Raw == -1 || State.Raw == -2 || State.Raw == -3
				|| State.Raw == -4 || State.Raw == -5 || State.Raw == -6 || State.Raw == -9 || State.Raw == -11)
		}

		CloseFrame() {
			if ActiveFrame != State || State.Closed
				throw Error("The original registration scope cannot close twice.")
			State.Closed := true
			; Failed publication is still custody: absence of global Unknown is no ACK.
			if !State.Completed && (State.Uncertain || (State.Genuine && !KnownRefusal())
					|| (State.Mode == "custom" && NativeRegistrationSerial != State.NativeSerial))
				RetainedFrame := State
			ActiveFrame := 0
			Scopes.Delete(State.Operations)
			State.Operations := 0
		}
	}

	DigitCurrent(State, ObserveMode := true) {
		StateCurrent() {
			return IsObject(State) && ActiveFrame == State && !State.Closed
				&& OwnersCurrent() && ScopeCurrent(State.Operations) && PlainMap(State.Frame)
		}
		if !StateCurrent()
			return false
		if !State.DigitCaptured
			return State.Mode == "unselected" && !State.Frame["native_attempted"]
		Cell := State.DigitCell, Pure := State.DigitGuard, Policy := State.DigitModeGuard
		SourceCurrent() {
			return StateCurrent() && PlainMap(Cell) && State.DigitCell == Cell
				&& State.Frame.Get("digit_source", 0) == Cell
				&& State.DigitGuard == Pure && State.DigitModeGuard == Policy
				&& Pure is BoundFunc && Policy is BoundFunc
				&& !Object.Prototype.HasOwnProp.Call(Pure, "Call")
				&& !Object.Prototype.HasOwnProp.Call(Policy, "Call")
		}
		if !SourceCurrent() || !(ObserveMode ? Policy.Call() : Pure.Call()) || !SourceCurrent()
			return false
		if State.CandidateGuard is BoundFunc {
			Witness := State.CandidateGuard, Candidate := State.CandidateCell
			if !PlainMap(Candidate) || State.Frame.Get("candidate", 0) != Candidate
					|| Object.Prototype.HasOwnProp.Call(Witness, "Call") || !Witness.Call()
					|| !SourceCurrent() || State.CandidateCell != Candidate
					|| State.Frame.Get("candidate", 0) != Candidate || State.CandidateGuard != Witness
				return false
		}
		return SourceCurrent()
	}

	BuildStop(Snapshot) {
		if Constructing || !OwnersCurrent() || !A_IsCritical || !_LLM_NavEventOwnerStopping
				|| _LLM_NavEventOwnerStarting || _LLM_NavEventOwnerTerminalRouteRefreshing
				|| IsObject(ActiveFrame) || IsObject(ActiveStop) || !EpochCurrent(_LLM_NavEventOwnerRuntimeEpoch)
			throw Error("The native stop scope cannot be issued.")
		Ticket := {Frame: Snapshot, Snapshot: Snapshot, Missing: false,
			Epoch: _LLM_NavEventOwnerRuntimeEpoch, Mode: "unselected",
			Called: false, Raw: "unobserved", Genuine: false, Module: 0, Exports: 0,
			Closed: false, Operations: 0, State: RetainedFrame}
		if IsObject(RetainedFrame) && Snapshot is Integer && Snapshot == 0 {
			; The real Frame remains private even if its public publication failed.
			Ticket.Frame := RetainedFrame.Frame, Ticket.Missing := true
		}
		Operations := Map("guard", GuardStop, "custom", CustomStop, "native", NativeStop,
			"requires_native", RequiresNativeStop, "accept", AcceptTeardown, "settle", SettleStop, "close", CloseStop)
		Image := Operations.Clone()
		Scopes[Operations] := {Image: Image, Close: CloseStop}
		Ticket.Operations := Operations
		ActiveStop := Ticket
		return Operations

		GuardStop() {
			if ActiveStop != Ticket || Ticket.Closed || !OwnersCurrent() || !ScopeCurrent(Ticket.Operations)
				throw Error("The original native stop dispatcher was withdrawn.")
		}

		RequiresNativeStop() {
			GuardStop()
			return NativeRegistrationDebt
		}

		CustomStop() {
			GuardStop()
			if Ticket.Mode != "unselected"
				throw Error("The stop scope already selected its boundary.")
			Ticket.Mode := "custom"
		}

		UnknownCurrent() {
			if Ticket.Missing
				return Ticket.Snapshot is Integer && Ticket.Snapshot == 0
					&& _LLM_NavEventOwnerTerminalRouteUnknown is Integer && _LLM_NavEventOwnerTerminalRouteUnknown == 0
			return Type(_LLM_NavEventOwnerTerminalRouteUnknown) == Type(Ticket.Snapshot)
				&& _LLM_NavEventOwnerTerminalRouteUnknown == Ticket.Snapshot
		}

		NativeStop() {
			GuardStop()
			if Ticket.Mode != "unselected" || !_LLM_NavEventOwnerStopping
					|| _LLM_NavEventOwnerTerminalRouteRefreshing || !EpochCurrent(Ticket.Epoch)
					|| !UnknownCurrent()
				throw Error("The original native stop scope was withdrawn.")
			Ticket.Mode := "default", Ticket.Called := true
			if IssuedModule && !ExportsCurrent()
				throw Error("The issued native stop export image was withdrawn.")
			Ticket.Genuine := ExportsCurrent()
			if IsObject(Ticket.State)
					&& (RetainedFrame != Ticket.State || Ticket.State.Frame != Ticket.Frame
						|| !FrameCustodyCurrent(Ticket.State))
				throw Error("The retained native registration lifetime changed.")
			if Ticket.Genuine {
				Ticket.Module := IssuedModule, Ticket.Exports := IssuedExports
				Address := OriginalExports["ErgoptiNav_Stop"]
			} else {
				if IssuedModule || !OwnersCurrent()
					throw Error("The issued native stop export image changed.")
				Address := _LLM_NavEventOwnerNativeExport("ErgoptiNav_Stop")
			}
			Ticket.Raw := DllCall(Address, "Int")
			return Ticket.Raw
		}

		ReceiptCurrent() {
			return ActiveStop == Ticket && !Ticket.Closed && A_IsCritical
				&& _LLM_NavEventOwnerStopping && !_LLM_NavEventOwnerTerminalRouteRefreshing
				&& ScopeCurrent(Ticket.Operations) && Ticket.Mode == "default"
				&& Ticket.Called && Ticket.Genuine && Ticket.Raw is Integer
				&& (Ticket.Raw == 0 || Ticket.Raw == 10) && EpochCurrent(Ticket.Epoch)
				&& ExportsCurrent() && Ticket.Module is Integer && Ticket.Module > 0
				&& Ticket.Module == IssuedModule && Ticket.Exports == IssuedExports
		}

		AcceptTeardown() {
			GuardStop()
			if !A_IsCritical || !_LLM_NavEventOwnerStopping || _LLM_NavEventOwnerTerminalRouteRefreshing
				return false
			; Completed registration retains C debt until its actual Stop receipt.
			if NativeRegistrationDebt && !ReceiptCurrent()
				return false
			State := Ticket.State
			if !IsObject(State)
				return !IsObject(Ticket.Frame) && UnknownCurrent() && EpochCurrent(Ticket.Epoch)
			return RetainedFrame == State && State.Frame == Ticket.Frame
				&& UnknownCurrent() && FrameCustodyCurrent(State) && EpochCurrent(Ticket.Epoch)
				&& (!RequiresNativeReceipt(State) || ReceiptCurrent())
		}

		SettleStop() {
			GuardStop()
			if !AcceptTeardown()
				return false
			if ReceiptCurrent()
				NativeRegistrationDebt := false
			OwnedProjection := false
			for Dictionary, Registry in HistoricalRows {
				if _LLM_NavEventOwnerTerminalRouteRecipes == Dictionary {
					_LLM_NavEventOwnerTerminalRouteRecipes := Map()
					OwnedProjection := true
				}
				if _LLM_NavEventOwnerTerminalRouteModels == Registry.Models {
					_LLM_NavEventOwnerTerminalRouteModels := Map()
					OwnedProjection := true
				}
			}
			if OwnedProjection
				_LLM_NavEventOwnerTerminalRouteCoverage := Map(
					"generation", 0, "layout_id", 0, "registered", 0,
					"cohort_complete", false, "transformed_output_enabled", false,
					"unconverted", ["native terminal owner retired"])
			HistoricalRows := Map(), HighestNativeRecipe := 0
			State := Ticket.State
			if !IsObject(State)
				return true
			_LLM_NavEventOwnerTerminalRouteCoverage := Map(
				"generation", 0, "layout_id", 0, "registered", 0,
				"cohort_complete", false, "transformed_output_enabled", false,
				"unconverted", ["native terminal owner retired"])
			if _LLM_NavEventOwnerTerminalRouteRecipes == State.Recipes
				_LLM_NavEventOwnerTerminalRouteRecipes := Map()
			if _LLM_NavEventOwnerTerminalRouteModels == State.Models
				_LLM_NavEventOwnerTerminalRouteModels := Map()
			if !Ticket.Missing
				_LLM_NavEventOwnerTerminalRouteUnknown := 0
			RetainedFrame := 0
			return true
		}

		CloseStop() {
			if ActiveStop != Ticket || Ticket.Closed
				throw Error("The original stop scope cannot close twice.")
			Ticket.Closed := true
			ActiveStop := 0
			Scopes.Delete(Ticket.Operations)
			Ticket.Operations := 0, Ticket.Frame := 0, Ticket.State := 0
		}
	}

	; Retention grants no native authority and survives a withdrawn callable.
	if Request == "retain_frame" {
		if !IsObject(ActiveFrame) || ActiveFrame.Closed || ActiveFrame.Frame != Payload
			return false
		ActiveFrame.Uncertain := true
		return true
	}

	; Cleanup uses only an issued scope identity and its private original closure.
	; It grants no native receipt and can unwind after a public callable withdrawal.
	if Request == "close_scope" {
		if !Scopes.Has(Payload)
			return false
		Func.Prototype.Call.Call(Scopes[Payload].Close)
		return true
	}
	if Request == "owns_scope"
		return OwnersCurrent() && ScopeCurrent(Payload)
	if Request == "stamp_historical"
		return StampHistorical(Payload)
	if Request == "step_historical"
		return HistoricalStep(Payload)
	if Request == "frame_held" || Request == "protected_historical" || Request == "prune_historical" {
		if !PlainMap(Payload) || !IsObject(ActiveFrame) || ActiveFrame.Frame != Payload.Get("frame", 0)
				|| !ScopeCurrent(ActiveFrame.Operations) || !CanonicalCurrent(ActiveFrame)
			throw ValueError("The historical frame request was not genuinely issued.")
		Original := Scopes[ActiveFrame.Operations].Image
		if Request == "frame_held"
			return Original["held"].Call(Payload["buffer"])
		if Request == "protected_historical"
			return Original["protected"].Call()
		return Original["prune"].Call(Payload["keep"], Payload["models"])
	}
	if Request == "guard_frame"
		return OwnersCurrent() && IsObject(ActiveFrame) && PlainMap(Payload)
			&& ActiveFrame.Frame == Payload && ScopeCurrent(ActiveFrame.Operations)
			&& CanonicalCurrent(ActiveFrame)
	; UInt32 count times the forty-byte x64 descriptor fits signed64-bit arithmetic.
	; This admission calculation adds no callable dependency to genuine Stop.
	if Request == "route_storage_size" {
		if !OwnersCurrent()
			throw Error("The original terminal route storage owner was withdrawn.")
		if !(Payload is Integer) || Payload < 0 || Payload > 0xFFFFFFFF
			throw ValueError("The terminal route descriptor count is invalid.")
		return Payload * 40
	}
	if Request == "digit_current"
		return IsObject(ActiveFrame) && ActiveFrame.Frame == Payload
			&& CanonicalCurrent(ActiveFrame) && DigitCurrent(ActiveFrame) && CanonicalCurrent(ActiveFrame)
	if Request == "allows_native_admission"
		return OwnersCurrent() && !IsObject(ActiveStop) && !Constructing
	if Request == "publish_start_epoch"
		return PublishStartEpoch(Payload)
	if Request == "begin_frame" {
		if !((Payload is Integer) && Payload == 0)
			throw ValueError("Frame construction accepts no supplied authority.")
		return BuildFrame()
	}
	if Request == "begin_stop"
		return BuildStop(Payload)
	if Request == "export" {
		_LLM_NavEventOwnerNativeEnsureLoaded()
		if !_LLM_NavEventOwnerExports.Has(Payload)
			throw Error("Navigation owner DLL export is unavailable")
		Address := _LLM_NavEventOwnerExports[Payload]
		; The direct ABI also owns registration storage without an AHK Frame.
		if IssuedModule && Address == OriginalExports["ErgoptiNav_RegisterTerminalRoutes"] {
			NativeRegistrationDebt := true
			NativeRegistrationSerial += 1
			if NativeRegistrationSerial <= 0
				throw Error("The native registration serial overflowed.")
		}
		return Address
	}
	if Request != "load"
		throw ValueError("The native owner constructor request is invalid.")

	; A real issuance is immutable for this process, including ordinary load calls.
	; Public module zero or a foreign export image must never issue a new lifetime.
	if IssuedModule {
		if !ExportsCurrent()
			throw Error("The process-resident native issuance was withdrawn.")
		return true
	}
	; Preserve controlled unissued adapter calls; these confer no genuine authority.
	if _LLM_NavEventOwnerModule
		return true
	if !OwnersCurrent()
		throw Error("The original native loader owner was withdrawn.")
	if A_PtrSize != 8
		throw Error("Navigation owner requires a 64-bit process")
	Path := _VendorDir . "\ergopti_nav_owner.dll"
	Module := DllCall("Kernel32\LoadLibraryW", "Str", Path, "Ptr")
	if !(Module is Integer) || Module <= 0
		throw Error("Navigation owner DLL could not be loaded")
	Names := [
		"ErgoptiEditor_Begin", "ErgoptiEditor_Poll", "ErgoptiEditor_Decide", "ErgoptiEditor_Close",
		"ErgoptiNav_Start", "ErgoptiNav_Stop", "ErgoptiNav_PreparePlan", "ErgoptiNav_CommitPlan",
		"ErgoptiNav_SetSuspended", "ErgoptiNav_CanStop", "ErgoptiNav_BeginTerminalCapture",
		"ErgoptiNav_CommitTerminalCapture", "ErgoptiNav_AbortTerminalCapture", "ErgoptiNav_GetTerminalCapture",
		"ErgoptiNav_BeginTerminalCaptureOwned", "ErgoptiNav_GetTerminalCaptureOwned",
		"ErgoptiNav_PeekTerminalRouteOwned", "ErgoptiNav_ReleaseTerminalCaptureOwned",
		"ErgoptiNav_StartHookTrace", "ErgoptiNav_ReadHookTrace", "ErgoptiNav_StopHookTrace",
		"ErgoptiNav_RegisterTerminalRoutes", "ErgoptiNav_PeekTerminalRoute", "ErgoptiNav_ListTerminalHeldRecipes",
		"ErgoptiNav_PreviewTerminalOutput", "ErgoptiNav_PlanTerminalOutput", "ErgoptiNav_BeginTerminalOutputAttempt",
		"ErgoptiNav_AcknowledgeTerminalOutput", "ErgoptiNav_ConsumeTerminalOutput", "ErgoptiNav_CancelTerminalOutput",
		"ErgoptiNav_SerializeTerminalOutputAttempt", "ErgoptiNav_BeginOwnerSwap", "ErgoptiNav_CommitOwnerSwap",
		"ErgoptiNav_AbortOwnerSwap", "ErgoptiNav_ClaimOwner", "ErgoptiNav_GetOwner", "ErgoptiNav_PollReceipt",
		"ErgoptiNav_BeginProfileSwap", "ErgoptiNav_CommitProfileSwap", "ErgoptiNav_AbortProfileSwap",
		"ErgoptiNav_ProfilePendingMask", "ErgoptiNav_CompleteReceipt", "ErgoptiNav_PendingForToken",
		"ErgoptiNav_GetLastOsError", "ErgoptiNav_GetHookOrderStats", "ErgoptiNav_TestDispatch"]
	Exports := Map()
	try {
		for Name in Names {
			Address := DllCall("Kernel32\GetProcAddress", "Ptr", Module, "AStr", Name, "Ptr")
			if !(Address is Integer) || Address <= 0
				throw Error("Navigation owner DLL export is missing")
			Exports[Name] := Address
		}
		if !OwnersCurrent()
			throw Error("The original native loader owner was withdrawn.")
		Detached := Exports.Clone()
	} catch as Err {
		DllCall("Kernel32\FreeLibrary", "Ptr", Module, "Int")
		throw Err
	}
	_LLM_NavEventOwnerModule := Module, _LLM_NavEventOwnerExports := Exports
	IssuedModule := Module, IssuedExports := Exports, OriginalExports := Detached
	return true
}

_LLM_NavEventOwnerNativeExport(Name) {
	return _LLM_NavEventOwnerNativeEnsureLoaded("export", Name)
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
