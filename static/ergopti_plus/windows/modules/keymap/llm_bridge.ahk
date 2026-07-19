; modules/keymap/llm_bridge.ahk

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





; ===============================
; ===============================
; ======= 1/ Buffer State =======
; ===============================
; ===============================

; Hard ceiling on the rolling context buffer. Unlike HSE_Buffer (capped at 64
; chars — the longest hotstring trigger it must match), this buffer feeds
; menu_settings.ahk's SubStr(_LLM_Bridge_Buffer, -_LLM_Menu["ctx_chars"]), and
; ctx_chars is user-configurable up to 10000 (LLM_Menu_PromptCtxChars's range
; in menu_settings.ahk) — so the cap must stay >= that maximum or a high
; ctx_chars setting would silently lose context. It exists only to bound
; per-keystroke growth on an unbroken long typing run: every sibling hot-path
; buffer (HSE_Buffer, KLRoi.current_word) is capped; this one previously was
; not (F47).
global LLM_BRIDGE_BUFFER_MAX_CHARS := 10000
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
; Cursor travel (px, per axis) FROM THE ORIGIN where the prediction appeared,
; before pointer movement counts as a DELIBERATE dismiss. It must clear two kinds
; of incidental motion that the user considers "rien touché": optical-sensor
; jitter / slow drift (1-3 px), AND the ~30-50 px lurch the mouse makes when a
; hand lifts off it and it settles. A real relocation to click/use something else
; crosses far more (200+ px across the screen), and a click dismisses regardless.
; Measured against a FIXED origin (total displacement), not per tick, so a slow
; deliberate move still accumulates past it; drift cannot reach it within the
; prediction's ~20 s lifetime. Tunable — raise it if a mouse lurches further.
global _LLM_POINTER_MOVE_THRESHOLD_PX := 100
; Mirrors macOS llm_bridge.lua HOTSTRING_CHAIN_OFFSET_SEC — prediction fires
; just after the hotstring tooltip would normally close.
global _LLM_HOTSTRING_CHAIN_OFFSET_SEC := 0.05
global _LLM_INFINITE_TOOLTIP_SEC       := 86400
global _LLM_MIN_TOOLTIP_DURATION_SEC   := 0.05





; =================================
; =================================
; ======= 2/ Initialisation =======
; =================================
; =================================

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
	try LLM_Engine_StopGeneration()   ; Cancel in-flight HTTP before disabling the engine
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
 * Mirror a hotstring expansion into the LLM rolling context buffer.
 * Called from HSE_DispatchMatch right after HSE_ApplyExpansion so the LLM
 * buffer stays in sync with the on-screen text even though physical chars
 * typed inside the 60 ms post-fire suppression window are not fed via
 * LLM_Bridge_FeedCharIfActive (AHK-23).
 * Mirrors HSE_ApplyExpansion semantics: strip Spec.Length + EndChar off the
 * right end of _LLM_Bridge_Buffer, then append Replacement + EndChar.
 * @param {Object} Spec - Hotstring spec with a .Length property.
 * @param {string} Replacement - The expanded text.
 * @param {string} EndChar - The terminator char, empty for star triggers.
 */
