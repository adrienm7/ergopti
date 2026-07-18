; tests/meta/test_metrics_app_time_accuracy.ahk

; ==============================================================================
; MODULE: Metrics App Time Accuracy Meta Test
; DESCRIPTION:
; Guards two sources of under-counted application time: treating every
; micro-idle as a session break and omitting the currently open foreground
; interval from the metrics manifest.
; ==============================================================================

#Requires AutoHotkey v2.0

_MATA_MicroIdleDoesNotResetAppTime() {
	Src := _DriverFuncBody("KL_Watchers_OnKeystroke")
	Assert(Src != "", "KL_Watchers_OnKeystroke must exist")
	Assert(!InStr(Src, "KLWatch.is_idle or gap >= KLWatchConst.SESSION_TIMEOUT_MS"),
		"micro-idle must not reset app_entered_at: it under-counts reading and thinking time")
	Assert(InStr(Src, "if (gap >= KLWatchConst.SESSION_TIMEOUT_MS)") > 0,
		"only a true session timeout may reset the foreground interval")
}
Test("metrics app time: micro-idle does not discard foreground duration", _MATA_MicroIdleDoesNotResetAppTime)

_MATA_ManifestIncludesLiveForegroundInterval() {
	ReaderBody := _DriverFuncBody("KLR_ReadManifest")
	Assert(ReaderBody != "", "KLR_ReadManifest must exist")
	Assert(InStr(ReaderBody, "KLR_AddLiveForegroundTime(manifest, start_date, end_date)") > 0,
		"manifest reader must add the still-open foreground interval")
	Src := _DriverFuncBody("KLR_AddLiveForegroundTime")
	Assert(Src != "", "KLR_AddLiveForegroundTime must exist")
	Assert(InStr(Src, 'cell["app_time_ms"] += elapsed') > 0,
		"live foreground duration must be projected into app_time_ms")
	Assert(InStr(Src, "date_str < start_date") > 0 && InStr(Src, "date_str > end_date") > 0,
		"the live interval must respect the manifest date filter")
}
Test("metrics app time: manifest includes the current foreground interval", _MATA_ManifestIncludesLiveForegroundInterval)
