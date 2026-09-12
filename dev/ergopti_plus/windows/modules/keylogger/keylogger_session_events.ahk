; modules/keylogger/keylogger_session_events.ahk

; ==============================================================================
; MODULE: Session Event Publication
; DESCRIPTION: Pair accepted session records with their ownership commits.
; ==============================================================================

#Requires AutoHotkey v2.0

KL_LogSession(kind, duration_ms := unset, PublishCommit := 0) {
	e := Map("type", kind)
	if IsSet(duration_ms)
		e["duration_ms"] := duration_ms
	if HasMethod(PublishCommit, "Call") {
		RejectedBySuspend := false
		return KL_AppendLog(e, &RejectedBySuspend, , PublishCommit)
	}
	return KL_AppendLog(e)
}
