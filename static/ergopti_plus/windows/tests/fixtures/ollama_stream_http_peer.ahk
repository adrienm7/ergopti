; tests/fixtures/ollama_stream_http_peer.ahk

; ==============================================================================
; MODULE: Streaming HTTP Status Peer
; DESCRIPTION:
; Serves fixed synthetic HTTP responses to genuine Windows curl on an owned
; loopback listener, retaining only method, path and response status evidence.
; ==============================================================================

; Standalone private HTTP service for genuine Windows curl fixtures.
; Only method, path and status reach its transcript; payloads stay in RAM.
#Requires AutoHotkey v2.0
#SingleInstance Off

_R7HS_Error(Operation) {
	return Error(Operation . " failed (Winsock " . DllCall("Ws2_32\WSAGetLastError", "Int") . ").")
}

_R7HS_Request(Peer) {
	MAX_REQUEST_BYTES := 1048576
	MAX_HEADER_BYTES := 65536
	Raw := Buffer(0), HeaderEnd := 0, Expected := 0
	loop {
		Chunk := Buffer(4096)
		Count := DllCall("Ws2_32\recv", "Ptr", Peer, "Ptr", Chunk, "Int", Chunk.Size, "Int", 0, "Int")
		if Count < 0
			throw _R7HS_Error("Receiving the private HTTP request")
		if Count == 0
			throw Error("The peer closed before its complete HTTP request.")
		Before := Raw.Size
		if Before + Count > MAX_REQUEST_BYTES
			throw Error("The private HTTP request exceeded its fixture bound.")
		Next := Buffer(Before + Count)
		if Before
			DllCall("RtlMoveMemory", "Ptr", Next, "Ptr", Raw, "UPtr", Before)
		DllCall("RtlMoveMemory", "Ptr", Next.Ptr + Before, "Ptr", Chunk, "UPtr", Count)
		Raw := Next
		if !HeaderEnd {
			loop Max(0, Raw.Size - 3) {
				At := A_Index - 1
				if NumGet(Raw, At, "UChar") == 13 && NumGet(Raw, At + 1, "UChar") == 10
						&& NumGet(Raw, At + 2, "UChar") == 13 && NumGet(Raw, At + 3, "UChar") == 10 {
					HeaderEnd := At + 4
					break
				}
			}
			if !HeaderEnd {
				if Raw.Size > MAX_HEADER_BYTES
					throw Error("The private HTTP headers exceeded their fixture bound.")
				continue
			}
			Head := StrGet(Raw, HeaderEnd, "UTF-8")
			if !RegExMatch(Head, "^([A-Z]+) ([^ ]+) HTTP/1\.[01]`r`n", &Line)
				throw Error("The fixture received an invalid HTTP request line.")
			Length := 0
			if RegExMatch(Head, "im)^Content-Length:[ \t]*([0-9]+)[ \t]*`r?$", &Field)
				Length := Integer(Field[1])
			else if Line[1] != "GET"
				throw Error("The private POST must declare its complete payload length.")
			Expected := HeaderEnd + Length
			if Expected > MAX_REQUEST_BYTES
				throw Error("The declared HTTP payload exceeded its fixture bound.")
		}
		if Raw.Size >= Expected
			return Map("method", Line[1], "path", Line[2])
	}
}

_R7HS_Reply(Peer, Status, Body) {
	Reason := Status == 200 ? "OK" : "Fixture Response"
	Reply := "HTTP/1.1 " . Status . " " . Reason . "`r`nContent-Type: application/x-ndjson`r`n"
		. "Content-Length: " . (StrPut(Body, "UTF-8") - 1) . "`r`nConnection: close`r`n`r`n" . Body
	Bytes := Buffer(StrPut(Reply, "UTF-8"))
	Count := StrPut(Reply, Bytes, "UTF-8") - 1, Sent := 0
	while Sent < Count {
		Written := DllCall("Ws2_32\send", "Ptr", Peer, "Ptr", Bytes.Ptr + Sent, "Int", Count - Sent, "Int", 0, "Int")
		if Written <= 0
			throw _R7HS_Error("Sending the private HTTP response")
		Sent += Written
	}
	if DllCall("Ws2_32\shutdown", "Ptr", Peer, "Int", 1, "Int") != 0
		throw _R7HS_Error("Finishing the private HTTP response")
}

