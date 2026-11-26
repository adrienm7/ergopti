; modules/keystats/keystats_system_events.ahk

; ==============================================================================
; MODULE: Windows System Event Integration
; DESCRIPTION: Own passive interval publication across message callbacks, pause and shutdown.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include keystats_system_event_owner.ahk

_KL_SystemEventClock() {
	; Native GetTickCount64 includes sleep and hibernation without 32-bit rollover.
	return Map("tick", DllCall("GetTickCount64", "UInt64"), "timestamp", KL_NowTimestamp())
}

_KL_SystemEventAppend(Entry, Guard, Commit) {
	RejectedBySuspend := false
	Accepted := KL_AppendLog(Entry, &RejectedBySuspend, Guard, Commit)
	; The central receipt reports only an exact lifecycle refusal. Earlier
	; privacy/validation drops stay terminal even if the owner also changed.
	if Accepted
		return true
	return RejectedBySuspend ? KLSystemEventOwner.APPEND_RETRY : false
}

_KL_Watchers_SystemStart() {
	if IsObject(KLWatch.system_events) && !KLWatch.system_events.Stopped
		return !KLWatch.system_events.Stopping
	KLWatch.system_events := KLSystemEventOwner(_KL_SystemEventClock, _KL_SystemEventAppend,
		() => !A_IsSuspended || Keystats._shutting_down)
	KLWatch.system_failure_reported := false
	return true
}

KL_Watchers_ResetSystemIntervals() {
	if IsObject(KLWatch.system_events)
		KLWatch.system_events.Pause()
	return true
}

_KL_Watchers_SystemResult(Ok, Reason := "") {
	if Ok {
		KLWatch.system_failure_reported := false
		return true
	}
	if !KLWatch.system_failure_reported {
		KLWatch.system_failure_reported := true
		; Only fixed failure categories reach diagnostics, never event payloads.
		try LoggerError("Keystats", "System event delivery remains incomplete: {1}.", Reason)
	}
	return false
}

_KL_Watchers_SystemObserve(Action) {
	if !IsObject(KLWatch.system_events)
		return _KL_Watchers_SystemResult(false, "owner-uninitialized")
	try {
		Owner := KLWatch.system_events
		Ok := Owner.Observe(Action)
		return _KL_Watchers_SystemResult(Ok, Owner.LastFailure)
	} catch Error {
		return _KL_Watchers_SystemResult(false, "observation-exception")
	}
}

/**
 * Records one finished keep-awake session: a passive_period row of kind awake,
 * the row the rebuild sums into awake_ms (maintainer decision KMD-3, as macOS
 * and Linux). Metrics that are off credit nothing, by their setting.
 * @param DurationMs {Integer} The session's length in milliseconds.
 * @returns {Integer} True once the owner holds no delivery debt for it.
 */
KL_RecordAwakeSession(DurationMs) {
	if !(DurationMs is Integer) || DurationMs < 0
		throw ValueError("A keep-awake session needs a non-negative integer duration.")
	if !Keystats.initialized
		return true
	if !IsObject(KLWatch.system_events)
		return _KL_Watchers_SystemResult(false, "owner-uninitialized")
	try {
		Owner := KLWatch.system_events
		Ok := Owner.RecordCompleted(Map("kind", "awake", "duration_ms", DurationMs))
		; A pause stops keep-awake: the session stays pending for the idle
		; tick's drain after the resume, which is its delivery, not a failure.
		if !Ok && Owner.LastFailure == "collection-paused"
			return true
		return _KL_Watchers_SystemResult(Ok, Owner.LastFailure)
	} catch Error {
		return _KL_Watchers_SystemResult(false, "record-exception")
	}
}

_KL_Watchers_SystemDrain(Stopping := false) {
	if !IsObject(KLWatch.system_events)
		return true
	try {
		Owner := KLWatch.system_events
		; Shutdown may drain pre-pause records, never the unobserved paused interval.
		if Stopping && A_IsSuspended && !Owner.Stopping
			Owner.Pause()
		Ok := Stopping ? Owner.Stop() : Owner.Drain()
		return _KL_Watchers_SystemResult(Ok,
			Owner.LastFailure != "" ? Owner.LastFailure : "active-drain")
	} catch Error {
		return _KL_Watchers_SystemResult(false, "drain-exception")
	}
}
