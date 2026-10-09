; modules/llm/vision_action.ahk

; ==============================================================================
; MODULE: Screen Reading Actions (AHK)
; DESCRIPTION:
; Runs the llm_screen_region, llm_screen_full and llm_screen_error actions: a
; screenshot is read by a vision model (modules/llm/vision.ahk), then the AI
; menu's text backend drafts one answer per entry of an answer list of
; vision.json (answers, or error_answers for llm_screen_error), offered as the
; prediction tooltip's candidates. Accepting one types it at the caret.
;
; FEATURES & RATIONALE:
; 1. The refusals of the manual prediction trigger (paused, AI off, backend not
;    ready) come first, then the binding and its model: nothing is captured
;    for a request that cannot run.
; 2. The capture is the screenshot actions' own (modules/gestures/screenshots.ahk):
;    Snip & Sketch for a region, a GDI+ copy of the pointer's monitor for the
;    full screen. It is saved to a private temp PNG, shrunk to vision.json's
;    max_image_edge, read once and deleted whatever happens next.
; 3. The vision request goes to the binding's backend ("local" is the local
;    Ollama server, whatever the AI menu uses; any other id is the API provider
;    of that id, with the key of the menu's API entry for it). The answers go
;    to the AI menu's current backend, one after the other: the local server
;    runs one request at a time.
; 4. The answers are shown in their list's order as they arrive, through the
;    tooltip's usual candidates, navigation and Tab accept (nothing erased).
;    Nothing is typed without the user's acceptance.
; 5. One flow at a time: each trigger takes a generation, and a capture or an
;    answer carrying an older one is dropped.
;
; Neither the image nor the screen's text is ever logged: only their sizes.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include local_model_offer.ahk





; ===============================
; ===============================
; ======= 1/ Module State =======
; ===============================
; ===============================

; The context handed to the manual-prediction refusals: the screen is what the
; answers complete, and it is never empty, unlike a typed buffer
global LLM_VISION_REFUSAL_CONTEXT := "screen"

; Capture reasons that mean the user or a newer capture ended it: logged, no notice
global LLM_VISION_CAPTURE_CANCELLED := Map(
	"selection timeout", true,
	"superseded", true,
	"suspended", true,
	"driver suspended", true
)

; Generation of the newest flow; a callback carrying an older one is stale
global _LLM_Vision_Generation := 0

; Test seams, 0 in production. Capture: (Kind, Path, MaxEdge, OnDone(Ok, Reason)).
; Remote: (Resolved, Url, Body, OnSuccess, OnFail). Ollama: (Body, OnSuccess,
; OnFail). Source: () => Map("hwnd", "control"), the control an accept targets.
global _LLM_Vision_CaptureFn := 0
global _LLM_Vision_RemoteTransport := 0
global _LLM_Vision_OllamaTransport := 0
global _LLM_Vision_SourceProbe := 0





; =============================
; =============================
; ======= 2/ Public API =======
; =============================
; =============================

/**
 * The screen actions: capture kind per action id.
 * @returns {Map} Action id -> "region" or "full".
 */
LLM_VisionActions() {
	static Actions := Map(
		"llm_screen_region", "region",
		"llm_screen_full", "full",
		"llm_screen_error", "region",
	)
	return Actions
}

/**
 * The answer list of vision.json a screen action drafts: "Why this error?"
 * explains then fixes, the other screen actions reply, translate and explain.
 * @param {String} ActionId A key of LLM_VisionActions.
 * @returns {String} "error_answers" or "answers".
 */
LLM_Vision_AnswersKey(ActionId) {
	if !LLM_VisionActions().Has(ActionId)
		throw ValueError("LLM_Vision_AnswersKey: unknown screen action " . String(ActionId) . ".")
	return (ActionId == "llm_screen_error") ? "error_answers" : "answers"
}

/**
 * The vision backends a binding may name, in picker order: the local server,
 * then the API providers in api_providers.json's order whose format reads an
 * image (Backboard's messages carry text only, a decisions provider answers
 * typed questions only).
 * @returns {Array} Maps ("value", "label", "defaultModel"); defaultModel is
 *     vision.json's default for that backend, "" when it has none.
 */
