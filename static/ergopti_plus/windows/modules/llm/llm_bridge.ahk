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
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================
; ===============================
; ======= 1/ Buffer State =======
; ===============================
; ==============================

global _LLM_Bridge_Buffer := ""
global _LLM_Bridge_Active := false





; ==========================================
; =================================
; ======= 2/ Initialisation =======
; =================================
; ==========================================

/**
 * Starts the LLM bridge with the given configuration.
 * @param {Map} opts - Configuration passed through to LLM_Engine_Init().
 */
LLM_Bridge_Start(opts) {
	global _LLM_Bridge_Active
	_LLM_Bridge_Active := true
	LLM_Engine_Init(opts)
}

/**
 * Stops the bridge and hides any visible tooltip.
 */
LLM_Bridge_Stop() {
	global _LLM_Bridge_Active, _LLM_Bridge_Buffer
	_LLM_Bridge_Active := false
	_LLM_Bridge_Buffer := ""
	LLM_Engine_SetEnabled(false)
	LLM_Tooltip_Hide()
}





; =========================================
; =========================================
; ======= 3/ Keyboard Hook Handlers =======
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
	; Pass ``silent := true`` so the bridge's natural "tooltip is stale,
	; new keystroke incoming" hide does NOT emit an llm_dismissed event.
	; Otherwise every keystroke while a tooltip is on screen produces a
	; bogus dismissed event before the next suggestion arrives, flooding
	; the keylogger with spurious dismiss / suggest pairs that ruin the
	; acceptance-rate metric.
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

	; Same reasoning as LLM_Bridge_OnChar — typing past a suggestion is a
	; "stale" hide, not a "user said no" hide.
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
	SendText(text)
	_LLM_Bridge_Buffer .= text
	; Audit event — pairs with the llm_suggested event the engine emitted
	; when the tooltip first rendered. The pair lets a log tail compute
	; "accepted / suggested" ratios per app / per model. We log the
	; PROCESS NAME (not the window title) so per-app grouping is stable:
	; window titles change as documents change (``Doc1 — Word``) but the
	; process name (``WINWORD.EXE``) does not.
	try {
		app_name := ""
		try app_name := WinGetProcessName("A")
		slots := LLM_Tooltip_GetSlots()
		idx   := LLM_Tooltip_GetActiveIdx()
		KL_LogLlmAccepted(text, app_name, slots, idx)
	}
	; Pass accepted=true so the tooltip's own hide path doesn't also emit
	; an ``llm_dismissed`` event — we'd double-count this suggestion as
	; both accepted AND dismissed.
	LLM_Tooltip_Hide(true)
}
