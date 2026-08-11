--- modules/llm/api_ollama.lua

--- ==============================================================================
--- MODULE: LLM API Controller (Ollama)
--- DESCRIPTION:
--- Manages communication with the local Ollama API.
--- ==============================================================================

local M = {}
local Logger  = require("infra.logger")
local text_utils = require("infra.text_utils")
local Notifications = require("infra.notifications")
local i18n    = require("infra.i18n")
local Parser         = require("modules.llm.parser")
local Profiles       = require("modules.llm.profiles")
local ApiCommon      = require("modules.llm.api_common")
-- Two independent HTTP clients: one for long inference POST requests, one for
-- quick health-check GETs on /api/tags. A single shared client would cancel
-- an in-flight completion whenever a background availability ping arrived.
local _infer_client  = require("adapters.http_client").new()
local _check_client  = require("adapters.http_client").new()
local JsonCodec      = require("adapters.json_codec")
local TimerScheduler = require("adapters.timer_scheduler")
local ShellRunner    = require("adapters.shell_runner")
local OllamaServerCommand = require("modules.llm.ollama_server_command")
local LOG            = "llm.api_ollama"

-- Ollama bind address. The default port is the single source in
-- _shared/modules/llm/defaults.json (llm_ollama_port, surfaced via DEFAULT_STATE); a user
-- override from the LLM menu (settings key OLLAMA_PORT_SETTING_KEY) wins so a
-- port collision can be resolved without editing any file. Host stays loopback.
local OLLAMA_DEFAULT_HOST     = "127.0.0.1"
local OLLAMA_PORT_SETTING_KEY = "ergopti.llm.ollama_port"
local OLLAMA_PORT_MIN, OLLAMA_PORT_MAX = 1024, 65535

-- Persistent store for the user's port override. Routed through the Storage port
-- adapter (not the OS settings store directly) so this module stays OS-pure; the
-- adapter wraps the same key the LLM menu persists.
local Storage = require("adapters.storage")

--- Reads a valid user port override from persistent storage, or nil when unset.
--- @return integer|nil
local function read_ollama_port_override()
	local ok, v = pcall(Storage.get, OLLAMA_PORT_SETTING_KEY)
	if not ok then return nil end
	v = tonumber(v)
	if type(v) ~= "number" or v < OLLAMA_PORT_MIN or v > OLLAMA_PORT_MAX then return nil end
	return math.floor(v)
end

--- Resolves the Ollama port: a valid user override wins, otherwise the canonical
--- default from _shared/modules/llm/defaults.json (DEFAULT_STATE.llm_ollama_port). init is
--- required lazily to avoid the init <-> api_ollama require cycle.
--- @return integer
local function resolve_ollama_port()
	local override = read_ollama_port_override()
	if override then return override end
	local ok, Core = pcall(require, "modules.llm.init")
	local ds   = ok and Core and Core.DEFAULT_STATE or nil
	local port = ds and tonumber(ds.llm_ollama_port)
	if port then return math.floor(port) end
	Logger.error(LOG, "llm_ollama_port missing from DEFAULT_STATE (_shared/modules/llm/defaults.json) — LLM defaults not initialised.")
	return 11434
end

--- Returns the Ollama base URL ("http://host:port"), honouring the user override.
--- @return string
function M.get_base_url()
	return "http://" .. OLLAMA_DEFAULT_HOST .. ":" .. tostring(resolve_ollama_port())
end

local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end