LLM_Vision_BackendChoices() {
	global LLM_VISION_LOCAL_BACKEND, LLM_API_PROVIDERS, LLM_API_PROVIDER_ORDER
	Config := LLM_Vision_Config()
	Choices := [_LLM_Vision_Choice(LLM_VISION_LOCAL_BACKEND, t("llm.vision.local_backend"), Config)]
	for ProviderId in LLM_API_PROVIDER_ORDER {
		if LLM_RemoteFormatServes(LLM_API_PROVIDERS[ProviderId]["Format"], "images")
			Choices.Push(_LLM_Vision_Choice(ProviderId, LLM_API_PROVIDERS[ProviderId]["Label"], Config))
	}
	return Choices
}

/**
 * The backends as the native parameter prompt lists them, one per line.
 * @returns {String} "<id> — <label>" lines.
 */
LLM_Vision_BackendChoicesText() {
	Text := ""
	for Choice in LLM_Vision_BackendChoices()
		Text .= (Text == "" ? "" : "`n") . Choice["value"] . " — " . Choice["label"]
	return Text
}

/**
 * Runs one screen reading. The capture and the requests are asynchronous; this
 * call applies the refusals, supersedes any flow in progress and starts the
 * capture.
 * @param {String} Kind "region" or "full".
 * @param {String} Value The binding's llm_vision parameter.
 * @param {String} AnswersKey The answer list of vision.json to draft, in order.
 * @returns {Boolean} True when the capture started.
 */
LLM_Vision_Trigger(Kind, Value, AnswersKey := "answers") {
	global _LLM_Menu, _LLM_Engine, _LLM_Vision_Generation, _LLM_Vision_CaptureFn
	global LLM_VISION_REFUSAL_CONTEXT
	if (Kind != "region" && Kind != "full")
		throw ValueError("LLM_Vision_Trigger: unknown capture kind " . String(Kind) . ".")
	if (AnswersKey != "answers" && AnswersKey != "error_answers")
		throw ValueError("LLM_Vision_Trigger: unknown answer list " . String(AnswersKey) . ".")
	Enabled := _LLM_Menu.Get("enabled", false)
	Refusal := LLM_Menu_ManualPredictionRefusal(A_IsSuspended, Enabled,
		Enabled && _LLM_Menu_BackendIsReadyForUse(), LLM_VISION_REFUSAL_CONTEXT)
	if (Refusal != "") {
		_LLM_Menu_ShowManualPredictionRefusal(Refusal, 0)
		return false
	}
	Parsed := LLM_Vision_Parse(Value, &Reason)
	if !(Parsed is Map) {
		LoggerWarn("LLM", "Screen reading ignored: the binding's vision backend is invalid ({1}).", Reason)
		return false
	}
	Fmt := LLM_RemoteProviderFormat(Parsed["backend"])
	if (Fmt != "" && !LLM_RemoteFormatServes(Fmt, "images")) {
		LoggerWarn("LLM", "Screen reading refused: '{1}' cannot read an image ({2} format).",
			Parsed["backend"], Fmt)
		_LLM_Menu_ShowManualPredictionNotice("llm.vision.read_failed")
		return false
	}
	Config := LLM_Vision_Config()
	Model := LLM_Vision_ResolveModel(Parsed, Config)
	if (Model == "") {
		LoggerInfo("LLM", "Screen reading refused: the backend '{1}' has no default vision model.",
			Parsed["backend"])
		_LLM_Menu_ShowManualPredictionNotice("llm.vision.no_model")
		return false
	}
	Target := _LLM_Vision_ResolveTarget(Parsed["backend"], Model)
	if !(Target is Map) {
		_LLM_Menu_ShowManualPredictionNotice("llm.vision.read_failed")
		return false
	}
	; The screen would leave an app the user excluded from the AI
	if _LLM_Engine_ShouldSuppressForDisabledApps() {
		LoggerInfo("LLM", "Screen reading refused: the focused app is excluded from the AI.")
		return false
	}
	_LLM_Vision_Generation += 1
	Flow := Map(
		"generation", _LLM_Vision_Generation,
		"kind", Kind,
		"backend", Parsed["backend"],
		"model", Model,
		"target", Target,
		"path", "",
		"config", Config,
		"prompts", Config[AnswersKey],
		"screen", "",
		"answers", [],
		"index", 0,
		"source", ""
	)
	LoggerStart("LLM", "Screen reading #{1}: {2} capture for '{3}' ({4}), {5}.",
		Flow["generation"], Kind, Parsed["backend"], Model, AnswersKey)
	Capture := HasMethod(_LLM_Vision_CaptureFn, "Call") ? _LLM_Vision_CaptureFn : _LLM_Vision_DefaultCapture
	try {
		Flow["path"] := _LLM_Vision_CapturePath(Flow["generation"])
		Capture.Call(Kind, Flow["path"], Config["max_image_edge"], _LLM_Vision_OnCaptured.Bind(Flow))
	} catch as Err {
		LoggerError("LLM", "Screen reading #{1}: the capture could not start: {2}.",
			Flow["generation"], Err.Message)
		if (Flow["path"] != "")
			_LLM_Vision_DeleteCapture(Flow)
		_LLM_Menu_ShowManualPredictionNotice("llm.vision.capture_failed")
		return false
	}
	return true
}





