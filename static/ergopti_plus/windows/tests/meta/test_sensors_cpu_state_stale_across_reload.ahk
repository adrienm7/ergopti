; tests/meta/test_sensors_cpu_state_stale_across_reload.ahk

; ==============================================================================
; MODULE: Sensors CPU Baseline Reset Meta Test
; DESCRIPTION:
; Static source guard for the finding sensors-cpu-state-stale-across-reload.
;
; KLSensors.prev_idle/prev_kernel/prev_user are class statics holding the last
; GetSystemTimes snapshot for CPU-delta math. Statics persist for the lifetime
; of the AHK instance regardless of Stop/Start, so without an explicit reset the
; first system_load tick after a re-Start computes a delta straddling the whole
; off-period and emits one bogus CPU sample into the dashboard trend.
;
; The fix resets the three baseline statics to -1 in KL_Sensors_Stop so the next
; tick takes the ">= 0" guard's "record baseline only" branch, exactly as on a
; cold start. This test scans the source text of KL_Sensors_Stop and asserts the
; three baseline fields are invalidated there.
;
; This is a meta-static test (scans source text) because keylogger_sensors.ahk
; is not part of the headless runner include graph; calling its functions would
; be a load-time error.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_SCSR_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ==================================================
; ==================================================
; ======= 2/ Baseline-reset assertion ==============
; ==================================================
; ==================================================

_SCSR_StopResetsCpuBaseline() {
	Src := _SCSR_ReadSource("modules/keylogger/keylogger_sensors.ahk")
	Seg := _DriverFuncBody("KL_Sensors_Stop")
	Assert(Seg != "", "KL_Sensors_Stop() declaration must exist in keylogger_sensors.ahk")
	AssertContains(Seg, "KLSensors.prev_idle   := -1",
		"KL_Sensors_Stop must reset KLSensors.prev_idle to -1 — statics survive Stop/Start, so a stale CPU baseline would emit a bogus first sample after re-enabling")
	AssertContains(Seg, "KLSensors.prev_kernel := -1",
		"KL_Sensors_Stop must reset KLSensors.prev_kernel to -1 to invalidate the CPU delta baseline")
	AssertContains(Seg, "KLSensors.prev_user   := -1",
		"KL_Sensors_Stop must reset KLSensors.prev_user to -1 to invalidate the CPU delta baseline")
}
Test("sensors: KL_Sensors_Stop resets CPU baseline statics to -1 (sensors-cpu-state-stale-across-reload)", _SCSR_StopResetsCpuBaseline)
