; adapters/timer_scheduler.ahk

; ==============================================================================
; MODULE: TimerScheduler Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the TimerScheduler port contract defined in
; static/ergopti_plus/_shared/core/ports/TimerScheduler.spec.js. Wraps AHK's SetTimer
; behind four canonical methods (TimerAfter, TimerEvery, TimerCancel,
; TimerCancelAll) so domain modules can schedule deferred work without
; calling SetTimer directly.
;
; NAMING CONVENTION:
; AHK v2 has no namespaces, so all exported names are prefixed with "Timer"
; to avoid collisions. Port method → AHK name mapping:
;   after(delay, fn)    → TimerAfter(DelaySec, Fn)
;   every(interval, fn) → TimerEvery(IntervalSec, Fn)
;   cancel(handle)      → TimerCancel(Handle)
;   cancelAll()         → TimerCancelAll()
;
; HANDLE SHAPE:
; An opaque Map { Fn: <bound-fn>, Interval: <ms>, Fired: false } returned
; by TimerAfter/TimerEvery. Callers must pass this to TimerCancel; the
; adapter never exposes the raw timer function name to callers.
; ==============================================================================




; =====================================================
; =====================================================
; ======= 1/ Internal Handle Registry =================
; =====================================================
; =====================================================

; Strong ownership registry of all live timer handles — allows TimerCancelAll to
; drain without requiring the caller to track every handle individually.
global _TIMER_ADAPTER_REGISTRY := Map()
global _TIMER_ADAPTER_NEXT_ID  := 0
global TIMER_ADAPTER_MAX_INTERVAL_MS := 0xFFFFFFFF


; Allocates a new unique handle ID.
_TimerAdapterNextId() {
	global _TIMER_ADAPTER_NEXT_ID
	_TIMER_ADAPTER_NEXT_ID += 1
	return _TIMER_ADAPTER_NEXT_ID
}

_TimerAdapterSetNative(BoundFn, IntervalMs) {
	SetTimer(BoundFn, IntervalMs)
}

_TimerAdapterCancelNative(BoundFn) {
	SetTimer(BoundFn, 0)
}

/** Schedules or cancels an owned native callback without replacing its identity. */
TimerSetCallback(Callback, PeriodMs) {
	global TIMER_ADAPTER_MAX_INTERVAL_MS
	if !HasMethod(Callback, "Call")
		throw TypeError("TimerSetCallback requires a callable callback")
	if !IsNumber(PeriodMs) || PeriodMs != Round(PeriodMs)
		|| Abs(PeriodMs) > TIMER_ADAPTER_MAX_INTERVAL_MS
		throw ValueError("TimerSetCallback requires an integer native timer period")
	_TimerAdapterSetNative(Callback, PeriodMs)
	return true
}

_TimerAdapterCommitNative(Handle, BoundFn, IntervalMs, NativeSetFn := 0) {
	global _TIMER_ADAPTER_REGISTRY
	if !HasMethod(NativeSetFn, "Call")
		NativeSetFn := _TimerAdapterSetNative
	Failure := 0, RollbackFailure := 0
	PreviousCritical := Critical("On")
	try {
		; Admission and publication cannot be interrupted by the newly armed timer.
		NativeSetFn.Call(BoundFn, IntervalMs)
		_TIMER_ADAPTER_REGISTRY[Handle["Id"]] := Handle
	} catch as Err {
		Failure := Err
		; An exception alone cannot prove that an admission did not arm the timer.
		; Retain a reachable cancellation capability until this exact rollback ACK.
		try NativeSetFn.Call(BoundFn, 0)
		catch as CancelErr
			RollbackFailure := CancelErr
		if IsObject(RollbackFailure) {
			; Keep cancellation debt reachable without authorizing rejected work.
			Handle["Fired"] := true
			_TIMER_ADAPTER_REGISTRY[Handle["Id"]] := Handle
		} else {
			Handle["Fired"] := true
			Handle["Fn"] := 0
			if _TIMER_ADAPTER_REGISTRY.Has(Handle["Id"])
				&& _TIMER_ADAPTER_REGISTRY[Handle["Id"]] == Handle
				_TIMER_ADAPTER_REGISTRY.Delete(Handle["Id"])
		}
	} finally Critical(PreviousCritical)
	if IsObject(RollbackFailure)
		Failure.Message .= " Native rollback also failed: " . RollbackFailure.Message
	if IsObject(Failure)
		throw Failure
	return Handle
}

