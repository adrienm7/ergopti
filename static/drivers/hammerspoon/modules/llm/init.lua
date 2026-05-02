--- modules/llm/init.lua

--- ==============================================================================
--- MODULE: LLM Prediction Engine Core
--- DESCRIPTION:
--- Coordinates communication with the local Ollama/MLX API through decoupled API, 
--- Profiles, and Parsing engines.
--- ==============================================================================

local M = {}

local hs        = hs
local Profiles  = require("modules.llm.profiles")
local ApiOllama = require("modules.llm.api_ollama")
local ApiMlx    = require("modules.llm.api_mlx")
local Logger    = require("lib.logger")

local LOG = "llm.core"

M.BUILTIN_PROFILES = Profiles.BUILTIN_PROFILES





-- =======================================
-- =======================================
-- ======= 1/ Constants & Defaults =======
-- =======================================
-- =======================================

M.DEFAULT_STATE = {
	llm_enabled           = false,
	llm_backend           = "ollama",
	llm_model_ollama      = "gemma-4-E2B-it",
	llm_model_mlx         = "Qwen3.5-2B",
	llm_debounce          = 0.2,
	llm_num_predictions   = 3,
	llm_sequential_mode   = false,
	llm_context_length    = 500,
	llm_temperature       = 0.1,
	llm_min_words         = 5,
	llm_max_words         = 20,
	llm_arrow_nav_enabled = false,
	llm_nav_modifiers     = {},
	llm_show_info_bar     = true,
	llm_val_modifiers     = {"alt"},
	llm_pred_indent       = -3,
	llm_active_profile    = "basic",
	-- Bridge behavioral flags (read by llm_bridge, overridden by menu_llm at startup)
	llm_reset_on_nav      = true,
	llm_after_hotstring   = true,
	llm_auto_raise_temp   = true,  -- Incrementally raise temperature for each extra prediction
	llm_streaming             = true,  -- Token-by-token streaming
	llm_streaming_multi       = true,  -- Show predictions as they arrive when num_predictions > 1 (otherwise wait for all to complete before showing any)
	llm_instant_on_word_end   = true,  -- Fire the LLM immediately when the buffer ends with whitespace (word just completed)
}

-- Single source of truth for the streaming flag; backends receive it as a parameter
-- on each fetch call so they hold no state of their own for this flag
local _streaming_enabled = M.DEFAULT_STATE.llm_streaming

local CoreState = {
	active_profile_id      = M.DEFAULT_STATE.llm_active_profile,
	user_profiles          = {},
	backend                = M.DEFAULT_STATE.llm_backend,
	last_backend_check     = 0,
	backend_check_interval = 10,
}





-- =====================================
-- =====================================
-- ======= 2/ Core Orchestration =======
-- =====================================
-- =====================================

--- Auto-detect best available backend and set it as active.
--- Uses async HTTP checks — never blocks the main thread.
--- @param callback function|nil Optional callback(backend_name) called when detection completes.
function M.auto_detect_backend(callback)
	local now = hs.timer.secondsSinceEpoch()

	-- Return cached result immediately if checked recently (within 10s)
	if now - CoreState.last_backend_check < CoreState.backend_check_interval then
		local result = CoreState.backend
		if type(callback) == "function" then pcall(callback, result) end
		return result
	end

	CoreState.last_backend_check = now

	-- Async parallel health checks — both fire at once, state resolved in callbacks
	local ollama_done, mlx_done = false, false
	local ollama_ok, mlx_ok = false, false

	local function on_both_done()
		if not (ollama_done and mlx_done) then return end
		-- Prefer Ollama if both available, otherwise use MLX if available
		if ollama_ok then
			CoreState.backend = "ollama"
		elseif mlx_ok then
			CoreState.backend = "mlx"
		else
			CoreState.backend = "inconnu"
		end
		
		if type(callback) == "function" then pcall(callback, CoreState.backend) end
	end

	pcall(hs.http.asyncGet, "http://127.0.0.1:11434/api/version", {}, function(status, body)
		ollama_ok = (status == 200) and type(body) == "string" and body:find('"version"') ~= nil
		ollama_done = true
		on_both_done()
	end)

	pcall(hs.http.asyncGet, "http://127.0.0.1:8080/v1/models", {}, function(status, body)
		mlx_ok = (status == 200) and type(body) == "string" and body:find('"object"') ~= nil
		mlx_done = true
		on_both_done()
	end)
