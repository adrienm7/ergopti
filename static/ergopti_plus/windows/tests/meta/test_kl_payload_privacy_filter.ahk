; tests/meta/test_kl_payload_privacy_filter.ahk

; ==============================================================================
; MODULE: Payload Privacy Re-check Regression (kl-payload-privacy-filter-scoped)
; DESCRIPTION:
; The privacy verdict and the event payload described two different windows.
; MF_ShouldFilter() reads MetricsFocusCache, which MF_RefreshFocus repoints
; within MF_FOCUS_TTL_MS (50 ms). Every payload, by contrast, describes the
; window its producer saw: app_switch / window_switch carry the outgoing
; prev_app / prev_title by design, and every OTHER type carries
; Keylogger.session_app / session_title, whose only writer is
; KL_Hook_RefreshContext under its own CONTEXT_TTL_MS (1000 ms) on a 250 ms
; timer. So for up to ~1.25 s after Alt-Tabbing away from an Incognito window or
; an excluded password manager, the live check passed while the row still
; stamped that window's process name and verbatim title into events_typing --
; precisely the identifiers the filter exists to suppress.
;
; The F9 fix recognised the failure mode and added MF_ShouldFilterFor plus an
; outgoing-side re-check, but scoped it to the two entry types whose payload is
; EXPLICITLY named prev_app/prev_title. The typing, shortcut, hotstring, mouse
; and ergo siblings carry the same potentially-outgoing context implicitly and
; were left unchecked -- this repo's dominant failure mode, an invariant applied
; at one site with the siblings forgotten.
;
; ROOT CAUSE ENCODED: the privacy re-check must cover whatever context an entry
; actually carries, whatever its type. It must not be scoped by type again.
;
; Meta-static because the headless harness does not load
; modules/keylogger/keylogger.ahk (it registers live hooks at load time).
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================================================
; ==========================================================
; ======= 1/ The re-check is not scoped to two types =======
; ==========================================================
; ==========================================================

_KPPF_OutgoingRecheckIsNotTypeScoped() {
	Body := _DriverFuncBody("KL_AppendLog")
	Assert(Body != "", "KL_AppendLog must exist")

	Assert(InStr(Body, "MF_ShouldFilterFor") > 0,
		"prerequisite: KL_AppendLog still re-checks the context the entry carries against the "
		. "explicit-argument privacy predicate (F9)")

	Assert(RegExMatch(Body, 'entry\["type"\]\s*=\s*"app_switch"\s*\|\|\s*entry\["type"\]\s*=\s*"window_switch"') = 0,
		"the privacy re-check must not be gated on 'app_switch || window_switch'. Every other "
		. "entry type carries the Keylogger.session_app / session_title pair, which lags the "
		. "live focus cache by CONTEXT_TTL_MS (1000 ms) while MF_ShouldFilter reads a cache "
		. "refreshed every MF_FOCUS_TTL_MS (50 ms), so scoping the check to the two switch "
		. "types leaks an excluded or private-browsing app name and window title into "
		. "events_typing for over a second after switching away")

	Assert(InStr(Body, 'entry.Has("app")') > 0 && InStr(Body, 'entry.Has("title")') > 0,
		"KL_AppendLog must read the generic 'app' and 'title' keys, not only the switch-only "
		. "prev_* pair -- those are the keys the typing / shortcut / hotstring / mouse / ergo "
		. "entries stamp from the stale session context")

	Assert(InStr(Body, 'entry["prev_app"]') > 0 && InStr(Body, 'entry["prev_title"]') > 0,
		"and the switch-specific outgoing keys must remain -- app_switch and window_switch "
		. "carry their context under different names, and losing them would re-open F9")
}

Test("keylogger: the outgoing-context privacy re-check covers every entry type (kl-payload-privacy-filter-scoped)",
	_KPPF_OutgoingRecheckIsNotTypeScoped)





; ==========================================================
; ==========================================================
; ======= 2/ The lag the re-check exists for is real =======
; ==========================================================
; ==========================================================

; Prerequisite half. If the payload ever stopped carrying the lagging session
; context, or the two caches were single-sourced onto one TTL, the assertion
; above would still hold but would no longer be guarding anything -- so pin the
; divergence that makes it load-bearing.
_KPPF_PayloadStillCarriesTheLaggingContext() {
	Flush := _DriverFuncBody("KL_FlushBuffer")
	Assert(Flush != "", "KL_FlushBuffer must exist")
	Assert(InStr(Flush, "Keylogger.session_app") > 0 && InStr(Flush, "Keylogger.session_title") > 0,
		"prerequisite: the typing entry still stamps app/title from the session context")

	Hook := _DriverFuncBody("KL_Hook_RefreshContext")
	Assert(Hook != "", "KL_Hook_RefreshContext must exist")
	Assert(InStr(Hook, "Keylogger.session_app") > 0 && InStr(Hook, "Keylogger.session_title") > 0,
		"prerequisite: KL_Hook_RefreshContext is still the sole writer of that pair")
	Assert(InStr(Hook, "CONTEXT_TTL_MS") > 0,
		"prerequisite: it still self-gates on its own TTL, which is what makes the payload "
		. "lag the focus cache MF_ShouldFilter reads")

	Filter := _DriverFuncBody("MF_ShouldFilter")
	Assert(InStr(Filter, "MetricsFocusCache.state") > 0,
		"prerequisite: the live privacy verdict is still read from MetricsFocusCache, a "
		. "different snapshot on a different cadence from the payload's")
}

Test("keylogger: the payload context that the re-check guards still lags the focus cache (kl-payload-privacy-filter-scoped)",
	_KPPF_PayloadStillCarriesTheLaggingContext)
