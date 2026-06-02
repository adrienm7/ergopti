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
; 4. HookDispatcher integration: Start/Stop register/unregister the char and
;    key-down callbacks with the central dispatcher so the bridge shares the
;    single process-wide InputHook instead of creating its own.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ===============================
; ======= 1/ Buffer State =======
; ===============================
; ==============================

global _LLM_Bridge_Buffer := ""
global _LLM_Bridge_Active := false

; Bound callback references kept at module scope so Unregister() receives
; the exact same function object that was passed to Register(). A bare
; ``Func.Bind()`` creates a new object every call — without storing the
; reference the dispatcher can never find the matching entry to remove.
global _LLM_Bridge_OnCharCb    := _LLM_Bridge_DispatchChar.Bind()
global _LLM_Bridge_OnKeyDownCb := _LLM_Bridge_DispatchKeyDown.Bind()





; ==========================================
; =================================
; ======= 2/ Initialisation =======
; =================================
; ==========================================

/**
 * Starts the LLM bridge with the given configuration.
 * Registers char/key-down subscribers with HookDispatcher so the bridge
 * receives every keystroke from the single shared InputHook.
 * @param {Map} opts - Configuration passed through to LLM_Engine_Init().
 */
LLM_Bridge_Start(opts) {
	global _LLM_Bridge_Active, _LLM_Bridge_OnCharCb, _LLM_Bridge_OnKeyDownCb
	if _LLM_Bridge_Active
		return
	_LLM_Bridge_Active := true
	HookDispatcher.Register(HookDispatcherConst.EVT_KB_CHAR, _LLM_Bridge_OnCharCb)
	HookDispatcher.Register(HookDispatcherConst.EVT_KB_DOWN, _LLM_Bridge_OnKeyDownCb)
	LLM_Engine_Init(opts)
}

/**
 * Stops the bridge and hides any visible tooltip.
 * Unregisters from HookDispatcher so no callbacks fire while disabled.
 */
LLM_Bridge_Stop() {
	global _LLM_Bridge_Active, _LLM_Bridge_Buffer, _LLM_Bridge_OnCharCb, _LLM_Bridge_OnKeyDownCb
	if !_LLM_Bridge_Active
		return
	_LLM_Bridge_Active := false
	_LLM_Bridge_Buffer := ""
	try HookDispatcher.Unregister(HookDispatcherConst.EVT_KB_CHAR, _LLM_Bridge_OnCharCb)
	try HookDispatcher.Unregister(HookDispatcherConst.EVT_KB_DOWN, _LLM_Bridge_OnKeyDownCb)
	LLM_Engine_SetEnabled(false)
	LLM_Tooltip_Hide()
}





; ============================================================
; ======================================================
; ======= 3/ HookDispatcher subscriber callbacks =======
; ======================================================
; ============================================================

; Receives (ih, char) from HookDispatcher — routes to the bridge char handler.
_LLM_Bridge_DispatchChar(ih, char) {
	LLM_Bridge_OnChar(char)
}

; Receives (ih, vk, sc) from HookDispatcher — routes special keys to the bridge.
; VK codes: 0x08 = Backspace, 0x09 = Tab, 0x0D = Enter, 0x1B = Escape.
_LLM_Bridge_DispatchKeyDown(ih, vk, sc) {
	if (vk = 0x08)
		LLM_Bridge_OnBackspace()
	else if (vk = 0x09 or vk = 0x0D or vk = 0x1B)
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
	; A flush IS a deliberate user action (Esc / Enter / Tab) — keep the
	; default behaviour where Hide emits llm_dismissed so the acceptance
	; metric counts these as "user moved on without taking the suggestion".
	LLM_Tooltip_Hide()
	LLM_Engine_CancelTimer()
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
