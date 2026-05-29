--- modules/llm/api_remote.lua

--- ==============================================================================
--- MODULE: LLM API Controller (Remote)
--- DESCRIPTION:
--- Async HTTP client for remote LLM APIs (OpenAI, Anthropic, Google Gemini,
--- and any OpenAI-Chat-Completions-compatible endpoint such as Groq, OpenRouter,
--- LM Studio, vLLM, Together, Fireworks…). Mirrors the AHK twin
--- (modules/llm/api_remote.ahk) so both drivers expose the same provider
--- catalogue and surface, but adapted to the HS engine's fetch_batch /
--- fetch_sequential / fetch_parallel surface so the prediction engine can
--- dispatch to it transparently.
---
--- FEATURES & RATIONALE:
--- 1. Provider catalogue — each entry declares Label, BaseUrl, DefaultModel
---    and Format (openai / anthropic / gemini). Adding a new provider is a
---    single table entry plus (optionally) a new branch in the formatter and
---    parser helpers; the engine and menu stay unchanged.
--- 2. Async non-streaming — every call goes through ``hs.http.asyncPost`` so
---    the main thread never blocks. Remote streaming is intentionally OFF:
---    the three popular streaming flavours (OpenAI SSE / Anthropic event
---    stream / Gemini chunked JSONL) all parse differently, and for the
---    short completions this engine targets (3–15 words) the latency gain
---    is ~200–500 ms — not enough to justify three brittle codecs. The
---    rate-limit floor in inference.json plus the user's debounce already
---    pace requests, so the synchronous shape keeps error paths trivial.
--- 3. Multi-entry state — the user can configure several API entries (one per
---    provider/account) and switch between them via the tray menu. Each
---    fetch picks up the active entry at dispatch time so a switch takes
---    effect on the very next prediction.
--- ==============================================================================

local M = {}

local Logger         = require("lib.logger")
local Profiles       = require("modules.llm.profiles")
local Parser         = require("modules.llm.parser")
local ApiCommon      = require("modules.llm.api_common")
local HttpClient     = require("adapters.http_client").new()
local JsonCodec      = require("adapters.json_codec")
local TimerScheduler = require("adapters.timer_scheduler")
local LOG            = "llm.api_remote"

local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end




-- =======================================
-- =======================================
-- ======= 1/ Provider Catalogue =========
-- =======================================
-- =======================================

--- Map of provider id → descriptor. Each descriptor MUST match the schema:
---   { label = string, base_url = string, default_model = string, format = string }
--- where ``format`` is one of "openai" | "anthropic" | "gemini" and selects the
--- request/response codec at call time.
M.PROVIDERS = {
	openai = {
		label         = "OpenAI",
		base_url      = "https://api.openai.com/v1",
		default_model = "gpt-4o-mini",
		format        = "openai",
	},
	anthropic = {
		label         = "Anthropic",
		base_url      = "https://api.anthropic.com/v1",
		default_model = "claude-haiku-4-5",
		format        = "anthropic",
	},
	gemini = {
		label         = "Google Gemini",
		base_url      = "https://generativelanguage.googleapis.com/v1beta",
		default_model = "gemini-2.0-flash",
		format        = "gemini",
	},
	-- xAI ships an OpenAI-compatible Chat Completions endpoint. Bearer auth.
	xai = {
		label         = "xAI (Grok)",
		base_url      = "https://api.x.ai/v1",
		default_model = "grok-2-mini",
		format        = "openai",
	},
	-- Mistral: OpenAI-compatible Chat Completions. mistral-small-latest is
	-- the cheap-and-fast default; codestral / large stay accessible via the
	-- model field on the entry.
	mistral = {
		label         = "Mistral",
		base_url      = "https://api.mistral.ai/v1",
		default_model = "mistral-small-latest",
		format        = "openai",
	},
	-- DeepSeek: same shape as OpenAI. deepseek-chat is sized like
	-- gpt-4o-mini and competitively priced.
	deepseek = {
		label         = "DeepSeek",
		base_url      = "https://api.deepseek.com",
		default_model = "deepseek-chat",
		format        = "openai",
	},
	-- Cohere: exposes an OpenAI-compatible Chat Completions route at
	-- ``/compatibility/v1`` (NOT the native ``/v2/chat`` route, which has a
	-- different schema). Pointing at /v2 returned 404 on every request.
	cohere = {
		label         = "Cohere",
		base_url      = "https://api.cohere.ai/compatibility/v1",
		default_model = "command-r7b-12-2024",
		format        = "openai",
	},
	-- Cerebras: hardware-accelerated Llama / Qwen inference. Pure
	-- OpenAI-compatible at /v1/chat/completions; the value-add is raw
	-- tokens-per-second (~1700 tok/s on Llama 3.1 70B), not the schema.
	cerebras = {
		label         = "Cerebras",
		base_url      = "https://api.cerebras.ai/v1",
		default_model = "llama-3.1-8b",
		format        = "openai",
	},
	-- Generic OpenAI-compatible covers Groq, OpenRouter, LM Studio, vLLM,
	-- llama.cpp HTTP server, Together.ai, Fireworks, DeepInfra, … —
	-- anything that speaks the Chat Completions schema. ``base_url`` is
	-- empty so the user has to fill it in (no sensible default for a
	-- generic endpoint).
	openai_compat = {
		label         = "OpenAI-compatible",
		base_url      = "",
		default_model = "",
		format        = "openai",
	},
}

