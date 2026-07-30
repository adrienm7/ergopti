; tests/meta/test_metrics_focus_ttl_leak.ahk

; ==============================================================================
; MODULE: Metrics Focus TTL Leak Meta Test
; DESCRIPTION:
; Static source guard for the metrics-focus-cache-ttl-leak finding.
;
; MF_RefreshFocus()'s cache-refresh gate is a pure time-based TTL, independent
; of real focus-change events. At the original 250 ms value, a fast typist
; landing 2-3 keystrokes inside that window right after alt-tabbing into a
; disabled/private app would have those keystrokes evaluated against the
; PREVIOUS window's stale (process_name, title, class), slipping past the
; privacy filter. The fix shrinks MF_FOCUS_TTL_MS to 50 ms — below realistic
; inter-keystroke intervals — bounding the leak window.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

; Scans the whole lib/metrics/ directory instead of one hardcoded file. The
; assertion below is a PRESENCE check, so widening the scope cannot weaken it —
; and _DriverDirConcat throws when the directory moves, instead of dying with an
; unreadable-path error that says nothing about the invariant at stake.
_MFTL_ReadSource() {
	return _DriverDirConcat("lib/metrics")
}




; ===================================================
; ===================================================
; ======= 2/ TTL bound assertion =====================
; ===================================================
; ===================================================

; Root cause: the leak window is exactly MF_FOCUS_TTL_MS wide. This asserts
; the constant is bounded well below a fast typist's inter-keystroke interval
; (50 ms) rather than the original 250 ms, which is wide enough for 2-3
; keystrokes to land inside it (metrics-focus-cache-ttl-leak).
_MFTL_FocusCacheTtlIsBounded() {
	Src := _MFTL_ReadSource()

	if !RegExMatch(Src, "global MF_FOCUS_TTL_MS := (\d+)", &m)
		Assert(false, "MF_FOCUS_TTL_MS must be declared as a global numeric constant in metrics_filters.ahk")

	Ttl := Integer(m[1])
	Assert(Ttl <= 50,
		"MF_FOCUS_TTL_MS must be <= 50 ms — the original 250 ms let 2-3 keystrokes from a fast typist land inside the stale window right after a focus switch, slipping past the privacy filter (metrics-focus-cache-ttl-leak)")
}
Test("metrics_filters: MF_FOCUS_TTL_MS bounded to <=50ms to close the post-focus-switch leak window (metrics-focus-cache-ttl-leak)", _MFTL_FocusCacheTtlIsBounded)