_TimerAdapterDurationMs(DurationSec, ParamName) {
	if !IsNumber(DurationSec)
		throw TypeError(ParamName . " must be numeric.")
	if (DurationSec <= 0)
		throw ValueError(ParamName . " must be greater than zero.")
	if (DurationSec > TIMER_ADAPTER_MAX_INTERVAL_MS / 1000)
		throw ValueError(ParamName . " exceeds the native timer range.")
	Ms := Round(DurationSec * 1000)
	if (Ms < 1 or Ms > TIMER_ADAPTER_MAX_INTERVAL_MS)
		throw ValueError(ParamName . " must resolve to 1-4294967295 milliseconds.")
	return Ms
}




; =====================================================
; =====================================================
; ======= 2/ Adapter Methods ==========================
; =====================================================
; =====================================================

; Schedules Fn to fire once after DelaySec seconds.
; Returns an opaque handle Map that can be passed to TimerCancel.
;
; RE-REGISTRATION WARNING: Each call allocates a NEW OS timer handle. Calling
; TimerAfter() twice with the same Fn registers TWO independent timers — the
; first handle no longer cancels the second. Always call TimerCancel(handle)
; before calling TimerAfter() again if you intend to replace an existing timer.
;
; @param DelaySec   {Float}    Delay in seconds (fractional values accepted).
; @param Fn         {Callable} Zero-arity function to invoke.
; @return {Map}  Opaque cancellation handle.
TimerAfter(DelaySec, Fn) {
	global _TIMER_ADAPTER_REGISTRY
	Ms := _TimerAdapterDurationMs(DelaySec, "DelaySec")
	if !HasMethod(Fn, "Call")
		throw TypeError("TimerAfter requires a callable callback.")
	Handle := Map("Fn", 0, "Interval", 0, "Fired", false,
		"Id", _TimerAdapterNextId(), "Kind", "after", "UserCallback", Fn,
		"WrapperEpoch", 1, "ArmEpoch", 1, "RequeueSerial", 0, "PrimaryArmed", true)
	; Convert seconds to the negative milliseconds AHK uses for one-shot timers.
	Ms := -Ms
	; Wrap Fn in a closure that marks the handle fired and calls the user callback.
	BoundFn := _TimerAdapterMakeOneShot(Handle, Fn)
	Handle["Fn"] := BoundFn
	Handle["Interval"] := Ms
	try _TimerAdapterCommitNative(Handle, BoundFn, Ms)
	catch as Err {
		try LoggerError("TimerScheduler", "one-shot schedule failed: {1}", Err.Message)
		throw Err
	}
	return Handle
}

; Re-arms an existing one-shot handle with the same callback. This is the
; allocation-free counterpart to cancel()+after() while the handle is active.
; Its wrapper identity stays stable across active restarts. After acknowledged
; retirement a new wrapper preserves the opaque handle and original user callback.
;
; @param Handle   {Map}   Token returned by TimerAfter.
; @param DelaySec {Float} New delay in seconds.
; @return {Map} The same handle identity, now live again.
TimerRestartAfter(Handle, DelaySec) {
	global _TIMER_ADAPTER_REGISTRY
	if !(Handle is Map) or !Handle.Has("Fn") or !Handle.Has("Id")
		throw TypeError("TimerRestartAfter requires a TimerAfter handle.")
	if Handle.Get("Kind", "") != "after"
		throw TypeError("TimerRestartAfter cannot re-arm a repeating timer.")
	Ms := -_TimerAdapterDurationMs(DelaySec, "DelaySec")
	Failure := 0
	PreviousCritical := Critical("On")
	try {
		BoundFn := Handle["Fn"]
		UserCallback := Handle["UserCallback"]
		if !HasMethod(UserCallback, "Call")
			throw TypeError("TimerRestartAfter handle has no callable user callback.")
		RequeuedFn := Handle.Get("RequeuedFn", 0)
		if Handle.Has("RequeuedFn") {
			try _TimerAdapterCancelNative(Handle["RequeuedFn"])
			catch as Err {
				Failure := Err
				throw Err
			}
			Handle.Delete("RequeuedFn")
		}
		; A retired wrapper must not keep its handle alive. Rebuild only after
		; terminal ACK; an ACTIVE restart retains its exact native callback.
		if BoundFn == 0 {
			Handle["WrapperEpoch"] += 1
			BoundFn := _TimerAdapterMakeOneShot(Handle, UserCallback)
			Handle["Fn"] := BoundFn
		} else if !HasMethod(BoundFn, "Call")
			throw TypeError("TimerRestartAfter handle has no callable owner.")
		Handle["ArmEpoch"] += 1
		Handle["RequeueSerial"] += 1
		Handle["PrimaryArmed"] := true
		Handle["Interval"] := Ms
		Handle["Fired"] := false
		try _TimerAdapterCommitNative(Handle, BoundFn, Ms)
		catch as Err {
			Failure := Err
			throw Err
		}
		return Handle
	} finally {
		Critical(PreviousCritical)
		if IsObject(Failure)
			try LoggerError("TimerScheduler", "one-shot restart failed: {1}", Failure.Message)
	}
}