local _req_counter = 0
local _ollama_started = false
local _ollama_starting = false
local _ollama_start_generation = 0
local _ollama_kill_task = nil
local _ollama_launch_timer = nil
local _ollama_serve_task = nil
local _ollama_ambiguous_task = nil
local DEDUPLICATION_ENABLED = ApiCommon.DEFAULT_DEDUPLICATION_ENABLED
-- Retry policy lives in _shared/modules/llm/inference.json so the AHK twin can read
-- the same numbers. ``max_mult`` is the upper bound on attempts as a
-- multiple of requested_predictions; ``retry_temp_step`` is added on top of
-- the diversity step for the 2nd attempt; ``retry_extra_tokens`` gives the
-- retry a larger budget so a too-short first attempt has room to finish.
local _RETRY_MAX_MULT, _RETRY_TEMP_STEP, _RETRY_EXTRA_TOKENS = ApiCommon.get_retry_policy()
local RETRY_FAILED_PREDICTION_ENABLED        = (_RETRY_MAX_MULT or 0) > 1
local RETRY_FAILED_PREDICTION_MAX_MULTIPLIER = _RETRY_MAX_MULT

-- Holds the current in-flight hs.task; cancelled when a new streaming request starts.
-- The streaming flag itself is owned by modules/llm/init.lua and passed per-call.
local _active_stream_task = nil
-- Monotonic counter; each new stream gets its own ID so a stale on_done from a
-- terminated stream does not clobber the active task reference of a newer one.
local _stream_generation  = 0
-- Readiness flag: true once warmup has confirmed the model is loaded
local _is_ready           = false
-- Bumped by reset_ready(); a warmup callback that captured an older value describes
-- a server/model that is no longer current and must discard itself. Mirrors the
-- api_mlx _warmup_gen invariant (F-L4).
local _warmup_gen         = 0

--- Returns true when the backend has confirmed it can answer inference requests.
--- @return boolean
function M.is_ready()
	return _is_ready
end

--- Clears the readiness flag so the NEXT warmup must re-confirm the backend.
--- _is_ready is only ever set true by a 200 warmup; nothing else cleared it, so a
--- backend round-trip (MLX kills `ollama serve`, then back to Ollama) or a model
--- switch left it stale-true. The warmup retry chain then self-terminates on the
--- stale flag and perform_check dispatches to a dead/cold server. Mirrors the MLX
--- reset_endpoints() invariant: a fresh server/model deserves a fresh verdict (F-M8).
function M.reset_ready()
	_is_ready = false
	-- Clearing the flag alone is racy: an Ollama warmup POST triggers the actual
	-- model load and can stay in flight for tens of seconds, so a response issued
	-- against the PREVIOUS server can still land after this reset and flip
	-- _is_ready back to true. warmup_controller.try_warmup then sees a ready
	-- backend, logs "stopping retry chain" and terminates — no warmup ever runs
	-- again for the session and every prediction goes to a dead server. Bumping
	-- the generation makes those in-flight callbacks self-discard.
	_warmup_gen = _warmup_gen + 1
	Logger.debug(LOG, "Ollama readiness flag reset — next warmup must re-confirm (gen %d).", _warmup_gen)
end

--- Invalidates any in-flight warmup POST so its response cannot flip _is_ready or
--- fire the user-facing "server ready" notification after the LLM gate closed
--- (pause, or set_llm_enabled(false)). Mirrors api_mlx.stop_warmup (M-3), but
--- without a _warmup_stopped flag — Ollama has no self-rescheduling retry chain to
--- short-circuit — and without clearing _is_ready, so a resume does not force a
--- pointless re-warm when the weights really are loaded.
function M.stop_warmup()
	_warmup_gen = _warmup_gen + 1
	Logger.debug(LOG, "stop_warmup() — gen bumped to %d, in-flight warmup invalidated.", _warmup_gen)
end

-- Delay before launching Ollama after killing a stale instance (seconds)
local OLLAMA_KILL_SETTLE_SEC = 0.1

-- curl --max-time ceiling for streaming requests (seconds).
-- STREAM_TMPFILE_CLEANUP_SEC is the safety-net delay before removing the
-- payload temp file; it must be strictly greater than STREAM_MAX_TIME_SEC so
-- the file is never deleted while curl is still reading it.
local STREAM_MAX_TIME_SEC      = 60
local STREAM_TMPFILE_CLEANUP_SEC = 70

