; modules/llm/llm_bridge.ahk

; ==============================================================================
; MODULE: LLM Bridge
; DESCRIPTION:
; Keyboard hook that feeds the typed buffer to the prediction engine.
; Intercepts printable keystrokes and backspace to maintain a rolling context
; string, then forwards it to LLM_Engine_OnKeystroke().
;
; FEATURES & RATIONALE:
; 1. Non-blocking: hook only updates the buffer and restarts a timer — the LLM
;    call happens on a separate timer fire, not inside the hook itself.
; 2. Context reset: Escape, Enter, and Tab flush the buffer so predictions
;    remain relevant to the current editing context.
; 3. AcceptChar filter: only printable ASCII + accented Latin chars are buffered;
;    navigation keys (arrows, F-keys) are ignored to keep context clean.
; 4. PrefixWatcher integration: keystrokes are fed from the prefix watcher's
;    pass-through InputHook (``hotstring_prefix_watcher.ahk``). On Windows,
;    HookDispatcher + Keylogger + PrefixWatcher each create an InputHook;
;    the LLM bridge no longer registers with HookDispatcher because keystrokes
;    were not reaching it on some machines while the prefix hook was reliable.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ===============================
; ======= 1/ Buffer State =======
; ===============================
; ==============================

global _LLM_Bridge_Buffer := ""
global _LLM_Bridge_Active := false
; Fallback path when Ollama becomes ready before PrefixWatcher's InputHook exists.
global _LLM_Bridge_DispatcherCharFn := 0
global _LLM_Bridge_DispatcherKeyFn := 0
; Throttle keystroke logs — one INFO line per ~2 s of typing is enough to
; confirm the pipeline is alive without flooding ErgoptiPlus_*.log.
global _LLM_Bridge_LastLogTick := 0
; Pointer-dismiss watcher — mirrors macOS tooltip_llm.lua mouseMoved/click/scroll.
global _LLM_PointerWatch_Armed     := false
global _LLM_PointerWatch_LastX     := unset
global _LLM_PointerWatch_LastY     := unset
global _LLM_PointerWatch_MoveFn    := unset
global _LLM_PointerWatch_ActivityFn := unset
global _LLM_POINTER_POLL_MS        := 50





; ==========================================
; =================================
; ======= 2/ Initialisation =======
; =================================
; ==========================================

/**
 * Starts the LLM bridge with the given configuration.
 * Keystrokes are delivered by PrefixWatcher (see ``LLM_Bridge_Feed*``).
 * @param {Map} opts - Configuration passed through to LLM_Engine_Init().
 */
LLM_Bridge_Start(opts) {
	global _LLM_Bridge_Active
	LLM_Engine_Init(opts)
	if _LLM_Bridge_Active
		return
	if (IsSet(_PrefixInputHook) && _PrefixInputHook) {
		_LLM_Bridge_Activate("PrefixWatcher")
		_LLM_PointerWatch_Start()
		return
	}
	_LLM_Bridge_RegisterDispatcherFallback()
	_LLM_Bridge_Active := true
	_LLM_PointerWatch_Start()
	try LoggerInfo("LLM", "Bridge engine ready — keystrokes via HookDispatcher until PrefixWatcher starts.")
}

/**
 * Turns on keystroke capture once a reliable hook exists.
 * @param {string} source - ``PrefixWatcher`` or ``HookDispatcher`` (for logs).
 */
_LLM_Bridge_Activate(source) {
	global _LLM_Bridge_Active
	_LLM_Bridge_UnregisterDispatcherFallback()
	if _LLM_Bridge_Active
		return
	_LLM_Bridge_Active := true
	_LLM_PointerWatch_Start()
	try LoggerInfo("LLM", "Bridge active — keystrokes via {1}.", source)
}

_LLM_Bridge_RegisterDispatcherFallback() {
	global _LLM_Bridge_DispatcherCharFn, _LLM_Bridge_DispatcherKeyFn
	if !IsSet(HookDispatcher) or !IsSet(HookDispatcherConst)
		return
	if !(_LLM_Bridge_DispatcherCharFn is Func) {
		_LLM_Bridge_DispatcherCharFn := _LLM_Bridge_OnDispatcherChar.Bind()
		_LLM_Bridge_DispatcherKeyFn := _LLM_Bridge_OnDispatcherKey.Bind()
	}
	try HookDispatcher.Register(HookDispatcherConst.EVT_KB_CHAR, _LLM_Bridge_DispatcherCharFn)
	try HookDispatcher.Register(HookDispatcherConst.EVT_KB_DOWN, _LLM_Bridge_DispatcherKeyFn)
}

