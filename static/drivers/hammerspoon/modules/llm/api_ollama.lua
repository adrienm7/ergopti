--- modules/llm/api_ollama.lua

--- ==============================================================================
--- MODULE: LLM API Controller (Ollama)
--- DESCRIPTION:
--- Manages communication with the local Ollama API.
--- ==============================================================================

local M = {}
local hs = hs
local Logger  = require("lib.logger")
local Parser  = require("modules.llm.parser")
local Profiles = require("modules.llm.profiles")
local ApiCommon = require("modules.llm.api_common")
local LOG     = "llm.api_ollama"

local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end

local _req_counter = 0
local _ollama_started = false
local _model_cache = {}
local DEDUPLICATION_ENABLED = ApiCommon.DEFAULT_DEDUPLICATION_ENABLED
local RETRY_FAILED_PREDICTION_ENABLED = true
local RETRY_FAILED_PREDICTION_MAX_MULTIPLIER = 2

-- Holds the current in-flight hs.task; cancelled when a new streaming request starts.
-- The streaming flag itself is owned by modules/llm/init.lua and passed per-call.
local _active_stream_task = nil
-- Monotonic counter; each new stream gets its own ID so a stale on_done from a
-- terminated stream does not clobber the active task reference of a newer one.
local _stream_generation  = 0
-- Readiness flag: true once warmup has confirmed the model is loaded
local _is_ready           = false

--- Returns true when the backend has confirmed it can answer inference requests.
--- @return boolean
function M.is_ready()
	return _is_ready
end

-- Ensure Ollama daemon is running with optimized background start
local function ensure_ollama_running()
	if _ollama_started then return end
	_ollama_started = true
	pcall(function()
		hs.execute("pkill -f '[o]llama serve' 2>/dev/null || true")
		hs.timer.usleep(50 * 1000)
		-- Funnel Ollama stdout/stderr into the unified Ergopti log behind an
		-- [OLLAMA-SERVER] prefix so the user has a single tail target for the
		-- whole stack (HS + MLX + Ollama land in the same /tmp/ergopti.log).
		-- Uses a `while read` loop instead of awk: macOS' default BWK awk
		-- does not implement the gawk-only strftime() / fflush(file) builtins,
		-- so the previous awk pipeline crashed on the first line and killed
		-- the ollama subprocess on SIGPIPE.
		hs.execute(
			"nohup bash -c \"/opt/homebrew/bin/ollama serve 2>&1 | " ..
			"while IFS= read -r LINE; do " ..
			"printf '%s [OLLAMA-SERVER] %s\\n' \\\"\\$(date +%H:%M:%S)\\\" \\\"\\$LINE\\\" " ..
			">> /tmp/ergopti.log; " ..
			"done\" &"
		)
	end)
end

-- Deferred off the synchronous require path to avoid blocking Hammerspoon startup
hs.timer.doAfter(0, function() pcall(ensure_ollama_running) end)

--- Sends a minimal 1-token inference to load model weights into GPU memory.
--- Called once after the model is configured; subsequent real requests then
--- skip the cold-start penalty (typically 1–3 s for a 2B model on Apple Silicon).
--- @param model_name string The Ollama model identifier to pre-load.
function M.warmup(model_name)
	if type(model_name) ~= "string" or model_name == "" then return end
	Logger.debug(LOG, "Warming up model '%s'…", model_name)
	local ok, encoded = pcall(hs.json.encode, {
		model      = model_name,
		messages   = { { role = "user", content = " " } },
		stream     = false,
		keep_alive = "30m",
		options    = { num_predict = 1, temperature = 0 },
	})
	if not ok then return end
	hs.http.asyncPost(
		"http://127.0.0.1:11434/api/chat",
		encoded,
		{ ["Content-Type"] = "application/json" },
		function(status, _)
			if status == 200 then
				_is_ready = true
				Logger.info(LOG, "Model '%s' warmed up — GPU cache ready.", model_name)
			else
				_is_ready = false
				Logger.debug(LOG, "Warmup request returned %s — model may not be loaded yet.", tostring(status))
			end
		end
	)
end

--- Terminates the in-flight streaming task if one is active.
--- Called when a newer request supersedes the current one.
function M.cancel_streaming()
	-- Bump generation so any stale on_done from a terminated stream becomes a no-op
	_stream_generation = _stream_generation + 1
	if _active_stream_task then
		pcall(function() _active_stream_task:terminate() end)
		_active_stream_task = nil
		Logger.debug(LOG, "Active Ollama stream cancelled.")
	end
