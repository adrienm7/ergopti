; static/ergopti_plus/windows/lib/healthcheck.ahk

; ==============================================================================
; MODULE: Healthcheck
; DESCRIPTION:
; Diagnostic probe that snapshots the runtime state of the AutoHotkey driver
; and returns it in both structured (Map) and human-readable (string) form.
; ==============================================================================

#Requires AutoHotkey v2.0

; Module-level state — populated by HealthCheck_Init().
global _HealthCheckStartMs   := A_TickCount
global _HealthCheckLastError := ""
global _HealthCheckWarnCount := 0
global _HealthCheckErrCount  := 0

_HealthCheck_AdapterSpecs() {
	Specs := Map()
	Specs["clipboard"]             := ["CB_Read", "CB_Write"]
	Specs["file_system"]           := ["FSRead", "FSWrite", "FSExists"]
	Specs["http_client"]           := ["HTTPPost", "HTTPCancel"]
	Specs["keyboard_hook"]         := ["KHStart", "KHStop"]
	Specs["mouse_control"]         := ["MCSetPos", "MCGetPos"]
	Specs["network_info"]          := ["NI_GetSsidHash"]
	Specs["notifier"]              := ["NotifierSend"]
	Specs["process_lifecycle"]     := ["PLC_Start", "PLC_Stop"]
	Specs["secure_field_detector"] := ["SFD_IsSecureField"]
	Specs["storage"]               := ["ST_Get", "ST_Set"]
	Specs["text_sender"]           := ["TextSend", "TextEraseChars"]
	Specs["timer_scheduler"]       := ["TimerAfter", "TimerEvery"]
	Specs["tooltip_renderer"]      := ["TooltipRShow", "TooltipRHide"]
	Specs["tray_menu"]             := ["TrayMenuSetIcon", "TrayMenuSetMenu", "TrayMenuSetTooltip", "TrayMenuDestroy"]
	Specs["window_info"]           := ["WIGetFocused", "WIGetAll"]
	Specs["window_manager"]        := ["WMActivate", "WMExists"]
	return Specs
}

HealthCheck_RecordError(Msg) {
	global _HealthCheckLastError, _HealthCheckErrCount
	_HealthCheckLastError := Msg
	_HealthCheckErrCount  += 1
}

HealthCheck_RecordWarn() {
	global _HealthCheckWarnCount
	_HealthCheckWarnCount += 1
}

HealthCheck_Run() {
	global _HealthCheckStartMs, _HealthCheckLastError, _HealthCheckWarnCount, _HealthCheckErrCount
	
	; Safe defaults
	v_version := "local", v_loaded := [], v_validated := [], v_failed := [], v_uptime := 0, v_issues := []
	v_sys := Map(), v_pause := Map(), v_keylogger := Map(), v_llm := Map(), v_layout := Map(), v_hotstrings := Map(), v_logs := Map(), v_config := Map()

	try v_version := Updater_CurrentVersion()
	try {
		specs := _HealthCheck_AdapterSpecs()
		for id, fns in specs {
			ok := true
			for _, fn in fns {
				if !IsSet(%fn%) or !((%fn%) is Func)
					ok := false
			}
			if ok {
				v_loaded.Push(id)
				v_validated.Push(id)
			} else {
				v_failed.Push(id)
			}
		}
	}
	try v_uptime := (A_TickCount - _HealthCheckStartMs) // 1000
	try v_issues := _HealthCheck_RecentIssues(100)
	try v_sys    := _HealthCheck_SysInfo()
	try v_pause  := _HealthCheck_PauseState()
	try v_keylogger := _HealthCheck_KeyloggerSummary()
	try v_llm    := _HealthCheck_LLMState()
	try v_layout := _HealthCheck_LayoutState()
	try v_hotstrings := _HealthCheck_HotstringsState()
	try v_logs   := _HealthCheck_LogsInfo()
	try v_config := _HealthCheck_ConfigSummary()

	res := Map(
		"version", v_version, "loaded_adapters", v_loaded, "ports_validated", v_validated, "failed_adapters", v_failed,
		"last_error", _HealthCheckLastError, "uptime_sec", v_uptime, "warn_count", _HealthCheckWarnCount, "err_count", _HealthCheckErrCount,
		"sys", v_sys, "recent_issues", v_issues, "pause_state", v_pause, "keylogger", v_keylogger, "llm", v_llm,
		"layout", v_layout, "hotstrings", v_hotstrings, "logs", v_logs, "config", v_config
	)
	return res
}

HealthCheck_FormatMarkdown(Snapshot := 0) {
	if !(Snapshot is Map)
		Snapshot := HealthCheck_Run()
	return HealthCheck_FormatPlain(Snapshot)
}

HealthCheck_ShowWindow() {
	Snapshot  := HealthCheck_Run()
	PlainText := HealthCheck_FormatPlain(Snapshot)
	MsgBox(PlainText, "ErgoptiPlus — Healthcheck")
}

HealthCheck_FormatPlain(Snapshot) {
	Out := "=== ErgoptiPlus Healthcheck ===`n`n"
	Out .= "Version: " . Snapshot["version"] . "`n"
	Out .= "Uptime: " . Snapshot["uptime_sec"] . "s`n"
	Out .= "Warnings: " . Snapshot["warn_count"] . "`n"
	Out .= "Errors: " . Snapshot["err_count"] . "`n"
	Out .= "Last Error: " . Snapshot["last_error"] . "`n`n"
	Out .= "Adapters OK: " . Snapshot["ports_validated"].Length . "`n"
	Out .= "Adapters Failed: " . Snapshot["failed_adapters"].Length . "`n"
	return Out
}

HealthCheck_Format(Snapshot := 0) {
	if !(Snapshot is Map)
		Snapshot := HealthCheck_Run()
	return HealthCheck_FormatPlain(Snapshot)
}

_HealthCheck_SysInfo() {
	i := Map()
	i["ahk_version"] := A_AhkVersion
	i["os_name"] := A_OSVersion
	i["os_arch"] := A_Is64bitOS ? "64-bit" : "32-bit"
	i["locale"] := A_Language
	i["git_hash"] := ""
	i["config_dir"] := ""
	i["cpu_name"] := ""
	i["cpu_cores"] := 0
	i["ram_total_gb"] := 0
	i["ram_free_gb"] := 0
	i["screen_res"] := A_ScreenWidth . "x" . A_ScreenHeight
	i["dpi"] := A_ScreenDPI
	i["dpi_scale"] := 100
	return i
}

_HealthCheck_PauseState() {
	return Map("is_paused", !!A_IsSuspended, "source", "A_IsSuspended")
}

_HealthCheck_KeyloggerSummary() {
	return Map("events_session", 0, "wpm", 0, "privacy_hits", 0)
}

_HealthCheck_LLMState() {
	return Map("enabled", "unknown")
}

_HealthCheck_LayoutState() {
	return Map("ergopti_base", "unknown")
}

_HealthCheck_HotstringsState() {
	return Map("terminators", 0, "personal_count", 0, "dynamic_count", 0, "magic_key", "")
}

_HealthCheck_LogsInfo() {
	return Map("unified_today", "", "errors_today", "", "ring_lines", 0)
}

_HealthCheck_ConfigSummary() {
	return Map("overrides", 0, "config_files", [])
}

_HealthCheck_RecentIssues(Max) {
	return []
}