; Schedules Fn to fire repeatedly every IntervalSec seconds.
; The first firing happens after IntervalSec (not immediately).
;
; RE-REGISTRATION WARNING: Each call allocates a NEW OS timer handle. Calling
; TimerEvery() twice with the same Fn registers TWO independent timers — the
; first handle no longer cancels the second. Always call TimerCancel(handle)
; before calling TimerEvery() again if you intend to replace an existing timer.
;
; @param IntervalSec {Float}    Repeat interval in seconds.
; @param Fn          {Callable} Zero-arity function to invoke.
; @return {Map}  Opaque cancellation handle.
TimerEvery(IntervalSec, Fn) {
	global _TIMER_ADAPTER_REGISTRY
	Ms := _TimerAdapterDurationMs(IntervalSec, "IntervalSec")
	if !HasMethod(Fn, "Call")
		throw TypeError("TimerEvery requires a callable callback.")
	Handle := Map("Fn", 0, "Interval", 0, "Fired", false,
		"Id", _TimerAdapterNextId(), "Kind", "every", "UserCallback", Fn,
		"WrapperEpoch", 1, "ArmEpoch", 1)
	; Wrap Fn so uncaught exceptions are logged without crashing the timer thread.
	BoundFn := _TimerAdapterMakeRepeating(Handle, Fn)
	Handle["Fn"] := BoundFn
	Handle["Interval"] := Ms
	try _TimerAdapterCommitNative(Handle, BoundFn, Ms)
	catch as Err {
		try LoggerError("TimerScheduler", "repeating schedule failed: {1}", Err.Message)
		throw Err
	}
	return Handle
}

; Cancels a previously scheduled timer. Safe to call on a nil or already-fired handle.
; Also cancels any pending re-queue timer created when the script was suspended.
; @param Handle {Map|0} Token returned by TimerAfter or TimerEvery.
; @param NativeCancelFn {Callable|0} Test seam for native cancellation.
; @return {Boolean} True only after every native callback owner was released.
TimerCancel(Handle, NativeCancelFn := 0) {
	global _TIMER_ADAPTER_REGISTRY
	if !(Handle is Map)
		return true
	if !HasMethod(NativeCancelFn, "Call")
		NativeCancelFn := _TimerAdapterCancelNative
	CancelErrors := []
	PreviousCritical := Critical("On")
	try {
		BoundFn := Handle.Get("Fn", 0)
		RequeuedFn := Handle.Get("RequeuedFn", 0)
		ArmEpoch := Handle.Get("ArmEpoch", 0)
		if BoundFn != 0 {
			try NativeCancelFn.Call(BoundFn)
			catch as Err
				CancelErrors.Push("timer cancellation failed: " . Err.Message)
		}
		if RequeuedFn != 0 {
			try NativeCancelFn.Call(RequeuedFn)
			catch as Err
				CancelErrors.Push("re-queued timer cancellation failed: " . Err.Message)
		}
		if CancelErrors.Length = 0 {
			if Handle.Get("Fn", 0) == BoundFn
				&& Handle.Get("RequeuedFn", 0) == RequeuedFn
				&& Handle.Get("ArmEpoch", 0) == ArmEpoch {
				Handle["Fired"] := true
				Handle["Fn"] := 0
				if Handle.Has("RequeuedFn")
					Handle.Delete("RequeuedFn")
				Id := Handle.Get("Id", 0)
				if Id != 0 and _TIMER_ADAPTER_REGISTRY.Has(Id)
					&& _TIMER_ADAPTER_REGISTRY[Id] == Handle
					_TIMER_ADAPTER_REGISTRY.Delete(Id)
			} else
				CancelErrors.Push("timer ownership changed during cancellation")
		}
	} finally Critical(PreviousCritical)
	for Message in CancelErrors
		try LoggerWarn("TimerScheduler", Message)
	return CancelErrors.Length = 0
}

