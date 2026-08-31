; modules/keylogger/keylogger_health.ahk

; ==============================================================================
; MODULE: Keylogger Health Snapshot
; DESCRIPTION:
; Exposes one privacy-safe, atomic diagnostic snapshot from the live Keylogger
; owner. No raw text, title, URL or application name crosses this boundary.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Counters and snapshot ==
; ===================================
; ===================================

KL_RecordPrivacyHit() {
	PreviousCritical := Critical("On")
	try Keylogger.health_privacy_hits += 1
	finally Critical(PreviousCritical)
}

KL_HealthSnapshot(WpmFn := 0) {
	PreviousCritical := Critical("On")
	try {
		Snapshot := Map(
			"enabled", Keylogger.initialized ? true : false,
			"events_session", Keylogger.health_events_session,
			"privacy_hits", Keylogger.health_privacy_hits,
			"today_log", Keylogger.today_log_path,
			"wpm", "n/a")
	} finally {
		Critical(PreviousCritical)
	}

	if !HasMethod(WpmFn, "Call") && IsSet(WPMWidget_Calc)
		WpmFn := WPMWidget_Calc
	if HasMethod(WpmFn, "Call") {
		WpmState := WpmFn.Call()
		if (WpmState is Map) && WpmState.Has("wpm")
			Snapshot["wpm"] := WpmState["wpm"]
	}
	return Snapshot
}
