; static/ergopti_plus/windows/tests/unit/test_llm_vision.ahk

; ==============================================================================
; MODULE: Answering What Is on the Screen (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/llm/vision_vectors.json, which the shared Lua
; module (macOS, Linux) replays too, through modules/llm/vision.ahk, comparing
; every request body as decoded JSON. Then drives llm_screen_region and
; llm_screen_full through the real code path with only the outer boundaries
; faked: the capture (a private PNG the fake writes), the vision transport
; (answered with an OpenAI-dialect body the real classifier reads), the menu's
; text transport, the focus probe and the keyboard. Binding -> capture ->
; vision request (address, key, image) -> transcription -> three answer
; requests -> tooltip candidates in order -> accept types one at the caret.
;
; The network, keyboard and log fixtures are those of
; test_llm_prompt_prediction.ahk (_LPP_Run, _LPP_WithKeyboard, _LPP_Answer).
;
; ROOT CAUSE ENCODED:
; No request could carry an image, so answering a message on the screen meant
; retyping it into a chat. The screen actions read the screen with a vision
; model and offer the replies where the user types.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================================
; =================================================
; ======= 1/ Shared corpus (vision_vectors) =======
; =================================================
; =================================================

_LVS_Corpus() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\llm\vision_vectors.json"
	AssertTrue(FileExist(Path) != "", "the vision corpus must exist at " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

; Compares two decoded JSON values structurally.
; @returns {String} "" when equal, else where they differ.
_LVS_DeepEqual(A, B, Where := "$") {
	if (A is Map) {
		if !(B is Map)
			return Where . ": object vs " . Type(B)
		if (A.Count != B.Count)
			return Where . ": " . A.Count . " vs " . B.Count . " keys"
		for Key, Value in A {
			if !B.Has(Key)
				return Where . "." . Key . " is missing"
			Why := _LVS_DeepEqual(Value, B[Key], Where . "." . Key)
			if (Why != "")
				return Why
		}
		return ""
	}
	if (A is Array) {
		if !(B is Array)
			return Where . ": array vs " . Type(B)
		if (A.Length != B.Length)
			return Where . ": " . A.Length . " vs " . B.Length . " items"
		for Index, Value in A {
			Why := _LVS_DeepEqual(Value, B[Index], Where . "[" . Index . "]")
			if (Why != "")
				return Why
		}
		return ""
	}
	if (B is Map || B is Array)
		return Where . ": " . Type(A) . " vs " . Type(B)
	if (Type(A) != Type(B))
		return Where . ": " . Type(A) . " vs " . Type(B)
	return (A == B) ? "" : Where . ": <" . String(A) . "> vs <" . String(B) . ">"
}

_LVS_DeepEqualCanFail() {
	AssertEqual("", _LVS_DeepEqual(JsonParse('{"a":[1,{"b":"x"}]}'), JsonParse('{"a":[1,{"b":"x"}]}')),
		"equal documents compare equal")
	AssertTrue(_LVS_DeepEqual(JsonParse('{"a":[1]}'), JsonParse('{"a":[2]}')) != "", "a value differs")
	AssertTrue(_LVS_DeepEqual(JsonParse('{"a":1}'), JsonParse('{"a":1,"b":1}')) != "", "a key is missing")
	AssertTrue(_LVS_DeepEqual(JsonParse('{"a":"X"}'), JsonParse('{"a":"x"}')) != "", "the case of a string counts")
	AssertTrue(_LVS_DeepEqual(JsonParse('{"a":"1"}'), JsonParse('{"a":1}')) != "", "a string is not a number")
}
Test("LLM vision: the structural comparison can fail", _LVS_DeepEqualCanFail)

_LVS_ParseVectors() {
	Checked := 0
	for Vector in _LVS_Corpus()["parse_vectors"] {
		Parsed := LLM_Vision_Parse(Vector["value"], &Reason)
		if (Vector.Get("valid", true) == false) {
			AssertEqual("", Parsed, Vector["id"] . ": refused")
			AssertTrue(Reason != "", Vector["id"] . ": with a reason")
			AssertFalse(LLM_Vision_IsValid(Vector["value"]), Vector["id"] . ": invalid")
		} else {
			AssertTrue(Parsed is Map, Vector["id"] . ": must parse")
			AssertEqual(Vector["backend"], Parsed["backend"], Vector["id"] . ": backend")
			AssertEqual(Vector.Get("model", "<none>"), Parsed.Get("model", "<none>"), Vector["id"] . ": model")
			AssertTrue(LLM_Vision_IsValid(Vector["value"]), Vector["id"] . ": valid")
		}
		Checked += 1
	}
	AssertTrue(Checked >= 13, "expected at least 13 parse vectors, found " . Checked)
}
Test("LLM vision: the binding parameter replays the shared corpus", _LVS_ParseVectors)

_LVS_ModelVectors() {
	Config := LLM_Vision_Config()
	Checked := 0
	for Vector in _LVS_Corpus()["model_vectors"] {
		AssertEqual(Vector.Get("model", ""), LLM_Vision_ResolveModel(LLM_Vision_Parse(Vector["value"]), Config),
			Vector["id"] . ": model")
		Checked += 1
	}
	AssertTrue(Checked >= 5, "expected at least 5 model vectors, found " . Checked)
}
Test("LLM vision: the vision model replays the shared corpus", _LVS_ModelVectors)

_LVS_RequestVectors() {
	Checked := 0
	Formats := Map()
	for Vector in _LVS_Corpus()["request_vectors"] {
		Body := LLM_Vision_BuildRequest(Vector["format"], Vector["spec"])
		AssertEqual("", _LVS_DeepEqual(Vector["body"], JsonParse(Body)), Vector["id"] . ": body")
		; The decoder reads false as 0: the wire text must say false
		if (Vector["format"] == "openai" || Vector["format"] == "ollama")
			AssertContains(Body, '"stream":false', Vector["id"] . ": streaming is off")
		Formats[Vector["format"]] := true
		Checked += 1
	}
	AssertTrue(Checked >= 8, "expected at least 8 request vectors, found " . Checked)
	AssertEqual(4, Formats.Count, "every dialect is replayed")
}
Test("LLM vision: every request dialect replays the shared corpus", _LVS_RequestVectors)

_LVS_ExtractVectors() {
	Checked := 0
	for Vector in _LVS_Corpus()["extract_vectors"] {
		AssertEqual(Vector.Get("text", ""), LLM_Vision_Extract(Vector["block"], Vector["tag"]),
			Vector["id"] . ": extracted text")
		Checked += 1
	}
	AssertTrue(Checked >= 6, "expected at least 6 extract vectors, found " . Checked)
}
Test("LLM vision: reading a tagged answer replays the shared corpus", _LVS_ExtractVectors)

_LVS_RequestRefusals() {
	Spec := Map("model", "m", "system", "S", "text", "T", "max_tokens", 10)
	AssertThrows(() => LLM_Vision_BuildRequest("xml", Spec), "an unknown dialect is a caller bug")
	Spec["image"] := "QUJD"
	AssertThrows(() => LLM_Vision_BuildRequest("openai", Spec), "an image needs its mime type")
	Spec["mime"] := "image/png"
	Spec["image"] := ""
	AssertThrows(() => LLM_Vision_BuildRequest("gemini", Spec), "an image needs data")
	AssertEqual("SCREEN:`nhi", LLM_Vision_AnswerUserText("hi"), "the answer's user turn")
	AssertEqual("Say it in fr, fr.", LLM_Vision_FillLanguage("Say it in {language}, {language}.", "fr"),
		"every {language} is filled")
}
Test("LLM vision: malformed requests are refused", _LVS_RequestRefusals)

_LVS_ShippedConfig() {
	global LLM_VISION_LOCAL_BACKEND
	Config := LLM_Vision_Config()
	AssertContains(Config["read_prompt"], Config["screen_tag"], "the reading prompt asks for the screen tag")
	AssertEqual(3, Config["answers"].Length, "reply, translate, explain")
	for Answer in Config["answers"]
		AssertContains(Answer["prompt"], Config["answer_tag"], Answer["id"] . " asks for the answer tag")
	AssertTrue(Config["default_models"].Has(LLM_VISION_LOCAL_BACKEND), "a local default model")
	AssertThrows(() => _LLM_Vision_ValidateConfig(Map("screen_tag", "S:"), "vision.json"),
		"an incomplete configuration is refused")
	; "Why this error?": the explanation first, in the interface language, then the fix
	AssertEqual(2, Config["error_answers"].Length, "cause, then fix")
	AssertEqual("cause", Config["error_answers"][1]["id"], "the explanation comes first")
	AssertEqual("fix", Config["error_answers"][2]["id"], "the fix second")
	AssertContains(Config["error_answers"][1]["prompt"], "{language}", "the explanation is in the interface language")
	for Answer in Config["error_answers"]
		AssertContains(Answer["prompt"], Config["answer_tag"], Answer["id"] . " asks for the answer tag")
	Broken := Map()
	for Key, Value in Config
		Broken[Key] := Value
	Broken.Delete("error_answers")
	AssertThrows(() => _LLM_Vision_ValidateConfig(Broken, "vision.json"),
		"a configuration without the error answers is refused")
}
Test("LLM vision: vision.json holds what the screen actions need", _LVS_ShippedConfig)

_LVS_Base64OfAFile() {
	Path := A_Temp . "\ergopti_test_vision_" . A_TickCount . ".bin"
	File := FileOpen(Path, "w", "UTF-8-RAW")
	File.Write("ABC")
	File.Close()
	try AssertEqual("QUJD", _LLM_Vision_Base64File(Path), "the file is encoded without line breaks")
	finally FileDelete(Path)
}
Test("LLM vision: a screenshot file is sent as base64", _LVS_Base64OfAFile)

_LVS_DownscaleScript() {
	AssertEqual("", _GestureScreenshotDownscaleScript("$bmp", 0), "no limit, no resize")
	Script := _GestureScreenshotDownscaleScript("$bmp", 1568)
	AssertContains(Script, "-gt 1568", "only a larger image is shrunk")
	AssertContains(Script, "HighQualityBicubic", "with GDI+ resampling")
	AssertContains(Script, "$bmp = $dsImg", "and replaces the captured bitmap")
	Direct := _GestureScreenshotDirectScript(0, 0, 3000, 2000, "save", "C:\t.png", 1568)
	AssertTrue(InStr(Direct, Script) > 0 && InStr(Direct, Script) < InStr(Direct, "$bmp.Save("),
		"the full-screen capture shrinks before saving")
	Region := _GestureScreenshotRegionSaveScript("C:\t.png", 1568)
	AssertTrue(InStr(Region, _GestureScreenshotDownscaleScript("$img", 1568)) > 0,
		"the region capture shrinks the selection before saving")
	AssertThrows(() => _GestureScreenshotDownscaleScript("$bmp", -1), "a negative edge is a caller bug")
}
Test("LLM vision: the capture scripts shrink the image to the longest edge", _LVS_DownscaleScript)

_LVS_ParameterKind() {
	global LLM_API_PROVIDER_ORDER, LLM_API_PROVIDERS
	AssertTrue(GestureValidateActionParameter("llm_screen_region", "openai|gpt-4.1-mini"),
		"a provider and a model validate")
	AssertTrue(GestureValidateActionParameter("llm_screen_full", "cerebras"),
		"a provider without a default still validates: the model is checked at run time")
	ErrorText := ""
	AssertFalse(GestureValidateActionParameter("llm_screen_full", "OpenAI", &ErrorText), "the syntax is checked")
	AssertEqual(t("dialog.gestures.param_err_llm_vision"), ErrorText, "with the kind's refusal")
	Choices := LLM_Vision_BackendChoices()
	AssertEqual("local", Choices[1]["value"], "the local server comes first")
	AssertEqual(t("llm.vision.local_backend"), Choices[1]["label"], "under its localized label")
	AssertEqual(LLM_Vision_Config()["default_models"]["local"], Choices[1]["defaultModel"],
		"with its default model")
	; Backboard's messages carry text only and a decisions provider answers
	; typed questions only: neither can read the screenshot
	Readers := []
	for ProviderId in LLM_API_PROVIDER_ORDER {
		if LLM_RemoteFormatServes(LLM_API_PROVIDERS[ProviderId]["Format"], "images")
			Readers.Push(ProviderId)
	}
	AssertTrue(Readers.Length < LLM_API_PROVIDER_ORDER.Length, "some providers cannot read an image")
	AssertEqual(Readers.Length + 1, Choices.Length, "then every provider that reads an image")
	for Index, ProviderId in Readers {
		AssertEqual(ProviderId, Choices[Index + 1]["value"], "providers keep their order")
		AssertEqual(LLM_API_PROVIDERS[ProviderId]["Label"], Choices[Index + 1]["label"], ProviderId . " label")
	}
	for Choice in Choices
		AssertFalse(Choice["value"] == "backboard" || LLM_RemoteProviderFormat(Choice["value"]) == "decisions",
			Choice["value"] . " is no vision backend")
	AssertFalse(InStr(GestureActionParameterPrompt("llm_screen_region"), "typesafe"),
		"the prompt does not list a decisions provider")
	Prompt := GestureActionParameterPrompt("llm_screen_region")
	AssertContains(Prompt, "local — " . t("llm.vision.local_backend") . "`n", "the prompt lists the local server")
	AssertContains(Prompt, "openai — " . LLM_API_PROVIDERS["openai"]["Label"], "and the providers")
}
Test("LLM vision: the llm_vision parameter validates, lists and prompts", _LVS_ParameterKind)

_LVS_ActionsAreRegistered() {
	global GESTURE_ACTIONS
	for ActionId, Kind in LLM_VisionActions() {
		AssertTrue(GESTURE_ACTIONS.Has(ActionId), ActionId . " must be a gesture action")
		AssertEqual("llm_vision", GestureActionParameterSpec(ActionId), ActionId . " takes llm_vision")
	}
	AssertEqual(3, LLM_VisionActions().Count, "three screen actions")
	AssertEqual("region", LLM_VisionActions()["llm_screen_region"], "the region action draws a region")
	AssertEqual("full", LLM_VisionActions()["llm_screen_full"], "the full action takes the whole screen")
	AssertEqual("region", LLM_VisionActions()["llm_screen_error"], "the error action draws a region")
	AssertEqual("answers", LLM_Vision_AnswersKey("llm_screen_region"), "the region action replies")
	AssertEqual("answers", LLM_Vision_AnswersKey("llm_screen_full"), "so does the full one")
	AssertEqual("error_answers", LLM_Vision_AnswersKey("llm_screen_error"), "the error action explains and fixes")
	AssertThrows(() => LLM_Vision_AnswersKey("llm_screen_nope"), "an unknown action is a caller bug")
	AssertThrows(() => LLM_Vision_Trigger("region", "openai", "nope"), "so is an unknown answer list")
}
Test("LLM vision: the three screen actions are registered", _LVS_ActionsAreRegistered)





; ==================================================
; ==================================================
; ======= 2/ Fixture: capture, vision, focus =======
; ==================================================
; ==================================================

global LVS_SCREEN := "Salut, on se voit demain à 14h ?"

; Records a capture; the scenario completes it with _LVS_Complete.
_LVS_FakeCapture(Fx, Kind, Path, MaxEdge, OnDone) {
	Fx.Captures.Push({ Kind: Kind, Path: Path, MaxEdge: MaxEdge, OnDone: OnDone })
}

; Ends a recorded capture: a saved screenshot ("ABC", QUJD in base64) or a failure.
_LVS_Complete(Capture, Ok, Reason := "saved") {
	if Ok {
		File := FileOpen(Capture.Path, "w", "UTF-8-RAW")
		File.Write("ABC")
		File.Close()
	}
	Capture.OnDone.Call(Ok, Reason)
}

_LVS_RecordRemote(Fx, Resolved, Url, Body, OnSuccess, OnFail) {
	Fx.Vision.Push(Map("resolved", Resolved, "url", Url, "body", Body,
		"on_success", OnSuccess, "on_fail", OnFail))
}

_LVS_RecordOllama(Fx, Body, OnSuccess, OnFail) {
	Fx.Ollama.Push(Map("body", Body, "on_success", OnSuccess, "on_fail", OnFail))
}

; Runs Body(Calls, Lines, Sent, Fx) with the prompt-prediction fixture, a fake
; capture, fake vision transports and a fixed focused control; everything is put
; back afterwards. Calls are the menu backend's requests (_LPP_RecordTransport).
_LVS_Run(Menu, Body) {
	global _LLM_Vision_CaptureFn, _LLM_Vision_RemoteTransport, _LLM_Vision_OllamaTransport
	global _LLM_Vision_SourceProbe, _LLM_Vision_Generation
	Saved := {
		Capture: _LLM_Vision_CaptureFn, Remote: _LLM_Vision_RemoteTransport,
		Ollama: _LLM_Vision_OllamaTransport, Probe: _LLM_Vision_SourceProbe,
		Generation: _LLM_Vision_Generation
	}
	Fx := { Captures: [], Vision: [], Ollama: [] }
	try {
		_LLM_Vision_CaptureFn := _LVS_FakeCapture.Bind(Fx)
		_LLM_Vision_RemoteTransport := _LVS_RecordRemote.Bind(Fx)
		_LLM_Vision_OllamaTransport := _LVS_RecordOllama.Bind(Fx)
		_LLM_Vision_SourceProbe := () => Map("hwnd", 7, "control", 9)
		_LPP_Run(Menu, "", _WithNetwork)
	} finally {
		for Capture in Fx.Captures
			try FileDelete(Capture.Path)
		_LLM_Vision_CaptureFn := Saved.Capture
		_LLM_Vision_RemoteTransport := Saved.Remote
		_LLM_Vision_OllamaTransport := Saved.Ollama
		_LLM_Vision_SourceProbe := Saved.Probe
		_LLM_Vision_Generation := Saved.Generation
	}
	_WithNetwork(Calls, Lines) {
		_LPP_WithKeyboard(_WithKeyboard)
		_WithKeyboard(Sent) {
			Body.Call(Calls, Lines, Sent, Fx)
		}
	}
}

; Stores a binding's llm_vision value and runs its action.
_LVS_Invoke(ActionId, Value) {
	global GestureActionParameters
	Binding := "keyboard__vision_test"
	GestureActionParameters[GestureActionParameterKey(Binding, ActionId)] := Value
	return GestureInvokeAction(ActionId, Binding)
}

; Asserts that a menu-backend request asks for the answer at Index of a list.
_LVS_AssertAnswerRequest(Call, Index, ListKey := "answers") {
	Config := LLM_Vision_Config()
	AssertEqual(LLM_Vision_FillLanguage(Config[ListKey][Index]["prompt"], "fr"), Call["system"],
		"answer " . Index . " runs its own prompt in the interface language")
	AssertEqual("SCREEN:`n" . LVS_SCREEN, Call["ctx"], "the user turn is the transcription")
	AssertEqual("", Call["tail"], "without a TAIL")
	AssertEqual(Config["answer_max_tokens"], Call["max_tokens"], "within the answer budget")
	Request := _LLMRemote_BuildRequestContext(Call["system"], Call["ctx"], Call["tail"])
	AssertEqual("SCREEN:`n" . LVS_SCREEN, Request["user"], "no PREFIX/TAIL wrapping reaches the wire")
}

; @returns {Integer} How many captured lines mention Needle, at any level.
_LVS_LinesMentioning(Lines, Needle) {
	Count := 0
	for Line in Lines
		if InStr(Line, Needle, true)
			Count += 1
	return Count
}





; ===================================================
; ===================================================
; ======= 3/ The screen, end to end, answered =======
; ===================================================
; ===================================================

_LVS_RegionEndToEnd() {
	_LVS_Run(_LPP_Menu(), _Body)
	_Body(Calls, Lines, Sent, Fx) {
		global _Stub_LlmTooltipCalls, LLM_VISION_READ_USER_TEXT
		Config := LLM_Vision_Config()
		AssertTrue(_LVS_Invoke("llm_screen_region", "openai|gpt-4.1-mini"), "the capture starts")
		AssertEqual(1, Fx.Captures.Length, "one capture")
		Capture := Fx.Captures[1]
		AssertEqual("region", Capture.Kind, "the user draws a region")
		AssertEqual(Config["max_image_edge"], Capture.MaxEdge, "shrunk to the configured edge")
		AssertEqual(0, Fx.Vision.Length, "nothing is sent before the capture ends")

		_LVS_Complete(Capture, true)
		AssertFalse(FileExist(Capture.Path), "the screenshot is deleted once read")
		AssertEqual(1, Fx.Vision.Length, "one vision request")
		Vision := Fx.Vision[1]
		AssertEqual("https://example.invalid/v1/chat/completions", Vision["url"],
			"the provider's chat endpoint, at the entry's address")
		AssertEqual("gpt-4.1-mini", Vision["resolved"]["Model"], "the binding's model")
		AssertContains(_LLMRemote_BuildCurlConfig(Vision["resolved"]["Format"], Vision["resolved"]["Token"],
			Vision["url"]), "Authorization: Bearer secret", "with the entry's key as a bearer token")
		Expected := JsonParse(LLM_Vision_BuildRequest("openai", Map(
			"model", "gpt-4.1-mini", "system", Config["read_prompt"], "text", LLM_VISION_READ_USER_TEXT,
			"image", "QUJD", "mime", Config["image_mime"], "max_tokens", Config["read_max_tokens"])))
		AssertEqual("", _LVS_DeepEqual(Expected, JsonParse(Vision["body"])), "the body carries the image")
		AssertContains(Vision["body"], '"url":"data:image/png;base64,QUJD"', "as a data URL")
		AssertEqual(0, Calls.Length, "no answer is asked before the screen is read")

		_LPP_Answer(Vision, "SCREEN: " . LVS_SCREEN)
		Answers := ["Oui, à demain 14h !`nBonne soirée", "Hi, see you tomorrow at 2 pm?", "Marc propose un rendez-vous."]
		loop 3 {
			AssertEqual(A_Index, Calls.Length, "the answers are asked one after the other")
			_LVS_AssertAnswerRequest(Calls[A_Index], A_Index)
			_LPP_Answer(Calls[A_Index], "ANSWER: " . Answers[A_Index])
		}
		AssertEqual(3, Calls.Length, "three answers, no more")
		First := _Stub_LlmTooltipCalls[1]
		AssertFalse(First.is_final, "the first answer is shown as soon as it arrives")
		AssertEqual(1, First.slots.Length, "alone")
		Final := _LPP_LastFinalRender()
		AssertTrue(IsObject(Final), "the answers reach the tooltip")
		AssertEqual(3, Final.slots.Length, "three candidates")
		loop 3
			AssertEqual(Answers[A_Index], Final.slots[A_Index], "candidate " . A_Index . " in answer order")
		AssertEqual(7, Final.meta["accept_source"]["hwnd"], "accepted in the focused window")
		AssertEqual(9, Final.meta["accept_source"]["control"], "and control")
		AssertEqual(0, _LVS_LinesMentioning(Lines, "Salut"), "the screen's text is never logged")
		AssertEqual(0, _LVS_LinesMentioning(Lines, "QUJD"), "nor the image")
		AssertEqual(0, _LVS_LinesMentioning(Lines, "[ERROR]"), "nothing failed")

		Presented := LLM_Tooltip_GetAcceptSnapshot()
		AssertTrue(IsObject(Presented), "the final candidates are acceptable")
		Transaction := _LPP_AcceptTransaction(Presented)
		AssertEqual(0, Transaction.Deletes, "accepting erases nothing")
		Results := []
		TextSend(Transaction.Text, _LLM_Bridge_InjectionOptions(Transaction),
			(Ok, ErrorMessage := "") => Results.Push(Ok))
		AssertEqual(1, Sent.Length, "one output")
		AssertEqual("{Text}" . Answers[1], Sent[1], "the first answer, both lines, typed at the caret")
		AssertTrue(Results.Length == 1 && Results[1], "and reported as typed")
	}
}
Test("LLM vision: a region is read, answered three ways and one answer typed", _LVS_RegionEndToEnd)

_LVS_LocalBackendEndToEnd() {
	_LVS_Run(_LPP_Menu(), _Body)
	_Body(Calls, Lines, Sent, Fx) {
		global _LLM_Engine
		Config := LLM_Vision_Config()
		AssertTrue(_LVS_Invoke("llm_screen_full", "local"), "the capture starts")
		AssertEqual("full", Fx.Captures[1].Kind, "the whole screen, no selection")
		_LVS_Complete(Fx.Captures[1], true)
		AssertEqual(0, Fx.Vision.Length, "no provider is asked")
		AssertEqual(1, Fx.Ollama.Length, "the local server reads the screen")
		Body := JsonParse(Fx.Ollama[1]["body"])
		AssertEqual(Config["default_models"]["local"], Body["model"], "with the default local model")
		AssertEqual("QUJD", Body["messages"][2]["images"][1], "the image rides with the user turn")

		; The answers follow the menu's backend: the local server this time.
		_LLM_Engine["backend"] := "ollama"
		_LLM_Engine["model"] := "local-a"
		Fx.Ollama[1]["on_success"].Call("SCREEN: " . LVS_SCREEN)
		AssertEqual(0, Calls.Length, "no remote answer request")
		AssertEqual(2, Fx.Ollama.Length, "the first answer is asked locally")
		Answer := JsonParse(Fx.Ollama[2]["body"])
		AssertEqual(LLM_ResolveOllamaTag(_LLM_Engine["model"]), Answer["model"], "on the menu's model")
		AssertEqual("SCREEN:`n" . LVS_SCREEN, Answer["messages"][2]["content"], "about the transcription")
		AssertFalse(Answer["messages"][2].Has("images"), "without the image")
		AssertFalse(Answer.Has("options") && Answer["options"].Has("stop"), "and no line stop")
		Fx.Ollama[2]["on_success"].Call("ANSWER: Oui !")
		Fx.Ollama[3]["on_fail"].Call()
		Fx.Ollama[4]["on_success"].Call("No tag here")
		Final := _LPP_LastFinalRender()
		AssertTrue(IsObject(Final), "the answer that came is offered")
		AssertEqual(1, Final.slots.Length, "a failed or untagged answer is skipped")
		AssertEqual("Oui !", Final.slots[1], "the good one stays")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "holds no text"), "the untagged answer is logged")
	}
}
Test("LLM vision: the local backend reads the screen with the image, answers follow the menu",
	_LVS_LocalBackendEndToEnd)





