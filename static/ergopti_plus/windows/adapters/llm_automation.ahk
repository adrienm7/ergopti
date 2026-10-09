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
	SetTimer(_LLM_Automation_Accept, -1)
	return 1
}

; Listens for the automation request exactly while the bridge is active.
_LLM_Automation_Listen(Enabled) {
	OnMessage(LLM_Automation_AcceptMessage(), _LLM_Automation_OnAcceptMessage,
		Enabled ? 1 : 0)
}