; Cancels every timer owned by this adapter. Safe to call at any time.
TimerCancelAll() {
	global _TIMER_ADAPTER_REGISTRY
	AllCancelled := true
	for Id, Handle in _TIMER_ADAPTER_REGISTRY.Clone() {
		if !TimerCancel(Handle)
			AllCancelled := false
	}
	return AllCancelled
}

; Arms a native one-shot while preserving the caller's callback identity. This
; is intentionally outside the portable TimerScheduler port: lifecycle state
; machines use the same named callback as a coalescing owner, whereas TimerAfter
; wraps every request in a fresh closure and therefore cannot replace an already
; armed retry. Domain code still stays decoupled from AHK's negative-interval
; SetTimer convention.
TimerArmOneShotMs(Callback, DelayMs) {
	if !HasMethod(Callback, "Call")
		throw TypeError("TimerArmOneShotMs requires a callable callback")
	if !IsNumber(DelayMs)
		throw TypeError("TimerArmOneShotMs requires a numeric delay")
	Delay := Max(1, Round(Abs(DelayMs)))
	try {
		_TimerAdapterSetNative(Callback, -Delay)
		return true
	} catch as Err {
		try LoggerError("TimerScheduler", "native one-shot schedule failed: {1}", Err.Message)
		throw Err
	}
}

; Returns the count of currently live (non-fired, non-cancelled) timer handles
; tracked by this adapter. Intended for diagnostics and tests.
; @return {Integer} Number of active timer handles.
TimerActiveCount() {
	global _TIMER_ADAPTER_REGISTRY
	Count := 0
	for Id, Handle in _TIMER_ADAPTER_REGISTRY {
		if Handle is Map and !(Handle.Has("Fired") and Handle["Fired"]) {
			Count += 1
		}
	}
	return Count
}




; ==============================================
; ==============================================
; ======= 3/ Internal Callback Wrappers ========
; ==============================================
; ==============================================