-- Ensure Ollama daemon is running — fully async to avoid blocking the Cocoa
-- run loop. Previous implementation used synchronous hs.execute + usleep which
-- permanently corrupted the CFRunLoop and killed timers/menubar/eventtaps.
-- @return boolean accepted True when a daemon is running or one launch attempt
-- was committed to native async ownership.
local function ensure_ollama_running()
	-- A thrown start is outside ShellRunner's normal contract, but an injected or
	-- future adapter can still leave native ownership ambiguous. Do not launch a
	-- sibling until the exact retained capability has been terminated.
	if _ollama_ambiguous_task then
		local ambiguous = _ollama_ambiguous_task
		local stop_ok, stop_result = xpcall(function() return ambiguous.terminate() end, debug.traceback)
		if not stop_ok or stop_result ~= true then
			Logger.error(LOG, "Ambiguous Ollama startup task could not be revoked; launch remains fenced: %s",
				tostring(stop_result))
			return false
		end
		if _ollama_ambiguous_task == ambiguous then _ollama_ambiguous_task = nil end
		_ollama_start_generation = _ollama_start_generation + 1
		_ollama_starting = false
	end

	if _ollama_started or _ollama_starting then return true end

	_ollama_start_generation = _ollama_start_generation + 1
	local my_generation = _ollama_start_generation
	_ollama_starting = true

	local function fail_start(stage, result, ambiguous_task)
		if my_generation ~= _ollama_start_generation then return false end
		_ollama_kill_task = nil
		_ollama_launch_timer = nil
		if ambiguous_task then
			local stop_ok, stop_result = xpcall(function() return ambiguous_task.terminate() end, debug.traceback)
			if not stop_ok or stop_result ~= true then
				_ollama_ambiguous_task = ambiguous_task
				_ollama_starting = true
				Logger.error(LOG, "Ollama %s left ambiguous native ownership; retry fenced: %s",
					tostring(stage), tostring(stop_result))
				return false
			end
		end
		_ollama_starting = false
		Logger.error(LOG, "Ollama %s did not commit (result: %s); launch remains retryable.",
			tostring(stage), tostring(result))
		return false
	end

	-- Locals are declared above the callbacks that capture them. Moving either
	-- declaration below its closure silently binds a nil global in Lua.
	local kill_handle
	local function on_kill_done()
		local callback_ok, callback_err = xpcall(function()
			if my_generation ~= _ollama_start_generation or not _ollama_starting then return end
			if _ollama_kill_task ~= kill_handle then return end
			_ollama_kill_task = nil

			local launch_handle
			local launch_callback_ran = false
			local function launch_server()
				launch_callback_ran = true
				local launch_ok, launch_err = xpcall(function()
					if my_generation ~= _ollama_start_generation or not _ollama_starting then return end
					_ollama_launch_timer = nil

					-- Funnel Ollama stdout/stderr into the unified Ergopti log behind an
					-- [OLLAMA-SERVER] prefix. The shared builder captures only the stable
					-- directory; its shell loop derives the dated filename for every line.
					local launch_cmd, command_err = OllamaServerCommand.build(
						"/opt/homebrew/bin/ollama", Logger.UNIFIED_LOG_FILE)
					if not launch_cmd then
						fail_start("server command creation", command_err)
						return
					end

					local serve_handle
					local serve_completed = false
					local function on_serve_done()
						local done_ok, done_err = xpcall(function()
							serve_completed = true
							if my_generation ~= _ollama_start_generation then return end
							if _ollama_serve_task ~= serve_handle then return end
							_ollama_serve_task = nil
							_ollama_started = false
							_ollama_starting = false
							Logger.warn(LOG, "Ollama server task exited; the next demand will relaunch it.")
						end, debug.traceback)
						if not done_ok then Logger.error(LOG, "Ollama server completion callback raised: %s", tostring(done_err)) end
					end

					local spawn_ok, spawned = xpcall(function()
						return ShellRunner.spawn("/bin/sh", { "-c", launch_cmd }, on_serve_done)
					end, debug.traceback)
					if not spawn_ok or type(spawned) ~= "table" or type(spawned.start) ~= "function" then
						fail_start("server task creation", spawned)
						return
					end
					serve_handle = spawned
					_ollama_serve_task = serve_handle
					local start_ok, start_result = xpcall(function() return serve_handle.start() end, debug.traceback)
					if not start_ok then
						_ollama_serve_task = nil
						fail_start("server task start", start_result, serve_handle)
						return
					end
					if start_result ~= true then
						_ollama_serve_task = nil
						fail_start("server task start", start_result)
						return
					end
					if not serve_completed and my_generation == _ollama_start_generation then
						_ollama_started = true
						_ollama_starting = false
						Logger.debug(LOG, "Ollama server launched asynchronously.")
					end
				end, debug.traceback)
				if not launch_ok then fail_start("server launch callback", launch_err) end
			end

			local schedule_ok, scheduled, settle_committed = xpcall(function()
				return TimerScheduler.after(OLLAMA_KILL_SETTLE_SEC, launch_server)
			end, debug.traceback)
			if not schedule_ok or settle_committed ~= true then
				fail_start("settle timer", scheduled)
				return
			end
			launch_handle = scheduled
			if not launch_callback_ran then _ollama_launch_timer = launch_handle end
		end, debug.traceback)
		if not callback_ok then fail_start("kill completion callback", callback_err) end
	end

	local spawn_ok, spawned = xpcall(function()
		return ShellRunner.spawn("/bin/sh", {
			"-c", "pkill -f '[o]llama serve' 2>/dev/null || true"
		}, on_kill_done)
	end, debug.traceback)
	if not spawn_ok or type(spawned) ~= "table" or type(spawned.start) ~= "function" then
		return fail_start("stale-process task creation", spawned)
	end
	kill_handle = spawned
	_ollama_kill_task = kill_handle
	local start_ok, start_result = xpcall(function() return kill_handle.start() end, debug.traceback)
	if not start_ok then
		return fail_start("stale-process task start", start_result, kill_handle)
	end
	if start_result ~= true then
		return fail_start("stale-process task start", start_result)
	end
	return true
