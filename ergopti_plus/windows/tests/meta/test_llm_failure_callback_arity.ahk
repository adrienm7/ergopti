; tests/meta/test_llm_failure_callback_arity.ahk
#Requires AutoHotkey v2.0

Test_LLMFailureCallbackAcceptsParseErrorPayload() {
	Dispatch := _DriverFuncBody("_LLM_Engine_DispatchVariant")
	Fail := _DriverFuncBody("_LLM_Engine_OnVariantFail")
	Assert(InStr(Dispatch, '(failure := "") => _LLM_Engine_OnVariantFail(state_ref, failure)') > 0,
		"LLM variant failure callback must accept the parser's structured error payload")
	Assert(InStr(Fail, '_LLM_Engine_OnVariantFail(state, failure := "")') > 0,
		"variant failure handler must declare an optional failure payload")
	Assert(InStr(Fail, "failure is Map") > 0,
		"structured parser failure must be logged, not swallowed by callback arity")
}
Test("LLM: parse-failure callback accepts its structured payload", Test_LLMFailureCallbackAcceptsParseErrorPayload)
