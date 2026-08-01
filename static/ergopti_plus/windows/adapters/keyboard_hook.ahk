; adapters/keyboard_hook.ahk

; ==============================================================================
; MODULE: KeyboardHook Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the KeyboardHook port contract defined in
; static/ergopti_plus/_shared/core/ports/KeyboardHook.spec.js. Wraps the unified
; HookDispatcher (infra/hook_dispatcher.ahk) behind the five canonical
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
; HOOK OWNERSHIP:
; This adapter no longer creates its own InputHook. Instead it registers
; _KH_DispatchChar and _KH_DispatchKey as subscribers with HookDispatcher so
; the process has exactly one InputHook shared by all features. KHStart /
; KHStop toggle the subscriber registration; the underlying hook lifecycle
; is managed entirely by HookDispatcher.Start() / HookDispatcher.Stop().
;
; INTERCEPT MODE:
; When opts["intercept"] is true the flag is stored but has no effect at this
; layer — AHK's shared InputHook runs in visible ("V") mode and cannot suppress
; events selectively per subscriber. Rather than silently swallow an inert
; option, KHStart emits a WARNING so the unsupported capability is loud (see the
; "no silent behavioral fallback" rule, CLAUDE.md 5.4) while keeping the option
; in the port contract (_shared/core/ports/KeyboardHook.spec.js).
; ==============================================================================

; Cached context (appId = process name, windowTitle = window caption).
global _KH_CONTEXT       := Map("appId", "", "windowTitle", "")
; User-registered callbacks stored by KHStart.
global _KH_ON_CHAR       := 0
global _KH_ON_KEY        := 0
global _KH_INTERCEPT     := false
; Whether this adapter's subscribers are currently registered with HookDispatcher.
global _KH_RUNNING       := false
; Bound dispatch callbacks — created ONCE (lazily, on first KHStart) and reused
; for both Register and Unregister. HookDispatcher matches subscribers by object
; identity (==), so a fresh _KH_DispatchChar.Bind() at KHStop is a different object
; than the one registered at KHStart — Unregister would never match and the
; subscriber would leak (KHStop a no-op → adapter keeps dispatching after stop).
global _KH_CB_CHAR       := 0
global _KH_CB_KEY        := 0




; ==========================================
; ==========================================
; ======= 1/ Adapter Methods ===============
; ==========================================
; ==========================================

; Starts the keyboard hook. Idempotent — safe to call while already running.
; Registers this adapter's dispatch callbacks with HookDispatcher instead of
; creating a separate InputHook, so the process keeps a single shared hook.
; @param Opts {Map|0} { intercept?: bool, onChar?: Func, onKey?: Func }
KHStart(Opts) {
	global _KH_RUNNING, _KH_ON_CHAR, _KH_ON_KEY, _KH_INTERCEPT, _KH_CB_CHAR, _KH_CB_KEY
	if _KH_RUNNING
		return
	if (Opts is Map) {
		if Opts.Has("onChar") and Opts["onChar"] != 0
			_KH_ON_CHAR := Opts["onChar"]
		if Opts.Has("onKey") and Opts["onKey"] != 0
			_KH_ON_KEY := Opts["onKey"]
		if Opts.Has("intercept") {
			_KH_INTERCEPT := Opts["intercept"] == true
			; The shared InputHook runs in visible ("V") mode, so intercept=true
			; cannot suppress events per-subscriber at this layer. Surface the
			; unsupported capability loudly instead of silently honoring a flag
			; that does nothing (CLAUDE.md 5.4 — no silent behavioral fallback).
			if _KH_INTERCEPT
				try LoggerWarn("KeyboardHook", "intercept=true requested but unsupported — the shared visible InputHook cannot suppress events per-subscriber; the key will still pass through.")
		}
	}
	; Warn if neither callback was supplied — events will be dispatched to no one
	if (_KH_ON_CHAR = 0 and _KH_ON_KEY = 0)
		try LoggerWarn("KeyboardHook", "KHStart called with both onChar and onKey = 0 — no events will be dispatched.")
	KHRefreshContext()
	; Register with the central dispatcher — no separate InputHook needed.
	; Bind once and cache so KHStop can Unregister the SAME object (identity match).
	if _KH_CB_CHAR = 0
		_KH_CB_CHAR := _KH_DispatchChar.Bind()
	if _KH_CB_KEY = 0
		_KH_CB_KEY := _KH_DispatchKey.Bind()
	HookDispatcher.Register(HookDispatcherConst.EVT_KB_CHAR, _KH_CB_CHAR)
	HookDispatcher.Register(HookDispatcherConst.EVT_KB_DOWN, _KH_CB_KEY)
	_KH_RUNNING := true
}

; Stops the keyboard hook. Safe to call when not running.
; Unregisters this adapter's subscribers from HookDispatcher; the shared
; InputHook itself keeps running for other subscribers.
KHStop() {
	global _KH_RUNNING, _KH_CB_CHAR, _KH_CB_KEY
	if !_KH_RUNNING
		return
	; Unregister the SAME cached BoundFunc objects registered in KHStart.
	if _KH_CB_CHAR != 0
		HookDispatcher.Unregister(HookDispatcherConst.EVT_KB_CHAR, _KH_CB_CHAR)
	if _KH_CB_KEY != 0
		HookDispatcher.Unregister(HookDispatcherConst.EVT_KB_DOWN, _KH_CB_KEY)
	; Reset cached callbacks so a subsequent KHStart() creates fresh BoundFunc
	; objects and can re-register with HookDispatcher (identity-based guard).
	_KH_CB_CHAR := 0
	_KH_CB_KEY  := 0
	_KH_RUNNING := false
}

; Returns true if the hook is currently active.
; @return {Integer} 1 (true) or 0 (false) — AHK boolean convention.
KHIsRunning() {
	global _KH_RUNNING
	return _KH_RUNNING ? 1 : 0
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

; Called by HookDispatcher for each printable character (keyboard_char event).
; Signature matches HookDispatcher.Dispatch(EVT_KB_CHAR, ih, char).
_KH_DispatchChar(IH, Char) {
	global _KH_ON_CHAR, _KH_CONTEXT
	if _KH_ON_CHAR = 0
		return
	Evt := Map("char", Char, "timestamp", A_TickCount, "appId", _KH_CONTEXT["appId"])
	; AHK-20: let exceptions propagate to HookDispatcher.Dispatch (the centralized
	; error sink) — a bare try here would swallow them and bypass stuck-modifier recovery
	_KH_ON_CHAR(Evt)
}

; Called by HookDispatcher for each key-down event (keyboard_down event).
; Signature matches HookDispatcher.Dispatch(EVT_KB_DOWN, ih, vk, sc).
_KH_DispatchKey(IH, VK, SC) {
	global _KH_ON_KEY, _KH_CONTEXT
	if _KH_ON_KEY = 0
		return
	Evt := Map("key", Format("{:02X}", VK), "timestamp", A_TickCount, "appId", _KH_CONTEXT["appId"])
	; AHK-20: same as above — let exceptions propagate to HookDispatcher.Dispatch
	_KH_ON_KEY(Evt)
}

; Port dispatch map (ADAPTER_KEYBOARD_HOOK) — the single-source-of-truth contract
; surface, verified against _shared/core/ports/contracts.json by
; tools/test/test-port-compliance.cjs.
global ADAPTER_KEYBOARD_HOOK := Map(
    "getContext", KHGetContext,
    "isRunning", KHIsRunning,
    "refreshContext", KHRefreshContext,
    "start", KHStart,
    "stop", KHStop
)
