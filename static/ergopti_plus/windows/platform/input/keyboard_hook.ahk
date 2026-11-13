; platform/input/keyboard_hook.ahk

; ==============================================================================
; MODULE: KeyboardHook Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the KeyboardHook port contract defined in
; static/ergopti_plus/_shared/core/ports/KeyboardHook.spec.js. Wraps the unified
; HookDispatcher (platform/input/hook_dispatcher.ahk) behind the five canonical
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
global _KH_CB_KEY_DOWN   := 0
global _KH_CB_KEY_UP     := 0




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
	global _KH_RUNNING, _KH_ON_CHAR, _KH_ON_KEY, _KH_INTERCEPT
	global _KH_CB_CHAR, _KH_CB_KEY_DOWN, _KH_CB_KEY_UP
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
	if _KH_CB_KEY_DOWN = 0
		_KH_CB_KEY_DOWN := _KH_DispatchKey.Bind(true)
	if _KH_CB_KEY_UP = 0
		_KH_CB_KEY_UP := _KH_DispatchKey.Bind(false)
	HookDispatcher.Register(HookDispatcherConst.EVT_KB_CHAR, _KH_CB_CHAR)
	HookDispatcher.Register(HookDispatcherConst.EVT_KB_DOWN, _KH_CB_KEY_DOWN)
	HookDispatcher.Register(HookDispatcherConst.EVT_KB_UP, _KH_CB_KEY_UP)
	_KH_RUNNING := true
}

; Stops the keyboard hook. Safe to call when not running.
; Unregisters this adapter's subscribers from HookDispatcher; the shared
; InputHook itself keeps running for other subscribers.
KHStop() {
	global _KH_RUNNING, _KH_CB_CHAR, _KH_CB_KEY_DOWN, _KH_CB_KEY_UP
	if !_KH_RUNNING
		return
	; Unregister the SAME cached BoundFunc objects registered in KHStart.
	if _KH_CB_CHAR != 0
		HookDispatcher.Unregister(HookDispatcherConst.EVT_KB_CHAR, _KH_CB_CHAR)
	if _KH_CB_KEY_DOWN != 0
		HookDispatcher.Unregister(HookDispatcherConst.EVT_KB_DOWN, _KH_CB_KEY_DOWN)
	if _KH_CB_KEY_UP != 0
		HookDispatcher.Unregister(HookDispatcherConst.EVT_KB_UP, _KH_CB_KEY_UP)
	; Reset cached callbacks so a subsequent KHStart() creates fresh BoundFunc
	; objects and can re-register with HookDispatcher (identity-based guard).
	_KH_CB_CHAR := 0
	_KH_CB_KEY_DOWN := 0
	_KH_CB_KEY_UP := 0
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
	Evt := Map("char", Char, "timestamp", _KH_EpochMs(), "appId", _KH_CONTEXT["appId"])
	; AHK-20: let exceptions propagate to HookDispatcher.Dispatch (the centralized
	; error sink) — a bare try here would swallow them and bypass stuck-modifier recovery
	_KH_ON_CHAR(Evt)
}

_KH_EpochMs() {
	FileTime := Buffer(8, 0)
	DllCall("Kernel32\GetSystemTimeAsFileTime", "Ptr", FileTime.Ptr)
	return (NumGet(FileTime, 0, "Int64") - 116444736000000000) // 10000
}

_KH_NormalizeKey(VK) {
	switch VK {
		case 0x08: return "Backspace"
		case 0x2E: return "Delete"
		case 0x0D: return "Enter"
		case 0x09: return "Tab"
		case 0x1B: return "Escape"
		case 0x25: return "ArrowLeft"
		case 0x27: return "ArrowRight"
		case 0x26: return "ArrowUp"
		case 0x28: return "ArrowDown"
		case 0x24: return "Home"
		case 0x23: return "End"
		case 0x21: return "PageUp"
		case 0x22: return "PageDown"
	}
	if (VK >= 0x70 and VK <= 0x7B)
		return "F" . (VK - 0x6F)
	return ""
}

; Called by HookDispatcher for normalized non-printable key-down/up events.
; IsDown is frozen by the two bound subscriber owners registered in KHStart.
_KH_DispatchKey(IsDown, IH, VK, SC) {
	global _KH_ON_KEY, _KH_CONTEXT
	if _KH_ON_KEY = 0
		return
	KeyName := _KH_NormalizeKey(VK)
	if (KeyName = "")
		return
	Evt := Map("key", KeyName, "timestamp", _KH_EpochMs(),
		"appId", _KH_CONTEXT["appId"], "isDown", IsDown)
	; AHK-20: same as above — let exceptions propagate to HookDispatcher.Dispatch
	_KH_ON_KEY(Evt)
}





; ======================================================
; ======================================================
; ======= 3/ Physical Key Position Capture =============
; ======================================================
; ======================================================

