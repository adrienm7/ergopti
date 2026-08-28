; tests/unit/test_llm_pointer_watch_transaction.ahk

; ==============================================================================
; MODULE: LLM Pointer Watch Transaction Tests
; DESCRIPTION:
; Proves that pointer-dismiss observation publishes ownership only after every
; dispatcher subscription, direct hotkey, and timer has been acquired. Any
; intermediate failure must unwind the exact partial resource set and remain
; observable to bridge lifecycle callers.
; ==============================================================================

#Requires AutoHotkey v2.0

global _LPWT_Trace := []
global _LPWT_FailStage := ""

_LPWT_Register(EventType, Callback) {
	global _LPWT_Trace, _LPWT_FailStage, _LLM_PointerWatch_Armed
	AssertFalse(_LLM_PointerWatch_Armed,
		"the pointer watcher must not publish armed before every resource exists")
	_LPWT_Trace.Push("register:" . EventType)
	if (_LPWT_FailStage == "register" && _LPWT_Trace.Length == 3)
		throw Error("injected register failure")
}

_LPWT_Unregister(EventType, Callback) {
	global _LPWT_Trace
	_LPWT_Trace.Push("unregister:" . EventType)
}

_LPWT_Hotkey(KeyName, Callback, Mode) {
	global _LPWT_Trace, _LLM_PointerWatch_Armed
	AssertFalse(_LLM_PointerWatch_Armed,
		"direct hotkeys must be installed before publishing armed")
	_LPWT_Trace.Push("hotkey:" . KeyName . ":" . Mode)
}

_LPWT_Timer(Callback, Period) {
	global _LPWT_Trace, _LPWT_FailStage, _LLM_PointerWatch_Armed
	AssertFalse(_LLM_PointerWatch_Armed,
		"the move timer must be installed before publishing armed")
	_LPWT_Trace.Push("timer:" . Period)
	if (_LPWT_FailStage == "timer" && Period > 0)
		throw Error("injected timer failure")
}

_LPWT_Port() {
	return Map(
		"register", _LPWT_Register,
		"unregister", _LPWT_Unregister,
		"hotkey", _LPWT_Hotkey,
		"timer", _LPWT_Timer)
}

_LPWT_Reset(FailStage) {
	global _LPWT_Trace, _LPWT_FailStage, _LLM_PointerWatch_Armed
	global _LLM_PointerWatch_MoveFn, _LLM_PointerWatch_ActivityFn
	_LPWT_Trace := []
	_LPWT_FailStage := FailStage
	_LLM_PointerWatch_Armed := false
	_LLM_PointerWatch_MoveFn := unset
	_LLM_PointerWatch_ActivityFn := unset
}

_LPWT_RegisterFailureRollsBack() {
	global _LPWT_Trace, _LLM_PointerWatch_Armed
	_LPWT_Reset("register")
	Thrown := false
	try _LLM_PointerWatch_Start(_LPWT_Port())
	catch
		Thrown := true
	AssertTrue(Thrown,
		"a pointer subscription failure must remain observable to lifecycle")
	AssertFalse(_LLM_PointerWatch_Armed,
		"a partial pointer watcher must never retain the armed latch")
	AssertEqual(5, _LPWT_Trace.Length,
		"the failed third registration must roll back both prior subscriptions")
	Assert(InStr(_LPWT_Trace[4], "unregister:") == 1
			&& InStr(_LPWT_Trace[5], "unregister:") == 1,
		"registered pointer events must be retired after partial admission")
}

Test("llm pointer watcher: registration failure rolls back ownership (llm-pointer-watch-transaction)",
	_LPWT_RegisterFailureRollsBack)

_LPWT_TimerFailureRollsBack() {
	global _LPWT_Trace, _LLM_PointerWatch_Armed
	_LPWT_Reset("timer")
	Thrown := false
	try _LLM_PointerWatch_Start(_LPWT_Port())
	catch
		Thrown := true
	AssertTrue(Thrown,
		"a move-timer failure must remain observable to lifecycle")
	AssertFalse(_LLM_PointerWatch_Armed,
		"timer admission failure must leave the watcher restartable")
	Assert(InStr(_LPWT_Trace[-1], "unregister:") == 1,
		"timer failure must retire every dispatcher subscription")
	Assert(InStr(_LPWT_Trace[-9], "hotkey:~XButton2:Off") == 1
			&& InStr(_LPWT_Trace[-8], "hotkey:~XButton1:Off") == 1,
		"timer failure must retire both direct hotkeys")
}

Test("llm pointer watcher: timer failure rolls back every owner (llm-pointer-watch-transaction)",
	_LPWT_TimerFailureRollsBack)
