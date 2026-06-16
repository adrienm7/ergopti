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

; Reads a windows/-relative source file (A_ScriptDir is the runner dir tests/).
_ATG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(StrReplace(Root, "/", "\") . "\" . StrReplace(RelPath, "/", "\"), "UTF-8")
}

; Drops full-line comments so assertions never match an explanatory comment.
_ATG_StripComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}

; Column-0 function body (definition, not a call site) to the first flush-left
; closing brace, with full-line comments stripped.
_ATG_FuncBodyStripped(Src, Decl) {
	Idx := InStr(Src, "`n" . Decl)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx + 1)
	End := InStr(Rest, "`n}")
	Body := End ? SubStr(Rest, 1, End + 1) : Rest
	return _ATG_StripComments(Body)
}




; =========================================================
; =========================================================
; ======= 1/ metrics-timers-bypass-pause ==================
; =========================================================
; =========================================================

_ATG_MetricsTicksGatedOnSuspend() {
	Checks := Map(
		"modules/keylogger/keylogger_sensors.ahk", "KL_Sensors_Tick()",
		"modules/keylogger/keylogger.ahk",         "KL_IngestOnce()",
		"modules/keylogger/keylogger_hook.ahk",    "KL_Hook_Tick()")
	for RelPath, Decl in Checks {
		Body := _ATG_FuncBodyStripped(_ATG_ReadSource(RelPath), Decl)
		Assert(Body != "", Decl . " must exist in " . RelPath)
		Assert(InStr(Body, "A_IsSuspended") > 0,
			Decl . " must early-return on A_IsSuspended so metrics timers go quiet while paused (metrics-timers-bypass-pause)")
	}
	; KL_Hook_LivePush lives in the same hook file.
	Body := _ATG_FuncBodyStripped(_ATG_ReadSource("modules/keylogger/keylogger_hook.ahk"), "KL_Hook_LivePush()")
	Assert(Body != "", "KL_Hook_LivePush() must exist in keylogger_hook.ahk")
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
	Body := _ATG_FuncBodyStripped(_ATG_ReadSource("modules/keylogger/keylogger.ahk"), "KL_IngestOnce()")
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
	Src := _ATG_StripComments(_ATG_ReadSource("modules/keylogger/keylogger_av_state.ahk"))
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
	Src := _ATG_StripComments(_ATG_ReadSource("lib/metrics/wpm_widget.ahk"))
	; The graph renderer was migrated to a GDI+ layered window; with no live
	; WebView2 controller there is no per-process user-data folder to orphan on
	; Reload, eliminating the temp-dir leak at the source.
	Assert(InStr(Src, "WebView2") = 0,
		"wpm_widget.ahk must not instantiate a live WebView2 renderer — the GDI+ migration removed the leaking user-data folder (wpm-webview-temp-dir-leak)")
}
Test("wpm_widget: graph renderer has no live WebView2 (wpm-webview-temp-dir-leak)", _ATG_WpmWidgetHasNoLiveWebView2)