; Position capture observes the shared InputHook. It never suppresses a key,
; lends a logical action or reserves output; it hands the physical editor one
; key-down's scan code and the modifiers physically held with it, as
; keyboard_hook.capture_position does on Linux and macOS.
global _KH_POSITION_PENDING := 0
global _KH_POSITION_BUSY    := false
global _KH_POSITION_TOKENS  := Map()
global _KH_POSITION_CB      := 0
; Virtual keys a capture waits past: they are the held modifiers, not the key.
global _KH_POSITION_MODIFIER_VKS := Map(0x10, 1, 0x11, 1, 0x12, 1, 0x14, 1,
	0xA0, 1, 0xA1, 1, 0xA2, 1, 0xA3, 1, 0xA4, 1, 0xA5, 1, 0x5B, 1, 0x5C, 1)

; Reports the existing observation prerequisites without enrolling anything.
; @returns {Integer} 1 when the shared hook runs and no capture is pending.
KHPositionCaptureAvailable() {
	global _KH_POSITION_PENDING, _KH_POSITION_BUSY
	return !A_IsSuspended && !_KH_POSITION_BUSY && !IsObject(_KH_POSITION_PENDING)
		&& HookDispatcher._started ? 1 : 0
}

; Enrolls one exact page's observation-only position request.
; @param Current {Func} The page and inventory guard, read again before delivery.
; @param Receive {Func} Takes Map("native_code", "SCnnn", "mods", name → 0/1).
; @returns {Object|Integer} The exact cancellation token, or 0 when refused.
KHCapturePosition(Current, Receive) {
	global _KH_POSITION_PENDING, _KH_POSITION_BUSY, _KH_POSITION_TOKENS, _KH_POSITION_CB
	if !HasMethod(Current, "Call") || !HasMethod(Receive, "Call") || KHPositionCaptureAvailable() != 1
		return 0
	Token := {}
	Record := { Current: Current, Receive: Receive, Token: Token }
	_KH_POSITION_BUSY := true
	try Accepted := Current.Call() == true
	catch as Err {
		LoggerError("KeyboardHook", "The position capture guard failed: {1}.", Err.Message)
		Accepted := false
	}
	_KH_POSITION_BUSY := false
	if !Accepted
		return 0
	_KH_POSITION_TOKENS[Token] := Record
	_KH_POSITION_PENDING := Record
	if (_KH_POSITION_CB == 0)
		_KH_POSITION_CB := _KH_ObservePosition.Bind()
	HookDispatcher.Register(HookDispatcherConst.EVT_KB_DOWN, _KH_POSITION_CB)
	return Token
}

; Cancels only the original observation; forwarding and key ownership continue.
; @param Token {Object} The exact enrollment token, never a page field.
; @returns {Integer} 1 when retired.
KHCancelPosition(Token) {
	global _KH_POSITION_TOKENS, _KH_POSITION_PENDING
	if !IsObject(Token) || !_KH_POSITION_TOKENS.Has(Token)
		return 0
	Record := _KH_POSITION_TOKENS[Token]
	if IsObject(_KH_POSITION_PENDING) && _KH_POSITION_PENDING == Record
		_KH_FinishPosition()
	_KH_POSITION_TOKENS.Delete(Token)
	return 1
}

_KH_FinishPosition() {
	global _KH_POSITION_PENDING, _KH_POSITION_CB
	_KH_POSITION_PENDING := 0
	if (_KH_POSITION_CB != 0)
		HookDispatcher.Unregister(HookDispatcherConst.EVT_KB_DOWN, _KH_POSITION_CB)
}

; The modifiers physically held, by their canonical physical-slot names. AltGr
; is refused rather than read as Alt: its fake LCtrl and the layout's third
; level belong to another owner.
; @param &Mods {Map} Receives name → 0/1.
; @returns {Integer} 1, or 0 while AltGr is held.
_KH_PositionModifiers(&Mods) {
	if GetKeyState("RAlt", "P")
		return 0
	Mods := Map(
		"ctrl", (GetKeyState("LCtrl", "P") || GetKeyState("RCtrl", "P")) ? 1 : 0,
		"alt", GetKeyState("LAlt", "P") ? 1 : 0,
		"shift", (GetKeyState("LShift", "P") || GetKeyState("RShift", "P")) ? 1 : 0,
		"super", (GetKeyState("LWin", "P") || GetKeyState("RWin", "P")) ? 1 : 0)
	return 1
}

; EVT_KB_DOWN subscriber while a capture is pending. The shared hook ignores
; Ergopti's own sends (I1); the key must also be physically down, so an
; injected key cannot mint a position.
_KH_ObservePosition(IH, VK, SC) {
	global _KH_POSITION_PENDING, _KH_POSITION_BUSY, _KH_POSITION_MODIFIER_VKS
	Record := _KH_POSITION_PENDING
	if !IsObject(Record) || _KH_POSITION_BUSY || _KH_POSITION_MODIFIER_VKS.Has(VK) || SC <= 0
		return
	; One primary key per request, accepted or refused.
	_KH_FinishPosition()
	Name := Format("SC{:03X}", SC)
	if !GetKeyState(Name, "P") || !_KH_PositionModifiers(&Mods)
		return
	_KH_POSITION_BUSY := true
	try {
		if Record.Current.Call() == true
			Record.Receive.Call(Map("native_code", Name, "mods", Mods))
	} catch as Err
		LoggerError("KeyboardHook", "The position capture could not be delivered: {1}.", Err.Message)
	finally _KH_POSITION_BUSY := false
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
