; modules/llm/agent_action.ahk

; ==============================================================================
; MODULE: AI Agent Actions (AHK)
; DESCRIPTION:
; Runs the AI agent (modules/llm/agent.ahk) on Windows: the
; llm_agent_selection and llm_agent_command actions, the automatic mode that
; watches the typing pause (llm.agent_mode = "auto"), the tooltip candidates
; whose acceptance runs a connector (modules/llm/agent_connectors.ahk), and the
; per-application thresholds the automatic mode learns.
;
; FEATURES & RATIONALE:
; 1. The agent never uses the AI menu's prediction backend, so it refuses only
;    while paused, when its mode is off, or when System 2 is not chosen or its
;    provider has no API entry with a key: the AI menu switched off or its
;    backend not ready refuse nothing. Nothing is read for a request that
;    cannot run.
; 2. System 1 and System 2 each go through ONE transport function taking the
;    backend and the payload (LLM_Agent_System1Request,
;    LLM_Agent_System2Request): a new API format plugs in there. The backend is
;    "local" (the local Ollama server) or an API provider, whose key is the one
;    of the menu's API entry for it, like the screen reading's backend. System 1
;    has a second kind: Jev, TypeSafe's decisions model, asked the triage as a
;    typed question (a decisions provider, or Backboard with a "typesafe/"
;    model).
; 3. Every proposed action is a tooltip candidate with its OWN accept handler:
;    Tab runs the connector, nothing is typed.
; 4. One flow at a time: each flow takes a generation, and a selection, a
;    triage or an answer carrying an older one is dropped. A keystroke retires
;    the flow in flight, as it cancels the requests of the prediction engine.
; 5. The automatic mode asks System 1 about the current sentence once the user
;    pauses, never twice about the same sentence, never while paused, in a
;    secure field, in an excluded application, in live mode or while a
;    hotstring tooltip or another AI tooltip is shown. An automatic next-word
;    prediction does not hold it back: it appears before the pause ends, and
;    the actions replace it when they arrive for the same sentence. Above the
;    learned threshold of the sentence's intent in that application, System 2
;    proposes its actions.
; 6. Accepting an automatic suggestion lowers that threshold, dismissing it
;    raises it; the map lives in the driver's local state store (the Storage
;    adapter), never in config.toml, bounded to the most recent applications.
;
; Neither the selection, the command, the sentence nor any proposed action is
; ever logged: only their sizes, counts and types.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include local_model_offer.ahk





; ===============================
; ===============================
; ======= 1/ Module State =======
; ===============================
; ===============================

; The context handed to the manual-prediction refusals: the agent brings its own
; text (a selection or a command), so an empty typing buffer never refuses it
global LLM_AGENT_REFUSAL_CONTEXT := "agent"

; The Lua %s class, as a PCRE character class: a text of only these is blank
global LLM_AGENT_BLANK_PATTERN := "^[ \t\n\x0B\f\r]*\z"

; Storage key of the learned thresholds, in the driver's local state store
global LLM_AGENT_LEARNING_KEY := "llm_agent_thresholds"

; Most applications the learned thresholds remember, the least recent dropped
global LLM_AGENT_LEARNING_MAX_APPS := 200

; Delay before the learned thresholds are written, so a burst of outcomes is
; one write
global LLM_AGENT_LEARNING_SAVE_DELAY_MS := 2000

; Most sentences the automatic mode remembers having triaged
global LLM_AGENT_TRIAGED_MEMORY := 64

; Model prefix of Jev served through Backboard: such a System 1 asks the triage
; as a decisions question instead of the chat prompt
global LLM_AGENT_JEV_BACKBOARD_PREFIX := "typesafe/"

; The state a Jev triage is about: the application and the sentence
global LLM_AGENT_JEV_STATE := "App: {app}`nText: {text}"

; English weekday names, A_WDay order (1 = Sunday): the prompt is English
global LLM_AGENT_WEEKDAYS := ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

; Registry value naming the Windows time zone
global LLM_AGENT_TIMEZONE_KEY := "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation"

; Generation of the newest flow; a callback carrying an older one is stale
global _LLM_Agent_Generation := 0

; The automatic mode: its armed pause timer, the suggestion it showed and not
; settled yet, and the sentences it already triaged (Map + insertion order)
global _LLM_Agent_Auto := Map("timer", 0, "offer", "", "triaged", Map(), "order", [])

; The learned thresholds, loaded on first use: Map("apps", Map(App -> Map(
; "used", Integer, "intents", Map(Intent -> thousandths))), "clock", Integer)
global _LLM_Agent_Learning := ""

; Test seams, 0 in production. Prompt: (Title, Text, Default) => Map("ok",
; "value"). Context: () => Map("app", "window", "now", "weekday", "timezone").
; Source: () => Map("hwnd", "control"). Connector: (Action, Config) => result
; Map. Schedule: SetTimer's signature. State reader/writer: ST_Get / ST_Set.
; Secure: () => Boolean. Commit: LLM_Menu_CommitMutation's first three
; parameters. Rebuild: () after a committed setting.
global _LLM_Agent_PromptFn := 0
global _LLM_Agent_ContextProbe := 0
global _LLM_Agent_SourceProbe := 0
global _LLM_Agent_ConnectorFn := 0
global _LLM_Agent_ScheduleFn := 0
global _LLM_Agent_StateReader := 0
global _LLM_Agent_StateWriter := 0
global _LLM_Agent_SecureFieldFn := 0
global _LLM_Agent_CommitFn := 0
global _LLM_Agent_RebuildFn := 0





; ===========================
; ===========================
; ======= 2/ Settings =======
; ===========================
; ===========================

/**
 * Reads one agent setting: the menu's value once the user's settings are
 * restored, the manifest default before.
 * @param {String} Key "agent_system1", "agent_system2", "agent_mode" or
 *     "agent_disabled_apps".
 * @returns {Any}
 */
LLM_Agent_Setting(Key) {
	global _LLM_Menu, LLM_AGENT_SETTING_KEYS
	Known := false
	for Candidate in LLM_AGENT_SETTING_KEYS
		Known := Known || Candidate == Key
	if !Known
		throw ValueError("LLM_Agent_Setting: unknown agent setting " . String(Key) . ".")
	if IsSet(_LLM_Menu) && (_LLM_Menu is Map) && _LLM_Menu.Has(Key)
		return _LLM_Menu[Key]
	return ManifestDefaultFor("llm." . Key)
}

/**
 * Resolves the backend of System 1 or System 2.
 * @param {String} Key "agent_system1" or "agent_system2".
 * @param {VarRef} Reason Receives why it is not usable, "" when it is.
 * @returns {Map|String} Map("backend", "model", "label"), "" when the setting
 *     is off, invalid or names a backend without a model.
 */
