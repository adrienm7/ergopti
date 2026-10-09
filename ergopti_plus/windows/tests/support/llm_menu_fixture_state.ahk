; tests/support/llm_menu_fixture_state.ahk

; ==============================================================================
; MODULE: LLM Menu Fixture State Ownership
; DESCRIPTION:
; Both menu fixtures restore the same callback-owned state. Object references
; are retained so restoring an outer fixture also restores its journal identity.
; ==============================================================================

#Requires AutoHotkey v2.0

_LMT_CaptureFixtureState() {
	global _LMT_WriterResult, _LMT_WriterCalls, _LMT_ApplyCalls
	global _LMT_WriterCritical, _LMT_ApplyCritical, _LMT_LiveAtWrite
	global _LMT_ConfigPath, _LMT_ApiPath, _LMT_ApiRefused
	global _LMT_PrepareResult, _LMT_PrepareCalls, _LMT_PublishCalls, _LMT_Events
	return Map("writer_result", _LMT_WriterResult, "writer_calls", _LMT_WriterCalls,
		"apply_calls", _LMT_ApplyCalls, "writer_critical", _LMT_WriterCritical,
		"apply_critical", _LMT_ApplyCritical, "live_at_write", _LMT_LiveAtWrite,
		"config_path", _LMT_ConfigPath, "api_path", _LMT_ApiPath,
		"api_refused", _LMT_ApiRefused, "prepare_result", _LMT_PrepareResult,
		"prepare_calls", _LMT_PrepareCalls, "publish_calls", _LMT_PublishCalls,
		"events", _LMT_Events)
}

_LMT_RestoreFixtureState(State) {
	global _LMT_WriterResult, _LMT_WriterCalls, _LMT_ApplyCalls
	global _LMT_WriterCritical, _LMT_ApplyCritical, _LMT_LiveAtWrite
	global _LMT_ConfigPath, _LMT_ApiPath, _LMT_ApiRefused
	global _LMT_PrepareResult, _LMT_PrepareCalls, _LMT_PublishCalls, _LMT_Events
	_LMT_WriterResult := State["writer_result"]
	_LMT_WriterCalls := State["writer_calls"]
	_LMT_ApplyCalls := State["apply_calls"]
	_LMT_WriterCritical := State["writer_critical"]
	_LMT_ApplyCritical := State["apply_critical"]
	_LMT_LiveAtWrite := State["live_at_write"]
	_LMT_ConfigPath := State["config_path"]
	_LMT_ApiPath := State["api_path"]
	_LMT_ApiRefused := State["api_refused"]
	_LMT_PrepareResult := State["prepare_result"]
	_LMT_PrepareCalls := State["prepare_calls"]
	_LMT_PublishCalls := State["publish_calls"]
	_LMT_Events := State["events"]
}
