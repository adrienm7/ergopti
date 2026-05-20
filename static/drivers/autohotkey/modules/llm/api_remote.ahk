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

; Each provider ID maps to a descriptor consumed by LLM_RemoteGenerate. Fields:
;   - Label         — human-readable name shown in the picker dialog.
;   - BaseUrl       — default endpoint. The user can override per API entry.
;   - DefaultModel  — pre-filled when adding a new API entry; the user can
;                     replace it with any model the provider exposes.
;   - Format        — "openai" | "anthropic" | "gemini". Selects the request
;                     formatter and response parser at call time.
;
; Adding a new provider = one entry here + (optionally) a new Format branch in
; _LLMRemoteBuildPayload / _LLMRemoteParseResponse.
global LLM_API_PROVIDERS := Map(
    "openai", Map(
        "Label",        "OpenAI",
        "BaseUrl",      "https://api.openai.com/v1",
        "DefaultModel", "gpt-4o-mini",
        "Format",       "openai"
    ),
    "anthropic", Map(
        "Label",        "Anthropic",
        "BaseUrl",      "https://api.anthropic.com/v1",
        "DefaultModel", "claude-haiku-4-5",
        "Format",       "anthropic"
    ),
    "gemini", Map(
        "Label",        "Google Gemini",
        "BaseUrl",      "https://generativelanguage.googleapis.com/v1beta",
        "DefaultModel", "gemini-2.0-flash",
        "Format",       "gemini"
    ),
    ; xAI ships an OpenAI-compatible Chat Completions endpoint; the only
    ; difference is the URL. Bearer auth.
    "xai", Map(
        "Label",        "xAI (Grok)",
        "BaseUrl",      "https://api.x.ai/v1",
        "DefaultModel", "grok-2-mini",
        "Format",       "openai"
    ),
    ; Mistral: OpenAI-compatible at the URL below. ``mistral-small-latest``
    ; is the cheap-and-fast default; codestral / large stay accessible
    ; via the model field.
    "mistral", Map(
        "Label",        "Mistral",
        "BaseUrl",      "https://api.mistral.ai/v1",
        "DefaultModel", "mistral-small-latest",
        "Format",       "openai"
    ),
    ; DeepSeek: same shape as OpenAI. The ``deepseek-chat`` model is
    ; sized like gpt-4o-mini and competitively priced.
    "deepseek", Map(
        "Label",        "DeepSeek",
        "BaseUrl",      "https://api.deepseek.com",
        "DefaultModel", "deepseek-chat",
        "Format",       "openai"
    ),
    ; Cohere: speaks OpenAI Chat Completions via the v2 ``/chat`` route.
    ; ``command-r7b-12-2024`` is the small / fast tier.
    "cohere", Map(
        "Label",        "Cohere",
        "BaseUrl",      "https://api.cohere.com/v2",
        "DefaultModel", "command-r7b-12-2024",
        "Format",       "openai"
    ),
    ; Cerebras: hardware-accelerated Llama / Qwen inference. Pure
    ; OpenAI-compatible at /v1/chat/completions; the value-add is raw
    ; tokens-per-second (~1700 tok/s on Llama 3.1 70B), not the schema.
    "cerebras", Map(
        "Label",        "Cerebras",
        "BaseUrl",      "https://api.cerebras.ai/v1",
        "DefaultModel", "llama-3.1-8b",
        "Format",       "openai"
    ),
    ; Generic OpenAI-compatible covers Groq, OpenRouter, LM Studio, vLLM,
    ; llama.cpp HTTP server, Together.ai, Fireworks, DeepInfra, … — anything
    ; that speaks the Chat Completions schema. BaseUrl is empty so the user
    ; HAS to fill it in (no sensible default for a generic endpoint).
    "openai_compat", Map(
        "Label",        "OpenAI-compatible",
        "BaseUrl",      "",
        "DefaultModel", "",
        "Format",       "openai"
    )
)

