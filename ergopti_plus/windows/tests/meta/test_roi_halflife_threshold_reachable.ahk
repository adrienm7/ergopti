; tests/meta/test_roi_halflife_threshold_reachable.ahk
; ==============================================================================
; MODULE: ROI Half-Life Threshold Reachability Meta Test
; DESCRIPTION:
; Static source guard for the F28 "trigger_halflife threshold dead code" bug.
;
; KL_Roi_HalflifeTick clamps the wrap-corrected tick age to MAX_SANE_AGE_MS
; before comparing it against a threshold derived from HALFLIFE_WARN_DAYS.
; When the clamp ceiling is BELOW the alert threshold the comparison can never
; be true — the alert becomes unreachable dead code.
;
; This test parses both values from the source file and asserts:
;   MAX_SANE_AGE_MS >= HALFLIFE_WARN_DAYS * 86400000
; so the alert path is always reachable.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================================
; ===================================================
; ======= 1/ Threshold reachability assertion =======
; ===================================================
; ===================================================

_RHTR_HalflifeAlertIsReachable() {
	; Move-resilient: scan the keylogger module dir via the framework helper instead
	; of a pinned keylogger_trigger_roi.ahk path. Both MAX_SANE_AGE_MS and
	; HALFLIFE_WARN_DAYS are static class constants (not function bodies), each
	; defined exactly once in the dir, so the value parse below stays unambiguous.
	Src := _DriverDirConcat("modules/keylogger")

	; --- parse MAX_SANE_AGE_MS ---------------------------------
	; Matches:  static MAX_SANE_AGE_MS := 3888000000
	ClampMs := 0
	if RegExMatch(Src, "MAX_SANE_AGE_MS\s*:=\s*(\d+)", &m1)
		ClampMs := Integer(m1[1])
	Assert(ClampMs > 0, "MAX_SANE_AGE_MS must be present and positive in keylogger_trigger_roi.ahk")

	; --- parse HALFLIFE_WARN_DAYS ------------------------------
	; Matches:  static HALFLIFE_WARN_DAYS   := 30
	WarnDays := 0
	if RegExMatch(Src, "HALFLIFE_WARN_DAYS\s*:=\s*(\d+)", &m2)
		WarnDays := Integer(m2[1])
	Assert(WarnDays > 0, "HALFLIFE_WARN_DAYS must be present and positive in keylogger_trigger_roi.ahk")

	; Convert warn days to milliseconds (same formula used at runtime)
	ThresholdMs := WarnDays * 86400000

	; The clamp ceiling must be >= the alert threshold or the alert is dead code
	Assert(ClampMs >= ThresholdMs,
		"MAX_SANE_AGE_MS (" . ClampMs . " ms) must be >= HALFLIFE_WARN_DAYS * 86400000 ("
		. ThresholdMs . " ms) — otherwise the trigger_halflife alert is unreachable dead code")
}
Test("keylogger_trigger_roi: MAX_SANE_AGE_MS clamp ceiling is >= HALFLIFE_WARN_DAYS alert threshold", _RHTR_HalflifeAlertIsReachable)
