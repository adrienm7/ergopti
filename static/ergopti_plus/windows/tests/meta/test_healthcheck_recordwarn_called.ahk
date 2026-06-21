; tests/meta/test_healthcheck_recordwarn_called.ahk

; ==============================================================================
; MODULE: HealthCheck RecordWarn Meta Test
; DESCRIPTION:
; Static source guard for the "healthcheck-recordwarn-never-called" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

_THR_Check() {
	Src := _DriverDirConcat("lib")
	Assert(Src != "", "Source file logger.ahk must exist")
	Assert(InStr(Src, "HealthCheck_RecordWarn()") > 0, "logger.ahk must call HealthCheck_RecordWarn")
	Assert(InStr(Src, "HealthCheck_RecordError(Body)") > 0, "logger.ahk must call HealthCheck_RecordError")
}

Test("HealthCheck: logger increments warn/err counters", _THR_Check)