; ==========================
; ==========================
; ======= 3/ Capture =======
; ==========================
; ==========================

; Starts the real capture into Path.
; @param {String} Kind "region" or "full".
; @param {String} Path The private PNG to write.
; @param {Integer} MaxEdge Longest edge of the saved image.
; @param {Func} OnDone Called with (Ok, Reason).
_LLM_Vision_DefaultCapture(Kind, Path, MaxEdge, OnDone) {
	if (Kind == "region") {
		GestureScreenshotRegion("save", OnDone, Path, MaxEdge)
		return
	}
	Bounds := _LLM_Vision_PointerMonitorBounds()
	GestureCaptureRegion(Bounds["x"], Bounds["y"], Bounds["w"], Bounds["h"], "save", Path,
		OnDone, MaxEdge)
}

; @returns {Map} x, y, w, h of the monitor under the mouse pointer.
_LLM_Vision_PointerMonitorBounds() {
	Pointer := MCGetPosStrict()
	X := Pointer["x"]
	Y := Pointer["y"]
	loop MonitorGetCount() {
		MonitorGet(A_Index, &Left, &Top, &Right, &Bottom)
		if (X >= Left && X < Right && Y >= Top && Y < Bottom)
			return Map("x", Left, "y", Top, "w", Right - Left, "h", Bottom - Top)
	}
	throw Error("No monitor contains the mouse pointer at " . X . "," . Y . ".")
}

; @param {Integer} Generation The flow's generation.
; @returns {String} A private temp path for its screenshot.
_LLM_Vision_CapturePath(Generation) {
	return _LLM_Ollama_TempDir() . "\ergopti_vision_" . Generation . "_" . A_TickCount . ".png"
}

; Deletes the flow's screenshot; a failure is logged, never hidden.
; @param {Map} Flow The flow.
_LLM_Vision_DeleteCapture(Flow) {
	if !FSDelete(Flow["path"])
		LoggerError("LLM", "Screen reading #{1}: the temporary screenshot could not be deleted.",
			Flow["generation"])
}

; @param {String} Path A file.
; @returns {String} Its content in base64, without line breaks.
_LLM_Vision_Base64File(Path) {
	Data := FSReadBytesStrict(Path)
	if (Data.Size == 0)
		throw Error("the screenshot is empty")
	Encoded := CryptoBase64Encode(Data)
	if (Encoded == "")
		throw Error("the screenshot could not be encoded")
	return Encoded
}

