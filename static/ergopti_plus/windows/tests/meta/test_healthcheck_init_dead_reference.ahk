; tests/meta/test_healthcheck_init_dead_reference.ahk

; ==============================================================================
; MODULE: HealthCheck Init Dead-Reference Meta Test
; DESCRIPTION:
; Static source guard for the "healthcheck-init-dead-reference" finding.
;
; healthcheck.ahk documented HealthCheck_Init() as the uptime origin, but no
; such function was ever implemented — _HealthCheckStartMs is captured at module
; load (parse time) instead. The dangling references in the comments/docstrings
; were a maintenance footgun: a maintainer could add code that calls
; HealthCheck_Init() per the contract and it would silently do nothing.
;
; The fix removes every HealthCheck_Init reference from the comments/docstrings
; and documents the module-load origin. This guard fails if the name reappears
; UNLESS it reappears as a genuine function definition (regex
; `HealthCheck_Init\s*(`), which would make the contract honest again.
;
; Meta-static (scans source text): healthcheck.ahk registers no top-level
; hooks/timers usable by the headless runner, and is not in the run_all include
; graph, so it cannot be #Included here.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helper =====================
; ===================================================
; ===================================================

; True when the source contains a real function definition for the given name,
; i.e. the name immediately followed (after optional spaces) by an opening paren.
_HCIDR_HasFuncDef(Src, Name) {
	return RegExMatch(Src, Name . "\s*\(") > 0
}




; ===================================================
; ===================================================
; ======= 2/ Dead-reference assertion ===============
; ===================================================
; ===================================================

_HCIDR_NoDanglingInit() {
	Src := _DriverDirConcat("ui/healthcheck")
	Assert(Src != "", "the ui/healthcheck module must exist")
	; The contract must either not mention HealthCheck_Init at all, or back it
	; with a real function definition. A bare mention (comment/docstring) with no
	; definition is the regression we are guarding against.
	Mentioned := InStr(Src, "HealthCheck_Init") > 0
	HasDef    := _HCIDR_HasFuncDef(Src, "HealthCheck_Init")
	Assert(!Mentioned || HasDef,
		"healthcheck.ahk references HealthCheck_Init but never defines it — the uptime origin is _HealthCheckStartMs captured at module load; remove the dangling reference or implement the function")
}
Test("HealthCheck: no dangling HealthCheck_Init reference (healthcheck-init-dead-reference)", _HCIDR_NoDanglingInit)

_HCIDR_StartMsAnchored() {
	Src := _DriverDirConcat("ui/healthcheck")
	; The uptime origin must still be the module-load tick capture — the single
	; source of truth crash_reporter.ahk also reads.
	Assert(InStr(Src, "_HealthCheckStartMs   := A_TickCount") > 0,
		"healthcheck.ahk must capture _HealthCheckStartMs := A_TickCount at module load — it is the single source of truth for the uptime origin")
}
Test("HealthCheck: _HealthCheckStartMs anchored at module load (healthcheck-init-dead-reference)", _HCIDR_StartMsAnchored)
