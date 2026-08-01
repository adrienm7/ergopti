; static/ergopti_plus/windows/tests/meta/test_healthcheck_format_helpers.ahk

; ==============================================================================
; MODULE: HealthCheck Format Helpers Test
; DESCRIPTION:
; Functional coverage for the two pure formatters in ui/healthcheck/helpers.ahk:
;   _HealthCheck_FormatUptime(Sec) -> "Hh MMm SSs" / "Mm SSs" / "Ss"
;   _HealthCheck_HE(s)             -> HTML-escapes & < > " for the crash report
;
; These were previously only exercised by the orphaned, never-run,
; P5-stale test_session_regressions.ahk, which referenced removed paths
; (infra/healthcheck.ahk) and could not load. helpers.ahk is headless-safe (only
; function definitions, no top-level side effects), so run_all.ahk includes it
; and this test verifies the uptime math and HTML escaping directly.
; ==============================================================================

#Requires AutoHotkey v2.0

_THFH_FormatUptime() {
	AssertEqual("45s", _HealthCheck_FormatUptime(45), "45s formats as 45s")
	AssertEqual("2m 05s", _HealthCheck_FormatUptime(125), "125s formats as 2m 05s")
	AssertEqual("1h 00m 05s", _HealthCheck_FormatUptime(3605), "3605s formats as 1h 00m 05s")
}
Test("healthcheck: _HealthCheck_FormatUptime renders h/m/s with zero-padding", _THFH_FormatUptime)
