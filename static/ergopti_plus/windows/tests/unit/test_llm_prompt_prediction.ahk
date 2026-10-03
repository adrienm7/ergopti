; static/ergopti_plus/windows/tests/unit/test_llm_prompt_prediction.ahk

; ==============================================================================
; MODULE: AI Prediction With a Chosen Prompt, and the Rewrite Prompt (Windows)
; DESCRIPTION:
; Drives llm_prompt_prediction and the llm_predict_<profile> presets through the
; real code path, with only the two outer boundaries faked: the network (the
; engine's remote transport, answered with a Cerebras/OpenAI-dialect body that
; the real response classifier reads) and the keyboard (the SendInput primitive
; TextSender emits through). Typed buffer -> action -> outgoing request (system
; prompt, tail, token budget, count) -> model answer -> parser -> tooltip slot
; carrying its erasure -> accept -> Backspaces and text in one batch -> buffer.
;
; ROOT CAUSE ENCODED:
; A prediction could only use the globally active prompt, and the Windows accept
; path could not erase: every prediction that replaced typed text was dropped
; (llm-parser-deletes-never-applied). A rewrite replaces the sentence being
; typed, so it needed both: its own prompt per binding, and an erase step that
; runs inside the same admission-guarded output as the text it types.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================
; =================================
; ======= 1/ Shared fixture =======
; =================================
; =================================

; The typed buffer every scenario starts from: a finished sentence, then the
; abbreviated one being typed.
global LPP_BUFFER := "Bonjour Marc. ok pr jd 14h"
global LPP_SENTENCE := "ok pr jd 14h"

_LPP_Entry() {
	return Map(
		"Id", "remote-a",
		"Provider", "openai",
		"BaseUrl", "https://example.invalid/v1",
		"Token", "secret",
		"Model", "model-a")
}

; A menu whose remote backend is ready, with "advanced" as the active profile.
_LPP_Menu(Enabled := true) {
	return Map(
		"backend", "api",
		"enabled", Enabled,
		"api_entry_id", "remote-a",
		"api_entries", [_LPP_Entry()],
		"model", "local-a",
		"ctx_chars", 500,
		"bootstrap_pending", false,
		"profile_id", "advanced",
		"n_predictions", 3,
		"user_profiles", [])
}

; The engine state matching that menu. Streaming and the per-app overrides are
; off so the scenario is deterministic; the rate floor starts open.
_LPP_Engine(Base) {
	Engine := Base.Clone()
	Settings := Map(
		"enabled", true, "backend", "api",
		"api_entries", [_LPP_Entry()], "api_entry_id", "remote-a",
		"profile_id", "advanced", "user_profiles", [], "n_predictions", 3,
		"min_words", 1, "max_words", 5, "ctx_chars", 500, "language", "fr",
		"streaming", false, "show_all_at_once", true, "inline_autotype", false,
		"disable_password_fields", false, "disabled_apps", [],
		"app_profile_overrides", Map(), "last_request_tick", 0,
		"last_ctx", "", "last_results", [], "last_semantic_signature", "")
	for Key, Value in Settings
		Engine[Key] := Value
	return Engine
}

; The fake network: records what the engine hands the remote transport.
_LPP_RecordTransport(Calls, Entry, SystemPrompt, Ctx, Temperature, OnSuccess, OnFail,
		Tail := "", MaxTokens := "") {
	Calls.Push(Map("entry", Entry, "system", SystemPrompt, "ctx", Ctx,
		"temperature", Temperature, "on_success", OnSuccess, "on_fail", OnFail,
		"tail", Tail, "max_tokens", MaxTokens))
	return Calls.Length
}

; Answers one recorded request the way the curl poller does: the provider body
; goes through the real classifier, and its text and usage reach on_success.
_LPP_Answer(Call, Content) {
	Body := '{"id":"chatcmpl-1","object":"chat.completion","model":"model-a",'
		. '"choices":[{"index":0,"message":{"role":"assistant","content":'
		. JsonStringLiteral(Content) . '},"finish_reason":"stop"}],'
		. '"usage":{"prompt_tokens":40,"completion_tokens":9,"total_tokens":49}}'
	Classified := _LLMRemoteClassifyResponse("openai", Body, "model-a")
	AssertTrue(Classified["ok"], "the OpenAI-dialect answer must classify as a completion")
	Call["on_success"].Call(Classified["text"], Classified["usage"])
}

