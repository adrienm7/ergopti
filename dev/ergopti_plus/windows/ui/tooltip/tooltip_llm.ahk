; ui/tooltip/tooltip_llm.ahk

; ==============================================================================
; MODULE: LLM Tooltip UI
; DESCRIPTION:
; Floating, Gui-based tooltip that displays one or more LLM text predictions
; near the current caret position. Delegates all rendering to infra/tooltip.ahk
; (the shared Gui engine) so the LLM tooltip is visually identical to the
; hotstring tooltip: rounded corners, per-group tint, 1 px border overlay.
;
; FEATURES & RATIONALE:
; 1. Shared renderer: uses TooltipShow() / LLM_TooltipShow() from
;    infra/tooltip.ahk instead of the OS-native ToolTip() function. This gives
;    diff-chunk coloring (green corrections, orange next-words, gray inactive
;    slots) and visual parity with the Hammerspoon renderer.
; 2. Stable rendering surface: external rendering and navigation callers keep
;    the LLM_Tooltip_* API while the implementation delegates to the shared Gui.
; 3. Acceptance ownership: the menu wires the Tab hotkey, while the canonical
;    source-control/modifier policy and injection gateway live in llm_bridge.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================
; ====================================
; ======= 1/ Tooltip Constants =======
; ====================================
; ====================================

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

; Returns the positive generation owned by this exact committed render, else 0.
LLM_Tooltip_Show(payload, active := 1, is_final := false,
		PresentationMeta := 0) {
	return LLM_TooltipShow(payload, active, is_final, PresentationMeta)
}

LLM_Tooltip_IsRenderGenerationCurrent(RenderGeneration) {
	return LLM_TooltipRenderGenerationIsCurrent(RenderGeneration)
}

/**
 * Shows the purple "generation in progress" tooltip (macOS show_loading parity).
 * Replaced automatically when ``LLM_Tooltip_Show`` paints the first prediction.
 */
LLM_Tooltip_ShowLoading(PresentationMeta := 0) {
	LLM_TooltipShowLoading(PresentationMeta)
}

/**
 * Hides the prediction tooltip immediately.
 *
 * @param {boolean} accepted  True when called from the accept path (prevents
 *     duplicate llm_dismissed event emission).
 */
LLM_Tooltip_Hide(accepted := false) {
	return LLM_TooltipHide(accepted)
}

LLM_Tooltip_HideExact(ExpectedRecord, accepted := false) {
	return LLM_TooltipHide(accepted, unset, unset, ExpectedRecord)
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

LLM_Tooltip_GetPresentedToken() {
	return LLM_TooltipGetPresentedToken()
}

LLM_Tooltip_GetAcceptSnapshot() {
	return LLM_TooltipGetAcceptSnapshot()
}

LLM_Tooltip_ClaimAcceptance(ExpectedRecord) {
	return LLM_TooltipClaimAcceptance(ExpectedRecord)
}

LLM_Tooltip_FinalizeAcceptance(Lifecycle, Accepted) {
	return LLM_TooltipFinalizeAcceptance(Lifecycle, Accepted)
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
