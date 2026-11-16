; tests/unit/ai/actions/test_agent_plan_corpus.ahk

; ==============================================================================
; MODULE: Agent Request Plan Corpus Consumer (Windows)
; DESCRIPTION:
; Replays llm/request_plan_agent_vectors.json through the real owners of the
; agent: the manual refusals and the typing pause, in the world of test_llm_agent.
;
; FEATURES & RATIONALE:
; 1. The first replay found a real bug: the manual actions looked at excluded
;    applications alone, where the plan refuses a blocked focus, secure fields
;    included, so a selection could leave a password field.
; 2. A refusal names its step through its own log line, and a notice is the
;    pending tooltip. The automatic mode logs no blocker name, so its vectors
;    assert the outcome: a triage was sent or nothing left.
; 3. ai_busy and vision are one Windows fact: an AI tooltip that is not an
;    automatic prediction holds the surface. That is how the replay sets both.
; ==============================================================================

#Requires AutoHotkey v2.0

global _LAPC_STEP_LOG := Map(
	"paused", "Manual prediction refused (paused)",
	"ai_off", "Manual prediction refused (disabled)",
	"mode_off", "AI agent refused: its mode is off",
	"no_system2", "System 2 is not usable",
	"focus_blocked", "excluded from the AI"
)

global _LAPC_NOTICE_KEY := Map(
	"disabled", "llm.manual_prediction.disabled",
	"agent_off", "llm.agent.off_notice",
	"no_system2", "llm.agent.no_system2"
)

_LAPC_Vectors(Kind) {
	global _SharedDir
	Rows := []
	for Vector in JsonParse(FileRead(_SharedDir . "\tests\corpus\llm\request_plan_agent_vectors.json", "UTF-8"))["vectors"]
		if (Vector["kind"] == Kind)
			Rows.Push(Vector)
	return Rows
}

_LAPC_Admit(Vector) {
	Facts := Vector["facts"]
	Expect := Vector["expect"]
	Menu := _LAG_Menu(Facts["mode"], "cerebras", Facts.Get("system2_usable", true) ? "cerebras" : "", Facts["ai_enabled"])
	_LAG_Run(Menu, _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		global _LOGGER_DEDUP_KEY, _TooltipPendingRequest
		_LOGGER_DEDUP_KEY := ""
		_TooltipPendingRequest := ""
		Fx.Secure := Facts.Get("focus_blocked", false)
		if Facts["paused"]
			Suspend(true)
		try Result := _LLM_Agent_ManualRefusal()
		finally Suspend(false)
		AssertEqual(Expect["allowed"] ? 1 : 0, Result is Map ? 1 : 0, Vector["id"])
		if Expect["allowed"]
			return
		for Step, Text in _LAPC_STEP_LOG
			AssertEqual(Step == Expect["step"] ? 1 : 0, _LPP_LinesWith(Lines, "INFO", Text) > 0 ? 1 : 0,
				Vector["id"] . " logs only its own step, " . Step)
		Notice := Expect.Get("notice", "")
		if _LAPC_NOTICE_KEY.Has(Notice)
			AssertEqual(t(_LAPC_NOTICE_KEY[Notice]), _LPP_PendingNotice(), Vector["id"])
		else if (Notice == "")
			AssertEqual("", _LPP_PendingNotice(), Vector["id"] . " refuses in silence")
	}
}

_LAPC_Pause(Fx, Sentence, Armed := true) {
	global _LLM_Agent_Generation
	Result := _LLM_Agent_OnPause(_LLM_Agent_Generation, Sentence)
	AssertEqual(Armed ? 1 : 0, Result ? 1 : 0, "the pause's outcome")
	AssertEqual(Armed ? 1 : 0, Fx.Remote.Length, "the requests the pause sent")
}

_LAPC_Auto(Vector) {
	Facts := Vector["facts"]
	_LAG_Run(_LAG_Menu(Facts["mode"], "cerebras", "cerebras", Facts["ai_enabled"]), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		global _LLM_Live, _Stub_LlmTooltipVisible, _Stub_LlmPresentedRecord, _TooltipActiveSurface
		SavedLive := _LLM_Live["active"]
		SavedSurface := IsSet(_TooltipActiveSurface) ? _TooltipActiveSurface : 0
		_LLM_Live["active"] := Facts["live"]
		_Stub_LlmTooltipVisible := Facts["ai_busy"] || Facts["vision"]
		_Stub_LlmPresentedRecord := 0
		Fx.Secure := Facts["focus_blocked"]
		_TooltipActiveSurface := Facts["hotstring_preview"] ? {Record: {Kind: "hotstring"}} : 0
		if Facts["paused"]
			Suspend(true)
		try _LAPC_Pause(Fx, "Envoie le devis à Paul demain matin", !Vector["expect"].Has("blocker"))
		finally {
			Suspend(false)
			_LLM_Live["active"] := SavedLive
			_TooltipActiveSurface := SavedSurface
		}
	}
}

_LAPC_Triage(Vector) {
	Facts := Vector["facts"]
	_LAG_Run(_LAG_Menu("auto", "cerebras", "cerebras"), _LTN_Screen(""), _Body)
	_Body(Fx, Lines, Sent) {
		; The vectors' distance to the minimum, at the setting this driver ships
		Chars := LLM_Agent_Config()["system1"]["min_chars"] + Facts["chars"] - Facts["min_chars"]
		Sentence := ""
		loop Chars
			Sentence .= "a"
		if Facts["already_triaged"]
			_LLM_Agent_RememberTriaged(Sentence)
		_LAPC_Pause(Fx, Sentence, !Vector["expect"].Has("skip"))
	}
}

for _LAPC_Kind, _LAPC_Fn in Map("admit", _LAPC_Admit, "auto_blocker", _LAPC_Auto, "triage_skip", _LAPC_Triage)
	for _LAPC_Vector in _LAPC_Vectors(_LAPC_Kind)
		Test("corpus: agent plan " . _LAPC_Vector["id"] . " (corpus-agent-plan)", _LAPC_Fn.Bind(_LAPC_Vector))
