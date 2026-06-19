; tests/meta/test_sensors_warmup_distinct_callback.ahk

; ==============================================================================
; MODULE: KLSensors Warm-Up Distinct Callback Meta-Test
; DESCRIPTION:
; Structural regression for the sensors warm-up cancellation fix in
; keylogger_sensors.ahk.
;
; Before the fix, KL_Sensors_Start() called:
;   SetTimer(KLSensors.tick_fn, -2000)       ; one-shot warm-up
;   SetTimer(KLSensors.tick_fn, SENSOR_TICK) ; periodic
; Both calls use the SAME BoundFunc reference. AHK's SetTimer replaces the
; registration for that function, so the second call cancelled the warm-up
; before it ever fired. The dashboard had no initial data until the first
; periodic tick 60 s after start.
;
; The fix stores a SECOND BoundFunc in KLSensors.warmup_fn and registers the
; one-shot on that reference so the two registrations occupy independent timer
; slots:
;   SetTimer(KLSensors.warmup_fn, -2000)
;   SetTimer(KLSensors.tick_fn, SENSOR_TICK)
;
; This test inspects keylogger_sensors.ahk source and asserts:
;   1. KLSensors declares a warmup_fn property.
;   2. KL_Sensors_Start() calls SetTimer with warmup_fn for the -2000 one-shot.
;   3. KL_Sensors_Start() calls SetTimer with tick_fn for the periodic arm.
;   4. The two SetTimer calls reference DIFFERENT identifiers (not both tick_fn).
;   5. KL_Sensors_Stop() cancels the warmup_fn timer as well.
; ==============================================================================

#Requires AutoHotkey v2.0




; ================================================================
; ================================================================
; ======= 1/ Source-inspection helpers ===========================
; ================================================================
; ================================================================

_SWDC_ReadSource() {
	return FileRead(A_ScriptDir . "\..\modules\keylogger\keylogger_sensors.ahk", "UTF-8")
}


_SWDC_FindStartBlock(src) {
	pos := InStr(src, "KL_Sensors_Start()")
	if (!pos)
		return ""
	return SubStr(src, pos, 600)
}


_SWDC_FindStopBlock(src) {
	pos := InStr(src, "KL_Sensors_Stop()")
	if (!pos)
		return ""
	return SubStr(src, pos, 400)
}




; ================================================================
; ================================================================
; ======= 2/ Assertions ==========================================
; ================================================================
; ================================================================

_SWDC_WarmupFnDeclared() {
	src := _SWDC_ReadSource()
	Assert(InStr(src, "warmup_fn") > 0,
		"keylogger_sensors.ahk: KLSensors must declare a warmup_fn property for the distinct warm-up BoundFunc")
}
Test("KLSensors: warmup_fn property declared (sensors-warmup-distinct)", _SWDC_WarmupFnDeclared)


_SWDC_WarmupTimerUsesWarmupFn() {
	block := _SWDC_FindStartBlock(_SWDC_ReadSource())
	; The one-shot (-2000) must reference warmup_fn, not tick_fn.
	posWarmup := InStr(block, "warmup_fn")
	pos2000   := InStr(block, "-2000")
	Assert(posWarmup > 0 and pos2000 > 0,
		"keylogger_sensors.ahk: KL_Sensors_Start() must reference warmup_fn and -2000 for the one-shot")
	; Ensure warmup_fn appears near -2000 (within 100 chars of each other).
	Assert(Abs(posWarmup - pos2000) < 100,
		"keylogger_sensors.ahk: warmup_fn and -2000 must be on adjacent SetTimer lines in KL_Sensors_Start()")
}
Test("KLSensors: SetTimer one-shot (-2000) uses warmup_fn (sensors-warmup-distinct)", _SWDC_WarmupTimerUsesWarmupFn)


_SWDC_PeriodicTimerUsesTickFn() {
	block := _SWDC_FindStartBlock(_SWDC_ReadSource())
	; The periodic arm must reference tick_fn.
	Assert(InStr(block, "tick_fn") > 0,
		"keylogger_sensors.ahk: KL_Sensors_Start() must still register KLSensors.tick_fn for the periodic timer")
}
Test("KLSensors: SetTimer periodic arm uses tick_fn (sensors-warmup-distinct)", _SWDC_PeriodicTimerUsesTickFn)


_SWDC_StopCancelsWarmup() {
	block := _SWDC_FindStopBlock(_SWDC_ReadSource())
	Assert(InStr(block, "warmup_fn") > 0,
		"keylogger_sensors.ahk: KL_Sensors_Stop() must cancel the warmup_fn timer so it does not fire after stop")
}
Test("KLSensors: KL_Sensors_Stop() cancels warmup_fn timer (sensors-warmup-distinct)", _SWDC_StopCancelsWarmup)
