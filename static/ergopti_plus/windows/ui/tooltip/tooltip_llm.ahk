; ui/tooltip/tooltip_llm.ahk

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
;    wired by menu_llm/tab_accept.ahk which calls LLM_Tooltip_GetText() /
;    LLM_Tooltip_SetActiveIdx().
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================
; ====================================
; ======= 1/ Tooltip Constants =======
; ====================================
; ====================================

; Re-entrancy guard: prevents double-injection when Tab fires via both the
; #HotIf hotkey path and the InputHook FeedKeyDown path in the same tick.
global _LLM_AcceptInProgress := false

; LLM tooltip chrome — loaded from _shared/modules/tooltip/constants.toml via ui_style.ahk.
; Compile-time sentinels overwritten by Tooltip_LlmUiSyncFromShared() at boot.
LLM_TOOLTIP_ACTIVE_PREFIX   := ""
LLM_TOOLTIP_INACTIVE_PREFIX := ""   ; built dynamically from pred_indent
LLM_TOOLTIP_TAB_SUFFIX      := ""
LLM_TOOLTIP_PLACEHOLDER     := ""

; Mirrors shared [llm_ui] into the legacy LLM_TOOLTIP_* aliases after TOML load.
; UiStyle_LoadSharedConst() already fail-fast-validated every key.
Tooltip_LlmUiSyncFromShared() {
	global LLM_TOOLTIP_ACTIVE_PREFIX, LLM_TOOLTIP_PLACEHOLDER
	global UI_LLM_ACTIVE_PREFIX, UI_LLM_SLOT_PLACEHOLDER
	LLM_TOOLTIP_ACTIVE_PREFIX := UI_LLM_ACTIVE_PREFIX
	LLM_TOOLTIP_PLACEHOLDER := UI_LLM_SLOT_PLACEHOLDER
}





; =============================================
; =============================================
; ======= 2/ Public API (compatibility) =======
; =============================================
; =============================================

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
LLM_Tooltip_SetDisplayOpts(opts) {
	LLM_TooltipSetDisplayOpts(opts)
}

LLM_Tooltip_SetChainStart() {
	LLM_TooltipSetChainStart()
}

LLM_Tooltip_MarkChainTimingOnly(NowTick) {
	LLM_TooltipMarkChainTimingOnly(NowTick)
}

LLM_Tooltip_Show(payload, active := 1, is_final := false) {
	LLM_TooltipShow(payload, active, is_final)
}

/**
 * Shows the purple "generation in progress" tooltip (macOS show_loading parity).
 * Replaced automatically when ``LLM_Tooltip_Show`` paints the first prediction.
 */
LLM_Tooltip_ShowLoading() {
	LLM_TooltipShowLoading()
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

LLM_Tooltip_IsLoading() {
	return LLM_TooltipIsLoading()
}

/**
 * True while a real prediction is still inside its minimum-display window — the
 * brief span after it renders during which incidental input (an in-flight
 * keystroke, stray pointer drift, the shared hotstring surface resetting) must
 * not dismiss it. The bridge dismiss paths consult this for parity with the
 * macOS prediction, which lives on its own surface and is never clobbered by the
 * hotstring lifecycle.
 * @returns {boolean}
 */
LLM_Tooltip_InGracePeriod() {
	return LLM_TooltipInGracePeriod()
}

/**
 * Accepts the active prediction when the tooltip is showing. Used by the
 * physical Tab hotkey, tap-hold keys remapped to Tab (e.g. AltGr tap), and
 * synthetic Tab events from the prefix watcher.
 * @returns {boolean} True when a prediction was accepted.
 */
LLM_Tooltip_TryAcceptTab() {
	global _LLM_AcceptInProgress
	if _LLM_AcceptInProgress
		return false
	if !LLM_Tooltip_IsVisible()
		return false
	text := LLM_Tooltip_GetText()
	if (text == "")
		return false
	_LLM_AcceptInProgress := true
	try {
		LLM_Bridge_OnAccept(text)
	} finally {
		_LLM_AcceptInProgress := false
	}
	return true
}

/**
 * Fires an unmodified Tab keystroke unless an LLM prediction is visible —
 * then accepts it instead of sending Tab to the active app.
 * @param {Array|String} Modifiers - TextPressKey modifier argument (Down/Up unchanged).
 */
LLM_Tooltip_FireTabOrAccept(Modifiers := []) {
	if (Modifiers == "Down" or Modifiers == "Up") {
		TextPressKey("Tab", Modifiers)
		return
	}
	has_mods := false
	if (Modifiers is Array)
		has_mods := (Modifiers.Length > 0)
	else if (Modifiers != "")
		has_mods := true
	if !has_mods and LLM_Tooltip_TryAcceptTab()
		return
	TextPressKey("Tab", Modifiers)
}