LLM_Agent_Backend(Key, &Reason := "") {
	global LLM_API_PROVIDERS
	Value := LLM_Agent_Setting(Key)
	if (Value == "") {
		Reason := "off"
		return ""
	}
	Parsed := LLM_Vision_Parse(Value, &Reason)
	if !(Parsed is Map)
		return ""
	Model := LLM_Agent_ResolveModel(Parsed, LLM_Agent_Config(), LLM_API_PROVIDERS)
	if (Model == "") {
		Reason := "no model for '" . Parsed["backend"] . "'"
		return ""
	}
	Fmt := LLM_RemoteProviderFormat(Parsed["backend"])
	if (Key == "agent_system2" && Fmt != "" && !LLM_RemoteFormatServes(Fmt, "chat")) {
		Reason := "'" . Parsed["backend"] . "' answers typed questions only, it cannot write actions"
		return ""
	}
	; A provider without an API entry with a key cannot answer
	if !(_LLM_Vision_TryResolveTarget(Parsed["backend"], Model, &Why) is Map) {
		Reason := Why
		return ""
	}
	Reason := ""
	return Map("backend", Parsed["backend"], "model", Model,
		"label", LLM_Agent_BackendLabel(Parsed["backend"]))
}

/**
 * The backends System 1 or System 2 may run, in menu order: the local server,
 * then every API provider of api_providers.json in its order that can serve
 * it. A chat provider serves both; a decisions provider (TypeSafe's Jev)
 * answers typed questions, so it serves System 1 only.
 * @param {String} Key "agent_system1" or "agent_system2".
 * @returns {Array} Maps ("value", "label").
 */
LLM_Agent_BackendChoices(Key) {
	global LLM_VISION_LOCAL_BACKEND, LLM_API_PROVIDERS, LLM_API_PROVIDER_ORDER
	if (Key != "agent_system1" && Key != "agent_system2")
		throw ValueError("LLM_Agent_BackendChoices: unknown system " . String(Key) . ".")
	Choices := [Map("value", LLM_VISION_LOCAL_BACKEND, "label", t("llm.vision.local_backend"))]
	for ProviderId in LLM_API_PROVIDER_ORDER {
		Provider := LLM_API_PROVIDERS[ProviderId]
		if (Key == "agent_system1" || LLM_RemoteFormatServes(Provider["Format"], "chat"))
			Choices.Push(Map("value", ProviderId, "label", Provider["Label"]))
	}
	return Choices
}

/**
 * The label the menu and the prompts give a backend id.
 * @param {String} Backend "local" or an API provider id.
 * @returns {String}
 */
LLM_Agent_BackendLabel(Backend) {
	for Choice in LLM_Agent_BackendChoices("agent_system1") {
		if (Choice["value"] == Backend)
			return Choice["label"]
	}
	return Backend
}

/**
 * Stores one agent setting through the AI menu's config.toml transaction.
 * @param {String} Key The setting.
 * @param {Any} Value Its new value.
 * @returns {Boolean} True when it is durable and live.
 */
LLM_Agent_CommitSetting(Key, Value) {
	global _LLM_Agent_CommitFn
	if !LLM_Option_TryNormalize(Key, Value, &Normalized)
		throw ValueError("LLM_Agent_CommitSetting: invalid value for " . String(Key) . ".")
	Commit := HasMethod(_LLM_Agent_CommitFn, "Call") ? _LLM_Agent_CommitFn : LLM_Menu_CommitMutation
	if !Commit.Call("the AI agent '" . Key . "' setting",
			_LLM_Agent_SetCandidate.Bind(Key, Normalized), _LLM_Agent_ApplyCommitted.Bind(Key))
		return false
	LLM_Agent_RefreshTray()
	return true
}

/**
 * Rebuilds the tray once a committed agent setting is live, so its submenu
 * shows it. Called after the transaction released config.toml.
 */
LLM_Agent_RefreshTray() {
	global _LLM_Agent_RebuildFn
	Rebuild := HasMethod(_LLM_Agent_RebuildFn, "Call") ? _LLM_Agent_RebuildFn : RebuildTrayMenu
	Rebuild.Call()
}

/**
 * Sets the agent's mode, refusing "auto" while System 1 or System 2 is not
 * chosen: the mode then stays as it was.
 * @param {String} Mode "off", "action" or "auto".
 * @returns {Boolean} True when the mode changed.
 */
LLM_Agent_SetMode(Mode) {
	if !LLM_Option_TryNormalize("agent_mode", Mode, &Normalized)
		throw ValueError("LLM_Agent_SetMode: unknown mode " . String(Mode) . ".")
	if (Normalized == "auto" && !_LLM_Agent_AutoIsPossible())
		return false
	if (LLM_Agent_Setting("agent_mode") == Normalized)
		return false
	if !LLM_Agent_CommitSetting("agent_mode", Normalized)
		return false
	LoggerInfo("LLM", "AI agent mode set to '{1}'.", Normalized)
	if (Normalized != "auto")
		_LLM_Agent_StopAuto("the automatic mode was turned off")
	return true
}

/**
 * Runs the llm_agent_auto_toggle action: the automatic mode on (from "action"
 * or "off") or back to "action", with its notice.
 * @returns {Boolean} True when the mode changed.
 */
LLM_Agent_ToggleAuto() {
	TurnOn := LLM_Agent_Setting("agent_mode") != "auto"
	if !LLM_Agent_SetMode(TurnOn ? "auto" : "action")
		return false
	_LLM_Menu_ShowManualPredictionNotice(TurnOn ? "llm.agent.auto_on" : "llm.agent.auto_off")
	return true
}

; Candidate mutation of a commit: the menu state gets the validated value.
; @returns {Integer} True, the transaction's success contract.
_LLM_Agent_SetCandidate(Key, Value, Candidate) {
	if !(Candidate is Map)
		return false
	Candidate[Key] := Value
	return true
}

; Live tail of a committed agent setting: the agent reads the menu state, which
; the transaction already published.
; @returns {Integer} True, the transaction's success contract.
_LLM_Agent_ApplyCommitted(Key, Candidate) {
	LoggerDebug("LLM", "AI agent setting '{1}' committed.", Key)
	return true
}

; Tells whether the automatic mode can run, and says why when it cannot.
; @returns {Boolean}
_LLM_Agent_AutoIsPossible() {
	if !(LLM_Agent_Backend("agent_system1", &Reason) is Map) {
		LoggerInfo("LLM", "AI agent automatic mode refused: System 1 is not usable ({1}).", Reason)
		_LLM_Menu_ShowManualPredictionNotice("llm.agent.no_system1")
		return false
	}
	if !(LLM_Agent_Backend("agent_system2", &Reason) is Map) {
		LoggerInfo("LLM", "AI agent automatic mode refused: System 2 is not usable ({1}).", Reason)
		_LLM_Menu_ShowManualPredictionNotice("llm.agent.no_system2")
		return false
	}
	return true
}





; ==========================
; ==========================
; ======= 3/ Actions =======
; ==========================
; ==========================

/**
 * Runs llm_agent_selection: the selection is read, then handed to System 2.
 * @returns {Boolean} True when the selection capture started.
 */