; The text of the tooltip request TooltipShow published, or "" when none.
_LPP_PendingNotice() {
	global _TooltipPendingRequest
	if !IsObject(_TooltipPendingRequest)
		return ""
	Items := _TooltipPendingRequest.Items
	if (Items is Array)
		Items := Items.Length ? Items[1] : ""
	return (IsObject(Items) && Items.HasOwnProp("Text")) ? Items.Text : ""
}

; The last final render the engine published to the tooltip.
_LPP_LastFinalRender() {
	global _Stub_LlmTooltipCalls
	Index := _Stub_LlmTooltipCalls.Length
	while (Index >= 1) {
		Call := _Stub_LlmTooltipCalls[Index]
		if (Call.HasOwnProp("is_final") && Call.is_final)
			return Call
		Index -= 1
	}
	return ""
}

; Runs Body(Calls, Lines) with the menu, the engine, the bridge buffer, the
; binding parameters, the fake transport and a log capture in place, then puts
; every one of them back.
_LPP_Run(Menu, Buffer, Body, AllowTimers := false) {
	global _LLM_Menu, _LLM_Engine, _LLM_Bridge_Buffer, _LLM_Engine_RemoteTransport
	global GestureActionParameters, _Stub_LlmTooltipCalls
	global _LOGGER_TEST_SINK, _LOGGER_INFO_ENABLED
	Saved := {
		Menu: _LLM_Menu, Engine: _LLM_Engine, Buffer: _LLM_Bridge_Buffer,
		Transport: _LLM_Engine_RemoteTransport, Parameters: GestureActionParameters,
		Tooltip: _Stub_LlmTooltipCalls, Sink: _LOGGER_TEST_SINK, Info: _LOGGER_INFO_ENABLED
	}
	Calls := []
	Lines := []
	; Synchronous scenarios retire notices before relinquishing their fake ports.
	; Live-mode scenarios opt in to the deferred observers they exercise.
	PreviousCritical := AllowTimers ? A_IsCritical : Critical("On")
	try {
		_LLM_Menu := Menu
		_LLM_Engine := _LPP_Engine(Saved.Engine)
		_LLM_Bridge_Buffer := Buffer
		GestureActionParameters := Saved.Parameters.Clone()
		_Stub_LlmTooltipCalls := []
		_LLM_Engine_RemoteTransport := _LPP_RecordTransport.Bind(Calls)
		_LOGGER_INFO_ENABLED := true
		LoggerSetTestSink((Line) => Lines.Push(Line))
		Body(Calls, Lines)
	} finally {
		; Retire whatever the scenario left in flight on its own engine state.
		LLM_Engine_StopGeneration()
		TooltipHide("PromptPredictionTest", true)
		_LOGGER_TEST_SINK := Saved.Sink
		_LOGGER_INFO_ENABLED := Saved.Info
		_LLM_Engine_RemoteTransport := Saved.Transport
		_Stub_LlmTooltipCalls := Saved.Tooltip
		GestureActionParameters := Saved.Parameters
		_LLM_Bridge_Buffer := Saved.Buffer
		_LLM_Engine := Saved.Engine
		_LLM_Menu := Saved.Menu
		Critical(PreviousCritical)
	}
}

; @returns {Integer} How many captured lines hold Needle at the given level.
_LPP_LinesWith(Lines, Level, Needle) {
	Count := 0
	for Line in Lines
		if InStr(Line, "[" . Level . "]") && InStr(Line, Needle)
			Count += 1
	return Count
}

