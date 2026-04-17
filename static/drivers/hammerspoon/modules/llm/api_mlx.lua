--- modules/llm/api_mlx.lua

--- ==============================================================================
--- MODULE: LLM API Controller (Apple MLX)
--- DESCRIPTION:
--- Manages communication with the local MLX server via its OpenAI-compatible endpoint.
--- ==============================================================================

local M = {}

local hs       = hs
local Logger   = require("lib.logger")
local Parser   = require("modules.llm.parser")
local Profiles = require("modules.llm.profiles")
local ApiCommon = require("modules.llm.api_common")
local LOG      = "llm.api_mlx"

local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end

local _req_counter = 0
local DEDUPLICATION_ENABLED = false
local RETRY_FAILED_PREDICTION_ENABLED = true
local RETRY_FAILED_PREDICTION_MAX_MULTIPLIER = 2

-- Holds the current in-flight hs.task; cancelled when a new streaming request starts.
-- The streaming flag itself is owned by modules/llm/init.lua and passed per-call.
local _active_stream_task = nil

-- M.is_thinking_model is injected by init.lua

--- Terminates the in-flight streaming task if one is active.
--- Called when a newer request supersedes the current one.
function M.cancel_streaming()
	if _active_stream_task then
		pcall(function() _active_stream_task:terminate() end)
		_active_stream_task = nil
		Logger.debug(LOG, "Active MLX stream cancelled.")
	end
end

--- Sends a minimal 1-token inference to load model weights into GPU memory.
--- Mirrors api_ollama.warmup() for the MLX backend.
--- @param model_name string The MLX model identifier (not used in the request, logged only).
function M.warmup(model_name)
	Logger.debug(LOG, "Warming up MLX model '%s'…", tostring(model_name))
	local ok, encoded = pcall(hs.json.encode, {
		prompt      = " ",
		max_tokens  = 1,
		temperature = 0,
	})
	if not ok then return end
	hs.http.asyncPost(
		"http://127.0.0.1:8080/v1/completions",
		encoded,
		{ ["Content-Type"] = "application/json" },
		function(status, _)
			if status == 200 then
				Logger.info(LOG, "MLX model '%s' warmed up — GPU cache ready.", tostring(model_name))
			else
				Logger.debug(LOG, "MLX warmup returned %s — model may not be loaded yet.", tostring(status))
			end
		end
	)
end





-- =====================================
-- =====================================
-- ======= 1/ Check Availability =======
-- =====================================
-- =====================================

--- Asynchronously checks if the MLX server is reachable and loaded.
--- @param model_name string Name of the model (not strictly checked in MLX).
--- @param on_available function Callback if server answers.
--- @param on_missing function Callback if server fails to answer.
function M.check_availability(model_name, on_available, on_missing)
	Logger.debug(LOG, "Checking MLX server availability…")
	hs.http.asyncGet("http://127.0.0.1:8080/v1/models", {}, function(status, body)
		if status == 200 then
			Logger.info(LOG, "MLX server is available.")
			if type(on_available) == "function" then pcall(on_available) end
		else
			Logger.warn(LOG, "MLX server is missing or unreachable.")
			if type(on_missing) == "function" then pcall(on_missing, false) end
		end
	end)
end





-- ======================================
-- ======================================
-- ======= 2/ Core Request Engine =======
-- ======================================
-- ======================================

-- Builds the options payload for the OpenAI API format (MLX Server) - optimized
local STOP_BASE_MLX  = { "<|eot_id|>", "<|im_end|>", "[/INST]", "PREFIX:" }
local STOP_LINE_MLX  = { "<|eot_id|>", "<|im_end|>", "[/INST]", "PREFIX:", "\n\n", "\n", "\r", "</", "Suite finale", "SUITE", "NEXT_WORDS:" }

