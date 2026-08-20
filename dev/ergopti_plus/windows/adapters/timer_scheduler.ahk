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

; Weak-reference registry of all live timer handles — allows TimerCancelAll to
; drain without requiring the caller to track every handle individually.
global _TIMER_ADAPTER_REGISTRY := Map()
global _TIMER_ADAPTER_NEXT_ID  := 0


; Allocates a new unique handle ID.
_TimerAdapterNextId() {
	global _TIMER_ADAPTER_NEXT_ID
	_TIMER_ADAPTER_NEXT_ID += 1
	return _TIMER_ADAPTER_NEXT_ID
}

_TimerAdapterSetNative(BoundFn, IntervalMs) {
	SetTimer(BoundFn, IntervalMs)
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
	Handle := Map("Fn", 0, "Interval", 0, "Fired", false,
		"Id", _TimerAdapterNextId(), "Kind", "after")
	; Convert seconds to the negative milliseconds AHK uses for one-shot timers.
	Ms := -Round(DelaySec * 1000)
	; AHK v2 treats SetTimer(fn, 0) as cancel, not immediate-one-shot; use -1 ms
	; as the minimum delay when DelaySec rounds to zero.
	if Ms = 0
		Ms := -1
	; Wrap Fn in a closure that marks the handle fired and calls the user callback.
	BoundFn := _TimerAdapterMakeOneShot(Handle, Fn)
	Handle["Fn"] := BoundFn
	Handle["Interval"] := Ms
	try SetTimer(BoundFn, Ms)
	catch as Err {
		Handle["Fired"] := true
		try LoggerError("TimerScheduler", "one-shot schedule failed: {1}", Err.Message)
		throw Err
	}
	_TIMER_ADAPTER_REGISTRY[Handle["Id"]] := Handle
	return Handle
}

; Re-arms an existing one-shot handle with the same callback. This is the
; allocation-free counterpart to cancel()+after() for hot-path debouncers: the
; opaque handle, wrapper and captured callback keep their identity, while the OS
; timer is restarted from now. A fired/cancelled handle may be restarted too.
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
	BoundFn := Handle["Fn"]
	if !HasMethod(BoundFn, "Call")
		throw TypeError("TimerRestartAfter handle has no callable owner.")
	; SetTimer on the same callback identity resets its due time in place. Do not
	; cancel first: that would double the OS calls on the per-keystroke debounce.
	if Handle.Has("RequeuedFn") {
		try SetTimer(Handle["RequeuedFn"], 0)
		catch as Err
			try LoggerWarn("TimerScheduler", "re-queued timer restart cancellation failed: {1}", Err.Message)
		Handle.Delete("RequeuedFn")
	}
	Ms := -Round(DelaySec * 1000)
	if Ms = 0
		Ms := -1
	Handle["Interval"] := Ms
	Handle["Fired"] := false
	try SetTimer(BoundFn, Ms)
	catch as Err {
		Handle["Fired"] := true
		if _TIMER_ADAPTER_REGISTRY.Has(Handle["Id"])
			_TIMER_ADAPTER_REGISTRY.Delete(Handle["Id"])
		try LoggerError("TimerScheduler", "one-shot restart failed: {1}", Err.Message)
		throw Err
	}
	_TIMER_ADAPTER_REGISTRY[Handle["Id"]] := Handle
	return Handle
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
	Handle := Map("Fn", 0, "Interval", 0, "Fired", false,
		"Id", _TimerAdapterNextId(), "Kind", "every")
	Ms := Round(IntervalSec * 1000)
	; AHK treats SetTimer with interval=0 as a cancel; clamp to 1ms minimum so a
	; near-zero interval still fires as a true repeating timer rather than silently
	; defaulting to the 250ms AHK fallback
	if Ms <= 0
		Ms := 1
	; Wrap Fn so uncaught exceptions are logged without crashing the timer thread.
	BoundFn := _TimerAdapterMakeRepeating(Handle, Fn)
	Handle["Fn"] := BoundFn
	Handle["Interval"] := Ms
	try SetTimer(BoundFn, Ms)
	catch as Err {
		Handle["Fired"] := true
		try LoggerError("TimerScheduler", "repeating schedule failed: {1}", Err.Message)
		throw Err
	}
	_TIMER_ADAPTER_REGISTRY[Handle["Id"]] := Handle
	return Handle
}

