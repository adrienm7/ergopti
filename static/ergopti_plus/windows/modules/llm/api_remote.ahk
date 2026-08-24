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

    resolved := _LLMRemoteResolveEntry(Entry)
    if (resolved == "") {
        _LLM_InvokeCallback(on_fail, "on_fail")
        return req_id
    }

    req := _LLMRemote_BuildRequestContext(SystemPrompt, FullText, TailText)
    Url     := _LLMRemoteBuildUrl(resolved["BaseUrl"], resolved["Format"], resolved["Token"], resolved["Model"])
    Payload := _LLMRemoteBuildPayload(resolved["Format"], resolved["Model"], req["system"], req["user"], Temperature, max_tokens)

    ; Prefer a curl child process so the synchronous DNS resolve + TCP connect (which
    ; WinHttpRequest.5.1 performs on the message-loop thread even in "async" mode) never
    ; freezes typing. _LLMRemote_DispatchCurl returns true once it owns the request
    ; (dispatched, or already failed via on_fail); only fall through to the WinHTTP path
    ; when curl is unavailable on this host (remote-generate-connect-blocks).
    timeout_ms := (LLM_REMOTE_TIMEOUT_MS > 0) ? LLM_REMOTE_TIMEOUT_MS : 30000
    if (_LLMRemote_DispatchCurl(req_id, resolved, Url, Payload, on_success, on_fail, timeout_ms))
        return req_id

    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("POST", Url, true)
        http.SetTimeouts(LLM_REMOTE_CONNECT_TIMEOUT_MS, LLM_REMOTE_CONNECT_TIMEOUT_MS, LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_TIMEOUT_MS)
        http.SetRequestHeader("Content-Type", "application/json")
        _LLMRemoteSetAuthHeaders(http, resolved["Format"], resolved["Token"])
        http.Send(Payload)
    } catch as err {
        _LLM_InvokeCallback(on_fail, "on_fail")
        return req_id
    }

    _LLMRemote_TrimAsyncRegistry()
    ; Record the start tick and timeout duration so the poll loop can self-cancel
    ; when WinHTTP silently stalls (CDN silent drop, network change mid-request).
    ; Uses wrap-safe elapsed-delta arithmetic via _LLM_DeadlineExpired.
    ; Falls back to 30 s when LLM_REMOTE_TIMEOUT_MS is still the 0 sentinel.
    timeout_ms := (LLM_REMOTE_TIMEOUT_MS > 0) ? LLM_REMOTE_TIMEOUT_MS : 30000
    _LLM_Remote_Async[req_id] := Map(
        "http", http, "format", resolved["Format"],
        "model_id_at_dispatch", resolved["Model"],
        "on_success", on_success, "on_fail", on_fail, "cancelled", false,
        "start_tick", A_TickCount, "timeout_ms", timeout_ms)
    _LLMRemote_PollRequest(req_id)
    return req_id
}

; True iff curl.exe is present on this host (Windows 10+ ships it at System32\curl.exe).
_LLMRemote_CurlAvailable() {
    return FileExist(A_WinDir . "\System32\curl.exe") != ""
}

