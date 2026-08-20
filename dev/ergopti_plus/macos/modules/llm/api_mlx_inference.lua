--- modules/llm/api_mlx_inference.lua

--- ==============================================================================
--- MODULE: LLM API Request Engine (Apple MLX)
--- DESCRIPTION:
--- The request/response mechanics of the MLX controller: turns one resolved
--- prediction request into an HTTP call to the local MLX server (streaming via
--- curl -N, or a single non-streaming POST), parses the OpenAI-compatible
--- response, strips reasoning, and hands clean predictions back. The server
--- lifecycle it depends on (port resolution, endpoint discovery, warmup, zombie
--- kills) is owned by api_mlx.lua and reached through injected accessors.
---
--- FEATURES & RATIONALE:
--- 1. State by injection: the live endpoint routes, model identifiers, the
---    active-model-arg reader, and the shared streaming-task table are owned by
---    api_mlx.lua and reached here through the ctx given to M.init(). This module
---    holds no server state of its own, so there is a single source of truth.
--- 2. Logs on the "llm.api_mlx" channel so every MLX line lands in ErgoptiPlus_mlx.log.
--- 3. The dispatch strategies (fetch_batch/parallel/sequential) in api_mlx_fetch.lua
---    call into M.post_and_parse / M.post_and_parse_streaming.
--- ==============================================================================

local M = {}

local Logger         = require("infra.logger")
local text_utils = require("infra.text_utils")
local Parser         = require("modules.llm.parser")
local ApiCommon      = require("modules.llm.api_common")
local SharedPromptBuilder = require("llm.prompt_builder")   -- single source for DEFAULT_MAX_TOKENS
local JsonCodec      = require("adapters.json_codec")
local TimerScheduler = require("adapters.timer_scheduler")
local ShellRunner    = require("adapters.shell_runner")
local Timings        = require("infra.timings")
-- MLX log channel; every MLX line lands in ErgoptiPlus_mlx.log.
local LOG            = "llm.api_mlx"

local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end

-- Dedicated client for non-streaming inference POSTs; isolated so it never shares
-- state with the warmup/probe/check clients that live in api_mlx.lua.
local _infer_client  = require("adapters.http_client").new()