; Runs Body with the keyboard boundary replaced by a recorder, and with every
; mirror an accepted output commits restored afterwards.
_LPP_WithKeyboard(Body) {
	global _AHK_SendInput, HSE_Buffer, HSE_StartIsWordBoundary
	global _PrefixBuffer, _PrefixFocusedControlToken
	global _PrefixContentGeneration, _PrefixInputContextGeneration
	global _LSC_RING, _LSC_CURSOR, _LSC_LEN
	Saved := {
		Send: _AHK_SendInput, Hse: HSE_Buffer, HseBoundary: HSE_StartIsWordBoundary,
		Prefix: _PrefixBuffer, PrefixControl: _PrefixFocusedControlToken,
		PrefixGeneration: _PrefixContentGeneration,
		ContextGeneration: _PrefixInputContextGeneration,
		LscRing: _LSC_RING.Clone(), LscCursor: _LSC_CURSOR, LscLen: _LSC_LEN
	}
	Sent := []
	try {
		_AHK_SendInput := (Keys) => Sent.Push(Keys)
		Body(Sent)
	} finally {
		_AHK_SendInput := Saved.Send
		HSE_Buffer := Saved.Hse
		HSE_StartIsWordBoundary := Saved.HseBoundary
		_PrefixBuffer := Saved.Prefix
		_PrefixFocusedControlToken := Saved.PrefixControl
		_PrefixContentGeneration := Saved.PrefixGeneration
		_PrefixInputContextGeneration := Saved.ContextGeneration
		_LSC_RING := Saved.LscRing
		_LSC_CURSOR := Saved.LscCursor
		_LSC_LEN := Saved.LscLen
	}
}

; An acceptance transaction for the presented slot. The admission predicate is
; the one piece replaced: it probes the real foreground window, which a headless
; runner cannot own, and its own tests cover it (test_llm_tab_accept_policy).
_LPP_AcceptTransaction(Presented) {
	Seed := Map("hwnd", 1, "control", 1, "physical_generation", 0,
		"content_generation", 0, "context_generation", 0)
	Transaction := _LLM_Bridge_NewInjectionTransaction(Presented.Text, Seed, 1, false,
		Presented.Slots, Presented.ActiveIdx, 0, 0,
		_LLM_Bridge_AcceptedSlotEdit(Presented.Text, Presented.Slots, Presented.ActiveIdx))
	Transaction.Admission := () => true
	return Transaction
}





; ==========================================================
; ==========================================================
; ======= 2/ Rewrite, end to end, through the action =======
; ==========================================================
; ==========================================================

_LPP_RewriteEndToEnd() {
	global LPP_BUFFER
	_LPP_Run(_LPP_Menu(), LPP_BUFFER, _Body)
	_Body(Calls, Lines) {
		global GestureActionParameters, _LLM_Menu, _LLM_Engine, _LLM_Bridge_Buffer, LPP_SENTENCE
		Binding := "keyboard__rewrite_test"
		GestureActionParameters[GestureActionParameterKey(Binding, "llm_prompt_prediction")] := "rewrite|2"
		AssertTrue(GestureInvokeAction("llm_prompt_prediction", Binding),
			"the bound action must request a prediction")

		; The outgoing request.
		AssertEqual(1, Calls.Length, "the first variant is dispatched at once")
		Call := Calls[1]
		Rewrite := LLM_FindProfile("rewrite")
		AssertEqual(LLM_ResolveSystemPrompt(Rewrite, 2, 1, 5, "fr"), Call["system"],
			"the binding's prompt answers, not the active one")
		AssertContains(Call["system"], "REWRITE:", "the rewrite prompt asks for the rewrite tag")
		AssertEqual(LPP_BUFFER, Call["ctx"], "the context is the typed text")
		AssertEqual(LPP_SENTENCE, Call["tail"], "the tail is the current sentence, not five words")
		AssertEqual(_LLM_Engine_CallTokenBudget(LLM_Rewrite_MaxTokens(LPP_SENTENCE), 1),
			Call["max_tokens"], "the budget is the rewrite budget, not the continuation one")
		Request := _LLMRemote_BuildRequestContext(Call["system"], Call["ctx"], Call["tail"])
		AssertEqual('PREFIX: "' . LPP_BUFFER . '"`nTAIL: "' . LPP_SENTENCE . '"', Request["user"],
			"the user turn names the sentence as the TAIL")
		Payload := _LLMRemoteBuildPayload("openai", "model-a", Request["system"], Request["user"],
			Call["temperature"], Call["max_tokens"])
		AssertContains(Payload, '"max_tokens":' . Call["max_tokens"], "the wire request carries the budget")
		AssertEqual("advanced", _LLM_Menu["profile_id"], "the active profile is untouched")
		AssertEqual("advanced", _LLM_Engine["profile_id"], "the engine's profile is untouched")
		AssertEqual(3, _LLM_Engine["n_predictions"], "the menu's count is untouched")

		; The model answers; the binding's count is two.
		_LPP_Answer(Calls[1], "REWRITE: Ok pour jeudi 14 h.")
		AssertEqual(2, Calls.Length, "a count of two asks a second variant")
		_LPP_Answer(Calls[2], "REWRITE: OK pour jeudi à 14 h.")
		AssertEqual(2, Calls.Length, "and no third one")
		Final := _LPP_LastFinalRender()
		AssertTrue(IsObject(Final), "the answers must reach the tooltip")
		AssertEqual(2, Final.slots.Length, "both rewrites are offered")
		Slot := Final.slots[1]
		AssertTrue(IsObject(Slot) && Slot.HasOwnProp("Deletes"), "a rewrite slot carries its erasure")
		AssertEqual("Ok pour jeudi 14 h.", Slot.Text, "the slot types the rewritten sentence")
		AssertEqual(StrLen(LPP_SENTENCE), Slot.Deletes, "it erases the whole sentence it rewrites")
		AssertEqual(LPP_SENTENCE, Slot.DeletedText, "and names what it erases")

		; Tab: erase then type, in one output, then mirror both in the buffer.
		_LPP_WithKeyboard(_Accept)
		_Accept(Sent) {
			global _LLM_Bridge_Buffer
			Presented := LLM_Tooltip_GetAcceptSnapshot()
			AssertTrue(IsObject(Presented), "the final render must be acceptable")
			Transaction := _LPP_AcceptTransaction(Presented)
			AssertEqual(StrLen(LPP_SENTENCE), Transaction.Deletes, "the accept step erases the sentence")
			AssertTrue(_LLM_Bridge_RewriteStillApplies(Transaction), "nothing was typed meanwhile")
			Results := []
			TextSend(Transaction.Text, _LLM_Bridge_InjectionOptions(Transaction),
				(Ok, ErrorMessage := "") => Results.Push(Ok))
			AssertEqual(1, Sent.Length, "the erasure and the text are one SendInput batch")
			AssertEqual("{Backspace " . StrLen(LPP_SENTENCE) . "}{Text}Ok pour jeudi 14 h.", Sent[1],
				"one Backspace per erased character, then the rewrite in text mode")
			AssertEqual(1, Results.Length, "the sender completes once")
			AssertTrue(Results[1], "the output is reported as emitted")
			AssertEqual("Bonjour Marc. Ok pour jeudi 14 h.", _LLM_Bridge_Buffer,
				"the buffer mirrors the erase and the insert")
		}
	}
}
Test("LLM prompt prediction: a rewrite binding runs end to end with a fake network and keyboard",
	_LPP_RewriteEndToEnd)

