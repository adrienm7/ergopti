; ui/tooltip_llm.ahk

; ==============================================================================
; MODULE: LLM Tooltip UI
; DESCRIPTION:
; Floating tooltip that displays one or more LLM text predictions near the
; current caret position. Disappears on any keystroke and accepts the active
; suggestion on Tab. Mirrors the HS multi-slot tooltip semantics so the user
; sees up to N predictions stacked, with the active one highlighted.
;
; FEATURES & RATIONALE:
; 1. Caret-relative: uses CaretGetPos() so the tooltip tracks the insertion point.
; 2. Tab-to-accept: pressing Tab while the tooltip is visible inserts the
;    currently-active suggestion (slot 1 by default; navigation modifiers
;    move the active slot up/down — wired by the engine).
; 3. Multi-slot rendering: when the engine produces N predictions, every
;    slot is stacked vertically. The active slot gets a ▶ prefix; the others
;    are dimmed by a leading bullet. Empty slots show a placeholder line
;    that fills in once that variant's request returns.
; 4. Auto-dismiss: tooltip hides after a configurable timeout so it never
;    blocks. Engine resets the timer on every new partial / final update.
; 5. Pure AHK: no external GUI framework — uses the built-in ToolTip()
;    function.
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

; Visual prefixes used by the multi-slot renderer. ▶ marks the active row;
; the other rows are prefixed with a faint bullet so the user can see all
; candidates without losing track of which one Tab will accept.
LLM_TOOLTIP_ACTIVE_PREFIX   := "▶ "
LLM_TOOLTIP_INACTIVE_PREFIX := "·  "
; Suffix on the active row only — same Tab hint as before but only attached
; to the slot Tab would actually fire on.
LLM_TOOLTIP_TAB_SUFFIX      := "   [Tab]"
; Placeholder shown while a slot is still being generated. The hourglass
; emoji is an explicit "thinking…" indicator (mirrors HS's "🔄 Génération
; en cours" cue): the previous bare "…" was too subtle and users
; mistook a streaming slot for a finished short prediction. Kept narrow
; so the tooltip width doesn't jump when the slot finally fills in.
LLM_TOOLTIP_PLACEHOLDER     := "⏳ …"

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
; Array of slot texts. Empty string for "not generated yet" — rendered as
; the placeholder so the user sees the full N rows even before all variants
; have finished streaming.
global _LLM_Tooltip_Slots := []
; 1-based index of the currently-active slot — the one Tab inserts. The
; engine bumps this when the user presses the navigation modifier; we
; clamp it to the slot count on every render.
global _LLM_Tooltip_ActiveIdx := 1




; =========================================
; =========================================
; ======= 3/ Public Interface =======
; =========================================
; =========================================

/**
 * Displays the prediction tooltip. Accepts either a single string (for
 * backwards compatibility with the legacy single-prediction caller) or
 * an array of slot texts. Empty array elements render as the placeholder
 * "⏳ …" so the user sees the full row count immediately.
 *
 * @param {string|Array} payload   - The prediction text(s) to show.
 * @param {Integer}      active    - 1-based active slot index (default 1).
 * @param {boolean}      is_final  - True on the final render of a request.
 *                                   When true, trailing AND middle empty
 *                                   slots are dropped so a failed variant
 *                                   doesn't leave a stray "⏳ …" row on
 *                                   screen forever.
 */
LLM_Tooltip_Show(payload, active := 1, is_final := false) {
	global _LLM_Tooltip_Visible, _LLM_Tooltip_Slots, _LLM_Tooltip_ActiveIdx

	; Normalise payload → array of slot strings.
	slots := []
	if (Type(payload) == "Array") {
		for s in payload
			slots.Push(Type(s) == "String" ? s : "")
	} else if (Type(payload) == "String") {
		if (payload == "")
			return
		slots.Push(payload)
	} else {
		return
	}

	; Always drop trailing empty slots so the tooltip doesn't grow taller
	; than it needs to be on the last variants.
	while (slots.Length > 0 and slots[slots.Length] == "")
		slots.Pop()
	; On the final render, also drop middle empty slots — they would
	; otherwise be drawn as the "⏳ …" placeholder for a generation that
	; will never complete (the variant failed and the loop has moved on).
	; Mid-stream we KEEP the empty slots so the user sees the upcoming
	; prediction row appear in advance.
	if is_final {
		filtered := []
		for s in slots {
			if (s != "")
				filtered.Push(s)
		}
		slots := filtered
	}
	if (slots.Length == 0)
		return

	_LLM_Tooltip_Slots := slots
	; Clamp the active index defensively — callers may pass an idx that
	; was valid for a previous slot array but is now out of bounds (a
	; variant failed and the array shrank between renders). Reading
	; outside the array would throw in _Render and kill the tooltip.
	_LLM_Tooltip_ActiveIdx := Max(1, Min(Integer(active), slots.Length))
	_LLM_Tooltip_Visible := true
	_LLM_Tooltip_Render()

	; Cancel any pending hide before rescheduling — _LLM_Tooltip_TimerFn is a
	; stable named function so SetTimer can reliably cancel the old call.
	SetTimer(_LLM_Tooltip_TimerFn, 0)
	SetTimer(_LLM_Tooltip_TimerFn, -LLM_TOOLTIP_TIMEOUT)
}

/**
 * Updates the active slot index without rebuilding the rest of the tooltip.
 * Used by the navigation hotkeys to move the ▶ marker up / down.
 * @param {Integer} idx - 1-based slot index.
 */
LLM_Tooltip_SetActiveIdx(idx) {
	global _LLM_Tooltip_Visible, _LLM_Tooltip_Slots, _LLM_Tooltip_ActiveIdx
	if !_LLM_Tooltip_Visible
		return
	if (_LLM_Tooltip_Slots.Length == 0)
		return
	_LLM_Tooltip_ActiveIdx := Max(1, Min(idx, _LLM_Tooltip_Slots.Length))
	_LLM_Tooltip_Render()
}

/**
 * Hides the prediction tooltip immediately.
 *
 * @param {boolean} accepted - True when called from the accept path so we
 *     do NOT emit a duplicate ``llm_dismissed`` event (the accept path
 *     emits ``llm_accepted`` itself). False everywhere else (timeout,
 *     keystroke, bridge stop) so a tail of the log can compute
 *     accepted/dismissed/suggested ratios.
 */
LLM_Tooltip_Hide(accepted := false) {
	global _LLM_Tooltip_Visible, _LLM_Tooltip_Slots
	SetTimer(_LLM_Tooltip_TimerFn, 0)
	was_visible := _LLM_Tooltip_Visible
	slots_snapshot := _LLM_Tooltip_Slots
	_LLM_Tooltip_Visible := false
	_LLM_Tooltip_Slots := []
	ToolTip(, , , LLM_TOOLTIP_SLOT)
	; Emit a dismissed event when the tooltip was actually showing AND
	; the hide isn't part of the accept path. The engine's
	; ``llm_suggested`` event landed when the tooltip first rendered;
	; without this matching dismissed, "shown but not accepted" cases
	; are invisible in the log.
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
 * when no usable prediction is available. Wired into the Tab hotkey via
 * #HotIf in tray_llm.ahk so Tab only fires when a real prediction is on
 * screen — when only placeholders are showing, GetText returns "" and
 * the Tab keystroke falls through to the active app (which is the right
 * behaviour: "tab" mid-streaming should not insert a "⏳ …" string).
 */
LLM_Tooltip_GetText() {
	global _LLM_Tooltip_Visible, _LLM_Tooltip_Slots, _LLM_Tooltip_ActiveIdx
	if !IsSet(_LLM_Tooltip_Visible) or !_LLM_Tooltip_Visible
		return ""
	if !IsSet(_LLM_Tooltip_Slots) or _LLM_Tooltip_Slots.Length == 0
		return ""
	idx := IsSet(_LLM_Tooltip_ActiveIdx) ? _LLM_Tooltip_ActiveIdx : 1
	if (idx < 1 or idx > _LLM_Tooltip_Slots.Length)
		return ""
	active := _LLM_Tooltip_Slots[idx]
	; Empty (= still-generating) active slot → fall through. If another
	; slot in the array has finished, prefer that one so Tab inserts
	; *something* useful rather than nothing. Walks left-to-right
	; because that's the order variants completed in.
	if (active == "") {
		for s in _LLM_Tooltip_Slots {
			if (s != "")
				return s
		}
		return ""
	}
	return active
}

/**
 * Returns the full slot array — used by the engine when it needs to know
 * how many predictions are currently shown (e.g. when computing the next
 * active slot for the navigation hotkey).
 * @returns {Array} The currently displayed slot strings.
 */
LLM_Tooltip_GetSlots() {
	global _LLM_Tooltip_Slots
	if !IsSet(_LLM_Tooltip_Slots)
		return []
	return _LLM_Tooltip_Slots
}

LLM_Tooltip_GetActiveIdx() {
	global _LLM_Tooltip_ActiveIdx
	if !IsSet(_LLM_Tooltip_ActiveIdx)
		return 1
	return _LLM_Tooltip_ActiveIdx
}

LLM_Tooltip_IsVisible() {
	global _LLM_Tooltip_Visible
	return IsSet(_LLM_Tooltip_Visible) and _LLM_Tooltip_Visible
}




; =========================================
; =========================================
; ======= 4/ Rendering =====================
; =========================================
; =========================================

_LLM_Tooltip_Render() {
	global _LLM_Tooltip_Slots, _LLM_Tooltip_ActiveIdx

	; Build a multi-line label. Each row is prefixed with ▶ for the active
	; slot, "·" for inactive ones. Empty (in-flight) slots show the
	; placeholder so the height stays stable as variants fill in.
	rows := []
	for i, txt in _LLM_Tooltip_Slots {
		display := (txt != "") ? txt : LLM_TOOLTIP_PLACEHOLDER
		prefix := (i == _LLM_Tooltip_ActiveIdx) ? LLM_TOOLTIP_ACTIVE_PREFIX : LLM_TOOLTIP_INACTIVE_PREFIX
		suffix := (i == _LLM_Tooltip_ActiveIdx) ? LLM_TOOLTIP_TAB_SUFFIX : ""
		rows.Push(prefix . display . suffix)
	}
	label := ""
	for r in rows {
		if (label != "")
			label .= "`n"
		label .= r
	}

	x := 0, y := 0
	if !CaretGetPos(&x, &y) {
		x := A_CaretX
		y := A_CaretY
	}
	y += LLM_TOOLTIP_OFFSET_Y
	ToolTip(label, x, y, LLM_TOOLTIP_SLOT)
}
