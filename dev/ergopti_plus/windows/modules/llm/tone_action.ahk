; modules/llm/tone_action.ahk

; ==============================================================================
; MODULE: Tone Ladder Actions (AHK)
; DESCRIPTION:
; Runs the llm_tone_more_formal / llm_tone_more_familiar actions and their
; _cycle variants: the selection is rewritten one register up or down the tone
; ladder (modules/llm/tone.ahk) and replaced in place, left selected.
;
; FEATURES & RATIONALE:
; 1. The selection is read like wrap_selection reads it (GetSelectionAsync:
;    clipboard copy with restore), and nothing selected does nothing.
; 2. One request, one answer, straight to the backend's own request function
;    (the one the prediction engine dispatches through), never the tooltip
;    pipeline: the rewrite replaces the selection as soon as it arrives.
; 3. The answer is typed over the selection, then exactly the typed text is
;    selected again, so the next step applies to it; the memory of that rewrite
;    makes the next step rewrite the ORIGINAL text, not the rewrite.
; 4. An answer is typed only into the window that asked for it: the focus is
;    compared when the answer arrives and again, as the sender's admission, at
;    the instant the keys are sent.
; 5. A new step supersedes the one in flight: its generation is retained
;    through queued output admission and courtesy selection completion.
;
; The refusals (paused, AI off, backend not ready) and their notices are those
; of the manual prediction trigger (ui/menu/menu_llm/menu_settings.ahk).
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Module State =============
; =====================================
; =====================================

; The last rewrite typed over a selection: Map("source", "output", "level"),
; or "" before the first one (LLM_Tone_Remember)
global _LLM_Tone_Memory := ""

; Generation of the newest step; an answer carrying an older one is stale
global _LLM_Tone_Generation := 0

; Selection reader, GetSelectionAsync's signature, of every selection action
; (LLM_SelectionReader). 0 selects the real clipboard capture; the test suite
; installs a reader that answers synchronously.
global _LLM_Tone_ReadSelection := 0

; Focus probe returning an identity String ("" when unknown). 0 selects the
; foreground window and focused control; the test suite installs its own.
global _LLM_Tone_FocusProbe := 0





; ================================
; ================================
; ======= 2/ Public API ==========
; ================================
; ================================

/**
 * The tone actions: direction x cycle, one entry per action id.
 * @returns {Map} Action id -> { Direction, Cycle }.
 */
LLM_ToneActions() {
	global LLM_TONE_MORE_FORMAL, LLM_TONE_MORE_FAMILIAR
	static Actions := Map(
		"llm_tone_more_formal", { Direction: LLM_TONE_MORE_FORMAL, Cycle: false },
		"llm_tone_more_familiar", { Direction: LLM_TONE_MORE_FAMILIAR, Cycle: false },
		"llm_tone_more_formal_cycle", { Direction: LLM_TONE_MORE_FORMAL, Cycle: true },
		"llm_tone_more_familiar_cycle", { Direction: LLM_TONE_MORE_FAMILIAR, Cycle: true },
	)
	return Actions
}

/**
 * Runs one tone step on the selection. The selection arrives asynchronously;
 * this call only supersedes any step still waiting and starts the capture.
 * @param {Integer} Direction LLM_TONE_MORE_FORMAL or LLM_TONE_MORE_FAMILIAR.
 * @param {Boolean} Cycle Whether to wrap around at the ends of the ladder.
 * @returns {Boolean} True when the selection capture started.
 */
LLM_Tone_Trigger(Direction, Cycle) {
	global _LLM_Tone_Generation
	_LLM_Tone_Generation += 1
	if !LLM_SelectionReader().Call(_LLM_Tone_OnSelection.Bind(_LLM_Tone_Generation, Direction, Cycle)) {
		LoggerInfo("LLM", "Tone step skipped: the selection could not be read (paused or clipboard busy).")
		return false
	}
	return true
}

/**
 * The selection reader of the actions that work on the selection (the tone
 * ladder, the translation): GetSelectionAsync, or the test suite's reader.
 * @returns {Func} Called with OnText; returns false when it cannot read.
 */
LLM_SelectionReader() {
	global _LLM_Tone_ReadSelection
	return HasMethod(_LLM_Tone_ReadSelection, "Call") ? _LLM_Tone_ReadSelection : GetSelectionAsync
}





; =====================================
; =====================================
; ======= 3/ Request and Answer =======
; =====================================
; =====================================