; Every built-in gets a ready-made action running it with the menu's count.
_LPP_PresetsRunTheirProfile() {
	global LPP_BUFFER
	_LPP_Run(_LPP_Menu(), LPP_BUFFER, _Body)
	_Body(Calls, Lines) {
		global LLM_PROFILE_BUILTIN_ORDER, _LLM_Engine, _LLM_Menu, LPP_SENTENCE
		Checked := 0
		for Id in LLM_PROFILE_BUILTIN_ORDER {
			_LLM_Engine["last_request_tick"] := 0
			Before := Calls.Length
			AssertTrue(GestureInvokeAction("llm_predict_" . Id),
				"llm_predict_" . Id . " must request a prediction")
			AssertEqual(Before + 1, Calls.Length, "llm_predict_" . Id . " dispatches one request")
			Call := Calls[Calls.Length]
			AssertEqual(LLM_ResolveSystemPrompt(LLM_FindProfile(Id), 3, 1, 5, "fr"), Call["system"],
				"llm_predict_" . Id . " runs its own profile with the menu's count")
			if LLM_Rewrite_IsRewriteProfile(LLM_FindProfile(Id))
				AssertEqual(LPP_SENTENCE, Call["tail"], "the rewrite preset " . Id . " sends the sentence")
			else
				AssertFalse(Call["tail"] == LPP_SENTENCE && Call["max_tokens"]
					== _LLM_Engine_CallTokenBudget(LLM_Rewrite_MaxTokens(LPP_SENTENCE), 1),
					"a continuation preset keeps the continuation request shape")
			Checked += 1
		}
		AssertEqual(11, Checked,
			"one preset per built-in, rewrite, the tone ladder and the translations included")
		AssertEqual("advanced", _LLM_Menu["profile_id"], "no preset changes the active profile")
	}
}
Test("LLM prompt prediction: each llm_predict_<profile> preset runs its built-in",
	_LPP_PresetsRunTheirProfile)