LLM_Agent_TriggerSelection() {
	global _LLM_Agent_Generation
	Backend := _LLM_Agent_ManualRefusal()
	if !(Backend is Map)
		return false
	_LLM_Agent_Generation += 1
	Generation := _LLM_Agent_Generation
	if !LLM_SelectionReader().Call(_LLM_Agent_OnSelection.Bind(Generation, Backend)) {
		LoggerInfo("LLM", "AI agent #{1} skipped: the selection could not be read (paused or clipboard busy).",
			Generation)
		return false
	}
	return true
}

/**
 * Runs llm_agent_command: the user types a command in a native dialog, then
 * it is handed to System 2. Cancelling or leaving it empty does nothing.
 * @returns {Boolean} True when a request was sent.
 */
LLM_Agent_TriggerCommand() {
	global _LLM_Agent_Generation, _LLM_Agent_PromptFn, LLM_AGENT_BLANK_PATTERN
	Backend := _LLM_Agent_ManualRefusal()
	if !(Backend is Map)
		return false
	Prompt := HasMethod(_LLM_Agent_PromptFn, "Call") ? _LLM_Agent_PromptFn : _LLM_Agent_NativePrompt
	Answer := Prompt.Call(t("dialog.agent.command_title"), t("dialog.agent.command_prompt"), "")
	if !Answer["ok"] || RegExMatch(Answer["value"], LLM_AGENT_BLANK_PATTERN) {
		LoggerInfo("LLM", "AI agent command cancelled: the dialog was closed or left empty.")
		return false
	}
	_LLM_Agent_Generation += 1
	return LLM_Agent_Ask(Map("generation", _LLM_Agent_Generation, "source", "command",
		"backend", Backend, "auto", false), Answer["value"])
}

; Applies the refusals every agent action shares, with their notices. The agent
; never uses the AI menu's prediction backend: the AI switched off or its
; backend not ready refuse nothing here, only the pause does.
; @returns {Map|String} The System 2 backend, "" when the action is refused.
_LLM_Agent_ManualRefusal() {
	global LLM_AGENT_REFUSAL_CONTEXT
	Refusal := LLM_Menu_ManualPredictionRefusal(A_IsSuspended, true, true, LLM_AGENT_REFUSAL_CONTEXT)
	; A pause outranks everything, the agent's own switch included
	if (Refusal != "") {
		_LLM_Menu_ShowManualPredictionRefusal(Refusal, 0)
		return ""
	}
	if (LLM_Agent_Setting("agent_mode") == "off") {
		LoggerInfo("LLM", "AI agent refused: its mode is off.")
		_LLM_Menu_ShowManualPredictionNotice("llm.agent.off_notice")
		return ""
	}
	Backend := LLM_Agent_Backend("agent_system2", &Reason)
	if !(Backend is Map) {
		LoggerInfo("LLM", "AI agent refused: System 2 is not usable ({1}).", Reason)
		_LLM_Menu_ShowManualPredictionNotice("llm.agent.no_system2")
		return ""
	}
	; The text would leave an app the user excluded from the AI
	if _LLM_Engine_ShouldSuppressForDisabledApps() {
		LoggerInfo("LLM", "AI agent refused: the focused app is excluded from the AI.")
		return ""
	}
	return Backend
}

; The selection arrived: hand it to System 2, or say that nothing is selected.
_LLM_Agent_OnSelection(Generation, Backend, Text) {
	global _LLM_Agent_Generation, LLM_AGENT_BLANK_PATTERN
	if (Generation != _LLM_Agent_Generation) {
		LoggerInfo("LLM", "AI agent #{1} dropped: a newer flow superseded it before the selection arrived.",
			Generation)
		return
	}
	if A_IsSuspended {
		LoggerInfo("LLM", "AI agent #{1} dropped: the driver is paused.", Generation)
		return
	}
	if !(Text is String) || RegExMatch(Text, LLM_AGENT_BLANK_PATTERN) {
		LoggerInfo("LLM", "AI agent #{1} skipped: nothing is selected.", Generation)
		_LLM_Menu_ShowManualPredictionNotice("llm.agent.no_selection")
		return
	}
	LLM_Agent_Ask(Map("generation", Generation, "source", "selection", "backend", Backend,
		"auto", false), Text)
}

; The native text dialog of the command action.
; @returns {Map} Map("ok", Boolean, "value", String).
_LLM_Agent_NativePrompt(Title, Text, Default) {
	Result := Ui_InputBox(Text, Title, "w560 h160", Default)
	return Map("ok", Result.Result == "OK", "value", Result.Value)
}





; ===========================
; ===========================
; ======= 4/ System 2 =======
; ===========================
; ===========================

/**
 * Asks System 2 for the actions a text implies and offers them. Shared by the
 * selection, the command and the automatic mode.
 * @param {Map} Flow Map("generation", "source", "backend", "auto"[, "intent",
 *     "context"]).
 * @param {String} Text The source text.
 * @returns {Boolean} True when the request was sent.
 */
LLM_Agent_Ask(Flow, Text) {
	Config := LLM_Agent_Config()
	if !Flow.Has("context")
		Flow["context"] := _LLM_Agent_Context(Config)
	Ctx := Flow["context"].Clone()
	Ctx["source"] := Flow["source"]
	Flow["config"] := Config
	Flow["tools"] := Ctx["tools"]
	Payload := Map(
		"system", LLM_Agent_System2Prompt(Config, Ctx),
		"user", LLM_Agent_System2UserText(Config, Text),
		"max_tokens", Config["system2"]["max_tokens"])
	; Sizes only: the text is the user's own
	LoggerStart("LLM", "AI agent #{1}: {2} character(s) of {3} to System 2 '{4}' ({5}).",
		Flow["generation"], StrLen(Text), Flow["source"], Flow["backend"]["backend"],
		Flow["backend"]["model"])
	; The automatic mode stays discreet: no spinner, only its candidates
	if !Flow["auto"]
		_LLM_Agent_ShowLoading(Flow)
	if !LLM_Agent_System2Request(Flow["backend"], Payload, _LLM_Agent_OnActions.Bind(Flow),
			_LLM_Agent_OnActionsFail.Bind(Flow), !Flow["auto"]) {
		LoggerWarn("LLM", "AI agent #{1} failed: System 2 '{2}' has no API entry with a key.",
			Flow["generation"], Flow["backend"]["backend"])
		_LLM_Agent_Notify(Flow, "llm.agent.failed")
		return false
	}
	return true
}

/**
 * Sends one System 2 request: the one transport of System 2.
 * @param {Map} Backend LLM_Agent_Backend's record.
 * @param {Map} Payload Map("system", "user", "max_tokens").
 * @param {Func} OnSuccess Called with the answer text.
 * @param {Func} OnFail Called on failure.
 * @param {Boolean} CancelEngine Whether a pending or in-flight prediction gives
 *     way (a flow the user asked for).
 * @returns {Boolean} False, with nothing sent, when the backend cannot be reached.
 */
LLM_Agent_System2Request(Backend, Payload, OnSuccess, OnFail, CancelEngine := true) {
	return _LLM_Agent_Chat(Backend, Payload, OnSuccess, OnFail, CancelEngine)
}

