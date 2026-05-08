; modules/keylogger_sensors.ahk

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
; 1. CPU % — queried via WMI Win32_PerfFormattedData_PerfOS_Processor
;    (instance "_Total"). This is the same counter Taskmgr displays; it
;    is a rolling average over the WMI refresh interval (~1 s) so a
;    single reading is already noise-smoothed without extra math.
; 2. RAM — two counters from WMI Win32_OperatingSystem:
;    FreePhysicalMemory (kB) and TotalVisibleMemorySize (kB). We compute
;    ram_used_pct = Round((total - free) / total * 100). No external DLL.
; 3. Battery — Win32_Battery gives EstimatedChargeRemaining (0-100) and
;    BatteryStatus (1=discharging, 2=AC, 3=fully charged). If no battery
;    is present the WMI query returns an empty result and the fields are
;    omitted from the snapshot.
; 4. Thermal state — heuristic derived from CPU load:
;    < 40 % → "normal", 40-79 % → "moderate", ≥ 80 % → "high".
;    Full hardware thermal readings require WMI provider extensions that
;    are not available on all OEMs; the load-based proxy is reliable
;    enough for heatmap visualization and break suggestions.
; 5. Privacy — snapshots are only emitted when Keylogger.initialized is
;    true (i.e., the metrics feature is on) and pass through the standard
;    MF_ShouldFilter() gate. No personal data is captured.
; 6. Batching — the timer period is intentionally long
;    (SENSOR_TICK_MS = 60 000 ms). One snapshot per minute is sufficient
;    for trend graphs; more frequent polls add WMI overhead without
;    improving UI accuracy at the dashboard's 5-minute granularity.
;
; LIFECYCLE:
; - KL_Sensors_Start() is called after KL_Mouse_Start() in ErgoptiPlus.ahk.
; - KL_Sensors_Stop() cancels the timer.
; ==============================================================================

#Requires Autohotkey v2.0+




; ===================================
; ===================================
; ======= 1/ Constants =======
; ===================================
; ===================================

class KLSensorConst {
    ; One snapshot per minute — coarse enough to be cheap, fine enough
    ; for per-hour aggregation in the dashboard.
    static SENSOR_TICK_MS     := 60000

    ; CPU load thresholds for the thermal_state heuristic (%).
    static THERMAL_MODERATE   := 40
    static THERMAL_HIGH       := 80
}




; ===================================
; ===================================
; ======= 2/ Module state =======
; ===================================
; ===================================

class KLSensors {
    static tick_fn := unset
}




; =========================================
; =========================================
; ======= 3/ Snapshot collection =======
; =========================================
; =========================================

KL_Sensors_Tick() {
    if !Keylogger.initialized
        return
    filtered := false
    try filtered := MF_ShouldFilter()
    if filtered
        return

    meta := Map()

    ; ── CPU ──────────────────────────────────────────────────────────────
    cpu_pct := -1
    try {
        q := ComObjGet("winmgmts:").ExecQuery(
            "SELECT PercentProcessorTime FROM Win32_PerfFormattedData_PerfOS_Processor"
            . " WHERE Name='_Total'")
        for item in q {
            cpu_pct := item.PercentProcessorTime
            break
        }
    }
    if (cpu_pct >= 0) {
        meta["cpu_pct"] := cpu_pct
        ; Thermal heuristic
        if (cpu_pct >= KLSensorConst.THERMAL_HIGH)
            meta["thermal_state"] := "high"
        else if (cpu_pct >= KLSensorConst.THERMAL_MODERATE)
            meta["thermal_state"] := "moderate"
        else
            meta["thermal_state"] := "normal"
    }

    ; ── RAM ──────────────────────────────────────────────────────────────
    try {
        q := ComObjGet("winmgmts:").ExecQuery(
            "SELECT FreePhysicalMemory, TotalVisibleMemorySize FROM Win32_OperatingSystem")
        for item in q {
            total := item.TotalVisibleMemorySize
            free  := item.FreePhysicalMemory
            if (total > 0)
                meta["ram_used_pct"] := Round((total - free) / total * 100)
            ; Expose absolute values in MB for the dashboard
            meta["ram_total_mb"] := Round(total / 1024)
            meta["ram_free_mb"]  := Round(free  / 1024)
            break
        }
    }

    ; ── Battery ──────────────────────────────────────────────────────────
    try {
        q := ComObjGet("winmgmts:").ExecQuery(
            "SELECT EstimatedChargeRemaining, BatteryStatus"
            . " FROM Win32_Battery")
        for item in q {
            meta["battery_pct"]    := item.EstimatedChargeRemaining
            ; BatteryStatus: 1=discharging, 2=AC, 3=fully-charged
            st := item.BatteryStatus
            if (st = 2 or st = 3)
                meta["on_ac"] := true
            else
                meta["on_ac"] := false
            break
        }
    }

    KL_LogSystemEvent("system_load", meta)
}




; =====================================
; =====================================
; ======= 4/ Lifecycle =======
; =====================================
; =====================================

KL_Sensors_Start() {
    if KLSensors.HasOwnProp("tick_fn") && IsObject(KLSensors.tick_fn)
        return
    KLSensors.tick_fn := KL_Sensors_Tick.Bind()
    ; Fire once shortly after start so the dashboard has initial data
    ; without waiting the full 60 s.
    SetTimer(KLSensors.tick_fn, -2000)
    SetTimer(KLSensors.tick_fn, KLSensorConst.SENSOR_TICK_MS)
}

KL_Sensors_Stop() {
    if KLSensors.HasOwnProp("tick_fn") && IsObject(KLSensors.tick_fn) {
        try SetTimer(KLSensors.tick_fn, 0)
        KLSensors.tick_fn := unset
    }
}
