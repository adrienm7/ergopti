; static/ergopti_plus/windows/tests/unit/test_llm_translate.ahk

; ==============================================================================
; MODULE: Translating the Selection (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/llm/translate_vectors.json, which the shared Lua
; module (macOS, Linux) replays too, through modules/llm/translate.ahk: the
; binding parameter, the target language, the prompt, the user turn and the
; answer reading. Then drives llm_translate_selection through the real code
; path with only the outer boundaries faked: the selection reader, the menu's
; text transport, the accept source and the keyboard. Binding -> selection ->
; one request -> one tooltip candidate -> accept types it over the selection
; and selects it again.
;
; The selection fixture is test_llm_tone.ahk's (_LTN_Screen, _LTN_Run); the
; network, keyboard and log fixtures are test_llm_prompt_prediction.ahk's.
;
; ROOT CAUSE ENCODED:
; Translating a selected text meant copying it into a chat and pasting the
; answer back. The action translates it in place, on the user's acceptance.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================================
; ====================================================
; ======= 1/ Shared corpus (translate_vectors) =======
; ====================================================
; ====================================================

_LTR_Corpus() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\llm\translate_vectors.json"
	AssertTrue(FileExist(Path) != "", "the translation corpus must exist at " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

_LTR_ParseVectors() {
	Config := LLM_Translate_Config()
	Names := LLM_Translate_LocaleNames()
	Checked := 0
	for Vector in _LTR_Corpus()["parse_vectors"] {
		Valid := Vector["valid"] ? true : false
		Parsed := LLM_Translate_Parse(Vector["value"], Config, Names)
		AssertEqual(Valid, Parsed != "", Vector["id"] . ": parsed")
		if Valid
			AssertEqual(Vector["value"], Parsed, Vector["id"] . ": the value is the target")
		AssertEqual(Valid, LLM_Translate_IsValid(Vector["value"]), Vector["id"] . ": valid")
		Checked += 1
	}
	AssertTrue(Checked >= 8, "expected at least 8 parse vectors, found " . Checked)
	AssertFalse(LLM_Translate_IsValid(0), "a value that is not a string is refused")
}
Test("LLM translate: the binding parameter replays the shared corpus", _LTR_ParseVectors)

_LTR_TargetVectors() {
	Config := LLM_Translate_Config()
	Names := LLM_Translate_LocaleNames()
	Checked := 0
	for Vector in _LTR_Corpus()["target_vectors"] {
		Code := LLM_Translate_TargetLocale(LLM_Translate_Parse(Vector["value"], Config, Names), Config,
			Vector["ui_locale"])
		AssertEqual(Vector["locale"], Code, Vector["id"] . ": locale")
		AssertEqual(Vector["language"], LLM_Translate_LanguageName(Code, Names), Vector["id"] . ": language")
		Checked += 1
	}
	AssertTrue(Checked >= 3, "expected at least 3 target vectors, found " . Checked)
	AssertEqual("", LLM_Translate_LanguageName("xx", Names), "an unknown code has no name")
}
Test("LLM translate: the target language replays the shared corpus", _LTR_TargetVectors)

_LTR_PromptVectors() {
	Config := LLM_Translate_Config()
	Corpus := _LTR_Corpus()
	Checked := 0
	for Vector in Corpus["prompt_vectors"] {
		AssertEqual(Vector["prompt"], LLM_Translate_SystemPrompt(Config, Vector["language"]), Vector["id"])
		Checked += 1
	}
	AssertTrue(Checked >= 3, "expected at least 3 prompt vectors, found " . Checked)
	for Vector in Corpus["user_text_vectors"] {
		AssertEqual(Vector["user_text"], LLM_Translate_UserText(Config, Vector["text"]), Vector["id"])
		Checked += 1
	}
	AssertTrue(Checked >= 4, "the user text vectors are replayed too")
}
Test("LLM translate: the prompt and the user turn replay the shared corpus", _LTR_PromptVectors)

_LTR_ExtractVectors() {
	Config := LLM_Translate_Config()
	Checked := 0
	Missing := 0
	for Vector in _LTR_Corpus()["extract_vectors"] {
		; A vector without text expects no translation
		Expected := Vector.Get("text", "")
		Missing += (Expected == "") ? 1 : 0
		AssertEqual(Expected, LLM_Translate_Extract(Config, Vector["block"]), Vector["id"] . ": extracted text")
		Checked += 1
	}
	AssertTrue(Checked >= 5, "expected at least 5 extract vectors, found " . Checked)
	AssertTrue(Missing >= 2, "the vectors without a translation are replayed")
}
Test("LLM translate: reading the answer replays the shared corpus", _LTR_ExtractVectors)

_LTR_ChoicesFollowTheLanguageMenu() {
	Config := LLM_Translate_Config()
	Names := LLM_Translate_LocaleNames()
	Order := LLM_Translate_LocaleOrder()
	Choices := LLM_Translate_Choices(Names, Order, Config, "Interface")
	AssertEqual(Order["order"].Length + 1, Choices.Length, "the interface language, then every locale")
	AssertEqual(Config["ui_value"], Choices[1]["value"], "the interface language first")
	AssertEqual("Interface", Choices[1]["label"], "under the given label")
	for Index, Code in Order["order"] {
		AssertEqual(Code, Choices[Index + 1]["value"], "locales keep the menu order")
		AssertEqual(Names["locales"][Code]["flag"] . " " . Names["locales"][Code]["name"],
			Choices[Index + 1]["label"], Code . " is labelled by its flag and native name")
		AssertTrue(LLM_Translate_IsValid(Code), Code . " must be accepted")
	}
	Shipped := LLM_Translate_ShippedChoices()
	AssertEqual(22, Shipped.Length, "the shipped list: ui and the 21 locales")
	AssertEqual("ui", Shipped[1]["value"], "ui first")
	AssertEqual(StrReplace(t("llm.translate.ui_language"), "{1}", LLM_Translate_LanguageName(I18nGetLocale(), Names)),
		Shipped[1]["label"], "labelled with the interface language's native name")
}
Test("LLM translate: the choices are the interface language, then the language menu", _LTR_ChoicesFollowTheLanguageMenu)

_LTR_ShippedConfig() {
	Config := LLM_Translate_Config()
	AssertContains(Config["prompt"], "{language}", "the prompt names the target language")
	AssertContains(Config["prompt"], Config["tag"], "the prompt asks for the tag")
	AssertThrows(() => _LLM_Translate_ValidateConfig(Map("ui_value", "ui"), "translate.json"),
		"an incomplete configuration is refused")
	Broken := Map()
	for Key, Value in Config
		Broken[Key] := Value
	Broken["max_tokens"] := 0
	AssertThrows(() => _LLM_Translate_ValidateConfig(Broken, "translate.json"), "a zero budget is refused")
}
Test("LLM translate: translate.json holds what the action needs", _LTR_ShippedConfig)

_LTR_ParameterKind() {
	global GESTURE_ACTIONS
	AssertTrue(GESTURE_ACTIONS.Has("llm_translate_selection"), "the action is registered")
	AssertEqual("llm_language", GestureActionParameterSpec("llm_translate_selection"), "it takes llm_language")
	AssertTrue(GestureValidateActionParameter("llm_translate_selection", "ui"), "ui validates")
	AssertTrue(GestureValidateActionParameter("llm_translate_selection", "ja"), "a locale code validates")
	ErrorText := ""
	AssertFalse(GestureValidateActionParameter("llm_translate_selection", "French|2", &ErrorText),
		"reserved action syntax is refused")
	AssertEqual(t("dialog.gestures.param_err_llm_language"), ErrorText, "with the kind's refusal")
	AssertFalse(GestureValidateActionParameter("llm_translate_selection", " ja"), "a padded value is refused")
	Prompt := GestureActionParameterPrompt("llm_translate_selection")
	AssertFalse(InStr(Prompt, "{1}"), "the list is filled in")
	AssertEqual(StrReplace(t("dialog.gestures.param_llm_language"), "{1}",
		LLM_Translate_Config()["max_language_bytes"]), Prompt, "the bounded language InputBox")
	AssertTrue(GestureValidateActionParameter("llm_translate_selection", "Esperanto"), "free language is admitted")
}
Test("LLM translate: the llm_language parameter validates, lists and prompts", _LTR_ParameterKind)





; ================================================
; ================================================
; ======= 2/ Fixture: selection and locale =======
; ================================================
; ================================================

global LTR_SELECTION := "On se voit demain ?"
global LTR_TRANSLATION := "See you tomorrow?"

; Runs Body(Calls, Lines, Sent) with the tone fixture's fake selection, the
; interface locale, a fixed accept source and a fresh generation; everything
; is put back afterwards.
_LTR_Run(Menu, Screen, Locale, Body) {
	global _I18nLocale, _LLM_Translate_SourceProbe, _LLM_Translate_Generation
	Saved := {
		Locale: _I18nLocale, Probe: _LLM_Translate_SourceProbe, Generation: _LLM_Translate_Generation
	}
	try {
		_I18nLocale := Locale
		_LLM_Translate_SourceProbe := () => Map("hwnd", 7, "control", 9)
		_LTN_Run(Menu, Screen, Body)
	} finally {
		_I18nLocale := Saved.Locale
		_LLM_Translate_SourceProbe := Saved.Probe
		_LLM_Translate_Generation := Saved.Generation
	}
}

; Stores a binding's llm_language value and runs the action.
_LTR_Invoke(Value) {
	global GestureActionParameters
	Binding := "keyboard__translate_test"
	GestureActionParameters[GestureActionParameterKey(Binding, "llm_translate_selection")] := Value
	return GestureInvokeAction("llm_translate_selection", Binding)
}

; Asserts that a menu-backend request translates Text into Language.
_LTR_AssertRequest(Call, Language, Text) {
	Config := LLM_Translate_Config()
	AssertEqual(LLM_Translate_SystemPrompt(Config, Language), Call["system"],
		"the system prompt names " . Language)
	AssertEqual("TEXT:`n" . Text, Call["ctx"], "the user turn is the selection")
	AssertEqual("", Call["tail"], "without a TAIL")
	AssertEqual(Config["max_tokens"], Call["max_tokens"], "within the translation budget")
	Request := _LLMRemote_BuildRequestContext(Call["system"], Call["ctx"], Call["tail"])
	AssertEqual("TEXT:`n" . Text, Request["user"], "no PREFIX/TAIL wrapping reaches the wire")
}

; The acceptance transaction of the presented candidate, claimed like Tab claims it.
_LTR_AcceptTransaction(Presented) {
	Transaction := _LPP_AcceptTransaction(Presented)
	Transaction.PresentedRecord := Presented.Record
	Transaction.PresentedLifecycle := LLM_Tooltip_ClaimAcceptance(Presented.Record, Presented.Surface,
		Presented.ActiveIdx)
	AssertTrue(IsObject(Transaction.PresentedLifecycle), "the candidate is claimed")
	return Transaction
}





; =========================================================
; =========================================================
; ======= 3/ The selection, translated and replaced =======
; =========================================================
; =========================================================

_LTR_EndToEnd() {
	Screen := _LTN_Screen(LTR_SELECTION)
	_LTR_Run(_LPP_Menu(), Screen, "fr", _Body)
	_Body(Calls, Lines, Sent) {
		global _Stub_LlmTooltipCalls
		AssertTrue(_LTR_Invoke("ui"), "the action reads the selection")
		AssertEqual(1, Screen.Reads, "the selection is read once")
		AssertEqual(1, Calls.Length, "one request")
		_LTR_AssertRequest(Calls[1], "Français", LTR_SELECTION)
		AssertEqual(0, _Stub_LlmTooltipCalls.Length, "nothing is shown before the answer")

		_LPP_Answer(Calls[1], "TRANSLATION: " . LTR_TRANSLATION)
		AssertEqual(1, _Stub_LlmTooltipCalls.Length, "the translation is shown once")
		Final := _LPP_LastFinalRender()
		AssertTrue(IsObject(Final), "as a final offer")
		AssertEqual(1, Final.slots.Length, "one candidate")
		AssertEqual(LTR_TRANSLATION, Final.slots[1].Text, "the translation")
		AssertTrue(Final.slots[1].SelectAfterAccept, "which stays selected once accepted")
		AssertEqual(7, Final.meta["accept_source"]["hwnd"], "accepted in the focused window")
		AssertEqual(0, Sent.Length, "nothing is typed before the user accepts")
		AssertEqual(0, _LVS_LinesMentioning(Lines, "demain"), "the selection is never logged")
		AssertEqual(0, _LVS_LinesMentioning(Lines, "tomorrow"), "nor the translation")

		Presented := LLM_Tooltip_GetAcceptSnapshot()
		AssertTrue(IsObject(Presented), "the candidate is acceptable")
		Transaction := _LTR_AcceptTransaction(Presented)
		AssertEqual(0, Transaction.Deletes, "accepting erases nothing: typing replaces the selection")
		Results := []
		TextSend(Transaction.Text, _LLM_Bridge_InjectionOptions(Transaction),
			(Ok, ErrorMessage := "") => Results.Push(Ok))
		AssertTrue(Results.Length == 1 && Results[1], "the translation is typed")
		AssertEqual(1, Sent.Length, "typed alone first")
		; The success step of the bridge's completion (_LLM_Bridge_OnInjectComplete),
		; run without its deferred tooltip teardown, which this stub fixture has no need of
		AssertTrue(_LLM_Bridge_SelectAcceptedText(Transaction), "the completion selects it again")
		AssertEqual(2, Sent.Length, "the text, then the selection")
		AssertEqual("{Text}" . LTR_TRANSLATION, Sent[1], "typed over the selection, which it replaces")
		AssertEqual("+{Left " . StrLen(LTR_TRANSLATION) . "}", Sent[2], "then selected again, like a tone step")
	}
}
Test("LLM translate: the selection is translated, offered, and replaced on acceptance", _LTR_EndToEnd)

_LTR_FixedLanguage() {
	_LTR_Run(_LPP_Menu(), _LTN_Screen(LTR_SELECTION), "fr", _Body)
	_Body(Calls, Lines, Sent) {
		AssertTrue(_LTR_Invoke("ja"), "a fixed language runs")
		_LTR_AssertRequest(Calls[1], "日本語", LTR_SELECTION)
	}
}
Test("LLM translate: a fixed language ignores the interface language", _LTR_FixedLanguage)

_LTR_OrdinaryAcceptKeepsNoSelection() {
	; A prediction slot that did not replace a selection is not selected after it is typed
	Transaction := { Text: "abc", Slots: ["abc"], ActiveIdx: 1 }
	AssertFalse(_LLM_Bridge_SelectAcceptedText(Transaction), "a plain string slot")
	Transaction.Slots := [{ Text: "abc" }]
	AssertFalse(_LLM_Bridge_SelectAcceptedText(Transaction), "a slot without the flag")
}
Test("LLM translate: only a translation is selected again after acceptance", _LTR_OrdinaryAcceptKeepsNoSelection)





; ====================================================
; ====================================================
; ======= 4/ Dismissal, refusals, supersession =======
; ====================================================
; ====================================================

_LTR_EscapeLeavesTheText() {
	_LTR_Run(_LPP_Menu(), _LTN_Screen(LTR_SELECTION), "fr", _Body)
	_Body(Calls, Lines, Sent) {
		_LTR_Invoke("ui")
		_LPP_Answer(Calls[1], "TRANSLATION: " . LTR_TRANSLATION)
		AssertTrue(LLM_Tooltip_IsVisible(), "the translation is offered")
		LLM_Tooltip_Hide()
		AssertFalse(IsObject(LLM_Tooltip_GetAcceptSnapshot()), "a dismissed offer cannot be accepted")
		AssertEqual(0, Sent.Length, "and nothing was typed")
	}
}
Test("LLM translate: dismissing the offer leaves the text untouched", _LTR_EscapeLeavesTheText)

_LTR_EmptySelection() {
	Screen := _LTN_Screen("  `n")
	_LTR_Run(_LPP_Menu(), Screen, "fr", _Body)
	_Body(Calls, Lines, Sent) {
		AssertTrue(_LTR_Invoke("ui"), "the selection is read")
		AssertEqual(1, Screen.Reads, "once")
		AssertEqual(0, Calls.Length, "a blank selection sends nothing")
		AssertEqual(t("llm.translate.no_selection"), _LPP_PendingNotice(), "the user is told to select")
	}
}
Test("LLM translate: nothing selected, a notice and no request", _LTR_EmptySelection)

_LTR_AiOffIsRefused() {
	Screen := _LTN_Screen(LTR_SELECTION)
	_LTR_Run(_LPP_Menu(false), Screen, "fr", _Body)
	_Body(Calls, Lines, Sent) {
		AssertFalse(_LTR_Invoke("ui"), "an AI switched off")
		AssertEqual(0, Screen.Reads, "reads no selection")
		AssertEqual(0, Calls.Length, "and sends nothing")
		AssertEqual(t("llm.manual_prediction.disabled"), _LPP_PendingNotice(),
			"with the notice llm_generate_prediction shows")
	}
}
Test("LLM translate: the manual-prediction refusals come first", _LTR_AiOffIsRefused)

_LTR_InvalidParameter() {
	Screen := _LTN_Screen(LTR_SELECTION)
	_LTR_Run(_LPP_Menu(), Screen, "fr", _Body)
	_Body(Calls, Lines, Sent) {
		AssertFalse(_LTR_Invoke("Klingon|2"), "an invalid stored value")
		AssertEqual(0, Screen.Reads, "reads nothing")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "binding's language"), "and is logged")
	}
}
Test("LLM translate: an invalid stored language does nothing", _LTR_InvalidParameter)

