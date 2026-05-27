; adapters/timer_scheduler.ahk

; ==============================================================================
; MODULE: TimerScheduler Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the TimerScheduler port contract defined in
; static/ergopti_plus/shared/ports/TimerScheduler.spec.js. Wraps AHK's SetTimer
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




; =====================================================
; =====================================================
; ======= 2/ Adapter Methods ==========================
; =====================================================
; =====================================================

; Schedules Fn to fire once after DelaySec seconds.
; Returns an opaque handle Map that can be passed to TimerCancel.
; @param DelaySec   {Float}    Delay in seconds (fractional values accepted).
; @param Fn         {Callable} Zero-arity function to invoke.
; @return {Map}  Opaque cancellation handle.
TimerAfter(DelaySec, Fn) {
	global _TIMER_ADAPTER_REGISTRY
	Handle := Map("Fn", 0, "Interval", 0, "Fired", false, "Id", _TimerAdapterNextId())
	; Convert seconds to the negative milliseconds AHK uses for one-shot timers.
	Ms := -Round(DelaySec * 1000)
	; Wrap Fn in a closure that marks the handle fired and calls the user callback.
	BoundFn := _TimerAdapterMakeOneShot(Handle, Fn)
	Handle["Fn"] := BoundFn
	Handle["Interval"] := Ms
	_TIMER_ADAPTER_REGISTRY[Handle["Id"]] := Handle
	SetTimer(BoundFn, Ms)
	return Handle
}

; Schedules Fn to fire repeatedly every IntervalSec seconds.
; The first firing happens after IntervalSec (not immediately).
; @param IntervalSec {Float}    Repeat interval in seconds.
; @param Fn          {Callable} Zero-arity function to invoke.
; @return {Map}  Opaque cancellation handle.
TimerEvery(IntervalSec, Fn) {
	global _TIMER_ADAPTER_REGISTRY
	Handle := Map("Fn", 0, "Interval", 0, "Fired", false, "Id", _TimerAdapterNextId())
	Ms := Round(IntervalSec * 1000)
	; Wrap Fn so uncaught exceptions are logged without crashing the timer thread.
	BoundFn := _TimerAdapterMakeRepeating(Handle, Fn)
	Handle["Fn"] := BoundFn
	Handle["Interval"] := Ms
	_TIMER_ADAPTER_REGISTRY[Handle["Id"]] := Handle
	SetTimer(BoundFn, Ms)
	return Handle
}

; Cancels a previously scheduled timer. Safe to call on a nil or already-fired handle.
; @param Handle {Map|0} Token returned by TimerAfter or TimerEvery.
TimerCancel(Handle) {
	global _TIMER_ADAPTER_REGISTRY
	if !(Handle is Map)
		return
	BoundFn := Handle.Has("Fn") ? Handle["Fn"] : 0
	if BoundFn != 0
		SetTimer(BoundFn, 0)
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
		global _TIMER_ADAPTER_REGISTRY
		BoundHandle["Fired"] := true
		Id := BoundHandle.Has("Id") ? BoundHandle["Id"] : 0
		if Id != 0 and _TIMER_ADAPTER_REGISTRY.Has(Id)
			_TIMER_ADAPTER_REGISTRY.Delete(Id)
		try BoundFn()
		catch as Err {
			OutputDebug("TimerAdapter [one-shot] callback error: " . Err.Message)
		}
	}
	return _OneShot.Bind(Handle, Fn)
}

; Builds a repeating wrapper that logs uncaught exceptions without killing the timer.
_TimerAdapterMakeRepeating(Handle, Fn) {
	_Repeating(BoundHandle, BoundFn) {
		if BoundHandle["Fired"]
			return
		try BoundFn()
		catch as Err {
			OutputDebug("TimerAdapter [repeating] callback error: " . Err.Message)
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