local function build_options(temperature, num_predict_tokens, is_batch, line_mode)
    local opts = {
        temperature = tonumber(temperature) or 0.1,
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
local function post_and_parse(model_name, system_prompt, full_text, tail_text,
                               temperature, num_predict_tokens, num_predictions, is_batch,
                               on_success, on_fail, dedup_stats, force_line_mode)
    _req_counter = _req_counter + 1
    local req_id = _req_counter
    local messages = {}

	local final_sys = system_prompt
	if type(final_sys) == "string" then
		final_sys = final_sys:gsub("%{n%}", tostring(num_predictions))
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

    table.insert(messages, { role = "user", content = merged_prompt })

    local t0_req = hs.timer.secondsSinceEpoch()

    -- Advanced mode is only the strict correction profile
    local is_advanced_prompt = type(final_sys) == "string" and final_sys:find("RÈGLES CRITIQUES", 1, true) ~= nil
    local line_mode = (force_line_mode == true) or ((not is_batch) and (not is_advanced_prompt))

    local opts = build_options(temperature, num_predict_tokens, is_batch, line_mode)
    local payload
    local endpoint = "http://127.0.0.1:8080/v1/chat/completions"
    local prompt_preview = merged_prompt

    if line_mode then
        -- For plain autocomplete, completion endpoint is more reliable than chat formatting
        local ctx = type(full_text) == "string" and full_text or ""
        local prompt = (#ctx > 240) and ctx:sub(#ctx - 239) or ctx
        prompt_preview = prompt
        endpoint = "http://127.0.0.1:8080/v1/completions"
        payload = {
            prompt      = prompt,
            stream      = false,
            temperature = opts.temperature,
            max_tokens  = tonumber(opts.max_tokens) or 50,
            stop        = { "\n", "\r", "</", "\"", "- " }
        }
    else
        payload = {
            messages    = messages,
            stream      = false,
            temperature = opts.temperature,
            max_tokens  = opts.max_tokens,
            stop        = opts.stop,
            chat_template_kwargs = { enable_thinking = false }
        }
    end

    Logger.debug(LOG, "[%s] #%d PROMPT (%d chars) -> %s", model_name, req_id, #prompt_preview, prompt_preview:sub(1, 250))
    Logger.debug(LOG, "[%s] #%d MODE is_batch=%s line_mode=%s max_tokens=%s endpoint=%s", model_name, req_id, tostring(is_batch), tostring(line_mode), tostring(opts.max_tokens), endpoint)

	local ok, encoded = pcall(hs.json.encode, payload)
	if not ok or not encoded then
		Logger.error(LOG, "Failed to encode MLX payload.")
		if type(on_fail) == "function" then pcall(on_fail) end
		return
	end

    local done = false
    local timeout_timer = hs.timer.doAfter(8, function()
        if done then return end
        done = true
        Logger.warn(LOG, "[%s] #%d TIMEOUT after 8s", model_name, req_id)
        if type(on_fail) == "function" then pcall(on_fail) end
    end)

    hs.http.asyncPost(endpoint, encoded, { ["Content-Type"] = "application/json" },
        function(status, body, _)
            if done then return end
            done = true
            if timeout_timer and type(timeout_timer.stop) == "function" then timeout_timer:stop() end

            if status ~= 200 then
                Logger.error(LOG, "MLX HTTP %s :: %s", tostring(status), tostring((body or ""):sub(1, 260)))
                if type(on_fail) == "function" then pcall(on_fail) end
                return
            end
            
            local ok_dec, resp = pcall(hs.json.decode, body)
            if not ok_dec or type(resp) ~= "table" or type(resp.choices) ~= "table" or not resp.choices[1] then
                Logger.debug(LOG, "[%s] #%d Unusable response (decode/choices), body='%s'", model_name, req_id, tostring((body or ""):sub(1, 220)))
				if type(on_fail) == "function" then pcall(on_fail) end
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
                if type(on_fail) == "function" then pcall(on_fail) end
                return
            end

            local raw     = Parser.strip_thinking(content)
            local ms_req  = math.floor((hs.timer.secondsSinceEpoch() - t0_req) * 1000)
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
                if type(on_fail) == "function" then pcall(on_fail) end return
            end
            Logger.debug(LOG, "[%s] #%d PARSED -> %d result(s)", model_name, req_id, #results)
            if keylogger and type(keylogger.log_llm) == "function" then pcall(keylogger.log_llm, full_text, results) end
            if type(on_success) == "function" then pcall(on_success, results) end
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
local function post_and_parse_streaming(model_name, system_prompt, full_text, tail_text,
                                         temperature, num_predict_tokens, num_predictions, is_batch,
                                         on_success, on_fail, dedup_stats, on_partial)
	-- Terminate any previous stream so resources are not leaked
	if _active_stream_task then
		pcall(function() _active_stream_task:terminate() end)
		_active_stream_task = nil
	end

	_req_counter = _req_counter + 1
	local req_id = _req_counter

	-- Replicate message/endpoint building from post_and_parse
	local final_sys = system_prompt
	if type(final_sys) == "string" then
		final_sys = final_sys:gsub("%{n%}", tostring(num_predictions))
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

	local is_advanced_prompt = type(final_sys) == "string" and final_sys:find("RÈGLES CRITIQUES", 1, true) ~= nil
	local line_mode = (not is_batch) and (not is_advanced_prompt)
	local opts = build_options(temperature, num_predict_tokens, is_batch, line_mode)

	local payload, endpoint, prompt_preview
	if line_mode then
		local ctx    = type(full_text) == "string" and full_text or ""
		local prompt = (#ctx > 240) and ctx:sub(#ctx - 239) or ctx
		prompt_preview = prompt
		endpoint = "http://127.0.0.1:8080/v1/completions"
		payload = {
			prompt      = prompt,
			stream      = true,
			temperature = opts.temperature,
			max_tokens  = tonumber(opts.max_tokens) or 50,
			stop        = { "\n", "\r", "</", "\"", "- " },
		}
	else
		prompt_preview = merged_prompt
		endpoint = "http://127.0.0.1:8080/v1/chat/completions"
		payload = {
			messages    = { { role = "user", content = merged_prompt } },
			stream      = true,
			temperature = opts.temperature,
			max_tokens  = opts.max_tokens,
			stop        = opts.stop,
			chat_template_kwargs = { enable_thinking = false },
		}
	end

	Logger.debug(LOG, "[%s] #%d STREAM_PROMPT (%d chars) -> %s",
		model_name, req_id, #prompt_preview, prompt_preview:sub(1, 250))

	local ok, encoded = pcall(hs.json.encode, payload)
	if not ok or not encoded then
		Logger.error(LOG, "Failed to encode MLX streaming payload.")
		if type(on_fail) == "function" then pcall(on_fail) end
		return
	end

	local accumulated = ""
	local line_buf    = ""
	local t0_req      = hs.timer.secondsSinceEpoch()

	-- Parse one SSE line (data: {...} or data: [DONE]) and append its token to accumulated
	local function process_sse_line(line)
		Logger.debug(LOG, "[%s] #%d SSE line: '%s'", model_name, req_id, line:sub(1, 120))
		if line:sub(1, 6) ~= "data: " then return end
		local json_str = line:sub(7)
		if json_str == "[DONE]" then return end
		local ok_dec, obj = pcall(hs.json.decode, json_str)
		if not ok_dec or type(obj) ~= "table" or type(obj.choices) ~= "table" or not obj.choices[1] then
			Logger.debug(LOG, "[%s] #%d SSE decode fail: ok=%s type_obj=%s",
				model_name, req_id, tostring(ok_dec), type(obj))
			return
		end
		local choice = obj.choices[1]
		local token  = nil
		-- Chat completions streaming: delta.content
		if type(choice.delta) == "table" and type(choice.delta.content) == "string" then
			token = choice.delta.content
		-- Completions endpoint streaming: text directly
		elseif type(choice.text) == "string" then
			token = choice.text
		end
		if token and token ~= "" then
			accumulated = accumulated .. token
			if type(on_partial) == "function" then pcall(on_partial, accumulated) end
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

	-- Streaming callback: fired each time curl writes a chunk to stdout
	local function on_chunk(_, chunk, stderr_chunk)
		if not chunk or chunk == "" then return true end
		Logger.debug(LOG, "[%s] #%d STREAM chunk (%d bytes): '%s'",
			model_name, req_id, #chunk, chunk:sub(1, 120))
		line_buf = line_buf .. chunk
		flush_lines()
		return true
	end

	-- Completion callback: fired when curl exits
	local function on_done(exit_code, remaining, stderr_out)
		_active_stream_task = nil
		Logger.debug(LOG, "[%s] #%d STREAM on_done: exit=%s remaining_len=%d stderr='%s'",
			model_name, req_id, tostring(exit_code),
			(remaining and #remaining or -1),
			tostring((stderr_out or ""):sub(1, 200)))
		if remaining and remaining ~= "" then
			line_buf = line_buf .. remaining
			flush_lines()
		end

		if accumulated == "" then
			Logger.warn(LOG, "[%s] #%d STREAM: empty accumulation — on_fail.", model_name, req_id)
			if type(on_fail) == "function" then pcall(on_fail) end
			return
		end

		local raw    = Parser.strip_thinking(accumulated)
		local ms_req = math.floor((hs.timer.secondsSinceEpoch() - t0_req) * 1000)
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
			if type(on_fail) == "function" then pcall(on_fail) end
			return
		end
		Logger.debug(LOG, "[%s] #%d STREAM: %d result(s).", model_name, req_id, #results)
		if keylogger and type(keylogger.log_llm) == "function" then pcall(keylogger.log_llm, full_text, results) end
		if type(on_success) == "function" then pcall(on_success, results) end
	end

	-- Write payload to a temp file so curl reads it directly — avoids the
	-- stdin-pipe/streaming-callback conflict in hs.task
	local tmp_path = os.tmpname() .. "_mlx_stream.json"
	local fh = io.open(tmp_path, "w")
	if not fh then
		Logger.error(LOG, "Failed to open temp file '%s' for MLX streaming payload.", tmp_path)
		if type(on_fail) == "function" then pcall(on_fail) end
		return
	end
	fh:write(encoded)
	fh:close()

	local task = hs.task.new("/usr/bin/curl", on_done, on_chunk, {
		"-s", "-N", "-X", "POST",
		"-H", "Content-Type: application/json",
		"--data-binary", "@" .. tmp_path,
		endpoint,
	})
	task:start()
	_active_stream_task = task
	Logger.debug(LOG, "[%s] #%d STREAM task started (payload: %s).", model_name, req_id, tmp_path)

	-- Clean up the temp file once the task has had time to read it
	hs.timer.doAfter(10, function()
		os.remove(tmp_path)
	end)
end




-- ===================================
-- ===================================
-- ======= 3/ Fetch Strategies =======
-- ===================================
-- ===================================

--- Dispatches a single API request asking for N clustered predictions.
--- @param full_text string The complete tracked context string.
--- @param tail_text string The most recent segment of the context.
--- @param model_name string Name of the targeted local model.
--- @param temperature number Base sampling temperature.
--- @param max_predict number Maximum allowed output tokens.
--- @param num_predictions number Request quantity for prediction arrays.
--- @param profile table Active profile mapping.
--- @param on_success function Function to execute on success.
--- @param on_fail function Function to execute on failure.
--- @param request_id_provider function Callback returning the current request identifier.
--- @param streaming boolean Whether to use token-by-token streaming (controlled by init.lua).
--- @param on_partial function|nil Optional token-by-token streaming callback.
function M.fetch_batch(full_text, tail_text, model_name, temperature,
                       max_predict, num_predictions, profile,
                       on_success, on_fail, request_id_provider, streaming, on_partial)

	local effective_temp = tonumber(temperature) or 0.1
	local system_prompt  = Profiles.resolve_system_prompt(profile, num_predictions)
	local tokens         = tonumber(max_predict) * num_predictions + (num_predictions * 5)
	local is_batch       = profile.batch
	local dedup_stats    = ApiCommon.new_dedup_stats()
	local post_fn        = streaming and post_and_parse_streaming or post_and_parse

	local t0 = hs.timer.secondsSinceEpoch()
	post_fn(model_name, system_prompt, full_text, tail_text,
		effective_temp, tokens, num_predictions, is_batch,
		function(results)
			local ms = math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000)
			ApiCommon.log_prediction_summary(Logger, LOG, "batch", num_predictions, dedup_stats, #results)
			if type(on_success) == "function" then pcall(on_success, results, ms, true) end
		end,
		on_fail,
		dedup_stats,
		streaming and on_partial or nil)
end

--- Dispatches multiple parallel API requests incrementing the temperature to aggregate predictions.
--- @param full_text string The complete tracked context string.
--- @param tail_text string The most recent segment of the context.
--- @param model_name string Name of the targeted local model.
--- @param temperature number Base sampling temperature.
--- @param max_predict number Maximum allowed output tokens.
--- @param num_predictions number Request quantity for prediction arrays.
--- @param profile table Active profile mapping.
--- @param on_success function Function to execute on success.
--- @param on_fail function Function to execute on failure.
--- @param request_id_provider function Callback returning the current request identifier.
--- @param streaming boolean Whether to use token-by-token streaming.
--- @param on_partial function|nil Optional token-by-token streaming callback.
function M.fetch_parallel(full_text, tail_text, model_name, temperature,
                          max_predict, num_predictions, profile,
                          on_success, on_fail, request_id_provider, streaming, on_partial)
	-- MLX can produce unstable outputs under parallel fan-out with some models
	-- Force sequential dispatch for reliability while keeping the same public API
	return M.fetch_sequential(full_text, tail_text, model_name, temperature,
		max_predict, num_predictions, profile,
		on_success, on_fail, request_id_provider, streaming, on_partial)
end

--- Dispatches multiple sequential API requests to avoid parallel connection dropping.
--- @param full_text string The complete tracked context string.
--- @param tail_text string The most recent segment of the context.
--- @param model_name string Name of the targeted local model.
--- @param temperature number Base sampling temperature.
--- @param max_predict number Maximum allowed output tokens.
--- @param num_predictions number Request quantity for prediction arrays.
--- @param profile table Active profile mapping.
--- @param on_success function Function to execute on success.
--- @param on_fail function Function to execute on failure.
--- @param request_id_provider function Callback returning the current request identifier.
--- @param streaming boolean Whether to use token-by-token streaming.
--- @param on_partial function|nil Optional token-by-token streaming callback.
function M.fetch_sequential(full_text, tail_text, model_name, temperature,
                             max_predict, num_predictions, profile,
                             on_success, on_fail, request_id_provider, streaming, on_partial)

	local system_prompt = Profiles.resolve_system_prompt(profile, 1)
	local t0            = hs.timer.secondsSinceEpoch()
	local results       = {}
	local base_temp     = tonumber(temperature) or 0.1
	local requested_predictions = math.max(1, math.floor(tonumber(num_predictions) or 1))
	local max_attempts = requested_predictions
	if RETRY_FAILED_PREDICTION_ENABLED == true then
		max_attempts = math.max(requested_predictions, requested_predictions * math.max(1, math.floor(tonumber(RETRY_FAILED_PREDICTION_MAX_MULTIPLIER) or 2)))
	end
	local attempt_index = 1
	local dedup_stats   = ApiCommon.new_dedup_stats()
	local initial_request_id = type(request_id_provider) == "function" and request_id_provider() or nil

	local function do_next()
		-- Check if this request batch was cancelled dynamically
		if type(request_id_provider) == "function" then
			local current_request_id = request_id_provider()
			if initial_request_id ~= nil and current_request_id ~= initial_request_id then
				Logger.debug(LOG, "Request batch cancelled: ID changed from %s to %s at step %d/%d",
					tostring(initial_request_id), tostring(current_request_id), attempt_index, max_attempts)
				return
			end
		end

		if #results >= requested_predictions or attempt_index > max_attempts then
			if #results == 0 then if type(on_fail) == "function" then pcall(on_fail) end return end
			ApiCommon.log_prediction_summary(Logger, LOG, "sequential", requested_predictions, dedup_stats, #results)
			local ms = math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000)
			if type(on_success) == "function" then pcall(on_success, results, ms, true) end
			return
		end

		local variant_index  = attempt_index
		attempt_index        = attempt_index + 1
		local variant_temp   = ApiCommon.get_diversity_temperature(base_temp, variant_index, 0.30)
		local primary_tokens = tonumber(max_predict)
		-- Stream partial updates only for the first variant; retries and diversity
		-- variants run in the background without overwriting the growing preview
		local variant_partial = (variant_index == 1) and on_partial or nil

		local function request_variant(attempt, tokens, temp)
			local post_fn = streaming and post_and_parse_streaming or post_and_parse
			post_fn(model_name, system_prompt, full_text, tail_text,
				temp, tokens, 1, false,
				function(preds)
					if type(preds) == "table" and type(preds[1]) == "table" then
						if #results < requested_predictions then
							ApiCommon.insert_prediction(results, preds[1], dedup_stats, DEDUPLICATION_ENABLED, Logger, LOG)
							local ms = math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000)
							if type(on_success) == "function" then pcall(on_success, results, ms, false) end
						end
					end
					do_next()
				end,
				function()
					if attempt < 2 then
						local retry_tokens = tokens + 5
						local retry_temp   = math.min(1.30, (tonumber(temp) or 0.1) + 0.18)
						Logger.debug(LOG, "[%s] Variant %d/%d quick chat retry: tokens=%d temp=%.2f",
							model_name, variant_index, max_attempts, retry_tokens, retry_temp)
						-- Retry does not stream partial updates (would overwrite the growing preview)
						request_variant(attempt + 1, retry_tokens, retry_temp)
						return
					end
					do_next()
				end,
				dedup_stats,
				streaming and variant_partial or nil)
		end

		request_variant(1, primary_tokens, variant_temp)
	end

	do_next()
end

return M