end

--- Pre-warms TCP connections to both backends (async, non-blocking).
--- This establishes the loopback socket but does NOT load the model into GPU memory.
--- Call warmup_model() separately once the model name is known.
function M.warm_up_connections()
	pcall(function()
		-- Parallel async pings to both backends (fire-and-forget)
		hs.http.asyncGet("http://127.0.0.1:11434/api/version", {}, function() end)
		hs.http.asyncGet("http://127.0.0.1:8080/v1/models",   {}, function() end)
	end)
end

--- Returns the active API engine based on the current backend state.
--- Defined here (early in the file) because warmup_model and cancel_streaming
--- need to reference it; Lua locals are only visible after their declaration,
--- so placing this later silently turns get_api into a nil global lookup that
--- fails the first time it is called.
--- @return table The specific backend module object.
local function get_api()
	if CoreState.backend == "mlx" then
		return ApiMlx
	end
	return ApiOllama
end

--- Primes the backend model and its KV cache with the active profile's system prompt.
--- Must be called after both model and profile are configured; runs async so it does
--- not block the caller.
--- @param model_name string The backend-specific model identifier.
--- @param profile table|nil The active profile object; omit to use a minimal ping.
function M.warmup_model(model_name, profile)
	if type(model_name) ~= "string" or model_name == "" then
		Logger.debug(LOG, "warmup_model: skipped — model_name is empty.")
		return
	end
	local resolved_profile = profile or M.get_active_profile()
	Logger.debug(LOG, "warmup_model: dispatching to backend '%s' for model '%s'.",
		tostring(CoreState.backend), tostring(model_name))
	local ok, err = pcall(function() get_api().warmup(model_name, resolved_profile) end)
	if not ok then
		Logger.warn(LOG, "warmup_model: backend warmup raised: %s", tostring(err))
	end
end

--- Returns true when the active backend has confirmed it can answer inference
--- requests (model loaded, server responsive). The prediction engine uses this
--- to gate the loading tooltip and request dispatch — without it, the spinner
--- shows even while the MLX server is still loading model weights and would
--- never produce a prediction in time.
--- @return boolean
function M.is_backend_ready()
	local api = get_api()
	if type(api.is_ready) ~= "function" then return true end
	return api.is_ready() == true
end

-- Defer backend detection entirely off the synchronous init path
hs.timer.doAfter(0, function()
	pcall(function() M.auto_detect_backend() end)
	pcall(function() M.warm_up_connections() end)
end)

--- Retrieves the currently active profile object.
--- @return table The active profile object.
function M.get_active_profile()
	return Profiles.get_active_profile(CoreState.active_profile_id, CoreState.user_profiles)
end

--- Updates the active profile ID and re-primes the KV cache for the new profile's
--- system prompt so the first request after a profile switch benefits from the cache.
--- @param id string The ID of the profile to activate.
function M.set_active_profile(id)
	if type(id) ~= "string" then return end
	CoreState.active_profile_id = id
	-- Re-prime the KV cache: the new profile may have a different static prompt prefix
	local model = M.get_current_model()
	if type(model) == "string" and model ~= "" then
		local new_profile = M.get_active_profile()
		hs.timer.doAfter(0, function() pcall(M.warmup_model, model, new_profile) end)
	end
end