; The capture ended: read the screenshot, delete it, send the vision request.
; @param {Map} Flow The flow.
; @param {Boolean} Ok Whether the screenshot was saved.
; @param {String} Reason Why the capture ended.
_LLM_Vision_OnCaptured(Flow, Ok, Reason := "") {
	global LLM_VISION_CAPTURE_CANCELLED, LLM_VISION_READ_USER_TEXT
	Image := ""
	try {
		if !_LLM_Vision_IsCurrent(Flow) {
			LoggerInfo("LLM", "Screen reading #{1} dropped: a newer one superseded its capture.",
				Flow["generation"])
			return
		}
		if !Ok {
			if LLM_VISION_CAPTURE_CANCELLED.Has(Reason) {
				LoggerInfo("LLM", "Screen reading #{1} cancelled: {2}.", Flow["generation"], Reason)
				return
			}
			LoggerWarn("LLM", "Screen reading #{1}: the capture failed: {2}.", Flow["generation"], Reason)
			_LLM_Menu_ShowManualPredictionNotice("llm.vision.capture_failed")
			return
		}
		if A_IsSuspended {
			LoggerInfo("LLM", "Screen reading #{1} dropped: the driver is paused.", Flow["generation"])
			return
		}
		try Image := _LLM_Vision_Base64File(Flow["path"])
		catch as Err {
			LoggerWarn("LLM", "Screen reading #{1}: the screenshot could not be read: {2}.",
				Flow["generation"], Err.Message)
			_LLM_Menu_ShowManualPredictionNotice("llm.vision.capture_failed")
			return
		}
	} finally {
		_LLM_Vision_DeleteCapture(Flow)
	}
	Config := Flow["config"]
	Target := Flow["target"]
	Body := LLM_Vision_BuildRequest(Target["format"], Map(
		"model", Flow["model"],
		"system", Config["read_prompt"],
		"text", LLM_VISION_READ_USER_TEXT,
		"image", Image,
		"mime", Config["image_mime"],
		"max_tokens", Config["read_max_tokens"]))
	LoggerInfo("LLM", "Screen reading #{1}: {2} KB of image sent to '{3}'.",
		Flow["generation"], Round(StrLen(Image) * 3 / 4 / 1024), Flow["backend"])
	_LLM_Vision_Send(Target, Body, _LLM_Vision_OnRead.Bind(Flow), _LLM_Vision_OnReadFail.Bind(Flow))
}





; ===========================
; ===========================
; ======= 4/ Requests =======
; ===========================
; ===========================

; Resolves where a request to a named backend goes: the screen reading's vision
; request, and the AI agent's System 1 and System 2 requests.
; @param {String} Backend The backend id: "local" or an API provider.
; @param {String} Model The model the request runs.
; @param {String} Caller The feature asking, for the log.
; @returns {Map|String} Map("format"[, "resolved", "url"]), "" when the backend
;     is an unknown provider or has no API entry with a key.
_LLM_Vision_ResolveTarget(Backend, Model, Caller := "Screen reading") {
	Target := _LLM_Vision_TryResolveTarget(Backend, Model, &Reason)
	if !(Target is Map)
		LoggerWarn("LLM", "{1} refused: {2}.", Caller, Reason)
	return Target
}

/**
 * Resolves a backend like _LLM_Vision_ResolveTarget, without logging: the AI
 * agent checks its systems with it before any request.
 * @param {String} Backend The backend id: "local" or an API provider.
 * @param {String} Model The model the request runs.
 * @param {VarRef} Reason Receives why it is not reachable, "" when it is.
 * @returns {Map|String} Map("format"[, "resolved", "url"]), "" when unreachable.
 */
_LLM_Vision_TryResolveTarget(Backend, Model, &Reason := "") {
	global LLM_VISION_LOCAL_BACKEND, LLM_API_PROVIDERS
	Reason := ""
	if (Backend == LLM_VISION_LOCAL_BACKEND)
		return Map("format", "ollama")
	if !LLM_API_PROVIDERS.Has(Backend) {
		Reason := "'" . Backend . "' is not an API provider"
		return ""
	}
	Entry := _LLM_Vision_ProviderEntry(Backend)
	if !IsObject(Entry) {
		Reason := "no API entry is configured for '" . Backend . "'"
		return ""
	}
	; The entry lends its address and key; the model is the vision one
	Candidate := Map("Provider", Backend, "Model", Model)
	for Field in ["Id", "BaseUrl", "Token"]
		Candidate[Field] := _LLMRemoteEntryGet(Entry, Field, "")
	Resolved := _LLMRemoteResolveEntry(Candidate)
	if !(Resolved is Map) {
		Reason := "the API entry for '" . Backend . "' has no usable key or address"
		return ""
	}
	return Map(
		"format", Resolved["Format"],
		"resolved", Resolved,
		"url", _LLMRemoteBuildUrl(Resolved["BaseUrl"], Resolved["Format"], Resolved["Token"], Model))
}