; The selection arrived: plan the step, apply the refusals, send the request.
; @param {Integer} Generation The step's generation.
; @param {Integer} Direction The ladder direction.
; @param {Boolean} Cycle Whether to wrap around.
; @param {String} Text The selected text ("" when nothing is selected).
_LLM_Tone_OnSelection(Generation, Direction, Cycle, Text) {
	global _LLM_Tone_Generation, _LLM_Tone_Memory, _LLM_Menu, LLM_TONE_MORE_FORMAL
	if (Generation != _LLM_Tone_Generation) {
		LoggerDebug("LLM", "Tone step dropped: a newer step superseded it before the selection arrived.")
		return
	}
	Plan := LLM_Tone_Plan(Text, _LLM_Tone_Memory, Direction, Cycle, &Reason)
	if !(Plan is Map) {
		if (Reason == "empty_selection") {
			LoggerDebug("LLM", "Tone step skipped: nothing is selected.")
			return
		}
		LoggerInfo("LLM", "Tone step refused: the selection is already at the end of the ladder ({1}).",
			(Direction == LLM_TONE_MORE_FORMAL) ? "most formal" : "most familiar")
		_LLM_Menu_ShowManualPredictionNotice((Direction == LLM_TONE_MORE_FORMAL)
			? "llm.tone.most_formal" : "llm.tone.most_familiar")
		return
	}
	Enabled := _LLM_Menu.Get("enabled", false)
	Refusal := LLM_Menu_ManualPredictionRefusal(A_IsSuspended, Enabled,
		Enabled && _LLM_Menu_BackendIsReadyForUse(), Plan["source"])
	if (Refusal != "") {
		_LLM_Menu_ShowManualPredictionRefusal(Refusal, StrLen(Plan["source"]))
		return
	}
	; The selection would leave an app the user excluded from the AI
	if _LLM_Engine_ShouldSuppressForDisabledApps()
		return
	_LLM_Tone_Dispatch(Generation, Plan, _LLM_Tone_CurrentFocus())
}

; Sends the one request of a step to the current backend.
; @param {Integer} Generation The step's generation.
; @param {Map} Plan LLM_Tone_Plan's plan.
; @param {String} Focus The focus identity the answer must still find.
; @returns {Boolean} True when the request was sent.
_LLM_Tone_Dispatch(Generation, Plan, Focus) {
	global _LLM_Engine
	ProfileId := Plan["profile_id"]
	Profile := LLM_FindProfile(ProfileId, _LLM_Engine.Get("user_profiles", []))
	if !(Profile is Map) {
		LoggerError("LLM", "Tone step dropped: the built-in prompt '{1}' is missing.", ProfileId)
		return false
	}
	if (Focus == "") {
		LoggerWarn("LLM", "Tone step dropped: the focused window cannot be identified.")
		return false
	}
	Source := Plan["source"]
	SystemPrompt := LLM_ResolveSystemPrompt(Profile, 1, _LLM_Engine["min_words"],
		_LLM_Engine["max_words"], _LLM_Engine["language"])
	MaxTokens := LLM_Rewrite_MaxTokens(Source)
	Temperature := _LLM_Engine["temperature"] + 0.0
	OnSuccess := _LLM_Tone_OnAnswer.Bind(Generation, Plan, Focus)
	OnFail := _LLM_Tone_OnFail.Bind(Generation, ProfileId)
	Backend := _LLM_Engine.Get("backend", "ollama")
	Entry := ""
	if (Backend == "api") {
		Entry := _LLM_Engine_GetActiveApiEntry()
		if !IsObject(Entry) {
			LoggerWarn("LLM", "Tone step dropped: the API backend has no entry configured.")
			return false
		}
	}
	; A pending or in-flight automatic prediction would hold the backend's
	; single slot and delay the rewrite behind it; so would an older step.
	LLM_Engine_CancelTimer()
	LLM_Engine_CancelInflight()
	_LLM_Engine["last_request_tick"] := A_TickCount
	; The size of the selection, never its content: it is the user's own text
	LoggerInfo("LLM", "Tone step requested with '{1}' ({2} character(s)).", ProfileId, StrLen(Source))
	; PREFIX and TAIL are both the text to rewrite: a selection has no context
	if (Backend == "api")
		_LLM_Engine_ResolveRemoteTransport().Call(Entry, SystemPrompt, Source, Temperature,
			OnSuccess, OnFail, Source, MaxTokens)
	else
		LLM_OllamaGenerate_Async(LLM_ResolveOllamaTag(_LLM_Engine["model"]), SystemPrompt, Source,
			Temperature, OnSuccess, OnFail, "", MaxTokens, false, Source)
	return true
}