; System 2 answered: validate its actions and offer them.
_LLM_Agent_OnActions(Flow, Raw, Meta := "") {
	if !_LLM_Agent_IsCurrent(Flow) {
		LoggerInfo("LLM", "AI agent #{1}: answer ignored, a newer flow superseded it.", Flow["generation"])
		return
	}
	if A_IsSuspended {
		LoggerInfo("LLM", "AI agent #{1} dropped: the driver is paused.", Flow["generation"])
		return
	}
	Actions := LLM_Agent_ParseActions(Flow["config"], Raw, Flow["tools"], &Rejected)
	for Reason in Rejected
		LoggerInfo("LLM", "AI agent #{1}: an action was refused ({2}).", Flow["generation"], Reason)
	if !(Actions is Array) {
		LoggerWarn("LLM", "AI agent #{1} failed: the answer holds no action list ({2} character(s)).",
			Flow["generation"], (Raw is String) ? StrLen(Raw) : 0)
		_LLM_Agent_Notify(Flow, "llm.agent.failed")
		return
	}
	if (Actions.Length == 0) {
		LoggerSuccess("LLM", "AI agent #{1}: no action to suggest.", Flow["generation"])
		_LLM_Agent_Notify(Flow, "llm.agent.no_action")
		return
	}
	_LLM_Agent_Show(Flow, Actions)
	Types := ""
	for Action in Actions
		Types .= (A_Index == 1 ? "" : ", ") . Action["type"]
	LoggerSuccess("LLM", "AI agent #{1}: {2} action(s) offered ({3}).", Flow["generation"], Actions.Length, Types)
}

; The System 2 request failed.
_LLM_Agent_OnActionsFail(Flow, Failure := "") {
	if !_LLM_Agent_IsCurrent(Flow) {
		LoggerInfo("LLM", "AI agent #{1}: failure ignored, a newer flow superseded it.", Flow["generation"])
		return
	}
	LoggerWarn("LLM", "AI agent #{1} failed: the System 2 request failed ({2}).",
		Flow["generation"], _LLM_Vision_FailureReason(Failure))
	if LLM_LocalModelIsMissing(Failure) {
		_LLM_Agent_HideOwnTooltip(Flow)
		LLM_LocalModelOffer(Failure, Flow["auto"], _LLM_Agent_RenderIsCurrent.Bind(Flow["generation"]))
		return
	}
	_LLM_Agent_Notify(Flow, "llm.agent.failed")
}

; Shows a notice of a manual flow and retires its spinner; the automatic mode
; only logs, the user asked nothing.
_LLM_Agent_Notify(Flow, Key) {
	_LLM_Agent_HideOwnTooltip(Flow)
	if !Flow["auto"]
		_LLM_Menu_ShowManualPredictionNotice(Key)
}





; =============================
; =============================
; ======= 5/ Candidates =======
; =============================
; =============================

; Publishes the actions as the tooltip's candidates, each with its own accept
; handler: Tab runs the selected action's connector, nothing is typed.
_LLM_Agent_Show(Flow, Actions) {
	global _LLM_Agent_Auto
	Slots := []
	for Action in Actions {
		Label := LLM_Agent_Label(Action)
		Slots.Push({ Text: _LLM_Agent_Format(Label["key"], Label["args"]),
			OnAccept: _LLM_Agent_Accept.Bind(Flow, Action) })
	}
	Source := _LLM_Agent_AcceptSource(Flow)
	Meta := Map(
		"offer_id", _LLM_Agent_OfferId(Flow),
		"accept_source", Source,
		"app_name", _LLM_Engine_AppNameForAcceptSource(Source),
		"is_final", true,
		"render_guard", _LLM_Agent_RenderIsCurrent.Bind(Flow["generation"])
	)
	; Still the same sentence, no keystroke since: the actions take the place
	; of the automatic prediction shown meanwhile
	if Flow["auto"]
		_LLM_Agent_RetirePrediction(Flow)
	LLM_Tooltip_Show(Slots, 1, true, Meta)
	if Flow["auto"]
		_LLM_Agent_Auto["offer"] := Map("app", Flow["context"]["app"], "intent", Flow["intent"],
			"generation", Flow["generation"])
}

; The user accepted one candidate: run its connector and say how it went.
; @param {Map} Flow The flow that offered it.
; @param {Map} Action The validated action.
; @returns {Boolean} True when the connector succeeded.
_LLM_Agent_Accept(Flow, Action) {
	global _LLM_Agent_ConnectorFn
	if Flow["auto"]
		_LLM_Agent_SettleOffer(true)
	Connector := HasMethod(_LLM_Agent_ConnectorFn, "Call") ? _LLM_Agent_ConnectorFn : LLM_AgentConnector_Execute
	LoggerStart("LLM", "AI agent #{1}: running the {2} connector.", Flow["generation"], Action["type"])
	Result := Connector.Call(Action, Flow["config"])
	if !(Result is Map) || !Result.Get("ok", false) {
		Reason := (Result is Map) ? Result.Get("reason", "unknown") : "no result"
		LoggerError("LLM", "AI agent #{1}: the {2} connector failed: {3}.", Flow["generation"], Action["type"], Reason)
		_LLM_Menu_ShowManualPredictionNotice("llm.agent.connector_failed")
		return false
	}
	LoggerSuccess("LLM", "AI agent #{1}: the {2} connector succeeded ({3}).", Flow["generation"], Action["type"],
		Result.Get("path", "direct"))
	switch Action["type"] {
		case "calendar", "reminder":
			_LLM_Menu_ShowNotice(StrReplace(t("llm.agent.done_" . Action["type"]), "{1}", Action["title"]))
		case "mail":
			_LLM_Menu_ShowManualPredictionNotice("llm.agent.done_mail")
		default:
			_LLM_Menu_ShowNotice(StrReplace(t("llm.agent.done_shortcut"), "{1}", Action["name"]))
	}
	return true
}

; Fills a locale text's {1}, {2}… with the arguments, in one pass.
_LLM_Agent_Format(Key, Args) {
	Template := t(Key)
	Out := ""
	Position := 1
	while RegExMatch(Template, "\{([1-9])\}", &Match, Position) {
		Out .= SubStr(Template, Position, Match.Pos - Position)
		Index := Integer(Match[1])
		Out .= (Index <= Args.Length) ? Args[Index] : Match[0]
		Position := Match.Pos + Match.Len
	}
	return Out . SubStr(Template, Position)
}

; The purple "in progress" tooltip of a manual flow.
_LLM_Agent_ShowLoading(Flow) {
	Source := _LLM_Agent_AcceptSource(Flow)
	LLM_Tooltip_ShowLoading(Map(
		"offer_id", _LLM_Agent_OfferId(Flow),
		"accept_source", Source,
		"app_name", _LLM_Engine_AppNameForAcceptSource(Source),
		"render_guard", _LLM_Agent_RenderIsCurrent.Bind(Flow["generation"])))
}