; Quotes a value for a curl config file. curl unescapes `\\` and `\"` inside a
; quoted value, so both have to be escaped here — an unescaped backslash or quote
; in a provider token would truncate the header and ship a malformed credential.
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
; process — the AHK message loop only polls ProcessExist. Mirrors _LLM_Ollama_DispatchAsync.
; Returns true once it owns the request (dispatched, or failed and fired on_fail); returns
; false ONLY when curl is unavailable, so the caller falls back to WinHTTP.
_LLMRemote_DispatchCurl(req_id, resolved, Url, Payload, on_success, on_fail, timeout_ms, Port := 0) {
    global _LLM_Remote_Async
    FileExistsFn := _LLM_CurlArtifactPortFn(Port, "file_exists", FileExist)
    TempDirFn := _LLM_CurlArtifactPortFn(Port, "temp_dir", _LLM_Ollama_TempDir)
    WriteFn := _LLM_CurlArtifactPortFn(Port, "write", FSWrite)
    DeleteFn := _LLM_CurlArtifactPortFn(Port, "delete", FSDelete)
    RunFn := _LLM_CurlArtifactPortFn(Port, "run", _LLM_CurlArtifactRun)
    PollFn := _LLM_CurlArtifactPortFn(Port, "poll", _LLMRemote_PollCurl)
    TickFn := _LLM_CurlArtifactPortFn(Port, "tick", _LLM_CurlArtifactTick)
    curl_exe := A_WinDir . "\System32\curl.exe"
    if !FileExistsFn.Call(curl_exe)
        return false
    uid := req_id . "_" . TickFn.Call()
    tmp_dir := TempDirFn.Call()
    tmp_payload := tmp_dir . "\ergopti_remote_" . uid . ".json"
    tmp_stdout  := tmp_dir . "\ergopti_remote_" . uid . ".out"
    tmp_config  := tmp_dir . "\ergopti_remote_" . uid . ".conf"
    terminal    := _LLM_CurlTerminalPaths(tmp_stdout)
    if !WriteFn.Call(tmp_payload, Payload) {
        _LLMRemote_CleanupPrePollArtifacts(tmp_payload, tmp_stdout, tmp_config, terminal, DeleteFn)
        try LoggerWarn("LLM.remote", "Failed to write curl payload file.")
        _LLM_InvokeCallback(on_fail, "on_fail")
        return true
    }
    if !WriteFn.Call(tmp_config, _LLMRemote_BuildCurlConfig(resolved["Format"], resolved["Token"], Url)) {
        _LLMRemote_CleanupPrePollArtifacts(tmp_payload, tmp_stdout, tmp_config, terminal, DeleteFn)
        try LoggerWarn("LLM.remote", "Failed to write curl config file — request abandoned rather than sent with the token on the command line.")
        _LLM_InvokeCallback(on_fail, "on_fail")
        return true
    }
    ; URL and auth headers come from --config, never from argv (see
    ; _LLMRemote_BuildCurlConfig): argv has no ACL for a same-user reader.
    curlCmd := '"' . curl_exe . '" -s -S -X POST '
        . '--config ' . _Q(tmp_config) . ' '
        . '--data-binary @' . _Q(tmp_payload) . ' '
        . '-o ' . _Q(tmp_stdout)
    cmdLine := _LLM_CurlOwnedCommand(curlCmd, terminal["status"], terminal["exit"])
    pid := 0
    try {
        RunFn.Call(cmdLine, "", "Hide", &pid)
    } catch as err {
        _LLMRemote_CleanupPrePollArtifacts(tmp_payload, tmp_stdout, tmp_config, terminal, DeleteFn)
        try LoggerWarn("LLM.remote", "curl launch failed: {1}.", err.Message)
        _LLM_InvokeCallback(on_fail, "on_fail")
        return true
    }
    _LLMRemote_TrimAsyncRegistry()
    ; ``model_id_at_dispatch`` is what the usage extractor prices the response
    ; against; the WinHTTP sibling has always recorded it and the curl transport
    ; (the only one reached on a host that ships curl.exe) must too.
    _LLM_Remote_Async[req_id] := Map(
        "transport", "curl", "pid", pid,
        "tmp_payload", tmp_payload, "tmp_stdout", tmp_stdout, "tmp_config", tmp_config,
        "tmp_status", terminal["status"], "tmp_exit", terminal["exit"],
        "format", resolved["Format"], "model_id_at_dispatch", resolved["Model"],
        "on_success", on_success, "on_fail", on_fail,
        "cancelled", false, "start_tick", TickFn.Call(), "timeout_ms", timeout_ms)
    PollFn.Call(req_id)
    return true
}

