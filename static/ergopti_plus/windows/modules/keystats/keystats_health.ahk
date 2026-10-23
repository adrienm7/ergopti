; modules/keystats/keystats_health.ahk

; ==============================================================================
; MODULE: Keystats Health Snapshot
; DESCRIPTION:
; Exposes one privacy-safe, atomic diagnostic snapshot from the live Keystats
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
	try Keystats.health_privacy_hits += 1
	finally Critical(PreviousCritical)
}

KL_HealthSnapshot(WpmFn := 0) {
	PreviousCritical := Critical("On")
	try {
		Snapshot := Map(
			"enabled", Keystats.initialized ? true : false,
			"events_session", Keystats.health_events_session,
			"privacy_hits", Keystats.health_privacy_hits,
			"today_log", Keystats.today_log_path,
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