; Hides the flow's own tooltip, never another one.
_LLM_Agent_HideOwnTooltip(Flow) {
	Record := LLM_Tooltip_GetPresentedToken()
	if IsObject(Record) && Record.Lifecycle.OfferId == _LLM_Agent_OfferId(Flow)
		LLM_Tooltip_HideExact(Record)
}

; The control the candidates' Tab targets: the one focused when the flow began.
_LLM_Agent_AcceptSource(Flow) {
	global _LLM_Agent_SourceProbe
	if !Flow.Has("accept_source")
		Flow["accept_source"] := HasMethod(_LLM_Agent_SourceProbe, "Call")
			? _LLM_Agent_SourceProbe.Call() : _LLM_Engine_CaptureAcceptSource()
	return Flow["accept_source"]
}

; @returns {String} The tooltip offer id of a flow.
_LLM_Agent_OfferId(Flow) {
	return "agent_" . Flow["generation"]
}

; @returns {Boolean} True when no newer flow started.
_LLM_Agent_IsCurrent(Flow) {
	global _LLM_Agent_Generation
	return Flow["generation"] == _LLM_Agent_Generation
}

; Render guard of the candidates: a strict Boolean the tooltip checks before
; painting.
_LLM_Agent_RenderIsCurrent(Generation) {
	global _LLM_Agent_Generation
	return (Generation == _LLM_Agent_Generation && !A_IsSuspended) ? true : false
}





; ==========================
; ==========================
; ======= 6/ Context =======
; ==========================
; ==========================

; The context of a System 2 prompt, without its source.
; @returns {Map} app, window, now, weekday, timezone, language, tools.
_LLM_Agent_Context(Config) {
	global _LLM_Agent_ContextProbe
	Probe := HasMethod(_LLM_Agent_ContextProbe, "Call") ? _LLM_Agent_ContextProbe.Call() : _LLM_Agent_SystemContext()
	Ctx := Map("language", I18nGetLocale(), "tools", LLM_AgentConnector_ToolNames(Config))
	for Key in ["app", "window", "now", "weekday", "timezone"]
		Ctx[Key] := Probe[Key]
	return Ctx
}

; The frontmost application, its window, the local time and the time zone.
; @returns {Map}
_LLM_Agent_SystemContext() {
	global LLM_AGENT_WEEKDAYS
	Focused := WIGetFocused()
	Stamp := A_Now
	return Map(
		"app", RegExReplace(Focused.Get("appId", ""), "i)\.exe\z", ""),
		"window", Focused.Get("windowTitle", ""),
		"now", FormatTime(Stamp, "yyyy-MM-dd") . "T" . FormatTime(Stamp, "HH:mm"),
		"weekday", LLM_AGENT_WEEKDAYS[Integer(FormatTime(Stamp, "WDay"))],
		"timezone", _LLM_Agent_TimeZone())
}

