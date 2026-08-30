; adapters/uia_worker.ahk

; ==============================================================================
; MODULE: UIA Probe Worker Adapter
; DESCRIPTION:
; Owns every Win32/process/UIA operation used by the disposable selection,
; password and focused-element-bounds probes. Resident modules keep only
; request ownership and cache policy; this adapter owns cross-process transport,
; unsafe provider calls and the minimal source-mode worker entry.
; ==============================================================================

#Requires AutoHotkey v2.0+





; ==================================
; ==================================
; ======= 1/ Protocol state ========
; ==================================
; ==================================

global UIASW_READY_RETRY_MS := 50
global UIASW_SEND_TIMEOUT_MS := 25
global UIASW_MAX_TEXT_CHARS := 8192
; Transport discriminators outside the valid selection-length domain.
; PostMessage gives the worker only one integer payload field, so these values
; request typed probes while 1..UIASW_MAX_TEXT_CHARS remain selection requests.
global UIASW_PASSWORD_REQUEST_CODE := UIASW_MAX_TEXT_CHARS + 1
global UIASW_BOUNDS_REQUEST_CODE := UIASW_MAX_TEXT_CHARS + 2

class UIASWWorkerState {
	; A ready send can arrive while the parent is temporarily uninterruptible.
	; Retry until its WM_COPYDATA handler returns the explicit acknowledgement;
	; the parent startup watchdog remains the final bound.
	static ready_acknowledged := false
}

UIASW_RequestMessage() {
	static MessageId := DllCall("User32\RegisterWindowMessageW",
		"Str", "Ergopti.UIA.Selection.Request.v1", "UInt")
	return MessageId
}

UIASW_IsWorkerInvocation() {
	for _, Arg in A_Args {
		if (Arg = "--uia-selection-worker")
			return true
	}
	return false
}





; ======================================
; ======================================
; ======= 2/ Resident Win32 port =======
; ======================================
; ======================================

UIAW_CloseProcessHandle(ProcessHandle) {
	if !ProcessHandle
		return true
	return DllCall("Kernel32\CloseHandle", "Ptr", ProcessHandle, "Int") != 0
}

UIAW_WorkerParentPid(ProcessHandle) {
	; PROCESS_BASIC_INFORMATION is six pointer-sized fields; the final field is
	; InheritedFromUniqueProcessId. Querying the already-open child handle avoids
	; WMI/COM and binds the ready HWND to ShellRunner's still-live cmd wrapper.
	Info := Buffer(6 * A_PtrSize, 0)
	ReturnLength := 0
	Status := DllCall("Ntdll\NtQueryInformationProcess",
		"Ptr", ProcessHandle, "UInt", 0,
		"Ptr", Info.Ptr, "UInt", Info.Size,
		"UInt*", &ReturnLength, "Int")
	return Status = 0 ? NumGet(Info, 5 * A_PtrSize, "UPtr") : 0
}

UIAW_OpenVerifiedWorkerProcess(WorkerHwnd, ExpectedParentPid,
		RejectedReleaseFn) {
	if !HasMethod(RejectedReleaseFn, "Call")
		throw TypeError("RejectedReleaseFn must own rejected process handles.")
	if !WorkerHwnd || !ExpectedParentPid
		return 0
	WorkerPid := 0
	DllCall("User32\GetWindowThreadProcessId", "Ptr", WorkerHwnd,
		"UInt*", &WorkerPid, "UInt")
	if !WorkerPid
		return 0
	; PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION = 0x1001.
	ProcessHandle := DllCall("Kernel32\OpenProcess", "UInt", 0x1001,
		"Int", false, "UInt", WorkerPid, "Ptr")
	if !ProcessHandle
		return 0
	if UIAW_WorkerParentPid(ProcessHandle) != ExpectedParentPid {
		RejectedReleaseFn.Call(ProcessHandle)
		return 0
	}
	return ProcessHandle
}

UIAW_TerminateProcessHandle(ProcessHandle) {
	return DllCall("Kernel32\TerminateProcess",
		"Ptr", ProcessHandle, "UInt", 1, "Int") != 0
}

UIAW_PostRequest(WorkerHwnd, RequestGeneration, MaxTextChars) {
	if !WorkerHwnd
		return false
	return DllCall("User32\PostMessageW", "Ptr", WorkerHwnd,
		"UInt", UIASW_RequestMessage(), "UPtr", RequestGeneration,
		"Ptr", MaxTextChars, "Int") != 0
}





; =====================================
; =====================================
; ======= 3/ Worker process ===========
; =====================================
; =====================================

UIASW_WorkerSendReady(ParentHwnd, WorkerGeneration) {
	global UIASW_SEND_TIMEOUT_MS
	Data := Buffer((StrLen(WorkerGeneration) + 1) * 2, 0)
	StrPut(WorkerGeneration, Data, "UTF-16")
	StructSize := (A_PtrSize = 8) ? 24 : 12
	CopyData := Buffer(StructSize, 0)
	; dwData = 0 is the ready tag. Real request generations start at one.
	NumPut("UPtr", 0, CopyData, 0)
	NumPut("UInt", Data.Size, CopyData, A_PtrSize)
	NumPut("Ptr", Data.Ptr, CopyData, (A_PtrSize = 8) ? 16 : 8)
	Result := 0
	; WM_COPYDATA is the same bounded, cross-process channel as normal results. A
	; successful parent claim returns 1; timeout/rejection simply causes a retry
	; until the parent-owned startup watchdog expires and terminates this process.
	Sent := DllCall("User32\SendMessageTimeoutW",
		"Ptr", ParentHwnd, "UInt", 0x004A,
		"UPtr", A_ScriptHwnd, "Ptr", CopyData.Ptr,
		"UInt", 0x0003, "UInt", UIASW_SEND_TIMEOUT_MS,
		"UPtr*", &Result, "Ptr")
	return Sent != 0 && Result = 1
}