-- Per-provider ordered listing for the picker UI (Lua tables don't preserve
-- order; this array is the user-facing display order).
M.PROVIDER_ORDER = { "openai", "anthropic", "gemini", "xai", "mistral", "deepseek", "cohere", "cerebras", "openai_compat" }

local REQUEST_TIMEOUT_S = 30

local DEDUPLICATION_ENABLED      = ApiCommon.DEFAULT_DEDUPLICATION_ENABLED
-- Retry policy from shared/llm/inference.json (api_common.lua) so the
-- remote backend tracks the same retry budget as Ollama / MLX.
local _R_MAX_MULT, _R_TEMP_STEP, _R_EXTRA_TOKENS = ApiCommon.get_retry_policy()
local RETRY_FAILED_PREDICTION    = (_R_MAX_MULT or 0) > 1
local RETRY_FAILED_MAX_MULT      = _R_MAX_MULT




-- =======================================
-- =======================================
-- ======= 2/ Multi-Entry State ==========
-- =======================================
-- =======================================

-- Array of user-configured API entries. Each entry is a table:
--   { id, provider, base_url?, token, model, label? }
-- ``base_url`` overrides the provider default when present (empty string =
-- inherit). ``label`` is a user-friendly name shown in the entry picker.
local _entries = {}
local _active_id = ""
local _is_ready = false