global LLM_REMOTE_TIMEOUT_MS := 30000   ; same generous ceiling as Ollama




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
LLM_RemoteGenerate(Entry, SystemPrompt, UserText, Temperature := 0.1) {
    global LLM_API_PROVIDERS, LLM_REMOTE_TIMEOUT_MS

    resolved := _LLMRemoteResolveEntry(Entry)
    if (resolved == "")
        return ""

    Url     := _LLMRemoteBuildUrl(resolved["BaseUrl"], resolved["Format"], resolved["Token"], resolved["Model"])
    Payload := _LLMRemoteBuildPayload(resolved["Format"], resolved["Model"], SystemPrompt, UserText, Temperature)

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

; ============================================
; ===== Async surface =====
; ============================================

; Registry of in-flight async remote requests (parallel to _LLM_Ollama_Async).
global _LLM_Remote_Async := Map()
global _LLM_Remote_AsyncCounter := 0
global LLM_REMOTE_POLL_MS := 50
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
LLM_RemoteGenerate_Async(Entry, SystemPrompt, UserText, Temperature, on_success, on_fail) {
    global _LLM_Remote_Async, _LLM_Remote_AsyncCounter, LLM_REMOTE_TIMEOUT_MS

    _LLM_Remote_AsyncCounter += 1
    req_id := _LLM_Remote_AsyncCounter

    resolved := _LLMRemoteResolveEntry(Entry)
    if (resolved == "") {
        try on_fail()
        return req_id
    }

    Url     := _LLMRemoteBuildUrl(resolved["BaseUrl"], resolved["Format"], resolved["Token"], resolved["Model"])
    Payload := _LLMRemoteBuildPayload(resolved["Format"], resolved["Model"], SystemPrompt, UserText, Temperature)

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
    _LLM_Remote_Async[req_id] := Map("http", http, "format", resolved["Format"], "on_success", on_success, "on_fail", on_fail, "cancelled", false)
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
    format     := entry["format"]
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
    text := _LLMRemoteParseResponse(format, body)
    if (text == "") {
        try on_fail()
        return
    }
    try on_success(text)
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
    Format   := Provider["Format"]
    BaseUrl  := _LLMRemoteEntryGet(Entry, "BaseUrl", "")
    if (BaseUrl == "")
        BaseUrl := Provider["BaseUrl"]
    if (BaseUrl == "")
        return ""
    Token := _LLMRemoteEntryGet(Entry, "Token", "")
    Model := _LLMRemoteEntryGet(Entry, "Model", Provider["DefaultModel"])
    if (Model == "")
        return ""
    return Map("Provider", ProviderId, "Format", Format, "BaseUrl", BaseUrl, "Token", Token, "Model", Model)
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
    Format := Provider["Format"]
    PingUrl := ""
    if (Format == "openai" or Format == "anthropic") {
        PingUrl := RTrim(BaseUrl, "/") . "/models"
    } else if (Format == "gemini") {
        PingUrl := RTrim(BaseUrl, "/") . "/models?key=" . Token
    }
    if (PingUrl == "") {
        return false
    }
    try {
        Http := ComObject("WinHttp.WinHttpRequest.5.1")
        Http.Open("GET", PingUrl, false)
        Http.SetTimeouts(2000, 2000, 2000, 2000)
        _LLMRemoteSetAuthHeaders(Http, Format, Token)
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
_LLMRemoteBuildUrl(BaseUrl, Format, Token, Model) {
    Trimmed := RTrim(BaseUrl, "/")
    if (Format == "anthropic") {
        return Trimmed . "/messages"
    }
    if (Format == "gemini") {
        ; Gemini's path is /models/<model>:generateContent?key=<token>.
        Encoded := ""
        try Encoded := DllCall("Shlwapi\UrlEscapeW", "WStr", Token, "WStr", "", "UInt*", &Out := 0, "UInt", 0, "Str")
        ; Fallback: send token raw — providers accept basic URL-safe characters.
        if (Encoded == "")
            Encoded := Token
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
_LLMRemoteBuildPayload(Format, Model, SystemPrompt, UserText, Temperature) {
    SysEsc  := _LLMRemoteJsonEscape(SystemPrompt)
    UserEsc := _LLMRemoteJsonEscape(UserText)
    ModelEsc := _LLMRemoteJsonEscape(Model)
    Temp := Format("{:.2f}", Temperature)

    if (Format == "anthropic") {
        ; Anthropic Messages API: top-level ``system`` field, ``messages`` is
        ; user/assistant turns only. ``max_tokens`` is REQUIRED by Anthropic.
        return Format('{"model":"{1}","system":"{2}","messages":[{"role":"user","content":"{3}"}],"max_tokens":256,"temperature":{4}}',
            ModelEsc, SysEsc, UserEsc, Temp)
    }
    if (Format == "gemini") {
        ; Gemini wraps the system instruction in ``systemInstruction`` and the
        ; user turn in ``contents.parts.text``.
        return Format('{"systemInstruction":{"parts":[{"text":"{1}"}]},"contents":[{"role":"user","parts":[{"text":"{2}"}]}],"generationConfig":{"temperature":{3},"maxOutputTokens":256}}',
            SysEsc, UserEsc, Temp)
    }
    ; OpenAI Chat Completions shape — covers OpenAI itself plus every
    ; OpenAI-compatible endpoint (Groq, OpenRouter, LM Studio, vLLM, …).
    return Format('{"model":"{1}","messages":[{"role":"system","content":"{2}"},{"role":"user","content":"{3}"}],"temperature":{4},"max_tokens":256,"stream":false}',
        ModelEsc, SysEsc, UserEsc, Temp)
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