; The model answered: type the rewrite over the selection, in the same window.
; @param {Integer} Generation The step's generation.
; @param {Map} Plan The step's plan.
; @param {String} Focus The focus identity at dispatch.
; @param {String} Raw The model's answer.
; @param {Map} Meta Usage metadata (remote backend), unused.
; @param {Func} SendFn Optional sender; resolved at call time.
_LLM_Tone_OnAnswer(Generation, Plan, Focus, Raw, Meta := "", SendFn := unset) {
	global _LLM_Tone_Generation
	if (Generation != _LLM_Tone_Generation) {
		LoggerInfo("LLM", "Tone answer ignored: a newer step superseded it.")
		return
	}
	if A_IsSuspended {
		LoggerInfo("LLM", "Tone answer dropped: the driver is paused.")
		return
	}
	Text := LLM_Tone_Extract(Raw)
	if (Text == "") {
		LoggerWarn("LLM", "Tone answer dropped: the model's answer holds no rewrite ({1} character(s)).",
			(Raw is String) ? StrLen(Raw) : 0)
		return
	}
	if !_LLM_Tone_OutputCurrent(Generation, Focus) {
		LoggerInfo("LLM", "Tone answer dropped: its step was superseded or the focus moved to another window.")
		return
	}
	Opts := Map(
		; Left to the adapter: typed, or pasted where typed text is garbled
		"mode", "auto",
		"atomic_input", true,
		; Checked again at the instant the keys are sent
		"admission", _LLM_Tone_OutputCurrent.Bind(Generation, Focus)
	)
	if !IsSet(SendFn)
		SendFn := TextSend
	if !HasMethod(SendFn, "Call")
		throw TypeError("Tone output requires a callable sender.")
	SendFn.Call(Text, Opts, _LLM_Tone_OnTyped.Bind(Generation, Plan, Focus, Text))
}

; The rewrite was typed (or refused): select it again and remember it.
; @param {Integer} Generation The step which owns this completion.
; @param {Map} Plan The step's plan.
; @param {String} Focus The focused window and control at dispatch.
; @param {String} Text The typed rewrite.
; @param {Boolean} Ok Whether the text was sent.
; @param {String} ErrorMessage Why it was not.
; @param {Func} SelectFn Optional courtesy selection sender; resolved at call time.
_LLM_Tone_OnTyped(Generation, Plan, Focus, Text, Ok, ErrorMessage := "", SelectFn := unset) {
	global _LLM_Tone_Memory
	if !Ok {
		LoggerInfo("LLM", "Tone rewrite not typed: {1}.", ErrorMessage)
		return
	}
	if !_LLM_Tone_OutputCurrent(Generation, Focus) or A_IsSuspended {
		LoggerInfo("LLM", "Tone completion dropped: its step or focused control is no longer current, or the driver is paused.")
		return
	}
	if !IsSet(SelectFn)
		SelectFn := TextSelectBack
	if !HasMethod(SelectFn, "Call")
		throw TypeError("Tone completion requires a callable selection sender.")
	if !SelectFn.Call(LLM_Rewrite_CodepointLength(Text))
		LoggerWarn("LLM", "Tone rewrite typed but not selected again.")
	; The selection sender may finish yielding effects before it returns. A
	; newer step owns the memory even when the old selection was admitted.
	if !_LLM_Tone_OutputCurrent(Generation, Focus) or A_IsSuspended {
		LoggerInfo("LLM", "Tone completion memory dropped: its output owner was retired during selection.")
		return
	}
	_LLM_Tone_Memory := LLM_Tone_Remember(Plan, Text)
	LoggerInfo("LLM", "Tone rewrite applied with '{1}' ({2} character(s)).",
		Plan["profile_id"], StrLen(Text))
}

; The request failed: nothing is typed.
; @param {Integer} Generation The step's generation.
; @param {String} ProfileId The ladder profile it ran.
; @param {Map} Failure Remote failure details, when the backend gives them.
_LLM_Tone_OnFail(Generation, ProfileId, Failure := "") {
	global _LLM_Tone_Generation
	if (Generation != _LLM_Tone_Generation)
		return
	Reason := (Failure is Map) ? Failure.Get("reason", "") : ""
	LoggerWarn("LLM", "Tone step with '{1}' failed{2}.", ProfileId,
		(Reason != "") ? " (" . Reason . ")" : "")
}





; =====================================
; =====================================
; ======= 4/ Focus Identity ===========
; =====================================
; =====================================

; @returns {String} The foreground window and focused control, "" when unknown.
_LLM_Tone_CurrentFocus() {
	global _LLM_Tone_FocusProbe
	if HasMethod(_LLM_Tone_FocusProbe, "Call")
		return _LLM_Tone_FocusProbe.Call()
	Hwnd := WinExist("A")
	if !Hwnd
		return ""
	return Hwnd . ":" . WIGetFocusedControlToken()
}

; Admission predicate of the typed rewrite: a strict Boolean, false when the
; focus is unknown.
; @param {String} Focus The focus identity at dispatch.
; @returns {Integer} True when the same window and control still have focus.
_LLM_Tone_FocusUnchanged(Focus) {
	Current := _LLM_Tone_CurrentFocus()
	return (Focus != "" && Current == Focus) ? true : false
}

; Admission of queued output and its courtesy selection share the step owner.
; Recheck after the focus probe: the probe can finish a newer callback.
; @param {Integer} Generation The step which produced the rewrite.
; @param {String} Focus The focused window and control captured at dispatch.
; @returns {Integer} True only while the same step and focus remain current.
_LLM_Tone_OutputCurrent(Generation, Focus) {
	global _LLM_Tone_Generation
	if Generation != _LLM_Tone_Generation
		return false
	FocusCurrent := _LLM_Tone_FocusUnchanged(Focus)
	return FocusCurrent and Generation == _LLM_Tone_Generation
}
