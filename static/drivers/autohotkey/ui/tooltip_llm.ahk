; ui/tooltip_llm.ahk

; ==============================================================================
; MODULE: LLM Tooltip UI
; DESCRIPTION:
; Floating tooltip that displays LLM text predictions near the current caret
; position. Disappears on any keystroke and accepts the suggestion on Tab.
;
; FEATURES & RATIONALE:
; 1. Caret-relative: uses CaretGetPos() so the tooltip tracks the insertion point.
; 2. Tab-to-accept: pressing Tab while the tooltip is visible inserts the text.
; 3. Auto-dismiss: tooltip hides after a configurable timeout so it never blocks.
; 4. Pure AHK: no external GUI framework — uses the built-in ToolTip() function.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================
; ===================================
; ======= 1/ Tooltip Constants =======
; ===================================
; ===================================

LLM_TOOLTIP_SLOT      := 10      ; ToolTip slot reserved for LLM predictions (1-20)
LLM_TOOLTIP_OFFSET_Y  := 24      ; Vertical offset below caret in pixels
LLM_TOOLTIP_TIMEOUT   := 5000    ; Auto-dismiss after 5 s of no interaction

; Stable timer reference — must not be a closure so SetTimer can cancel by
; identity. Each fresh () => lambda is a new object; re-scheduling it never
; cancels the prior timer, letting N calls accumulate N independent hiders.
_LLM_Tooltip_TimerFn() => LLM_Tooltip_Hide()




; ====================================
; ====================================
; ======= 2/ Tooltip State =======
; ====================================
; ====================================

global _LLM_Tooltip_Visible := false
global _LLM_Tooltip_Text    := ""




; =========================================
; =========================================
; ======= 3/ Public Interface =======
; =========================================
; =========================================

/**
 * Displays the prediction tooltip near the current caret position.
 * @param {string} text - Prediction text to show.
 */
LLM_Tooltip_Show(text) {
	global _LLM_Tooltip_Visible, _LLM_Tooltip_Text

	if (text == "")
		return

	_LLM_Tooltip_Text    := text
	_LLM_Tooltip_Visible := true

	; Prefer caret position; fall back to mouse position
	x := 0
	y := 0
	if !CaretGetPos(&x, &y) {
		x := A_CaretX
		y := A_CaretY
	}
	y += LLM_TOOLTIP_OFFSET_Y

	label := "↵ " text " [Tab]"
	ToolTip(label, x, y, LLM_TOOLTIP_SLOT)

	; Cancel any pending hide before rescheduling — _LLM_Tooltip_TimerFn is a
	; stable named function so SetTimer can reliably cancel the old call.
	SetTimer(_LLM_Tooltip_TimerFn, 0)
	SetTimer(_LLM_Tooltip_TimerFn, -LLM_TOOLTIP_TIMEOUT)
}

/**
 * Hides the prediction tooltip immediately.
 */
LLM_Tooltip_Hide() {
	global _LLM_Tooltip_Visible, _LLM_Tooltip_Text
	SetTimer(_LLM_Tooltip_TimerFn, 0)
	_LLM_Tooltip_Visible := false
	_LLM_Tooltip_Text    := ""
	ToolTip(, , , LLM_TOOLTIP_SLOT)
}

/**
 * Returns the text currently shown in the tooltip, or "" if hidden.
 * @returns {string} The visible prediction text.
 */
LLM_Tooltip_GetText() {
	global _LLM_Tooltip_Visible, _LLM_Tooltip_Text
	return _LLM_Tooltip_Visible ? _LLM_Tooltip_Text : ""
}