; ======================================================
; ======================================================
; ======= 4/ Refusals, failures and supersession =======
; ======================================================
; ======================================================

_LVS_CancelledRegionSendsNothing() {
	_LVS_Run(_LPP_Menu(), _Body)
	_Body(Calls, Lines, Sent, Fx) {
		_LVS_Invoke("llm_screen_region", "openai")
		_LVS_Complete(Fx.Captures[1], false, "selection timeout")
		AssertEqual(0, Fx.Vision.Length, "a cancelled selection sends nothing")
		AssertTrue(_LPP_PendingNotice() != t("llm.vision.capture_failed"), "and shows no notice")
		AssertEqual(1, _LPP_LinesWith(Lines, "INFO", "cancelled"), "it is logged")
	}
}
Test("LLM vision: a cancelled region does nothing", _LVS_CancelledRegionSendsNothing)

_LVS_CaptureFailureIsShown() {
	_LVS_Run(_LPP_Menu(), _Body)
	_Body(Calls, Lines, Sent, Fx) {
		_LVS_Invoke("llm_screen_full", "openai")
		_LVS_Complete(Fx.Captures[1], false, "worker exited without staged output")
		AssertEqual(0, Fx.Vision.Length, "a failed capture sends nothing")
		AssertEqual(t("llm.vision.capture_failed"), _LPP_PendingNotice(), "the user is told")
	}
}
Test("LLM vision: a failed capture is reported", _LVS_CaptureFailureIsShown)

