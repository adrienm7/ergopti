; tests/meta/test_kl_switch_privacy_filter_outgoing.ahk

; ==============================================================================
; MODULE: KL-Switch Privacy Filter Outgoing-Side Meta Test
; DESCRIPTION:
; Static source guard for finding F9.
;
; app_switch / window_switch events carry the OUTGOING (prev_app / prev_title)
; context as their payload. KL_AppendLog's single privacy chokepoint used to
; call the zero-argument MF_ShouldFilter(), which only ever evaluates the LIVE
; (new, non-excluded) focused window — the exclusion / private-browsing check
; always answered the wrong side of the transition, leaking the excluded
; process name and/or verbatim private-browsing window title into today.log
; and data.sql.
;
; THE FIX: lib/metrics/metrics_filters.ahk exposes MF_ShouldFilterFor(app,
; title), an explicit-argument variant of the same predicate. KL_AppendLog
; calls it against entry["prev_app"] (app_switch) / entry["app"] +
; entry["prev_title"] (window_switch) and drops the entry when the OUTGOING
; context was excluded/private. keylogger_hook.ahk's KL_Hook_RefreshContext
; also snapshots the outgoing app BEFORE the app-switch block mutates
; KLHook.prev_app, so window_switch's "app" field is never silently
; overwritten with the NEW app on a combined app+title transition.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_KLSPF_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ===================================================
; ===================================================
; ======= 2/ MF_ShouldFilterFor existence ===========
; ===================================================
; ===================================================

_KLSPF_ShouldFilterForExists() {
	Body := _DriverFuncBody("MF_ShouldFilterFor")
	Assert(Body != "",
		"lib/metrics/metrics_filters.ahk must define MF_ShouldFilterFor(app, title) — "
		. "an explicit-argument privacy predicate independent of the live focus cache (F9)")
	Assert(InStr(Body, "MetricsFocusCache") = 0,
		"MF_ShouldFilterFor must NOT read MetricsFocusCache.state — it must evaluate the "
		. "caller-supplied (app, title) pair, not the live focused window (F9)")
	Assert(InStr(Body, "disabled_apps.Has(proc)") > 0,
		"MF_ShouldFilterFor must check the disabled-apps exclusion list against the supplied app (F9)")
	Assert(InStr(Body, "MF_PRIVATE_TITLE_PATTERNS") > 0,
		"MF_ShouldFilterFor must check the private-browsing title patterns against the supplied title (F9)")
}
Test("metrics_filters: MF_ShouldFilterFor evaluates an explicit (app, title) pair (F9)",
	_KLSPF_ShouldFilterForExists)





; ===================================================
; ===================================================
; ======= 3/ KL_AppendLog outgoing-side check =======
; ===================================================
; ===================================================

_KLSPF_AppendLogChecksOutgoingSide() {
	Body := _DriverFuncBody("KL_AppendLog")
	Assert(Body != "", "KL_AppendLog(entry) declaration must exist in keylogger.ahk")
	Assert(InStr(Body, "MF_ShouldFilterFor") > 0,
		"KL_AppendLog must call MF_ShouldFilterFor for app_switch/window_switch entries — "
		. "MF_ShouldFilter() alone only ever evaluates the LIVE (new) focused window, which "
		. "is never the excluded/private context on a switch AWAY from it (F9)")
	Assert(InStr(Body, 'entry["prev_app"]') > 0,
		'KL_AppendLog must pass entry["prev_app"] (the OUTGOING app) into the privacy check '
		. "for app_switch events (F9)")
	Assert(InStr(Body, 'entry["prev_title"]') > 0,
		'KL_AppendLog must pass entry["prev_title"] (the OUTGOING title) into the privacy check '
		. "for window_switch events (F9)")
}
Test("keylogger: KL_AppendLog re-checks the OUTGOING app/title for app_switch/window_switch (F9)",
	_KLSPF_AppendLogChecksOutgoingSide)




; ===================================================
; ===================================================
; ======= 4/ Outgoing-app snapshot ordering =========
; ===================================================
; ===================================================

; Root cause encoded: without snapshotting KLHook.prev_app BEFORE the
; app-switch block mutates it, a combined app+title switch would silently
; relabel window_switch's "app" field with the NEW app, defeating the F9
; check in section 3 above (it would check the wrong app's exclusion status).
_KLSPF_OutgoingAppSnapshottedBeforeMutation() {
	Body := _DriverFuncBody("KL_Hook_RefreshContext")
	Assert(Body != "", "KL_Hook_RefreshContext must exist in keylogger_hook.ahk")

	SnapshotPos := InStr(Body, "outgoing_app := KLHook.prev_app")
	MutatePos    := InStr(Body, "KLHook.prev_app := NewApp")
	UsagePos     := InStr(Body, "KL_LogWindowSwitch(outgoing_app,")

	Assert(SnapshotPos > 0,
		"KL_Hook_RefreshContext must snapshot 'outgoing_app := KLHook.prev_app' before "
		. "the app-switch block can mutate KLHook.prev_app (F9)")
	Assert(MutatePos > 0,
		"KL_Hook_RefreshContext must still mutate KLHook.prev_app in the app-switch block")
	Assert(UsagePos > 0,
		"KL_Hook_RefreshContext must call KL_LogWindowSwitch(outgoing_app, ...) rather than "
		. "KL_LogWindowSwitch(KLHook.prev_app, ...), which may already read the NEW app on a "
		. "combined app+title transition (F9)")
	Assert(SnapshotPos < MutatePos,
		"outgoing_app must be captured BEFORE KLHook.prev_app is mutated by the app-switch "
		. "block, otherwise the snapshot itself would already read the NEW app (F9)")
}
Test("keylogger_hook: outgoing_app is snapshotted before KLHook.prev_app mutates (F9)",
	_KLSPF_OutgoingAppSnapshottedBeforeMutation)
