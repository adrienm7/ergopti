; ui/tooltip_llm.ahk

; ==============================================================================
; MODULE: LLM Tooltip UI
; DESCRIPTION:
; Floating, Gui-based tooltip that displays one or more LLM text predictions
; near the current caret position. Delegates all rendering to lib/tooltip.ahk
; (the shared Gui engine) so the LLM tooltip is visually identical to the
; hotstring tooltip: rounded corners, per-group tint, 1 px border overlay.
;
; FEATURES & RATIONALE:
; 1. Shared renderer: uses TooltipShow() / LLM_TooltipShow() from
;    lib/tooltip.ahk instead of the OS-native ToolTip() function. This gives
;    diff-chunk coloring (green corrections, orange next-words, gray inactive
;    slots) and visual parity with the Hammerspoon renderer.
; 2. Backwards-compatible public surface: all external callers (prediction_engine,
;    llm_bridge, tab_accept) use the same LLM_Tooltip_* names as before — only
;    the implementation changes, not the API.
; 3. Tab-to-accept + slot navigation: unchanged from the previous implementation;
;    wired by tray_llm/tab_accept.ahk which calls LLM_Tooltip_GetText() /
;    LLM_Tooltip_SetActiveIdx().
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ====================================
; ======= 1/ Tooltip Constants =======
; ====================================
; ===================================

; Visual prefixes for the active / inactive slot rows.
LLM_TOOLTIP_ACTIVE_PREFIX   := "▶ "
LLM_TOOLTIP_INACTIVE_PREFIX := "·  "
; Suffix appended to the active row to hint that Tab accepts it.
LLM_TOOLTIP_TAB_SUFFIX      := "   [Tab]"
; Placeholder shown while a slot is still being generated.
LLM_TOOLTIP_PLACEHOLDER     := "⏳ …"





; ==============================================
; =============================================
; ======= 2/ Public API (compatibility) =======
; =============================================
; ==============================================

/**
 * Displays the prediction tooltip via the shared Gui engine.
 * Accepts either a plain string (backwards compat) or an Array of slot
 * values. Each slot may be a plain string or an object with diff chunks:
 *   { Text: "...", Chunks: [{type:"equal"|"insert", text:"..."}], NextWords: "..." }
 *
 * @param {string|Array} payload   The prediction text(s) to show.
 * @param {Integer}      active    1-based active slot index (default 1).
 * @param {boolean}      is_final  True on the final render of a request.
 */
LLM_Tooltip_Show(payload, active := 1, is_final := false) {
	LLM_TooltipShow(payload, active, is_final)
}

/**
 * Hides the prediction tooltip immediately.
 *
 * @param {boolean} accepted  True when called from the accept path (prevents
 *     duplicate llm_dismissed event emission).
 */
LLM_Tooltip_Hide(accepted := false) {
	global _LLM_Tooltip_Visible, _LLM_Tooltip_Slots
	was_visible := LLM_TooltipIsVisible()
	slots_snapshot := LLM_TooltipGetSlots()
	LLM_TooltipHide(accepted)
	; Emit dismissed event when the tooltip was visible AND this hide is not
	; part of the accept path — mirrors the previous ToolTip()-based behaviour.
	if (was_visible and !accepted) {
		try {
			app_name := ""
			try app_name := WinGetProcessName("A")
			KL_LogLlmDismissed(app_name, slots_snapshot)
		}
	}
}

/**
 * Returns the text of the active suggestion (the one Tab inserts), or ""
 * when no usable prediction is available or only placeholders are shown.
 */
LLM_Tooltip_GetText() {
	return LLM_TooltipGetText()
}

/**
 * Updates the active slot index and redraws without rebuilding the Gui.
 * @param {Integer} idx - 1-based slot index.
 */
LLM_Tooltip_SetActiveIdx(idx) {
	LLM_TooltipSetActiveIdx(idx)
}

/**
 * Returns the full slot array currently shown.
 * @returns {Array}
 */
LLM_Tooltip_GetSlots() {
	return LLM_TooltipGetSlots()
}

LLM_Tooltip_GetActiveIdx() {
	return LLM_TooltipGetActiveIdx()
}

LLM_Tooltip_IsVisible() {
	return LLM_TooltipIsVisible()
}