_LVS_NoDefaultModelIsRefused() {
	_LVS_Run(_LPP_Menu(), _Body)
	_Body(Calls, Lines, Sent, Fx) {
		AssertFalse(_LVS_Invoke("llm_screen_region", "cerebras"), "a backend without a default model")
		AssertEqual(0, Fx.Captures.Length, "is refused before any capture")
		AssertEqual(t("llm.vision.no_model"), _LPP_PendingNotice(), "with its notice")
	}
}
Test("LLM vision: a backend without a default model needs one in the binding", _LVS_NoDefaultModelIsRefused)

_LVS_AiOffIsRefused() {
	_LVS_Run(_LPP_Menu(false), _Body)
	_Body(Calls, Lines, Sent, Fx) {
		AssertFalse(_LVS_Invoke("llm_screen_region", "openai"), "an AI switched off")
		AssertEqual(0, Fx.Captures.Length, "captures nothing")
		AssertEqual(t("llm.manual_prediction.disabled"), _LPP_PendingNotice(),
			"with the notice llm_generate_prediction shows")
	}
}
Test("LLM vision: the manual-prediction refusals come before the capture", _LVS_AiOffIsRefused)

_LVS_ProviderWithoutKeyIsRefused() {
	_LVS_Run(_LPP_Menu(), _Body)
	_Body(Calls, Lines, Sent, Fx) {
		AssertFalse(_LVS_Invoke("llm_screen_region", "anthropic"), "no API entry for the provider")
		AssertFalse(_LVS_Invoke("llm_screen_region", "nope|model"), "an unknown provider")
		AssertEqual(0, Fx.Captures.Length, "neither captures")
		AssertEqual(t("llm.vision.read_failed"), _LPP_PendingNotice(), "the user is told")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "no API entry"), "the missing key is logged")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "not an API provider"), "the unknown id too")
	}
}
Test("LLM vision: a provider without a key or an unknown one is refused", _LVS_ProviderWithoutKeyIsRefused)