; Builds a one-shot wrapper that marks the handle fired before invoking Fn.
; AHK v2 closures capture variables by reference, so BoundHandle is passed
; explicitly via Bind to freeze it at creation time.
_TimerAdapterMakeOneShot(Handle, Fn, ChildSerial := 0) {
	_OneShot(BoundHandle, WrapperEpoch, RequeueSerial) {
		global _TIMER_ADAPTER_REGISTRY
		Failure := 0, CleanupFailure := 0
		PreviousCritical := Critical("On")
		try {
			if BoundHandle["Fired"] || BoundHandle["WrapperEpoch"] != WrapperEpoch
				return
			Id := BoundHandle["Id"]
			if !_TIMER_ADAPTER_REGISTRY.Has(Id) || _TIMER_ADAPTER_REGISTRY[Id] != BoundHandle
				return
			if RequeueSerial {
				if RequeueSerial != BoundHandle["RequeueSerial"] || !BoundHandle.Has("RequeuedFn")
					return
			} else if !BoundHandle["PrimaryArmed"]
				return
			; Strong old references survive retirement and Critical restoration. No
			; cleanup after the user callback can erase its reentrant successor.
			OldFn := BoundHandle["Fn"]
			OldRequeuedFn := BoundHandle.Get("RequeuedFn", 0)
			UserCallback := BoundHandle["UserCallback"]
			if A_IsSuspended {
				BoundHandle["PrimaryArmed"] := false
				Serial := ++BoundHandle["RequeueSerial"]
				requeued := _TimerAdapterMakeOneShot(BoundHandle, UserCallback, Serial)
				BoundHandle["RequeuedFn"] := requeued
				try SetTimer(requeued, -500)
				catch as Err {
					Failure := Err
					try _TimerAdapterCancelNative(requeued)
					catch as CancelErr
						CleanupFailure := CancelErr
					if !IsObject(CleanupFailure) {
						BoundHandle["Fired"] := true
						BoundHandle["Fn"] := 0
						BoundHandle.Delete("RequeuedFn")
						_TIMER_ADAPTER_REGISTRY.Delete(Id)
					}
				}
				return
			}
			BoundHandle["Fired"] := true
			BoundHandle["PrimaryArmed"] := false
			BoundHandle["Fn"] := 0
			if BoundHandle.Has("RequeuedFn")
				BoundHandle.Delete("RequeuedFn")
			_TIMER_ADAPTER_REGISTRY.Delete(Id)
		} finally {
			Critical(PreviousCritical)
			if IsObject(Failure)
				try LoggerError("TimerScheduler", "suspended one-shot re-queue failed: {1}", Failure.Message)
			if IsObject(CleanupFailure)
				try LoggerError("TimerScheduler", "suspended re-queue cleanup failed: {1}", CleanupFailure.Message)
		}
		try UserCallback.Call()
		catch as Err {
			try LoggerError("TimerScheduler", "one-shot callback threw: {1}", Err.Message)
		}
	}
	return _OneShot.Bind(Handle, Handle["WrapperEpoch"], ChildSerial)
}

; A periodic callback retains its wrapper until acknowledged cancellation.
_TimerAdapterMakeRepeating(Handle, Fn) {
	_Repeating(BoundHandle, WrapperEpoch) {
		global _TIMER_ADAPTER_REGISTRY
		PreviousCritical := Critical("On")
		try {
			if A_IsSuspended || BoundHandle["Fired"] || BoundHandle["WrapperEpoch"] != WrapperEpoch
				return
			Id := BoundHandle["Id"]
			if !_TIMER_ADAPTER_REGISTRY.Has(Id) || _TIMER_ADAPTER_REGISTRY[Id] != BoundHandle
				return
			BoundFn := BoundHandle["UserCallback"]
		} finally Critical(PreviousCritical)
		try BoundFn()
		catch as Err {
			try LoggerError("TimerScheduler", "repeating callback threw: {1}", Err.Message)
		}
	}
	return _Repeating.Bind(Handle, Handle["WrapperEpoch"])
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/unit/adapters/test_adapter_compliance.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_TIMER_SCHEDULER := Map(
    "after",       TimerAfter,
    "every",       TimerEvery,
    "cancel",      TimerCancel,
    "cancelAll",   TimerCancelAll,
    "activeCount", TimerActiveCount,
)





; ========================================================
; ========================================================
; ======= 4/ Local Server Owned Callback Producers =======
; ========================================================
; ========================================================

; Native callback producers retain the caller-owned identity and strict
; cancellation/one-shot contract. Domain owners inherit these exact methods;
; no scheduler handle, wrapper callback or repeating interval is introduced.

class _LocalServerModelsTimerNativeAdapter {
	_NativeTimer(Callback, Period) {
		; This owner only cancels or rearms one exact record's one-shot. An
		; opaque positive interval must never become an idle repeating poller.
		if !(Period is Integer) || Period > 0
			throw TypeError("Models timers require cancellation or a negative one-shot period.")
		if Period == 0
			SetTimer(Callback, 0)
		else
			SetTimer(Callback, -Abs(Period))
		return true
	}
}

class _LocalServersTimerNativeAdapter {
	_NativeTimer(Callback, Period) {
		; Logical queue observation only rearms an exact job's one-shot.
		if !(Period is Integer) || Period > 0
			throw TypeError("Local server queue timers require cancellation or a negative one-shot period.")
		if Period == 0
			SetTimer(Callback, 0)
		else
			SetTimer(Callback, -Abs(Period))
		return true
	}
}