end





-- ===================================
-- ===================================
-- ======= 1/ Model Heuristics =======
-- ===================================
-- ===================================

--- Determines if a model is categorized as a thinking model based on its name.
--- @param name string The model name to evaluate.
--- @return boolean True if it is a thinking model, false otherwise.
local function is_thinking_model(name)
	if type(name) ~= "string" then return false end
	name = name:lower()
	if name:match("qwen3") or name:match("deepseek") or name:match("%-r1") or name:match(":r1") or name:match("think") then return true end
	return false
end
M.is_thinking_model = is_thinking_model

--- Asynchronously checks if a specific model is available in the local Ollama instance.
--- @param model_name string The name of the model to check.
--- @param on_available function Callback executed if the model is found.
--- @param on_missing function Callback executed if the model is missing or API is unreachable.
function M.check_availability(model_name, on_available, on_missing)
	if type(model_name) ~= "string" then return end
	Logger.debug(LOG, "Checking Ollama server availability…")
	
	hs.http.asyncGet("http://127.0.0.1:11434/api/tags", {}, function(status, body)
		if status ~= 200 then
			Logger.warn(LOG, "Ollama server is unreachable.")
			if type(on_missing) == "function" then pcall(on_missing, true) end
			return
		end
		
		local ok, tags = pcall(hs.json.decode, body)
		if ok and type(tags) == "table" and type(tags.models) == "table" then
			local found = false
			for _, m in ipairs(tags.models) do
				if type(m.name) == "string" and m.name:find(model_name, 1, true) then
					found = true
					break
				end
			end
			
			if found then
				Logger.info(LOG, "Ollama server and model are available.")
				if type(on_available) == "function" then pcall(on_available) end
			else
				Logger.warn(LOG, "Ollama model is missing.")
				if type(on_missing) == "function" then pcall(on_missing, false) end
			end
		else
			Logger.error(LOG, "Failed to parse Ollama tags response.")
			if type(on_missing) == "function" then pcall(on_missing, false) end
		end
	end)
end





-- ======================================
-- ======================================
-- ======= 2/ Core Request Engine =======
-- ======================================
-- ======================================

-- Pre-allocated stop sequences for performance optimization
local STOP_BASE     = { "<|eot_id|>", "<|im_end|>", "[/INST]", "PREFIX:", "TAIL:" }
local STOP_BATCH    = { "<|eot_id|>", "<|im_end|>", "[/INST]", "PREFIX:", "TAIL:" }
local STOP_LINE     = { "<|eot_id|>", "<|im_end|>", "[/INST]", "PREFIX:", "TAIL:", "\n\n", "===", "\n", "\r", "</", "Suite finale", "SUITE", "NEXT_WORDS:" }

--- Builds the options payload for the Ollama API (optimized for speed).
--- @param temperature number The creativity parameter.
--- @param num_predict_tokens number Max tokens to predict.
--- @param model_name string Name of the target model.
--- @param is_batch boolean Whether this request is a batch prompt expecting multiple outputs.
--- @param line_mode boolean Line mode flag.
--- @return table The options configuration table.
local function build_options(temperature, num_predict_tokens, model_name, is_batch, line_mode)
    local opts = {
        temperature = tonumber(temperature) or 0.1,
        num_predict = tonumber(num_predict_tokens),
        stop        = (line_mode and not is_batch) and STOP_LINE or STOP_BATCH,
    }
    
    opts.think = false
    opts.thinking_budget = 0
    
    return opts
end

--- Resolves the system prompt template and builds the Ollama messages array.
--- Shared by post_and_parse and post_and_parse_streaming to avoid duplication.
--- @param system_prompt string|nil Raw prompt template.
--- @param full_text string Full context string.
--- @param tail_text string Tail context string.
--- @param num_predictions number Substituted for {n} in the prompt.
--- @param is_batch boolean Whether this is a batch request.
--- @return table messages, boolean line_mode, string user_prompt_preview
local function build_request_context(system_prompt, full_text, tail_text, num_predictions, is_batch)
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
			final_sys   = nil
		else
			user_prompt = context_str
		end
	end
	local is_advanced = type(final_sys) == "string" and (
		final_sys:find("TAIL_CORRECTED", 1, true) or final_sys:find("NEXT_WORDS", 1, true)
	)
	local line_mode = (not is_batch) and (not is_advanced)
	local messages  = {}
	if final_sys and final_sys ~= "" then
		table.insert(messages, { role = "system", content = final_sys })
	end
	table.insert(messages, { role = "user", content = user_prompt })
	return messages, line_mode, user_prompt
