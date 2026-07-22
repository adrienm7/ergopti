; modules/keylogger/keylogger_sensors.ahk

; ==============================================================================
; MODULE: Keylogger System Sensors
; DESCRIPTION:
; Periodic snapshots of CPU load, RAM usage, battery level, and thermal
; state. Each snapshot is emitted as a ``system_event`` with action
; ``system_load`` — the SQL builder in keylogger.ahk already handles
; this action type and routes it into events_system with a JSON metadata
; column so we can add fields freely without schema migrations.
;
; FEATURES & RATIONALE:
; 1. CPU % — two calls to GetSystemTimes spaced one tick apart give idle,
;    kernel, and user time deltas; cpu_pct = 100 - idle_pct. This is the
;    same approach used by Task Manager and is a pure kernel32 call with
;    microsecond latency — no subprocess, no WMI cold-start.
; 2. RAM — GlobalMemoryStatusEx (kernel32) returns dwMemoryLoad (0-100 %
;    used), ullTotalPhys, and ullAvailPhys in a single in-process call.
;    Replaces WMI Win32_OperatingSystem which blocked the AHK thread.
; 3. Battery — GetSystemPowerStatus (kernel32) returns the charge level
;    (0-100, 255 = unknown) and AC/DC flag in one syscall. Replaces WMI
;    Win32_Battery which is unavailable on desktops and slow on laptops.
; 4. Thermal state — heuristic derived from CPU load:
;    < 40 % → "normal", 40-79 % → "moderate", ≥ 80 % → "high".
; 5. Privacy — snapshots are only emitted when Keylogger.initialized is
;    true (i.e., the metrics feature is on) and pass through the standard
;    MF_ShouldFilter() gate. No personal data is captured.
; 6. Batching — the timer period is intentionally long
;    (SENSOR_TICK_MS = 60 000 ms). One snapshot per minute is sufficient
;    for trend graphs.
;
; LIFECYCLE:
; - KL_Sensors_Start is called after KL_Mouse_Start() in ErgoptiPlus.ahk.
; - KL_Sensors_Stop cancels the timer.
; ==============================================================================

#Requires Autohotkey v2.0+





; ===================================
; ============================
; ======= 1/ Constants =======
; ============================
; ===================================

class KLSensorConst {
	; One snapshot per minute — coarse enough to be cheap, fine enough
	; for per-hour aggregation in the dashboard.
	static SENSOR_TICK_MS := 60000

	; CPU load thresholds for the thermal_state heuristic (%).
	static THERMAL_MODERATE := 40
	static THERMAL_HIGH      := 80
}





; ===================================
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===================================

class KLSensors {
	static tick_fn      := unset
	; Separate BoundFunc for the warm-up one-shot so it does not share a
	; SetTimer registration with tick_fn — AHK replaces the previous period
	; when the same function reference is re-registered, which would cancel
	; the warm-up before it ever fires.
	static warmup_fn    := unset

	; Last GetSystemTimes snapshot for CPU delta computation.
	; FILETIME values are 64-bit 100-ns ticks stored as two 32-bit DWORDs
	; (low, high); we combine them into a single integer for arithmetic.
	static prev_idle   := -1
	static prev_kernel := -1
	static prev_user   := -1
}





; =========================================
; ======================================
; ======= 3/ Snapshot collection =======
; ======================================
; =========================================