--- Enables or disables token-by-token streaming.
--- The flag is stored here and passed to backends at dispatch time — no backend state.
--- @param v boolean True to enable streaming, false to disable.
function M.set_llm_streaming(v)
	_streaming_enabled = (v == true)
	Logger.debug(LOG, "Streaming: %s.", _streaming_enabled and "on" or "off")
end

--- Cancels the in-flight streaming task on the active backend, if any.
--- Called when a new request supersedes the current stream.
function M.cancel_streaming()
	pcall(function() get_api().cancel_streaming() end)
end

--- Sets the active LLM backend identifier.
--- @param backend string The backend identifier (e.g., "mlx", "ollama").
function M.set_backend(backend)
	if type(backend) == "string" and backend ~= "" then
		CoreState.backend = backend
	end
end

--- Returns the currently active LLM backend identifier.
--- @return string The backend identifier.
function M.get_backend()
	return CoreState.backend or "inconnu"
end

-- Flat index: { [label] = { ollama = "...", mlx = "..." } } — built once from JSON
local _model_index = nil

--- Builds and caches a flat O(1) lookup index from llm_models.json.
--- @return table The index keyed by model label.
local function get_model_index()
	if _model_index then return _model_index end
	local candidates = {
		hs.configdir .. "/data/llm_models.json",
		hs.configdir .. "/../hammerspoon/data/llm_models.json",
	}
	local presets = {}
	for _, path in ipairs(candidates) do
		local ok, fh = pcall(io.open, path, "r")
		if ok and fh then
			local raw = fh:read("*a")
			pcall(function() fh:close() end)
			local dec_ok, data = pcall(hs.json.decode, raw)
			if dec_ok and type(data) == "table" then presets = data; break end
		end
	end
	-- Flatten all models into a single index keyed by label
	local index = {}
	for _, provider in ipairs(presets) do
		for _, family in ipairs(provider.families or {}) do
			for _, m in ipairs(family.models or {}) do
				if type(m) == "table" and type(m.name) == "string" then
					local ollama_url = m.urls and m.urls.ollama or ""
					local mlx_url    = m.urls and m.urls.mlx    or ""
					index[m.name] = {
						ollama = (ollama_url ~= "" and ollama_url:match("/([^/]+)$")) or nil,
						mlx    = (mlx_url    ~= "" and mlx_url:match("/([^/]+)$"))    or nil,
					}
				end
			end
		end
	end
	_model_index = index
	return index
end

--- Translates a JSON model label to the backend-specific identifier in O(1).
--- e.g., "gemma-4-E2B-it" -> "gemma4:e2b" (Ollama) or "gemma-4-e2b-it-mxfp4" (MLX)
--- @param label string The model label ("name" field from llm_models.json).
--- @param backend string The target backend identifier.
--- @return string The backend-specific identifier, or label unchanged if not found.
local function resolve_model_for_backend(label, backend)
	if type(label) ~= "string" or label == "" then return label end
	local entry = get_model_index()[label]
	if not entry then return label end
	return (entry[backend]) or label
end

--- Resolves the current model name based on the active backend.
--- @return string The model name for the active backend.
function M.get_current_model()
	local label = (CoreState.backend == "mlx") and CoreState.llm_model_mlx or CoreState.llm_model_ollama
	return resolve_model_for_backend(label, CoreState.backend)
end

--- Sets the model for Ollama backend.
--- @param model_name string The model identifier for Ollama.
function M.set_llm_model_ollama(model_name)
	if type(model_name) == "string" then
		CoreState.llm_model_ollama = model_name
	end
end

--- Sets the model for MLX backend.
--- @param model_name string The model identifier for MLX.
function M.set_llm_model_mlx(model_name)
	if type(model_name) == "string" then
		CoreState.llm_model_mlx = model_name
	end
end

--- Exposes built-in profiles and user profiles.
--- @return table An array containing all available profiles.
function M.get_all_profiles()
	return Profiles.get_all_profiles(CoreState.user_profiles)
end