end

--- Posts data to the local LLM and parses the response (non-streaming path).
--- @param model_name string The LLM model name.
--- @param system_prompt string The resolved instructions.
--- @param full_text string The complete preceding document text.
--- @param tail_text string The immediate trailing text.
--- @param temperature number Model temperature.
--- @param num_predict_tokens number Token limits.
--- @param num_predictions number Total predictions to process from batch.
--- @param is_batch boolean Flag to determine batch parsing strategy.
--- @param on_success function Callback triggering on successful parse.
--- @param on_fail function Callback triggering on failure.
--- @param dedup_stats table Dedup stats metrics.
local function post_and_parse(model_name, system_prompt, full_text, tail_text,
                               temperature, num_predict_tokens, num_predictions, is_batch,
                               on_success, on_fail, dedup_stats)
    _req_counter = _req_counter + 1
    local req_id = _req_counter

    local messages, line_mode, user_prompt = build_request_context(
        system_prompt, full_text, tail_text, num_predictions, is_batch)

    local t0_req = hs.timer.secondsSinceEpoch()
    Logger.debug(LOG, "[%s] #%d PROMPT (%d chars) mode_line=%s -> %s", model_name, req_id, #user_prompt, tostring(line_mode), user_prompt:sub(1, 250))

    local payload = {
        model      = tostring(model_name),
        messages   = messages,
        stream     = false,
        think      = false,
        keep_alive = "30m",
        options    = build_options(temperature, num_predict_tokens, model_name, is_batch, line_mode),
    }

	local ok, encoded = pcall(hs.json.encode, payload)
	if not ok or not encoded then
		Logger.error(LOG, "Failed to encode Ollama payload.")
		if type(on_fail) == "function" then pcall(on_fail) end
		return
	end

    hs.http.asyncPost("http://127.0.0.1:11434/api/chat", encoded, { ["Content-Type"] = "application/json" },
        function(status, body, _)
            pcall(function()
                Logger.debug(LOG, "[%s] #%d HTTP_RESPONSE status=%d, body_len=%d", model_name, req_id, status or -1, #(body or ""))
                
                if not status or status ~= 200 then 
                    Logger.error(LOG, "[%s] #%d HTTP_ERROR status=%d: %s", model_name, req_id, status or -1, (body or ""):sub(1, 200))
                    if type(on_fail) == "function" then pcall(on_fail) end 
                    return 
                end
                
                local ok_dec, resp = pcall(hs.json.decode, body)
                if not ok_dec then
                    Logger.error(LOG, "[%s] #%d JSON_DECODE_ERROR: %s", model_name, req_id, tostring(resp))
                    if type(on_fail) == "function" then pcall(on_fail) end
                    return
                end
                
                if type(resp) ~= "table" then
                    Logger.error(LOG, "[%s] #%d RESPONSE_INVALID: resp type=%s", model_name, req_id, type(resp))
                    if type(on_fail) == "function" then pcall(on_fail) end
                    return
                end
                
                if type(resp.message) ~= "table" then
                    Logger.error(LOG, "[%s] #%d MESSAGE_INVALID: message type=%s", model_name, req_id, type(resp.message))
                    if type(on_fail) == "function" then pcall(on_fail) end
                    return
                end
                
                local content = type(resp.message.content) == "string" and resp.message.content or ""
                local thinking = type(resp.message.thinking) == "string" and resp.message.thinking or ""
                if content == "" then
                    if thinking ~= "" then
                        Logger.debug(LOG, "[%s] #%d Ollama reasoning-only response detected (empty content, thinking present).", model_name, req_id)
                    else
                        Logger.error(LOG, "[%s] #%d CONTENT_INVALID: content type=%s", model_name, req_id, type(resp.message.content))
                    end
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
            end)
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

	_stream_generation = _stream_generation + 1
	local my_generation = _stream_generation

	_req_counter = _req_counter + 1
	local req_id = _req_counter

	local messages, line_mode, user_prompt = build_request_context(
		system_prompt, full_text, tail_text, num_predictions, is_batch)

	local t0_req = hs.timer.secondsSinceEpoch()
	Logger.debug(LOG, "[%s] #%d STREAM_PROMPT (%d chars) -> %s",
		model_name, req_id, #user_prompt, user_prompt:sub(1, 250))

	local payload = {
		model      = tostring(model_name),
		messages   = messages,
		stream     = true,
		think      = false,
		keep_alive = "30m",
		options    = build_options(temperature, num_predict_tokens, model_name, is_batch, line_mode),
	}

	local ok, encoded = pcall(hs.json.encode, payload)
	if not ok or not encoded then
		Logger.error(LOG, "Failed to encode Ollama streaming payload.")
		if type(on_fail) == "function" then pcall(on_fail) end
		return
	end

	local accumulated = ""
	local line_buf    = ""

	-- Parse one complete NDJSON line and append its content to accumulated
	local function process_line(line)
		local ok_dec, obj = pcall(hs.json.decode, line)
		if not ok_dec or type(obj) ~= "table" then return end
		if type(obj.message) == "table" and type(obj.message.content) == "string" then
			local token = obj.message.content
			if token ~= "" then
				accumulated = accumulated .. token
				if type(on_partial) == "function" then pcall(on_partial, accumulated) end
			end
		end
	end

	-- Drain line_buf, processing every complete line found
	local function flush_lines()
		while true do
			local nl = line_buf:find("\n", 1, true)
			if not nl then break end
			local line = line_buf:sub(1, nl - 1)
			line_buf   = line_buf:sub(nl + 1)
			if line ~= "" then process_line(line) end
		end
	end

	-- Streaming callback: fired each time curl writes a chunk to stdout
	local function on_chunk(_, chunk, _)
		if not chunk or chunk == "" then return true end
		-- Generation check: discard chunks from a stream that has been superseded
		if my_generation ~= _stream_generation then return false end
		line_buf = line_buf .. chunk
		flush_lines()
		return true
	end

	-- Completion callback: fired when curl exits
	local function on_done(_, remaining, _)
		-- Generation check: a newer request superseded this stream — don't touch
		-- shared state (otherwise we untrack the active stream and leak its task)
		if my_generation ~= _stream_generation then
			Logger.debug(LOG, "[%s] #%d STREAM: superseded — discarding on_done.", model_name, req_id)
			return
		end
		_active_stream_task = nil
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
	local tmp_path = os.tmpname() .. "_ollama_stream.json"
	local fh = io.open(tmp_path, "w")
	if not fh then
		Logger.error(LOG, "Failed to open temp file '%s' for Ollama streaming payload.", tmp_path)
		if type(on_fail) == "function" then pcall(on_fail) end
		return
	end
	fh:write(encoded)
	fh:close()

	local task = hs.task.new("/usr/bin/curl", on_done, on_chunk, {
		"-s", "-N", "-X", "POST",
		"-H", "Content-Type: application/json",
		"--data-binary", "@" .. tmp_path,
		"http://127.0.0.1:11434/api/chat",
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
			-- With streaming OFF: reveal each prediction one by one (complete, no animation) so
			-- the user sees slot 1 fill, then slot 2, etc. rather than all appearing at once.
			-- Each doAfter(0) yields to the event loop so the tooltip renders between reveals.
			-- With streaming ON: on_partial_cb already showed each pred token by token;
			-- emit the final call directly to replace stream placeholders with diff colors.
			if not streaming and #results > 1 then
				local function reveal_next(idx)
					if idx > #results then return end
					local subset = {}
					for j = 1, idx do subset[j] = results[j] end
					local is_final = (idx == #results)
					-- Pass is_batch_progressive=true so prediction_engine bypasses the
					-- streaming_multi early-return for these intermediate calls
					if type(on_success) == "function" then pcall(on_success, subset, ms, is_final, not is_final) end
					if not is_final then hs.timer.doAfter(0, function() reveal_next(idx + 1) end) end
				end
				reveal_next(1)
			else
				if type(on_success) == "function" then pcall(on_success, results, ms, true) end
			end
		end,
		on_fail,
		dedup_stats,
		streaming and on_partial or nil)
end

--- Dispatches multiple sequential API requests.
--- @param streaming boolean Whether to use token-by-token streaming.
--- @param on_partial function|nil Optional token-by-token streaming callback.
function M.fetch_parallel(full_text, tail_text, model_name, temperature,
                          max_predict, num_predictions, profile,
                          on_success, on_fail, request_id_provider, streaming, on_partial)
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
		-- Each variant streams its tokens via on_partial so the tooltip shows each
		-- prediction building in its own slot; prediction_engine.lua keeps the cursor
		-- at slot 1 (or wherever the user navigated) regardless of which slot streams
		local variant_partial = on_partial

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
						Logger.debug(LOG, "[%s] Variant %d/%d quick retry: tokens=%d temp=%.2f",
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
