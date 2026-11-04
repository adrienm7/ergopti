#Requires AutoHotkey v2.0
#SingleInstance Off
; Audit reproducer: verbatim production _LLM_Agent_Accept body below.
; Audited SHA: 89b0b774c8c960c7ad458ac3cb98d5c97598e518
; No OS connector executes: its production seam is a recorder.
global ConnectorCalls := 0
global _LLM_Agent_ConnectorFn := RecordConnector
global _LLM_Agent_Generation := 2
Flow := Map("auto", false, "generation", 1, "config", Map())
Action := Map("type", "mail")
QueuedHandler := _LLM_Agent_Accept.Bind(Flow, Action)
Suspend(true)
try {
    ; Replay the callback already queued by SetTimer(Handler, -1).
    QueuedHandler.Call()
} finally {
    Suspend(false)
}
FileAppend("connector calls after pause + retired generation: " ConnectorCalls "`n", "*")
ExitApp(ConnectorCalls == 0 ? 0 : 1)

RecordConnector(Action, Config) {
    global ConnectorCalls
    ConnectorCalls += 1
    return Map("ok", true, "path", "test")
}
LoggerStart(Args*) {
}
LoggerSuccess(Args*) {
}
_LLM_Menu_ShowManualPredictionNotice(Args*) {
}
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
