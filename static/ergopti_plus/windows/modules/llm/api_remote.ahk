; modules/llm/api_remote.ahk

; ==============================================================================
; MODULE: LLM API — Remote API Backend
; DESCRIPTION:
; Synchronous HTTP client for remote LLM APIs (OpenAI, Anthropic, Google Gemini,
; and any OpenAI-Chat-Completions-compatible endpoint such as Groq, OpenRouter,
; LM Studio, vLLM, llama.cpp's HTTP server, …). Sits next to api_ollama.ahk and
; exposes the same surface — ``LLM_RemoteGenerate`` returns the generated text
; (or "" on error) for the prediction engine to consume.
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

; Loaded from shared/llm/api_providers.json at boot (see _LLMRemote_LoadCatalog).
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

; Dispatch a prediction request to the remote API entry. Entry is the per-user
; record (Map or object) carrying:
;   - Provider — one of LLM_API_PROVIDERS keys.
;   - BaseUrl  — the endpoint URL (Entry.BaseUrl overrides the provider default).
;   - Token    — the API key / bearer.
;   - Model    — model name to request.
;
; Returns the generated text, or "" on any error (network, HTTP non-2xx, parse
; failure). Failure is silent by design so the prediction loop never crashes —
; the user gets no tooltip instead of an error dialog mid-typing.
LLM_RemoteGenerate(Entry, SystemPrompt, FullText, Temperature := 0.1, TailText := "", max_tokens := 256) {
    global LLM_API_PROVIDERS, LLM_REMOTE_TIMEOUT_MS

    resolved := _LLMRemoteResolveEntry(Entry)
    if (resolved == "")
        return ""

    req := _LLMRemote_BuildRequestContext(SystemPrompt, FullText, TailText)
    Url     := _LLMRemoteBuildUrl(resolved["BaseUrl"], resolved["Format"], resolved["Token"], resolved["Model"])
    Payload := _LLMRemoteBuildPayload(resolved["Format"], resolved["Model"], req["system"], req["user"], Temperature, max_tokens)

    try {
        Http := ComObject("WinHttp.WinHttpRequest.5.1")
        Http.Open("POST", Url, false)
        Http.SetTimeouts(LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_TIMEOUT_MS,
                        LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_TIMEOUT_MS)
        Http.SetRequestHeader("Content-Type", "application/json")
        _LLMRemoteSetAuthHeaders(Http, resolved["Format"], resolved["Token"])
        Http.Send(Payload)
        if (Http.Status < 200 or Http.Status >= 300) {
            return ""
        }
        return _LLMRemoteParseResponse(resolved["Format"], Http.ResponseText)
    } catch as err {
        return ""
    }
}



; =========================
; ===== Async surface =====
; =========================

; Registry of in-flight async remote requests (parallel to _LLM_Ollama_Async).
global _LLM_Remote_Async := Map()
global _LLM_Remote_AsyncCounter := 0
global LLM_REMOTE_POLL_MS := 0   ; sentinel — sourced at boot by LLMApiLoadTimings ([llm] poll_interval_ms)
global LLM_REMOTE_MAX_INFLIGHT := 16

/**
 * Non-blocking variant of LLM_RemoteGenerate. Mirrors hs.http.asyncPost on
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
LLM_RemoteGenerate_Async(Entry, SystemPrompt, FullText, Temperature, on_success, on_fail, TailText := "", max_tokens := 256) {
    global _LLM_Remote_Async, _LLM_Remote_AsyncCounter, LLM_REMOTE_TIMEOUT_MS

    _LLM_Remote_AsyncCounter += 1
    req_id := _LLM_Remote_AsyncCounter

    resolved := _LLMRemoteResolveEntry(Entry)
    if (resolved == "") {
        try on_fail()
        return req_id
    }

    req := _LLMRemote_BuildRequestContext(SystemPrompt, FullText, TailText)
    Url     := _LLMRemoteBuildUrl(resolved["BaseUrl"], resolved["Format"], resolved["Token"], resolved["Model"])
    Payload := _LLMRemoteBuildPayload(resolved["Format"], resolved["Model"], req["system"], req["user"], Temperature, max_tokens)

    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("POST", Url, true)
        http.SetTimeouts(LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_TIMEOUT_MS)
        http.SetRequestHeader("Content-Type", "application/json")
        _LLMRemoteSetAuthHeaders(http, resolved["Format"], resolved["Token"])
        http.Send(Payload)
    } catch as err {
        try on_fail()
        return req_id
    }

    _LLMRemote_TrimAsyncRegistry()
    _LLM_Remote_Async[req_id] := Map(
        "http", http, "format", resolved["Format"],
        "model_id_at_dispatch", resolved["Model"],
        "on_success", on_success, "on_fail", on_fail, "cancelled", false)
    _LLMRemote_PollRequest(req_id)
    return req_id
}

LLM_RemoteCancelAsync(req_id) {
    global _LLM_Remote_Async
    if !_LLM_Remote_Async.Has(req_id)
        return
    _LLM_Remote_Async[req_id]["cancelled"] := true
}

LLM_RemoteCancelAllAsync() {
    global _LLM_Remote_Async
    for _id, entry in _LLM_Remote_Async
        entry["cancelled"] := true
}

_LLMRemote_PollRequest(req_id) {
    global _LLM_Remote_Async, LLM_REMOTE_POLL_MS
    if !_LLM_Remote_Async.Has(req_id)
        return
    entry := _LLM_Remote_Async[req_id]
    if entry["cancelled"] {
        _LLM_Remote_Async.Delete(req_id)
        return
    }
    http := entry["http"]
    ready := false
    try ready := http.WaitForResponse(0)
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
        try on_fail()
        return
    }
    if (status < 200 or status >= 300) {
        try on_fail()
        return
    }
    text := _LLMRemoteParseResponse(entryFormat, body)
    if (text == "") {
        try on_fail()
        return
    }
    ; Pull the per-provider ``usage`` block out of the response so the
    ; engine can record tokens consumed + estimated cost in the keylogger
    ; event. Same shape as OpenAI / Anthropic / Gemini all carry; Ollama
    ; doesn't (its non-streaming response has ``eval_count`` /
    ; ``prompt_eval_count`` instead, which we don't parse for the remote
    ; path because the engine only treats local backends as "free").
    meta := _LLMRemoteExtractUsage(entryFormat, body, entry.Has("model_id_at_dispatch") ? entry["model_id_at_dispatch"] : "")
    try on_success(text, meta)
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
    ; Gemini uses ``promptTokenCount`` / ``candidatesTokenCount`` /
    ; ``totalTokenCount`` inside ``usageMetadata``.
    if (format == "gemini") {
        if RegExMatch(body, '"promptTokenCount"\s*:\s*([0-9]+)', &m)
            out["prompt_tokens"] := Integer(m[1])
        if RegExMatch(body, '"candidatesTokenCount"\s*:\s*([0-9]+)', &m)
            out["completion_tokens"] := Integer(m[1])
        if RegExMatch(body, '"totalTokenCount"\s*:\s*([0-9]+)', &m)
            out["total_tokens"] := Integer(m[1])
    } else if (format == "anthropic") {
        ; Anthropic: input_tokens / output_tokens at top level under ``usage``.
        if RegExMatch(body, '"input_tokens"\s*:\s*([0-9]+)', &m)
            out["prompt_tokens"] := Integer(m[1])
        if RegExMatch(body, '"output_tokens"\s*:\s*([0-9]+)', &m)
            out["completion_tokens"] := Integer(m[1])
        out["total_tokens"] := out["prompt_tokens"] + out["completion_tokens"]
    } else {
        ; OpenAI shape (also used by Mistral / DeepSeek / Cohere / xAI /
        ; Cerebras / openai_compat): prompt_tokens / completion_tokens /
        ; total_tokens inside ``usage``.
        if RegExMatch(body, '"prompt_tokens"\s*:\s*([0-9]+)', &m)
            out["prompt_tokens"] := Integer(m[1])
        if RegExMatch(body, '"completion_tokens"\s*:\s*([0-9]+)', &m)
            out["completion_tokens"] := Integer(m[1])
        if RegExMatch(body, '"total_tokens"\s*:\s*([0-9]+)', &m)
            out["total_tokens"] := Integer(m[1])
    }
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
    for oldest_id, _entry in _LLM_Remote_Async {
        _LLM_Remote_Async.Delete(oldest_id)
        return
    }
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
_LLMRemoteBuildPayload(Fmt, Model, SystemPrompt, UserText, Temperature, max_tokens := 256) {
    SysEsc  := _LLMRemoteJsonEscape(SystemPrompt)
    UserEsc := _LLMRemoteJsonEscape(UserText)
    ModelEsc := _LLMRemoteJsonEscape(Model)
    Temp := Format("{:.2f}", Temperature)
    ; Output-token cap threaded from the shared PromptBuilder budget (single
    ; cross-driver source); replaces the former hardcoded 256 in each provider
    ; branch. Falls back to 256 only for an out-of-range value.
    MaxTok := (max_tokens is Number and max_tokens > 0) ? Integer(max_tokens) : 256

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

; Pull the generated text out of a provider response. Each branch targets the
; canonical "first choice / first candidate / first content block" path. When
; the regex misses (HTTP error body, malformed JSON), returns "" — the caller
; treats that the same as a network failure: no tooltip, no crash.
_LLMRemoteParseResponse(Format, Body) {
    if (Body == "")
        return ""
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
    s := StrReplace(s, "\n", "`n")
    s := StrReplace(s, "\r", "`r")
    s := StrReplace(s, "\t", "`t")
    s := StrReplace(s, '\"', '"')
    s := StrReplace(s, "\\",  "\")
    return s
}

; ============================================
; ======= 4/ Shared catalogue loader =========
; ============================================

/**
 * Loads provider descriptors + model prices from shared/llm/api_providers.json.
 * Fail-fast when the file is missing or malformed — same contract as the HS twin.
 */
_LLMRemote_LoadCatalog() {
    global LLM_API_PROVIDERS, LLM_API_PROVIDER_ORDER, LLM_REMOTE_MODEL_PRICES, _SharedDir
    path := _SharedDir . "\llm\api_providers.json"
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

    LLM_API_PROVIDERS := Map()
    LLM_API_PROVIDER_ORDER := []
    for _, pid in order {
        if (Type(pid) != "String" or pid = "")
            throw Error("api_providers.json: invalid provider_order entry")
        if !providers.Has(pid)
            throw Error("api_providers.json: provider_order references unknown '" . pid . "'")
        desc := providers[pid]
        if !(desc is Map)
            throw Error("api_providers.json: providers." . pid . " must be an object")
        for req in ["label", "base_url", "default_model", "format"] {
            if !desc.Has(req)
                throw Error("api_providers.json: providers." . pid . " missing '" . req . "'")
        }
        fmt := desc["format"]
        if (fmt != "openai" and fmt != "anthropic" and fmt != "gemini")
            throw Error("api_providers.json: providers." . pid . " has invalid format '" . fmt . "'")
        LLM_API_PROVIDERS[pid] := Map(
            "Label", desc["label"],
            "BaseUrl", desc["base_url"],
            "DefaultModel", desc["default_model"],
            "Format", fmt)
        LLM_API_PROVIDER_ORDER.Push(pid)
    }

    LLM_REMOTE_MODEL_PRICES := Map()
    for model, row in prices {
        if !(row is Map) or !row.Has("in") or !row.Has("out")
            throw Error("api_providers.json: model_prices." . model . " must have in/out")
        LLM_REMOTE_MODEL_PRICES[model] := Map("in", row["in"], "out", row["out"])
    }
}

_LLMRemote_LoadCatalog()
