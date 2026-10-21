; tests/unit/platform/network/test_managed_curl_empty_header.ahk

; ==============================================================================
; MODULE: Managed curl Empty Header Serialization Tests
; DESCRIPTION:
; curl reads a configured header written "Name:" with nothing after the colon
; as "remove this header", so a caller's present-but-empty field never reached
; the wire. curl's "Name;" form sends it with an empty value. The real managed
; transport (worker, capability observation and curl) sends one request to a
; private loopback listener, which records the exact request head; empty and
; space-only fields must arrive empty, ordinary fields unchanged.
; ==============================================================================

#Requires AutoHotkey v2.0

class _MCEH_Listener {
	__New() {
		Data := Buffer(512, 0)
		if DllCall("Ws2_32\WSAStartup", "UShort", 0x202, "Ptr", Data, "Int") != 0
			throw Error("the fixture must acquire its own Winsock reference")
		this.Socket := -1, this.Peer := -1, this.Head := "", this.Answered := false
		this.Socket := DllCall("Ws2_32\socket", "Int", 2, "Int", 1, "Int", 6, "Ptr")
		if this.Socket == -1
			throw Error("the private listener socket must open")
		Address := Buffer(16, 0)
		NumPut("UShort", 2, Address, 0)
		NumPut("UChar", 127, Address, 4)
		NumPut("UChar", 1, Address, 7)
		if DllCall("Ws2_32\bind", "Ptr", this.Socket, "Ptr", Address, "Int", Address.Size, "Int") != 0
			throw Error("the private listener must bind loopback")
		Length := Address.Size
		DllCall("Ws2_32\getsockname", "Ptr", this.Socket, "Ptr", Address, "Int*", &Length, "Int")
		this.Port := NumGet(Address, 2, "UChar") * 256 + NumGet(Address, 3, "UChar")
		DllCall("Ws2_32\listen", "Ptr", this.Socket, "Int", 1, "Int")
		NonBlocking := 1
		DllCall("Ws2_32\ioctlsocket", "Ptr", this.Socket, "UInt", 0x8004667E, "UInt*", &NonBlocking, "Int")
	}

	; One nonblocking step: accept, read the request head, then answer once.
	Pump() {
		if this.Answered
			return
		if this.Peer == -1 {
			this.Peer := DllCall("Ws2_32\accept", "Ptr", this.Socket, "Ptr", 0, "Ptr", 0, "Ptr")
			if this.Peer == -1
				return
		}
		Chunk := Buffer(4096, 0)
		Received := DllCall("Ws2_32\recv", "Ptr", this.Peer, "Ptr", Chunk, "Int", Chunk.Size, "Int", 0, "Int")
		if Received > 0
			this.Head .= StrGet(Chunk, Received, "UTF-8")
		if !InStr(this.Head, "`r`n`r`n")
			return
		Reply := "HTTP/1.1 200 OK`r`nContent-Length: 2`r`nConnection: close`r`n`r`nok"
		Bytes := Buffer(StrPut(Reply, "UTF-8"))
		Count := StrPut(Reply, Bytes, "UTF-8") - 1
		DllCall("Ws2_32\send", "Ptr", this.Peer, "Ptr", Bytes, "Int", Count, "Int", 0, "Int")
		this.Answered := true
	}

	Close() {
		if this.Peer != -1
			DllCall("Ws2_32\closesocket", "Ptr", this.Peer)
		if this.Socket != -1
			DllCall("Ws2_32\closesocket", "Ptr", this.Socket)
		this.Peer := -1, this.Socket := -1
		DllCall("Ws2_32\WSACleanup")
	}
}

; Direct routing: no PAC, no proxy, so the request goes straight to loopback.
_MCEH_DirectSettings() {
	return Map("auto_detect", false, "pac_url", "", "proxy", "", "bypass", "")
}

_MCEH_HeaderLines(Head) {
	Lines := Map()
	Lines.CaseSense := "Off"
	for Line in StrSplit(Head, "`r`n") {
		Colon := InStr(Line, ":")
		if Colon > 1
			Lines[SubStr(Line, 1, Colon - 1)] := SubStr(Line, Colon + 1)
	}
	return Lines
}

; Managed: the production worker. Legacy: the explicit-spawn serializer that
; the dispatch-port owners still use; both must write the same header lines.
_MCEH_EmptyFieldsReachTheWire(Mode) {
	Listener := _MCEH_Listener()
	Request := 0
	try {
		if Mode == "managed" {
			Request := CurlAsyncRequest()
			Request.SetManagedRouting(_MCEH_DirectSettings)
		} else
			Request := CurlAsyncRequest(Map("spawn", ShellRunner_SpawnTreeOwned))
		Request.SetDeadline(A_TickCount, 30000)
		Request.Open("GET", "http://127.0.0.1:" . Listener.Port . "/empty-header", true)
		Request.SetRequestHeader("X-Ergopti-Empty", "")
		Request.SetRequestHeader("X-Ergopti-Spaces", "   ")
		Request.SetRequestHeader("X-Ergopti-Plain", "kept value")
		AssertTrue(Request.Send(), "the managed request must dispatch")
		Begin := A_TickCount
		while !Request.WaitForResponse(0) && TickElapsed(Begin) < 30000 {
			Listener.Pump()
			Sleep(10)
		}
		AssertTrue(Listener.Answered, "the private listener must receive the complete request head")
		AssertTrue(Request.WaitForResponse(0), "the managed request must complete")
		AssertEqual(200, Request.Status, "the managed request must observe the loopback answer")
		Fields := _MCEH_HeaderLines(Listener.Head)
		AssertTrue(Fields.Has("X-Ergopti-Empty"), "an empty header value must still be sent")
		AssertEqual("", Trim(Fields.Get("X-Ergopti-Empty", "<absent>")), "the empty header must arrive empty")
		AssertTrue(Fields.Has("X-Ergopti-Spaces"), "a space-only header value must still be sent")
		AssertEqual("", Trim(Fields.Get("X-Ergopti-Spaces", "<absent>")), "a space-only header must arrive empty")
		AssertEqual("kept value", Trim(Fields.Get("X-Ergopti-Plain", "<absent>")), "an ordinary header must arrive unchanged")
	} finally {
		if IsObject(Request) && !Request.Completed
			Request.Abort()
		Listener.Close()
	}
}
Test("managed curl: empty and space-only header values reach the wire (managed-curl-empty-header)",
	_MCEH_EmptyFieldsReachTheWire.Bind("managed"))
Test("legacy curl: empty and space-only header values reach the wire (managed-curl-empty-header)",
	_MCEH_EmptyFieldsReachTheWire.Bind("legacy"))