_LVS_TextOnlyProviderIsRefused() {
	_LVS_Run(_LPP_Menu(), _Body)
	_Body(Calls, Lines, Sent, Fx) {
		AssertFalse(_LVS_Invoke("llm_screen_region", "backboard|openai/gpt-4o-mini"), "Backboard reads no image")
		AssertFalse(_LVS_Invoke("llm_screen_full", "typesafe"), "nor does a decisions provider")
		AssertEqual(0, Fx.Captures.Length, "neither captures")
		AssertEqual(t("llm.vision.read_failed"), _LPP_PendingNotice(), "the user is told")
		AssertEqual(2, _LPP_LinesWith(Lines, "WARNING", "cannot read an image"), "and the log says why")
	}
}
Test("LLM vision: a provider that cannot read an image is refused before the capture", _LVS_TextOnlyProviderIsRefused)

_LVS_VisionFailureIsShown() {
	_LVS_Run(_LPP_Menu(), _Body)
	_Body(Calls, Lines, Sent, Fx) {
		_LVS_Invoke("llm_screen_region", "openai")
		_LVS_Complete(Fx.Captures[1], true)
		Fx.Vision[1]["on_fail"].Call(_LLMRemote_FailInfo("provider_error", 400, "bad image"))
		AssertEqual(0, Calls.Length, "no answer is asked")
		AssertEqual(t("llm.vision.read_failed"), _LPP_PendingNotice(), "the user is told")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "provider_error"), "with the reason in the log")

		TooltipHide("VisionTest", true)
		_LVS_Invoke("llm_screen_region", "openai")
		_LVS_Complete(Fx.Captures[2], true)
		_LPP_Answer(Fx.Vision[2], "I cannot read this image.")
		AssertEqual(0, Calls.Length, "an answer without the screen tag asks nothing")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "holds no transcription"), "and is logged")
		AssertEqual(t("llm.vision.read_failed"), _LPP_PendingNotice(), "and reported")
	}
}
Test("LLM vision: a failed or unreadable vision answer is reported", _LVS_VisionFailureIsShown)