_LTR_MissingTagFails() {
	_LTR_Run(_LPP_Menu(), _LTN_Screen(LTR_SELECTION), "fr", _Body)
	_Body(Calls, Lines, Sent) {
		global _Stub_LlmTooltipCalls
		_LTR_Invoke("ui")
		_LPP_Answer(Calls[1], LTR_TRANSLATION)
		AssertEqual(0, _Stub_LlmTooltipCalls.Length, "an answer without the tag is not offered")
		AssertEqual(t("llm.translate.failed"), _LPP_PendingNotice(), "the user is told")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "holds no translation"), "and it is logged")

		TooltipHide("TranslateTest", true)
		_LTR_Invoke("ui")
		Calls[2]["on_fail"].Call(_LLMRemote_FailInfo("timeout"))
		AssertEqual(t("llm.translate.failed"), _LPP_PendingNotice(), "a failed request is reported")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "timeout"), "with its reason")
	}
}
Test("LLM translate: an answer without a translation or a failed request is reported", _LTR_MissingTagFails)

_LTR_NewTriggerSupersedes() {
	_LTR_Run(_LPP_Menu(), _LTN_Screen(LTR_SELECTION), "fr", _Body)
	_Body(Calls, Lines, Sent) {
		global _Stub_LlmTooltipCalls, _LLM_Translate_Generation
		_LTR_Invoke("ui")
		_LTR_Invoke("ja")
		AssertEqual(2, Calls.Length, "both selections are sent")
		_LPP_Answer(Calls[1], "TRANSLATION: Trop tard")
		AssertEqual(0, _Stub_LlmTooltipCalls.Length, "the superseded answer is not shown")
		AssertEqual(1, _LPP_LinesWith(Lines, "INFO", "newer translation superseded"), "its drop is logged")
		AssertFalse(_LLM_Translate_RenderIsCurrent(_LLM_Translate_Generation - 1),
			"an older translation can no longer paint")
		_LPP_Answer(Calls[2], "TRANSLATION: 明日会いましょう")
		Final := _LPP_LastFinalRender()
		AssertTrue(IsObject(Final), "the newest answer is shown")
		AssertEqual("明日会いましょう", Final.slots[1].Text, "alone")
	}
}
Test("LLM translate: a new trigger supersedes the translation in progress", _LTR_NewTriggerSupersedes)


