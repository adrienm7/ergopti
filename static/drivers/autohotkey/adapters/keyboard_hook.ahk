; adapters/keyboard_hook.ahk

; ==============================================================================
; MODULE: KeyboardHook Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the KeyboardHook port contract defined in
; static/drivers/_shared/ports/KeyboardHook.spec.js. Wraps AHK's InputHook
; and WinGetActiveTitle / ProcessGetName APIs behind the five canonical
; functions (KHStart, KHStop, KHIsRunning, KHRefreshContext, KHGetContext).
;
; NAMING CONVENTION:
; Port method → AHK name mapping:
;   start(opts)       → KHStart(Opts)
;   stop()            → KHStop()
;   isRunning()       → KHIsRunning()
;   refreshContext()  → KHRefreshContext()
;   getContext()      → KHGetContext()
;
; INTERCEPT MODE:
; When opts["intercept"] is true, the hook may suppress events before they
; reach the OS. AHK's InputHook does not support real-time intercept in the
; same way as hs.eventtap; the production keylogger module owns the real hook.
; This adapter provides the contract interface; the intercept flag is stored
; but has no effect at this layer — production modules read it separately.
; ==============================================================================

; Active InputHook instance (0 = not running).
global _KH_HOOK          := 0
; Cached context (appId = process name, windowTitle = window caption).
global _KH_CONTEXT       := Map("appId", "", "windowTitle", "")
; User-registered callbacks stored by KHStart.
global _KH_ON_CHAR       := 0
global _KH_ON_KEY        := 0
global _KH_INTERCEPT     := false




; ==========================================
; ==========================================
; ======= 1/ Adapter Methods ===============
; ==========================================
; ==========================================

; Starts the keyboard hook. Idempotent — safe to call while already running.
; @param Opts {Map|0} { intercept?: bool, onChar?: Func, onKey?: Func }
KHStart(Opts) {
	global _KH_HOOK, _KH_ON_CHAR, _KH_ON_KEY, _KH_INTERCEPT
	if (_KH_HOOK != 0)
		return
	if (Opts is Map) {
		if Opts.Has("onChar") and Opts["onChar"] != 0
			_KH_ON_CHAR := Opts["onChar"]
		if Opts.Has("onKey") and Opts["onKey"] != 0
			_KH_ON_KEY := Opts["onKey"]
		if Opts.Has("intercept")
			_KH_INTERCEPT := Opts["intercept"] == true
	}
	KHRefreshContext()
	; Construct an InputHook that captures all keys so onKey can fire.
	IH := InputHook("V")
	; OnChar fires for each printable character typed.
	IH.OnChar := _KH_DispatchChar
	IH.OnKeyDown := _KH_DispatchKey
	IH.Start()
	_KH_HOOK := IH
}

; Stops the keyboard hook. Safe to call when not running.
KHStop() {
	global _KH_HOOK
	if (_KH_HOOK = 0)
		return
	try _KH_HOOK.Stop()
	_KH_HOOK := 0
}

; Returns true if the hook is currently active.
; @return {Integer} 1 (true) or 0 (false) — AHK boolean convention.
KHIsRunning() {
	global _KH_HOOK
	return _KH_HOOK != 0
}

; Re-reads the foreground application identity and caches it.
KHRefreshContext() {
	global _KH_CONTEXT
	try {
		Title   := WinGetTitle("A")
		Process := WinGetProcessName("A")
		_KH_CONTEXT["appId"]      := Process
		_KH_CONTEXT["windowTitle"] := Title
	} catch {
		_KH_CONTEXT["appId"]      := ""
		_KH_CONTEXT["windowTitle"] := ""
	}
}

; Returns the last-known foreground application identity.
; @return {Map} { appId, windowTitle }
KHGetContext() {
	global _KH_CONTEXT
	return Map("appId", _KH_CONTEXT["appId"], "windowTitle", _KH_CONTEXT["windowTitle"])
}




; ======================================================
; ======================================================
; ======= 2/ Internal Event Dispatch Callbacks =========
; ======================================================
; ======================================================

; Called by the InputHook for each printable character.
_KH_DispatchChar(IH, Char) {
	global _KH_ON_CHAR, _KH_CONTEXT
	if _KH_ON_CHAR = 0
		return
	Evt := Map("char", Char, "timestamp", A_TickCount, "appId", _KH_CONTEXT["appId"])
	try _KH_ON_CHAR(Evt)
}

; Called by the InputHook for each key-down event.
_KH_DispatchKey(IH, VK, SC) {
	global _KH_ON_KEY, _KH_CONTEXT
	if _KH_ON_KEY = 0
		return
	Evt := Map("key", Format("{1:X}", VK), "timestamp", A_TickCount, "appId", _KH_CONTEXT["appId"])
	try _KH_ON_KEY(Evt)
}