; The menu's API entry for a provider: the active one when it is that provider,
; else the first one. The AI menu's state owns the entries even while the AI is
; off, which the AI agent does not depend on.
; @param {String} ProviderId The provider.
; @returns {Map|Object|String} The entry, "" when there is none.
_LLM_Vision_ProviderEntry(ProviderId) {
	global _LLM_Menu
	if !IsSet(_LLM_Menu) || !(_LLM_Menu is Map)
		return ""
	Entries := _LLM_Menu.Get("api_entries", [])
	if !(Entries is Array)
		return ""
	ActiveId := _LLM_Menu.Get("api_entry_id", "")
	First := ""
	for Entry in Entries {
		if (_LLMRemoteEntryGet(Entry, "Provider", "") != ProviderId)
			continue
		if (ActiveId != "" && _LLMRemoteEntryGet(Entry, "Id", "") == ActiveId)
			return Entry
		if !IsObject(First)
			First := Entry
	}
	return First
}

; Sends a caller-written body to a target: the local server or a provider.
; @param {Map} Target _LLM_Vision_ResolveTarget's record.
; @param {String} Body The JSON body.
; @param {Func} OnSuccess Called with the answer text.
; @param {Func} OnFail Called on failure.
; @param {Boolean} CancelEngine Whether a pending or in-flight prediction gives
;     way: every request the user asked for; the AI agent's automatic triage,
;     which the user did not ask for, leaves the prediction running.
_LLM_Vision_Send(Target, Body, OnSuccess, OnFail, CancelEngine := true) {
	global _LLM_Vision_RemoteTransport, _LLM_Vision_OllamaTransport
	if CancelEngine
		_LLM_Vision_CancelEngine()
	if Target.Has("resolved") {
		Transport := HasMethod(_LLM_Vision_RemoteTransport, "Call")
			? _LLM_Vision_RemoteTransport : LLM_RemotePostBody_Async
		Transport.Call(Target["resolved"], Target["url"], Body, OnSuccess, OnFail)
		return
	}
	Transport := HasMethod(_LLM_Vision_OllamaTransport, "Call")
		? _LLM_Vision_OllamaTransport : LLM_OllamaChat_Async
	Transport.Call(Body, OnSuccess, OnFail)
}

/**
 * Makes a pending or in-flight prediction give way to a request the user asked
 * for: it would hold the backend's slot.
 */
_LLM_Vision_CancelEngine() {
	global _LLM_Engine
	LLM_Engine_CancelTimer()
	LLM_Engine_CancelInflight()
	_LLM_Engine["last_request_tick"] := A_TickCount
}

; The vision model answered: extract the screen, then ask for the answers.
; @param {Map} Flow The flow.
; @param {String} Raw The model's answer.
; @param {Map} Meta Usage metadata (remote backend), unused.
_LLM_Vision_OnRead(Flow, Raw, Meta := "") {
	if !_LLM_Vision_IsCurrent(Flow) {
		LoggerInfo("LLM", "Screen reading #{1}: transcription ignored, a newer reading superseded it.",
			Flow["generation"])
		return
	}
	if A_IsSuspended {
		LoggerInfo("LLM", "Screen reading #{1} dropped: the driver is paused.", Flow["generation"])
		return
	}
	Screen := LLM_Vision_Extract(Raw, Flow["config"]["screen_tag"])
	if (Screen == "") {
		LoggerWarn("LLM", "Screen reading #{1}: the vision answer holds no transcription ({2} character(s)).",
			Flow["generation"], (Raw is String) ? StrLen(Raw) : 0)
		_LLM_Menu_ShowManualPredictionNotice("llm.vision.read_failed")
		return
	}
	Flow["screen"] := Screen
	LoggerInfo("LLM", "Screen reading #{1}: {2} character(s) transcribed.", Flow["generation"], StrLen(Screen))
	_LLM_Vision_NextAnswer(Flow)
}

; The vision request failed.
; @param {Map} Flow The flow.
; @param {Map} Failure Failure details, when the backend gives them.
_LLM_Vision_OnReadFail(Flow, Failure := "") {
	if !_LLM_Vision_IsCurrent(Flow)
		return
	LoggerWarn("LLM", "Screen reading #{1}: the vision request to '{2}' failed ({3}).",
		Flow["generation"], Flow["backend"], _LLM_Vision_FailureReason(Failure))
	if LLM_LocalModelIsMissing(Failure) {
		LLM_LocalModelOffer(Failure, false, _LLM_Vision_RenderIsCurrent.Bind(Flow["generation"]))
		return
	}
	_LLM_Menu_ShowManualPredictionNotice("llm.vision.read_failed")
}

