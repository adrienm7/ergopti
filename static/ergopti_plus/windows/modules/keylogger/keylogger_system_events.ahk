; modules/keylogger/keylogger_system_events.ahk

; ==============================================================================
; MODULE: Windows System Event Integration
; DESCRIPTION: Own passive interval publication across message callbacks, pause and shutdown.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include keylogger_system_event_owner.ahk

_KL_SystemEventClock() {
	; Native GetTickCount64 includes sleep and hibernation without 32-bit rollover.
	return Map("tick", DllCall("GetTickCount64", "UInt64"), "timestamp", KL_NowTimestamp())
}

_KL_SystemEventAppend(Entry, Guard, Commit) {
	RejectedBySuspend := false
	return KL_AppendLog(Entry, &RejectedBySuspend, Guard, Commit)
}

_KL_Watchers_SystemStart() {
	if IsObject(KLWatch.system_events) && !KLWatch.system_events.Stopped
		return !KLWatch.system_events.Stopping
	KLWatch.system_events := KLSystemEventOwner(_KL_SystemEventClock, _KL_SystemEventAppend,
		() => !A_IsSuspended)
	KLWatch.system_failure_reported := false
	return true
}

KL_Watchers_ResetSystemIntervals() {
	if IsObject(KLWatch.system_events)
		KLWatch.system_events.Reset()
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
		try LoggerError("Keylogger", "System event delivery remains incomplete: {1}.", Reason)
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

_KL_Watchers_SystemDrain(Stopping := false) {
	if !IsObject(KLWatch.system_events)
		return true
	try {
		Owner := KLWatch.system_events
		Ok := Stopping ? Owner.Stop() : Owner.Drain()
		return _KL_Watchers_SystemResult(Ok,
			Owner.LastFailure != "" ? Owner.LastFailure : "active-drain")
	} catch Error {
		return _KL_Watchers_SystemResult(false, "drain-exception")
	}
}