_LLM_Bridge_UnregisterDispatcherFallback() {
	global _LLM_Bridge_DispatcherCharFn, _LLM_Bridge_DispatcherKeyFn
	if (_LLM_Bridge_DispatcherCharFn is Func) {
		try HookDispatcher.Unregister(HookDispatcherConst.EVT_KB_CHAR, _LLM_Bridge_DispatcherCharFn)
		try HookDispatcher.Unregister(HookDispatcherConst.EVT_KB_DOWN, _LLM_Bridge_DispatcherKeyFn)
	}
}

_LLM_Bridge_OnDispatcherChar(ih, ch) {
	if (IsSet(_PrefixInputHook) && _PrefixInputHook)
		return
	LLM_Bridge_OnChar(ch)
}

_LLM_Bridge_OnDispatcherKey(ih, vk, sc) {
	if (IsSet(_PrefixInputHook) && _PrefixInputHook)
		return
	LLM_Bridge_FeedKeyDownIfActive(vk)
}

/**
 * Stops the bridge and hides any visible tooltip.
 */
LLM_Bridge_Stop() {
	global _LLM_Bridge_Active, _LLM_Bridge_Buffer
	_LLM_Bridge_UnregisterDispatcherFallback()
	_LLM_PointerWatch_Stop()
	if !_LLM_Bridge_Active
		return
	_LLM_Bridge_Active := false
	_LLM_Bridge_Buffer := ""
	LLM_Engine_SetEnabled(false)
	try LLM_OllamaCancelWarmupRetry()
	LLM_Tooltip_Hide()
	try LoggerInfo("LLM", "Bridge stopped.")
}

/**
 * Called when PrefixWatcher's InputHook comes online after an early Ollama bootstrap.
 */
LLM_Bridge_OnPrefixWatcherReady() {
	global _LLM_Bridge_Active
	if !_LLM_Bridge_Active
		_LLM_Bridge_Activate("PrefixWatcher")
	else
		_LLM_Bridge_UnregisterDispatcherFallback()
}

/**
 * Called from PrefixWatcher on each printable character (when not suppressed).
 * @param {string} ch - Character from the prefix InputHook.
 */
LLM_Bridge_FeedCharIfActive(ch) {
	if (IsSet(_LLM_Bridge_Active) && _LLM_Bridge_Active)
		LLM_Bridge_OnChar(ch)
}

/**
 * Called from PrefixWatcher OnKeyDown for navigation / editing keys.
 * @param {Integer} vk - Virtual key code.
 */
LLM_Bridge_FeedKeyDownIfActive(vk) {
	if !(IsSet(_LLM_Bridge_Active) && _LLM_Bridge_Active)
		return
	if (vk = 0x08)
		LLM_Bridge_OnBackspace()
	else if (vk = 0x09) {
		if (IsSet(LLM_Tooltip_TryAcceptTab) and LLM_Tooltip_TryAcceptTab())
			return
		LLM_Bridge_OnFlush()
	} else if (vk = 0x0D or vk = 0x1B)
		LLM_Bridge_OnFlush()
}





; =========================================
; =========================================
; ======= 4/ Keyboard Hook Handlers =======
; =========================================
; =========================================

/**
 * Must be called from a hotkey or keyboard hook on every typed character.
 * Maintains the rolling context buffer and feeds it to the prediction engine.
 * @param {string} ch - The character that was just typed.
 */