; The Windows time zone id ("Romance Standard Time"), else the UTC offset.
_LLM_Agent_TimeZone() {
	global LLM_AGENT_TIMEZONE_KEY
	if Reg_TryRead(LLM_AGENT_TIMEZONE_KEY, "TimeZoneKeyName", &Name) && (Name is String) && Name != ""
		return Name
	Minutes := DateDiff(A_Now, A_NowUTC, "Minutes")
	LoggerDebug("LLM", "AI agent: no Windows time zone id, the UTC offset stands in.")
	return Format("UTC{1}{2:02d}:{3:02d}", Minutes < 0 ? "-" : "+", Abs(Minutes) // 60, Mod(Abs(Minutes), 60))
}





; =================================
; =================================
; ======= 7/ Automatic Mode =======
; =================================
; =================================

/**
 * Tells whether the automatic mode watches the typing: its mode is "auto" and
 * Ergopti+ is not paused. While predictions are off the LLM bridge feeds
 * LLM_Agent_OnTyping on this alone, so the AI menu's switch never starves the
 * automatic mode; the agent's mode and the pause start and stop that feed.
 * @returns {Boolean}
 */
LLM_Agent_WatchesTyping() {
	if A_IsSuspended
		return false
	return LLM_Agent_Setting("agent_mode") == "auto"
}

/**
 * Called by the LLM bridge on every typed character and Backspace, with the
 * predictions on or, in the automatic mode, off: settles a suggestion the user
 * typed over, retires the flow in flight and, in the automatic mode, arms the
 * pause timer on the new buffer.
 * @param {String} Buffer The typed context, most recent character last.
 * @returns {Boolean} True when the pause timer was armed.
 */
LLM_Agent_OnTyping(Buffer, PublishGuard := unset) {
	global _LLM_Agent_Generation, _LLM_Agent_Auto
	if IsSet(PublishGuard) && !PublishGuard.Call()
		return false
	_LLM_Agent_SettleOffer(false)
	Automatic := LLM_Agent_Setting("agent_mode") == "auto"
	; Configuration may be cold; resolve it before mutating the pause owner.
	PauseMs := Automatic ? LLM_Agent_Config()["system1"]["pause_ms"] : 0
	PreviousCritical := Critical("On")
	try {
		if IsSet(PublishGuard) && !PublishGuard.Call()
			return false
		_LLM_Agent_Generation += 1
		_LLM_Agent_CancelPause()
		if !Automatic
			return false
		Timer := _LLM_Agent_OnPause.Bind(_LLM_Agent_Generation, Buffer)
		_LLM_Agent_Auto["timer"] := Timer
		_LLM_Agent_Schedule(Timer, -PauseMs)
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

/**
 * Sends one System 1 request and reads its triage: the one transport of
 * System 1. A chat model reads the triage prompt; Jev (a decisions provider,
 * or Backboard with a "typesafe/" model) answers the triage as a typed
 * question about the application and the sentence.
 * @param {Map} Backend LLM_Agent_Backend's record.
 * @param {String} Sentence The sentence being typed.
 * @param {Map} Ctx Map("app", "tools").
 * @param {Func} OnTriage Called with the triage Map, or "" when there is none.
 * @returns {Boolean} False, with nothing sent, when the backend cannot be reached.
 */
LLM_Agent_System1Request(Backend, Sentence, Ctx, OnTriage, Generation := -1) {
	global LLM_AGENT_JEV_STATE
	Config := LLM_Agent_Config()
	if _LLM_Agent_IsJev(Backend)
		return _LLM_Agent_Decide(Backend, _LLM_Agent_Fill(LLM_AGENT_JEV_STATE,
			Map("app", Ctx.Get("app", ""), "text", Sentence)), Config, OnTriage)
	Payload := Map(
		"system", LLM_Agent_System1Prompt(Config, Ctx),
		"user", Sentence,
		"max_tokens", Config["system1"]["max_tokens"])
	return _LLM_Agent_Chat(Backend, Payload, _LLM_Agent_OnSystem1Answer.Bind(Config, OnTriage),
		_LLM_Agent_OnSystem1Fail.Bind(OnTriage, Generation), false)
}

; System 1 answered: hand its triage on.
_LLM_Agent_OnSystem1Answer(Config, OnTriage, Raw, Meta := "") {
	OnTriage.Call(LLM_Agent_ParseSystem1(Config, Raw))
}

; @returns {Boolean} True when a System 1 backend is Jev: a decisions provider,
;     or Backboard running a "typesafe/" model.
_LLM_Agent_IsJev(Backend) {
	global LLM_AGENT_JEV_BACKBOARD_PREFIX
	Fmt := LLM_RemoteProviderFormat(Backend["backend"])
	if (Fmt == "decisions")
		return true
	return Fmt == "backboard"
		&& SubStr(Backend["model"], 1, StrLen(LLM_AGENT_JEV_BACKBOARD_PREFIX)) == LLM_AGENT_JEV_BACKBOARD_PREFIX
}

; Asks Jev the triage question about a state: System 1's second transport.
; @returns {Boolean} False, with nothing sent, when the backend cannot be reached.
_LLM_Agent_Decide(Backend, State, Config, OnTriage) {
	Target := _LLM_Vision_ResolveTarget(Backend["backend"], Backend["model"], "AI agent")
	if !(Target is Map)
		return false
	Questions := LLM_Agent_JevQuestions(Config)
	OnFail := _LLM_Agent_OnSystem1Fail.Bind(OnTriage, -1)
	if (Target["format"] == "decisions") {
		LLM_RemoteDecisions_Async(Target["resolved"], State, Questions,
			_LLM_Agent_OnJevAnswers.Bind(Config, OnTriage), OnFail)
		return true
	}
	LLM_RemoteBackboard_Async(Target["resolved"],
		Map("model", Backend["model"], "system", "", "text", State, "questions", Questions),
		_LLM_Agent_OnBackboardJev.Bind(Config, OnTriage), OnFail)
	return true
}

; Jev answered through a decisions provider: hand its triage on.
_LLM_Agent_OnJevAnswers(Config, OnTriage, Answers, Usage := "") {
	OnTriage.Call(LLM_Agent_ParseJevAnswers(Config, Answers))
}

; Jev answered through Backboard: find its answers, say where they were, and
; hand the triage on. Where Backboard puts them is not documented, so a miss
; names the answer's top-level keys (never its content) to locate them.
_LLM_Agent_OnBackboardJev(Config, OnTriage, Response, Usage := "") {
	Answers := LLM_RemoteFormats_BackboardDecisionAnswers(Response, &Where)
	if !IsObject(Answers) {
		LoggerWarn("LLM", "AI agent: Backboard returned no Jev answers (top-level keys: {1}).",
			LLM_RemoteTopLevelKeys(Response))
		OnTriage.Call("")
		return
	}
	LoggerInfo("LLM", "AI agent: Jev's answers read from Backboard's '{1}'.", Where)
	OnTriage.Call(LLM_Agent_ParseJevAnswers(Config, Answers))
}

; The System 1 request failed: there is no triage.
_LLM_Agent_OnSystem1Fail(OnTriage, Generation, Failure := "") {
	global _LLM_Agent_Generation
	if Generation >= 0 && (Generation != _LLM_Agent_Generation || A_IsSuspended)
		return
	if LLM_LocalModelIsMissing(Failure) && Generation >= 0 && LLM_Agent_WatchesTyping()
		LLM_LocalModelOffer(Failure, true, _LLM_Agent_RenderIsCurrent.Bind(Generation))
	LoggerWarn("LLM", "AI agent: the System 1 request failed ({1}).", _LLM_Vision_FailureReason(Failure))
	OnTriage.Call("")
}

; The typing paused: triage the current sentence when everything allows it.
_LLM_Agent_OnPause(Generation, Buffer) {
	global _LLM_Agent_Generation, _LLM_Agent_Auto, _LLM_Agent_SecureFieldFn
	_LLM_Agent_Auto["timer"] := 0
	if (Generation != _LLM_Agent_Generation) || A_IsSuspended
		return false
	; The AI menu's switch is not the agent's: only its own mode counts
	if (LLM_Agent_Setting("agent_mode") != "auto")
		return false
	if LLM_Engine_LiveIsActive() || _LLM_Agent_SurfaceIsHeld() || _LLM_Engine_HotstringTooltipShown() {
		LoggerDebug("LLM", "AI agent: no triage, live mode or another tooltip holds the surface.")
		return false
	}
	System1 := LLM_Agent_Backend("agent_system1", &Reason)
	System2 := LLM_Agent_Backend("agent_system2", &Reason)
	if !(System1 is Map) || !(System2 is Map) {
		LoggerDebug("LLM", "AI agent: no triage, a system is not usable ({1}).", Reason)
		return false
	}
	Config := LLM_Agent_Config()
	Sentence := RTrim(LLM_Rewrite_SentenceSpan(Buffer), " `t`r`n")
	if (LLM_Rewrite_CodepointLength(Sentence) < Config["system1"]["min_chars"])
		return false
	if _LLM_Agent_Auto["triaged"].Has(Sentence) {
		LoggerDebug("LLM", "AI agent: no triage, this sentence was already triaged.")
		return false
	}
	Secure := true
	try Secure := HasMethod(_LLM_Agent_SecureFieldFn, "Call") ? _LLM_Agent_SecureFieldFn.Call() : SFD_IsSecureField()
	if Secure {
		LoggerInfo("LLM", "AI agent: no triage in a secure field.")
		return false
	}
	Ctx := _LLM_Agent_Context(Config)
	if _LLM_Agent_AppIsExcluded(Ctx["app"]) || _LLM_Engine_ShouldSuppressForDisabledApps() {
		LoggerDebug("LLM", "AI agent: no triage, the application is excluded.")
		return false
	}
	_LLM_Agent_RememberTriaged(Sentence)
	Flow := Map("generation", Generation, "source", "typing", "backend", System2, "auto", true,
		"context", Ctx, "sentence", Sentence)
	LoggerInfo("LLM", "AI agent #{1}: triage of {2} character(s) by System 1 '{3}'.", Generation,
		StrLen(Sentence), System1["backend"])
	if !LLM_Agent_System1Request(System1, Sentence, Ctx, _LLM_Agent_OnTriage.Bind(Flow), Generation) {
		LoggerWarn("LLM", "AI agent #{1}: System 1 '{2}' has no API entry with a key.", Generation,
			System1["backend"])
		return false
	}
	return true
}

; System 1 answered: wake System 2 above the learned threshold of the intent.
_LLM_Agent_OnTriage(Flow, Triage) {
	if !_LLM_Agent_IsCurrent(Flow) {
		LoggerInfo("LLM", "AI agent #{1}: triage ignored, the user kept typing.", Flow["generation"])
		return
	}
	if A_IsSuspended
		return
	if !(Triage is Map) {
		LoggerInfo("LLM", "AI agent #{1}: the triage is unreadable.", Flow["generation"])
		return
	}
	Threshold := LLM_Agent_Threshold(Flow["context"]["app"], Triage["intent"])
	if !LLM_Agent_ShouldAct(Triage, Threshold) {
		LoggerInfo("LLM", "AI agent #{1}: '{2}' at {3} stays under {4}, nothing suggested.", Flow["generation"],
			Triage["intent"], Triage["probability"], Threshold)
		return
	}
	Flow["intent"] := Triage["intent"]
	LLM_Agent_Ask(Flow, Flow["sentence"])
}

; @returns {Boolean} True when App is in the automatic mode's excluded apps.
_LLM_Agent_AppIsExcluded(App) {
	Apps := LLM_Agent_Setting("agent_disabled_apps")
	; The engine's matcher: case-insensitive, with or without ".exe"
	return (Apps is Array) && Apps.Length > 0 && _LLM_Engine_AppIsExcluded(App, Apps)
}

; Remembers a triaged sentence, forgetting the oldest beyond the memory.
_LLM_Agent_RememberTriaged(Sentence) {
	global _LLM_Agent_Auto, LLM_AGENT_TRIAGED_MEMORY
	_LLM_Agent_Auto["triaged"][Sentence] := true
	_LLM_Agent_Auto["order"].Push(Sentence)
	while (_LLM_Agent_Auto["order"].Length > LLM_AGENT_TRIAGED_MEMORY)
		_LLM_Agent_Auto["triaged"].Delete(_LLM_Agent_Auto["order"].RemoveAt(1))
}

; Tells whether a tooltip the automatic mode must not cover is shown: any AI
; tooltip but an automatic next-word prediction (its candidates or its spinner).
; @returns {Boolean}
_LLM_Agent_SurfaceIsHeld() {
	if !LLM_Tooltip_IsVisible()
		return false
	return !_LLM_Agent_IsAutoPrediction(LLM_Tooltip_GetPresentedToken())
}

; Tells whether a presented tooltip record is an automatic prediction: offered
; by the prediction engine (its request id), neither live mode's nor one the
; user asked for (llm_generate_prediction and its presets).
; @param {Object} Record LLM_Tooltip_GetPresentedToken's record, 0 when none.
; @returns {Boolean}
_LLM_Agent_IsAutoPrediction(Record) {
	global _LLM_Engine
	if !IsObject(Record) || !Record.HasOwnProp("Lifecycle") || !IsObject(Record.Lifecycle)
		return false
	OfferId := Record.Lifecycle.OfferId
	if !(OfferId is Integer) || OfferId <= 0
		return false
	return (OfferId != _LLM_Engine.Get("explicit_request_id", 0)) && !_LLM_Engine_RequestIsLive(OfferId)
}

; Retires the automatic prediction the actions of an automatic flow replace:
; its pending and in-flight requests, whose late answer would cover the
; actions, and its tooltip.
_LLM_Agent_RetirePrediction(Flow) {
	LLM_Engine_CancelTimer()
	LLM_Engine_CancelInflight()
	Record := LLM_Tooltip_GetPresentedToken()
	if _LLM_Agent_IsAutoPrediction(Record) {
		LLM_Tooltip_HideExact(Record)
		LoggerInfo("LLM", "AI agent #{1}: its actions replace the prediction tooltip.", Flow["generation"])
	}
}

; Retires the armed pause timer.
_LLM_Agent_CancelPause() {
	global _LLM_Agent_Auto
	if IsObject(_LLM_Agent_Auto["timer"])
		_LLM_Agent_Schedule(_LLM_Agent_Auto["timer"], 0)
	_LLM_Agent_Auto["timer"] := 0
}

; Leaves the automatic mode's state behind, the bridge's agent-only typing
; feed included.
_LLM_Agent_StopAuto(Reason) {
	global _LLM_Agent_Auto
	_LLM_Agent_CancelPause()
	_LLM_Agent_SettleOffer(false)
	_LLM_Agent_Auto["triaged"] := Map()
	_LLM_Agent_Auto["order"] := []
	if IsSet(LLM_Bridge_ResetAgentFeed)
		LLM_Bridge_ResetAgentFeed(Reason)
	LoggerInfo("LLM", "AI agent automatic mode stopped ({1}).", Reason)
}

/**
 * Pause step of the lifecycle ("pause = tout éteint"): retires the flow in
 * flight, whose answer could otherwise land after the resume, the armed pause
 * timer, which native Suspend does not stop, and the bridge's agent-only typing
 * feed with its context. The suggestion the pause hid is dropped unlearned:
 * the user did not dismiss it. Resuming needs nothing: the next keystroke
 * starts the feed again when the agent still watches the typing.
 * @returns {Boolean} True, the lifecycle step's contract.
 */
LLM_Agent_OnSuspend() {
	global _LLM_Agent_Generation, _LLM_Agent_Auto
	_LLM_Agent_Generation += 1
	_LLM_Agent_CancelPause()
	_LLM_Agent_Auto["offer"] := ""
	if IsSet(LLM_Bridge_ResetAgentFeed)
		LLM_Bridge_ResetAgentFeed("Ergopti+ was paused")
	LoggerInfo("LLM", "AI agent #{1}: typing watch and flow in flight retired by the pause.", _LLM_Agent_Generation)
	return true
}

; Arms a one-shot timer (a negative period) or cancels one (0), through the
; test suite's scheduler when it is set. The agent never repeats a timer: its
; pause and its learning write run once, re-armed on demand, since a repeating
; timer would tick on the keystroke thread.
_LLM_Agent_Schedule(Callback, Period) {
	global _LLM_Agent_ScheduleFn
	if !(Period is Integer) || Period > 0
		throw ValueError("_LLM_Agent_Schedule: a one-shot period is negative, a cancel 0, got " . String(Period) . ".")
	if HasMethod(_LLM_Agent_ScheduleFn, "Call")
		return _LLM_Agent_ScheduleFn.Call(Callback, Period)
	if (Period == 0)
		return SetTimer(Callback, 0)
	return SetTimer(Callback, -Abs(Period))
}

; Sends one chat request to an agent backend: the local server or an API
; provider, whose key is the one of the menu's API entry for it. A provider's
; body is the one the prediction engine sends, with the per-model fields of
; api_providers.json (a reasoning model told not to reason over a triage).
; @param {Boolean} CancelEngine Whether a pending or in-flight prediction must
;     give way (a manual flow); the automatic mode leaves it running.
; @returns {Boolean} False, with nothing sent, when the backend cannot be reached.
_LLM_Agent_Chat(Backend, Payload, OnSuccess, OnFail, CancelEngine := true) {
	global _LLM_Engine
	Target := _LLM_Vision_ResolveTarget(Backend["backend"], Backend["model"], "AI agent")
	if !(Target is Map)
		return false
	if Target.Has("resolved") && !LLM_RemoteFormatServes(Target["format"], "chat")
		throw ValueError("The AI agent cannot chat with '" . Backend["backend"] . "': it answers typed questions only.")
	; Backboard's exchange writes its own bodies; it takes no temperature
	if (Target["format"] == "backboard") {
		if CancelEngine
			_LLM_Vision_CancelEngine()
		LLM_RemoteBackboardChat_Async(Target["resolved"], Payload["system"], Payload["user"], OnSuccess, OnFail)
		return true
	}
	if Target.Has("resolved") {
		Resolved := Target["resolved"]
		Body := _LLMRemoteBuildPayload(Resolved["Format"], Resolved["Model"], Payload["system"],
			Payload["user"], _LLM_Engine["temperature"] + 0.0, Payload["max_tokens"], Resolved["Extras"])
	} else {
		Body := LLM_Vision_BuildRequest(Target["format"], Map(
			"model", Backend["model"],
			"system", Payload["system"],
			"text", Payload["user"],
			"max_tokens", Payload["max_tokens"]))
	}
	_LLM_Vision_Send(Target, Body, OnSuccess, OnFail, CancelEngine)
	return true
}





; ===========================
; ===========================
; ======= 8/ Learning =======
; ===========================
; ===========================

/**
 * The threshold an intent must reach in an application: the learned one, else
 * agent.json's.
 * @param {String} App The application.
 * @param {String} Intent The triage's intent.
 * @returns {Number}
 */
LLM_Agent_Threshold(App, Intent) {
	Learning := _LLM_Agent_LearningState()
	Key := StrLower(App)
	if Learning["apps"].Has(Key) && Learning["apps"][Key]["intents"].Has(Intent)
		return Learning["apps"][Key]["intents"][Intent] / 1000
	return LLM_Agent_Config()["system1"]["threshold"]
}

/**
 * Moves the threshold of an intent in an application after the user accepted
 * or dismissed an automatic suggestion, and schedules the write.
 * @param {String} App The application.
 * @param {String} Intent The suggestion's intent.
 * @param {Boolean} Accepted
 * @returns {Number} The new threshold.
 */
LLM_Agent_LearnOutcome(App, Intent, Accepted) {
	global LLM_AGENT_LEARNING_SAVE_DELAY_MS
	Learning := _LLM_Agent_LearningState()
	Next := LLM_Agent_Learn(LLM_Agent_Config(), LLM_Agent_Threshold(App, Intent), Accepted)
	Key := StrLower(App)
	if !Learning["apps"].Has(Key)
		Learning["apps"][Key] := Map("used", 0, "intents", Map())
	Learning["clock"] += 1
	Learning["apps"][Key]["used"] := Learning["clock"]
	Learning["apps"][Key]["intents"][Intent] := Round(Next * 1000)
	_LLM_Agent_TrimLearning(Learning)
	LoggerInfo("LLM", "AI agent: the '{1}' threshold in '{2}' is now {3} ({4}).", Intent, App, Next,
		Accepted ? "accepted" : "dismissed")
	_LLM_Agent_Schedule(_LLM_Agent_SaveLearning, -LLM_AGENT_LEARNING_SAVE_DELAY_MS)
	return Next
}

; Settles the automatic suggestion on screen, once.
; @param {Boolean} Accepted True when the user ran one of its actions.
_LLM_Agent_SettleOffer(Accepted) {
	global _LLM_Agent_Auto
	Offer := _LLM_Agent_Auto["offer"]
	if !(Offer is Map)
		return false
	_LLM_Agent_Auto["offer"] := ""
	LLM_Agent_LearnOutcome(Offer["app"], Offer["intent"], Accepted)
	return true
}

; The learned thresholds, read from the local state store on first use.
_LLM_Agent_LearningState() {
	global _LLM_Agent_Learning, _LLM_Agent_StateReader, LLM_AGENT_LEARNING_KEY
	if (_LLM_Agent_Learning is Map)
		return _LLM_Agent_Learning
	Reader := HasMethod(_LLM_Agent_StateReader, "Call") ? _LLM_Agent_StateReader : ST_Get
	Stored := ""
	try Stored := Reader.Call(LLM_AGENT_LEARNING_KEY, "")
	catch as Err
		LoggerError("LLM", "AI agent: the learned thresholds could not be read: {1}.", Err.Message)
	_LLM_Agent_Learning := Map("apps", Map(), "clock", 0)
	if (Stored is Map) {
		Kept := _LLM_Agent_LoadLearning(Stored, _LLM_Agent_Learning)
		LoggerInfo("LLM", "AI agent: learned thresholds of {1} application(s) loaded.", Kept)
	} else if (Stored != "") {
		LoggerError("LLM", "AI agent: the stored learned thresholds are not a map; starting afresh.")
	}
	return _LLM_Agent_Learning
}

; Copies every well-formed entry of a stored map; a malformed one is logged
; and left out.
; @returns {Integer} The applications kept.
_LLM_Agent_LoadLearning(Stored, Learning) {
	Config := LLM_Agent_Config()
	Low := Round(Config["learning"]["min_threshold"] * 1000)
	High := Round(Config["learning"]["max_threshold"] * 1000)
	for App, Entry in Stored {
		Used := (Entry is Map) ? Entry.Get("used", "") : ""
		Intents := (Entry is Map) ? Entry.Get("intents", "") : ""
		if !(Used is Integer) || !(Intents is Map) {
			LoggerError("LLM", "AI agent: a malformed learned entry was left out.")
			continue
		}
		Clean := Map()
		for Intent, Milli in Intents {
			if (Milli is Integer) && Milli >= Low && Milli <= High && _LLM_Agent_IsIntent(Config, Intent)
				Clean[Intent] := Milli
			else
				LoggerError("LLM", "AI agent: a malformed learned threshold was left out.")
		}
		Learning["apps"][StrLower(App)] := Map("used", Used, "intents", Clean)
		Learning["clock"] := Max(Learning["clock"], Used)
	}
	_LLM_Agent_TrimLearning(Learning)
	return Learning["apps"].Count
}

; Drops the least recently used applications beyond the bound.
_LLM_Agent_TrimLearning(Learning) {
	global LLM_AGENT_LEARNING_MAX_APPS
	while (Learning["apps"].Count > LLM_AGENT_LEARNING_MAX_APPS) {
		Oldest := ""
		for App, Entry in Learning["apps"] {
			if (Oldest == "" || Entry["used"] < Learning["apps"][Oldest]["used"])
				Oldest := App
		}
		Learning["apps"].Delete(Oldest)
	}
}

; Writes the learned thresholds to the local state store.
_LLM_Agent_SaveLearning(*) {
	global _LLM_Agent_Learning, _LLM_Agent_StateWriter, LLM_AGENT_LEARNING_KEY
	if !(_LLM_Agent_Learning is Map)
		return false
	Writer := HasMethod(_LLM_Agent_StateWriter, "Call") ? _LLM_Agent_StateWriter : ST_Set
	Saved := false
	try Saved := Writer.Call(LLM_AGENT_LEARNING_KEY, _LLM_Agent_Learning["apps"])
	catch as Err
		LoggerError("LLM", "AI agent: the learned thresholds could not be written: {1}.", Err.Message)
	if !Saved {
		LoggerError("LLM", "AI agent: the learned thresholds were not written.")
		return false
	}
	LoggerDebug("LLM", "AI agent: learned thresholds of {1} application(s) written.", _LLM_Agent_Learning["apps"].Count)
	return true
}