; Cancels a previously scheduled timer. Safe to call on a nil or already-fired handle.
; Also cancels any pending re-queue timer created when the script was suspended.
; @param Handle {Map|0} Token returned by TimerAfter or TimerEvery.
TimerCancel(Handle) {
	global _TIMER_ADAPTER_REGISTRY
	if !(Handle is Map)
		return
        BoundFn := Handle.Has("Fn") ? Handle["Fn"] : 0
        if BoundFn != 0 {
                try SetTimer(BoundFn, 0)
                catch as Err
                        try LoggerWarn("TimerScheduler", "timer cancellation failed: {1}", Err.Message)
        }
	; Cancel any re-queued one-shot timer that was created during a suspend window.
	; Without this, the re-queued timer has no reference and fires indefinitely after
	; the original handle is cancelled.
	RequeuedFn := Handle.Has("RequeuedFn") ? Handle["RequeuedFn"] : 0
        if RequeuedFn != 0 {
                try SetTimer(RequeuedFn, 0)
                catch as Err
                        try LoggerWarn("TimerScheduler", "re-queued timer cancellation failed: {1}", Err.Message)
        }
	Handle["Fired"] := true
	Id := Handle.Has("Id") ? Handle["Id"] : 0
	if Id != 0 and _TIMER_ADAPTER_REGISTRY.Has(Id)
		_TIMER_ADAPTER_REGISTRY.Delete(Id)
}

; Cancels every timer owned by this adapter. Safe to call at any time.
TimerCancelAll() {
	global _TIMER_ADAPTER_REGISTRY
	for Id, Handle in _TIMER_ADAPTER_REGISTRY.Clone() {
		TimerCancel(Handle)
	}
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
_TimerAdapterMakeOneShot(Handle, Fn) {
	_OneShot(BoundHandle, BoundFn) {
		if BoundHandle["Fired"]
			return
		if A_IsSuspended {
			; One-shot SetTimer with a negative delay never re-fires on its own.
			; Re-queue the callback for 500ms later so it is not silently lost
			; while the script is suspended (timer-scheduler-oneshot-suspend fix).
			; The registry entry is intentionally kept intact until the callback
			; actually fires.
			; Store the re-queued closure in the handle so TimerCancel can reach it
			; and cancel it if the caller cancels before the suspend window lifts.
			requeued := _OneShot.Bind(BoundHandle, BoundFn)
			BoundHandle["RequeuedFn"] := requeued
                        try SetTimer(requeued, -500)
                        catch as Err {
                                ; A failed re-queue must become a terminal, visible
                                ; state.  Leaving this handle live would advertise
                                ; work that can never fire and later collide with a
                                ; reused timer id.
                                BoundHandle["Fired"] := true
                                Id := BoundHandle.Has("Id") ? BoundHandle["Id"] : 0
                                if Id != 0 and _TIMER_ADAPTER_REGISTRY.Has(Id)
                                        _TIMER_ADAPTER_REGISTRY.Delete(Id)
                                try LoggerError("TimerScheduler", "suspended one-shot re-queue failed: {1}", Err.Message)
                        }
                        return
		}
		; Clear any stored re-queue reference now that we are actually firing,
		; so TimerCancel does not attempt a redundant SetTimer(fn, 0) call.
		if BoundHandle.Has("RequeuedFn")
			BoundHandle.Delete("RequeuedFn")
		global _TIMER_ADAPTER_REGISTRY
		BoundHandle["Fired"] := true
		Id := BoundHandle.Has("Id") ? BoundHandle["Id"] : 0
		if Id != 0 and _TIMER_ADAPTER_REGISTRY.Has(Id)
			_TIMER_ADAPTER_REGISTRY.Delete(Id)
		try BoundFn()
		catch as Err {
			try LoggerError("TimerScheduler", "one-shot callback threw: {1}", Err.Message)
		}
	}
	return _OneShot.Bind(Handle, Fn)
}

; Builds a repeating wrapper that logs uncaught exceptions without killing the timer.
_TimerAdapterMakeRepeating(Handle, Fn) {
	_Repeating(BoundHandle, BoundFn) {
		if A_IsSuspended
			return
		if BoundHandle["Fired"]
			return
		try BoundFn()
		catch as Err {
			try LoggerError("TimerScheduler", "repeating callback threw: {1}", Err.Message)
		}
	}
	return _Repeating.Bind(Handle, Fn)
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_TIMER_SCHEDULER := Map(
    "after",       TimerAfter,
    "every",       TimerEvery,
    "cancel",      TimerCancel,
    "cancelAll",   TimerCancelAll,
    "activeCount", TimerActiveCount,
)