LLM_Bridge_ApplyExpansionIfActive(Spec, Replacement, EndChar := "") {
	global _LLM_Bridge_Active, _LLM_Bridge_Buffer
	if !(IsSet(_LLM_Bridge_Active) && _LLM_Bridge_Active)
		return
	StripLen := Spec.Length + (EndChar != "" ? 1 : 0)
	BufLen := StrLen(_LLM_Bridge_Buffer)
	if (BufLen >= StripLen) {
		_LLM_Bridge_Buffer := SubStr(_LLM_Bridge_Buffer, 1, BufLen - StripLen)
	} else {
		_LLM_Bridge_Buffer := ""
	}
	_LLM_Bridge_Buffer .= Replacement
	if (EndChar != "")
		_LLM_Bridge_Buffer .= EndChar
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
		; Skip if an accept is already in progress from the Tab hotkey path to
		; avoid double-injection when the InputHook and the hotkey fire together.
		if (IsSet(_LLM_AcceptInProgress) and _LLM_AcceptInProgress)
			return
		if (IsSet(LLM_Tooltip_TryAcceptTab) and LLM_Tooltip_TryAcceptTab()) {
			; Cancel the debounce timer so a stale prediction does not flash
			; the tooltip again immediately after the user accepted the suggestion
			LLM_Engine_CancelTimer()
			return
		}
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
 * Schedules an LLM prediction to fire when the hotstring tooltip closes.
 * Called from the prefix watcher after TooltipShow / TooltipRearmTimer.
 * Parity with macOS llm_bridge.update_preview() chain branch.
 * @param {Array} items - Tooltip rows shown by TooltipShow (DurationSec per row).
 */
LLM_Bridge_ScheduleAfterHotstring(items) {
	global _LLM_Bridge_Active, _LLM_Bridge_Buffer, _LLM_Engine
	global _LLM_HOTSTRING_CHAIN_OFFSET_SEC, _LLM_INFINITE_TOOLTIP_SEC
	global _LLM_MIN_TOOLTIP_DURATION_SEC

	if !(IsSet(_LLM_Bridge_Active) && _LLM_Bridge_Active)
		return
	if !(IsSet(_LLM_Engine) && _LLM_Engine["enabled"] && _LLM_Engine["after_hotstring"])
		return
	if !(IsObject(items) && items.Length > 0)
		return

	LLM_Engine_CancelTimer()

	minDur := 0
	hasDur := false
	for , Item in items {
		D := Item.HasOwnProp("DurationSec") ? Item.DurationSec : 0
		if (D > 0) {
			hasDur := true
			if (minDur == 0 or D < minDur)
				minDur := D
		}
	}
	tooltipTimeout := hasDur
		? Max(_LLM_MIN_TOOLTIP_DURATION_SEC, minDur)
		: _LLM_INFINITE_TOOLTIP_SEC
	delaySec := tooltipTimeout + _LLM_HOTSTRING_CHAIN_OFFSET_SEC
    BridgeBuffer := _LLM_Bridge_Buffer
	try LoggerDebug("LLM", "Hotstring chain scheduled in {1:.3f}s.", delaySec)
    LLM_Engine_StartTimer(delaySec, BridgeBuffer)
}

; Returns true when char ``c`` is a word boundary — whitespace or common sentence/
; clause punctuation. Apostrophes are intentionally NOT boundaries (French "l'arbre").
_LLM_Bridge_IsBoundaryChar(c) {
	static _boundaries := " `t`n`r.,;:!?" . Chr(0x00A0) . Chr(0x202F)
	return (c != "" and InStr(_boundaries, c) > 0)
}

; True when the just-typed char completes a word and instant_on_word_end is enabled:
; the char is a boundary and the character before it (the buffer already has ch
; appended) is a word character. Mirrors macOS engine.start_timer_word_end gating.
_LLM_Bridge_IsWordEndTrigger(ch) {
	global _LLM_Engine, _LLM_Bridge_Buffer
	if !(_LLM_Engine.Has("instant_on_word_end") and _LLM_Engine["instant_on_word_end"])
		return false
	if !_LLM_Bridge_IsBoundaryChar(ch)
		return false
	prev := SubStr(_LLM_Bridge_Buffer, -2, 1)  ; the char before the just-appended ch
	return (prev != "" and !_LLM_Bridge_IsBoundaryChar(prev))
}

/**
 * Must be called from a hotkey or keyboard hook on every typed character.
 * Maintains the rolling context buffer and feeds it to the prediction engine.
 * @param {string} ch - The character that was just typed.
 */
LLM_Bridge_OnChar(ch) {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active, LLM_BRIDGE_BUFFER_MAX_CHARS
	if !_LLM_Bridge_Active
		return

	_LLM_Bridge_Buffer .= ch
	if (StrLen(_LLM_Bridge_Buffer) > LLM_BRIDGE_BUFFER_MAX_CHARS)
		; Drop the oldest characters, keep the most recent typing — mirrors
		; HSE_FeedChar's trim-to-tail pattern (F47).
		_LLM_Bridge_Buffer := SubStr(_LLM_Bridge_Buffer, -LLM_BRIDGE_BUFFER_MAX_CHARS)
	; Hotstring tooltip priority: if the PrefixWatcher's tooltip is visible,
	; update the buffer but do NOT arm the LLM timer — LLM_Bridge_ScheduleAfterHotstring
	; (fired from _LookupAndRender / TooltipRearmTimer) owns the chain delay until
	; the overlay closes, mirroring HS update_preview().
	if TooltipIsVisible()
		return
	; Only hide OUR tooltip — never dismiss a hotstring overlay.
	; Silent=true so no llm_dismissed event is emitted for a stale hide.
	if LLM_Tooltip_IsVisible() {
		; Minimum-display window: a keystroke that was already in flight when the
		; slow model finally answered must not kill the prediction before the user
		; can perceive it. The buffer still advances below; only the dismiss is
		; deferred. Once the window elapses, typing dismisses as usual.
		if (IsSet(LLM_Tooltip_InGracePeriod) && LLM_Tooltip_InGracePeriod()) {
			try LoggerDebug("LLM.tt", "KEEP: keystroke '{1}' ignored — prediction still in min-display window.", ch)
		} else {
			try LoggerDebug("LLM.tt", "DISMISS: keystroke '{1}' typed while a prediction was shown.", ch)
			; Defer the tooltip teardown off the InputHook thread: the dismiss tears
			; down a multi-window layered overlay (DeferWindowPos batch + Gui Destroy),
			; and a slow DWM compositor can stretch that past Windows'
			; LowLevelHooksTimeout, dropping the in-flight or next physical key. The
			; hook stays fast — buffer + engine feed below are cheap — while the
			; expensive GDI/DWM work runs on a fresh thread once the hook returns
			; (mirrors the auto-hide TimerFn, which already runs off-thread). Silent=true
			; so no llm_dismissed event is emitted for this stale hide.
			SetTimer((*) => LLM_Tooltip_Hide(true), -1)
		}
	}
	global _LLM_Bridge_LastLogTick
	now := A_TickCount
	; Wrap-safe tick delta: A_TickCount overflows at ~49.7 days
	if (((now - _LLM_Bridge_LastLogTick + 0x100000000) & 0xFFFFFFFF) > 2000) {
		_LLM_Bridge_LastLogTick := now
		try LoggerInfo("LLM", "Keystroke buffered ({1} chars) — debounce pending.", StrLen(_LLM_Bridge_Buffer))
	}
	; instant_on_word_end: when the just-typed char completes a word (a word char
	; followed by whitespace/punctuation) and the user enabled the option, fire the
	; prediction immediately instead of waiting the full debounce — macOS parity with
	; engine.start_timer_word_end (llm-instant-word-end-trigger).
	if _LLM_Bridge_IsWordEndTrigger(ch)
		LLM_Engine_OnKeystroke(_LLM_Bridge_Buffer, 0)
	else
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
	try LoggerDebug("LLM.tt", "ResetPredictions: cancelling generation + hiding any tooltip.")
	if (IsSet(_LLM_Engine) and _LLM_Engine.Has("reset_on_nav") and _LLM_Engine["reset_on_nav"])
		_LLM_Bridge_Buffer := ""
	try LLM_Tooltip_MarkChainComplete()
	LLM_Engine_StopGeneration()
	if ((IsSet(LLM_Tooltip_IsVisible) && LLM_Tooltip_IsVisible())
			or (IsSet(LLM_Tooltip_IsLoading) && LLM_Tooltip_IsLoading()))
		LLM_Tooltip_Hide()
}

/**
 * Entry point for mouse / touchpad / wheel activity. Cancels ANY in-progress LLM
 * work — the loading spinner, an in-flight generation, or a shown prediction — so
 * any user input dismisses the prediction (macOS parity: its mouse_tap calls
 * reset_predictions on a click in every phase, and a keystroke cancels generation
 * via stop_timer). A real prediction is still shielded during its minimum-display
 * grace window so an incidental click / drift the instant it renders cannot kill it
 * before it is seen — the loading spinner has no grace, so it cancels immediately.
 */
LLM_Bridge_OnPointerActivity(reason := "?") {
	if !LLM_Bridge_HasActivePredictionWork()
		return
	; Minimum-display window: ignore stray pointer drift in the first moments after a
	; real prediction renders so it cannot vanish before the user perceives it.
	; InGracePeriod is false during loading, so the spinner stays fully cancellable.
	if (IsSet(LLM_Tooltip_InGracePeriod) && LLM_Tooltip_InGracePeriod())
		return
	; ``reason`` names the exact trigger: a mouse-button / wheel hotkey passes its
	; own name (e.g. "~LButton"), the move-tick passes "move dx=.. dy=..". This is
	; the lens for "it vanished while I sat still" — the log says whether it was a
	; real click, a wheel event, or pointer travel, and by how much.
	try LoggerDebug("LLM.tt", "DISMISS: pointer activity ({1}) — cancelling in-progress generation + tooltip.", reason)
	LLM_Bridge_ResetPredictions()
}

_LLM_PointerWatch_Start() {
    global _LLM_PointerWatch_Armed, _LLM_PointerWatch_MoveFn, _LLM_PointerWatch_ActivityFn, _LLM_PointerWatch_LastX, _LLM_PointerWatch_LastY
	if _LLM_PointerWatch_Armed
		return
	_LLM_PointerWatch_Armed := true
	_LLM_PointerWatch_LastX := unset
	_LLM_PointerWatch_LastY := unset
	; Always create a fresh Func object on each arm so the previous stop/start
	; cycle cannot leave a stale closure still registered in HookDispatcher — a
	; second Register with the SAME Func object would fire the handler twice per
	; event if HookDispatcher does not deduplicate by identity
	_LLM_PointerWatch_ActivityFn := LLM_Bridge_OnPointerActivity.Bind()
	; Subscribe via HookDispatcher for every key the dispatcher owns so we do not
	; clobber the dispatcher's central handlers (mouse-hotkey-clobber). XButton1/2
	; are not registered by the dispatcher — keep those as direct hotkeys.
	for evt in [HookDispatcherConst.EVT_MS_LDOWN, HookDispatcherConst.EVT_MS_RDOWN,
			HookDispatcherConst.EVT_MS_MDOWN, HookDispatcherConst.EVT_MS_WUP,
			HookDispatcherConst.EVT_MS_WDN, HookDispatcherConst.EVT_MS_WLEFT,
			HookDispatcherConst.EVT_MS_WRIGHT] {
		HookDispatcher.Register(evt, _LLM_PointerWatch_ActivityFn)
	}
	try Hotkey("~XButton1", _LLM_PointerWatch_ActivityFn, "On")
	try Hotkey("~XButton2", _LLM_PointerWatch_ActivityFn, "On")
	; Similarly create a fresh move-tick closure so SetTimer can cancel the old
	; one cleanly even if _LLM_PointerWatch_Stop was called without cancelling
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
		for evt in [HookDispatcherConst.EVT_MS_LDOWN, HookDispatcherConst.EVT_MS_RDOWN,
				HookDispatcherConst.EVT_MS_MDOWN, HookDispatcherConst.EVT_MS_WUP,
				HookDispatcherConst.EVT_MS_WDN, HookDispatcherConst.EVT_MS_WLEFT,
				HookDispatcherConst.EVT_MS_WRIGHT] {
			HookDispatcher.Unregister(evt, _LLM_PointerWatch_ActivityFn)
		}
		try Hotkey("~XButton1", _LLM_PointerWatch_ActivityFn, "Off")
		try Hotkey("~XButton2", _LLM_PointerWatch_ActivityFn, "Off")
	}
	try LoggerDebug("LLM", "Pointer-dismiss watcher stopped.")
}