_LVS_AllAnswersFailing() {
	_LVS_Run(_LPP_Menu(), _Body)
	_Body(Calls, Lines, Sent, Fx) {
		global _Stub_LlmTooltipCalls
		_LVS_Invoke("llm_screen_region", "openai")
		_LVS_Complete(Fx.Captures[1], true)
		_LPP_Answer(Fx.Vision[1], "SCREEN: " . LVS_SCREEN)
		loop 3
			Calls[A_Index]["on_fail"].Call(_LLMRemote_FailInfo("timeout"))
		AssertEqual(0, _Stub_LlmTooltipCalls.Length, "no candidate is shown")
		AssertEqual(t("llm.vision.read_failed"), _LPP_PendingNotice(), "the user is told")
	}
}
Test("LLM vision: no answer at all is reported", _LVS_AllAnswersFailing)

_LVS_NewTriggerSupersedes() {
	_LVS_Run(_LPP_Menu(), _Body)
	_Body(Calls, Lines, Sent, Fx) {
		global _Stub_LlmTooltipCalls
		_LVS_Invoke("llm_screen_region", "openai")
		_LVS_Invoke("llm_screen_full", "openai")
		_LVS_Complete(Fx.Captures[1], true)
		AssertEqual(0, Fx.Vision.Length, "the superseded capture sends nothing")
		AssertFalse(FileExist(Fx.Captures[1].Path), "and its screenshot is deleted")
		_LVS_Complete(Fx.Captures[2], true)
		AssertEqual(1, Fx.Vision.Length, "the newest capture is read")
		_LPP_Answer(Fx.Vision[1], "SCREEN: " . LVS_SCREEN)
		AssertEqual(1, Calls.Length, "its first answer is asked")

		_LVS_Invoke("llm_screen_full", "openai")
		_LPP_Answer(Calls[1], "ANSWER: Trop tard")
		AssertEqual(0, _Stub_LlmTooltipCalls.Length, "an answer of a superseded reading is not shown")
		AssertEqual(1, Calls.Length, "and asks nothing more")
		AssertTrue(_LPP_LinesWith(Lines, "INFO", "superseded") >= 2, "the drops are logged")
		AssertFalse(_LLM_Vision_RenderIsCurrent(1), "an older reading can no longer paint")
	}
}
Test("LLM vision: a new trigger supersedes the reading in progress", _LVS_NewTriggerSupersedes)