/**
 * Sends one chat request to the AI menu's current text backend: the system
 * prompt and the user turn as they are (no PREFIX/TAIL), streaming off. The
 * screen answers and the selection translation ask through it.
 * @param {String} System The system prompt.
 * @param {String} User The user turn.
 * @param {Integer} MaxTokens The answer's token budget.
 * @param {Func} OnSuccess Called with the answer text.
 * @param {Func} OnFail Called on failure.
 * @returns {Boolean} False, with nothing sent, when the API backend has no entry.
 */
LLM_Vision_SendText(System, User, MaxTokens, OnSuccess, OnFail) {
	global _LLM_Engine
	if (_LLM_Engine.Get("backend", "ollama") == "api") {
		Entry := _LLM_Engine_GetActiveApiEntry()
		if !IsObject(Entry)
			return false
		LLM_Engine_CancelTimer()
		LLM_Engine_CancelInflight()
		_LLM_Engine["last_request_tick"] := A_TickCount
		; No PREFIX/TAIL in these prompts: the user turn goes as it is
		_LLM_Engine_ResolveRemoteTransport().Call(Entry, System, User,
			_LLM_Engine["temperature"] + 0.0, OnSuccess, OnFail, "", MaxTokens)
		return true
	}
	; The local server's chat body, written whole: the prediction payload stops
	; at the first line break, and an answer may take several lines
	_LLM_Vision_Send(Map("format", "ollama"), LLM_Vision_BuildRequest("ollama", Map(
		"model", LLM_ResolveOllamaTag(_LLM_Engine["model"]),
		"system", System,
		"text", User,
		"max_tokens", MaxTokens)), OnSuccess, OnFail)
	return true
}

; Sends the next answer request to the AI menu's backend, or ends the flow.
; @param {Map} Flow The flow.
_LLM_Vision_NextAnswer(Flow) {
	global _LLM_Engine
	Prompts := Flow["prompts"]
	Flow["index"] += 1
	Index := Flow["index"]
	if (Index > Prompts.Length) {
		_LLM_Vision_Finish(Flow)
		return
	}
	System := LLM_Vision_FillLanguage(Prompts[Index]["prompt"], _LLM_Engine["language"])
	User := LLM_Vision_AnswerUserText(Flow["screen"])
	if !LLM_Vision_SendText(System, User, Flow["config"]["answer_max_tokens"],
			_LLM_Vision_OnAnswer.Bind(Flow, Index), _LLM_Vision_OnAnswerFail.Bind(Flow, Index)) {
		LoggerWarn("LLM", "Screen reading #{1}: the API backend has no entry configured.", Flow["generation"])
		_LLM_Vision_Finish(Flow)
	}
}

; One answer arrived: keep it and show what the flow has so far.
; @param {Map} Flow The flow.
; @param {Integer} Index The answer's position in the flow's answer list.
; @param {String} Raw The model's answer.
; @param {Map} Meta Usage metadata (remote backend), unused.
_LLM_Vision_OnAnswer(Flow, Index, Raw, Meta := "") {
	if !_LLM_Vision_IsCurrent(Flow) {
		LoggerInfo("LLM", "Screen reading #{1}: answer ignored, a newer reading superseded it.",
			Flow["generation"])
		return
	}
	Id := Flow["prompts"][Index]["id"]
	Text := LLM_Vision_Extract(Raw, Flow["config"]["answer_tag"])
	if (Text == "") {
		LoggerWarn("LLM", "Screen reading #{1}: the '{2}' answer holds no text ({3} character(s)).",
			Flow["generation"], Id, (Raw is String) ? StrLen(Raw) : 0)
	} else {
		Flow["answers"].Push(Text)
		LoggerInfo("LLM", "Screen reading #{1}: '{2}' answer ready ({3} character(s)).",
			Flow["generation"], Id, StrLen(Text))
		if (Index < Flow["prompts"].Length)
			_LLM_Vision_Show(Flow, false)
	}
	_LLM_Vision_NextAnswer(Flow)
}

