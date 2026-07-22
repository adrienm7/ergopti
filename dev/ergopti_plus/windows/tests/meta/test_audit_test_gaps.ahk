; tests/meta/test_audit_test_gaps.ahk

; ==============================================================================
; MODULE: Audit Test-Gap Guards
; DESCRIPTION:
; Wired regression guards for audit findings that were implemented but whose
; dedicated regression test was missing or too weak (verification flagged them
; as not pinning the fix). Each guard is a comment-stripped source scan — the
; production keylogger / wpm modules are not in the run_all include graph, so a
; behavioural test is impractical; the static guard still fails loudly if the
; fix is reverted, which is the regression contract.
;
; Covers:
;   metrics-timers-bypass-pause          — the four recurring metrics ticks gate on A_IsSuspended.
;   pending-entries-cross-thread-race    — the ingest drain swaps+clears under Critical.
;   av-mute-heuristic-and-doc-mismatch   — the volume probe uses winmm waveOutGetVolume.
;   wpm-webview-temp-dir-leak            — the WPM widget has no live WebView2 (GDI+ migration).
; ==============================================================================

; Drops full-line comments so assertions never match an explanatory comment.
_ATG_StripComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}




; =========================================================
; =========================================================
; ======= 1/ metrics-timers-bypass-pause ==================
; =========================================================
; =========================================================

_ATG_MetricsTicksGatedOnSuspend() {
	; Move-resilient: locate each tick function across the whole driver source
	; via the framework helper rather than a pinned per-module path. Maps the
	; bare function name to the original declaration used in assertion messages.
	Checks := Map(
		"KL_Sensors_Tick", "KL_Sensors_Tick()",
		"KL_IngestOnce",   "KL_IngestOnce(",
		"KL_Hook_Tick",    "KL_Hook_Tick()")
	for Name, Decl in Checks {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Decl . " must exist")
		Assert(InStr(Body, "A_IsSuspended") > 0,
			Decl . " must early-return on A_IsSuspended so metrics timers go quiet while paused (metrics-timers-bypass-pause)")
	}
	; KL_Hook_LivePush is the live-push companion tick.
	Body := _DriverFuncBody("KL_Hook_LivePush")
	Assert(Body != "", "KL_Hook_LivePush() must exist")
	Assert(InStr(Body, "A_IsSuspended") > 0,
		"KL_Hook_LivePush must gate on A_IsSuspended (metrics-timers-bypass-pause)")
}
Test("metrics: the recurring keylogger/metrics ticks gate on A_IsSuspended (metrics-timers-bypass-pause)", _ATG_MetricsTicksGatedOnSuspend)




; =========================================================
; =========================================================
; ======= 2/ pending-entries-cross-thread-race ============
; =========================================================
; =========================================================

_ATG_IngestDrainIsAtomic() {
	Body := _DriverFuncBody("KL_IngestOnce")
	Assert(Body != "", "KL_IngestOnce() must exist in keylogger.ahk")
	Assert(InStr(Body, "Critical(") > 0,
		"KL_IngestOnce must wrap the pending-entries drain in Critical() so the keystroke hook cannot append between snapshot and clear (pending-entries-cross-thread-race)")
	Assert(InStr(Body, "_pending_entries := []") > 0,
		"KL_IngestOnce must clear _pending_entries by reassignment inside the Critical section (atomic swap-and-clear, not read-then-clear) (pending-entries-cross-thread-race)")
}
Test("keylogger: KL_IngestOnce drains _pending_entries atomically under Critical (pending-entries-cross-thread-race)", _ATG_IngestDrainIsAtomic)




; =========================================================
; =========================================================
; ======= 3/ av-mute-heuristic-and-doc-mismatch ===========
; =========================================================
; =========================================================

_ATG_AvVolumeUsesWinmm() {
	; Scoped to the keylogger module tree: the winmm-vs-COM invariant is specific
	; to keylogger_av_state, and other modules may legitimately use COM, so a
	; whole-tree scan would false-trip the CoCreateInstance absence check.
	Src := _ATG_StripComments(_DriverDirConcat("modules/keylogger"))
	Assert(InStr(Src, "waveOutGetVolume") > 0,
		"the volume probe must read winmm waveOutGetVolume — the documented MMDevice/IAudioEndpointVolume COM path was never the implementation (av-mute-heuristic-and-doc-mismatch)")
	Assert(InStr(Src, "CoCreateInstance") = 0,
		"keylogger_av_state must not claim a CoCreateInstance COM path in live code — the impl is the lightweight winmm probe (av-mute-heuristic-and-doc-mismatch)")
}
Test("keylogger_av: master-volume probe uses the winmm path, code matches docs (av-mute-heuristic-and-doc-mismatch)", _ATG_AvVolumeUsesWinmm)




; =========================================================
; =========================================================
; ======= 4/ wpm-webview-temp-dir-leak ====================
; =========================================================
; =========================================================

_ATG_WpmWidgetHasNoLiveWebView2() {
	; Scope the scan to ui/wpm (both init.ahk and the wpm_widget.ahk render layer
	; after the F3 split) — NOT _DriverDirConcat("ui"): other ui/ files (changelog,
	; model browser, healthcheck) reference WebView2 in live code, so a whole-tree
	; scan would false-trip this module-scoped "wpm widget has none" invariant.
	Src := _ATG_StripComments(_DriverDirConcat("ui/wpm"))
	; The graph renderer was migrated to a GDI+ layered window; with no live
	; WebView2 controller there is no per-process user-data folder to orphan on
	; Reload, eliminating the temp-dir leak at the source.
	Assert(InStr(Src, "WebView2") = 0,
		"wpm_widget.ahk must not instantiate a live WebView2 renderer — the GDI+ migration removed the leaking user-data folder (wpm-webview-temp-dir-leak)")
}
Test("wpm_widget: graph renderer has no live WebView2 (wpm-webview-temp-dir-leak)", _ATG_WpmWidgetHasNoLiveWebView2)
