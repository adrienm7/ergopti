; tests/fixtures/native_owned_button.ahk

; ==============================================================================
; MODULE: Owned Native Button Test Transport
; DESCRIPTION:
; Delivers a semantic click to a verified private Button HWND. The real native
; window procedure emits BN_CLICKED and the production OnEvent remains intact.
; ==============================================================================

#Requires AutoHotkey v2.0

_TestClickOwnedNativeButton(OwnerGui, ButtonHwnd) {
	if !(OwnerGui is Gui) || !(ButtonHwnd is Integer) || ButtonHwnd <= 0
		throw TypeError("A native button action requires its exact GUI and control HWND.")
	OwnerHwnd := OwnerGui.Hwnd
	OwnerPid := 0, ButtonPid := 0
	OwnerThread := DllCall("GetWindowThreadProcessId", "Ptr", OwnerHwnd, "UInt*", &OwnerPid, "UInt")
	ButtonThread := DllCall("GetWindowThreadProcessId", "Ptr", ButtonHwnd, "UInt*", &ButtonPid, "UInt")
	CurrentPid := DllCall("GetCurrentProcessId", "UInt")
	CurrentThread := DllCall("GetCurrentThreadId", "UInt")
	ClassBuffer := Buffer(128, 0)
	ClassLength := DllCall("GetClassNameW", "Ptr", ButtonHwnd, "Ptr", ClassBuffer, "Int", 64, "Int")
	if !DllCall("IsWindow", "Ptr", OwnerHwnd, "Int")
		|| !DllCall("IsWindow", "Ptr", ButtonHwnd, "Int")
		|| OwnerPid != CurrentPid || ButtonPid != CurrentPid
		|| OwnerThread != CurrentThread || ButtonThread != CurrentThread
		|| DllCall("GetParent", "Ptr", ButtonHwnd, "Ptr") != OwnerHwnd
		|| ClassLength != 6 || !(StrGet(ClassBuffer) == "Button")
		|| !DllCall("IsWindowVisible", "Ptr", OwnerHwnd, "Int")
		|| !DllCall("IsWindowVisible", "Ptr", ButtonHwnd, "Int")
		|| !DllCall("IsWindowEnabled", "Ptr", ButtonHwnd, "Int")
		throw Error("The semantic click cannot target an unowned, hidden or disabled native Button.")
	; ControlClick posts separate mouse-down/up messages and acknowledges only
	; their enqueue. BM_CLICK executes the actual Button procedure directly;
	; the business assertions still prove its later OnEvent, not this send ACK.
	Reply := Buffer(A_PtrSize, 0)
	Sent := DllCall("user32\SendMessageTimeoutW", "Ptr", ButtonHwnd, "UInt", 0xF5,
		"UPtr", 0, "Ptr", 0, "UInt", 0x2, "UInt", 1000, "Ptr", Reply, "Ptr")
	if !Sent
		throw OSError(A_LastError, "SendMessageTimeoutW", "The owned native BM_CLICK send was not acknowledged.")
	return Map("transport", "semantic-native-bm-click", "parent_hwnd", OwnerHwnd,
		"control_hwnd", ButtonHwnd, "native_message", 0xF5, "send_ack", 1,
		"native_reply", NumGet(Reply, 0, "UPtr"))
}