LLM_Bridge_OnChar(ch) {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active
	if !_LLM_Bridge_Active
		return

	_LLM_Bridge_Buffer .= ch
	; Hotstring tooltip priority: if the PrefixWatcher's tooltip is visible,
	; update the buffer but do NOT arm the LLM timer — the prediction must
	; wait until the overlay is gone, exactly like the HS chain-delay logic
	; (modules/keymap/llm_bridge.lua: engine.start_timer(tooltip_timeout +
	; HOTSTRING_CHAIN_OFFSET_SEC)). The next keystroke after the tooltip
	; closes will re-arm the debounce timer and fire the prediction normally.
	if TooltipIsVisible()
		return
	; Only hide OUR tooltip — never dismiss a hotstring overlay.
	; Silent=true so no llm_dismissed event is emitted for a stale hide.
	if LLM_Tooltip_IsVisible()
		LLM_Tooltip_Hide(true)
	global _LLM_Bridge_LastLogTick
	now := A_TickCount
	if (now - _LLM_Bridge_LastLogTick > 2000) {
		_LLM_Bridge_LastLogTick := now
		try LoggerInfo("LLM", "Keystroke buffered ({1} chars) — debounce pending.", StrLen(_LLM_Bridge_Buffer))
	}
	LLM_Engine_OnKeystroke(_LLM_Bridge_Buffer)
}

/**
 * Must be called when Backspace is pressed.
 * Removes the last character from the buffer.
 */
LLM_Bridge_OnBackspace() {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active
	if !_LLM_Bridge_Active
		return

	if (StrLen(_LLM_Bridge_Buffer) > 0)
		_LLM_Bridge_Buffer := SubStr(_LLM_Bridge_Buffer, 1, -1)

	; Same hotstring-priority guard as OnChar.
	if TooltipIsVisible()
		return
	if LLM_Tooltip_IsVisible()
		LLM_Tooltip_Hide(true)
	LLM_Engine_OnKeystroke(_LLM_Bridge_Buffer)
}

/**
 * Must be called on Enter, Escape, or Tab.
 * Flushes the buffer so the next prediction starts from a fresh context.
 */
LLM_Bridge_OnFlush() {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active
	if !_LLM_Bridge_Active
		return
	_LLM_Bridge_Buffer := ""
	LLM_Bridge_ResetPredictions()
}

/**
 * Returns true when pointer activity should cancel LLM work (tooltip, loading,
 * debounce timer, or in-flight HTTP/stream).
 */
LLM_Bridge_HasActivePredictionWork() {
	if !(IsSet(_LLM_Bridge_Active) && _LLM_Bridge_Active)
		return false
	if (IsSet(LLM_Tooltip_IsVisible) && LLM_Tooltip_IsVisible())
		return true
	if (IsSet(LLM_Tooltip_IsLoading) && LLM_Tooltip_IsLoading())
		return true
	return LLM_Engine_IsBusy()
}

/**
 * Clears predictions, cancels generation, and hides the tooltip.
 * Parity with macOS LLMBridge.reset_predictions() + engine.reset().
 */
LLM_Bridge_ResetPredictions() {
	global _LLM_Bridge_Buffer, _LLM_Engine, _LLM_Bridge_Active
	if !(IsSet(_LLM_Bridge_Active) && _LLM_Bridge_Active)
		return
	if !LLM_Bridge_HasActivePredictionWork()
		return
	if (IsSet(_LLM_Engine) and _LLM_Engine.Has("reset_on_nav") and _LLM_Engine["reset_on_nav"])
		_LLM_Bridge_Buffer := ""
	try LLM_Tooltip_MarkChainComplete()
	LLM_Engine_StopGeneration()
	if ((IsSet(LLM_Tooltip_IsVisible) && LLM_Tooltip_IsVisible())
			or (IsSet(LLM_Tooltip_IsLoading) && LLM_Tooltip_IsLoading()))
		LLM_Tooltip_Hide()
}

/**
 * Entry point for mouse / touchpad / wheel activity while LLM work is active.
 */
LLM_Bridge_OnPointerActivity(*) {
	LLM_Bridge_ResetPredictions()
}