local _req_counter = 0
-- Read from the shared inference.json through ApiCommon, exactly as api_ollama and
-- api_remote do, so the dedup default lives in ONE place across every backend.
-- Hardcoding false here meant flipping the shared flag changed Ollama and remote
-- behaviour while MLX silently ignored it — the single-source-of-truth rule broken
-- by the one backend that redeclared the value. Exposed so the dispatch layer
-- (api_mlx_fetch) receives the identical flag this engine uses.
M.DEDUPLICATION_ENABLED = ApiCommon.DEFAULT_DEDUPLICATION_ENABLED
local DEDUPLICATION_ENABLED = M.DEDUPLICATION_ENABLED
-- MLX stream timeouts come from the shared cross-driver registry ([llm]).
local STREAM_CONNECT_TIMEOUT_SEC = Timings.sec("llm", "stream_connect_timeout_ms") -- Fail fast if the MLX server does not accept the TCP connection
local STREAM_HARD_TIMEOUT_SEC    = Timings.sec("llm", "stream_hard_timeout_ms")    -- Kill the task if the server accepts but never sends a token
local NON_STREAM_TIMEOUT_SEC     = Timings.sec("llm", "non_stream_timeout_ms")  -- Non-streaming inference hard timeout; prevents a hung server from blocking on_fail indefinitely
-- Safety-net delay before the fallback removal of the streaming payload temp
-- file (seconds). on_done removes it immediately in the normal case; this is
-- only reached if on_done fires late or not at all. Must be strictly greater
-- than STREAM_HARD_TIMEOUT_SEC so the file is never deleted while curl is
-- still reading it (mirrors api_ollama.lua's STREAM_TMPFILE_CLEANUP_SEC).
local STREAM_TMPFILE_CLEANUP_SEC = STREAM_HARD_TIMEOUT_SEC + 10

-- Controller state injected by api_mlx via M.init(): the live endpoint routes,
-- model identifiers, the active-model-arg reader, and the shared streaming-task
-- table (mutated here and by api_mlx's cancel_streaming). nil until init().
local _ctx = nil

-- Exact native timer capabilities whose cancellation was refused. The scheduler
-- also keeps a strong registry, but this request layer must retain its own debt so
-- it can prevent a sibling HTTP dispatch until the predecessor is proven inert.
local _non_stream_timer_cleanup = {}

--- Retains one exact non-stream timeout capability for a later cleanup attempt.
--- @param handle table|nil TimerScheduler handle.
local function retain_non_stream_timer_cleanup(handle)
	if type(handle) == "table" and handle.timer ~= nil then
		_non_stream_timer_cleanup[handle] = true
	end
end

--- Cancels one non-stream timeout and retains it when native stop refuses.
--- @param handle table|nil TimerScheduler handle.
--- @return boolean settled True only when no native timer remains.
local function cancel_non_stream_timer(handle)
	if type(handle) ~= "table" or handle.timer == nil then
		if type(handle) == "table" then _non_stream_timer_cleanup[handle] = nil end
		return true
	end
	local ok, settled_or_err = xpcall(function()
		return TimerScheduler.cancel(handle)
	end, debug.traceback)
	if ok and settled_or_err == true then
		_non_stream_timer_cleanup[handle] = nil
		return true
	end
	retain_non_stream_timer_cleanup(handle)
	Logger.error(LOG, "Non-stream timeout cleanup was refused; retained exact handle: %s.",
		tostring(settled_or_err))
	return false
end

--- Retries all retained non-stream timeout cleanup before another HTTP dispatch.
--- @return boolean settled True only when every predecessor timer settled.
local function drain_non_stream_timer_cleanup()
	local snapshot = {}
	for handle in pairs(_non_stream_timer_cleanup) do
		snapshot[#snapshot + 1] = handle
	end
	local settled = true
	for _, handle in ipairs(snapshot) do
		if cancel_non_stream_timer(handle) ~= true then settled = false end
	end
	return settled
end

--- Guard: every public request entry point reads injected controller state.
--- Logs an ERROR and bails when called before M.init() so a wiring regression is
--- loud instead of a nil-index crash deep inside a callback.
--- @param func_name string The caller, for the log line.
--- @return boolean True when the controller state is available.
local function require_ctx(func_name)
	if not _ctx then
		Logger.error(LOG, "'%s' called before ApiMlxInference.init() — controller state not injected.", func_name)
		return false
	end
	return true
end

--- Injects the live controller state owned by api_mlx.
--- @param ctx table {
---   completions_endpoint = function():string,  -- current resolved completions route
---   chat_endpoint        = function():string,  -- current resolved chat route
---   server_model_id      = function():string?, -- canonical /v1/models id, or nil
---   model_hf_path        = function():string?, -- launch --model HF path, or nil
---   read_active_model_arg = function():string?,-- exact --model arg written to disk
---   stream               = table,              -- shared { task, timeout, generation, has_chunks }
---   cancel_streaming     = function():boolean, -- strict shared teardown contract
--- }.
function M.init(ctx)
	if type(ctx) ~= "table" then
		Logger.error(LOG, "ApiMlxInference.init(): ctx must be a table — module non-functional.")
		return
	end
	if type(ctx.stream) ~= "table" then
		Logger.error(LOG, "ApiMlxInference.init(): ctx.stream must be the shared streaming-state table.")
		return
	end
	if type(ctx.cancel_streaming) ~= "function" then
		Logger.error(LOG, "ApiMlxInference.init(): ctx.cancel_streaming must be a function.")
		return
	end
	_ctx = ctx
	Logger.debug(LOG, "ApiMlxInference initialized.")
end





--- ======================================
--- ======================================
--- ======= 1/ Core Request Engine =======
--- ======================================
--- ======================================

-- Stop sequences from inference.json (single source — unified keys shared
-- with all backends; rationale in the JSON comment).
local STOP_BASE_MLX = ApiCommon.get_stop_sequences("batch")
local STOP_LINE_MLX = ApiCommon.get_stop_sequences("line")

local function build_options(temperature, num_predict_tokens, is_batch, line_mode)
    local opts = {
        temperature = tonumber(temperature) or ApiCommon.DEFAULT_TEMPERATURE,
        max_tokens  = tonumber(num_predict_tokens),
        stop        = (line_mode and not is_batch) and STOP_LINE_MLX or STOP_BASE_MLX,
    }
    return opts
end

--- Posts data to the local MLX LLM and parses the response.
--- @param model_name string Model identifier.
--- @param system_prompt string System instructions.
--- @param full_text string Context text.
--- @param tail_text string Recent context text.
--- @param temperature number Model temperature.
--- @param num_predict_tokens number Token limits.
--- @param num_predictions number Expected completions count.
--- @param is_batch boolean True if batch format requested.
--- @param on_success function Success callback.
--- @param on_fail function Failure callback.
--- @param dedup_stats table Dedup stats object.
--- @param force_line_mode boolean Force line completion parsing.
function M.post_and_parse(model_name, system_prompt, full_text, tail_text,
                               temperature, num_predict_tokens, num_predictions, is_batch,
                               on_success, on_fail, dedup_stats, force_line_mode)
    if not require_ctx("post_and_parse") then
        if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
        return
    end
    _req_counter = _req_counter + 1
    local req_id = _req_counter
    local messages = {}

	local final_sys = system_prompt
	if type(final_sys) == "string" then
		final_sys = final_sys:gsub("%{n%}", text_utils.escape_gsub_replacement(tostring(num_predictions)))
	end

	local user_prompt = ""
	if type(final_sys) == "string" and final_sys:find("PREFIX") and final_sys:find("TAIL") then
		user_prompt = string.format("PREFIX: \"%s\"\nTAIL: \"%s\"", full_text or "", tail_text or "")
	else
		local context_str = type(full_text) == "string" and full_text or ""
		if type(final_sys) == "string" and final_sys:find("{context}", 1, true) then
			final_sys = final_sys:gsub("%{context%}", function() return context_str end)
			user_prompt = final_sys
			final_sys = nil
		else
			user_prompt = context_str
		end
	end

    -- MLX OpenAI-compatible endpoint can reject system roles for some models
    -- Fold instructions into a single user message to keep compatibility
    local merged_prompt = user_prompt
    if type(final_sys) == "string" and final_sys ~= "" then
        merged_prompt = final_sys .. "\n\n" .. (user_prompt or "")
    end

    -- Disable reasoning mode globally (Qwen3, DeepSeek-R1, Hermes-3-think,
    -- etc.). See the streaming path below for the rationale; in short, these
    -- models otherwise burn the entire token budget on <think>…</think>
    -- monologue and emit zero final-answer content. /no_think is honoured
    -- as an in-prompt directive even when the chat template ignores
    -- chat_template_kwargs.
    table.insert(messages, { role = "user", content = merged_prompt .. "\n\n/no_think" })

    local t0_req = TimerScheduler.now()

    -- Advanced mode is only the strict correction profile
    local is_advanced_prompt = type(final_sys) == "string" and final_sys:find("TAIL_CORRECTED", 1, true) ~= nil
    local line_mode = (force_line_mode == true) or ((not is_batch) and (not is_advanced_prompt))

    local opts = build_options(temperature, num_predict_tokens, is_batch, line_mode)
    local payload
    local endpoint = _ctx.chat_endpoint()
    local prompt_preview = merged_prompt

    -- See read_active_model_arg() in api_mlx.lua: the payload must mirror the
    -- exact --model arg the bash launcher passed to mlx_lm or the server
    -- treats it as a different model and tries snapshot_download (offline 404).
    local effective_model = _ctx.read_active_model_arg() or _ctx.server_model_id() or _ctx.model_hf_path() or model_name
    if line_mode then
        -- For plain autocomplete, completion endpoint is more reliable than chat formatting
        local ctx = type(full_text) == "string" and full_text or ""
        local prompt = (#ctx > 240) and ctx:sub(#ctx - 239) or ctx
        prompt_preview = prompt
        endpoint = _ctx.completions_endpoint()
        payload = {
            model       = effective_model,
            prompt      = prompt,
            stream      = false,
            temperature = opts.temperature,
            -- No literal: unset cap resolves to the one shared DEFAULT_MAX_TOKENS
            max_tokens  = tonumber(opts.max_tokens) or SharedPromptBuilder.DEFAULT_MAX_TOKENS,
            stop        = { "\n\n", "</", "\"", "- " }
        }
    else
        payload = {
            model               = effective_model,
            messages            = messages,
            stream              = false,
            temperature         = opts.temperature,
            max_tokens          = opts.max_tokens,
            stop                = opts.stop,
            chat_template_kwargs = { enable_thinking = false },
            chat_template_args   = { enable_thinking = false },
        }
    end

    Logger.debug(LOG, "[%s] #%d PROMPT (%d chars) -> %s", model_name, req_id, #prompt_preview, prompt_preview:sub(1, 250))
    Logger.debug(LOG, "[%s] #%d MODE is_batch=%s line_mode=%s max_tokens=%s endpoint=%s", model_name, req_id, tostring(is_batch), tostring(line_mode), tostring(opts.max_tokens), endpoint)

	local encoded, enc_err = JsonCodec.encode(payload)
	if not encoded then
		Logger.error(LOG, "Failed to encode MLX payload — %s", tostring(enc_err))
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end

	if drain_non_stream_timer_cleanup() ~= true then
		Logger.error(LOG, "MLX request refused — predecessor timeout cleanup is still pending.")
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end

	local done = false
	local timeout_handle
	local timeout_committed
	local schedule_ok, schedule_err = xpcall(function()
		timeout_handle, timeout_committed = TimerScheduler.after(NON_STREAM_TIMEOUT_SEC, function()
			-- after() fences user delivery before attempting native stop. If that stop
			-- refuses, retain the exact inert capability for the next request boundary.
			retain_non_stream_timer_cleanup(timeout_handle)
		if done then return end
		done = true
		-- A SUPERSEDED request must not report failure. Nothing cancels this timer
		-- when a newer request starts, so it still fired eight seconds later and
		-- called on_fail — and on_fail is a retry path, which cancels streaming
		-- and tore down the transport of the request that is actually live. The
		-- abandoned request killed its successor. req_id against the counter is
		-- the identity: a newer request exists precisely when the counter has
		-- moved past this one.
		if req_id ~= _req_counter then
			Logger.debug(LOG, "[%s] #%d timeout ignored — superseded by #%d.",
				model_name, req_id, _req_counter)
			return
		end
		Logger.warn(LOG, "[%s] #%d TIMEOUT after %.0fs", model_name, req_id, NON_STREAM_TIMEOUT_SEC)
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		end)
	end, debug.traceback)
	if not schedule_ok or timeout_committed ~= true then
		retain_non_stream_timer_cleanup(timeout_handle)
		Logger.error(LOG, "MLX request timeout did not commit — HTTP dispatch refused: %s.",
			tostring(schedule_ok and timeout_handle or schedule_err))
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end

	_infer_client.post(endpoint, { ["Content-Type"] = "application/json" }, encoded,
		function(r)
			local status, body = r.status, r.body
			if done then return end
			done = true
			cancel_non_stream_timer(timeout_handle)

			if status ~= 200 then
				Logger.error(LOG, "MLX HTTP %s :: %s", tostring(status), tostring((body or ""):sub(1, 260)))
				if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
				return
			end

			local resp, _ = JsonCodec.decode(body)
			if type(resp) ~= "table" or type(resp.choices) ~= "table" or not resp.choices[1] then
                Logger.debug(LOG, "[%s] #%d Unusable response (decode/choices), body='%s'", model_name, req_id, tostring((body or ""):sub(1, 220)))
				if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
				return
			end

			local choice = resp.choices[1]
			local content = nil

			-- OpenAI-like format extraction
			if type(choice.message) == "table" then
				if type(choice.message.content) == "string" then
					content = choice.message.content
				elseif type(choice.message.content) == "table" then
					local chunks = {}
					for _, item in ipairs(choice.message.content) do
						if type(item) == "table" and type(item.text) == "string" then
							table.insert(chunks, item.text)
						elseif type(item) == "string" then
							table.insert(chunks, item)
						end
					end
					if #chunks > 0 then content = table.concat(chunks, "") end
				end
			end

			-- Legacy completion fallback execution
			if not content and type(choice.text) == "string" then
				content = choice.text
			end

            if type(content) ~= "string" or content == "" then
                local has_reasoning = type(choice.message) == "table" and type(choice.message.reasoning) == "string" and choice.message.reasoning ~= ""
                if has_reasoning then
                    Logger.debug(LOG, "[%s] #%d Reasoning-only response detected (empty content).", model_name, req_id)
                end
                Logger.debug(LOG, "[%s] #%d Empty content in choices[1]", model_name, req_id)
                if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
                return
            end

            local raw     = Parser.strip_thinking(content)
            local ms_req  = math.floor((TimerScheduler.now() - t0_req) * 1000)
            Logger.debug(LOG, "[%s] #%d RAW (%dms, %d chars) -> %s", model_name, req_id, ms_req, #raw, raw:sub(1, 250))
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
                Logger.debug(LOG, "[%s] #%d PARSED -> 0 result (parser failure)", model_name, req_id)
                if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end return
            end
            Logger.debug(LOG, "[%s] #%d PARSED -> %d result(s)", model_name, req_id, #results)
            if keylogger and type(keylogger.log_llm) == "function" then
                pcall(keylogger.log_llm, full_text, results, nil, {
                    backend       = "mlx",
                    model         = tostring(model_name),
                    system_prompt = system_prompt,
                    user_prompt   = user_prompt,
                })
            end
			if type(on_success) == "function" then ApiCommon.protected_call(on_success, "on_success", results) end
		end
	)
end

--- Streaming variant of post_and_parse using hs.task + curl -N.
--- Calls on_partial(accumulated_raw_text) after each received token so the
--- caller can update the UI incrementally. Calls on_success with the final
--- parsed result when the stream ends.
--- @param model_name string
--- @param system_prompt string
--- @param full_text string
--- @param tail_text string
--- @param temperature number
--- @param num_predict_tokens number
--- @param num_predictions number
--- @param is_batch boolean
--- @param on_success function Called once with final parsed results.
--- @param on_fail function Called on error.
--- @param dedup_stats table
--- @param on_partial function|nil Called with accumulated raw text as each token arrives.
function M.post_and_parse_streaming(model_name, system_prompt, full_text, tail_text,
                                         temperature, num_predict_tokens, num_predictions, is_batch,
                                         on_success, on_fail, dedup_stats, on_partial)
	if not require_ctx("post_and_parse_streaming") then
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end
	-- Supersede any previous stream: always terminate to free the MLX server connection
	if (_ctx.stream.task or _ctx.stream.timeout) and _ctx.cancel_streaming() ~= true then
		Logger.error(LOG, "Cannot start MLX stream while the previous task remains owned.")
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end

	_ctx.stream.generation = _ctx.stream.generation + 1
	local my_generation = _ctx.stream.generation

	_req_counter = _req_counter + 1
	local req_id = _req_counter

	-- Replicate message/endpoint building from post_and_parse
	local final_sys = system_prompt
	if type(final_sys) == "string" then
		final_sys = final_sys:gsub("%{n%}", text_utils.escape_gsub_replacement(tostring(num_predictions)))
	end

	local user_prompt = ""
	if type(final_sys) == "string" and final_sys:find("PREFIX") and final_sys:find("TAIL") then
		user_prompt = string.format("PREFIX: \"%s\"\nTAIL: \"%s\"", full_text or "", tail_text or "")
	else
		local context_str = type(full_text) == "string" and full_text or ""
		if type(final_sys) == "string" and final_sys:find("{context}", 1, true) then
			final_sys = final_sys:gsub("%{context%}", function() return context_str end)
			user_prompt = final_sys
			final_sys = nil
		else
			user_prompt = context_str
		end
	end

	local merged_prompt = user_prompt
	if type(final_sys) == "string" and final_sys ~= "" then
		merged_prompt = final_sys .. "\n\n" .. (user_prompt or "")
	end

	local is_advanced_prompt = type(final_sys) == "string" and final_sys:find("TAIL_CORRECTED", 1, true) ~= nil
	local line_mode = (not is_batch) and (not is_advanced_prompt)
	local opts = build_options(temperature, num_predict_tokens, is_batch, line_mode)

	-- See read_active_model_arg() in api_mlx.lua: the payload must mirror the
	-- exact --model arg the bash launcher passed to mlx_lm or the server
	-- treats it as a different model and tries snapshot_download (offline 404).
	-- Same four-tier chain as the non-streaming twin (line ~188) and warmup: when
	-- /tmp/mlx_active_model.txt is absent (tmp reaping, a reload that adopts an
	-- already-running server) read_active_model_arg() is nil and server_model_id()
	-- is always nil, so without model_hf_path() the payload would send the SHORT
	-- model name — which mlx-lm 0.26+ rejects with a 404, yielding no streamed
	-- prediction. Keep the HF-path tier so the default (streaming) path matches.
	local effective_model = _ctx.read_active_model_arg() or _ctx.server_model_id() or _ctx.model_hf_path() or model_name
	local payload, endpoint, prompt_preview
	if line_mode then
		local ctx    = type(full_text) == "string" and full_text or ""
		local prompt = (#ctx > 240) and ctx:sub(#ctx - 239) or ctx
		prompt_preview = prompt
		endpoint = _ctx.completions_endpoint()
		payload = {
			model       = effective_model,
			prompt      = prompt,
			stream      = true,
			temperature = opts.temperature,
			-- No literal: unset cap resolves to the one shared DEFAULT_MAX_TOKENS
			max_tokens  = tonumber(opts.max_tokens) or SharedPromptBuilder.DEFAULT_MAX_TOKENS,
			stop        = { "\n\n", "</", "\"", "- " },
		}
	else
		-- Disable reasoning / "thinking" mode globally. Qwen3, DeepSeek-R1,
		-- Hermes-3-think and other reasoning models otherwise spend their
		-- entire token budget producing <think>…</think> internal monologue
		-- and emit zero final-answer content, which surfaces as
		-- STREAM_DONE → empty raw → "parse yielded 0 result(s)".
		--
		-- Belt-and-braces:
		--   1. chat_template_kwargs / chat_template_args: the standard
		--      mlx-lm 0.31+ knob to flip Jinja templates that gate
		--      <think> blocks behind `enable_thinking`.
		--   2. /no_think suffix on the user message: Qwen3 honours this as
		--      a literal in-prompt directive even if the chat template
		--      does not pick up the kwarg (e.g. older snapshots).
		local user_content    = merged_prompt .. "\n\n/no_think"
		prompt_preview = user_content
		endpoint = _ctx.chat_endpoint()
		payload = {
			model               = effective_model,
			messages            = { { role = "user", content = user_content } },
			stream              = true,
			temperature         = opts.temperature,
			max_tokens          = opts.max_tokens,
			stop                = opts.stop,
			chat_template_kwargs = { enable_thinking = false },
			chat_template_args   = { enable_thinking = false },
		}
	end

	Logger.debug(LOG, "[%s] #%d STREAM_PROMPT (%d chars) -> %s",
		model_name, req_id, #prompt_preview, prompt_preview:sub(1, 250))

	local encoded, enc_err = JsonCodec.encode(payload)
	if not encoded then
		Logger.error(LOG, "Failed to encode MLX streaming payload — %s", tostring(enc_err))
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end

	-- Write payload to a temp file so curl reads it directly — avoids the
	-- stdin-pipe/streaming-callback conflict in hs.task.
	-- os.tmpname() creates an empty file at the base path; remove it immediately
	-- so only the suffixed path (which we own) exists in /tmp.
	-- Declared BEFORE on_done so the closure captures the real `tmp_path` upvalue
	-- (Lua lexical scoping: a local declared after the closure resolves to the
	-- nil global inside that closure, making os.remove(tmp_path) throw and abort
	-- the whole callback — mirrors the exact gotcha already fixed in
	-- api_ollama.lua's streaming twin).
	local _tmp_base = os.tmpname()
	local tmp_path = _tmp_base .. "_mlx_stream.json"
	os.remove(_tmp_base)
	local fh = io.open(tmp_path, "w")
	if not fh then
		Logger.error(LOG, "Failed to open temp file '%s' for MLX streaming payload.", tmp_path)
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end
	fh:write(encoded)
	fh:close()

	local accumulated   = ""
	local line_buf      = ""
	local in_reasoning  = false  -- Currently accumulating delta.reasoning(_content) tokens — close </think> on transition or end
	local t0_req        = TimerScheduler.now()
	local task = nil
	local task_completed = false

	-- Parse one SSE line (data: {...} or data: [DONE]) and append its token to accumulated
	local function process_sse_line(line)
		Logger.debug(LOG, "[%s] #%d SSE line: '%s'", model_name, req_id, line:sub(1, 120))
		if line:sub(1, 6) ~= "data: " then return end
		-- Strip a trailing CR: a CRLF-emitting mlx-lm/uvicorn build (or a proxy) sends
		-- "data: {...}\r"; flush_lines splits only on "\n", so without this the trailing
		-- CR makes the structural guard below see last_char == "\r" (not "}"/"]") and
		-- drop EVERY chunk — an empty stream with no prediction (F-L3). SSE permits CRLF.
		local json_str = line:sub(7):gsub("\r$", "")
		if json_str == "[DONE]" then return end
		-- Reject structurally incomplete chunks early: a valid JSON object or array
		-- must end with "}" or "]"; anything shorter is a split TCP chunk that
		-- JsonCodec.decode cannot reconstruct, so skip rather than log a spurious error
		local last_char = json_str:sub(-1)
		if last_char ~= "}" and last_char ~= "]" then
			Logger.debug(LOG, "process_sse_line: structurally incomplete chunk — skipping.")
			return
		end
		local ok_json, obj = pcall(function() return JsonCodec.decode(json_str) end)
		if not ok_json or not obj then
			Logger.debug(LOG, "process_sse_line: JSON parse failed (incomplete chunk?) — skipping.")
			return
		end
		if type(obj) ~= "table" or type(obj.choices) ~= "table" or not obj.choices[1] then
			Logger.debug(LOG, "[%s] #%d SSE decode fail: type_obj=%s",
				model_name, req_id, type(obj))
			return
		end
		local choice = obj.choices[1]
		-- Chat completions streaming. Reasoning models (Qwen3, DeepSeek-R1,
		-- Hermes-3 in think mode) route their thought tokens through
		-- delta.reasoning(_content) and the final answer through
		-- delta.content. We accumulate both into a single string,
		-- inserting a single <think>…</think> wrapper around the reasoning
		-- segment so Parser.strip_thinking() can remove it cleanly at the
		-- end. Without this branch, the reasoning chunks were silently
		-- dropped and the chat-completions stream finished with "empty
		-- accumulation" even when the server emitted hundreds of tokens.
		local reasoning_chunk = nil
		local content_chunk   = nil
		if type(choice.delta) == "table" then
			if type(choice.delta.content) == "string" and choice.delta.content ~= "" then
				content_chunk = choice.delta.content
			end
			if type(choice.delta.reasoning_content) == "string" and choice.delta.reasoning_content ~= "" then
				reasoning_chunk = choice.delta.reasoning_content
			elseif type(choice.delta.reasoning) == "string" and choice.delta.reasoning ~= "" then
				reasoning_chunk = choice.delta.reasoning
			end
		elseif type(choice.text) == "string" and choice.text ~= "" then
			-- Completions endpoint streaming: text directly
			content_chunk = choice.text
		end

		local appended = false
		if reasoning_chunk then
			if not in_reasoning then
				accumulated = accumulated .. "<think>"
				in_reasoning = true
			end
			accumulated = accumulated .. reasoning_chunk
			appended = true
		end
		if content_chunk then
			if in_reasoning then
				accumulated = accumulated .. "</think>"
				in_reasoning = false
			end
			accumulated = accumulated .. content_chunk
			appended = true
		end
		if appended and type(on_partial) == "function" then
			ApiCommon.protected_call(on_partial, "on_partial", accumulated)
		end
	end

	-- Drain line_buf, processing every complete SSE line found
	local function flush_lines()
		while true do
			local nl = line_buf:find("\n", 1, true)
			if not nl then break end
			local line = line_buf:sub(1, nl - 1)
			line_buf   = line_buf:sub(nl + 1)
			if line ~= "" then process_sse_line(line) end
		end
	end

	-- Arms (or re-arms) the stream IDLE watchdog: if no further token arrives
	-- within STREAM_HARD_TIMEOUT_SEC, the server is hung — terminate the task and
	-- fire on_fail so the UI never freezes and the single-request MLX connection
	-- is freed. Re-arming on every chunk (rather than cancelling after the first)
	-- bounds a MID-STREAM stall too: the prior code cancelled the watchdog on the
	-- first token, leaving a server that sent >=1 token then hung with NO bound at
	-- all — curl blocked forever, on_done never fired, every later prediction was
	-- blocked behind the held-open connection.
	local watchdog_epoch = 0
	local arm_stream_idle_watchdog
	arm_stream_idle_watchdog = function()
		watchdog_epoch = watchdog_epoch + 1
		local my_watchdog_epoch = watchdog_epoch
		if _ctx.stream.timeout then
			local old_timeout = _ctx.stream.timeout
			local cancel_ok, cancel_result = xpcall(function()
				return TimerScheduler.cancel(old_timeout)
			end, debug.traceback)
			local cancel_settled = cancel_ok and (cancel_result == nil or cancel_result == true)
			if not cancel_settled then
				-- The old callback is fenced by watchdog_epoch. Retain its exact handle;
				-- when it eventually fires it will re-arm from that later instant instead
				-- of terminating a healthy stream relative to the old deadline.
				Logger.error(LOG, "[%s] #%d STREAM watchdog cancellation did not commit (result: %s).",
					tostring(model_name), req_id, tostring(cancel_result))
				-- The exact old timer remains live. Its epoch fence makes it harmless,
				-- and when it fires it re-arms from that later instant, so the stream
				-- remains bounded without creating a duplicate timer.
				return true
			end
			if _ctx.stream.timeout == old_timeout then _ctx.stream.timeout = nil end
		end

		local candidate
		local schedule_ok, handle_or_err, watchdog_committed = xpcall(function()
			local committed
			candidate, committed = TimerScheduler.after(STREAM_HARD_TIMEOUT_SEC, function()
				local callback_ok, callback_err = xpcall(function()
					if _ctx.stream.timeout ~= candidate then return end
					_ctx.stream.timeout = nil
					if my_generation ~= _ctx.stream.generation then return end
					if my_watchdog_epoch ~= watchdog_epoch then
						-- A later chunk superseded this deadline but native cancellation
						-- failed. It has now fired safely; start a fresh full deadline.
						if _ctx.stream.task then arm_stream_idle_watchdog() end
						return
					end
					local task = _ctx.stream.task
					if not task then return end
					Logger.warn(LOG, "[%s] #%d STREAM idle timeout (%gs) — terminating hung task.",
						model_name, req_id, STREAM_HARD_TIMEOUT_SEC)
					local terminate_ok, terminate_result = xpcall(task.terminate, debug.traceback)
					if not terminate_ok or terminate_result ~= true then
						Logger.error(LOG, "[%s] #%d STREAM timeout termination did not commit (result: %s).",
							tostring(model_name), req_id, tostring(terminate_result))
						if _ctx.stream.task == task then arm_stream_idle_watchdog() end
						return
					end
					if _ctx.stream.task == task then
						_ctx.stream.task       = nil
						_ctx.stream.has_chunks = false
					end
					if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
				end, debug.traceback)
				if not callback_ok then
					Logger.error(LOG, "[%s] #%d STREAM watchdog callback raised: %s",
						tostring(model_name), req_id, tostring(callback_err))
				end
			end)
			return candidate, committed
		end, debug.traceback)
		if not schedule_ok or watchdog_committed ~= true then
			Logger.error(LOG, "[%s] #%d STREAM watchdog arm did not commit (result: %s).",
				tostring(model_name), req_id, tostring(handle_or_err))
			return false
		end
		_ctx.stream.timeout = candidate
		return true
	end

	-- Streaming callback: fired each time curl writes a chunk to stdout
	local function on_chunk(_, chunk, stderr_chunk)
		if not chunk or chunk == "" then return true end
		-- Generation check: if a newer request superseded us, discard chunks silently
		if my_generation ~= _ctx.stream.generation then return false end
		-- First chunk received — server is alive (logged once for diagnostics).
		if not _ctx.stream.has_chunks then
			_ctx.stream.has_chunks = true
		end
		-- Re-arm the idle watchdog on EVERY chunk so a mid-stream stall is bounded,
		-- not just a pre-first-token hang (the watchdog used to be cancelled here).
		if arm_stream_idle_watchdog() ~= true then
			-- The old deadline was already revoked and its replacement never became
			-- native ownership. Keep no unbounded stream behind a successful chunk.
			local owned_task = _ctx.stream.task
			_ctx.stream.generation = _ctx.stream.generation + 1
			if owned_task then
				local stop_ok, stop_result = xpcall(function() return owned_task.terminate() end, debug.traceback)
				if stop_ok and stop_result == true and _ctx.stream.task == owned_task then
					_ctx.stream.task = nil
				elseif not stop_ok or stop_result ~= true then
					Logger.error(LOG, "[%s] #%d STREAM task retained after watchdog loss: %s",
						tostring(model_name), req_id, tostring(stop_result))
				end
			end
			_ctx.stream.has_chunks = false
			if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
			return false
		end
		Logger.debug(LOG, "[%s] #%d STREAM chunk (%d bytes): '%s'",
			model_name, req_id, #chunk, chunk:sub(1, 120))
		line_buf = line_buf .. chunk
		flush_lines()
		return true
	end

	-- Completion callback: fired when curl exits
	local function on_done(exit_code, remaining, stderr_out)
		task_completed = true
		-- A completion callback owns teardown before every fallible parser/file/log
		-- operation. Otherwise a throw at line one leaves a dead curl published and
		-- every later request refuses to start behind it.
		if my_generation == _ctx.stream.generation and _ctx.stream.task == task then
			_ctx.stream.task = nil
			_ctx.stream.has_chunks = false
		end
		-- Remove the payload temp file as soon as curl exits so it doesn't linger
		-- for the full STREAM_TMPFILE_CLEANUP_SEC fallback window (mirrors the
		-- Ollama backend's streaming twin; F-MED-3).
		os.remove(tmp_path)

		Logger.debug(LOG, "[%s] #%d STREAM on_done: exit=%s remaining_len=%d stderr='%s'",
			model_name, req_id, tostring(exit_code),
			(remaining and #remaining or -1),
			tostring((stderr_out or ""):sub(1, 200)))

		-- Generation check: a newer request superseded this stream — discard result silently
		-- and DO NOT touch _ctx.stream.task: it now belongs to the newer request,
		-- and clearing it would untrack the active stream so subsequent cancel_streaming
		-- calls would no-op, leaking curl processes that hold the MLX connection
		if my_generation ~= _ctx.stream.generation then
			Logger.debug(LOG, "[%s] #%d STREAM: superseded by newer request (gen %d vs %d) — no callbacks.",
				model_name, req_id, my_generation, _ctx.stream.generation)
			return
		end

		-- This stream is still the current one — clear active state
		if _ctx.stream.timeout then
			local timeout = _ctx.stream.timeout
			local cancel_ok, cancel_result = xpcall(function()
				return TimerScheduler.cancel(timeout)
			end, debug.traceback)
			local cancel_settled = cancel_ok and (cancel_result == nil or cancel_result == true)
			if cancel_settled then
				if _ctx.stream.timeout == timeout then _ctx.stream.timeout = nil end
			else
				Logger.error(LOG, "[%s] #%d STREAM completion watchdog cancellation did not commit (result: %s).",
					tostring(model_name), req_id, tostring(cancel_result))
			end
		end

		-- SIGTERM (15) means this stream was explicitly terminated (mid-flight cancel)
		if exit_code == 15 then
			Logger.debug(LOG, "[%s] #%d STREAM: terminated mid-flight — no callbacks.", model_name, req_id)
			return
		end
		if exit_code ~= 0 then
			Logger.error(LOG, "[%s] #%d STREAM transport failed (exit=%s) — discarding partial output.",
				tostring(model_name), req_id, tostring(exit_code))
			if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
			return
		end

		if remaining and remaining ~= "" then
			line_buf = line_buf .. remaining
			flush_lines()
		end

		-- Close any unterminated reasoning segment so Parser.strip_thinking
		-- can remove the entire <think>…</think> block; without this,
		-- a reasoning-only stream that never transitions to content would
		-- leave "<think>…" unbalanced and strip_thinking would no-op.
		if in_reasoning then
			accumulated  = accumulated .. "</think>"
			in_reasoning = false
		end

		if accumulated == "" then
			Logger.warn(LOG, "[%s] #%d STREAM: empty accumulation — on_fail.", model_name, req_id)
			if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
			return
		end

		local raw    = Parser.strip_thinking(accumulated)
		local ms_req = math.floor((TimerScheduler.now() - t0_req) * 1000)
		Logger.debug(LOG, "[%s] #%d STREAM_DONE (%dms) -> %s", model_name, req_id, ms_req, raw:sub(1, 250))

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
			Logger.debug(LOG, "[%s] #%d STREAM: parse yielded 0 result(s).", model_name, req_id)
			if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
			return
		end
		Logger.debug(LOG, "[%s] #%d STREAM: %d result(s).", model_name, req_id, #results)
		if keylogger and type(keylogger.log_llm) == "function" then
			pcall(keylogger.log_llm, full_text, results, nil, {
				backend       = "mlx",
				model         = tostring(model_name),
				system_prompt = system_prompt,
				-- mlx streaming builds the user prompt inline (line 798 of
				-- post_and_parse_streaming uses ``merged_prompt``); fall back
				-- to that when the local helper variable is in scope.
				user_prompt   = (type(merged_prompt) == "string" and merged_prompt)
					or (type(user_prompt) == "string" and user_prompt)
					or nil,
			})
		end
		if type(on_success) == "function" then ApiCommon.protected_call(on_success, "on_success", results) end
	end

	local spawn_ok, spawned = xpcall(function()
		return ShellRunner.spawn("/usr/bin/curl", {
			"-s", "-N", "-X", "POST",
			"-H", "Content-Type: application/json",
			"--connect-timeout", tostring(STREAM_CONNECT_TIMEOUT_SEC),
			-- Hard ceiling on TOTAL stream duration so curl ALWAYS exits and on_done
			-- runs even if the server stalls mid-stream (mirrors the Ollama backend).
			-- Without this a post-first-token hang left curl blocked forever, holding
			-- the single-request MLX connection open against every later prediction.
			"--max-time", tostring(STREAM_HARD_TIMEOUT_SEC),
			"--data-binary", "@" .. tmp_path,
			endpoint,
		}, on_done, on_chunk)
	end, debug.traceback)
	if not spawn_ok or type(spawned) ~= "table" or type(spawned.start) ~= "function" then
		pcall(os.remove, tmp_path)
		Logger.error(LOG, "[%s] #%d STREAM task creation did not commit (result: %s).",
			tostring(model_name), req_id, tostring(spawned))
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end
	task = spawned
	_ctx.stream.task = task
	local start_ok, start_result = xpcall(function() return task.start() end, debug.traceback)
	if not start_ok or start_result ~= true then
		if not start_ok then
			local stop_ok, stop_result = xpcall(function() return task.terminate() end, debug.traceback)
			if stop_ok and stop_result == true then
				if _ctx.stream.task == task then _ctx.stream.task = nil end
			else
				Logger.error(LOG, "[%s] #%d STREAM ambiguous task retained for cancellation retry: %s",
					tostring(model_name), req_id, tostring(stop_result))
			end
		elseif _ctx.stream.task == task then
			_ctx.stream.task = nil
		end
		local removed, remove_err = pcall(os.remove, tmp_path)
		if not removed then
			Logger.error(LOG, "[%s] #%d STREAM payload cleanup failed: %s",
				tostring(model_name), req_id, tostring(remove_err))
		end
		Logger.error(LOG, "[%s] #%d STREAM task start did not commit (result: %s).",
			tostring(model_name), req_id, tostring(start_result))
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end
	if task_completed then return end
	_ctx.stream.has_chunks = false
	Logger.debug(LOG, "[%s] #%d STREAM task started (payload: %s).", model_name, req_id, tmp_path)

	-- Own the payload cleanup before arming the watchdog. If watchdog creation
	-- fails and task termination is itself ambiguous, curl may still be reading;
	-- this later deadline remains the only safe cleanup owner.
	local cleanup_ok, cleanup_handle, cleanup_committed = xpcall(function()
		return TimerScheduler.after(STREAM_TMPFILE_CLEANUP_SEC, function()
			os.remove(tmp_path)
		end)
	end, debug.traceback)
	if not cleanup_ok or cleanup_committed ~= true then
		Logger.error(LOG, "[%s] #%d STREAM payload cleanup timer did not commit (result: %s).",
			tostring(model_name), req_id, tostring(cleanup_handle))
	end

	-- Idle watchdog: bound the stream in-process too (belt-and-suspenders with
	-- --max-time). Armed now and re-armed on every chunk (see on_chunk), so a hung
	-- server — connection accepted but no further tokens — is terminated and
	-- surfaced via on_fail instead of freezing the UI on a stuck spinner.
	if arm_stream_idle_watchdog() ~= true then
		_ctx.stream.generation = _ctx.stream.generation + 1
		local stop_ok, stop_result = xpcall(function() return task.terminate() end, debug.traceback)
		if stop_ok and stop_result == true and _ctx.stream.task == task then
			_ctx.stream.task = nil
			pcall(os.remove, tmp_path)
		elseif not stop_ok or stop_result ~= true then
			Logger.error(LOG, "[%s] #%d STREAM task retained after initial watchdog failure: %s",
				tostring(model_name), req_id, tostring(stop_result))
		end
		_ctx.stream.has_chunks = false
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end
end

return M
