; adapters/process_lifecycle.ahk

; ==============================================================================
; MODULE: ProcessLifecycle Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the ProcessLifecycle port contract. Provides
; callbacks for foreground-window (focus) changes via a SetTimer polling loop
; since AHK v2 exposes no native app-launch/quit notification mechanism short
; of WMI subscriptions. Launch and quit callbacks are accepted but never fired.
;
; NAMING CONVENTION:
; Port method        -> AHK name mapping:
;   onFocusChange(cb)  -> PLC_OnFocusChange(Callback)
;   onAppLaunch(cb)    -> PLC_OnAppLaunch(Callback)
;   onAppQuit(cb)      -> PLC_OnAppQuit(Callback)
;   getForegroundApp() -> PLC_GetForegroundApp()
;   start()            -> PLC_Start()
;   stop()             -> PLC_Stop()
;
; POLLING NOTES:
; PLC_Poll() is called every PLC_POLL_MS milliseconds by a SetTimer. It reads
; WinGetProcessName("A") and WinGetTitle("A") and fires all registered focus
; callbacks when either value changes. Errors inside Poll (e.g., window closed
; between calls) are silently swallowed to prevent timer disruption.
; ==============================================================================





; ===============================
; ===============================
; ======= 1/ Global State =======
; ===============================
; ===============================

; Array of callbacks invoked when the foreground window changes
global PLC_FocusCallbacks  := []

; Array of app-launch callbacks - accepted but never triggered on AHK (no WMI)
global PLC_LaunchCallbacks := []

; Array of app-quit callbacks - accepted but never triggered on AHK (no WMI)
global PLC_QuitCallbacks   := []

; Whether the polling timer is currently running
global PLC_Running         := false

; Process name of the last known foreground application
global PLC_LastAppId       := ""

; Window title of the last known foreground window
global PLC_LastWindowTitle := ""

; Polling interval fed to SetTimer - 250 ms balances responsiveness and CPU use
global PLC_POLL_MS         := 250





; ====================================
; ====================================
; ======= 2/ Adapter Functions =======
; ====================================
; ====================================

; Registers a callback invoked whenever the foreground window changes.
; The callback signature is: Callback(AppId, WindowTitle).
; Non-function values are silently ignored.
; @param Callback {Func} A callable object to append to PLC_FocusCallbacks.
PLC_OnFocusChange(Callback) {
	try {
		; Guard: only accept genuine callable objects
		if Type(Callback) = "Func"
			PLC_FocusCallbacks.Push(Callback)
	} catch {
		return
	}
}

; Registers a callback for application-launch events (stub - never fired).
; AHK v2 has no built-in launch notification without WMI; this is accepted
; to satisfy the port contract but will never be triggered.
; @param Callback {Func} A callable object to append to PLC_LaunchCallbacks.
PLC_OnAppLaunch(Callback) {
	try {
		if Type(Callback) = "Func"
			PLC_LaunchCallbacks.Push(Callback)
	} catch {
		return
	}
}

; Registers a callback for application-quit events (stub - never fired).
; Same constraint as PLC_OnAppLaunch: no WMI means no quit signal.
; @param Callback {Func} A callable object to append to PLC_QuitCallbacks.
PLC_OnAppQuit(Callback) {
	try {
		if Type(Callback) = "Func"
			PLC_QuitCallbacks.Push(Callback)
	} catch {
		return
	}
}

; Returns a Map describing the current foreground application.
; @return {Map} Map with keys "appId" (process name) and "windowTitle".
;               Both values are empty strings on error.
PLC_GetForegroundApp() {
	try {
		local AppId    := WinGetProcessName("A")
		local WinTitle := WinGetTitle("A")
		return Map("appId", AppId, "windowTitle", WinTitle)
	} catch {
		return Map("appId", "", "windowTitle", "")
	}
}

; Starts the focus-change polling timer. Idempotent - safe to call repeatedly.
; @return {void}
PLC_Start() {
	try {
		if PLC_Running
			return
		PLC_Running := true
		SetTimer(PLC_Poll, PLC_POLL_MS)
	} catch {
		return
	}
}

; Stops the focus-change polling timer. Idempotent - safe to call repeatedly.
; @return {void}
PLC_Stop() {
	try {
		if !PLC_Running
			return
		SetTimer(PLC_Poll, 0)
		PLC_Running := false
	} catch {
		return
	}
}





; ======================================
; ======================================
; ======= 3/ Internal Poll Logic =======
; ======================================
; ======================================

; Timer callback - compares current foreground window to last known state
; and fires all PLC_FocusCallbacks when either the process name or window
; title has changed. Errors are swallowed so a transient API failure (e.g.,
; the window closed between the SetTimer tick and the WinGet call) cannot
; permanently disrupt subsequent poll cycles.
PLC_Poll() {
	try {
		local NewApp   := WinGetProcessName("A")
		local NewTitle := WinGetTitle("A")
		if NewApp != PLC_LastAppId or NewTitle != PLC_LastWindowTitle {
			PLC_LastAppId       := NewApp
			PLC_LastWindowTitle := NewTitle
			for Cb in PLC_FocusCallbacks {
				try Cb(NewApp, NewTitle)
			}
		}
	} catch {
		; Silently ignore errors (window may have closed between poll calls)
	}
}

; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_PROCESS_LIFECYCLE := Map(
    "onFocusChange",    PLC_OnFocusChange,
    "onAppLaunch",      PLC_OnAppLaunch,
    "onAppQuit",        PLC_OnAppQuit,
    "getForegroundApp", PLC_GetForegroundApp,
    "start",            PLC_Start,
    "stop",             PLC_Stop,
)
