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

    ProviderId := _LLMRemoteEntryGet(Entry, "Provider", "openai_compat")
    if !LLM_API_PROVIDERS.Has(ProviderId) {
        return ""
    }
    Provider := LLM_API_PROVIDERS[ProviderId]
    Format   := Provider["Format"]
    BaseUrl  := _LLMRemoteEntryGet(Entry, "BaseUrl", "")
    if (BaseUrl == "") {
        BaseUrl := Provider["BaseUrl"]
    }
    if (BaseUrl == "") {
        return ""
    }
    Token := _LLMRemoteEntryGet(Entry, "Token", "")
    Model := _LLMRemoteEntryGet(Entry, "Model", Provider["DefaultModel"])
    if (Model == "") {
        return ""
    }

    Url     := _LLMRemoteBuildUrl(BaseUrl, Format, Token, Model)
    Payload := _LLMRemoteBuildPayload(Format, Model, SystemPrompt, UserText, Temperature)

    try {
        Http := ComObject("WinHttp.WinHttpRequest.5.1")
        Http.Open("POST", Url, false)
        Http.SetTimeouts(LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_TIMEOUT_MS,
                        LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_TIMEOUT_MS)
        Http.SetRequestHeader("Content-Type", "application/json")
        _LLMRemoteSetAuthHeaders(Http, Format, Token)
        Http.Send(Payload)
        if (Http.Status < 200 or Http.Status >= 300) {
            return ""
        }
        return _LLMRemoteParseResponse(Format, Http.ResponseText)
    } catch as err {
        return ""
    }
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