_R7HS_Main() {
	SERVER_TIMEOUT_MS := 15000
	if A_Args.Length != 4
		throw Error("The private service requires ready path, transcript path, status and body kind.")
	ReadyPath := A_Args[1], Transcript := A_Args[2], ChatStatus := Integer(A_Args[3])
	BodyKind := A_Args[4]
	if BodyKind != "done" && BodyKind != "matching" && BodyKind != "foreign" && BodyKind != "private" && BodyKind != "after-done"
		throw Error("The private service refused an unknown response body kind.")
	if BodyKind != "done" && BodyKind != "after-done" && ChatStatus != 404
		throw Error("Missing-model response controls require HTTP404.")
	if BodyKind == "after-done" && ChatStatus != 200
		throw Error("The terminal-closure control requires HTTP200.")
	AllowedStatuses := Map(200, true, 201, true, 299, true, 302, true, 400, true,
		401, true, 404, true, 429, true, 500, true, 503, true)
	if !AllowedStatuses.Has(ChatStatus)
		throw Error("The private service admits only its explicit status controls.")
	if FileExist(ReadyPath) || FileExist(ReadyPath . ".staging") || FileExist(Transcript)
		throw Error("The private HTTP evidence path is already occupied.")
	WsaOwned := false, Listener := -1, Peer := -1
	try {
		Data := Buffer(512, 0)
		if DllCall("Ws2_32\WSAStartup", "UShort", 0x202, "Ptr", Data, "Int") != 0
			throw Error("The private service could not acquire Winsock.")
		WsaOwned := true
		Listener := DllCall("Ws2_32\socket", "Int", 2, "Int", 1, "Int", 6, "Ptr")
		if Listener == -1
			throw _R7HS_Error("Opening the private listener")
		Address := Buffer(16, 0)
		NumPut("UShort", 2, Address, 0)
		NumPut("UChar", 127, Address, 4)
		NumPut("UChar", 1, Address, 7)
		if DllCall("Ws2_32\bind", "Ptr", Listener, "Ptr", Address, "Int", Address.Size, "Int") != 0
			throw _R7HS_Error("Binding the private loopback listener")
		Length := Address.Size
		if DllCall("Ws2_32\getsockname", "Ptr", Listener, "Ptr", Address, "Int*", &Length, "Int") != 0
			throw _R7HS_Error("Reading the actual bound port")
		Port := NumGet(Address, 2, "UChar") * 256 + NumGet(Address, 3, "UChar")
		if Port < 1 || Port > 65535
			throw Error("The native listener did not publish a valid port.")
		if DllCall("Ws2_32\listen", "Ptr", Listener, "Int", 1, "Int") != 0
			throw _R7HS_Error("Listening on the private loopback port")
		NonBlocking := 1
		if DllCall("Ws2_32\ioctlsocket", "Ptr", Listener, "UInt", 0x8004667E, "UInt*", &NonBlocking, "Int") != 0
			throw _R7HS_Error("Making the private listener deadline-aware")
		FileAppend(String(Port) . "`n", ReadyPath . ".staging", "UTF-8-RAW")
		FileMove(ReadyPath . ".staging", ReadyPath, false)
		Started := DllCall("Kernel32\GetTickCount64", "UInt64"), Requests := 0
		loop {
			if DllCall("Kernel32\GetTickCount64", "UInt64") - Started >= SERVER_TIMEOUT_MS
				throw Error("The private service did not receive its chat before the deadline.")
			Peer := DllCall("Ws2_32\accept", "Ptr", Listener, "Ptr", 0, "Ptr", 0, "Ptr")
			if Peer == -1 {
				if DllCall("Ws2_32\WSAGetLastError", "Int") != 10035
					throw _R7HS_Error("Accepting the private HTTP peer")
				Sleep(10)
				continue
			}
			try {
				Blocking := 0
				if DllCall("Ws2_32\ioctlsocket", "Ptr", Peer, "UInt", 0x8004667E, "UInt*", &Blocking, "Int") != 0
					throw _R7HS_Error("Owning the accepted peer's blocking mode")
				Timeout := Buffer(4)
				NumPut("UInt", SERVER_TIMEOUT_MS, Timeout)
				for Option in [0x1005, 0x1006]
					if DllCall("Ws2_32\setsockopt", "Ptr", Peer, "Int", 0xFFFF, "Int", Option, "Ptr", Timeout, "Int", Timeout.Size, "Int") != 0
						throw _R7HS_Error("Bounding the accepted peer's native I/O")
				Request := _R7HS_Request(Peer)
				Requests += 1
				if Requests > 2
					throw Error("The private service received more than tags and one chat.")
				if Request["method"] == "GET" && Request["path"] == "/api/tags" {
					Status := 200, Body := '{"models":[{"name":"fixture-model:latest"}]}'
				} else if Request["method"] == "POST" && Request["path"] == "/api/chat" {
					Status := ChatStatus
					Body := '{"message":{"content":"native HTTP answer"},"done":true}' . "`n"
					if BodyKind == "after-done"
						Body .= '{"message":{"content":"unadmitted"},"done":false}' . "`n"
					else if BodyKind != "done" {
						ProviderModel := BodyKind == "matching" ? "fixture-model:latest"
							: BodyKind == "foreign" ? "foreign:latest" : "SCREEN_PRIVATE_MODEL_ECHO"
						Body := '{"error":"model ' . Chr(39) . ProviderModel . Chr(39) . ' not found"}'
					}
				} else
					throw Error("The private service refused an unexpected method or endpoint.")
				_R7HS_Reply(Peer, Status, Body)
				Record := '{"method":"' . Request["method"] . '","path":"' . Request["path"] . '","status":' . Status . '}'
				FileAppend(Record . "`n", Transcript, "UTF-8-RAW")
				if Request["method"] == "POST"
					return 0
			} finally {
				DllCall("Ws2_32\closesocket", "Ptr", Peer)
				Peer := -1
			}
		}
	} finally {
		if Peer != -1
			DllCall("Ws2_32\closesocket", "Ptr", Peer)
		if Listener != -1
			DllCall("Ws2_32\closesocket", "Ptr", Listener)
		if WsaOwned
			DllCall("Ws2_32\WSACleanup")
		if FileExist(ReadyPath . ".staging")
			FileDelete(ReadyPath . ".staging")
	}
}

try _R7HS_ExitCode := _R7HS_Main()
catch as _R7HS_Failure {
	FileAppend("Private HTTP fixture failed: " . _R7HS_Failure.Message . "`n", "**")
	_R7HS_ExitCode := 1
}
ExitApp(_R7HS_ExitCode)