; ================================================
; ================================================
; ======= 5/ "Why this error?", end to end =======
; ================================================
; ================================================

global LVS_ERROR_SCREEN := "Error: Cannot find module 'left-pad'"

_LVS_ErrorEndToEnd() {
	_LVS_Run(_LPP_Menu(), _Body)
	_Body(Calls, Lines, Sent, Fx) {
		global _Stub_LlmPresentedRecord
		Config := LLM_Vision_Config()
		AssertTrue(_LVS_Invoke("llm_screen_error", "openai|gpt-4.1-mini"), "the capture starts")
		AssertEqual(1, Fx.Captures.Length, "one capture")
		AssertEqual("region", Fx.Captures[1].Kind, "the user draws a region around the error")
		_LVS_Complete(Fx.Captures[1], true)
		AssertFalse(FileExist(Fx.Captures[1].Path), "the screenshot is deleted once read")
		AssertEqual(1, Fx.Vision.Length, "the vision model reads the region")
		_LPP_Answer(Fx.Vision[1], "SCREEN: " . LVS_ERROR_SCREEN)

		; The explanation, in the interface language, then the fix
		Answers := ["Le module left-pad n'est pas installé.", "npm install left-pad"]
		loop 2 {
			AssertEqual(A_Index, Calls.Length, "the answers are asked one after the other")
			Call := Calls[A_Index]
			AssertEqual(LLM_Vision_FillLanguage(Config["error_answers"][A_Index]["prompt"], "fr"), Call["system"],
				"answer " . A_Index . " runs the error prompt of its rank")
			AssertEqual("SCREEN:`n" . LVS_ERROR_SCREEN, Call["ctx"], "about the transcribed error")
			AssertEqual("", Call["tail"], "without a TAIL")
			AssertEqual(Config["answer_max_tokens"], Call["max_tokens"], "within the answer budget")
			_LPP_Answer(Call, "ANSWER: " . Answers[A_Index])
		}
		AssertEqual(2, Calls.Length, "two answers, no more")
		AssertFalse(InStr(Calls[1]["system"], "{language}"), "the language is filled in")
		AssertContains(Calls[1]["system"], "Explain in fr,", "with the interface language")
		AssertEqual(Config["error_answers"][2]["prompt"], Calls[2]["system"], "the fix prompt names no language")
		Final := _LPP_LastFinalRender()
		AssertTrue(IsObject(Final), "the answers reach the tooltip")
		AssertEqual(2, Final.slots.Length, "two candidates")
		loop 2
			AssertEqual(Answers[A_Index], Final.slots[A_Index], "candidate " . A_Index . " in cause-then-fix order")
		AssertEqual(0, _LVS_LinesMentioning(Lines, "left-pad"), "the screen's text is never logged")

		; The user moves to the fix and accepts it: it is typed at the caret
		_Stub_LlmPresentedRecord.ActiveIdx := 2
		Presented := LLM_Tooltip_GetAcceptSnapshot()
		AssertEqual(Answers[2], Presented.Text, "the fix is the accepted candidate")
		Transaction := _LPP_AcceptTransaction(Presented)
		AssertEqual(0, Transaction.Deletes, "accepting erases nothing")
		TextSend(Transaction.Text, _LLM_Bridge_InjectionOptions(Transaction), (Ok, ErrorMessage := "") => 0)
		AssertEqual(1, Sent.Length, "one output")
		AssertEqual("{Text}" . Answers[2], Sent[1], "the fix, typed verbatim at the caret")
	}
}
Test("LLM vision: why this error? explains then fixes, and the fix is typed", _LVS_ErrorEndToEnd)

