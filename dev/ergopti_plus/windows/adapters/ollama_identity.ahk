; adapters/ollama_identity.ahk

; ==============================================================================
; MODULE: Managed Ollama Native Identity
; DESCRIPTION:
; Reopens the captured foreground process without termination rights and binds
; its creation FILETIME, executable image and IPv4 listener before HTTP dispatch.
; A cached READY file cannot grant authority to a recycled PID or replacement server.
; ==============================================================================

#Requires AutoHotkey v2.0

global _OllamaIdentityPendingHandles := Map()

/** Retries refused handle retirement without discarding the exact native owner. */
OllamaNativeIdentityDrain() {
	global _OllamaIdentityPendingHandles
	for Handle in _OllamaIdentityPendingHandles.Clone() {
		if DllCall("CloseHandle", "Ptr", Handle, "Int")
			_OllamaIdentityPendingHandles.Delete(Handle)
	}
	return _OllamaIdentityPendingHandles.Count == 0
}

/** Includes failed probe-handle cleanup even after the foreground task exits. */
OllamaNativeIdentityHasDebt() {
	global _OllamaIdentityPendingHandles
	return _OllamaIdentityPendingHandles.Count != 0
}

/** Returns true only for the still-live exact captured foreground listener. */
OllamaNativeIdentityReady(Receipt, Target) {
	global _OllamaIdentityPendingHandles
	if !OllamaNativeIdentityDrain()
		return false
	if !(Receipt is Map) || !(Target is Map)
		return false
	Pid := Receipt.Get("child_pid", 0)
	Created := Receipt.Get("child_created_filetime", 0)
	Port := Target.Get("port", 0)
	if !(Pid is Integer) || Pid <= 0 || !(Created is Integer) || Created <= 0
			|| !(Port is Integer) || Port < 1 || Port > 65535
			|| Target.Get("origin", "") != "http://127.0.0.1:" . Port
		return false
	Handle := DllCall("OpenProcess", "UInt", 0x00101000, "Int", false, "UInt", Pid, "Ptr")
	if !Handle
		return false
	try {
		if DllCall("WaitForSingleObject", "Ptr", Handle, "UInt", 0, "UInt") != 0x102
			return false
		Times := Buffer(32, 0)
		if !DllCall("GetProcessTimes", "Ptr", Handle, "Ptr", Times.Ptr, "Ptr", Times.Ptr + 8,
				"Ptr", Times.Ptr + 16, "Ptr", Times.Ptr + 24, "Int") || NumGet(Times, 0, "Int64") != Created
			return false
		Length := 32768
		Image := Buffer(Length * 2, 0)
		if !DllCall("QueryFullProcessImageNameW", "Ptr", Handle, "UInt", 0,
				"Ptr", Image, "UInt*", &Length, "Int")
				|| StrGet(Image, Length, "UTF-16") != StrReplace(Target.Get("executable", ""), "/", "\")
			return false
		Size := 0
		Status := DllCall("Iphlpapi\GetExtendedTcpTable", "Ptr", 0, "UInt*", &Size,
			"Int", false, "UInt", 2, "UInt", 3, "UInt", 0, "UInt")
		if Status != 122 || Size < 4 || Size > 16777216
			return false
		Table := Buffer(Size, 0)
		if DllCall("Iphlpapi\GetExtendedTcpTable", "Ptr", Table, "UInt*", &Size,
				"Int", false, "UInt", 2, "UInt", 3, "UInt", 0, "UInt") != 0 || Size < 4 || Size > Table.Size
			return false
		Count := NumGet(Table, 0, "UInt")
		if Count > Floor((Size - 4) / 24)
			return false
		Found := false
		loop Count {
			Offset := 4 + (A_Index - 1) * 24
			EncodedPort := NumGet(Table, Offset + 8, "UShort")
			RowPort := ((EncodedPort & 255) << 8) | (EncodedPort >> 8)
			if RowPort != Port
				continue
			Address := NumGet(Table, Offset + 4, "UInt")
			if Address == 0 || Address == 0x0100007F {
				if Address != 0x0100007F || NumGet(Table, Offset + 20, "UInt") != Pid
					return false
				Found := true
			}
		}
		return Found && DllCall("WaitForSingleObject", "Ptr", Handle, "UInt", 0, "UInt") == 0x102
	} finally {
		if !DllCall("CloseHandle", "Ptr", Handle, "Int") {
			_OllamaIdentityPendingHandles[Handle] := true
			throw OSError(A_LastError, "CloseHandle", "Managed listener identity handle retirement failed.")
		}
	}
}
