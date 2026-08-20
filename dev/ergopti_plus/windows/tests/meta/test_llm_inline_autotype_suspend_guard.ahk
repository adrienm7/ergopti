; tests/meta/test_llm_inline_autotype_suspend_guard.ahk
#Requires AutoHotkey v2.0

Test_LLMInlineAutotypeChecksSuspendBeforeTextSend() {
	Body := _DriverFuncBody("LLM_Engine_OnResults")
	SuspendPos := InStr(Body, "if A_IsSuspended")
	TextSendPos := InStr(Body, "TextSend(text, _LLM_Bridge_InjectionOptions(Transaction)")
	Assert(SuspendPos > 0 and TextSendPos > 0 and SuspendPos < TextSendPos,
		"inline auto-type must reject a suspended result before TextSend")
}
Test("LLM: inline auto-type checks suspend immediately before TextSend", Test_LLMInlineAutotypeChecksSuspendBeforeTextSend)