; One answer request failed: the flow goes on without it.
; @param {Map} Flow The flow.
; @param {Integer} Index The answer's position in the flow's answer list.
; @param {Map} Failure Failure details, when the backend gives them.
_LLM_Vision_OnAnswerFail(Flow, Index, Failure := "") {
	if !_LLM_Vision_IsCurrent(Flow)
		return
	LoggerWarn("LLM", "Screen reading #{1}: the '{2}' answer request failed ({3}).",
		Flow["generation"], Flow["prompts"][Index]["id"], _LLM_Vision_FailureReason(Failure))
	if LLM_LocalModelIsMissing(Failure) {
		LLM_LocalModelOffer(Failure, false, _LLM_Vision_RenderIsCurrent.Bind(Flow["generation"]))
		return
	}
	_LLM_Vision_NextAnswer(Flow)
}

; Every answer request settled: show the final candidates, or say none came.
; @param {Map} Flow The flow.
_LLM_Vision_Finish(Flow) {
	if (Flow["answers"].Length == 0) {
		LoggerWarn("LLM", "Screen reading #{1}: no answer could be drafted.", Flow["generation"])
		_LLM_Menu_ShowManualPredictionNotice("llm.vision.read_failed")
		return
	}
	_LLM_Vision_Show(Flow, true)
	LoggerSuccess("LLM", "Screen reading #{1}: {2} answer(s) offered.", Flow["generation"],
		Flow["answers"].Length)
}

; @param {Map|String} Failure A backend's failure payload.
; @returns {String} Its reason, "unknown" when it gives none.
_LLM_Vision_FailureReason(Failure) {
	if (Failure is Map) {
		for Key in ["reason", "message"] {
			Value := Failure.Get(Key, "")
			if (Value is String && Value != "")
				return Value
		}
	}
	return "unknown"
}





; =============================
; =============================
; ======= 5/ Candidates =======
; =============================
; =============================

; Publishes the answers gathered so far as the tooltip's candidates. The accept
; source is the control focused when they are first shown: the user may have
; moved since the trigger, and accepts explicitly.
; @param {Map} Flow The flow.
; @param {Boolean} IsFinal Whether every answer request has settled.
_LLM_Vision_Show(Flow, IsFinal) {
	global _LLM_Vision_SourceProbe
	if A_IsSuspended {
		LoggerInfo("LLM", "Screen reading #{1}: answers not shown, the driver is paused.", Flow["generation"])
		return
	}
	if !(Flow["source"] is Map)
		Flow["source"] := HasMethod(_LLM_Vision_SourceProbe, "Call")
			? _LLM_Vision_SourceProbe.Call() : _LLM_Engine_CaptureAcceptSource()
	Source := Flow["source"]
	Meta := Map(
		"offer_id", "vision_" . Flow["generation"],
		"accept_source", Source,
		"app_name", _LLM_Engine_AppNameForAcceptSource(Source),
		"is_final", IsFinal ? true : false,
		"render_guard", _LLM_Vision_RenderIsCurrent.Bind(Flow["generation"])
	)
	LLM_Tooltip_Show(Flow["answers"].Clone(), 1, IsFinal ? true : false, Meta)
}

; @param {Map} Flow The flow.
; @returns {Boolean} True when no newer flow started.
_LLM_Vision_IsCurrent(Flow) {
	global _LLM_Vision_Generation
	return Flow["generation"] == _LLM_Vision_Generation
}

; Render guard of the candidates: a strict Boolean the tooltip checks before
; painting.
; @param {Integer} Generation The flow's generation.
; @returns {Integer}
_LLM_Vision_RenderIsCurrent(Generation) {
	global _LLM_Vision_Generation
	return (Generation == _LLM_Vision_Generation && !A_IsSuspended) ? true : false
}

; @param {String} Value A backend id.
; @param {String} Label Its label.
; @param {Map} Config The decoded vision.json.
; @returns {Map}
_LLM_Vision_Choice(Value, Label, Config) {
	Default := Config["default_models"].Get(Value, "")
	return Map("value", Value, "label", Label, "defaultModel", (Default is String) ? Default : "")
}