; Polls the curl child WITHOUT blocking the message loop. Mirrors _LLM_Ollama_PollCurl.
_LLMRemote_PollCurl(req_id) {
    global _LLM_Remote_Async, LLM_REMOTE_POLL_MS
    if !_LLM_Remote_Async.Has(req_id)
        return
    entry := _LLM_Remote_Async[req_id]
    if entry["cancelled"] {
        try ProcessClose(entry["pid"])
        _LLMRemote_CurlCleanup(entry)
        _LLM_Remote_Async.Delete(req_id)
        return
    }
    if (_LLM_DeadlineExpired(entry["start_tick"], entry["timeout_ms"])) {
        ; Hoisted above the Delete so the wrapper still has the callback, matching
        ; the sibling branches in _LLMRemote_PollRequest.
        on_fail := entry["on_fail"]
        try ProcessClose(entry["pid"])
        _LLMRemote_CurlCleanup(entry)
        _LLM_Remote_Async.Delete(req_id)
        try LoggerWarn("LLM.remote", "curl poll deadline exceeded for req_id={1} - aborting.", req_id)
        _LLM_InvokeCallback(on_fail, "on_fail")
        return
    }
    if ProcessExist(entry["pid"]) {
        SetTimer(() => _LLMRemote_PollCurl(req_id), -LLM_REMOTE_POLL_MS)
        return
    }
    on_success := entry["on_success"]
    on_fail    := entry["on_fail"]
    fmt        := entry["format"]
    model_id   := entry.Has("model_id_at_dispatch") ? entry["model_id_at_dispatch"] : ""
    terminal := _LLM_CurlReadTerminal(entry["tmp_status"], entry["tmp_exit"], entry["tmp_stdout"])
    body := terminal["body"]
    if !_LLM_CurlTerminalOk(terminal) {
        snip := StrLen(body) > 200 ? SubStr(body, 1, 200) . "…" : body
        try LoggerWarn("LLM.remote", "curl terminal failure req_id={1} exit={2} status={3} body=«{4}».",
            req_id, terminal["exit"], terminal["status"], snip)
        _LLMRemote_CurlCleanup(entry)
        _LLM_Remote_Async.Delete(req_id)
        _LLM_InvokeCallback(on_fail, "on_fail")
        return
    }
    text := _LLMRemoteParseResponse(fmt, body)
    if (text == "") {
        ; curl writes a provider ERROR body (401 bad key, 429 quota, 400 bad model)
        ; to the same file as a success, and only the parse miss distinguishes the
        ; two. Without the snippet a rejected API key is indistinguishable from a
        ; model that simply answered nothing.
        snip := StrLen(body) > 200 ? SubStr(body, 1, 200) . "…" : body
        try LoggerWarn("LLM.remote", "curl response for req_id={1} carried no completion — body: «{2}».", req_id, snip)
        _LLMRemote_CurlCleanup(entry)
        _LLM_Remote_Async.Delete(req_id)
        _LLM_InvokeCallback(on_fail, "on_fail")
        return
    }
    ; Same tail as _LLMRemote_PollRequest: the engine records tokens + estimated
    ; cost from this block, and curl is the transport every shipping Windows host
    ; actually takes — dropping it here zeroed every metric on the API backend.
    meta := _LLMRemoteExtractUsage(fmt, body, model_id)
    _LLMRemote_CurlCleanup(entry)
    _LLM_Remote_Async.Delete(req_id)
    _LLM_InvokeCallback(on_success, "on_success", text, meta)
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
        if entry.Has("pid")
            Kills.Push(Map("pid", entry["pid"]))
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
            if entry.Has("pid")
                Kills.Push(Map("pid", entry["pid"]))
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
    if (status < 200 or status >= 300) {
        _LLM_InvokeCallback(on_fail, "on_fail")
        return
    }
    text := _LLMRemoteParseResponse(entryFormat, body)
    if (text == "") {
        _LLM_InvokeCallback(on_fail, "on_fail")
        return
    }
    ; Pull the per-provider ``usage`` block out of the response so the
    ; engine can record tokens consumed + estimated cost in the keylogger
    ; event. Same shape as OpenAI / Anthropic / Gemini all carry; Ollama
    ; doesn't (its non-streaming response has ``eval_count`` /
    ; ``prompt_eval_count`` instead, which we don't parse for the remote
    ; path because the engine only treats local backends as "free").
    meta := _LLMRemoteExtractUsage(entryFormat, body, entry.Has("model_id_at_dispatch") ? entry["model_id_at_dispatch"] : "")
    _LLM_InvokeCallback(on_success, "on_success", text, meta)
}

