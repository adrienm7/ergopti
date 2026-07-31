; ui/tooltip/llm.ahk
; Requires: GraphicsRenderer

; ==============================================================================
; MODULE: Hotstring Tooltip / LLM Multi-slot Tooltip
; DESCRIPTION:
; The LLM prediction tooltip backed by the shared Gui engine: multi-slot state, show/hide/loading, slot text building, display-option setters, the chain-timing model, footer/info/nav-hint rendering and the LLM Gui builder.
;
; Split out of the former lib/tooltip.ahk (the module split); see ui/tooltip/init.ahk
; for the module overview. Functions and globals are hoisted, so load order
; across the tooltip/*.ahk files is irrelevant.
; ==============================================================================





; =========================================
; =========================================
; ======= 3/ LLM Multi-slot Tooltip =======
; =========================================
; =========================================

; Global state for the LLM multi-slot tooltip — backed by the shared Gui
; engine instead of the monochrome built-in ToolTip() function.
global _LLM_Tooltip_Slots    := []
global _LLM_Tooltip_ActiveIdx := 1
global _LLM_Tooltip_Visible  := false
global _LLM_Tooltip_Loading  := false
; Minimum on-screen time (ms) for a freshly-rendered prediction. Within this
; window the prediction is immune to INCIDENTAL dismissals: the shared hotstring
; surface resetting its buffer (ResetBuf / LookupNoMatch / a new lookup NewShow),
; an in-flight keystroke that was already travelling when the slow model finally
; answered, or stray pointer drift. Without it a prediction that lands mid-typing
; is clobbered within tens of milliseconds and never gets seen — the
; "n'a même pas le temps d'apparaître" bug. Unlike macOS, the AHK prediction
; shares one Gui surface with the hotstring autocomplete tooltip, so it is exposed
; to that surface's far more aggressive per-keystroke lifecycle; this window is the
; equaliser. Deliberate user actions (Tab/Enter accept, Escape) and driver suspend
; bypass it. Tunable; 600 ms is comfortably above human reaction time.
global _LLM_TOOLTIP_MIN_DISPLAY_MS := 600
; A_TickCount when the current real prediction was rendered (0 = none / loading).
global _LLM_Tooltip_ShownAt := 0
; Spinner label used when the i18n layer is not up yet (t is unset during the
; earliest boot window). It carries NO language on purpose: the previous
; fallback was hardcoded French, so a user on any of the other 20 locales who
; triggered a prediction in that window was shown French. An hourglass says the
; same thing in every one of them.
global _LLM_TOOLTIP_LOADING_FALLBACK := "⏳"
; Footer state — mirrors tooltip_llm.lua info/hint rows.
global _LLM_Tooltip_ShowInfoBar := false
global _LLM_Tooltip_InfoModel   := ""
global _LLM_Tooltip_FooterSlots := 1
global _LLM_Tooltip_NavMods     := ""
global _LLM_Tooltip_PredIndent  := 0
global _LLM_Tooltip_ValMods     := "alt"
global _LLM_Tooltip_Chain := {
	StartTick: 0, FirstShowTick: 0, LastUpdateTick: 0, TtftMs: 0, TtltMs: 0,
}

; Show the LLM multi-slot tooltip using the shared Gui engine.
; Each slot may be a plain string (streaming) or a diff object:
;   { Text, Chunks: [{type:"equal"|"insert", text}], NextWords, HasCorrections }
; Active slot: equal chunks in green, NextWords in orange, insert in white.
; Inactive slots: full Text in gray.
LLM_TooltipShow(payload, active := 1, is_final := false) {
	global _LLM_Tooltip_Slots, _LLM_Tooltip_ActiveIdx, _LLM_Tooltip_Visible

	; No prediction tooltip while paused — Ergopti_OnSuspendEnter already hid any
	; visible one, this refuses late async renders.
	if A_IsSuspended
		return

	slots := []
	if (Type(payload) == "Array") {
		for s in payload
			slots.Push(s)
	} else if (Type(payload) == "String") {
		if (payload == "")
			return
		slots.Push(payload)
	} else {
		return
	}

	if is_final {
		while (slots.Length > 0 and _LLM_SlotIsEmpty(slots[slots.Length]))
			slots.Pop()
		filtered := []
		for _, s in slots {
			if !_LLM_SlotIsEmpty(s)
				filtered.Push(s)
		}
		slots := filtered
	}
	if (slots.Length == 0) {
		LLM_TooltipHide()
		return
	}

	; macOS parity: keep the compact violet « Génération en cours… » indicator
	; until at least one slot carries real text. Intermediate placeholder paints
	; (DispatchBatch / variant reveal) used to swap in the full LLM chrome with
	; footer + info-bar width reservation, which stretched a short label across
	; the whole tooltip frame on Windows 11.
	if (!is_final) {
		all_placeholder := true
		for _, s in slots {
			if !_LLM_SlotIsPlaceholder(s) {
				all_placeholder := false
				break
			}
		}
		if all_placeholder {
			LLM_TooltipShowLoading()
			return
		}
	}

    global _LLM_Tooltip_Loading, _LLM_Tooltip_ShownAt
    global _TooltipGeneration, _TooltipTimerGeneration
    ; Reserve ownership before touching the shared Gui. UIA position resolution
    ; can pump messages; a later prediction/hide must make this invocation inert
    ; rather than allowing it to present stale content afterward.
    RenderGeneration := _TooltipGeneration + 1
    _TooltipGeneration := RenderGeneration
    _TooltipTimerGeneration := RenderGeneration
    SetTimer(_TooltipTimerFn, 0)
    _LLM_Tooltip_Loading := false
	_LLM_Tooltip_Slots    := slots
	_LLM_Tooltip_ActiveIdx := Max(1, Min(Integer(active), slots.Length))
	_LLM_Tooltip_Visible  := true
	; Open the minimum-display window: the moment a real prediction renders, start
	; the clock the incidental dismiss paths consult via LLM_TooltipInGracePeriod().
	_LLM_Tooltip_ShownAt := A_TickCount

	; Detect whether any slot carries diff chunks — if so use the rich Gui path.
	has_chunks := false
	for _, s in slots {
		if IsObject(s) and s.HasOwnProp("Chunks") and s.Chunks.Length > 0 {
			has_chunks := true
			break
		}
	}

	LLM_TooltipRefreshChainTiming()
	; _TooltipBuildGuiLlm tears the current prediction down at its start, then builds
	; the new one. If the BUILD ever throws (a formatting bug, a malformed slot), the
	; window is left destroyed with no SHOW/HIDE and no generation change — the
	; prediction silently vanishes (the "clignote et part" display bug, root-caused
	; to a misplaced StrReplace arg in the footer formatter). Guard it: log the exact
	; failure and reset to a clean hidden state rather than leaving a ghost "visible"
	; flag over a destroyed window, so a render error can never blank the surface
	; without a trace again.
	try {
        if !_TooltipBuildGuiLlm(slots, _LLM_Tooltip_ActiveIdx, RenderGeneration)
            return
    } catch as _llm_build_err {
		try LoggerError("LLM.tt", "Prediction render failed — hiding cleanly: {1} | file={2} line={3}.",
			_llm_build_err.Message,
			(_llm_build_err.HasOwnProp("File") ? _llm_build_err.File : "?"),
			(_llm_build_err.HasOwnProp("Line") ? _llm_build_err.Line : "?"))
        if (RenderGeneration == _TooltipGeneration)
            LLM_TooltipHide()
        return
    }

    if (RenderGeneration != _TooltipGeneration)
        return

	; Arm the LLM-specific auto-hide timer. The duration mirrors the macOS
	; llm_prediction delay: it defaults to UI_LLM_TIMEOUT_SEC (20 s) but is
	; user-overridable from the hotstrings "Delays" submenu, stored as the
	; "llm_prediction" delay override. Resolve it live so a change applies
	; without a restart; fall back to the UI constant if the resolver is absent.
    global UI_LLM_TIMEOUT_SEC
    _TooltipTimerGeneration := RenderGeneration
	llm_timeout_sec := UI_LLM_TIMEOUT_SEC
	try {
		_llm_ov := HotstringsResolve("llm_prediction", "")
		if _llm_ov.HasOverride
			llm_timeout_sec := _llm_ov.Delay
	}
	timeout_ms := Round(Max(0.05, llm_timeout_sec - 0.2) * 1000)
	SetTimer(_TooltipTimerFn, -timeout_ms)
	try LoggerDebug("LLM.tt", "SHOW prediction: {1} slot(s), is_final={2}, auto-hide in {3}ms (gen {4}).",
		slots.Length, (is_final ? "true" : "false"), timeout_ms, _TooltipGeneration)
}

; Purple in-flight indicator — macOS ``show_loading`` parity (ai_loading tint).
; Stays visible until replaced by ``LLM_TooltipShow`` or ``LLM_TooltipHide``.
LLM_TooltipShowLoading() {
	global _LLM_Tooltip_Visible, _LLM_Tooltip_Loading, _LLM_Tooltip_ShownAt
	if A_IsSuspended
		return
	_LLM_Tooltip_Loading := true
	_LLM_Tooltip_Visible  := true
	; The violet spinner is not a real prediction — clear any grace stamp so the
	; window cannot keep a previous prediction "protected" behind the loading state.
	_LLM_Tooltip_ShownAt := 0
	label := (IsSet(t)) ? t("llm.generating") : _LLM_TOOLTIP_LOADING_FALLBACK
	accent := _TooltipResolveAccent("ai_loading")
	; DurationSec 0 + ArmSafety false: the spinner must live until the prediction
	; lands or LLM_TooltipHide runs — inference legitimately outlasts the 3 s
	; _TOOLTIP_SAFETY_SEC deadline (Ollama cold start alone is granted 8 s).
	; This MUST be an argument: rendering is deferred by TOOLTIP_RENDER_DEBOUNCE_MS,
	; so cancelling _TooltipTimerFn here would run 75 ms before the timer is armed
	; and silently do nothing, letting the spinner vanish mid-inference.
	TooltipShow([{ Text: label, ColorHex: accent, IsDimmed: false, DurationSec: 0 }], 0, false)
	global _TooltipDequeueActive
	_TooltipDequeueActive := false
	try LoggerDebug("LLM.tt", "SHOW loading (no auto-hide).")
}

LLM_TooltipHide(accepted := false) {
	global _LLM_Tooltip_Visible, _LLM_Tooltip_Slots, _LLM_Tooltip_Loading, _LLM_Tooltip_ShownAt
	; Critical ensures the multi-variable write (Visible, Loading, Slots) is
	; not interleaved with the #HotIf thread reading them in LLM_TooltipGetText.
	local _c := Critical("On")
	if (_LLM_Tooltip_Visible or _LLM_Tooltip_Loading)
		try LoggerDebug("LLM.tt", "HIDE prediction via LLM_TooltipHide (accepted={1}, was visible={2} loading={3}).",
			(accepted ? "true" : "false"),
			(_LLM_Tooltip_Visible ? "true" : "false"), (_LLM_Tooltip_Loading ? "true" : "false"))
	_LLM_Tooltip_Visible := false
	_LLM_Tooltip_Loading := false
	_LLM_Tooltip_ShownAt := 0
	_LLM_Tooltip_Slots   := []
	Critical(_c)
	_LLM_TooltipResetChain()
	TooltipHide("LLM", true)
}

LLM_TooltipGetText() {
	global _LLM_Tooltip_Visible, _LLM_Tooltip_Slots, _LLM_Tooltip_ActiveIdx
	; Reachable from a PARSE-TIME #HotIf (`Tab::` in menu_llm/tab_accept.ahk),
	; which is armed before this module's globals are assigned. Bundle_Init's
	; RunWait extraction pumps messages, so a Tab pressed during the ~250 ms
	; unzip evaluates that #HotIf and lands here with all three still unset:
	; the bare read raised UnsetError inside the evaluator, _DriverBootPhase was
	; still "starting", and the boot was killed. Guarded rather than seeded in
	; the pre-pump block so every future caller is covered too, and placed above
	; the Critical so the unset path takes no lock. The sibling
	; LLM_TooltipIsVisible already guards; this one did not.
	if (!IsSet(_LLM_Tooltip_Visible) or !IsSet(_LLM_Tooltip_Slots) or !IsSet(_LLM_Tooltip_ActiveIdx))
		return ""
	; Critical serialises the multi-variable read against the timer callbacks
	; that write _LLM_Tooltip_Visible / _LLM_Tooltip_Slots. Without it the
	; #HotIf evaluator (a separate low-priority thread) can see Visible=true
	; but Slots already cleared by a concurrent LLM_TooltipHide().
	local _c := Critical("On")
	try {
		if !_LLM_Tooltip_Visible or _LLM_Tooltip_Slots.Length == 0
			return ""
		idx := _LLM_Tooltip_ActiveIdx
		if (idx < 1 or idx > _LLM_Tooltip_Slots.Length)
			return ""
		; Return only the active slot — never fall back to a different slot than
		; the one the user selected (▶ marker). If the active slot is a
		; placeholder the Tab key passes through naturally via the empty-string
		; return, avoiding silent injection of the wrong prediction.
		return _LLM_SlotGetText(_LLM_Tooltip_Slots[idx])
	} finally {
		Critical(_c)
	}
}

LLM_TooltipGetSlots() {
	global _LLM_Tooltip_Slots
	return IsSet(_LLM_Tooltip_Slots) ? _LLM_Tooltip_Slots : []
}

LLM_TooltipGetActiveIdx() {
	global _LLM_Tooltip_ActiveIdx
	return IsSet(_LLM_Tooltip_ActiveIdx) ? _LLM_Tooltip_ActiveIdx : 1
}

LLM_TooltipIsVisible() {
	global _LLM_Tooltip_Visible
	return IsSet(_LLM_Tooltip_Visible) and _LLM_Tooltip_Visible
}

; True whenever a real prediction occupies the shared surface (NOT the loading
; spinner), for the WHOLE time it is displayed. While true, the hotstring
; autocomplete lifecycle (TooltipShow lookups, ResetBuf / LookupNoMatch hides)
; must leave the surface alone — only the user, the prediction's own auto-hide
; timer, or suspend may tear it down. Distinct from the grace window, which is the
; brief minimum-display span the BRIDGE consults to debounce user dismissal.
LLM_TooltipOwnsSurface() {
	global _LLM_Tooltip_Visible, _LLM_Tooltip_Loading
	if (!IsSet(_LLM_Tooltip_Visible) or !_LLM_Tooltip_Visible)
		return false
	if (IsSet(_LLM_Tooltip_Loading) and _LLM_Tooltip_Loading)
		return false
	return true
}

; True while a real prediction is still inside its minimum-display window. The
; bridge's keystroke / pointer dismissal consults this so a prediction is never
; dismissed by the user the instant it appears. False during loading and once the
; window has elapsed, so normal dismiss behaviour resumes afterwards.
LLM_TooltipInGracePeriod() {
	global _LLM_Tooltip_Visible, _LLM_Tooltip_Loading, _LLM_Tooltip_ShownAt, _LLM_TOOLTIP_MIN_DISPLAY_MS
	if (!IsSet(_LLM_Tooltip_Visible) or !_LLM_Tooltip_Visible)
		return false
	if (IsSet(_LLM_Tooltip_Loading) and _LLM_Tooltip_Loading)
		return false
	if (!IsSet(_LLM_Tooltip_ShownAt) or _LLM_Tooltip_ShownAt == 0)
		return false
	return (A_TickCount - (_LLM_Tooltip_ShownAt) & 0xFFFFFFFF) < _LLM_TOOLTIP_MIN_DISPLAY_MS
}

LLM_TooltipIsLoading() {
	global _LLM_Tooltip_Loading
	return IsSet(_LLM_Tooltip_Loading) and _LLM_Tooltip_Loading
}

LLM_TooltipSetActiveIdx(idx) {
	global _LLM_Tooltip_Visible, _LLM_Tooltip_Slots, _LLM_Tooltip_ActiveIdx
	if !_LLM_Tooltip_Visible or _LLM_Tooltip_Slots.Length == 0
		return
	_LLM_Tooltip_ActiveIdx := Max(1, Min(idx, _LLM_Tooltip_Slots.Length))
	LLM_TooltipShow(_LLM_Tooltip_Slots, _LLM_Tooltip_ActiveIdx, false)
}



; =================================
; ===== 3.1) LLM slot helpers =====
; =================================

_LLM_SlotIsPlaceholder(slot) {
	global UI_LLM_SLOT_PLACEHOLDER, LLM_TOOLTIP_PLACEHOLDER
	ph := UI_LLM_SLOT_PLACEHOLDER != "" ? UI_LLM_SLOT_PLACEHOLDER : LLM_TOOLTIP_PLACEHOLDER
	txt := _LLM_SlotGetText(slot)
	if (txt = "")
		return true
	if (ph != "" and txt = ph)
		return true
	; HS streaming reserve char and common ellipsis variants.
	if (txt = "…" or txt = "...")
		return true
	return !!(txt ~= "^\s+$")
}

_LLM_AllSlotsPlaceholder(slots) {
	for s in slots {
		if !_LLM_SlotIsPlaceholder(s)
			return false
	}
	return slots.Length > 0
}

_LLM_SlotIsEmpty(slot) {
	return _LLM_SlotIsPlaceholder(slot)
}

_LLM_SlotGetText(slot) {
	if (Type(slot) == "String")
		return slot
	if IsObject(slot) and slot.HasOwnProp("Text")
		return slot.Text
	return ""
}

_LLM_RepeatChar(ch, count) {
	if (count <= 0)
		return ""
	out := ""
	loop count
		out .= ch
	return out
}

; Prefixes for active/inactive rows — mirrors tooltip_llm.lua assemble_blocks.
_LLM_GetActivePrefix(slotCount) {
	global _LLM_Tooltip_PredIndent, UI_LLM_ACTIVE_PREFIX
	sparkle := UI_LLM_ACTIVE_PREFIX
	indent := Integer(_LLM_Tooltip_PredIndent)
	if (slotCount >= 2 and indent > 0)
		return _LLM_RepeatChar(" ", indent) . sparkle
	return sparkle
}

_LLM_GetInactivePrefix(slotCount) {
	global _LLM_Tooltip_PredIndent, UI_LLM_INACTIVE_ALIGN_CHAR
	indent := Integer(_LLM_Tooltip_PredIndent)
	if (indent < 0 and indent > -3)
		return _LLM_RepeatChar(" ", -indent)
	if (indent <= -3)
		return _LLM_GetActivePrefix(slotCount) . _LLM_RepeatChar(" ", Max(0, -indent - 3))
	align := UI_LLM_INACTIVE_ALIGN_CHAR
	return (indent > -3) ? align : ""
}

_LLM_FormatValModifiers(valMods) {
	if (valMods = "" or valMods = "none")
		return ""
	sym := valMods
	; NOTE: a 4th positional value here lands on StrReplace's &OutputVarCount param,
	; which must be a VariableRef — passing an Integer (e.g. ``true``) throws
	; "Parameter #5 of StrReplace requires a variable reference". The replacement is
	; case-insensitive by default, which also tolerates "Alt"/"ALT" from config.
	sym := StrReplace(sym, "cmd", "⌘")
	sym := StrReplace(sym, "ctrl", "⌃")
	sym := StrReplace(sym, "alt", "⌥")
	sym := StrReplace(sym, "shift", "⇧")
	return StrReplace(sym, "+", "")
}

_LLM_BuildShortcutSuffix(idx, slotCount, valMods := "") {
	global UI_LLM_SHORTCUT_LABEL_GAP
	if (slotCount <= 1)
		return ""
	sym := _LLM_FormatValModifiers(valMods)
	if (sym = "")
		return ""
	gap := UI_LLM_SHORTCUT_LABEL_GAP
	if (idx <= 9)
		return gap . sym . idx
	if (idx = 10)
		return gap . sym . "0"
	return ""
}

; Build the display string for a slot row (used by the plain-string path).
_LLM_SlotBuildText(slot, is_active, slotIdx := 1, slotCount := 1) {
	global LLM_TOOLTIP_PLACEHOLDER, LLM_TOOLTIP_TAB_SUFFIX, _LLM_Tooltip_ValMods
	prefix := is_active ? _LLM_GetActivePrefix(slotCount) : _LLM_GetInactivePrefix(slotCount)
	shortcut := _LLM_BuildShortcutSuffix(slotIdx, slotCount, _LLM_Tooltip_ValMods)
	if _LLM_SlotIsEmpty(slot)
		return prefix . LLM_TOOLTIP_PLACEHOLDER . shortcut
	txt    := _LLM_SlotGetText(slot)
	suffix := is_active ? LLM_TOOLTIP_TAB_SUFFIX : ""
	return prefix . txt . suffix . shortcut
}

LLM_TooltipSetDisplayOpts(opts) {
	global _LLM_Tooltip_ShowInfoBar, _LLM_Tooltip_InfoModel
	global _LLM_Tooltip_FooterSlots, _LLM_Tooltip_NavMods
	global _LLM_Tooltip_PredIndent, _LLM_Tooltip_ValMods
	if !(opts is Map)
		return
	_LLM_Tooltip_ShowInfoBar := !!(opts.Has("show_info_bar") and opts["show_info_bar"])
	_LLM_Tooltip_InfoModel := (opts.Has("info_model") and opts["info_model"] != "")
		? opts["info_model"] : ""
	_LLM_Tooltip_FooterSlots := (opts.Has("slot_count") and opts["slot_count"] > 0)
		? Integer(opts["slot_count"]) : 1
	_LLM_Tooltip_NavMods := (opts.Has("nav_modifiers") and opts["nav_modifiers"] != "")
		? opts["nav_modifiers"] : ""
	if opts.Has("pred_indent")
		_LLM_Tooltip_PredIndent := Integer(opts["pred_indent"])
	if opts.Has("val_modifiers")
		_LLM_Tooltip_ValMods := opts["val_modifiers"]
}

LLM_TooltipSetChainStart() {
	global _LLM_Tooltip_Chain
	_LLM_Tooltip_Chain.StartTick := A_TickCount
	_LLM_Tooltip_Chain.FirstShowTick := 0
	_LLM_Tooltip_Chain.LastUpdateTick := 0
	_LLM_Tooltip_Chain.TtftMs := 0
	_LLM_Tooltip_Chain.TtltMs := 0
}

LLM_TooltipRefreshChainTiming() {
	global _LLM_Tooltip_Chain
	if !_LLM_Tooltip_Chain.StartTick
		return
	now := A_TickCount
	_LLM_Tooltip_Chain.LastUpdateTick := now
	if !_LLM_Tooltip_Chain.FirstShowTick {
		_LLM_Tooltip_Chain.FirstShowTick := now
		_LLM_Tooltip_Chain.TtftMs := now - _LLM_Tooltip_Chain.StartTick
	}
}

; Freezes the chain timings WITHOUT repainting. Callers invoke it just before the
; render that should display those timings, so the info bar picks TTLT up on that
; render instead of costing a second full rebuild.
;
; This is where AHK and macOS legitimately diverge. The Hammerspoon renderer's
; set_timing() rewrites a single canvas element, so re-rendering after the fact is
; nearly free there. AHK has no partial-update path: _TooltipBuildGuiLlm tears the
; windows down and rebuilds them, measures every row, repaints the border DIB and
; pushes a layered-window update. Doing that twice back to back — once for the
; prediction, once only to print a duration — doubled the cost of the most visible
; moment in the whole LLM flow.
;
; NowTick is supplied by the caller rather than read here so the instant that
; counts as "chain finished" belongs to the caller, not to this helper.
LLM_TooltipMarkChainTimingOnly(NowTick) {
	global _LLM_Tooltip_Chain
	if !_LLM_Tooltip_Chain.StartTick
		return
	final := _LLM_Tooltip_Chain.LastUpdateTick ? _LLM_Tooltip_Chain.LastUpdateTick : NowTick
	_LLM_Tooltip_Chain.TtltMs := final - _LLM_Tooltip_Chain.StartTick
	if !_LLM_Tooltip_Chain.TtftMs {
		_LLM_Tooltip_Chain.TtftMs := _LLM_Tooltip_Chain.TtltMs
		; Claim the first-show slot as well, and do NOT drop this line. On the
		; batch path every intermediate render is a placeholder, so LLM_TooltipShow
		; bails into its loading branch before it ever refreshes the chain:
		; FirstShowTick is still 0 at this point. The render that FOLLOWS this call
		; would then take the first-show branch in LLM_TooltipRefreshChainTiming and
		; overwrite TtftMs with a later value — printing an info bar whose TTFT is
		; greater than the TTLT frozen here.
		if !_LLM_Tooltip_Chain.FirstShowTick
			_LLM_Tooltip_Chain.FirstShowTick := final
	}
}

_LLM_TooltipResetChain() {
	global _LLM_Tooltip_Chain
	_LLM_Tooltip_Chain.StartTick := 0
	_LLM_Tooltip_Chain.FirstShowTick := 0
	_LLM_Tooltip_Chain.LastUpdateTick := 0
	_LLM_Tooltip_Chain.TtftMs := 0
	_LLM_Tooltip_Chain.TtltMs := 0
}

_LLM_FormatInfoLine(modelInfo, ttftMs := "", ttltMs := "", forSizing := false) {
	hasModel := (modelInfo != "")
	hasTtft := (IsNumber(ttftMs) and ttftMs > 0)
	hasTtlt := (IsNumber(ttltMs) and ttltMs > 0)
	if forSizing {
		if !hasTtft
			ttftMs := 9999, hasTtft := true
		if !hasTtlt
			ttltMs := 9999, hasTtlt := true
	}
	if (!hasModel and !hasTtft and !hasTtlt)
		return ""
	pieces := []
	if hasModel
		pieces.Push(modelInfo)
	if hasTtft {
		timing := Format("⏱ {:.2f} s", ttftMs / 1000)
		if hasTtlt
			timing .= Format(" — {:.2f} s", ttltMs / 1000)
		pieces.Push(timing)
	} else if hasTtlt
		pieces.Push(Format("⏱ {:.2f} s", ttltMs / 1000))
	out := ""
	for i, p in pieces
		out .= (i = 1) ? p : " — " . p
	return out
}

_LLM_BuildNavHint(slotCount, navMods := "") {
	global UI_LLM_FOOTER_SPACE_DIV, UI_LLM_HINT_ACCEPT_SINGLE, UI_LLM_HINT_NAV_LEFT
	global UI_LLM_HINT_NAV_RIGHT, UI_LLM_HINT_ACCEPT_CENTER, UI_LLM_HINT_ARROW_LEFT
	global UI_LLM_HINT_ARROW_RIGHT, UI_LLM_HINT_OR, UI_LLM_HINT_ARROW_SEP_LEFT
	global UI_LLM_HINT_ARROW_SEP_RIGHT
	spaceDiv := UI_LLM_FOOTER_SPACE_DIV
	acceptSingle := UI_LLM_HINT_ACCEPT_SINGLE
	if (slotCount <= 1)
		return acceptSingle
	navStr := navMods
	if (navStr = "" or navStr = "none")
		navStr := ""
	else
		navStr := _LLM_FormatValModifiers(navStr)
	hintLeft := UI_LLM_HINT_NAV_LEFT
	hintRight := UI_LLM_HINT_NAV_RIGHT
	hintOr := UI_LLM_HINT_OR
	arrL := UI_LLM_HINT_ARROW_LEFT
	arrR := UI_LLM_HINT_ARROW_RIGHT
	if (navStr != "") {
		hintLeft .= hintOr . navStr . " + " . arrL
		hintRight .= hintOr . navStr . " + " . arrR
	}
	sepL := UI_LLM_HINT_ARROW_SEP_LEFT
	sepR := UI_LLM_HINT_ARROW_SEP_RIGHT
	acceptCenter := UI_LLM_HINT_ACCEPT_CENTER
	return hintLeft . spaceDiv . sepL . spaceDiv . acceptCenter . spaceDiv . sepR . spaceDiv . hintRight
}

_LLM_TooltipAppendFooter(G, &TotalH, TotalW, bgHex) {
	global _LLM_Tooltip_ShowInfoBar, _LLM_Tooltip_InfoModel, _LLM_Tooltip_FooterSlots
	global _LLM_Tooltip_NavMods, _LLM_Tooltip_Chain
	global _TOOLTIP_FONT_NAME, _TOOLTIP_HINT_COLOR_HEX, _TOOLTIP_INFO_COLOR_HEX
	global _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_INFO_FONT_SIZE, _TOOLTIP_PADDING_Y
	global _TOOLTIP_PADDING_X, _TOOLTIP_LINE_SPACING, _TOOLTIP_HINT_SPACING, _TOOLTIP_SEP_COLOR_HEX

	hintText := _LLM_BuildNavHint(_LLM_Tooltip_FooterSlots, _LLM_Tooltip_NavMods)
	infoText := ""
	if _LLM_Tooltip_ShowInfoBar {
		ttft := _LLM_Tooltip_Chain.TtftMs
		ttlt := _LLM_Tooltip_Chain.TtltMs
		infoText := _LLM_FormatInfoLine(_LLM_Tooltip_InfoModel, ttft, ttlt, false)
	}
	if (hintText == "" and infoText == "")
		return

	global UI_LLM_FOOTER_SPACE_DIV, UI_LLM_FOOTER_COMBINED_SEP
	spaceDiv := UI_LLM_FOOTER_SPACE_DIV
	combinedSep := UI_LLM_FOOTER_COMBINED_SEP
	isCombined := false
	combinedText := ""
	combinedSz := { W: 0, H: 0 }
	if (hintText != "" and infoText != "") {
		combinedText := hintText . spaceDiv . combinedSep . spaceDiv . infoText
		combinedSz := _TooltipMeasureTextSize(combinedText, _TOOLTIP_LABEL_FONT_SIZE)
		if (combinedSz.W <= TotalW - 2 * _TOOLTIP_PADDING_X)
			isCombined := true
	}

	; HS layout: preds → line_spacing → sep → line_spacing → hint/info.
	if _TOOLTIP_LINE_SPACING > 0
		TotalH += _TOOLTIP_LINE_SPACING
	sepY := TotalH
	G.SetFont("s1", _TOOLTIP_FONT_NAME)
	G.Add("Text", Format("Background{1} x0 y{2} w{3} h1", _TOOLTIP_SEP_COLOR_HEX, sepY, TotalW), "")
	TotalH += 1
	if _TOOLTIP_LINE_SPACING > 0
		TotalH += _TOOLTIP_LINE_SPACING

	if isCombined {
		rowH := _TOOLTIP_PADDING_Y + combinedSz.H + _TOOLTIP_PADDING_Y
		textY := TotalH + _TOOLTIP_PADDING_Y
		G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", bgHex, TotalH, TotalW, rowH), "")
		G.SetFont("norm c" . _TOOLTIP_HINT_COLOR_HEX . " s" . _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_FONT_NAME)
		textX := Max(_TOOLTIP_PADDING_X, (TotalW - combinedSz.W) // 2)
		G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
			textX, textY, combinedSz.W + 4, combinedSz.H), combinedText)
		TotalH += rowH
		return
	}

	if (hintText != "") {
		hintSz := _TooltipMeasureTextSize(hintText, _TOOLTIP_LABEL_FONT_SIZE)
		hintY := TotalH + _TOOLTIP_PADDING_Y
		hintRowH := _TOOLTIP_PADDING_Y + hintSz.H + _TOOLTIP_PADDING_Y
		G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", bgHex, TotalH, TotalW, hintRowH), "")
		G.SetFont("norm c" . _TOOLTIP_HINT_COLOR_HEX . " s" . _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_FONT_NAME)
		hintX := Max(_TOOLTIP_PADDING_X, (TotalW - hintSz.W) // 2)
		G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
			hintX, hintY, hintSz.W + 4, hintSz.H), hintText)
		TotalH += hintRowH
	}

	if (infoText != "") {
		if (hintText != "")
			TotalH += _TOOLTIP_HINT_SPACING
		infoSz := _TooltipMeasureTextSize(infoText, _TOOLTIP_INFO_FONT_SIZE)
		infoY := TotalH + _TOOLTIP_PADDING_Y
		infoRowH := _TOOLTIP_PADDING_Y + infoSz.H + _TOOLTIP_PADDING_Y
		G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", bgHex, TotalH, TotalW, infoRowH), "")
		G.SetFont("norm c" . _TOOLTIP_INFO_COLOR_HEX . " s" . _TOOLTIP_INFO_FONT_SIZE, _TOOLTIP_FONT_NAME)
		infoX := Max(_TOOLTIP_PADDING_X, (TotalW - infoSz.W) // 2)
		G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
			infoX, infoY, infoSz.W + 4, infoSz.H), infoText)
		TotalH += infoRowH
	}
}



; ======================================
; ===== 3.2) Rich Gui LLM renderer =====
; ======================================

; Build a single Gui that renders all LLM slots with per-chunk coloring.
; Active slot: equal chunks in corr_sel (green), insert/NextWords in nw_sel
; (orange). Inactive slots: full text in unsel_gray. Each slot is one row;
; within a row, segment coloring is achieved by multiple Text controls placed
; side-by-side (same Y, X incremented by measured segment width).
_TooltipBuildGuiLlm(slots, active_idx, RenderGeneration) {
	global _TooltipGui, _TooltipRowGuis
	global _TOOLTIP_FONT_NAME, _TOOLTIP_FONT_SIZE, _TOOLTIP_PADDING_X, _TOOLTIP_PADDING_Y
	global _TOOLTIP_DEFAULT_BG_HEX, _TOOLTIP_SEP_COLOR_HEX, _TOOLTIP_LABEL_FONT_SIZE
	global _TOOLTIP_INFO_FONT_SIZE, _LLM_Tooltip_FooterSlots, _LLM_Tooltip_NavMods
	global _LLM_Tooltip_ShowInfoBar, _LLM_Tooltip_InfoModel, _LLM_Tooltip_ValMods
	global LLM_TOOLTIP_PLACEHOLDER, LLM_TOOLTIP_TAB_SUFFIX
	global UI_LLM_CORR_SEL_HEX, UI_LLM_NW_SEL_HEX, UI_LLM_UNSEL_GRAY_HEX, UI_LLM_LOADING_HEX
	global UI_LLM_CURSOR_HEX, UI_LLM_CMD_SEL_HEX, UI_LLM_CMD_DIM_HEX
	global UI_LLM_FOOTER_SPACE_DIV, UI_LLM_FOOTER_COMBINED_SEP
	; AHK-17: a hotstring dequeue cycle (_TooltipDequeueActive=true) with a 100 ms
	; poll timer fires into a freshly-rendered LLM prediction and force-hides or
	; clobbers it. Clear both dequeue state variables here so the poll timer bails
	; immediately on its next tick (empty items + inactive = no-op in DequeuePollFn).
	global _TooltipDequeueActive, _TooltipDequeueItems
	_TooltipDequeueActive := false
	_TooltipDequeueItems  := 0

	_TooltipSuspendSurfaces()
	_TooltipTeardownBorder()
	if _TooltipGui
		try _TooltipGui.Destroy()
	_TooltipGui    := 0
	_TooltipRowGuis := []

	DpiScale := A_ScreenDPI / 96
	SEP_H    := 1
	Count    := slots.Length

	; ── Measure all row texts to find max width ──────────────────────────────
	; Each row's text = prefix + full slot text + suffix (for width budget).
	Sizes := []
	MaxW  := 0
	slotCount := slots.Length
	all_placeholder := _LLM_AllSlotsPlaceholder(slots)
	loading_label := (IsSet(t)) ? t("llm.generating") : _LLM_TOOLTIP_LOADING_FALLBACK
	for i, slot in slots {
		is_active := (i == active_idx)
		display := all_placeholder ? loading_label : _LLM_SlotBuildText(slot, is_active, i, slotCount)
		S := _TooltipMeasureText(display)
		Sizes.Push(S)
		if (S.W > MaxW)
			MaxW := S.W
	}
	hintText := _LLM_BuildNavHint(_LLM_Tooltip_FooterSlots, _LLM_Tooltip_NavMods)
	infoSizing := ""
	if _LLM_Tooltip_ShowInfoBar
		infoSizing := _LLM_FormatInfoLine(_LLM_Tooltip_InfoModel, 9999, 9999, true)
	spaceDiv := UI_LLM_FOOTER_SPACE_DIV
	combinedSep := UI_LLM_FOOTER_COMBINED_SEP
	if (hintText != "" and infoSizing != "") {
		combinedW := _TooltipMeasureTextSize(
			hintText . spaceDiv . combinedSep . spaceDiv . infoSizing, _TOOLTIP_LABEL_FONT_SIZE).W
		if (combinedW > MaxW)
			MaxW := combinedW
	} else {
		if (hintText != "") {
			hintW := _TooltipMeasureTextSize(hintText, _TOOLTIP_LABEL_FONT_SIZE).W
			if (hintW > MaxW)
				MaxW := hintW
		}
		if (infoSizing != "") {
			infoW := _TooltipMeasureTextSize(infoSizing, _TOOLTIP_INFO_FONT_SIZE).W
			if (infoW > MaxW)
				MaxW := infoW
		}
	}

	TotalW := _TOOLTIP_PADDING_X + MaxW + _TOOLTIP_PADDING_X
	RowMeta := []
	TotalH  := 0
	for Idx, slot in slots {
		RowH := _TOOLTIP_PADDING_Y + Sizes[Idx].H + _TOOLTIP_PADDING_Y
		RowMeta.Push({ H: RowH, Y: TotalH })
		TotalH += RowH
		if (Idx < Count)
			TotalH += SEP_H
	}

	inflight_bg := _TooltipMixTintHex(_TooltipResolveAccent("ai_loading"))
	has_loading := false
	for , slot in slots {
		if _LLM_SlotIsPlaceholder(slot) {
			has_loading := true
			break
		}
	}
	cursorHex := UI_LLM_CURSOR_HEX
	cmdSelHex := UI_LLM_CMD_SEL_HEX
	cmdDimHex := UI_LLM_CMD_DIM_HEX
	G := Gui("+AlwaysOnTop -Caption +E0x20 +E0x80 +LastFound")
	G.BackColor := has_loading ? inflight_bg : _TOOLTIP_DEFAULT_BG_HEX
	G.MarginX := 0
	G.MarginY := 0

	for Idx, slot in slots {
		is_active := (Idx == active_idx)
		Meta := RowMeta[Idx]
		RowY := Meta.Y
		RowH := Meta.H
		S    := Sizes[Idx]
		TextY := RowY + _TOOLTIP_PADDING_Y
		row_bg := _LLM_SlotIsPlaceholder(slot) ? inflight_bg : _TOOLTIP_DEFAULT_BG_HEX
		activePrefix := _LLM_GetActivePrefix(slotCount)
		inactivePrefix := _LLM_GetInactivePrefix(slotCount)
		shortcut := _LLM_BuildShortcutSuffix(Idx, slotCount, _LLM_Tooltip_ValMods)

		; Full-width background band.
		G.SetFont("norm s1", _TOOLTIP_FONT_NAME)
		G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", row_bg, RowY, TotalW, RowH), "")

		if _LLM_SlotIsEmpty(slot) {
			; In-flight slot — full « Génération en cours… » copy when the whole
			; stack is still waiting; otherwise sparkle + ellipsis per slot (HS).
			color := UI_LLM_LOADING_HEX
			prefix := is_active ? activePrefix : inactivePrefix
			loading_label := (IsSet(t)) ? t("llm.generating") : _LLM_TOOLTIP_LOADING_FALLBACK
			display := _LLM_AllSlotsPlaceholder(slots) ? loading_label : (prefix . LLM_TOOLTIP_PLACEHOLDER)
			G.SetFont("italic c" . color . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
			G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
				_TOOLTIP_PADDING_X, TextY, MaxW, S.H), display)
			if (shortcut != "") {
				scSz := _TooltipMeasureTextSize(shortcut, _TOOLTIP_LABEL_FONT_SIZE)
				scColor := is_active ? cmdSelHex : cmdDimHex
				G.SetFont("norm c" . scColor . " s" . _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_FONT_NAME)
				G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
					TotalW - _TOOLTIP_PADDING_X - scSz.W, TextY, scSz.W + 2, S.H), shortcut)
			}
		} else if !is_active {
			; Inactive slot: plain gray.
			G.SetFont("norm c" . UI_LLM_UNSEL_GRAY_HEX . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
			display := inactivePrefix . _LLM_SlotGetText(slot)
			G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
				_TOOLTIP_PADDING_X, TextY, MaxW, S.H), display)
			if (shortcut != "") {
				scSz := _TooltipMeasureTextSize(shortcut, _TOOLTIP_LABEL_FONT_SIZE)
				G.SetFont("norm c" . cmdDimHex . " s" . _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_FONT_NAME)
				G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
					TotalW - _TOOLTIP_PADDING_X - scSz.W, TextY, scSz.W + 2, S.H), shortcut)
			}
		} else {
			; Active slot with per-chunk coloring.
			CurX := _TOOLTIP_PADDING_X
			PrefixSz := _TooltipMeasureText(activePrefix)
			G.SetFont("norm c" . cursorHex . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
			G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
				CurX, TextY, PrefixSz.W + 2, S.H), activePrefix)
			CurX += PrefixSz.W

			has_chunks := IsObject(slot) and slot.HasOwnProp("Chunks") and slot.Chunks.Length > 0
			if has_chunks {
				for , chunk in slot.Chunks {
					chunk_txt := chunk.HasOwnProp("text") ? chunk.text : ""
					if (chunk_txt == "")
						continue
					chunk_color := (chunk.HasOwnProp("type") and chunk.type == "insert") ? UI_LLM_CORR_SEL_HEX : UI_LLM_UNSEL_GRAY_HEX
					CSz := _TooltipMeasureText(chunk_txt)
					G.SetFont("norm c" . chunk_color . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
					G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
						CurX, TextY, CSz.W + 4, S.H), chunk_txt)
					CurX += CSz.W
				}
				nw := slot.HasOwnProp("NextWords") ? slot.NextWords : ""
				has_insert := false
				for , chunk in slot.Chunks {
					if (chunk.HasOwnProp("type") and chunk.type == "insert")
						has_insert := true
				}
				if (nw != "" and !has_insert) {
					CSz := _TooltipMeasureText(nw)
					G.SetFont("norm c" . UI_LLM_NW_SEL_HEX . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
					G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
						CurX, TextY, CSz.W + 4, S.H), nw)
					CurX += CSz.W
				}
			} else {
				; Plain text active slot (streaming).
				plain := _LLM_SlotGetText(slot)
				G.SetFont("norm cFFFFFF s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
				G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
					CurX, TextY, MaxW, S.H), plain)
				CurX += _TooltipMeasureText(plain).W
			}

			if (LLM_TOOLTIP_TAB_SUFFIX != "") {
				G.SetFont("norm c" . _TOOLTIP_LABEL_COLOR_HEX . " s" . _TOOLTIP_FONT_SIZE, _TOOLTIP_FONT_NAME)
				G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
					CurX, TextY, _TooltipMeasureText(LLM_TOOLTIP_TAB_SUFFIX).W + 4, S.H), LLM_TOOLTIP_TAB_SUFFIX)
			}
			if (shortcut != "") {
				scSz := _TooltipMeasureTextSize(shortcut, _TOOLTIP_LABEL_FONT_SIZE)
				G.SetFont("norm c" . cmdSelHex . " s" . _TOOLTIP_LABEL_FONT_SIZE, _TOOLTIP_FONT_NAME)
				G.Add("Text", Format("BackgroundTrans x{1} y{2} w{3} h{4}",
					TotalW - _TOOLTIP_PADDING_X - scSz.W, TextY, scSz.W + 2, S.H), shortcut)
			}
		}

		; Separator.
		if (Idx < Count) {
			SepY := RowY + RowH
			G.SetFont("s1", _TOOLTIP_FONT_NAME)
			G.Add("Text", Format("Background{1} x0 y{2} w{3} h{4}", _TOOLTIP_SEP_COLOR_HEX, SepY, TotalW, SEP_H), "")
		}
	}

	row_bg_final := _TOOLTIP_DEFAULT_BG_HEX
	_LLM_TooltipAppendFooter(G, &TotalH, TotalW, row_bg_final)

    ; A newer show/hide can take ownership while this renderer performs GUI
    ; work. Do not publish this detached Gui into the shared surface afterward.
    global _TooltipGeneration, _TooltipShownHwnds, _TOOLTIP_HWND_TRACK_CAP, _TooltipTimerGeneration
    if (RenderGeneration != _TooltipGeneration) {
        try G.Destroy()
        return false
    }
    _TooltipGui := G
    _TooltipRowGuis := [{ Gui: G, H: TotalH, W: TotalW, IsSep: false }]

	; Cache in a local variable to prevent "Invalid index" crashes if a
	; concurrent TooltipHide clears the global array during the
	; _TooltipResolvePosition yield point.
    Rows := _TooltipRowGuis
    if (Rows.Length == 0) {
        if (RenderGeneration == _TooltipGeneration)
            TooltipHide("LlmLateNoRows", true)
        return false
	}

	; AHK-34: mirror core.ahk — UIA COM must be profiled on the LLM path too
	_hpResolve := HotPath_Now()
    Pos := _TooltipResolvePosition()
    HotPath_LogIfSlow("Tooltip.ResolvePos", _hpResolve, "")
    if (RenderGeneration != _TooltipGeneration)
        return false
    Row := Rows[1]
    _TooltipTimerGeneration := RenderGeneration
    ; The LLM path presents the same stack as the hotstring path but had no
    ; Present segment of its own, so a slow prediction render was invisible while
    ; the identical work on the preview path was reported. Draining the sub-step
    ; attribution here is also what stops _TooltipPresentStack's marks leaking
    ; into whichever segment happens to be measured next.
    _hpLlmPresent := HotPath_Now()
    try {
        _TooltipPresentStack(Pos, Row, true)
    } catch {
        if (RenderGeneration == _TooltipGeneration)
            TooltipHide("LlmPresentFail", true)
        return false
    }
    HotPath_LogIfSlow("Tooltip.LlmPresent", _hpLlmPresent, HotPath_BreakdownDetail())
    if (RenderGeneration != _TooltipGeneration)
        return false
    return true
}