; The global active profile may be the rewrite one: the automatic path then
; builds the same rewrite request as the action.
_LPP_ActiveRewriteProfileRewrites() {
	global LPP_BUFFER
	_LPP_Run(_LPP_Menu(), LPP_BUFFER, _Body)
	_Body(Calls, Lines) {
		global _LLM_Engine, LPP_BUFFER, LPP_SENTENCE
		_LLM_Engine["profile_id"] := "rewrite"
		LLM_Engine_FirePrediction(LPP_BUFFER)
		AssertEqual(1, Calls.Length, "the automatic trigger dispatches the request")
		AssertEqual(LPP_SENTENCE, Calls[1]["tail"], "the tail is the current sentence")
		AssertEqual(_LLM_Engine_CallTokenBudget(LLM_Rewrite_MaxTokens(LPP_SENTENCE), 1),
			Calls[1]["max_tokens"], "the budget is the rewrite budget")
	}
}
Test("LLM prompt prediction: the rewrite profile also rewrites when it is the active one",
	_LPP_ActiveRewriteProfileRewrites)

; A sentence longer than the capped context still reaches the model whole.
_LPP_LongSentenceExtendsTheContext() {
	Sentence := ""
	loop 30
		Sentence .= "mot" . A_Index . " "
	Sentence .= "fin"
	_LPP_Run(_LPP_Menu(), "Avant. " . Sentence, _Body)
	_Body(Calls, Lines) {
		global _LLM_Engine
		_LLM_Engine["ctx_chars"] := 40
		AssertTrue(StrLen(Sentence) > 40, "precondition: the sentence exceeds the context cap")
		LLM_Engine_FirePrediction("Avant. " . Sentence, , Map("profile_id", "rewrite"))
		AssertEqual(1, Calls.Length, "the rewrite is dispatched")
		AssertEqual(Sentence, Calls[1]["tail"], "the whole sentence is rewritten")
		AssertEqual(Sentence, Calls[1]["ctx"], "the context grows to hold it, as an exact suffix")
	}
}
Test("LLM prompt prediction: a sentence longer than the context cap is sent whole",
	_LPP_LongSentenceExtendsTheContext)





; ============================================
; ============================================
; ======= 3/ The action's own contract =======
; ============================================
; ============================================

_LPP_CountAndProfileReachTheEngine() {
	_LPP_Run(_LPP_Menu(), "0123456789 abc", _Body)
	_Body(Calls, Lines) {
		global GestureActionParameters, _LLM_Menu
		Binding := "gesture__tap_3"
		GestureActionParameters[GestureActionParameterKey(Binding, "llm_prompt_prediction")] := "basic|4"
		Fired := []
		AssertTrue(GesturePromptPrediction(Binding, (Context, Override) => Fired.Push([Context, Override])),
			"a valid binding requests a prediction")
		AssertEqual(1, Fired.Length, "the engine is asked once")
		AssertEqual("0123456789 abc", Fired[1][1], "the continuation context is the capped buffer")
		AssertEqual("basic", Fired[1][2]["profile_id"], "the binding's profile is requested")
		AssertEqual(4, Fired[1][2]["num_predictions"], "the binding's count is requested")
		AssertEqual("advanced", _LLM_Menu["profile_id"], "the active profile is untouched")

		GestureActionParameters[GestureActionParameterKey(Binding, "llm_prompt_prediction")] := "basic"
		AssertTrue(GesturePromptPrediction(Binding, (Context, Override) => Fired.Push([Context, Override])),
			"a binding without a count requests a prediction")
		AssertEqual(0, Fired[2][2]["num_predictions"], "no count of its own leaves the menu's count")
	}
}
Test("LLM prompt prediction: the binding's profile and count reach the engine",
	_LPP_CountAndProfileReachTheEngine)