; Token + cost extraction. Each provider exposes the same numeric fields
; under a top-level ``usage`` block (OpenAI / Anthropic / Cohere / Mistral
; / xAI / Cerebras / DeepSeek) or under ``usageMetadata`` (Gemini). We
; pull prompt + completion + total when present and compute an estimated
; cost in USD from the per-model price table below.
_LLMRemoteExtractUsage(format, body, model) {
    out := Map("prompt_tokens", 0, "completion_tokens", 0, "total_tokens", 0, "est_cost_usd", 0.0)
    if (body == "")
        return out
    try root := JsonParse(body)
    catch
        return out
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
        ; Abort the live WinHTTP request so the COM object + socket are
        ; released now rather than lingering until WinHTTP's own timeout.
        if oldest_entry.Has("http")
            try oldest_entry["http"].Abort()
        if (oldest_entry.Has("transport") and oldest_entry["transport"] == "curl") {
            try ProcessClose(oldest_entry["pid"])
            _LLMRemote_CurlCleanup(oldest_entry)
        }
        ; Honour the async contract: exactly one of on_success / on_fail must
        ; fire. Without this the caller (e.g. the prediction engine slot state
        ; machine) hangs forever waiting for a callback that will never arrive.
        if oldest_entry.Has("on_fail") and oldest_entry["on_fail"] is Func
            _LLM_InvokeCallback(oldest_entry["on_fail"], "on_fail")
        _LLM_Remote_Async.Delete(oldest_id)
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
    return Map("Provider", ProviderId, "Format", ProvFmt, "BaseUrl", BaseUrl, "Token", Token, "Model", Model)
}

; Probes the API endpoint with a lightweight call (the providers' canonical
; "list models" endpoint when available, falling back to a HEAD on the base
; URL). Returns true when the endpoint is reachable AND the auth token is
; accepted. Used by the tray menu's health-dot helper for "api" backends.
LLM_RemoteIsReady(Entry) {
    global LLM_API_PROVIDERS

    ProviderId := _LLMRemoteEntryGet(Entry, "Provider", "openai_compat")
    if !LLM_API_PROVIDERS.Has(ProviderId) {
        return false
    }
    Provider := LLM_API_PROVIDERS[ProviderId]
    BaseUrl  := _LLMRemoteEntryGet(Entry, "BaseUrl", Provider["BaseUrl"])
    Token    := _LLMRemoteEntryGet(Entry, "Token", "")
    if (BaseUrl == "" or Token == "") {
        return false
    }

    ; The cheap-ping URL per provider: ``/models`` for OpenAI-shaped APIs, the
    ; same path for Anthropic, ``/models?key=...`` for Gemini. A 200 confirms
    ; both reachability and auth.
    ProvFmt := Provider["Format"]
    PingUrl := ""
    if (ProvFmt == "openai" or ProvFmt == "anthropic") {
        PingUrl := RTrim(BaseUrl, "/") . "/models"
    } else if (ProvFmt == "gemini") {
        PingUrl := RTrim(BaseUrl, "/") . "/models?key=" . Token
    }
    if (PingUrl == "") {
        return false
    }
    try {
        Http := ComObject("WinHttp.WinHttpRequest.5.1")
        Http.Open("GET", PingUrl, false)
        Http.SetTimeouts(2000, 2000, 2000, 2000)
        _LLMRemoteSetAuthHeaders(Http, ProvFmt, Token)
        Http.Send()
        return (Http.Status >= 200 and Http.Status < 300)
    } catch {
        return false
    }
}