_LVS_ErrorRefusedBeforeCapture() {
	_LVS_Run(_LPP_Menu(false), _Body)
	_Body(Calls, Lines, Sent, Fx) {
		AssertFalse(_LVS_Invoke("llm_screen_error", "openai"), "an AI switched off")
		AssertEqual(0, Fx.Captures.Length, "captures nothing")
		AssertEqual(t("llm.manual_prediction.disabled"), _LPP_PendingNotice(),
			"with the notice llm_generate_prediction shows")
	}
}
Test("LLM vision: why this error? refuses before the capture", _LVS_ErrorRefusedBeforeCapture)

_LVS_ErrorOneAnswerFailing() {
	_LVS_Run(_LPP_Menu(), _Body)
	_Body(Calls, Lines, Sent, Fx) {
		global _Stub_LlmTooltipCalls
		_LVS_Invoke("llm_screen_error", "openai")
		_LVS_Complete(Fx.Captures[1], true)
		_LPP_Answer(Fx.Vision[1], "SCREEN: " . LVS_ERROR_SCREEN)
		Calls[1]["on_fail"].Call(_LLMRemote_FailInfo("timeout"))
		AssertEqual(2, Calls.Length, "a failed explanation still asks for the fix")
		_LPP_Answer(Calls[2], "ANSWER: npm install left-pad")
		Final := _LPP_LastFinalRender()
		AssertTrue(IsObject(Final), "the fix is offered")
		AssertEqual(1, Final.slots.Length, "alone")
		AssertEqual("npm install left-pad", Final.slots[1], "the fix")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "'cause' answer request failed"),
			"the failed explanation is logged by its id")
	}
}
Test("LLM vision: why this error? skips a failed answer", _LVS_ErrorOneAnswerFailing)

