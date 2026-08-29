; modules/llm/api_remote.ahk

; ==============================================================================
; MODULE: LLM API — Remote API Backend
; DESCRIPTION:
; Synchronous HTTP client for remote LLM APIs (OpenAI, Anthropic, Google Gemini,
; and any OpenAI-Chat-Completions-compatible endpoint such as Groq, OpenRouter,
; LM Studio, vLLM, llama.cpp's HTTP server, …). Sits next to api_ollama.ahk and
; exposes the same async surface as api_ollama.ahk.
;
; FEATURES & RATIONALE:
; 1. Provider catalogue defines per-provider base URL + auth scheme + request
;    formatter + response parser. Adding a new provider = one entry in the
;    catalogue; the prediction engine and tray UI stay unchanged.
; 2. Sync WinHTTP, same as Ollama — keeps the wire protocol single-threaded and
;    the AHK main loop predictable. The engine-level rate-limit floor
;    (``LLM_BACKEND_MIN_REQUEST_INTERVAL_MS["api"] = 500``) is what protects
;    paid providers from token-burn on a per-keystroke debounce.
; 3. No async streaming yet — every call is request/response, which keeps error
;    handling trivial and matches the rest of the AHK LLM pipeline. Streaming
;    can be layered on later without changing the public signature.
; ==============================================================================

#Requires AutoHotkey v2.0




; =======================================
; =======================================
; ======= 1/ Provider Catalogue =========
; =======================================
; =======================================

; Loaded from _shared/modules/llm/api_providers.json at boot (see _LLMRemote_LoadCatalog).
; Each provider ID maps to Label / BaseUrl / DefaultModel / Format — same
; schema as the HS twin. Adding a provider = one entry in api_providers.json
; plus (optionally) a new Format branch in _LLMRemoteBuildPayload /
; _LLMRemoteParseResponse.
global LLM_API_PROVIDERS := Map()
global LLM_API_PROVIDER_ORDER := []

global LLM_REMOTE_TIMEOUT_MS := 0   ; sentinel — sourced at boot by LLMApiLoadTimings ([llm] request_timeout_ms)




; ============================================
; ============================================
; ======= 2/ Public API =====================
; ============================================
; ============================================



; =========================
; ===== Async surface =====
; =========================

; Registry of in-flight async remote requests (parallel to _LLM_Ollama_Async).
global _LLM_Remote_Async := Map()
global _LLM_Remote_AsyncCounter := 0
global LLM_REMOTE_POLL_MS := 0   ; sentinel — sourced at boot by LLMApiLoadTimings ([llm] poll_interval_ms)
global LLM_REMOTE_MAX_INFLIGHT := 16
; WinHttpRequest does the DNS resolve + TCP connect SYNCHRONOUSLY on the message-loop
; thread (its "async" mode only makes the RESPONSE wait async), so a stalled remote host
; freezes typing for the whole connect. This caps the resolve+connect phase so the worst-
; case freeze is bounded; the COMPLETE fix is to move the POST onto a curl child process
; (mirror _LLM_Ollama_DispatchAsync) - see remote-generate-connect-blocks (needs a live
; remote-API key to validate end-to-end).
global LLM_REMOTE_CONNECT_TIMEOUT_MS := 5000

/**
 * Non-blocking remote LLM generation. Mirrors hs.http.asyncPost on
 * the HS side: fire-and-forget dispatch, callbacks fire when ready. See
 * LLM_OllamaGenerate_Async for the polling model — both share the same
 * WinHTTP-async + SetTimer-poll pattern.
 *
 * @param {Map|Object} Entry        - Active API entry record.
 * @param {string}     SystemPrompt - Resolved system prompt.
 * @param {string}     UserText     - User context.
 * @param {number}     Temperature  - Sampling temperature.
 * @param {function}   on_success   - Called with the generated text.
 * @param {function}   on_fail      - Called on HTTP / parse failure.
 * @returns {Integer}  Request id, usable with LLM_RemoteCancelAsync.
 */
LLM_RemoteGenerate_Async(Entry, SystemPrompt, FullText, Temperature, on_success, on_fail, TailText := "", max_tokens := "") {
    global _LLM_Remote_Async, _LLM_Remote_AsyncCounter, LLM_REMOTE_TIMEOUT_MS

    _LLM_Remote_AsyncCounter += 1
    req_id := _LLM_Remote_AsyncCounter
    timeout_ms := (LLM_REMOTE_TIMEOUT_MS > 0) ? LLM_REMOTE_TIMEOUT_MS : 30000
    reservation := _LLMRemote_ReserveRequest(req_id, on_success, on_fail,
        timeout_ms, A_TickCount)

    resolved := _LLMRemoteResolveEntry(Entry)
    if (resolved == "") {
        _LLMRemote_FailReserved(req_id, reservation, on_fail)
        return req_id
    }
    reservation["format"] := resolved["Format"]
    reservation["model_id_at_dispatch"] := resolved["Model"]

    req := _LLMRemote_BuildRequestContext(SystemPrompt, FullText, TailText)
    Url     := _LLMRemoteBuildUrl(resolved["BaseUrl"], resolved["Format"], resolved["Token"], resolved["Model"])
    Payload := _LLMRemoteBuildPayload(resolved["Format"], resolved["Model"], req["system"], req["user"], Temperature, max_tokens)

    ; The curl child is the only production transport. Falling back to WinHTTP
    ; would put DNS/connect/Send back on the cooperative AHK thread.
    if (_LLMRemote_DispatchCurl(req_id, resolved, Url, Payload, on_success,
            on_fail, timeout_ms, 0, reservation))
        return req_id
    try LoggerError("LLM.remote",
        "Remote generation refused because the non-blocking curl transport is unavailable.")
    _LLMRemote_FailReserved(req_id, reservation, on_fail)
    return req_id
}

_LLMRemote_ReserveRequest(req_id, on_success, on_fail, timeout_ms, start_tick,
        Resolved := 0) {
    global _LLM_Remote_Async, LLM_REMOTE_MAX_INFLIGHT
    ResolvedFormat := Resolved is Map ? Resolved["Format"] : ""
    ResolvedModel := Resolved is Map ? Resolved["Model"] : ""
    reservation := Map(
        "transport", "pending",
        "format", ResolvedFormat,
        "model_id_at_dispatch", ResolvedModel,
        "on_success", on_success, "on_fail", on_fail,
        "cancelled", false, "start_tick", start_tick, "timeout_ms", timeout_ms)
    ; Publish before trim or transport work so a reentrant CancelAll always sees
    ; this invocation. Critical closes the only gap between the capacity snapshot
    ; and ownership publication; trim callbacks run after the owner is visible.
    PreviousCritical := Critical("On")
    try {
        needs_trim := _LLM_Remote_Async.Count >= LLM_REMOTE_MAX_INFLIGHT
        _LLM_Remote_Async[req_id] := reservation
    } finally Critical(PreviousCritical)
    if needs_trim
        _LLMRemote_TrimAsyncRegistry()
    return reservation
}

_LLMRemote_RequestOwns(req_id, reservation) {
    global _LLM_Remote_Async
    return _LLM_Remote_Async.Has(req_id)
        && ObjPtr(_LLM_Remote_Async[req_id]) == ObjPtr(reservation)
}

_LLMRemote_DeleteOwned(req_id, reservation) {
    global _LLM_Remote_Async
    Deleted := false
    PreviousCritical := Critical("On")
    try {
        if (_LLM_Remote_Async.Has(req_id)
                and ObjPtr(_LLM_Remote_Async[req_id]) == ObjPtr(reservation)) {
            _LLM_Remote_Async.Delete(req_id)
            Deleted := true
        }
    } finally Critical(PreviousCritical)
    return Deleted
}

_LLMRemote_FailReserved(req_id, reservation, on_fail) {
    if !_LLMRemote_DeleteOwned(req_id, reservation)
        return false
    if !reservation["cancelled"]
        _LLM_InvokeCallback(on_fail, "on_fail")
    return true
}

_LLMRemote_CancelCurlReservation(req_id, reservation, Port := 0) {
    _LLM_CurlReleaseEntryProcess(reservation, true, Port)
    _LLMRemote_CurlCleanup(reservation)
    _LLMRemote_DeleteOwned(req_id, reservation)
}

_LLMRemote_QueueCurlReservationCancel(req_id, reservation, Port := 0) {
    if reservation.Get("cancel_cleanup_queued", false)
        return
    reservation["cancel_cleanup_queued"] := true
    LLM_DeferCancelKills([Map("cancel",
        _LLMRemote_CancelCurlReservation.Bind(req_id, reservation, Port))])
}

_LLMRemote_DispatchWinHttp(req_id, resolved, Url, Payload, on_success, on_fail,
        timeout_ms, Port := 0, Reservation := 0) {
    global LLM_REMOTE_CONNECT_TIMEOUT_MS, LLM_REMOTE_TIMEOUT_MS
    CreateHttpFn := _LLM_CurlArtifactPortFn(Port, "create_http",
        (*) => ComObject("WinHttp.WinHttpRequest.5.1"))
    PollFn := _LLM_CurlArtifactPortFn(Port, "poll", _LLMRemote_PollRequest)
    TickFn := _LLM_CurlArtifactPortFn(Port, "tick", _LLM_CurlArtifactTick)
    reservation := Reservation is Map ? Reservation
        : _LLMRemote_ReserveRequest(req_id, on_success, on_fail,
            timeout_ms, TickFn.Call(), resolved)
    if !_LLMRemote_RequestOwns(req_id, reservation)
        return false
    if reservation["cancelled"] {
        _LLMRemote_DeleteOwned(req_id, reservation)
        return true
    }
    try {
        http := CreateHttpFn.Call()
        reservation["transport"] := "winhttp"
        reservation["http"] := http
        if reservation["cancelled"] or !_LLMRemote_RequestOwns(req_id, reservation) {
            _LLMRemote_DeleteOwned(req_id, reservation)
            return true
        }
        http.Open("POST", Url, true)
        http.SetTimeouts(LLM_REMOTE_CONNECT_TIMEOUT_MS, LLM_REMOTE_CONNECT_TIMEOUT_MS,
            LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_TIMEOUT_MS)
        http.SetRequestHeader("Content-Type", "application/json")
        _LLMRemoteSetAuthHeaders(http, resolved["Format"], resolved["Token"])
        if reservation["cancelled"] or !_LLMRemote_RequestOwns(req_id, reservation) {
            _LLMRemote_DeleteOwned(req_id, reservation)
            return true
        }
        http.Send(Payload)
    } catch as err {
        _LLMRemote_FailReserved(req_id, reservation, on_fail)
        return true
    }
    if !_LLMRemote_RequestOwns(req_id, reservation) or reservation["cancelled"] {
        _LLMRemote_DeleteOwned(req_id, reservation)
        return true
    }
    PollFn.Call(req_id)
    return true
}

; True iff curl.exe is present and can stop an unknown-length response while it
; is still being received.
_LLMRemote_CurlAvailable() {
    CurlExe := A_WinDir . "\System32\curl.exe"
    return FileExist(CurlExe) != ""
        && _HTTP_CurlRuntimeLimitSupported(CurlExe)
}

; Quotes a value for a curl config file. curl unescapes `\\` and `\"` inside a
; quoted value, so both have to be escaped here — an unescaped backslash or quote
; in a provider token would truncate the header and ship a malformed credential.
_LLMRemote_ConfigScalarIsSafe(Value) {
    return Value is String
        && !RegExMatch(Value, "[\x00-\x1F\x7F-\x9F]")
}

_LLMRemote_CurlConfQuote(Value) {
    Escaped := StrReplace(Value, '\', '\\')
    Escaped := StrReplace(Escaped, '"', '\"')
    return '"' . Escaped . '"'
}

; Builds the curl config-file text carrying the request URL and every auth header,
; mirroring _LLMRemoteSetAuthHeaders for the child-process transport.
;
; The credential must never travel on the command line: Win32_Process.CommandLine
; is readable by any same-user process with no elevation, and process-creation
; telemetry (Sysmon event 1, EDR, several AV products) copies argv verbatim into
; logs the driver does not control. A file in the per-PID temp directory is the
; same boundary the request payload already accepted, and it is deleted on every
; completion path.
_LLMRemote_BuildCurlConfig(Format, Token, Url) {
    if !_LLMRemote_ConfigScalarIsSafe(Format)
            || !_LLMRemote_ConfigScalarIsSafe(Token)
            || !_LLMRemote_ConfigScalarIsSafe(Url)
        return ""
    ; Gemini carries the key inside the URL, which is why the URL travels through
    ; this file too rather than being spliced into the command line.
    cfg := "url = " . _LLMRemote_CurlConfQuote(Url) . "`n"
    cfg .= "header = " . _LLMRemote_CurlConfQuote("Content-Type: application/json") . "`n"
    if (Format == "anthropic") {
        if (Token != "")
            cfg .= "header = " . _LLMRemote_CurlConfQuote("x-api-key: " . Token) . "`n"
        cfg .= "header = " . _LLMRemote_CurlConfQuote("anthropic-version: 2023-06-01") . "`n"
        return cfg
    }
    if (Format == "gemini")
        return cfg
    if (Token != "")
        cfg .= "header = " . _LLMRemote_CurlConfQuote("Authorization: Bearer " . Token) . "`n"
    return cfg
}

; Removes the per-request temp files (the payload carries the user's typed PII and
; the config file carries the provider token, so neither must linger). Best-effort.
_LLMRemote_CurlCleanup(entry) {
    try FSDelete(entry["tmp_payload"])
    try FSDelete(entry["tmp_stdout"])
    if entry.Has("tmp_status")
        try FSDelete(entry["tmp_status"])
    if entry.Has("tmp_exit")
        try FSDelete(entry["tmp_exit"])
    ; The token lives in tmp_config; it has to be reaped on the cancelled, deadline,
    ; trim and completion paths alike, which all funnel through here.
    if entry.Has("tmp_config")
        try FSDelete(entry["tmp_config"])
}

_LLMRemote_CleanupPrePollArtifacts(tmp_payload, tmp_stdout, tmp_config, terminal, DeleteFn) {
    for Path in [tmp_payload, tmp_stdout, tmp_config, terminal["status"], terminal["exit"]]
        try DeleteFn.Call(Path)
}

; Dispatch the POST through a curl child process so the connect happens in curl's own
; process — the AHK message loop only polls its durable terminal sidecar. Mirrors
; _LLM_Ollama_DispatchAsync.
; Returns true once it owns the request (dispatched, or failed and fired on_fail); returns
; false ONLY when curl is unavailable, so the caller falls back to WinHTTP.
_LLMRemote_DispatchCurl(req_id, resolved, Url, Payload, on_success, on_fail,
        timeout_ms, Port := 0, Reservation := 0) {
    global _LLM_Remote_Async
    FileExistsFn := _LLM_CurlArtifactPortFn(Port, "file_exists", FileExist)
    TempDirFn := _LLM_CurlArtifactPortFn(Port, "temp_dir", _LLM_Ollama_TempDir)
    WriteFn := _LLM_CurlArtifactPortFn(Port, "write", FSWrite)
    DeleteFn := _LLM_CurlArtifactPortFn(Port, "delete", FSDelete)
    RunFn := _LLM_CurlArtifactPortFn(Port, "run", _LLM_CurlArtifactRun)
    PollFn := _LLM_CurlArtifactPortFn(Port, "poll", _LLMRemote_PollCurl)
    TickFn := _LLM_CurlArtifactPortFn(Port, "tick", _LLM_CurlArtifactTick)
    SweepFn := _LLM_CurlArtifactPortFn(Port, "schedule_orphan_sweep",
        _LLM_Ollama_ScheduleOrphanSweep)
    reservation := Reservation is Map ? Reservation
        : _LLMRemote_ReserveRequest(req_id, on_success, on_fail,
            timeout_ms, TickFn.Call(), resolved)
    owns_fallback_reservation := !(Reservation is Map)
    curl_exe := A_WinDir . "\System32\curl.exe"
    if !FileExistsFn.Call(curl_exe) {
        if owns_fallback_reservation
            _LLMRemote_DeleteOwned(req_id, reservation)
        return false
    }
    if !_HTTP_CurlRuntimeLimitSupported(curl_exe) {
        try LoggerWarn("LLM.remote", "curl cannot enforce the live response-size limit.")
        _LLMRemote_FailReserved(req_id, reservation, on_fail)
        return true
    }
    if !_LLMRemote_RequestOwns(req_id, reservation)
        return true
    reservation["transport"] := "curl"
    config_image := _LLMRemote_BuildCurlConfig(
        resolved["Format"], resolved["Token"], Url)
    if (config_image == "") {
        try LoggerWarn("LLM.remote", "Rejected curl config input containing control characters.")
        _LLMRemote_FailReserved(req_id, reservation, on_fail)
        return true
    }
    ; Remote-only users never enter either Ollama dispatcher. Schedule the same
    ; bounded common reaper here so a prior crash cannot retain provider tokens,
    ; typed payloads, bodies or terminal sidecars indefinitely.
    try SweepFn.Call()
    uid := req_id . "_" . TickFn.Call()
    try tmp_dir := TempDirFn.Call()
    catch as err {
        try LoggerWarn("LLM.remote", "Private curl directory unavailable: {1}.", err.Message)
        _LLMRemote_FailReserved(req_id, reservation, on_fail)
        return true
    }
    tmp_payload := tmp_dir . "\ergopti_remote_" . uid . ".json"
    tmp_stdout  := tmp_dir . "\ergopti_remote_" . uid . ".out"
    tmp_config  := tmp_dir . "\ergopti_remote_" . uid . ".conf"
    terminal    := _LLM_CurlTerminalPaths(tmp_stdout)
    reservation["tmp_payload"] := tmp_payload
    reservation["tmp_stdout"] := tmp_stdout
    reservation["tmp_config"] := tmp_config
    reservation["tmp_status"] := terminal["status"]
    reservation["tmp_exit"] := terminal["exit"]
    if !WriteFn.Call(tmp_payload, Payload) {
        _LLMRemote_CleanupPrePollArtifacts(tmp_payload, tmp_stdout, tmp_config, terminal, DeleteFn)
        try LoggerWarn("LLM.remote", "Failed to write curl payload file.")
        _LLMRemote_FailReserved(req_id, reservation, on_fail)
        return true
    }
    if reservation["cancelled"] or !_LLMRemote_RequestOwns(req_id, reservation) {
        _LLMRemote_CleanupPrePollArtifacts(tmp_payload, tmp_stdout, tmp_config, terminal, DeleteFn)
        _LLMRemote_DeleteOwned(req_id, reservation)
        return true
    }
    if !WriteFn.Call(tmp_config, config_image) {
        _LLMRemote_CleanupPrePollArtifacts(tmp_payload, tmp_stdout, tmp_config, terminal, DeleteFn)
        try LoggerWarn("LLM.remote", "Failed to write curl config file — request abandoned rather than sent with the token on the command line.")
        _LLMRemote_FailReserved(req_id, reservation, on_fail)
        return true
    }
    if reservation["cancelled"] or !_LLMRemote_RequestOwns(req_id, reservation) {
        _LLMRemote_CleanupPrePollArtifacts(tmp_payload, tmp_stdout, tmp_config, terminal, DeleteFn)
        _LLMRemote_DeleteOwned(req_id, reservation)
        return true
    }
    ; URL and auth headers come from --config, never from argv (see
    ; _LLMRemote_BuildCurlConfig): argv has no ACL for a same-user reader.
    curlCmd := '"' . curl_exe . '" -s -S -m '
        . Max(1, Ceil(timeout_ms / 1000)) . ' '
        . _LLM_CurlMaxFileSizeArg() . '-X POST '
        . '--config ' . _Q(tmp_config) . ' '
        . '--data-binary @' . _Q(tmp_payload) . ' '
        . '-o ' . _Q(tmp_stdout)
    cmdLine := _LLM_CurlOwnedCommand(curlCmd, terminal["status"], terminal["exit"])
    pid := 0
    process_owner := 0
    try {
        PreviousCritical := Critical("On")
        try {
            process_owner := _LLM_CurlRunOwned(RunFn, cmdLine, "", "Hide", &pid, Port)
            reservation["pid"] := pid
            reservation["process_owner"] := process_owner
        } finally Critical(PreviousCritical)
    } catch as err {
        if process_owner is Map
            _LLM_CurlReleaseProcess(process_owner, true, Port)
        _LLMRemote_CleanupPrePollArtifacts(tmp_payload, tmp_stdout, tmp_config, terminal, DeleteFn)
        try LoggerWarn("LLM.remote", "curl launch failed: {1}.", err.Message)
        _LLMRemote_FailReserved(req_id, reservation, on_fail)
        return true
    }
    if reservation["cancelled"] or !_LLMRemote_RequestOwns(req_id, reservation) {
        _LLMRemote_QueueCurlReservationCancel(req_id, reservation, Port)
        return true
    }
    PollFn.Call(req_id)
    return true
}

; Polls the curl child WITHOUT blocking the message loop. Mirrors _LLM_Ollama_PollCurl.
_LLMRemoteClassifyTerminal(Format, Terminal, Model := "") {
    if !_LLM_CurlTerminalOk(Terminal) {
        Result := _LLMRemoteClassifyResponse(Format, "", Model)
        Result["terminal_ok"] := false
        Result["reason"] := "transport"
        return Result
    }
    Result := _LLMRemoteClassifyResponse(Format, Terminal["body"], Model)
    Result["terminal_ok"] := true
    return Result
}

_LLMRemote_PollCurl(req_id, Port := 0) {
    global _LLM_Remote_Async, LLM_REMOTE_POLL_MS
    ReadTerminalFn := _LLM_CurlArtifactPortFn(Port, "read_terminal", _LLM_CurlReadTerminal)
    CleanupFn := _LLM_CurlArtifactPortFn(Port, "cleanup", _LLMRemote_CurlCleanup)
    if !_LLM_Remote_Async.Has(req_id)
        return
    entry := _LLM_Remote_Async[req_id]
    terminal := ReadTerminalFn.Call(entry["tmp_status"], entry["tmp_exit"], entry["tmp_stdout"])
    ; The exit sidecar is written last by _LLM_CurlOwnedCommand. Resolve that
    ; durable receipt before cancellation, deadline or PID state: the numeric PID
    ; may already name an unrelated process by the time this timer runs.
    if _LLM_CurlTerminalComplete(terminal) {
        _LLM_CurlReleaseEntryProcess(entry, false, Port)
        if entry["cancelled"] {
            CleanupFn.Call(entry)
            _LLM_Remote_Async.Delete(req_id)
            return
        }
        on_success := entry["on_success"]
        on_fail    := entry["on_fail"]
        fmt        := entry["format"]
        model_id   := entry.Has("model_id_at_dispatch") ? entry["model_id_at_dispatch"] : ""
        body := terminal["body"]
        Classified := _LLMRemoteClassifyTerminal(fmt, terminal, model_id)
        if !Classified["terminal_ok"] {
            try LoggerWarn("LLM.remote", "curl terminal failure req_id={1} exit={2} status={3} body_chars={4}.",
                req_id, terminal["exit"], terminal["status"], StrLen(body))
            CleanupFn.Call(entry)
            _LLM_Remote_Async.Delete(req_id)
            _LLM_InvokeCallback(on_fail, "on_fail")
            return
        }
        if !Classified["ok"] {
            try LoggerWarn("LLM.remote", "curl response for req_id={1} carried no completion (reason={2}, body_chars={3}).",
                req_id, Classified["reason"], StrLen(body))
            CleanupFn.Call(entry)
            _LLM_Remote_Async.Delete(req_id)
            _LLM_InvokeCallback(on_fail, "on_fail")
            return
        }
        CleanupFn.Call(entry)
        _LLM_Remote_Async.Delete(req_id)
        _LLM_InvokeCallback(on_success, "on_success", Classified["text"], Classified["usage"])
        return
    }
    if entry["cancelled"] {
        _LLM_CurlReleaseEntryProcess(entry, true, Port)
        CleanupFn.Call(entry)
        _LLM_Remote_Async.Delete(req_id)
        return
    }
    if (_LLM_DeadlineExpired(entry["start_tick"], entry["timeout_ms"])) {
        ; Hoisted above the Delete so the wrapper still has the callback, matching
        ; the sibling branches in _LLMRemote_PollRequest.
        on_fail := entry["on_fail"]
        _LLM_CurlReleaseEntryProcess(entry, true, Port)
        CleanupFn.Call(entry)
        _LLM_Remote_Async.Delete(req_id)
        try LoggerWarn("LLM.remote", "curl poll deadline exceeded for req_id={1} - aborting.", req_id)
        _LLM_InvokeCallback(on_fail, "on_fail")
        return
    }
    ; No terminal receipt yet. Poll the receipt itself until its bounded deadline;
    ; ProcessExist(pid) cannot distinguish the original child from a recycled PID.
    SetTimer(() => _LLMRemote_PollCurl(req_id, Port), -LLM_REMOTE_POLL_MS)
}

LLM_RemoteCancelAsync(req_id) {
    global _LLM_Remote_Async
    if !_LLM_Remote_Async.Has(req_id)
        return
    entry := _LLM_Remote_Async[req_id]
    ; Flip the flag inline — the poll tick reads it — but release the transport
    ; off-thread, exactly as the plural sibling does. This is reached from the
    ; per-keystroke Critical, where both a blocking TerminateProcess and a WinHTTP
    ; Abort (a cross-apartment COM call) starve the keyboard hook while the
    ; message pump is suspended. The poll tick still cleans up the curl temp files
    ; carrying request PII on its next iteration, exactly as before.
    entry["cancelled"] := true
    Kills := []
    if (entry.Has("transport") and entry["transport"] == "curl") {
        if entry.Has("process_owner")
            Kills.Push(Map("cancel", _LLM_CurlReleaseProcess.Bind(
                entry["process_owner"], true)))
    } else if entry.Has("http") {
        Kills.Push(Map("http", entry["http"]))
    }
    LLM_DeferCancelKills(Kills)
}

LLM_RemoteCancelAllAsync() {
    global _LLM_Remote_Async
    ; Flip the flags inline — the per-request poll ticks read them — but snapshot
    ; the transports and release them off-thread. This is reached from the
    ; per-keystroke Critical, where both a blocking TerminateProcess and a WinHTTP
    ; Abort (a cross-apartment COM call) starve the keyboard hook while the
    ; message pump is suspended. The poll tick still performs the temp-file
    ; cleanup on its next iteration, exactly as before.
    Kills := []
    for _id, entry in _LLM_Remote_Async {
        entry["cancelled"] := true
        if (entry.Has("transport") and entry["transport"] == "curl") {
            if entry.Has("process_owner")
                Kills.Push(Map("cancel", _LLM_CurlReleaseProcess.Bind(
                    entry["process_owner"], true)))
        } else if entry.Has("http") {
            Kills.Push(Map("http", entry["http"]))
        }
    }
    LLM_DeferCancelKills(Kills)
}

_LLMRemote_PollRequest(req_id) {
    global _LLM_Remote_Async, LLM_REMOTE_POLL_MS
    if !_LLM_Remote_Async.Has(req_id)
        return
    entry := _LLM_Remote_Async[req_id]
    if entry["cancelled"] {
        ; Abort the in-flight WinHTTP request before dropping our reference.
        ; Without this the COM object + its socket stay resident until WinHTTP's
        ; own receive timeout fires — a provider that accepts the connection but
        ; never responds keeps the request alive far longer than intended.
        if entry.Has("http")
            try entry["http"].Abort()
        _LLM_Remote_Async.Delete(req_id)
        return
    }
    ; Wrap-safe deadline guard: if the response never arrives (CDN silent drop,
    ; network change mid-request), the poll loop would run forever without this
    ; cap. Uses elapsed-delta arithmetic via _LLM_DeadlineExpired so the guard
    ; remains correct across the 32-bit A_TickCount wrap (~49.7 days uptime).
    if _LLM_DeadlineExpired(entry["start_tick"], entry["timeout_ms"]) {
        on_fail := entry["on_fail"]
        ; Abort the stalled request so the COM object + socket are released now
        ; rather than lingering until WinHTTP's internal receive timeout fires.
        if entry.Has("http")
            try entry["http"].Abort()
        _LLM_Remote_Async.Delete(req_id)
        try LoggerWarn("LLM.remote", "Poll deadline exceeded for req_id={1} — aborting.", req_id)
        _LLM_InvokeCallback(on_fail, "on_fail")
        return
    }
    http := entry["http"]
    ready := false
    ; A COM exception from WaitForResponse (connection dropped mid-request: WiFi cut,
    ; provider socket reset, VPN flap) must abort the dead request immediately rather than
    ; swallow the error and keep waking the message loop every poll interval for the full
    ; deadline. Mirrors the Ollama fix (ollama-com-exception-busy-loop), which the remote
    ; twin never received.
    try {
        ready := http.WaitForResponse(0)
    } catch as com_err {
        on_fail := entry["on_fail"]
        try http.Abort()
        _LLM_Remote_Async.Delete(req_id)
        try LoggerWarn("LLM.remote", "WaitForResponse COM error for req_id={1}: {2} — aborting.", req_id, com_err.Message)
        _LLM_InvokeCallback(on_fail, "on_fail")
        return
    }
    if !ready {
        SetTimer(() => _LLMRemote_PollRequest(req_id), -LLM_REMOTE_POLL_MS)
        return
    }
    on_success := entry["on_success"]
    on_fail    := entry["on_fail"]
    entryFormat := entry["format"]
    _LLM_Remote_Async.Delete(req_id)
    try {
        status := http.Status
        body   := http.ResponseText
    } catch {
        _LLM_InvokeCallback(on_fail, "on_fail")
        return
    }
    Classified := _LLMRemoteClassifyTerminal(entryFormat,
        Map("exit", 0, "status", status, "body_read", true, "body", body),
        entry.Has("model_id_at_dispatch") ? entry["model_id_at_dispatch"] : "")
    if !Classified["terminal_ok"] {
        _LLM_InvokeCallback(on_fail, "on_fail")
        return
    }
    if !Classified["ok"] {
        _LLM_InvokeCallback(on_fail, "on_fail")
        return
    }
    _LLM_InvokeCallback(on_success, "on_success", Classified["text"], Classified["usage"])
}

; Token + cost extraction. Each provider exposes the same numeric fields
; under a top-level ``usage`` block (OpenAI / Anthropic / Cohere / Mistral
; / xAI / Cerebras / DeepSeek) or under ``usageMetadata`` (Gemini). We
; pull prompt + completion + total when present and compute an estimated
; cost in USD from the per-model price table below.
_LLMRemoteEmptyUsage() {
    return Map("prompt_tokens", 0, "completion_tokens", 0, "total_tokens", 0, "est_cost_usd", 0.0)
}

_LLMRemoteExtractUsageRoot(format, root, model) {
    out := _LLMRemoteEmptyUsage()
    if !(root is Map)
        return out
    usageKey := format == "gemini" ? "usageMetadata" : "usage"
    if !root.Has(usageKey) or !(root[usageKey] is Map)
        return out
    usage := root[usageKey]
    promptKey := format == "gemini" ? "promptTokenCount"
        : (format == "anthropic" ? "input_tokens" : "prompt_tokens")
    completionKey := format == "gemini" ? "candidatesTokenCount"
        : (format == "anthropic" ? "output_tokens" : "completion_tokens")
    totalKey := format == "gemini" ? "totalTokenCount" : "total_tokens"
    if usage.Has(promptKey) and usage[promptKey] is Number and usage[promptKey] >= 0
        out["prompt_tokens"] := Integer(usage[promptKey])
    if usage.Has(completionKey) and usage[completionKey] is Number and usage[completionKey] >= 0
        out["completion_tokens"] := Integer(usage[completionKey])
    if usage.Has(totalKey) and usage[totalKey] is Number and usage[totalKey] >= 0
        out["total_tokens"] := Integer(usage[totalKey])
    if (out["total_tokens"] == 0 and out["prompt_tokens"] > 0)
        out["total_tokens"] := out["prompt_tokens"] + out["completion_tokens"]
    out["est_cost_usd"] := _LLMRemoteEstimateCost(model, out["prompt_tokens"], out["completion_tokens"])
    return out
}

_LLMRemoteExtractUsage(format, body, model) {
    out := _LLMRemoteEmptyUsage()
    if (body == "")
        return out
    try root := JsonParse(body)
    catch
        return out
    return _LLMRemoteExtractUsageRoot(format, root, model)
}

; Per-model USD price table (per 1M tokens) — loaded from api_providers.json.
global LLM_REMOTE_MODEL_PRICES := Map()

_LLMRemoteEstimateCost(model, in_tokens, out_tokens) {
    global LLM_REMOTE_MODEL_PRICES
    if (model == "" or !LLM_REMOTE_MODEL_PRICES.Has(model))
        return 0.0
    p := LLM_REMOTE_MODEL_PRICES[model]
    return (in_tokens * p["in"] + out_tokens * p["out"]) / 1000000.0
}

_LLMRemote_TrimAsyncRegistry() {
    global _LLM_Remote_Async, LLM_REMOTE_MAX_INFLIGHT
    if (_LLM_Remote_Async.Count < LLM_REMOTE_MAX_INFLIGHT)
        return
    oldest_id := 0x7FFFFFFFFFFFFFFF
    for id in _LLM_Remote_Async {
        if (id < oldest_id)
            oldest_id := id
    }
    if !_LLM_Remote_Async.Has(oldest_id)
        return
    oldest_entry := _LLM_Remote_Async[oldest_id]
    ; Detach before cleanup or callbacks: either boundary can re-enter dispatch,
    ; and the terminated owner must no longer participate in successor trimming.
    _LLM_Remote_Async.Delete(oldest_id)
        ; Abort the live WinHTTP request so the COM object + socket are
        ; released now rather than lingering until WinHTTP's own timeout.
        if oldest_entry.Has("http")
            try oldest_entry["http"].Abort()
        if (oldest_entry.Has("transport") and oldest_entry["transport"] == "curl") {
            _LLM_CurlReleaseEntryProcess(oldest_entry, true)
            _LLMRemote_CurlCleanup(oldest_entry)
        }
        ; Honour the async contract: exactly one of on_success / on_fail must
        ; fire. Without this the caller (e.g. the prediction engine slot state
        ; machine) hangs forever waiting for a callback that will never arrive.
        if oldest_entry.Has("on_fail") and oldest_entry["on_fail"] is Func
            _LLM_InvokeCallback(oldest_entry["on_fail"], "on_fail")
        return
}

; Resolves an entry record to a normalised Map(Provider, Format, BaseUrl,
; Token, Model). Returns "" when the entry is unusable (missing token /
; model / unknown provider) so the caller can fail cleanly on a single
; check instead of repeating the same six guards everywhere.
_LLMRemoteResolveEntry(Entry) {
    global LLM_API_PROVIDERS
    ProviderId := _LLMRemoteEntryGet(Entry, "Provider", "openai_compat")
    if !LLM_API_PROVIDERS.Has(ProviderId)
        return ""
    Provider := LLM_API_PROVIDERS[ProviderId]
    ProvFmt  := Provider["Format"]
    BaseUrl  := _LLMRemoteEntryGet(Entry, "BaseUrl", "")
    if (BaseUrl == "")
        BaseUrl := Provider["BaseUrl"]
    if (BaseUrl == "")
        return ""
    Token := _LLMRemoteEntryGet(Entry, "Token", "")
    if (Token == "")
        return ""
    Model := _LLMRemoteEntryGet(Entry, "Model", Provider["DefaultModel"])
    if (Model == "")
        return ""
    for Scalar in [ProviderId, ProvFmt, BaseUrl, Token, Model] {
        if !_LLMRemote_ConfigScalarIsSafe(Scalar)
            return ""
    }
    return Map("Provider", ProviderId, "Format", ProvFmt, "BaseUrl", BaseUrl, "Token", Token, "Model", Model)
}

; Per-phase timeout (ms) for the readiness ping. Same value the sync path
; used, but here it is non-blocking: curl runs in its own process and we poll
; for completion, so even a hung connect never freezes
; the main message pump.
global LLM_REMOTE_READY_PING_TIMEOUT_MS := 2000
; Absolute-time cap (ms) for the readiness poll loop. Sized one cadence above
; the per-phase timeout so a silent connection drop (no WinHTTP timeout fires)
; still ends the timer chain promptly instead of polling forever.
global LLM_REMOTE_READY_PING_DEADLINE_MS := 3000
; Poll cadence (ms) for the readiness ping. A reachability check does not need
; sub-100 ms reactivity, so a relaxed cadence keeps timer pressure off the
; message loop (mirrors LLM_OllamaIsRunning_Async's 500 ms).
global LLM_REMOTE_READY_PING_POLL_MS := 250

/**
 * Probes the provider /models endpoint in a tree-owned curl child, so the caller
 * (the tray
 * save path) returns immediately and the message pump keeps running. Invokes
 * ``on_result(bool)`` from a polling tick once the ping resolves, times out,
 * or fails. Mirrors LLM_OllamaIsRunning_Async.
 *
 * @param {Map|Object} Entry     - API entry record (Provider / BaseUrl / Token).
 * @param {function}   on_result - Callback receiving the boolean reachability.
 */
_LLMRemote_ReadyOwnerIsCurrent(Owner) {
    return Owner is Map && LLM_AuxIsCurrent(Owner)
}

_LLMRemote_CompleteReady(Owner, on_result, reachable) {
    if !_LLMRemote_ReadyOwnerIsCurrent(Owner)
        return false
    try _LLM_InvokeCallback(on_result, "on_result", reachable)
    finally {
        if Owner is Map
            LLM_AuxFinish(Owner)
    }
    return true
}

LLM_RemoteIsReady_Async(Entry, on_result, Owner := 0) {
    global LLM_API_PROVIDERS
    global LLM_REMOTE_READY_PING_TIMEOUT_MS, LLM_REMOTE_READY_PING_DEADLINE_MS

    ProviderId := _LLMRemoteEntryGet(Entry, "Provider", "openai_compat")
    if !(Owner is Map) {
        EntryId := _LLMRemoteEntryGet(Entry, "Id", "")
        OwnerKind := EntryId != "" ? "api_validation:" . EntryId : "remote_ready"
        Owner := LLM_AuxBegin(OwnerKind, Map(
            "backend", "api",
            "endpoint", _LLMRemoteEntryGet(Entry, "BaseUrl", ""),
            "identity", EntryId))
    }
    if !LLM_API_PROVIDERS.Has(ProviderId) {
        _LLMRemote_CompleteReady(Owner, on_result, false)
        return Owner
    }
    Provider := LLM_API_PROVIDERS[ProviderId]
    BaseUrl  := _LLMRemoteEntryGet(Entry, "BaseUrl", Provider["BaseUrl"])
    Token    := _LLMRemoteEntryGet(Entry, "Token", "")
    if (BaseUrl == "" or Token == "") {
        _LLMRemote_CompleteReady(Owner, on_result, false)
        return Owner
    }

    ProvFmt := Provider["Format"]
    PingUrl := ""
    if (ProvFmt == "openai" or ProvFmt == "anthropic") {
        PingUrl := RTrim(BaseUrl, "/") . "/models"
    } else if (ProvFmt == "gemini") {
        PingUrl := RTrim(BaseUrl, "/") . "/models?key=" . Token
    }
    if (PingUrl == "") {
        _LLMRemote_CompleteReady(Owner, on_result, false)
        return Owner
    }

    try {
        Http := CurlAsyncRequest()
        Http.Open("GET", PingUrl, true)
        Http.SetTimeouts(LLM_REMOTE_READY_PING_TIMEOUT_MS, LLM_REMOTE_READY_PING_TIMEOUT_MS,
                        LLM_REMOTE_READY_PING_TIMEOUT_MS, LLM_REMOTE_READY_PING_TIMEOUT_MS)
        _LLMRemoteSetAuthHeaders(Http, ProvFmt, Token)
        Http.Send()
    } catch {
        _LLMRemote_CompleteReady(Owner, on_result, false)
        return Owner
    }
    if !LLM_AuxBindResources(Owner, Map("cancel", (*) => Http.Abort()))
        return Owner
    _LLMRemote_PollReady(Http, on_result, A_TickCount,
        LLM_REMOTE_READY_PING_DEADLINE_MS, Owner)
    return Owner
}

; Polling tick for LLM_RemoteIsReady_Async. Re-arms itself on a relaxed cadence
; until the response is ready or the elapsed time exceeds timeout_ms, then aborts
; the in-flight request and reports the result exactly once. Uses wrap-safe
; elapsed-delta arithmetic via _LLM_DeadlineExpired.
_LLMRemote_PollReady(Http, on_result, start_tick, timeout_ms, Owner := 0) {
    global LLM_REMOTE_READY_PING_POLL_MS
    if !_LLMRemote_ReadyOwnerIsCurrent(Owner) {
        try Http.Abort()
        return
    }
    ready := false
    try {
        ready := Http.WaitForResponse(0)
    } catch as com_err {
        ; The last uncovered site of the ollama-com-exception invariant. A COM
        ; exception means the connection dropped; the bare `try` this replaces
        ; swallowed it and re-armed the poll, so a dead readiness ping kept
        ; polling to its deadline against a socket that would never answer, with
        ; nothing in the log to say why the backend looked unreachable.
        try LoggerWarn("LLM.remote", "PollReady WaitForResponse threw COM error — abandoning: {1}", com_err.Message)
        try Http.Abort()
        _LLMRemote_CompleteReady(Owner, on_result, false)
        return
    }
    if !ready {
        if _LLM_DeadlineExpired(start_tick, timeout_ms) {
            ; Abort the stalled request so the COM object + socket are released
            ; now rather than lingering until WinHTTP's own timeout fires.
            try Http.Abort()
            _LLMRemote_CompleteReady(Owner, on_result, false)
            return
        }
        LLM_AuxSchedule(Owner,
            () => _LLMRemote_PollReady(Http, on_result, start_tick,
                timeout_ms, Owner), -LLM_REMOTE_READY_PING_POLL_MS)
        return
    }
    status := 0
    try status := Http.Status
    _LLMRemote_CompleteReady(Owner, on_result, status >= 200 and status < 300)
}




; ============================================
; ============================================
; ======= 3/ Internal helpers ===============
; ============================================
; ============================================

; Mirrors macOS api_remote.lua post_and_parse and api_ollama build_request_context.
_LLMRemote_BuildRequestContext(system_prompt, full_text, tail_text) {
    sys := system_prompt
    user := full_text
    tail := (tail_text != "") ? tail_text : full_text
    if (InStr(sys, "PREFIX") and InStr(sys, "TAIL")) {
        user := Format('PREFIX: "{1}"`nTAIL: "{2}"', full_text, tail)
    } else if (sys != "" and InStr(sys, "{context}")) {
        sys := StrReplace(sys, "{context}", full_text)
        user := ""
    } else {
        user := full_text
    }
    return Map("system", sys, "user", user)
}

_LLMRemoteEntryGet(Entry, Key, Default := "") {
    if (Entry is Map) {
        return Entry.Has(Key) ? Entry[Key] : Default
    }
    try {
        return Entry.%Key%
    } catch {
        return Default
    }
}

; URL builder. Gemini bakes the model + API key into the path (no Authorization
; header), so it needs a custom shape. OpenAI / Anthropic / OpenAI-compat all
; use POST against a fixed endpoint with the model in the JSON payload.
_LLMRemoteBuildUrl(BaseUrl, Fmt, Token, Model) {
    Trimmed := RTrim(BaseUrl, "/")
    if (Fmt == "anthropic") {
        return Trimmed . "/messages"
    }
    if (Fmt == "gemini") {
        ; Gemini's path is /models/<model>:generateContent?key=<token>.
        ; Google API keys are alphanumeric + dash + underscore (URL-safe by
        ; construction), so we send the token raw. An earlier version tried
        ; to call ``Shlwapi\UrlEscapeW`` with a broken signature AND then
        ; used ``Token`` instead of the (never-produced) escaped value — the
        ; whole branch was dead code that fortunately happened to do the
        ; right thing in practice. Replaced by an explicit comment so the
        ; intent is obvious to future readers.
        return Trimmed . "/models/" . Model . ":generateContent?key=" . Token
    }
    ; Default OpenAI Chat Completions shape.
    return Trimmed . "/chat/completions"
}

; Sets the per-provider auth headers on a WinHTTP request. Gemini's auth is in
; the query string; everything else uses a header.
_LLMRemoteSetAuthHeaders(Http, Format, Token) {
    if (Format == "anthropic") {
        if (Token != "")
            Http.SetRequestHeader("x-api-key", Token)
        Http.SetRequestHeader("anthropic-version", "2023-06-01")
        return
    }
    if (Format == "gemini") {
        ; Token is in the URL; nothing to set on the header.
        return
    }
    ; OpenAI / OpenAI-compatible all use bearer auth.
    if (Token != "") {
        Http.SetRequestHeader("Authorization", "Bearer " . Token)
    }
}

; Build the JSON payload for the chosen provider format. Each branch produces a
; minimal-but-correct body: a single system message + a single user message,
; plus the temperature. Streaming is intentionally OFF so the call is a single
; request/response round-trip (matches Ollama's non-streaming path).
; The parameter is named ``Fmt`` (not ``Format``) on purpose: AHK v2 lets a
; parameter name shadow the built-in ``Format()`` function, and we need the
; built-in available below to render the JSON payload templates. Using
; ``Format`` as a parameter would silently break every API request — the
; call ``Format("{:.2f}", ...)`` would try to invoke the parameter (a
; string, e.g. "openai") as a function and throw at runtime.
_LLMRemoteBuildPayload(Fmt, Model, SystemPrompt, UserText, Temperature, max_tokens := "") {
    SysEsc  := _LLMRemoteJsonEscape(SystemPrompt)
    UserEsc := _LLMRemoteJsonEscape(UserText)
    ModelEsc := _LLMRemoteJsonEscape(Model)
    Temp := Format("{:.2f}", Temperature)
    ; Output-token cap threaded from the shared PromptBuilder budget. The number
    ; is never re-declared here: an unset ("") or out-of-range value resolves to
    ; PB_DEFAULT_MAX_TOKENS — the single shared constant (codegen'd from the
    ; domain DEFAULT_MAX_TOKENS) the engine also threads. One source, no literal.
    MaxTok := (max_tokens is Number and max_tokens > 0) ? Integer(max_tokens) : PB_DEFAULT_MAX_TOKENS

    if (Fmt == "anthropic") {
        ; Anthropic Messages API: top-level ``system`` field, ``messages`` is
        ; user/assistant turns only. ``max_tokens`` is REQUIRED by Anthropic.
        return Format('{"model":"{1}","system":"{2}","messages":[{"role":"user","content":"{3}"}],"max_tokens":{5},"temperature":{4}}',
            ModelEsc, SysEsc, UserEsc, Temp, MaxTok)
    }
    if (Fmt == "gemini") {
        ; Gemini wraps the system instruction in ``systemInstruction`` and the
        ; user turn in ``contents.parts.text``.
        return Format('{"systemInstruction":{"parts":[{"text":"{1}"}]},"contents":[{"role":"user","parts":[{"text":"{2}"}]}],"generationConfig":{"temperature":{3},"maxOutputTokens":{4}}}',
            SysEsc, UserEsc, Temp, MaxTok)
    }
    ; OpenAI Chat Completions shape — covers OpenAI itself plus every
    ; OpenAI-compatible endpoint (Groq, OpenRouter, LM Studio, vLLM, …).
    return Format('{"model":"{1}","messages":[{"role":"system","content":"{2}"},{"role":"user","content":"{3}"}],"temperature":{4},"max_tokens":{5},"stream":false}',
        ModelEsc, SysEsc, UserEsc, Temp, MaxTok)
}

; Parse one immutable provider root and classify both the completion and usage
; owned by that root. Canonical containers own an empty result too: falling back
; after ``content:null`` or an empty parts array would promote reasoning/metadata
; decoys that are not assistant output. Compatibility extraction is allowed only
; for valid JSON maps that carry no canonical container and no provider error.
_LLMRemoteClassifyResponse(Format, Body, Model := "") {
    Result := Map(
        "ok", false, "valid_json", false, "recognized", false,
        "text", "", "usage", _LLMRemoteEmptyUsage(), "reason", "empty_body")
    if (Body == "")
        return Result
    try Root := JsonParse(Body)
    catch {
        Result["reason"] := "malformed_json"
        return Result
    }
    Result["valid_json"] := true
    if !(Root is Map) {
        Result["reason"] := "unsupported_json_root"
        return Result
    }
    State := _LLMRemoteParseStructuredRootState(Format, Root)
    Result["recognized"] := State["recognized"]
    Result["usage"] := _LLMRemoteExtractUsageRoot(Format, Root, Model)
    if State["recognized"]
        Result["text"] := State["text"]
    else
        Result["text"] := _LLMRemoteParseResponseRegex(Format, Body)
    Result["ok"] := Result["text"] != ""
    Result["reason"] := Result["ok"] ? "completion"
        : (State["recognized"] ? State["reason"] : "unsupported_shape")
    return Result
}

_LLMRemoteParseResponse(Format, Body) {
    return _LLMRemoteClassifyResponse(Format, Body)["text"]
}

_LLMRemoteParseStructuredRootState(Format, Root) {
    if Root.Has("error")
        return Map("recognized", true, "text", "", "reason", "provider_error")
    if (Format == "anthropic") {
        if !Root.Has("content")
            return Map("recognized", false, "text", "", "reason", "unsupported_shape")
        if Root["content"] is Array {
            for _, Block in Root["content"] {
                if !(Block is Map) or !Block.Has("type") or Block["type"] != "text"
                    continue
                Text := Block.Has("text") and Type(Block["text"]) == "String" ? Block["text"] : ""
                return Map("recognized", true, "text", Text, "reason", "canonical_empty")
            }
        }
        return Map("recognized", true, "text", "", "reason", "canonical_empty")
    }
    if (Format == "gemini") {
        if !Root.Has("candidates")
            return Map("recognized", false, "text", "", "reason", "unsupported_shape")
        if Root["candidates"] is Array and Root["candidates"].Length {
            Candidate := Root["candidates"][1]
            if (Candidate is Map) and Candidate.Has("content") and (Candidate["content"] is Map) {
                Content := Candidate["content"]
                if Content.Has("parts") and (Content["parts"] is Array) {
                    for _, Part in Content["parts"] {
                        if (Part is Map) and Part.Has("text") {
                            Text := Type(Part["text"]) == "String" ? Part["text"] : ""
                            return Map("recognized", true, "text", Text, "reason", "canonical_empty")
                        }
                    }
                }
            }
        }
        return Map("recognized", true, "text", "", "reason", "canonical_empty")
    }
    if !Root.Has("choices")
        return Map("recognized", false, "text", "", "reason", "unsupported_shape")
    if Root["choices"] is Array and Root["choices"].Length {
        Choice := Root["choices"][1]
        if (Choice is Map) and Choice.Has("message") and (Choice["message"] is Map) {
            Message := Choice["message"]
            if Message.Has("content") {
                Text := Type(Message["content"]) == "String" ? Message["content"] : ""
                return Map("recognized", true, "text", Text, "reason", "canonical_empty")
            }
        }
    }
    return Map("recognized", true, "text", "", "reason", "canonical_empty")
}

; Compatibility extraction is intentionally limited to syntactically valid
; JSON maps without a canonical response container or provider-error envelope.
_LLMRemoteParseResponseRegex(Format, Body) {
    if (Format == "anthropic") {
        ; { "content": [ { "type": "text", "text": "..." } ], ... }
        if RegExMatch(Body, 'm)"text"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)
            return _LLMRemoteJsonUnescape(m[1])
        return ""
    }
    if (Format == "gemini") {
        ; { "candidates": [ { "content": { "parts": [ { "text": "..." } ] } } ] }
        if RegExMatch(Body, 'm)"text"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)
            return _LLMRemoteJsonUnescape(m[1])
        return ""
    }
    ; OpenAI shape: { "choices": [ { "message": { "content": "..." } } ] }
    if RegExMatch(Body, 'm)"content"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)
        return _LLMRemoteJsonUnescape(m[1])
    return ""
}

; Escapes a string for embedding between caller-owned JSON quotes.
_LLMRemoteJsonEscape(s) {
    return JsonStringContents(s)
}

; Inverse of _LLMRemoteJsonEscape — undo the common escapes the provider used
; when serialising its response. Same reasoning: enough for normal model
; output, no need for the full JSON spec since we never feed the result back
; into a JSON parser.
_LLMRemoteJsonUnescape(s) {
    ; AHK-26: neutralise \\ FIRST via a sentinel so that \\n / \\t / \\r
    ; sequences are not munged by the later single-char escape passes (the old
    ; ordering let \\n → \newline instead of the correct \n). Chr(0) cannot be
    ; used as that sentinel — AHK strings are internally null-terminated, so
    ; StrReplace() with a null character silently truncates the string instead
    ; of substituting it. A Unicode private-use codepoint is a normal character
    ; to AHK's string engine and is not expected to appear in real LLM output.
    static sentinel := Chr(0xE000)
    s := StrReplace(s, "\\",    sentinel)  ; sentinel for literal backslash
    s := StrReplace(s, "\n",   "`n")
    s := StrReplace(s, "\r",   "`r")
    s := StrReplace(s, "\t",   "`t")
    s := StrReplace(s, '\"',   '"')
    s := StrReplace(s, sentinel, "\")      ; restore literal backslash
    return s
}

; ============================================
; ======= 4/ Shared catalogue loader =========
; ============================================

_LLMRemote_CatalogDescriptorIsValid(providerId, desc) {
    if !(desc is Map)
        return false
    for req in ["label", "base_url", "default_model", "format"] {
        if (!desc.Has(req) or Type(desc[req]) != "String")
            return false
    }

    label := desc["label"]
    baseUrl := desc["base_url"]
    defaultModel := desc["default_model"]
    format := desc["format"]
    if (Trim(label) = "" or (format != "openai" and format != "anthropic" and format != "gemini"))
        return false

    ; The compatibility row is a user-supplied endpoint/model template. Every
    ; shipped concrete provider must be immediately usable from the catalogue.
    if (providerId != "openai_compat" and (Trim(baseUrl) = "" or Trim(defaultModel) = ""))
        return false
    if (baseUrl != "" and !RegExMatch(baseUrl, "i)^https?://[^[:space:]]+$"))
        return false
    return true
}


_LLMRemote_CatalogPriceIsValid(value) {
    ; JsonParse normally produces finite doubles, but keep the publication
    ; boundary explicit so an alternate decoder/test port cannot inject NaN or
    ; infinity into the later arithmetic callback.
    return value is Number and value >= 0 and value <= 1.7976931348623157e308
}

/**
 * Loads provider descriptors + model prices from _shared/modules/llm/api_providers.json.
 * Fail-fast when the file is missing or malformed — same contract as the HS twin.
 */
_LLMRemote_LoadCatalog() {
    global LLM_API_PROVIDERS, LLM_API_PROVIDER_ORDER, LLM_REMOTE_MODEL_PRICES, _SharedDir
    path := _SharedDir . "\modules\llm\api_providers.json"
    if !FileExist(path)
        throw Error("api_providers.json not found at " . path)
    try {
        root := JsonParse(FileRead(path, "UTF-8"))
    } catch as err {
        throw Error("api_providers.json parse failed: " . err.Message)
    }
    if !(root is Map)
        throw Error("api_providers.json root must be an object")
    order := root.Has("provider_order") ? root["provider_order"] : ""
    providers := root.Has("providers") ? root["providers"] : ""
    prices := root.Has("model_prices") ? root["model_prices"] : ""
    if !(order is Array) or order.Length = 0
        throw Error("api_providers.json: provider_order must be a non-empty array")
    if !(providers is Map) or providers.Count = 0
        throw Error("api_providers.json: providers must be a non-empty object")
    if !(prices is Map)
        throw Error("api_providers.json: model_prices must be an object")

    candidateProviders := Map()
    candidateOrder := []
    seenProviders := Map()
    for _, pid in order {
        if (Type(pid) != "String" or Trim(pid) = "")
            continue
        if seenProviders.Has(pid) {
            try LoggerWarn("LLM.remote", "api_providers.json: duplicate provider_order entry '{1}' skipped.", pid)
            continue
        }
        seenProviders[pid] := true
        if !providers.Has(pid) {
            try LoggerWarn("LLM.remote", "api_providers.json: unknown provider '{1}' skipped.", pid)
            continue
        }
        desc := providers[pid]
        if !_LLMRemote_CatalogDescriptorIsValid(pid, desc) {
            try LoggerWarn("LLM.remote", "api_providers.json: provider '{1}' has an invalid descriptor and was skipped.", pid)
            continue
        }
        candidateProviders[pid] := Map(
            "Label", desc["label"],
            "BaseUrl", desc["base_url"],
            "DefaultModel", desc["default_model"],
            "Format", desc["format"])
        candidateOrder.Push(pid)
    }

    candidatePrices := Map()
    for model, row in prices {
        validModel := Type(model) = "String" and model != ""
        validRow := row is Map and row.Has("in") and row.Has("out")
        if validRow
            validRow := _LLMRemote_CatalogPriceIsValid(row["in"])
                and _LLMRemote_CatalogPriceIsValid(row["out"])
        if (!validModel or !validRow) {
            try LoggerWarn("LLM.remote", "api_providers.json: invalid price row '{1}' skipped.", model)
            continue
        }
        candidatePrices[model] := Map("in", row["in"], "out", row["out"])
    }

    ; Publish only the completely validated candidates. A failed/partial parse
    ; can never leak raw catalogue scalars to the menu or inference path.
    LLM_API_PROVIDERS := candidateProviders
    LLM_API_PROVIDER_ORDER := candidateOrder
    LLM_REMOTE_MODEL_PRICES := candidatePrices
}

; AHK-05: a corrupt or user-edited api_providers.json must disable only the remote
; backend, not abort the whole driver boot. Mirror the graceful-degradation pattern
; used by _LLM_LoadPresets (models.ahk) and LLM_LoadProfilesJSON (profiles.ahk).
try _LLMRemote_LoadCatalog()
catch as _e {
	LLM_API_PROVIDERS := Map()
	LLM_API_PROVIDER_ORDER := []
	LLM_REMOTE_MODEL_PRICES := Map()
	try LoggerError("LLM.remote", "api_providers.json load failed — remote API backend disabled: {1}.", _e.Message)
}
