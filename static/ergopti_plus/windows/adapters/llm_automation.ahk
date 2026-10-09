; adapters/llm_automation.ahk

; ==============================================================================
; MODULE: LLM automation request
; DESCRIPTION:
; The Win32 side of the third canonical acceptance primitive
; (llm-automation-accepts): the registered window message an external program
; posts to the driver to insert the shown prediction, and its listener. The
; policy and the insertion stay in modules/keymap/llm_bridge.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0

global _LLM_Automation_Generation := 0
global _LLM_Automation_Pending := 0
global _LLM_Automation_Listening := false

/**
 * Message an external program posts to the driver's window to insert the
 * shown prediction, for screen-recording demos and assistive tools. No key,
 * gesture, macro or text send of the driver can produce it, so the rule that
 * only the user's own Tab key accepts still holds on every keyboard path.
 * @returns {Integer} The registered message number.
 */
LLM_Automation_AcceptMessage() {
	static MessageId := DllCall("User32\RegisterWindowMessageW",
		"Str", "Ergopti.LLM.AcceptPrediction.v1", "UInt")
	if !MessageId
		throw OSError(A_LastError, -1,
			"RegisterWindowMessage failed for the prediction-accept message")
	return MessageId
}

; Message handler: acknowledges the request and leaves the message thread
; before the injection, which yields while the sender completes.
_LLM_Automation_OnAcceptMessage(wParam, lParam, Msg, Hwnd) {
	if A_IsSuspended || !_LLM_Bridge_Active
		return 0
	return IsObject(_LLM_Automation_Queue(LLM_Tooltip_GetAcceptSnapshot())) ? 1 : 0
}

; Queues one exact render. A timer is never permission to accept a later offer.
_LLM_Automation_Queue(Presented, TimerFn := unset) {
	global _LLM_Automation_Generation, _LLM_Automation_Pending
	PreviousCritical := Critical("On")
	try {
		if A_IsSuspended || !_LLM_Bridge_Active
			return 0
		if !IsObject(Presented)
			return 0
		_LLM_Automation_CancelPending()
		if !IsSet(TimerFn)
			TimerFn := (Callback, Period) => SetTimer(Callback, Period)
		State := { Presented: Presented, Generation: _LLM_Automation_Generation, TimerFn: TimerFn, Cancelled: false }
		State.Callback := _LLM_Automation_Accept.Bind(State)
		_LLM_Automation_Pending := State
		try TimerFn.Call(State.Callback, -1)
		catch as FirstError {
			try _LLM_Automation_CancelPending()
			catch as CleanupError {
				try LoggerError("LLM", "Automation timer retirement also failed: {1}.", CleanupError.Message)
			}
			throw FirstError
		}
		return State
	} finally {
		Critical(PreviousCritical)
	}
}

; A failed disarm keeps the exact callback rooted for retry, already epoch-fenced.
_LLM_Automation_CancelPending() {
	global _LLM_Automation_Pending
	PreviousCritical := Critical("On")
	try {
		State := _LLM_Automation_Pending
		if !IsObject(State)
			return
		State.Cancelled := true
		State.TimerFn.Call(State.Callback, 0)
		_LLM_Automation_Pending := 0
		State.Callback := 0
	} finally {
		Critical(PreviousCritical)
	}
}

; Native boundary collaborators are injectable only for deterministic unit tests.
_LLM_Automation_Listen(Enabled, Port := 0) {
	global _LLM_Automation_Generation, _LLM_Automation_Listening
	PreviousCritical := Critical("On")
	try {
		_LLM_Automation_Generation += 1
		_LLM_Automation_CancelPending()
		if !Enabled && !_LLM_Automation_Listening
			return
		if Enabled && _LLM_Automation_Listening
			throw Error("The prediction automation listener is already active.")
		if !(Port is Map)
			Port := Map("message", LLM_Automation_AcceptMessage,
				"listen", (Message, Callback, Threads) => OnMessage(Message, Callback, Threads))
		Message := Port["message"].Call()
		if Enabled
			_LLM_Automation_Listening := true
		Port["listen"].Call(Message, _LLM_Automation_OnAcceptMessage, Enabled ? 1 : 0)
		if !Enabled
			_LLM_Automation_Listening := false
	} finally {
		Critical(PreviousCritical)
	}
}

; Registration failure must retire the started bridge and retain the first error.
_LLM_Automation_StartListener(Port := 0, StopFn := unset) {
	global _LLM_Bridge_Active
	try _LLM_Automation_Listen(true, Port)
	catch as FirstError {
		try {
			if IsSet(StopFn)
				StopFn.Call()
			else
				LLM_Bridge_Stop()
		} catch as CleanupError {
			try LoggerError("LLM", "Automation listener cleanup also failed: {1}.", CleanupError.Message)
		} finally {
			_LLM_Bridge_Active := false
		}
		throw FirstError
	}
}