UIASW_WorkerMain() {
	global UIASW_READY_RETRY_MS
	if !UIASW_IsWorkerInvocation()
		return false
	if (A_Args.Length < 3)
		ExitApp(2)
	try {
		ParentHwnd := Integer(A_Args[2])
		WorkerGeneration := Integer(A_Args[3])
	} catch {
		ExitApp(2)
	}
	if !ParentHwnd || !DllCall("User32\IsWindow", "Ptr", ParentHwnd, "Int")
		ExitApp(2)

	UIASWWorkerState.ready_acknowledged := false
	OnMessage(UIASW_RequestMessage(), UIASW_WorkerHandleRequest.Bind(ParentHwnd))
	while DllCall("User32\IsWindow", "Ptr", ParentHwnd, "Int") {
		if !UIASWWorkerState.ready_acknowledged {
			UIASWWorkerState.ready_acknowledged := UIASW_WorkerSendReady(
				ParentHwnd, WorkerGeneration)
			Sleep(UIASW_READY_RETRY_MS)
		} else {
			Sleep(250)
		}
	}
	ExitApp(0)
}

UIASW_WorkerHandleRequest(ParentHwnd, RequestGeneration, RequestCode, Msg, ReceiverHwnd) {
	global UIASW_MAX_TEXT_CHARS, UIASW_PASSWORD_REQUEST_CODE
	global UIASW_BOUNDS_REQUEST_CODE
	try RequestCode := Integer(RequestCode)
	catch {
		UIASW_WorkerSendResult(ParentHwnd, RequestGeneration,
			"failed`n0`n0`nInvalid request code.")
		return 0
	}
	StartHwnd := DllCall("User32\GetForegroundWindow", "Ptr")
	StartControl := WIGetFocusedControlToken()
	Status := "empty"
	Body := ""
	try {
		if !IsSet(UIA)
			throw Error("UIA library is unavailable.")
		Element := UIA.GetFocusedElement()
		if (RequestCode = UIASW_PASSWORD_REQUEST_CODE) {
			ElementId := Element.RuntimeId
			if !(ElementId is String) || ElementId = ""
				throw Error("Focused UIA element has no RuntimeId.")
			Secure := Element.GetCurrentPropertyValue(UIA.Property.IsPassword)
			Body := (Secure ? "1" : "0") . "`n" . ElementId
			Status := "ok"
		} else if (RequestCode = UIASW_BOUNDS_REQUEST_CODE) {
			Rect := Element.BoundingRectangle
			Body := Rect.l . "`n" . Rect.t . "`n" . Rect.r . "`n" . Rect.b
			Status := "ok"
		} else {
			MaxTextChars := Min(Max(1, RequestCode), UIASW_MAX_TEXT_CHARS)
			if !Element.IsTextPatternAvailable {
				Status := "no_text_pattern"
			} else {
				Pattern := Element.GetPattern("Text")
				Ranges := Pattern.GetSelection()
				if (Ranges.Length > 0) {
					Body := Ranges[1].GetText(MaxTextChars)
					if (Body != "" && !RegExMatch(Body, "^(\r\n|\r|\n)+$"))
						Status := "ok"
				}
			}
		}
	} catch as Err {
		Status := "failed"
		Body := StrReplace(StrReplace(Err.Message, "`r", " "), "`n", " ")
	}
	EndHwnd := DllCall("User32\GetForegroundWindow", "Ptr")
	EndControl := WIGetFocusedControlToken()
	if !StartHwnd || !StartControl || StartHwnd != EndHwnd || StartControl != EndControl {
		Status := "stale"
		Body := ""
	}
	Payload := Status . "`n" . StartHwnd . "`n" . StartControl . "`n" . Body
	UIASW_WorkerSendResult(ParentHwnd, RequestGeneration, Payload)
	return 0
}

UIASW_WorkerSendResult(ParentHwnd, RequestGeneration, Payload) {
	global UIASW_SEND_TIMEOUT_MS
	Data := Buffer((StrLen(Payload) + 1) * 2, 0)
	StrPut(Payload, Data, "UTF-16")
	StructSize := (A_PtrSize = 8) ? 24 : 12
	CopyData := Buffer(StructSize, 0)
	NumPut("UPtr", RequestGeneration, CopyData, 0)
	NumPut("UInt", Data.Size, CopyData, A_PtrSize)
	NumPut("Ptr", Data.Ptr, CopyData, (A_PtrSize = 8) ? 16 : 8)
	Result := 0
	return DllCall("User32\SendMessageTimeoutW",
		"Ptr", ParentHwnd, "UInt", 0x004A,
		"UPtr", A_ScriptHwnd, "Ptr", CopyData.Ptr,
		"UInt", 0x0003, "UInt", UIASW_SEND_TIMEOUT_MS,
		"UPtr*", &Result, "Ptr") != 0
}
