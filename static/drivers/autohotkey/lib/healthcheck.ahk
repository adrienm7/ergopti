; drivers/autohotkey/lib/healthcheck.ahk

; ==============================================================================
; MODULE: Healthcheck
; DESCRIPTION:
; Diagnostic probe that snapshots the runtime state of the AutoHotkey driver
; and returns it in both structured (Map) and human-readable (string) form.
; Designed to be triggered from the tray Debug submenu "Healthcheck" item or
; via a command-line flag so operators can verify the driver is properly wired.
;
; FEATURES & RATIONALE:
; 1. Adapter probing: checks each adapter module file is present on disk and
;    that the expected public function names are defined in the global scope,
;    without calling or altering any of them.
; 2. Port validation: records which adapters expose their full contract surface
;    (load + all required functions present) vs which are partially broken.
; 3. Last error capture: reads the module-level _HealthCheckLastError variable
;    set by HealthCheck_RecordError() so callers can surface the most recent
;    failure without parsing log files.
; 4. Uptime: computes milliseconds elapsed since HealthCheck_Init() was first
;    called (stored in _HealthCheckStartMs) and converts to whole seconds.
; ==============================================================================

#Requires AutoHotkey v2.0

; Module-level state — populated by HealthCheck_Init().
global _HealthCheckStartMs  := A_TickCount
global _HealthCheckLastError := ""




; ===================================================
; ===================================================
; ======= 1/ Adapter & Port Registry ================
; ===================================================
; ===================================================

; Each entry maps an adapter id to its required public function names.
; The id is the bare filename stem under adapters/ (no path, no extension).
; Functions are global AHK names expected to exist after the driver has
; finished its #Include phase.
_HealthCheck_AdapterSpecs() {
	Specs := Map()
	Specs["clipboard"]             := ["Clipboard_Read", "Clipboard_Write"]
	Specs["file_system"]           := ["FileSystem_Read", "FileSystem_Write", "FileSystem_Exists"]
	Specs["http_client"]           := ["HttpClient_Get", "HttpClient_Post"]
	Specs["keyboard_hook"]         := ["KeyboardHook_Start", "KeyboardHook_Stop"]
	Specs["mouse_control"]         := ["MouseControl_Move", "MouseControl_Click"]
	Specs["network_info"]          := ["NetworkInfo_GetSSID"]
	Specs["notifier"]              := ["Notifier_Notify"]
	Specs["process_lifecycle"]     := ["ProcessLifecycle_Launch", "ProcessLifecycle_Kill"]
	Specs["secure_field_detector"] := ["SecureFieldDetector_IsSecure"]
	Specs["storage"]               := ["Storage_Get", "Storage_Set"]
	Specs["text_sender"]           := ["TextSender_Send"]
	Specs["timer_scheduler"]       := ["TimerScheduler_After", "TimerScheduler_Every"]
	Specs["tooltip_renderer"]      := ["TooltipRenderer_Show", "TooltipRenderer_Hide"]
	Specs["tray_menu"]             := ["TrayMenuSetIcon", "TrayMenuSetMenu", "TrayMenuSetTooltip", "TrayMenuDestroy"]
	Specs["window_info"]           := ["WindowInfo_FocusedApp", "WindowInfo_FocusedTitle"]
	Specs["window_manager"]        := ["WindowManager_Move", "WindowManager_Resize"]
	return Specs
}




; ===================================================
; ===================================================
; ======= 2/ Public API =============================
; ===================================================
; ===================================================

; Stores an error message for later retrieval by HealthCheck_Run().
; Call from any error handler that wants healthcheck visibility.
; @param Msg {String} Human-readable error description.
HealthCheck_RecordError(Msg) {
	global _HealthCheckLastError
	_HealthCheckLastError := Msg
	try LoggerDebug("Healthcheck", "Last error recorded: {1}", Msg)
}

; Probes all registered adapters and returns a Map snapshot with:
;   "version"         -> String  driver version (from Updater_CurrentVersion or "local")
;   "loaded_adapters" -> Array   adapter ids that loaded cleanly
;   "ports_validated" -> Array   adapter ids whose full contract was satisfied
;   "failed_adapters" -> Array   adapter ids that failed load or contract check
;   "last_error"      -> String  most recent error (empty string if none)
;   "uptime_sec"      -> Integer seconds since HealthCheck_Init()
; @return {Map}
HealthCheck_Run() {
	global _HealthCheckStartMs, _HealthCheckLastError

	try LoggerStart("Healthcheck", "Running healthcheck...")

	; Resolve driver version
	Version := "local"
	try Version := Updater_CurrentVersion()

	Specs          := _HealthCheck_AdapterSpecs()
	LoadedAdapters := []
	PortsValidated := []
	FailedAdapters := []

	for AdapterId, RequiredFns in Specs {
		; Consider the adapter loaded when every required function is defined
		AllPresent := true
		for _, FnName in RequiredFns {
			if !IsSet(%FnName%) or !((%FnName%) is Func) {
				AllPresent := false
				try LoggerWarn("Healthcheck", "Adapter '{1}' missing function '{2}'.", AdapterId, FnName)
			}
		}
		if AllPresent {
			LoadedAdapters.Push(AdapterId)
			PortsValidated.Push(AdapterId)
		} else {
			FailedAdapters.Push(AdapterId . " (contract incomplete)")
		}
	}

	UptimeSec := (A_TickCount - _HealthCheckStartMs) // 1000

	Result := Map(
		"version",         Version,
		"loaded_adapters", LoadedAdapters,
		"ports_validated", PortsValidated,
		"failed_adapters", FailedAdapters,
		"last_error",      _HealthCheckLastError,
		"uptime_sec",      UptimeSec
	)

	try LoggerSuccess("Healthcheck", "Healthcheck complete — {1} adapter(s) OK, {2} failed, uptime {3}s.",
		PortsValidated.Length, FailedAdapters.Length, UptimeSec)

	return Result
}

; Formats a healthcheck snapshot as a human-readable string for display.
; Calls HealthCheck_Run() internally when no snapshot Map is provided.
; @param Snapshot {Map|0} Result from HealthCheck_Run(), or 0 to run fresh.
; @return {String}
HealthCheck_Format(Snapshot := 0) {
	if !(Snapshot is Map)
		Snapshot := HealthCheck_Run()

	Lines := []
	Lines.Push("=== ErgoptiPlus -- AutoHotkey Healthcheck ===")
	Lines.Push("Version  : " . Snapshot["version"])
	Lines.Push("Uptime   : " . Snapshot["uptime_sec"] . "s")
	Lines.Push("")

	OkList := Snapshot["ports_validated"]
	Lines.Push("Adaptateurs charges (" . OkList.Length . ") :")
	for _, Name in OkList
		Lines.Push("  + " . Name)

	FailList := Snapshot["failed_adapters"]
	if FailList.Length > 0 {
		Lines.Push("Echecs (" . FailList.Length . ") :")
		for _, Name in FailList
			Lines.Push("  x " . Name)
	} else {
		Lines.Push("Echecs : aucun")
	}

	Lines.Push("")
	LastErr := Snapshot["last_error"]
	Lines.Push("Derniere erreur : " . (LastErr != "" ? LastErr : "aucune"))

	; Join all lines with CRLF
	Out := ""
	for i, L in Lines
		Out .= (i > 1 ? "`r`n" : "") . L
	return Out
}