; True when the cursor has travelled far enough from its origin to count as a
; deliberate move rather than sensor jitter / a hand resting on the mouse. Pure,
; so the threshold logic is unit-testable without a real pointer.
_LLM_PointerMovedEnough(x, y, ox, oy) {
	global _LLM_POINTER_MOVE_THRESHOLD_PX
	return (Abs(x - ox) > _LLM_POINTER_MOVE_THRESHOLD_PX
			or Abs(y - oy) > _LLM_POINTER_MOVE_THRESHOLD_PX)
}

_LLM_PointerWatch_OnMoveTick(*) {
	global _LLM_PointerWatch_LastX, _LLM_PointerWatch_LastY
	local _c := Critical("On")
	try {
	; AHK SetTimer threads bypass native Suspend, so this poll keeps firing
	; (MouseGetPos + branch) ~20x/s while the driver is paused. Inert it here so
	; "pause = tout eteint" holds even if the suspend reactor's _Stop call is ever
	; bypassed — the timer is also stopped from Ergopti_OnSuspendEnter, but this
	; guard is the cheap, local safety net.
	if A_IsSuspended
		return
	; Dismiss-on-move applies whenever LLM work is active — the loading spinner, an
	; in-flight generation, or a shown prediction (any input cancels). While NO work
	; is active we drop the origin so the next cycle captures a fresh one; the grace
	; branch below still shields a just-rendered prediction during its window.
	if !LLM_Bridge_HasActivePredictionWork() {
		_LLM_PointerWatch_LastX := unset
		_LLM_PointerWatch_LastY := unset
		return
	}
	; During the minimum-display window, ignore pointer movement entirely and keep
	; the origin unset, so motion that happened while the prediction was settling in
	; cannot dismiss it the instant the window opens.
	if (IsSet(LLM_Tooltip_InGracePeriod) && LLM_Tooltip_InGracePeriod()) {
		_LLM_PointerWatch_LastX := unset
		_LLM_PointerWatch_LastY := unset
		return
	}
	MouseGetPos(&x, &y)
	; First tick past the window: capture the ORIGIN once and never dismiss on it.
	if !IsSet(_LLM_PointerWatch_LastX) {
		_LLM_PointerWatch_LastX := x
		_LLM_PointerWatch_LastY := y
		return
	}
	; Measure TOTAL displacement from that fixed origin and dismiss only once it
	; clears the threshold — a deliberate relocation of the cursor. The origin is
	; never reassigned, so a hand lifting off the mouse (a ~50 px settle) and any
	; jitter/drift stay below it and keep the prediction up; only travelling well
	; away from where the prediction appeared counts as "the user moved on". This is
	; the "arrêté, rien touché" fix. A click still dismisses via its own hotkeys.
	dx := Abs(x - _LLM_PointerWatch_LastX)
	dy := Abs(y - _LLM_PointerWatch_LastY)
	if _LLM_PointerMovedEnough(x, y, _LLM_PointerWatch_LastX, _LLM_PointerWatch_LastY)
		LLM_Bridge_OnPointerActivity("move dx=" . dx . " dy=" . dy)
	} finally {
		Critical(_c)
	}
}