_LPP_UnknownPromptIsRefusedWithItsNotice() {
	_LPP_Run(_LPP_Menu(), "hello world", _Body)
	_Body(Calls, Lines) {
		global GestureActionParameters
		Binding := "gesture__tap_4"
		GestureActionParameters[GestureActionParameterKey(Binding, "llm_prompt_prediction")] := "user_deleted_42|2"
		Fired := []
		AssertFalse(GesturePromptPrediction(Binding, (Context, Override) => Fired.Push(Override)),
			"a prompt that no longer exists must not run")
		AssertEqual(0, Fired.Length, "no other prompt is run in its place")
		AssertEqual(t("llm.prompt_prediction.unknown_prompt"), _LPP_PendingNotice(),
			"the user is told the prompt is gone")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "user_deleted_42"),
			"the refusal is logged with the missing id")
	}
}
Test("LLM prompt prediction: a deleted prompt is refused with its notice, never replaced",
	_LPP_UnknownPromptIsRefusedWithItsNotice)

_LPP_SharedRefusalsStillApply() {
	_LPP_Run(_LPP_Menu(false), "hello world", _Body)
	_Body(Calls, Lines) {
		Fired := []
		AssertFalse(LLM_Menu_TriggerPredictionWith("basic", 2, (C, O) => Fired.Push(O)),
			"an AI switched off refuses the chosen prompt too")
		AssertEqual(t("llm.manual_prediction.disabled"), _LPP_PendingNotice(),
			"with the notice llm_generate_prediction shows")
		AssertEqual(0, Fired.Length, "nothing is requested")
	}
	_LPP_Run(_LPP_Menu(), "   ", _Blank)
	_Blank(Calls, Lines) {
		Fired := []
		AssertFalse(LLM_Menu_TriggerPredictionWith("rewrite", 0, (C, O) => Fired.Push(O)),
			"a blank sentence has nothing to rewrite")
		AssertEqual(t("llm.manual_prediction.empty_context"), _LPP_PendingNotice(),
			"it is refused as nothing typed")
		AssertEqual(0, Fired.Length, "nothing is requested")
	}
}
Test("LLM prompt prediction: the manual-prediction refusals and notices apply",
	_LPP_SharedRefusalsStillApply)

_LPP_InvalidStoredValueDoesNothing() {
	_LPP_Run(_LPP_Menu(), "hello world", _Body)
	_Body(Calls, Lines) {
		global GestureActionParameters
		Binding := "gesture__tap_5"
		GestureActionParameters[GestureActionParameterKey(Binding, "llm_prompt_prediction")] := "rewrite|11"
		Fired := []
		AssertFalse(GesturePromptPrediction(Binding, (C, O) => Fired.Push(O)),
			"a hand-edited invalid value is re-validated and refused")
		AssertEqual(0, Fired.Length, "nothing is requested")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "llm_prompt_prediction ignored"),
			"the refusal is logged")
	}
}
Test("LLM prompt prediction: an invalid stored value is refused at run time",
	_LPP_InvalidStoredValueDoesNothing)

; The info bar names the prompt that answered, not the active one.
_LPP_InfoBarNamesTheOverride() {
	_LPP_Run(_LPP_Menu(), LPP_BUFFER, _Body)
	_Body(Calls, Lines) {
		global _LLM_Engine, _LLM_Menu, LPP_BUFFER
		_LLM_Engine["user_profiles"] := [Map("id", "user_pro_1", "label", "Pro — formal",
			"system_single", "Continue formally: {context}", "batch", false)]
		_LLM_Menu["user_profiles"] := _LLM_Engine["user_profiles"]
		LLM_Engine_FirePrediction(LPP_BUFFER, , Map("profile_id", "user_pro_1", "num_predictions", 1))
		Override := _LLM_Engine["request_prompt_override"]
		AssertTrue(Override is Map, "the request records the prompt it runs")
		AssertEqual("user_pro_1", Override["profile_id"], "for the info bar")
		AssertEqual(_LLM_Engine["request_id"], Override["request_id"], "for this request only")
		LLM_Engine_FirePrediction(LPP_BUFFER)
		AssertEqual("", _LLM_Engine["request_prompt_override"], "an ordinary request clears it")
	}
}
Test("LLM prompt prediction: the info bar follows the request's own prompt",
	_LPP_InfoBarNamesTheOverride)