--- Replace the full list of configured API entries. Used at load time from
--- the persisted JSON sidecar and whenever the tray menu adds / removes one.
--- @param entries table Array of entry tables. Pass {} to clear.
function M.set_entries(entries)
	if type(entries) ~= "table" then return end
	_entries = {}
	for _, e in ipairs(entries) do
		if type(e) == "table" then table.insert(_entries, e) end
	end
	Logger.debug(LOG, "API entries set (%d entry/entries).", #_entries)
end

function M.get_entries()
	return _entries
end

--- Pick the active API entry by id. When the id is empty or unknown, the
--- first entry wins — same fallback as the AHK twin, so the engine never
--- silently produces no predictions when the user has at least one entry
--- configured but no explicit selection yet.
--- @param id string Active entry identifier (matches entry.id field).
function M.set_active_entry_id(id)
	if type(id) ~= "string" then return end
	_active_id = id
	Logger.debug(LOG, "Active API entry id: '%s'.", id)
end

function M.get_active_entry_id()
	return _active_id
end

--- Resolve the currently active entry, falling back to the first configured
--- one when no id matches. Returns nil when no entry exists at all.
--- @return table|nil entry
function M.get_active_entry()
	if #_entries == 0 then return nil end
	if _active_id ~= "" then
		for _, e in ipairs(_entries) do
			if e.id == _active_id then return e end
		end
	end
	return _entries[1]
end




-- =======================================
-- =======================================
-- ======= 3/ URL + Auth Helpers =========
-- =======================================
-- =======================================

--- Trim a trailing slash if present. Lua's string.gsub returns the count too,
--- so we drop it with a parenthesised expression for cleanliness.
local function rtrim_slash(s)
	return (tostring(s or ""):gsub("/+$", ""))
end

--- Build the per-provider request URL. Gemini bakes the model and API key
--- into the path; the OpenAI / Anthropic / OpenAI-compat shapes use a fixed
--- endpoint with the model in the JSON payload.
local function build_url(base_url, format, model, token)
	local base = rtrim_slash(base_url)
	if format == "anthropic" then
		return base .. "/messages"
	end
	if format == "gemini" then
		-- Gemini: /models/<model>:generateContent?key=<token>
		local enc = HttpClient.encodeForQuery(token)
		return base .. "/models/" .. model .. ":generateContent?key=" .. enc
	end
	-- OpenAI / OpenAI-compatible
	return base .. "/chat/completions"
end

--- Compute the per-provider auth headers. Gemini carries auth via the URL
--- query string and has nothing to add here; OpenAI uses Bearer; Anthropic
--- uses x-api-key + a fixed version pin.
local function build_headers(format, token)
	local headers = { ["Content-Type"] = "application/json" }
	if format == "anthropic" then
		if token and token ~= "" then headers["x-api-key"] = token end
		headers["anthropic-version"] = "2023-06-01"
		return headers
	end
	if format == "gemini" then
		-- Token already in the URL.
		return headers
	end
	if token and token ~= "" then
		headers["Authorization"] = "Bearer " .. token
	end
	return headers
end

--- Build the JSON payload for the chosen provider format. We keep the body
--- minimal but correct: one system message + one user message + temperature.
--- Streaming is OFF — the engine-level pacing already protects paid quotas,
--- and the single-shot path keeps error handling trivial.
local function build_payload(format, model, system_prompt, user_prompt, temperature, max_tokens)
	temperature = tonumber(temperature) or 0.1
	max_tokens  = tonumber(max_tokens) or 256

	if format == "anthropic" then
		return {
			model      = model,
			system     = system_prompt or "",
			messages   = { { role = "user", content = user_prompt or "" } },
			max_tokens = max_tokens,
			temperature = temperature,
		}
	end
	if format == "gemini" then
		return {
			systemInstruction = { parts = { { text = system_prompt or "" } } },
			contents          = { { role = "user", parts = { { text = user_prompt or "" } } } },
			generationConfig  = { temperature = temperature, maxOutputTokens = max_tokens },
		}
	end
	-- OpenAI Chat Completions
	return {
		model       = model,
		messages    = {
			{ role = "system", content = system_prompt or "" },
			{ role = "user",   content = user_prompt   or "" },
		},
		temperature = temperature,
		max_tokens  = max_tokens,
		stream      = false,
	}
end

--- Per-model USD price table (per 1M tokens). Mirror of the AHK
--- LLM_REMOTE_MODEL_PRICES map in api_remote.ahk — keep in lockstep when
--- providers re-tariff. Models not in the table fall back to 0 — cost is
--- reported as 0 rather than a wrong number, and the user knows to add
--- the pricing if they care about the metric.
local MODEL_PRICES = {
	-- OpenAI
	["gpt-4o-mini"]          = { ["in"] = 0.15,  ["out"] = 0.60 },
	["gpt-4o"]               = { ["in"] = 2.50,  ["out"] = 10.00 },
	["gpt-4.1-mini"]         = { ["in"] = 0.40,  ["out"] = 1.60 },
	["gpt-4.1"]              = { ["in"] = 2.00,  ["out"] = 8.00 },
	-- Anthropic
	["claude-haiku-4-5"]     = { ["in"] = 0.25,  ["out"] = 1.25 },
	["claude-sonnet-4-6"]    = { ["in"] = 3.00,  ["out"] = 15.00 },
	["claude-opus-4-7"]      = { ["in"] = 15.00, ["out"] = 75.00 },
	-- Gemini — ``gemini-2.0-pro`` was a tentative SKU that never shipped
	-- under that exact name; the actual large-tier Gemini at the time of
	-- writing is ``gemini-1.5-pro``. Both kept so an older config doesn't
	-- regress to zero cost while the user retunes.
	["gemini-2.0-flash"]     = { ["in"] = 0.10,  ["out"] = 0.40 },
	["gemini-1.5-pro"]       = { ["in"] = 1.25,  ["out"] = 5.00 },
	["gemini-2.0-pro"]       = { ["in"] = 1.25,  ["out"] = 5.00 },
	-- xAI — ``grok-2-mini`` was the original public mini-tier slug; xAI's
	-- current public API uses ``grok-2-1212`` (and ``grok-2`` as alias).
	-- Verify against https://docs.x.ai/docs before billing on these.
	["grok-2-mini"]          = { ["in"] = 0.30,  ["out"] = 0.50 },
	["grok-2-1212"]          = { ["in"] = 2.00,  ["out"] = 10.00 },
	["grok-2"]               = { ["in"] = 2.00,  ["out"] = 10.00 },
	-- Mistral
	["mistral-small-latest"] = { ["in"] = 0.20,  ["out"] = 0.60 },
	["mistral-large-latest"] = { ["in"] = 2.00,  ["out"] = 6.00 },
	-- DeepSeek
	["deepseek-chat"]        = { ["in"] = 0.14,  ["out"] = 0.28 },
	-- Cohere
	["command-r7b-12-2024"]  = { ["in"] = 0.0375,["out"] = 0.15 },
	["command-r-plus"]       = { ["in"] = 2.50,  ["out"] = 10.00 },
	-- Cerebras
	["llama-3.1-8b"]         = { ["in"] = 0.10,  ["out"] = 0.10 },
	["llama-3.1-70b"]        = { ["in"] = 0.60,  ["out"] = 0.60 },
}

local function estimate_cost(model, in_tokens, out_tokens)
	if not model or model == "" or not MODEL_PRICES[model] then return 0.0 end
	local p = MODEL_PRICES[model]
	return (in_tokens * p["in"] + out_tokens * p["out"]) / 1000000.0
end

--- Extract token usage from the provider response. Each format exposes the
--- same numeric fields under a top-level ``usage`` block (OpenAI shape) or
--- under ``usageMetadata`` (Gemini). We regex-scrape rather than re-parse
--- JSON (the response body has already been parsed once in parse_response;
--- doing it twice on every request is wasteful when this is a hot path).
local function _extract_usage(format, body, model)
	local out = { prompt_tokens = 0, completion_tokens = 0, total_tokens = 0, est_cost_usd = 0.0 }
	if not body or body == "" then return out end
	if format == "gemini" then
		out.prompt_tokens     = tonumber((body:match('"promptTokenCount"%s*:%s*(%d+)'))     or 0) or 0
		out.completion_tokens = tonumber((body:match('"candidatesTokenCount"%s*:%s*(%d+)')) or 0) or 0
		out.total_tokens      = tonumber((body:match('"totalTokenCount"%s*:%s*(%d+)'))      or 0) or 0
	elseif format == "anthropic" then
		out.prompt_tokens     = tonumber((body:match('"input_tokens"%s*:%s*(%d+)'))  or 0) or 0
		out.completion_tokens = tonumber((body:match('"output_tokens"%s*:%s*(%d+)')) or 0) or 0
		out.total_tokens      = out.prompt_tokens + out.completion_tokens
	else
		out.prompt_tokens     = tonumber((body:match('"prompt_tokens"%s*:%s*(%d+)'))     or 0) or 0
		out.completion_tokens = tonumber((body:match('"completion_tokens"%s*:%s*(%d+)')) or 0) or 0
		out.total_tokens      = tonumber((body:match('"total_tokens"%s*:%s*(%d+)'))      or 0) or 0
	end
	if out.total_tokens == 0 and out.prompt_tokens > 0 then
		out.total_tokens = out.prompt_tokens + out.completion_tokens
	end
	out.est_cost_usd = estimate_cost(model, out.prompt_tokens, out.completion_tokens)
	return out
end

--- Pull the generated text out of a provider response. Each branch targets the
--- canonical "first choice / first candidate / first content block" path. When
--- the path is missing, returns "" — the caller treats that as a soft failure
--- (no tooltip) rather than a crash.
local function parse_response(format, body)
	if type(body) ~= "string" or body == "" then return "" end
	local resp, _ = JsonCodec.decode(body)
	if type(resp) ~= "table" then return "" end

	if format == "anthropic" then
		local content = resp.content
		if type(content) == "table" and type(content[1]) == "table" then
			return tostring(content[1].text or "")
		end
		return ""
	end
	if format == "gemini" then
		local cand = resp.candidates
		if type(cand) == "table" and type(cand[1]) == "table" then
			local cnt = cand[1].content
			if type(cnt) == "table" and type(cnt.parts) == "table" and type(cnt.parts[1]) == "table" then
				return tostring(cnt.parts[1].text or "")
			end
		end
		return ""
	end
	-- OpenAI shape: { choices = [ { message = { content = "..." } } ] }
	local choices = resp.choices
	if type(choices) == "table" and type(choices[1]) == "table" then
		local msg = choices[1].message
		if type(msg) == "table" then
			return tostring(msg.content or "")
		end
	end
	return ""
end




-- =======================================
-- =======================================
-- ======= 4/ Backend Surface ============
-- =======================================
-- =======================================

--- Returns true once at least one configured entry has been ping-confirmed
--- ready. The prediction engine uses this to gate its loading-tooltip /
--- dispatch path — same contract as api_ollama.is_ready.
function M.is_ready()
	return _is_ready
end

--- API "warmup" maps to a cheap availability check rather than a model load —
--- remote providers don't have a GPU-cache cold-start the way Ollama/MLX do.
--- A successful ping flips ``_is_ready`` so the prediction engine starts
--- dispatching real requests immediately.
function M.warmup(_model_name, _profile)
	local entry = M.get_active_entry()
	if not entry then
		_is_ready = false
		Logger.debug(LOG, "warmup: no API entry configured.")
		return
	end
	local provider = M.PROVIDERS[entry.provider]
	if not provider then
		_is_ready = false
		Logger.debug(LOG, "warmup: unknown provider '%s'.", tostring(entry.provider))
		return
	end
	local base = (entry.base_url and entry.base_url ~= "") and entry.base_url or provider.base_url
	if base == "" then
		_is_ready = false
		Logger.debug(LOG, "warmup: empty base_url for provider '%s'.", entry.provider)
		return
	end
	local token = entry.token or ""
	if token == "" then
		_is_ready = false
		Logger.debug(LOG, "warmup: no token configured for entry '%s'.", tostring(entry.id))
		return
	end

	-- /models is the canonical cheap ping for OpenAI-shape and Anthropic; for
	-- Gemini the same shape works (with ?key= in the URL). A 200 confirms
	-- both reachability and auth.
	local format = provider.format
	local ping_url
	if format == "gemini" then
		local enc = HttpClient.encodeForQuery(token)
		ping_url = rtrim_slash(base) .. "/models?key=" .. enc
	else
		ping_url = rtrim_slash(base) .. "/models"
	end

	HttpClient.get(ping_url, build_headers(format, token), function(r)
		local was_ready = _is_ready
		_is_ready = r.ok
		if _is_ready and not was_ready then
			Logger.info(LOG, "Remote API ready (provider=%s, model=%s).",
				tostring(entry.provider), tostring(entry.model))
		elseif not _is_ready then
			Logger.warn(LOG, "Remote API ping failed (status=%s) for provider=%s.",
				tostring(r.status), tostring(entry.provider))
		end
	end)
end

--- No active stream to terminate — the remote path is request/response.
--- Kept as a no-op so the engine's dispatch surface stays identical across
--- backends and there is no need for a "supports streaming?" capability flag.
function M.cancel_streaming()
end

--- Async availability check used by the menu / status indicator. Calls
--- ``on_available()`` on HTTP 2xx, ``on_missing(unreachable_bool)`` on any
--- other status. ``model_name`` is accepted for surface parity but ignored:
--- remote providers list models, not a single configured one — exhaustive
--- model verification belongs in the picker, not the hot path.
function M.check_availability(_model_name, on_available, on_missing)
	local entry = M.get_active_entry()
	if not entry then
		if type(on_missing) == "function" then pcall(on_missing, true) end
		return
	end
	local provider = M.PROVIDERS[entry.provider]
	if not provider then
		if type(on_missing) == "function" then pcall(on_missing, true) end
		return
	end
	local base = (entry.base_url and entry.base_url ~= "") and entry.base_url or provider.base_url
	if base == "" or (entry.token or "") == "" then
		if type(on_missing) == "function" then pcall(on_missing, true) end
		return
	end

	local format = provider.format
	local url
	if format == "gemini" then
		local enc = HttpClient.encodeForQuery(entry.token)
		url = rtrim_slash(base) .. "/models?key=" .. enc
	else
		url = rtrim_slash(base) .. "/models"
	end

	HttpClient.get(url, build_headers(format, entry.token), function(r)
		if r.ok then
			if type(on_available) == "function" then pcall(on_available) end
		else
			if type(on_missing) == "function" then pcall(on_missing, r.status == 0) end
		end
	end)
end




-- =======================================
-- =======================================
-- ======= 5/ Request + Parse ============
-- =======================================
-- =======================================

local _req_counter = 0

--- Fire a single non-streaming remote request and turn the response into one
--- or more prediction objects via ``Parser.process_prediction`` /
--- ``Parser.split_blocks``. The signature mirrors api_ollama's
--- ``post_and_parse`` so the higher-level fetch_* strategies can keep their
--- structure unchanged.
local function post_and_parse(model_name, system_prompt, full_text, tail_text,
                               temperature, max_tokens, num_predictions, is_batch,
                               on_success, on_fail, dedup_stats)
	local entry = M.get_active_entry()
	if not entry then
		if type(on_fail) == "function" then pcall(on_fail) end
		return
	end
	local provider = M.PROVIDERS[entry.provider]
	if not provider then
		if type(on_fail) == "function" then pcall(on_fail) end
		return
	end
	local base = (entry.base_url and entry.base_url ~= "") and entry.base_url or provider.base_url
	local model = (model_name and model_name ~= "") and model_name or (entry.model and entry.model ~= "" and entry.model) or provider.default_model
	if base == "" or model == "" then
		if type(on_fail) == "function" then pcall(on_fail) end
		return
	end

	_req_counter = _req_counter + 1
	local req_id = _req_counter

	-- Compose user prompt: the engine's profile already injects PREFIX/TAIL
	-- markers or {context} substitution upstream, but for remote providers we
	-- still need to fall back gracefully when the active profile expects a
	-- different shape. Mirror api_ollama.build_request_context's intent: if
	-- the system prompt asks for PREFIX/TAIL, format the user turn as such;
	-- otherwise pass the full context as-is.
	local final_sys = system_prompt
	if type(final_sys) == "string" then
		final_sys = final_sys:gsub("%{n%}", tostring(num_predictions))
	end
	local user_prompt = ""
	if type(final_sys) == "string" and final_sys:find("PREFIX") and final_sys:find("TAIL") then
		user_prompt = string.format("PREFIX: \"%s\"\nTAIL: \"%s\"", full_text or "", tail_text or "")
	else
		local ctx = type(full_text) == "string" and full_text or ""
		if type(final_sys) == "string" and final_sys:find("{context}", 1, true) then
			final_sys  = final_sys:gsub("%{context%}", function() return ctx end)
			user_prompt = ""
			-- Some providers (Gemini) handle systemInstruction; keep ctx empty so
			-- the user turn doesn't duplicate the system prompt content.
		else
			user_prompt = ctx
		end
	end

	local payload = build_payload(provider.format, model, final_sys or "", user_prompt, temperature, max_tokens)
	local encoded, enc_err = JsonCodec.encode(payload)
	if not encoded then
		Logger.error(LOG, "[%s] #%d Payload encode failed — %s", model, req_id, tostring(enc_err))
		if type(on_fail) == "function" then pcall(on_fail) end
		return
	end

	local url     = build_url(base, provider.format, model, entry.token or "")
	local headers = build_headers(provider.format, entry.token or "")
	local t0      = TimerScheduler.now()

	Logger.debug(LOG, "[%s] #%d POST -> %s (provider=%s, %d chars prompt)",
		model, req_id, url, provider.format, #(user_prompt or ""))

	HttpClient.post(url, headers, encoded, function(r)
		local status, body = r.status, r.body
		pcall(function()
			local ms = math.floor((TimerScheduler.now() - t0) * 1000)
			if not r.ok then
				Logger.error(LOG, "[%s] #%d HTTP_ERROR status=%s body=%s",
					model, req_id, tostring(status), (body or ""):sub(1, 200))
				-- Log the failure so the audit trail shows it instead of
				-- silently dropping. Same envelope as keylogger.log_llm
				-- but routed to log_llm_failed; the engine doesn't need
				-- to know about the distinction.
				if keylogger and type(keylogger.log_llm_failed) == "function" then
					pcall(keylogger.log_llm_failed, full_text, nil, {
						backend        = "api",
						model          = tostring(model),
						system_prompt  = system_prompt,
						user_prompt    = user_prompt,
						failure_reason = "http_" .. tostring(status or "unknown"),
						elapsed_ms     = ms,
					})
				end
				if type(on_fail) == "function" then pcall(on_fail) end
				return
			end

			local raw_text = parse_response(provider.format, body)
			if raw_text == "" then
				Logger.warn(LOG, "[%s] #%d empty completion (could not parse).", model, req_id)
				if keylogger and type(keylogger.log_llm_failed) == "function" then
					pcall(keylogger.log_llm_failed, full_text, nil, {
						backend        = "api",
						model          = tostring(model),
						system_prompt  = system_prompt,
						user_prompt    = user_prompt,
						failure_reason = "parse_empty",
						elapsed_ms     = ms,
					})
				end
				if type(on_fail) == "function" then pcall(on_fail) end
				return
			end

			local raw     = Parser.strip_thinking(raw_text)
			local results = {}
			if not is_batch then
				local pred = Parser.process_prediction(full_text, tail_text, raw)
				if pred then ApiCommon.insert_prediction(results, pred, dedup_stats, DEDUPLICATION_ENABLED, Logger, LOG) end
			else
				for _, block in ipairs(Parser.split_blocks(raw)) do
					if #results >= num_predictions then break end
					local pred = Parser.process_prediction(full_text, tail_text, block)
					if pred then ApiCommon.insert_prediction(results, pred, dedup_stats, DEDUPLICATION_ENABLED, Logger, LOG) end
				end
			end

			if #results == 0 then
				Logger.debug(LOG, "[%s] #%d PARSED -> 0 result (parser failure)", model, req_id)
				if keylogger and type(keylogger.log_llm_failed) == "function" then
					pcall(keylogger.log_llm_failed, full_text, nil, {
						backend        = "api",
						model          = tostring(model),
						system_prompt  = system_prompt,
						user_prompt    = user_prompt,
						failure_reason = "parser_no_blocks",
						elapsed_ms     = ms,
					})
				end
				if type(on_fail) == "function" then pcall(on_fail) end
				return
			end

			-- Token usage + cost extraction. Each provider exposes the same
			-- numeric fields under a top-level ``usage`` block (OpenAI shape)
			-- or under ``usageMetadata`` (Gemini). Cost is computed from the
			-- per-model price table in pricing.lua.
			local usage = _extract_usage(provider.format, body, tostring(model))

			Logger.debug(LOG, "[%s] #%d PARSED -> %d result(s) in %dms", model, req_id, #results, ms)
			if keylogger and type(keylogger.log_llm) == "function" then
				pcall(keylogger.log_llm, full_text, results, nil, {
					backend           = "api",
					model             = tostring(model),
					system_prompt     = system_prompt,
					user_prompt       = user_prompt,
					prompt_tokens     = usage.prompt_tokens,
					completion_tokens = usage.completion_tokens,
					total_tokens      = usage.total_tokens,
					est_cost_usd      = usage.est_cost_usd,
					elapsed_ms        = ms,
				})
			end
			if type(on_success) == "function" then pcall(on_success, results) end
		end)
	end)
end




-- =======================================
-- =======================================
-- ======= 6/ Fetch Strategies ===========
-- =======================================
-- =======================================

--- Batch strategy: one request, the model returns N completions in a single
--- response. Mirrors api_ollama.fetch_batch but with the remote post_and_parse
--- helper. Most remote providers don't natively expose a "n completions" knob
--- — instead we ask once and let the parser split blocks (which is what the
--- profile prompt sets up).
function M.fetch_batch(full_text, tail_text, model_name, temperature,
                       max_predict, num_predictions, profile,
                       on_success, on_fail, request_id_provider, _streaming, _on_partial)
	local effective_temp = tonumber(temperature) or 0.1
	local system_prompt  = Profiles.resolve_system_prompt(profile, num_predictions)
	local tokens         = (tonumber(max_predict) or 32) * num_predictions + (num_predictions * 5)
	local is_batch       = profile.batch
	local dedup_stats    = ApiCommon.new_dedup_stats()
	local t0             = TimerScheduler.now()

	post_and_parse(model_name, system_prompt, full_text, tail_text,
		effective_temp, tokens, num_predictions, is_batch,
		function(results)
			local ms = math.floor((TimerScheduler.now() - t0) * 1000)
			ApiCommon.log_prediction_summary(Logger, LOG, "batch", num_predictions, dedup_stats, #results)
			if not is_batch and #results > 1 then
				local function reveal_next(idx)
					if idx > #results then return end
					local subset = {}
					for j = 1, idx do subset[j] = results[j] end
					local is_final = (idx == #results)
					if type(on_success) == "function" then pcall(on_success, subset, ms, is_final, not is_final) end
					if not is_final then TimerScheduler.after(0, function() reveal_next(idx + 1) end) end
				end
				reveal_next(1)
			else
				if type(on_success) == "function" then pcall(on_success, results, ms, true) end
			end
		end,
		on_fail, dedup_stats)
end

--- Sequential strategy: N requests fired in sequence with a temperature
--- diversity step. Useful for variants from a single-prediction profile.
function M.fetch_sequential(full_text, tail_text, model_name, temperature,
                             max_predict, num_predictions, profile,
                             on_success, on_fail, request_id_provider, _streaming, _on_partial)
	local system_prompt          = Profiles.resolve_system_prompt(profile, 1)
	local t0                     = TimerScheduler.now()
	local results                = {}
	local base_temp              = tonumber(temperature) or 0.1
	local requested_predictions  = math.max(1, math.floor(tonumber(num_predictions) or 1))
	local max_attempts           = requested_predictions
	if RETRY_FAILED_PREDICTION then
		max_attempts = math.max(requested_predictions, requested_predictions * math.max(1, math.floor(tonumber(RETRY_FAILED_MAX_MULT) or 2)))
	end
	local attempt_index          = 1
	local dedup_stats            = ApiCommon.new_dedup_stats()
	local initial_request_id     = type(request_id_provider) == "function" and request_id_provider() or nil

	local function do_next()
		if type(request_id_provider) == "function" then
			local cur = request_id_provider()
			if initial_request_id ~= nil and cur ~= initial_request_id then
				Logger.debug(LOG, "Sequential batch cancelled (id changed).")
				return
			end
		end
		if #results >= requested_predictions or attempt_index > max_attempts then
			if #results == 0 then
				if type(on_fail) == "function" then pcall(on_fail) end
				return
			end
			ApiCommon.log_prediction_summary(Logger, LOG, "sequential", requested_predictions, dedup_stats, #results)
			local ms = math.floor((TimerScheduler.now() - t0) * 1000)
			if type(on_success) == "function" then pcall(on_success, results, ms, true) end
			return
		end
		local variant_index = attempt_index
		attempt_index       = attempt_index + 1
		local variant_temp  = ApiCommon.get_diversity_temperature(base_temp, variant_index, 0.30)
		local primary_tokens = tonumber(max_predict)

		local function request_variant(attempt, tokens, temp)
			post_and_parse(model_name, system_prompt, full_text, tail_text,
				temp, tokens, 1, false,
				function(preds)
					if type(preds) == "table" and type(preds[1]) == "table" then
						if #results < requested_predictions then
							ApiCommon.insert_prediction(results, preds[1], dedup_stats, DEDUPLICATION_ENABLED, Logger, LOG)
							local ms = math.floor((TimerScheduler.now() - t0) * 1000)
							if type(on_success) == "function" then pcall(on_success, results, ms, false) end
						end
					end
					do_next()
				end,
				function()
					if attempt < 2 then
						local retry_tokens = tokens + (_R_EXTRA_TOKENS or 5)
						local retry_temp   = math.min(1.30, (tonumber(temp) or 0.1) + (_R_TEMP_STEP or 0.18))
						request_variant(attempt + 1, retry_tokens, retry_temp)
						return
					end
					do_next()
				end,
				dedup_stats)
		end

		request_variant(1, primary_tokens, variant_temp)
	end

	do_next()
end

--- Parallel strategy aliases to sequential — remote providers tend to throttle
--- per-key concurrency, and we cannot guarantee request ordering without an
--- extra coordinator. Sequential keeps the rate-limit floor honest without
--- having to reason about parallel races.
M.fetch_parallel = M.fetch_sequential

--- Thinking-model heuristic. Same heuristic as api_ollama so the menu's
--- thinking-model warning row triggers consistently on remote models that
--- expose a reasoning suffix (qwen3, deepseek, *-r1, *-think*).
function M.is_thinking_model(name)
	if type(name) ~= "string" then return false end
	name = name:lower()
	return name:find("qwen3") ~= nil
		or name:find("deepseek") ~= nil
		or name:find("%-r1") ~= nil
		or name:find(":r1") ~= nil
		or name:find("think") ~= nil
		or name:find("reasoning") ~= nil
end

return M