_LLM_PointerWatch_Start() {
	global _LLM_PointerWatch_Armed, _LLM_PointerWatch_MoveFn, _LLM_PointerWatch_ActivityFn
	if _LLM_PointerWatch_Armed
		return
	_LLM_PointerWatch_Armed := true
	_LLM_PointerWatch_LastX := unset
	_LLM_PointerWatch_LastY := unset
	if !IsSet(_LLM_PointerWatch_ActivityFn) or !(_LLM_PointerWatch_ActivityFn is Func)
		_LLM_PointerWatch_ActivityFn := LLM_Bridge_OnPointerActivity.Bind()
	; Pass-through hotkeys — same pattern as hotstring_prefix_watcher.ahk.
	for key in ["~LButton", "~RButton", "~MButton", "~XButton1", "~XButton2",
			"~WheelUp", "~WheelDown", "~WheelLeft", "~WheelRight"] {
		try Hotkey(key, _LLM_PointerWatch_ActivityFn, "On")
	}
	if !IsSet(_LLM_PointerWatch_MoveFn) or !(_LLM_PointerWatch_MoveFn is Func)
		_LLM_PointerWatch_MoveFn := _LLM_PointerWatch_OnMoveTick.Bind()
	global _LLM_POINTER_POLL_MS
	SetTimer(_LLM_PointerWatch_MoveFn, _LLM_POINTER_POLL_MS)
	try LoggerDebug("LLM", "Pointer-dismiss watcher armed.")
}

_LLM_PointerWatch_Stop() {
	global _LLM_PointerWatch_Armed, _LLM_PointerWatch_MoveFn, _LLM_PointerWatch_ActivityFn
	if !_LLM_PointerWatch_Armed
		return
	_LLM_PointerWatch_Armed := false
	if IsSet(_LLM_PointerWatch_MoveFn) and (_LLM_PointerWatch_MoveFn is Func)
		try SetTimer(_LLM_PointerWatch_MoveFn, 0)
	if IsSet(_LLM_PointerWatch_ActivityFn) and (_LLM_PointerWatch_ActivityFn is Func) {
		for key in ["~LButton", "~RButton", "~MButton", "~XButton1", "~XButton2",
				"~WheelUp", "~WheelDown", "~WheelLeft", "~WheelRight"] {
			try Hotkey(key, _LLM_PointerWatch_ActivityFn, "Off")
		}
	}
	try LoggerDebug("LLM", "Pointer-dismiss watcher stopped.")
}

_LLM_PointerWatch_OnMoveTick(*) {
	global _LLM_PointerWatch_LastX, _LLM_PointerWatch_LastY
	if !LLM_Bridge_HasActivePredictionWork()
		return
	MouseGetPos(&x, &y)
	if IsSet(_LLM_PointerWatch_LastX) {
		if (x != _LLM_PointerWatch_LastX or y != _LLM_PointerWatch_LastY)
			LLM_Bridge_OnPointerActivity()
	}
	_LLM_PointerWatch_LastX := x
	_LLM_PointerWatch_LastY := y
}

/**
 * Called when the user accepts the suggestion (e.g. pressing Tab over tooltip).
 * Appends the accepted text to the buffer and types it into the active window.
 * @param {string} text - The accepted prediction text.
 */
LLM_Bridge_OnAccept(text) {
	global _LLM_Bridge_Buffer
	; Delay (ms) before clearing the synthetic flag. The TextSend below is
	; asynchronous, so its keystrokes reach the InputHook a few ms later;
	; clearing inline would unflag them before the keylogger captures them.
	static SYNTH_CLEAR_DELAY_MS := 80
	; Tag the auto-typed prediction as synthetic so the keylogger keeps it out
	; of the manual `chars` count and attributes it to the LLM source (esrc).
	try KL_MarkSynthetic("llm")
	TextSend(text, 0, 0)
	SetTimer((*) => KL_ClearSynthetic(), -SYNTH_CLEAR_DELAY_MS)
	_LLM_Bridge_Buffer .= text
	; Audit event — pairs with the llm_suggested event the engine emitted
	; when the tooltip first rendered. The pair lets a log tail compute
	; "accepted / suggested" ratios per app / per model. We log the
	; PROCESS NAME (not the window title) so per-app grouping is stable:
	; window titles change as documents change (``Doc1 — Word``) but the
	; process name (``WINWORD.EXE``) does not.
	try {
		app_name := ""
		try app_name := WIGetFocused()["appId"]
		slots := LLM_Tooltip_GetSlots()
		idx   := LLM_Tooltip_GetActiveIdx()
		KL_LogLlmAccepted(text, app_name, slots, idx)
	}
	; Pass accepted=true so the tooltip's own hide path doesn't also emit
	; an ``llm_dismissed`` event — we'd double-count this suggestion as
	; both accepted AND dismissed.
	LLM_Tooltip_Hide(true)
}