; Per-phase timeout (ms) for the readiness ping. Same value the sync path
; used, but here it is non-blocking: WinHTTP runs the request on its own
; thread and we poll for completion, so even a hung connect never freezes
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
 * Async variant of LLM_RemoteIsReady. Same probe (provider /models endpoint),
 * but the WinHTTP request is opened async and polled, so the caller (the tray
 * save path) returns immediately and the message pump keeps running. Invokes
 * ``on_result(bool)`` from a polling tick once the ping resolves, times out,
 * or fails. Mirrors LLM_OllamaIsRunning_Async.
 *
 * @param {Map|Object} Entry     - API entry record (Provider / BaseUrl / Token).
 * @param {function}   on_result - Callback receiving the boolean reachability.
 */
LLM_RemoteIsReady_Async(Entry, on_result) {
    global LLM_API_PROVIDERS
    global LLM_REMOTE_READY_PING_TIMEOUT_MS, LLM_REMOTE_READY_PING_DEADLINE_MS

    ProviderId := _LLMRemoteEntryGet(Entry, "Provider", "openai_compat")
    if !LLM_API_PROVIDERS.Has(ProviderId) {
        _LLM_InvokeCallback(on_result, "on_result", false)
        return
    }
    Provider := LLM_API_PROVIDERS[ProviderId]
    BaseUrl  := _LLMRemoteEntryGet(Entry, "BaseUrl", Provider["BaseUrl"])
    Token    := _LLMRemoteEntryGet(Entry, "Token", "")
    if (BaseUrl == "" or Token == "") {
        _LLM_InvokeCallback(on_result, "on_result", false)
        return
    }

    ProvFmt := Provider["Format"]
    PingUrl := ""
    if (ProvFmt == "openai" or ProvFmt == "anthropic") {
        PingUrl := RTrim(BaseUrl, "/") . "/models"
    } else if (ProvFmt == "gemini") {
        PingUrl := RTrim(BaseUrl, "/") . "/models?key=" . Token
    }
    if (PingUrl == "") {
        _LLM_InvokeCallback(on_result, "on_result", false)
        return
    }

    try {
        Http := ComObject("WinHttp.WinHttpRequest.5.1")
        Http.Open("GET", PingUrl, true)
        Http.SetTimeouts(LLM_REMOTE_READY_PING_TIMEOUT_MS, LLM_REMOTE_READY_PING_TIMEOUT_MS,
                        LLM_REMOTE_READY_PING_TIMEOUT_MS, LLM_REMOTE_READY_PING_TIMEOUT_MS)
        _LLMRemoteSetAuthHeaders(Http, ProvFmt, Token)
        Http.Send()
    } catch {
        _LLM_InvokeCallback(on_result, "on_result", false)
        return
    }
    _LLMRemote_PollReady(Http, on_result, A_TickCount, LLM_REMOTE_READY_PING_DEADLINE_MS)
}

; Polling tick for LLM_RemoteIsReady_Async. Re-arms itself on a relaxed cadence
; until the response is ready or the elapsed time exceeds timeout_ms, then aborts
; the in-flight request and reports the result exactly once. Uses wrap-safe
; elapsed-delta arithmetic via _LLM_DeadlineExpired.
_LLMRemote_PollReady(Http, on_result, start_tick, timeout_ms) {
    global LLM_REMOTE_READY_PING_POLL_MS
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
        _LLM_InvokeCallback(on_result, "on_result", false)
        return
    }
    if !ready {
        if _LLM_DeadlineExpired(start_tick, timeout_ms) {
            ; Abort the stalled request so the COM object + socket are released
            ; now rather than lingering until WinHTTP's own timeout fires.
            try Http.Abort()
            _LLM_InvokeCallback(on_result, "on_result", false)
            return
        }
        SetTimer(() => _LLMRemote_PollReady(Http, on_result, start_tick, timeout_ms), -LLM_REMOTE_READY_PING_POLL_MS)
        return
    }
    status := 0
    try status := Http.Status
    _LLM_InvokeCallback(on_result, "on_result", status >= 200 and status < 300)
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

