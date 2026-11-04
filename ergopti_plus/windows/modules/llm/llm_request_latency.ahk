; modules/llm/llm_request_latency.ahk

; ==============================================================================
; MODULE: LLM Request Latency
; DESCRIPTION:
; The one line the Windows driver writes per finished prediction request, the
; counterpart of the macOS and Linux answer lines: its provider kind (local or
; remote), its provider, its model family, its outcome and its duration, read
; by tools/dev/field-log-analyse.py and judged against the [budgets]
; llm_local_request_ms and llm_remote_request_ms of
; _shared/modules/timings/constants.toml.
;
; FEATURES & RATIONALE:
; 1. Never content: no prompt, context or answer reaches the line, and every
;    name is cut to the closed grammar of a code; a value outside it is logged
;    as "other".
; 2. The family drops the tag, the path and the size of a model id
;    ("qwen3.5:2b" and "mlx-community/Qwen3.5-4B-MLX-4bit" are both "qwen3.5"),
;    so a log groups the requests of one model family.
; 3. Kind: the Ollama backend and an API entry whose provider is a declared local
;    server (LLM_LOCAL_SERVER_SCANS, from local_servers.json) are local; every
;    other API provider is remote.
; ==============================================================================

#Requires AutoHotkey v2.0

; TickElapsed (infra/tick_count.ahk), PerfBudget_Report (infra/perf_budget.ahk),
; TimingsGet and the logger come from ErgoptiPlus.ahk: the test harnesses that
; load the prediction engine stub some of them, and a second definition would
; stop their load.

/**
 * Returns a value cut to the closed code grammar, or "other".
 * @param {Any} Value - A provider id or a model family.
 * @returns {String}
 */
_LLMRequestLatency_Code(Value) {
	Text := (Value is String) ? StrLower(Value) : ""
	return RegExMatch(Text, "^[a-z0-9_.:\-]{1,48}$") ? Text : "other"
}

/**
 * Returns the family of a model id: no organisation, no tag, no size.
 * @param {Any} Model - The model id the request named.
 * @returns {String} The family, a closed code.
 */
LLM_RequestLatency_Family(Model) {
	Text := (Model is String) ? StrLower(Model) : ""
	Text := RegExReplace(Text, "^.*/", "")
	Text := RegExReplace(Text, ":.*$", "")
	Text := RegExReplace(Text, "[-_ ]\d+(\.\d+)?[bm]\b.*$", "")
	return _LLMRequestLatency_Code(Text)
}

/**
 * Writes the latency line of one finished prediction request and, when it
 * answered, judges its duration against its budget.
 * @param {String} Backend - The engine's backend: "ollama" or "api".
 * @param {String} ProviderId - The API provider id, or "" for Ollama.
 * @param {String} Model - The model id the request named.
 * @param {Integer} StartTick - The A_TickCount the request was sent at.
 * @param {String} Outcome - "ok" or "failed".
 */
LLM_RequestLatency_Report(Backend, ProviderId, Model, StartTick, Outcome) {
	if !(Outcome == "ok" || Outcome == "failed")
		throw ValueError("LLM_RequestLatency_Report: unknown outcome " . String(Outcome))
	global LLM_LOCAL_SERVER_SCANS
	IsLocalServer := IsSet(LLM_LOCAL_SERVER_SCANS) && (LLM_LOCAL_SERVER_SCANS is Map)
		&& (ProviderId is String) && LLM_LOCAL_SERVER_SCANS.Has(ProviderId)
	Kind := (Backend == "ollama" || IsLocalServer) ? "local" : "remote"
	Provider := (Backend == "ollama") ? "ollama" : _LLMRequestLatency_Code(ProviderId)
	ElapsedMs := TickElapsed(StartTick)
	LoggerInfo("LLM", "LLM request: kind={1} provider={2} family={3} outcome={4} in {5} ms.",
		Kind, Provider, LLM_RequestLatency_Family(Model), Outcome, ElapsedMs)
	if (Outcome != "ok")
		return
	if (Kind == "local")
		PerfBudget_Report("LLM", "llm.local", ElapsedMs, TimingsGet("budgets", "llm_local_request_ms"))
	else
		PerfBudget_Report("LLM", "llm.remote", ElapsedMs, TimingsGet("budgets", "llm_remote_request_ms"))
}