/** Exercises free language admission and the exact request-local override owner. */
_LTR_FreeLanguageReceipt() {
	Config := LLM_Translate_Config()
	Names := LLM_Translate_LocaleNames()
	AssertEqual("Esperanto", LLM_Translate_Parse("Esperanto", Config, Names))
	AssertEqual("Esperanto", LLM_Translate_ResolveLanguage("Esperanto", Config, Names, "fr"))
	AssertEqual("", LLM_Translate_ResolveLanguage("ui", Config, Names, "missing"))
	AssertEqual("", LLM_Translate_Parse("English|2", Config, Names))
	Parsed := LLM_PromptAction_Parse("translate|2|ქართული")
	AssertTrue(Parsed is Map)
	AssertEqual("ქართული", Parsed["translation_target"])
	Checked := _LLM_Engine_NormalizePromptOverride(Parsed)
	Parsed["translation_target"] := "Esperanto"
	AssertEqual("ქართული", Checked["translation_target"], "request receipt is detached")
	Profile := LLM_Translate_PredictionProfile(Checked["translation_target"])
	AssertTrue(Profile is Map)
	AssertTrue(InStr(Profile["system_single"], "Translate TAIL into ქართული", true) > 0)
	AssertTrue(LLM_Rewrite_IsRewriteProfile(Profile))
	AssertEqual("translate", _LLM_Engine_NormalizePromptOverride(Map("profile_id", "translate"))["profile_id"],
		"a bare legacy/custom id remains ordinary")
	AssertThrows(() => _LLM_Engine_NormalizePromptOverride(Map("profile_id", "TRANSLATE", "translation_target", "Esperanto")), ValueError)
}
Test("LLM translate: free-language request receipt is detached and fail-closed", _LTR_FreeLanguageReceipt)