; Two counts never share a cache entry or a callback identity.
_LPP_CountIsPartOfTheRequestIdentity() {
	global _LLM_Engine
	Profile := LLM_FindProfile("basic")
	Plain := _LLM_Engine_RequestSemanticSignature("basic", Profile)
	AssertEqual(Plain, _LLM_Engine_RequestSemanticSignature("basic", Profile, 0),
		"no override leaves the ordinary signature unchanged")
	Two := _LLM_Engine_RequestSemanticSignature("basic", Profile, 2)
	Four := _LLM_Engine_RequestSemanticSignature("basic", Profile, 4)
	AssertFalse(Two == Plain, "an override count changes the identity")
	AssertFalse(Two == Four, "two override counts differ")
	AssertThrows(() => _LLM_Engine_NormalizePromptOverride(Map("profile_id", "basic", "num_predictions", 11)),
		"an out-of-range count is a caller bug")
	AssertThrows(() => _LLM_Engine_NormalizePromptOverride(Map("num_predictions", 2)),
		"an override names a profile")
}
Test("LLM prompt prediction: the override count is part of the request identity",
	_LPP_CountIsPartOfTheRequestIdentity)





; ====================================================
; ====================================================
; ======= 4/ A correction erases what it names =======
; ====================================================
; ====================================================

; With the advanced prompt the model corrects the last words. The parser used
; to refuse every such correction on Windows (« Dropping a correction that
; needs N character(s) erased »), because only a rewrite recorded the text it
; erases: the maintainer's logs of 2026-10-01 show three in a row dropped, and
; no typo was ever fixed. A correction now names its erasure like a rewrite and
; goes through the same accept step (llm-correction-erases).
_LPP_CorrectionEndToEnd() {
	_LPP_Run(_LPP_Menu(), "Je vous envoit", _Body)
	_Body(Calls, Lines) {
		global _LLM_Engine
		LLM_Engine_FirePrediction("Je vous envoit", ,
			Map("profile_id", "advanced", "num_predictions", 1))
		AssertEqual(1, Calls.Length, "the request is dispatched")
		_LPP_Answer(Calls[1], "TAIL_CORRECTED: Je vous envoie`nNEXT_WORDS: ce mail")
		Final := _LPP_LastFinalRender()
		AssertTrue(IsObject(Final), "the correction must reach the tooltip")
		AssertEqual(1, Final.slots.Length, "as one slot")
		Slot := Final.slots[1]
		AssertTrue(IsObject(Slot) && Slot.HasOwnProp("Deletes"), "the slot carries its erasure")
		AssertEqual("e ce mail", Slot.Text, "it types what follows the erasure")
		AssertEqual(1, Slot.Deletes, "it erases the wrong letter")
		AssertEqual("t", Slot.DeletedText, "and names it")
		AssertEqual("Je vous envoit", Slot.RewriteSpan, "within the text it was asked about")
		Roles := ""
		for , Segment in _LLM_SlotSegments(Slot)
			Roles .= (Roles == "" ? "" : "|") . Segment.Role . ":" . Segment.Text
		AssertEqual("typed:envoi|corrected:e|next: ce mail", Roles,
			"the line reads the typed word, its correction, then the next words")
		AssertEqual("", _LLM_Engine["last_ctx"],
			"an erasing slot is never cached: the cache would replay its text without the erasure")
		AssertEqual(0, _LPP_LinesWith(Lines, "WARNING", "Dropping a correction"),
			"nothing is dropped")

		_LPP_WithKeyboard(_Accept)
		_Accept(Sent) {
			global _LLM_Bridge_Buffer
			Presented := LLM_Tooltip_GetAcceptSnapshot()
			AssertTrue(IsObject(Presented), "the final render must be acceptable")
			Transaction := _LPP_AcceptTransaction(Presented)
			AssertTrue(_LLM_Bridge_RewriteStillApplies(Transaction), "nothing was typed meanwhile")
			Results := []
			TextSend(Transaction.Text, _LLM_Bridge_InjectionOptions(Transaction),
				(Ok, ErrorMessage := "") => Results.Push(Ok))
			AssertEqual(1, Sent.Length, "the erasure and the text are one SendInput batch")
			AssertEqual("{Backspace 1}{Text}e ce mail", Sent[1],
				"the wrong letter is erased, then the correction and the next words typed")
			AssertEqual("Je vous envoie ce mail", _LLM_Bridge_Buffer,
				"the sentence comes out corrected, not appended to its typo")
		}
	}
}
Test("LLM prompt prediction: an advanced correction erases its typo and types the fix (llm-correction-erases)",
	_LPP_CorrectionEndToEnd)