--- Overrides user profiles globally.
--- @param profiles_table table The new user profile map.
function M.set_user_profiles(profiles_table)
	if type(profiles_table) == "table" then
		CoreState.user_profiles = profiles_table
	end
end

--- Initiates a new LLM prediction request, selecting the optimal fetch strategy based on profile state.
--- @param full_text string The complete tracked context string.
--- @param tail_text string The most recent segment of the context.
--- @param model_name string Name of the targeted local model.
--- @param temperature number Base sampling temperature.
--- @param max_predict number Maximum allowed output tokens.
--- @param num_predictions number Request quantity for prediction arrays.
--- @param on_success function Function to execute when successfully parsed payload returns.
--- @param on_fail function Function to execute on timeout, error, or empty output.
--- @param sequential_mode boolean Flag to enforce sequential API requests instead of parallel.
--- @param force boolean If true, bypasses application exclusions.
--- @param request_id_provider function Callback returning the current request identifier.
--- @param on_partial function|nil Optional token-by-token streaming callback.
function M.fetch_llm_prediction(full_text, tail_text, model_name, temperature,
                                  max_predict, num_predictions, on_success, on_fail, sequential_mode, force, request_id_provider, on_partial)

	-- Prevent firing requests if the active application is blacklisted by user settings
	if not force then
		local ok_front, front = pcall(hs.application.frontmostApplication)
		if ok_front and front then
			local disabled = hs.settings.get("llm_disabled_apps")
			if type(disabled) == "table" then
				local bid  = type(front.bundleID) == "function" and front:bundleID() or ""
				local path = type(front.path) == "function" and front:path() or ""
				for _, app in ipairs(disabled) do
					if type(app) == "table" and ((app.bundleID and app.bundleID == bid) or (app.appPath and app.appPath == path)) then
						Logger.info(LOG, "Prediction aborted due to application blacklist.")
						if type(on_fail) == "function" then pcall(on_fail) end
						return
					end
				end
			end
		end
	end

	num_predictions = math.max(1, math.floor(tonumber(num_predictions) or 1))
	local profile = M.get_active_profile()
	local api = get_api()

	if type(profile) == "table" and (not profile.batch) then
		if num_predictions > 1 and not sequential_mode then
			api.fetch_parallel(full_text, tail_text, model_name, temperature, max_predict, num_predictions, profile, on_success, on_fail, request_id_provider, _streaming_enabled, on_partial)
		else
			api.fetch_sequential(full_text, tail_text, model_name, temperature, max_predict, num_predictions, profile, on_success, on_fail, request_id_provider, _streaming_enabled, on_partial)
		end
	else
		api.fetch_batch(full_text, tail_text, model_name, temperature, max_predict, num_predictions, profile, on_success, on_fail, request_id_provider, _streaming_enabled, on_partial)
	end
end

--- Validates keystroke event modifiers against an expected explicit modifier set.
--- @param eventFlags table The flags object emitted by the keystroke event.
--- @param targetMods table A list of expected modifier keys (e.g., {"cmd", "shift"}).
--- @return boolean True if the flags exactly match the target criteria, false otherwise.
function M.check_modifiers(eventFlags, targetMods)
	if type(targetMods) ~= "table" then return false end
	if #targetMods == 1 and targetMods[1] == "none" then return false end
	
	local target_map = { cmd = false, alt = false, shift = false, ctrl = false }
	for _, mod in ipairs(targetMods) do if target_map[mod] ~= nil then target_map[mod] = true end end
	
	if (eventFlags.cmd or false)   ~= target_map.cmd   then return false end
	if (eventFlags.alt or false)   ~= target_map.alt   then return false end
	if (eventFlags.shift or false) ~= target_map.shift then return false end
	if (eventFlags.ctrl or false)  ~= target_map.ctrl  then return false end
	
	return true
end

-- Proxy Model Heuristics Methods
M.is_thinking_model  = ApiOllama.is_thinking_model
M.check_availability = function(...) get_api().check_availability(...) end

return M