_LVS_ErrorBothAnswersFailing() {
	_LVS_Run(_LPP_Menu(), _Body)
	_Body(Calls, Lines, Sent, Fx) {
		global _Stub_LlmTooltipCalls
		_LVS_Invoke("llm_screen_error", "openai")
		_LVS_Complete(Fx.Captures[1], true)
		_LPP_Answer(Fx.Vision[1], "SCREEN: " . LVS_ERROR_SCREEN)
		Calls[1]["on_fail"].Call(_LLMRemote_FailInfo("timeout"))
		_LPP_Answer(Calls[2], "No tag here")
		AssertEqual(2, Calls.Length, "two answers asked, no third")
		AssertEqual(0, _Stub_LlmTooltipCalls.Length, "no candidate is shown")
		AssertEqual(t("llm.vision.read_failed"), _LPP_PendingNotice(), "the user is told")
	}
}
Test("LLM vision: why this error? without any answer is reported", _LVS_ErrorBothAnswersFailing)


_LVS_MissingLocalModelStopsScreenFlow() {
	_LVS_Run(_LPP_Menu(), _Body)
	_Body(Calls, Lines, Sent, Fx) {
		global _LLM_LocalModelOfferPort, LLM_OLLAMA_BASE_URL, _LLM_Vision_Generation
		Saved := _LLM_LocalModelOfferPort
		Offers := []
		try {
			_LLM_LocalModelOfferPort := Map("confirm", (Title, Text) => (Offers.Push(Text), false))
			AssertTrue(_LVS_Invoke("llm_screen_region", "local"))
			_LVS_Complete(Fx.Captures[1], true)
			AssertEqual(1, Fx.Ollama.Length)
			Model := JsonParse(Fx.Ollama[1]["body"])["model"]
			Fx.Ollama[1]["on_fail"].Call(LLM_LocalModelFailure(Model, LLM_OLLAMA_BASE_URL))
			AssertEqual(1, Offers.Length, "current image failure offers the exact missing local model")
			AssertContains(Offers[1], Model)
			AssertEqual(0, Calls.Length, "no answer is requested without a transcription")
			AssertEqual(1, Fx.Ollama.Length, "the image failure cannot start more local requests")
			_LLM_Vision_Generation += 1
			Fx.Ollama[1]["on_fail"].Call(LLM_LocalModelFailure(Model, LLM_OLLAMA_BASE_URL))
			AssertEqual(1, Offers.Length, "a stale screenshot receipt cannot open another consent")
			AssertEqual(0, Sent.Length)
		} finally _LLM_LocalModelOfferPort := Saved
	}
}
Test("LLM vision: actual local missing-model failure stops screen answers and rejects stale offer (todo-46-local-model)",
	_LVS_MissingLocalModelStopsScreenFlow)