KL_Sensors_Tick() {
	if !Keylogger.initialized
		return
	if A_IsSuspended
		return
	filtered := false
	try filtered := MF_ShouldFilter()
	if filtered
		return

	meta := Map()

	; ── CPU via GetSystemTimes ────────────────────────────────────────────
	; GetSystemTimes fills three FILETIME structs (idle, kernel, user).
	; FILETIME = two consecutive DWORDs (low word first); we combine them
	; with (high << 32 | low) to get 64-bit 100-ns tick counts.
	; cpu_pct = (1 - idle_delta / (kernel_delta + user_delta)) * 100.
	; Note: kernel time includes idle time, so total = kernel + user (not idle).
	buf := Buffer(24, 0)   ; 3 × FILETIME (8 bytes each)
	if DllCall("kernel32\GetSystemTimes",
			"Ptr", buf.Ptr,      ; lpIdleTime
			"Ptr", buf.Ptr + 8,  ; lpKernelTime
			"Ptr", buf.Ptr + 16, ; lpUserTime
			"Int") {
		idle   := NumGet(buf,  0, "UInt") | (NumGet(buf,  4, "UInt") << 32)
		kernel := NumGet(buf,  8, "UInt") | (NumGet(buf, 12, "UInt") << 32)
		user   := NumGet(buf, 16, "UInt") | (NumGet(buf, 20, "UInt") << 32)

		if (KLSensors.prev_idle >= 0) {
			d_idle   := idle   - KLSensors.prev_idle
			d_kernel := kernel - KLSensors.prev_kernel
			d_user   := user   - KLSensors.prev_user
			d_total  := d_kernel + d_user   ; kernel already includes idle
			if (d_total > 0) {
				cpu_pct := Round((1.0 - d_idle / d_total) * 100)
				cpu_pct := Max(0, Min(100, cpu_pct))
				meta["cpu_pct"] := cpu_pct
				if (cpu_pct >= KLSensorConst.THERMAL_HIGH)
					meta["thermal_state"] := "high"
				else if (cpu_pct >= KLSensorConst.THERMAL_MODERATE)
					meta["thermal_state"] := "moderate"
				else
					meta["thermal_state"] := "normal"
			}
		}

		KLSensors.prev_idle   := idle
		KLSensors.prev_kernel := kernel
		KLSensors.prev_user   := user
	}

	; ── RAM via GlobalMemoryStatusEx ─────────────────────────────────────
	; MEMORYSTATUSEX: dwLength(4) + dwMemoryLoad(4) + ullTotalPhys(8) +
	; ullAvailPhys(8) + … = 64 bytes total. dwLength must be pre-filled.
	mem := Buffer(64, 0)
	NumPut("UInt", 64, mem, 0)   ; dwLength
	if DllCall("kernel32\GlobalMemoryStatusEx", "Ptr", mem, "Int") {
		ram_used_pct := NumGet(mem, 4, "UInt")
		total_phys   := NumGet(mem, 8, "UInt64")
		avail_phys   := NumGet(mem, 16, "UInt64")
		meta["ram_used_pct"] := ram_used_pct
		meta["ram_total_mb"] := Round(total_phys / 1048576)
		meta["ram_free_mb"]  := Round(avail_phys / 1048576)
	}

	; ── Battery via GetSystemPowerStatus ─────────────────────────────────
	; SYSTEM_POWER_STATUS: ACLineStatus(1) + BatteryFlag(1) +
	; BatteryLifePercent(1) + SystemStatusFlag(1) + BatteryLifeTime(4) +
	; BatteryFullLifeTime(4) = 12 bytes.
	; BatteryLifePercent = 255 when unknown (no battery / desktop).
	pwr := Buffer(12, 0)
	if DllCall("kernel32\GetSystemPowerStatus", "Ptr", pwr, "Int") {
		ac_line  := NumGet(pwr, 0, "UChar")   ; 0=battery, 1=AC, 255=unknown
		batt_pct := NumGet(pwr, 2, "UChar")   ; 255 = unknown
		if (batt_pct != 255) {
			meta["battery_pct"] := batt_pct
			meta["on_ac"]       := (ac_line = 1)
		}
	}

	KL_LogSystemEvent("system_load", meta)
}





; =====================================
; ============================
; ======= 4/ Lifecycle =======
; ============================
; =====================================

KL_Sensors_Start() {
	if KLSensors.HasOwnProp("tick_fn") && IsObject(KLSensors.tick_fn)
		return
	KLSensors.tick_fn   := KL_Sensors_Tick.Bind()
	; The warm-up one-shot uses a distinct BoundFunc so that registering the
	; periodic timer below does not cancel the warm-up. AHK replaces the
	; period of an existing timer when the same function reference is
	; re-registered; two distinct references get two independent timer slots.
	KLSensors.warmup_fn := KL_Sensors_Tick.Bind()
	SetTimer(KLSensors.warmup_fn, -2000)
	SetTimer(KLSensors.tick_fn, KLSensorConst.SENSOR_TICK_MS)
}

KL_Sensors_Stop() {
	if KLSensors.HasOwnProp("warmup_fn") && IsObject(KLSensors.warmup_fn) {
		try SetTimer(KLSensors.warmup_fn, 0)
		KLSensors.warmup_fn := unset
	}
	if KLSensors.HasOwnProp("tick_fn") && IsObject(KLSensors.tick_fn) {
		try SetTimer(KLSensors.tick_fn, 0)
		KLSensors.tick_fn := unset
	}
	; Statics survive Stop/Start for the AHK instance lifetime; invalidate the
	; CPU baseline so the first tick after a re-Start re-establishes a fresh
	; delta instead of straddling the off-period and emitting a bogus sample.
	KLSensors.prev_idle   := -1
	KLSensors.prev_kernel := -1
	KLSensors.prev_user   := -1
}