; Pull the generated text out of a provider response. First navigates the
; canonical JSON path per format with JsonParse (the same parser the Ollama
; path uses), which is robust against multi-block / reasoning shapes where the
; FIRST "content"/"text" string is NOT the answer (e.g. an Anthropic ``thinking``
; block preceding the ``text`` block, or an OpenRouter ``reasoning`` field before
; ``choices``). Only when the structured navigation misses (HTTP error body, a
; shape we don't model, malformed JSON) does it fall back to the legacy
; first-match regex. Returns "" when both miss — the caller treats that the same
; as a network failure: no tooltip, no crash.
_LLMRemoteParseResponse(Format, Body) {
    if (Body == "")
        return ""
    state := _LLMRemoteParseStructuredState(Format, Body)
    if !state["valid"]
        return ""
    if state["recognized"]
        return state["text"]
    return _LLMRemoteParseResponseRegex(Format, Body)
}

_LLMRemoteParseStructuredState(Format, Body) {
	try root := JsonParse(Body)
	catch
		return Map("valid", false, "recognized", false, "text", "")
	if !(root is Map)
		return Map("valid", true, "recognized", false, "text", "")
	if (Format == "anthropic") {
		if root.Has("content") and (root["content"] is Array) {
			for _, block in root["content"]
				if (block is Map) and block.Has("type") and block["type"] == "text"
						and block.Has("text") and Type(block["text"]) == "String"
					return Map("valid", true, "recognized", true, "text", block["text"])
		}
	} else if (Format == "gemini") {
		if root.Has("candidates") and (root["candidates"] is Array) and root["candidates"].Length {
			candidate := root["candidates"][1]
			if (candidate is Map) and candidate.Has("content") and (candidate["content"] is Map) {
				content := candidate["content"]
				if content.Has("parts") and (content["parts"] is Array)
					for _, part in content["parts"]
						if (part is Map) and part.Has("text") and Type(part["text"]) == "String"
							return Map("valid", true, "recognized", true, "text", part["text"])
			}
		}
	} else if root.Has("choices") and (root["choices"] is Array) and root["choices"].Length {
		choice := root["choices"][1]
		if (choice is Map) and choice.Has("message") and (choice["message"] is Map) {
			message := choice["message"]
			if message.Has("content") and Type(message["content"]) == "String"
				return Map("valid", true, "recognized", true, "text", message["content"])
		}
	}
	return Map("valid", true, "recognized", false, "text", "")
}

; Structured-navigation parse: walks the documented response tree for the
; format and returns the answer text, or "" when the expected path is absent
; (so the caller can fall back to the regex). Wrapped in try because JsonParse
; throws on malformed bodies (HTTP error pages) — that just means "fall back".
_LLMRemoteParseStructured(Format, Body) {
	state := _LLMRemoteParseStructuredState(Format, Body)
	return state["valid"] and state["recognized"] ? state["text"] : ""
}

; Anthropic Messages: ``content`` is an ARRAY of blocks; the answer is the first
; block with ``type == "text"`` — NOT necessarily the first block, which may be
; a ``thinking`` block. Returns the text already JSON-unescaped by JsonParse.
_LLMRemoteNavAnthropic(root) {
    if !root.Has("content") or !(root["content"] is Array)
        return ""
    for _idx, block in root["content"] {
        if !(block is Map)
            continue
        if !block.Has("type") or block["type"] != "text"
            continue
        if block.Has("text") and Type(block["text"]) == "String"
            return block["text"]
    }
    return ""
}

; Gemini: ``candidates[1].content.parts[1].text``. AHK arrays are 1-indexed, so
; the first candidate is index 1. Returns the FIRST text part of the first
; candidate — the cross-driver corpus contract (gemini_multipart_uses_first)
; requires first-part-only, mirroring the Anthropic/OpenAI navigators; a later
; part is a continuation/decoy, not a fragment to concatenate.
_LLMRemoteNavGemini(root) {
    if !root.Has("candidates") or !(root["candidates"] is Array) or root["candidates"].Length < 1
        return ""
    cand := root["candidates"][1]
    if !(cand is Map) or !cand.Has("content") or !(cand["content"] is Map)
        return ""
    content := cand["content"]
    if !content.Has("parts") or !(content["parts"] is Array)
        return ""
    for _idx, part in content["parts"] {
        if (part is Map) and part.Has("text") and Type(part["text"]) == "String"
            return part["text"]
    }
    return ""
}

; OpenAI Chat Completions (and every OpenAI-compatible gateway): the answer is
; ``choices[1].message.content``. Navigating to that exact field skips any
; sibling ``reasoning`` field (OpenRouter) or other decoy "content"-like keys
; that a first-match regex would grab by mistake.
_LLMRemoteNavOpenAI(root) {
    if !root.Has("choices") or !(root["choices"] is Array) or root["choices"].Length < 1
        return ""
    choice := root["choices"][1]
    if !(choice is Map) or !choice.Has("message") or !(choice["message"] is Map)
        return ""
    msg := choice["message"]
    if msg.Has("content") and Type(msg["content"]) == "String"
        return msg["content"]
    return ""
}

; Legacy first-match regex fallback. Kept verbatim from the original parser so a
; provider shape the structured navigator does not model still extracts SOMETHING
; rather than nothing — the same lenient behaviour the engine shipped before.
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

; Minimal JSON string escaper — enough for the user/system text we ship in the
; payload. Order matters: backslash MUST be escaped before quote so the second
; pass does not double-escape backslashes that the first pass produced.
_LLMRemoteJsonEscape(s) {
    s := StrReplace(s, "\",  "\\")
    s := StrReplace(s, '"',  '\"')
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`t", "\t")
    return s
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
    for _, pid in order {
        if (Type(pid) != "String" or pid = "")
            continue
        if !providers.Has(pid) {
            try LoggerWarn("LLM.remote", "api_providers.json: unknown provider '{1}' skipped.", pid)
            continue
        }
        desc := providers[pid]
        if !(desc is Map) {
            try LoggerWarn("LLM.remote", "api_providers.json: provider '{1}' is not an object and was skipped.", pid)
            continue
        }
        valid := true
        for req in ["label", "base_url", "default_model", "format"] {
			if (!desc.Has(req) or Type(desc[req]) != "String"
				or ((req = "label" or req = "format") and desc[req] = "")) {
                valid := false
                break
            }
        }
        if !valid {
            try LoggerWarn("LLM.remote", "api_providers.json: provider '{1}' has a non-string or empty descriptor and was skipped.", pid)
            continue
        }
        fmt := desc["format"]
        if (fmt != "openai" and fmt != "anthropic" and fmt != "gemini") {
            try LoggerWarn("LLM.remote", "api_providers.json: provider '{1}' has an unsupported format and was skipped.", pid)
            continue
        }
        candidateProviders[pid] := Map(
            "Label", desc["label"],
            "BaseUrl", desc["base_url"],
            "DefaultModel", desc["default_model"],
            "Format", fmt)
        candidateOrder.Push(pid)
    }

    candidatePrices := Map()
    for model, row in prices {
        validModel := Type(model) = "String" and model != ""
        validRow := row is Map and row.Has("in") and row.Has("out")
        if validRow
            validRow := row["in"] is Number and row["out"] is Number
                and row["in"] >= 0 and row["out"] >= 0
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