; A correction whose typed text changed since it was generated erases nothing.
_LPP_StaleCorrectionIsNotApplied() {
	_LPP_Run(_LPP_Menu(), "Je vous envoit", _Body)
	_Body(Calls, Lines) {
		global _LLM_Bridge_Buffer
		LLM_Engine_FirePrediction("Je vous envoit", ,
			Map("profile_id", "advanced", "num_predictions", 1))
		_LPP_Answer(Calls[1], "TAIL_CORRECTED: Je vous envoie`nNEXT_WORDS: ce mail")
		Slot := _LPP_LastFinalRender().slots[1]
		_LLM_Bridge_Buffer := "Je vous envoit" . "x"
		_LPP_WithKeyboard(_Accept)
		_Accept(Sent) {
			Seed := Map("hwnd", 1, "control", 1, "physical_generation", 0,
				"content_generation", 0, "context_generation", 0)
			LLM_Bridge_OnAccept(Slot.Text, Seed, [Slot], 1)
			AssertEqual(0, Sent.Length, "nothing is erased or typed")
		}
	}
}
Test("LLM prompt prediction: a correction whose text changed is not applied (llm-correction-erases)",
	_LPP_StaleCorrectionIsNotApplied)

; A record that counts an erasure without naming it is still refused: typing it
; would append the fix to the typo.
_LPP_UnnamedErasureIsRefused() {
	AssertFalse(_LLM_Parser_IsPhysicallyInjectable(Map("deletes", 1, "to_type", "e ce mail")),
		"an erasure with no deleted_text and no span cannot be applied")
	AssertTrue(_LLM_Parser_IsPhysicallyInjectable(Map("deletes", 1, "to_type", "e ce mail",
		"deleted_text", "t", "span", "Je vous envoit")), "a named erasure can")
	AssertTrue(_LLM_Parser_IsPhysicallyInjectable(Map("deletes", 0, "to_type", "ce mail")),
		"a continuation erases nothing")
}
Test("LLM prompt prediction: an erasure that names nothing is refused (llm-correction-erases)",
	_LPP_UnnamedErasureIsRefused)

; A keystroke admitted after the rewrite was generated (the tooltip's minimum
; display window) moves the end of the buffer: the recorded count would erase
; the wrong characters, so the accept refuses and types nothing.
_LPP_StaleRewriteIsNotApplied() {
	_LPP_Run(_LPP_Menu(), LPP_SENTENCE, _Body)
	_Body(Calls, Lines) {
		global _LLM_Bridge_Buffer, LPP_SENTENCE
		Slot := _LLM_Engine_RewriteDisplaySlot("Ok pour jeudi 14 h.", Map(
			"deletes", StrLen(LPP_SENTENCE), "deleted_text", LPP_SENTENCE, "span", LPP_SENTENCE))
		_LLM_Bridge_Buffer := LPP_SENTENCE . "x"
		_LPP_WithKeyboard(_Accept)
		_Accept(Sent) {
			Seed := Map("hwnd", 1, "control", 1, "physical_generation", 0,
				"content_generation", 0, "context_generation", 0)
			LLM_Bridge_OnAccept(Slot.Text, Seed, [Slot], 1)
			AssertEqual(0, Sent.Length, "nothing is erased or typed")
			AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "Rewrite not applied"),
				"the refusal is logged")
		}
	}
}
Test("LLM prompt prediction: a rewrite whose sentence changed is not applied",
	_LPP_StaleRewriteIsNotApplied)

; Only an admission-guarded output may erase: a plain send has no proof that
; the focus is still the text the Backspaces were meant for.
_LPP_EraseRequiresAtomicOutput() {
	_LPP_WithKeyboard(_Body)
	_Body(Sent) {
		Results := []
		TextSend("abc", Map("mode", "direct", "erase_before", 2),
			(Ok, ErrorMessage := "") => Results.Push(Ok))
		AssertEqual(1, Results.Length, "the refusal completes the request")
		AssertFalse(Results[1], "erasing without admission is refused")
		TextSend("abc", Map("mode", "direct", "erase_before", -1),
			(Ok, ErrorMessage := "") => Results.Push(Ok))
		AssertFalse(Results[2], "a negative count is refused")
		AssertEqual(0, Sent.Length, "no key was sent")
	}
}
Test("LLM prompt prediction: only an atomic output may erase before its text",
	_LPP_EraseRequiresAtomicOutput)
