; modules/llm/prediction_keylogger.ahk

; ==============================================================================
; MODULE: LLM Prediction Engine — Keystroke Handler
; DESCRIPTION:
; Handles incoming keystrokes for the debounce-based prediction engine.
; Arms and cancels the debounce timer, cancels in-flight generation on each
; keystroke, and exposes busy-query and stop-generation helpers.
;
; Included by modules/llm/prediction_engine.ahk after the lifecycle section.
; ==============================================================================





; ====================================
; ====================================
; ======= 1/ Keystroke Handler =======
; ====================================
; ====================================

; Capture the top-level window and focused-control identity as one immutable
; acceptance origin. Both values are required: two editors can share a single
; top-level HWND, while a windowless/restricted control may only expose the
; adapter's foreground-window fallback. Any probe failure returns BOTH fields
; zeroed so acceptance fails closed instead of reusing an older request origin.
; @returns {Map} Map("hwnd", Integer, "control", Integer).
_LLM_Engine_CaptureAcceptSource() {
	Source := Map("hwnd", 0, "control", 0)
	PreviousCritical := Critical("On")
	try {
		try {
			Hwnd := WinGetID("A")
			ControlToken := WIGetFocusedControlToken()
			if (Hwnd is Integer and Hwnd > 0
					and ControlToken is Integer and ControlToken > 0) {
				Source["hwnd"] := Hwnd
				Source["control"] := ControlToken
			}
		} catch {
			; Keep the zeroed pair: focus could not be verified.
		}
	} finally {
		Critical(PreviousCritical)
	}
	return Source
}

/**
 * Called on every relevant keystroke. Resets the debounce timer.
 * Callers (llm_bridge.ahk) pass the current typed buffer.
 * @param {string} buffer - Full typed context up to the caret.
 */
LLM_Engine_OnKeystroke(buffer, delay_override_ms := "", ScheduleFn := SetTimer) {
	global _LLM_Engine
	local _c := Critical("On")
	try {
		if !_LLM_Engine["enabled"]
			return

		LLM_Engine_CancelTimer()
		; Mirror macOS update_preview -> engine.stop_timer(): every keystroke cancels
		; any in-flight generation before re-arming. Without it a superseded request
		; (the user typed past it) kept the "génération en cours" spinner alive and
		; blocked Ollama's single queue behind stale work, draining for many seconds
		; after the user stopped typing — the lingering-spinner parity bug. Windows
		; previously cancelled only the debounce timer here.
		LLM_Engine_CancelInflight()

		; Arm debounce timer — closure captures the full buffer AND its focused
		; control. PromptBuilder (macOS parity) derives capped context + tail
		; inside FirePrediction. Binding the origin prevents a later keystroke in
		; another control from re-attributing this request before the timer fires.
		AcceptSource := _LLM_Engine_CaptureAcceptSource()
		_LLM_Engine["last_buffer"] := buffer
		_LLM_Engine["pending_timer"] := LLM_Engine_FirePrediction.Bind(buffer, AcceptSource)
		; A word-end fast-fire (instant_on_word_end) passes a delay override; otherwise the
		; configured debounce applies. Max(1, ...) keeps an override of 0 near-immediate.
		HasOverride := delay_override_ms != "" and IsNumber(delay_override_ms)
		_arm_ms := HasOverride ? Max(1, delay_override_ms) : _LLM_Engine["debounce_ms"]
		TimerPeriod := HasOverride ? -_arm_ms
			: LLM_Option_DebounceTimerPeriod(_LLM_Engine["debounce_ms"])
		ScheduleFn.Call(_LLM_Engine["pending_timer"], TimerPeriod)
		_LLM_Engine["timer_active"] := true
	} finally {
		Critical(_c)
	}
}

/**
 * Arms the debounce timer with an optional delay override in seconds.
 * Mirrors HS prediction_engine.start_timer(delay_override). When omitted,
 * uses the configured debounce_ms. The buffer defaults to last_buffer,
 * then falls back to the LLM bridge rolling context.
 * @param {number} delaySec - Optional timer delay in seconds (0 = immediate).
 * @param {string} buffer - Optional context override captured at schedule time.
 */
LLM_Engine_StartTimer(delaySec := "", buffer := "", PublishGuard := unset,
		ScheduleFn := SetTimer) {
	global _LLM_Engine
	if !_LLM_Engine["enabled"]
		return false

	if (buffer == "") {
		buffer := _LLM_Engine.Has("last_buffer") ? _LLM_Engine["last_buffer"] : ""
		if (buffer == "" and IsSet(_LLM_Bridge_Buffer))
			buffer := _LLM_Bridge_Buffer
	}
	if (buffer == "")
		return false

	; Focus capture and delay calculation may query adapters; perform them before
	; the guarded mutation span. A token-aware caller rechecks only at the exact
	; cancel/re-arm transaction, so a stale callback cannot cancel a newer timer.
	AcceptSource := _LLM_Engine_CaptureAcceptSource()
	HasOverride := delaySec != "" and IsNumber(delaySec)
	delay_ms := HasOverride
		? Max(1, Round(delaySec * 1000))
		: _LLM_Engine["debounce_ms"]
	TimerPeriod := HasOverride ? -delay_ms
		: LLM_Option_DebounceTimerPeriod(_LLM_Engine["debounce_ms"])
	PendingTimer := LLM_Engine_FirePrediction.Bind(buffer, AcceptSource)
	PreviousCritical := Critical("On")
	try {
		if IsSet(PublishGuard) && !PublishGuard.Call()
			return false
		LLM_Engine_CancelTimer()
		_LLM_Engine["last_buffer"] := buffer
		_LLM_Engine["pending_timer"] := PendingTimer
		ScheduleFn.Call(_LLM_Engine["pending_timer"], TimerPeriod)
		_LLM_Engine["timer_active"] := true
	} finally {
		Critical(PreviousCritical)
	}
	return true
}

