; tests/meta/corpus/test_corpus_llm_request_plan.ahk

; ==============================================================================
; MODULE: Request Plan and Context Corpus Consumers (Windows)
; DESCRIPTION:
; Replays through the real Windows owners the corpora the Lua suites replay on
; macOS and Linux: live mode (llm/request_plan_live_vectors.json), the info bar
; (llm/request_plan_info_bar_vectors.json) and the context buffer
; (llm/context_buffer_vectors.json).
;
; FEATURES & RATIONALE:
; 1. The first replay of the live corpus found a real bug: a deleted prompt
;    dropped each keystroke's request but left live mode on, warning on every
;    keystroke, where the corpus says it stops.
; 2. The context window is 2048 code points on macOS and Linux, and 10000 units
;    here because the Windows context setting goes up to 10000. The rule replayed
;    is the shared one, keep the newest text, at the corpus's capacity.
; 3. private_mirror has no Windows owner: a private expansion clears the buffer,
;    as on Linux, so no mark exists to replay.
; ==============================================================================

#Requires AutoHotkey v2.0

_CTRP_Read(Relative) {
	return JsonParse(FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\" . Relative, "UTF-8"))
}

_CTRP_LiveVector(Vector) {
	if Vector.Has("config") || Vector.Has("config_missing") {
		Decoded := Vector.Has("config") ? Vector["config"] : 0
		AssertEqual(Vector.Get("expect_reason", ""), LLM_Live_ConfigRefusal(Decoded), Vector["id"])
		return
	}
	Profile := Vector["profile_found"] ? Map("id", "found") : 0
	Decide := LLM_Live_Decide.Bind(Vector["live_config"], Vector["receipt"], Vector["menu_count"], Profile)
	if Vector.Has("expect_error") {
		Message := ""
		try Decide.Call()
		catch as Err
			Message := Err.Message
		AssertContains(Message, Vector["expect_error"], Vector["id"])
		return
	}
	Decision := Decide.Call()
	for Name, Value in Vector["expect"]
		AssertEqual(Value, Decision[Name], Vector["id"] . " " . Name)
}

_CTRP_Live() {
	Vectors := _CTRP_Read("llm\request_plan_live_vectors.json")["vectors"]
	AssertEqual(10, Vectors.Length, "the live vectors changed")
	for Vector in Vectors
		_CTRP_LiveVector(Vector)
}
Test("corpus: live mode replays every request plan vector (corpus-request-plan)", _CTRP_Live)

_CTRP_InfoBarVector(Vector) {
	Spec := Vector["spec"] is Map ? Vector["spec"] : Map()
	if Vector.Has("expect_error") {
		Message := ""
		try LLM_InfoBar_Parts(Spec)
		catch as Err
			Message := Err.Message
		AssertContains(Message, Vector["expect_error"], Vector["id"])
		return
	}
	Parts := LLM_InfoBar_Parts(Spec)
	if Vector.Has("expect_none") {
		AssertEqual(0, Parts, Vector["id"])
		return
	}
	AssertEqual(Vector["expect"].Length, Parts.Length, Vector["id"])
	for Index, Piece in Vector["expect"]
		AssertEqual(Piece, Parts[Index], Vector["id"])
}

_CTRP_InfoBar() {
	Vectors := _CTRP_Read("llm\request_plan_info_bar_vectors.json")["vectors"]
	AssertEqual(13, Vectors.Length, "the info bar vectors changed")
	for Vector in Vectors
		_CTRP_InfoBarVector(Vector)
}
Test("corpus: the info bar replays every request plan vector (corpus-request-plan)", _CTRP_InfoBar)

; One corpus operation on the real bridge buffer. A navigation is the bridge's own
; reset; a Backspace is its own handler.
_CTRP_ContextOp(Op, Cleared) {
	global _LLM_Bridge_Buffer, _LLM_Engine
	Text := Op.Get("text", "")
	; Each directly seeded edit must belong to the same real bridge source
	; before a later public Backspace consumes it. Clear/reset may retire it.
	AssertTrue(IsObject(_LLM_Bridge_BindTypingSource(Map("hwnd", 101, "control", 102), true)))
	switch Op["op"] {
		case "append":
			loop Op.Get("repeat", 1)
				_LLM_Bridge_ApplyBufferEdit(0, Text)
		case "backspace":
			LLM_Bridge_OnBackspace()
		case "replace_tail":
			_LLM_Bridge_ApplyBufferEdit(Op["deletes"], Text)
		case "set":
			_LLM_Bridge_ApplyBufferEdit()
			_LLM_Bridge_ApplyBufferEdit(0, Text)
		case "clear":
			_LLM_Bridge_ClearBuffer()
		case "navigated":
			_LLM_Engine[ConfigLeaf.RESET_ON_NAV] := Op["reset_on_nav"]
			Before := _LLM_Bridge_Buffer
			LLM_Bridge_ResetPredictions()
			Cleared.Push(Before != "" && _LLM_Bridge_Buffer == "")
		default:
			throw ValueError("Unknown corpus operation " . Op["op"])
	}
}

_CTRP_ContextCase(Row) {
	global _LLM_Bridge_Buffer
	_LLM_Bridge_ApplyBufferEdit()
	Cleared := []
	for Op in Row["ops"]
		_CTRP_ContextOp(Op, Cleared)
	AssertEqual(Row["expect"]["text"], _LLM_Bridge_Buffer, Row["id"])
	AssertEqual(Row["expect"]["length"], StrLen(_LLM_Bridge_Buffer), Row["id"])
	if Row.Has("cleared") {
		AssertEqual(Row["cleared"].Length, Cleared.Length, Row["id"])
		for Index, Expected in Row["cleared"]
			AssertEqual(Expected ? 1 : 0, Cleared[Index] ? 1 : 0, Row["id"])
	}
}

_CTRP_Context() {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active, _LLM_Engine, LLM_BRIDGE_BUFFER_MAX_CHARS
	global _LLM_Bridge_PrefixObserver
	Corpus := _CTRP_Read("llm\context_buffer_vectors.json")
	AssertEqual(13, Corpus["cases"].Length, "the context buffer vectors changed")
	SavedCap := LLM_BRIDGE_BUFFER_MAX_CHARS
	SavedEngine := _LLM_Engine
	SavedActive := _LLM_Bridge_Active
	AssertFalse(IsObject(_LLM_Bridge_PrefixObserver), "The corpus cannot retire another observer")
	PreviousCritical := Critical("On"), Privacy := 0
	try {
		Privacy := _LLM_TestPrivacyEnter(Map("hwnd", 101, "control", 102))
		_LLM_Engine := SavedEngine.Clone()
		_LLM_Engine["pending_timer"] := "", _LLM_Engine["timer_active"] := false
		if _LLM_Engine.Has("request_plan")
			_LLM_Engine.Delete("request_plan")
		LLM_BRIDGE_BUFFER_MAX_CHARS := Corpus["capacity"]
		_LLM_Bridge_Active := true
		_LLM_Engine["enabled"] := false
		for Row in Corpus["cases"]
			_CTRP_ContextCase(Row)
	} finally {
		try {
			LLM_BRIDGE_BUFFER_MAX_CHARS := SavedCap
			if IsObject(Privacy)
				LLM_Bridge_CancelPrefixObserver()
			_LLM_Engine := SavedEngine
			_LLM_Bridge_Active := SavedActive
			if IsObject(Privacy)
				_LLM_TestPrivacyExit(Privacy)
		} finally Critical(PreviousCritical)
	}
}
Test("corpus: the context buffer replays every shared case (corpus-request-plan)", _CTRP_Context)