/**
 * Called when the user accepts the suggestion (e.g. pressing Tab over tooltip).
 * Appends the accepted text to the buffer and types it into the active window.
 * @param {string} text - The accepted prediction text.
 */
LLM_Bridge_OnAccept(text) {
	global _LLM_Bridge_Buffer
	; AHK-09: invalidate every in-flight sequential/streaming variant callback so
	; they cannot re-show the tooltip after the user has already accepted a
	; suggestion. StopGeneration bumps request_id (all async callbacks bail on id
	; mismatch), cancels curl+WinHTTP streams, cancels the debounce timer, and
	; drops last_ctx/last_results so the dismissed context cannot replay from cache.
	; Must run BEFORE the injection so the id is bumped while callbacks are live.
	try LLM_Engine_StopGeneration()
	; Mute the hotstring InputHook before injecting the prediction so the
	; synthetic characters do not re-enter the engine and trigger false
	; hotstring matches on the appended text.
	if IsSet(PrefixWatcherSuppress)
		try PrefixWatcherSuppress(true)
	; Tag the auto-typed prediction as synthetic so the keylogger keeps it out
	; of the manual `chars` count and attributes it to the LLM source (esrc).
	try KL_MarkSynthetic("llm")
	; Completion callback: runs after TextSend has finished emitting all
	; keystrokes. Releasing the synthetic flag and the prefix-watcher
	; suppression here (rather than on a fixed timer) ensures the guards are
	; held for exactly as long as the injection is observable — even for
	; multi-sentence predictions that take longer than 80 ms to drain.
	; The callback also resyncs the LSC ring to the trailing chars of the
	; injected text so dead-key and ellipsis decisions see the prediction's
	; tail, not pre-prediction characters.
	; AHK-10: PrefixWatcherSuppress and KL_MarkSynthetic are DEPTH COUNTERS that must
	; be released exactly once per acquire. TextSend calls _InjectCallback on success
	; (synchronously for direct mode, deferred via SetTimer for clipboard mode >1000 chars)
	; and the callback owns the release. The finally must release ONLY when TextSend
	; threw before invoking the callback. Use an exception-thrown gate so clipboard-
	; mode defers never release synchronously ahead of the paste. A `released` flag
	; is wrong for clipboard mode (TextSend returns before invoking the callback so
	; `released` is still false when the finally runs — the correct gate is whether
	; TextSend threw, not whether the callback ran synchronously).
	_InjectCallback := _LLM_Bridge_OnInjectComplete.Bind(text)
	_threw := false
	try {
		TextSend(text, 0, _InjectCallback)
		; Clear the stale pre-prediction HSE and prefix buffers — the cursor is
		; now past the injected text, so accumulated context is no longer valid.
		if IsSet(HSE_HardReset)
			try HSE_HardReset()
		if IsSet(_ResetPrefixBuffer)
			try _ResetPrefixBuffer()
	} catch as AcceptError {
		; TextSend threw before the callback could run — arm the finally release
		_threw := true
		throw AcceptError
	} finally {
		; Release guards only when TextSend threw and never invoked the callback.
		; On the success path (direct or clipboard) the callback owns the release.
		if _threw {
			try KL_ClearSynthetic()
			if IsSet(PrefixWatcherSuppress)
				try PrefixWatcherSuppress(false)
		}
	}
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

; Invoked by TextSend after all keystrokes for an accepted/injected prediction
; have been emitted. Releases the keylogger synthetic flag and the prefix-watcher
; suppression that were armed in LLM_Bridge_OnAccept before injection, and
; resyncs the LSC ring to the trailing characters of the injected text.
; @param {string} InjectedText - The prediction text that was injected.
_LLM_Bridge_OnInjectComplete(InjectedText, *) {
	try KL_ClearSynthetic()
	if IsSet(PrefixWatcherSuppress)
		try PrefixWatcherSuppress(false)
	; Resync the last-sent-character ring so dead-key and ellipsis consumers
	; see the prediction's tail rather than pre-prediction characters.
	if IsSet(_LSCResetFrom) {
		Tail := []
		N := Min(StrLen(InjectedText), 5)
		loop N
			Tail.Push(SubStr(InjectedText, StrLen(InjectedText) - N + A_Index, 1))
		try _LSCResetFrom(Tail)
	}
}