_LTR_FreeLanguageSelection() {
	Screen := _LTN_Screen(LTR_SELECTION)
	_LTR_Run(_LPP_Menu(), Screen, "fr", _Body)
	_Body(Calls, Lines, Sent) {
		AssertTrue(_LTR_Invoke("Klingon"), "an admitted free-language binding")
		AssertEqual(1, Screen.Reads, "the real selection owner reads once")
		AssertEqual(1, Calls.Length, "the existing text transport receives one request")
		_LTR_AssertRequest(Calls[1], "Klingon", LTR_SELECTION)
		AssertEqual(0, Sent.Length, "nothing is published before actual acceptance")
	}
}
Test("LLM translate: a free-language selection uses the existing admitted request", _LTR_FreeLanguageSelection)

_LTR_TypedReceiptBounds() {
	Value := ""
	Loop LLM_Translate_Config()["max_language_bytes"]
		Value .= "a"
	AssertTrue(GestureValidateActionParameter("llm_prompt_prediction", "translate|1|" . Value))
	AssertFalse(GestureValidateActionParameter("llm_prompt_prediction", "translate|1|" . Value . "a"))
	AssertFalse(LLM_PromptAction_Parse("TRANSLATE|1|Esperanto") is Map)
	AssertTrue(LLM_PromptAction_Parse("translate") is Map, "bare profile lookup is unchanged")
}
Test("LLM translate: typed target admission enforces the shared bound and exact discriminator", _LTR_TypedReceiptBounds)