/**
 * Cancels any pending debounce timer.
 */
LLM_Engine_CancelTimer() {
	global _LLM_Engine
	local _c := Critical("On")
	try {
		; Always clear state so callers that pre-delete pending_timer still get a clean
		; result. The timer_active guard is skipped intentionally — an extra no-op
		; SetTimer(0) on an already-elapsed timer is harmless and avoids subtle
		; state divergence when the guard and the actual timer state disagree.
		if _LLM_Engine.Has("pending_timer") and IsObject(_LLM_Engine["pending_timer"])
			SetTimer(_LLM_Engine["pending_timer"], 0)
		_LLM_Engine["pending_timer"] := ""
		_LLM_Engine["timer_active"]  := false
	} finally {
		Critical(_c)
	}
}

/**
 * Returns true while a debounce timer, HTTP request, or curl stream is active.
 * Used by the pointer-dismiss watcher to avoid polling work when idle.
 */
LLM_Engine_IsBusy() {
	global _LLM_Engine, _LLM_Ollama_ActiveStreams, _LLM_Ollama_Async, _LLM_Remote_Async
	if (IsSet(_LLM_Engine) and _LLM_Engine.Has("timer_active") and _LLM_Engine["timer_active"])
		return true
	if (IsSet(_LLM_Ollama_ActiveStreams) and _LLM_Ollama_ActiveStreams.Length > 0)
		return true
	if (IsSet(_LLM_Ollama_Async)) {
		for , entry in _LLM_Ollama_Async {
			if (IsObject(entry) and (!entry.Has("cancelled") or !entry["cancelled"]))
				return true
		}
	}
	if (IsSet(_LLM_Remote_Async)) {
		for , entry in _LLM_Remote_Async {
			if (IsObject(entry) and (!entry.Has("cancelled") or !entry["cancelled"]))
				return true
		}
	}
	return false
}

/**
 * Stops debounced and in-flight generation without hiding the tooltip.
 * Mirrors HS prediction_engine.stop_timer() + cancel_streaming().
 */
LLM_Engine_StopGeneration() {
	global _LLM_Engine
	local _c := Critical("On")
	NewRequestId := -1
	try {
		LLM_Engine_CancelTimer()
		if IsSet(_LLM_Engine) {
			_LLM_Engine["request_id"] := (_LLM_Engine.Has("request_id") ? _LLM_Engine["request_id"] : 0) + 1
			NewRequestId := _LLM_Engine["request_id"]
			; Drop the prediction cache on every explicit stop (navigation reset,
			; pause/suspend). Context and semantic configuration jointly own a cache
			; entry; without this a context the user returns to — or rebuilds after a
			; pause/resume — would instantly replay a prediction they already
			; dismissed, surfacing as a "ghost" suggestion. The next fire on that
			; context must take the network path, not the cache branch.
			_LLM_Engine["last_ctx"]     := ""
			_LLM_Engine["last_results"] := []
			_LLM_Engine["last_result"]  := ""
			_LLM_Engine["last_semantic_signature"]  := ""
			_LLM_Engine["active_request_signature"] := ""
		}
		try LLM_OllamaCancelStreams()
		try LLM_OllamaCancelAllAsync()
		try LLM_RemoteCancelAllAsync()
	} finally {
		Critical(_c)
	}
	return NewRequestId
}

/**
 * Cancels in-flight generation (streaming + async + remote) and invalidates any
 * stale callbacks by bumping request_id — WITHOUT cancelling the debounce timer or
 * dropping the prediction cache. Mirrors macOS prediction_engine cancel_streaming(),
 * which update_preview() calls on every keystroke so typing always kills a
 * superseded request before re-arming. StopGeneration (which also cancels the timer
 * and drops the cache) stays for the heavier nav-reset / pause path.
 */
LLM_Engine_CancelInflight() {
	global _LLM_Engine
	local _c := Critical("On")
	try {
		if IsSet(_LLM_Engine) {
			_LLM_Engine["request_id"] := (_LLM_Engine.Has("request_id") ? _LLM_Engine["request_id"] : 0) + 1
			_LLM_Engine["active_request_signature"] := ""
		}
		try LLM_OllamaCancelStreams()
		try LLM_OllamaCancelAllAsync()
		try LLM_RemoteCancelAllAsync()
	} finally {
		Critical(_c)
	}
}