end

--- Ensures the Ollama daemon is running.
--- Must be called by the LLM orchestrator only when the effective backend is
--- Ollama — calling it unconditionally at require-time launches Ollama even for
--- MLX or API users who never selected it.
function M.ensure_running()
	local ok, result = xpcall(ensure_ollama_running, debug.traceback)
	if not ok or result ~= true then
		Logger.error(LOG, "ensure_running() did not commit: %s", tostring(result))
		return false
	end
	return true
end

--- Sends a minimal 1-token inference to load model weights into GPU memory.
--- Called once after the model is configured; subsequent real requests then
--- skip the cold-start penalty (typically 1–3 s for a 2B model on Apple Silicon).
--- @param model_name string The Ollama model identifier to pre-load.
function M.warmup(model_name)
	if type(model_name) ~= "string" or model_name == "" then return end
	Logger.debug(LOG, "Warming up model '%s'…", model_name)
	local encoded, enc_err = JsonCodec.encode({
		model      = model_name,
		messages   = { { role = "user", content = " " } },
		stream     = false,
		keep_alive = ApiCommon.OLLAMA_KEEP_ALIVE,
		options    = { num_predict = 1, temperature = 0 },
	})
	if not encoded then
		Logger.error(LOG, "warmup: encode failed — %s", tostring(enc_err))
		return
	end
	-- Snapshot the warmup generation: if reset_ready() bumps it while this POST is
	-- in flight, the response describes a now-stale server/model and its callback
	-- must not touch _is_ready (see reset_ready for the self-termination scenario).
	local my_warmup_gen = _warmup_gen
	_infer_client.post(
		M.get_base_url() .. "/api/chat",
		{ ["Content-Type"] = "application/json" },
		encoded,
		function(r)
			if my_warmup_gen ~= _warmup_gen then
				Logger.debug(LOG, "Discarding stale Ollama warmup response (gen %d != %d) — it describes a server/model that is no longer current.",
					my_warmup_gen, _warmup_gen)
				return
			end
			if r.status == 200 then
				local became_ready = (_is_ready ~= true)
				_is_ready = true
				Logger.info(LOG, "Model '%s' warmed up — GPU cache ready.", model_name)
				if became_ready then
					Notifications.notify(i18n.get("llm.server_ready_title"), i18n.get("llm.server_ollama_ready_body"), "success")
				end
			else
				_is_ready = false
				Logger.debug(LOG, "Warmup request returned %s — model may not be loaded yet.", tostring(r.status))
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
		local task = _active_stream_task
		local ok, result = xpcall(function() return task.terminate() end, debug.traceback)
		if not ok or result ~= true then
			Logger.error(LOG, "Active Ollama stream cancellation failed; retained for retry: %s", tostring(result))
			return false
		end
		_active_stream_task = nil
		Logger.debug(LOG, "Active Ollama stream cancelled.")
	end
	return true
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
	
	_check_client.get(M.get_base_url() .. "/api/tags", {}, function(r)
		if r.status ~= 200 then
			Logger.warn(LOG, "Ollama server is unreachable.")
			if type(on_missing) == "function" then ApiCommon.protected_call(on_missing, "on_missing", true) end
			return
		end
		local body = r.body
		local tags, _ = JsonCodec.decode(body)
		if type(tags) == "table" and type(tags.models) == "table" then
			local found = false
			for _, m in ipairs(tags.models) do
				if type(m.name) == "string" and m.name:find(model_name, 1, true) then
					found = true
					break
				end
			end
			
			if found then
				Logger.info(LOG, "Ollama server and model are available.")
				if type(on_available) == "function" then ApiCommon.protected_call(on_available, "on_available") end
			else
				Logger.warn(LOG, "Ollama model is missing.")
				if type(on_missing) == "function" then ApiCommon.protected_call(on_missing, "on_missing", false) end
			end
		else
			Logger.error(LOG, "Failed to parse Ollama tags response.")
			if type(on_missing) == "function" then ApiCommon.protected_call(on_missing, "on_missing", false) end
		end
	end)
end





-- ======================================
-- ======================================
-- ======= 2/ Core Request Engine =======
-- ======================================
-- ======================================

-- Stop sequences must come from inference.json via ApiCommon, with a defensive
-- fallback to empty lists if the common module is unavailable in a test harness.
-- This avoids hardcoding legacy literals here while preserving module load safety.
local function get_stop_sequences(variant)
	if type(ApiCommon.get_stop_sequences) == "function" then
		local ok, seq = pcall(ApiCommon.get_stop_sequences, variant)
		if ok and type(seq) == "table" then return seq end
	end
	return {}
end

local STOP_BATCH = get_stop_sequences("batch")
local STOP_LINE  = get_stop_sequences("line")

--- Builds the options payload for the Ollama API (optimized for speed).
--- @param temperature number The creativity parameter.
--- @param num_predict_tokens number Max tokens to predict.
--- @param model_name string Name of the target model.
--- @param is_batch boolean Whether this request is a batch prompt expecting multiple outputs.
--- @param line_mode boolean Line mode flag.
--- @return table The options configuration table.
local function build_options(temperature, num_predict_tokens, model_name, is_batch, line_mode)
    local opts = {
        temperature = tonumber(temperature) or ApiCommon.DEFAULT_TEMPERATURE,
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

    local t0_req = TimerScheduler.now()
    Logger.debug(LOG, "[%s] #%d PROMPT (%d chars) mode_line=%s -> %s", model_name, req_id, #user_prompt, tostring(line_mode), user_prompt:sub(1, 250))

    local payload = {
        model      = tostring(model_name),
        messages   = messages,
        stream     = false,
        think      = false,
        keep_alive = ApiCommon.OLLAMA_KEEP_ALIVE,
        options    = build_options(temperature, num_predict_tokens, model_name, is_batch, line_mode),
    }

	local encoded, enc_err = JsonCodec.encode(payload)
	if not encoded then
		Logger.error(LOG, "Failed to encode Ollama payload — %s", tostring(enc_err))
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end

	_infer_client.post(M.get_base_url() .. "/api/chat", { ["Content-Type"] = "application/json" }, encoded,
		function(r)
			local status, body = r.status, r.body
			-- xpcall, not a bare pcall whose status is discarded. The ENTIRE
			-- non-streaming response path runs in here — status checks, JSON
			-- decode, result shaping and the on_success hand-off — so a throw
			-- anywhere in it produced no prediction, no error and nothing to
			-- search the log for: the "green but no prediction" shape, with the
			-- whole handler as its blast radius.
			local ok_response, response_err = xpcall(function()
				Logger.debug(LOG, "[%s] #%d HTTP_RESPONSE status=%d, body_len=%d", model_name, req_id, status or -1, #(body or ""))

				if not status or status ~= 200 then
					Logger.error(LOG, "[%s] #%d HTTP_ERROR status=%d: %s", model_name, req_id, status or -1, (body or ""):sub(1, 200))
					if keylogger and type(keylogger.log_llm_failed) == "function" then
						pcall(keylogger.log_llm_failed, full_text, nil, {
							backend        = "ollama",
							model          = tostring(model_name),
							system_prompt  = system_prompt,
							user_prompt    = user_prompt,
							failure_reason = "http_" .. tostring(status or "unknown"),
						})
					end
					if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
					return
				end

				local resp, dec_err = JsonCodec.decode(body)
				if not resp then
					Logger.error(LOG, "[%s] #%d JSON_DECODE_ERROR: %s", model_name, req_id, tostring(dec_err))
					if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
                    return
                end
                
                if type(resp) ~= "table" then
                    Logger.error(LOG, "[%s] #%d RESPONSE_INVALID: resp type=%s", model_name, req_id, type(resp))
                    if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
                    return
                end
                
                if type(resp.message) ~= "table" then
                    Logger.error(LOG, "[%s] #%d MESSAGE_INVALID: message type=%s", model_name, req_id, type(resp.message))
                    if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
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
                        backend       = "ollama",
                        model         = tostring(model_name),
                        system_prompt = system_prompt,
                        user_prompt   = user_prompt,
                    })
                end
			if type(on_success) == "function" then ApiCommon.protected_call(on_success, "on_success", results) end
			end, debug.traceback)
			if not ok_response then
				Logger.error(LOG, "[%s] #%d response handler raised: %s. The request is abandoned — "
					.. "nothing downstream retries it, so the user simply never sees a prediction.",
					tostring(model_name), req_id, tostring(response_err))
			end
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
	if _active_stream_task and M.cancel_streaming() ~= true then
		Logger.error(LOG, "Cannot start Ollama stream while the previous task remains owned.")
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end

	_stream_generation = _stream_generation + 1
	local my_generation = _stream_generation

	_req_counter = _req_counter + 1
	local req_id = _req_counter

	local messages, line_mode, user_prompt = build_request_context(
		system_prompt, full_text, tail_text, num_predictions, is_batch)

	local t0_req = TimerScheduler.now()
	Logger.debug(LOG, "[%s] #%d STREAM_PROMPT (%d chars) -> %s",
		model_name, req_id, #user_prompt, user_prompt:sub(1, 250))

	local payload = {
		model      = tostring(model_name),
		messages   = messages,
		stream     = true,
		think      = false,
		keep_alive = ApiCommon.OLLAMA_KEEP_ALIVE,
		options    = build_options(temperature, num_predict_tokens, model_name, is_batch, line_mode),
	}

	local encoded, enc_err = JsonCodec.encode(payload)
	if not encoded then
		Logger.error(LOG, "Failed to encode Ollama streaming payload — %s", tostring(enc_err))
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end

	-- Write payload to a temp file so curl reads it directly — avoids the
	-- stdin-pipe/streaming-callback conflict in hs.task.
	-- os.tmpname() creates an empty file at the base path; remove it immediately
	-- so only the suffixed path (which we own) exists in /tmp.
	-- Declared BEFORE on_done so the closure captures the real `tmp_path` upvalue
	-- (Lua lexical scoping: a local declared after the closure resolves to the
	-- nil global, making os.remove(tmp_path) throw and abort the whole callback).
	local _tmp_base = os.tmpname()
	local tmp_path = _tmp_base .. "_ollama_stream.json"
	os.remove(_tmp_base)
	local fh = io.open(tmp_path, "w")
	if not fh then
		Logger.error(LOG, "Failed to open temp file '%s' for Ollama streaming payload.", tmp_path)
		if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end
		return
	end
	fh:write(encoded)
	fh:close()

	local accumulated = ""
	local line_buf    = ""
	local task = nil
	local task_completed = false

	-- Parse one complete NDJSON line and append its content to accumulated
	local function process_line(line)
		local obj, _ = JsonCodec.decode(line)
		if type(obj) ~= "table" then return end
		if type(obj.message) == "table" and type(obj.message.content) == "string" then
			local token = obj.message.content
			if token ~= "" then
				accumulated = accumulated .. token
				if type(on_partial) == "function" then ApiCommon.protected_call(on_partial, "on_partial", accumulated) end
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
		task_completed = true
		-- Relinquish the exact native capability before any parser/file/logger call
		-- can raise. A callback throw must never leave a completed task published.
		if my_generation == _stream_generation and _active_stream_task == task then
			_active_stream_task = nil
		end
		-- Remove the payload temp file as soon as curl exits so it doesn't linger
		-- for the full STREAM_TMPFILE_CLEANUP_SEC fallback window.
		os.remove(tmp_path)
		-- Generation check: a newer request superseded this stream — don't touch
		-- shared state (otherwise we untrack the active stream and leak its task)
		if my_generation ~= _stream_generation then
			Logger.debug(LOG, "[%s] #%d STREAM: superseded — discarding on_done.", model_name, req_id)
			return
		end
		if remaining and remaining ~= "" then
			line_buf = line_buf .. remaining
			flush_lines()
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
				backend       = "ollama",
				model         = tostring(model_name),
				system_prompt = system_prompt,
				user_prompt   = user_prompt,
			})
		end
		if type(on_success) == "function" then ApiCommon.protected_call(on_success, "on_success", results) end
	end

	local spawn_ok, spawned = xpcall(function()
		return ShellRunner.spawn("/usr/bin/curl", {
			"-s", "-N", "-X", "POST",
			"-H", "Content-Type: application/json",
			"--connect-timeout", "5",   -- abort if TCP handshake exceeds 5 s (Ollama dead)
			"--max-time", tostring(STREAM_MAX_TIME_SEC),  -- hard ceiling; also drives cleanup delay
			"--data-binary", "@" .. tmp_path,
			M.get_base_url() .. "/api/chat",
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
	-- Publish before start(): a very short task may complete synchronously from a
	-- test/native shim, and on_done must be able to revoke the exact capability.
	_active_stream_task = task
	local start_ok, start_result = xpcall(function() return task.start() end, debug.traceback)
	if not start_ok or start_result ~= true then
		if not start_ok then
			local stop_ok, stop_result = xpcall(function() return task.terminate() end, debug.traceback)
			if stop_ok and stop_result == true then
				if _active_stream_task == task then _active_stream_task = nil end
			else
				Logger.error(LOG, "[%s] #%d STREAM ambiguous task retained for cancellation retry: %s",
					tostring(model_name), req_id, tostring(stop_result))
			end
		elseif _active_stream_task == task then
			-- ShellRunner's false result proves hs.task never launched.
			_active_stream_task = nil
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
	Logger.debug(LOG, "[%s] #%d STREAM task started (payload: %s).", model_name, req_id, tmp_path)

	-- Safety-net: remove the payload temp file even if on_done fires late or not
	-- at all. Delay must be > STREAM_MAX_TIME_SEC so curl has finished reading.
	local cleanup_ok, cleanup_handle, cleanup_committed = xpcall(function()
		return TimerScheduler.after(STREAM_TMPFILE_CLEANUP_SEC, function()
			os.remove(tmp_path)
		end)
	end, debug.traceback)
	if not cleanup_ok or cleanup_committed ~= true then
		Logger.error(LOG, "[%s] #%d STREAM payload cleanup timer did not commit (result: %s).",
			tostring(model_name), req_id, tostring(cleanup_handle))
	end
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

	local effective_temp = tonumber(temperature) or ApiCommon.DEFAULT_TEMPERATURE
	local system_prompt  = Profiles.resolve_system_prompt(profile, num_predictions)
	local tokens         = tonumber(max_predict) * num_predictions + (num_predictions * 5)
	local is_batch       = profile.batch
	local dedup_stats    = ApiCommon.new_dedup_stats()
	local post_fn        = streaming and post_and_parse_streaming or post_and_parse

	local t0 = TimerScheduler.now()
	post_fn(model_name, system_prompt, full_text, tail_text,
		effective_temp, tokens, num_predictions, is_batch,
		function(results)
			local ms = math.floor((TimerScheduler.now() - t0) * 1000)
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
					if type(on_success) == "function" then ApiCommon.protected_call(on_success, "on_success", subset, ms, is_final, not is_final) end
					if not is_final then TimerScheduler.after(0, function() reveal_next(idx + 1) end) end
				end
				reveal_next(1)
			else
				if type(on_success) == "function" then ApiCommon.protected_call(on_success, "on_success", results, ms, true) end
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
	local t0            = TimerScheduler.now()
	local results       = {}
	local base_temp     = tonumber(temperature) or ApiCommon.DEFAULT_TEMPERATURE
	local requested_predictions = math.max(1, math.floor(tonumber(num_predictions) or 1))
	local max_attempts = requested_predictions
	if RETRY_FAILED_PREDICTION_ENABLED == true then
		max_attempts = math.max(requested_predictions, requested_predictions * math.max(1, math.floor(tonumber(RETRY_FAILED_PREDICTION_MAX_MULTIPLIER))))
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
			if #results == 0 then if type(on_fail) == "function" then ApiCommon.protected_call(on_fail, "on_fail") end return end
			ApiCommon.log_prediction_summary(Logger, LOG, "sequential", requested_predictions, dedup_stats, #results)
			local ms = math.floor((TimerScheduler.now() - t0) * 1000)
			if type(on_success) == "function" then ApiCommon.protected_call(on_success, "on_success", results, ms, true) end
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
							local ms = math.floor((TimerScheduler.now() - t0) * 1000)
							if type(on_success) == "function" then ApiCommon.protected_call(on_success, "on_success", results, ms, false) end
						end
					end
					do_next()
				end,
				function()
					if attempt < 2 then
						local retry_tokens = tokens + _RETRY_EXTRA_TOKENS
						local retry_temp   = math.min(1.30, (tonumber(temp) or ApiCommon.DEFAULT_TEMPERATURE) + _RETRY_TEMP_STEP)
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
