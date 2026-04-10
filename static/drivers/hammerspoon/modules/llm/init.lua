--- modules/llm/init.lua

--- ==============================================================================
--- MODULE: LLM Prediction Engine Core
--- DESCRIPTION:
--- Coordinates communication with the local Ollama/MLX API through decoupled API, 
--- Profiles, and Parsing engines.
--- ==============================================================================

local M = {}

local hs = hs
local Profiles  = require("modules.llm.profiles")
local ApiOllama = require("modules.llm.api_ollama")
local ApiMlx    = require("modules.llm.api_mlx")

M.BUILTIN_PROFILES = Profiles.BUILTIN_PROFILES





-- =======================================
-- =======================================
-- ======= 1/ Constants & Defaults =======
-- =======================================
-- =======================================

M.DEFAULT_STATE = {
    llm_enabled           = false,
    llm_use_mlx           = false,
    llm_model_ollama      = "gemma-4-E2B-it",
    llm_model_mlx         = "gemma-4-E2B-it",
    llm_debounce          = 0.2,
    llm_num_predictions   = 3,
    llm_sequential_mode   = false,
    llm_context_length    = 500,
    llm_temperature       = 0.1,
    llm_max_words         = 5,
    llm_arrow_nav_enabled = false,
    llm_nav_modifiers     = {},
    llm_show_info_bar     = false,
    llm_val_modifiers     = {"alt"},
    llm_pred_indent       = -3,
    llm_active_profile    = "basic",
}

local CoreState = {
    active_profile_id = M.DEFAULT_STATE.llm_active_profile,
    user_profiles     = {},
    use_mlx           = M.DEFAULT_STATE.llm_use_mlx,
    last_backend_check = 0,
    backend_check_interval = 10,  -- Re-check backend every 10s
}





-- =======================================
-- =======================================
-- ======= 2/ Core Orchestration =========
-- =======================================
-- =======================================

--- Auto-detect best available backend (Ollama or MLX) and set it as active.
--- Uses async HTTP checks — never blocks the main thread.
--- @param callback function|nil Optional callback(backend_name) called when detection completes.
function M.auto_detect_backend(callback)
    local now = hs.timer.secondsSinceEpoch()

    -- Return cached result immediately if checked recently (within 10s)
    if now - CoreState.last_backend_check < CoreState.backend_check_interval then
        local result = CoreState.use_mlx and "mlx" or "ollama"
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
            CoreState.use_mlx = false
        elseif mlx_ok then
            CoreState.use_mlx = true
        else
            CoreState.use_mlx = false
        end
        local result = CoreState.use_mlx and "mlx" or "ollama"
        if type(callback) == "function" then pcall(callback, result) end
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

--- Pre-warms API connections to reduce first-request latency (async, non-blocking).
function M.warm_up_connections()
    pcall(function()
        -- Parallel async pings to both backends (fire-and-forget)
        hs.http.asyncGet("http://127.0.0.1:11434/api/version", {}, function() end)
        hs.http.asyncGet("http://127.0.0.1:8080/v1/models", {}, function() end)
    end)
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

--- Updates the active profile ID and logic state.
--- @param id string The ID of the profile to activate.
function M.set_active_profile(id)
    if type(id) == "string" then
        CoreState.active_profile_id = id
    end
end

--- Sets whether to route queries to MLX or Ollama
function M.set_use_mlx(enabled)
    CoreState.use_mlx = enabled == true
end

--- Returns whether MLX is currently enabled as inference backend.
--- @return boolean True when MLX backend is active.
function M.is_using_mlx()
    return CoreState.use_mlx == true
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
--- @param is_mlx boolean True for MLX backend, false for Ollama.
--- @return string The backend-specific identifier, or label unchanged if not found.
local function resolve_model_for_backend(label, is_mlx)
	if type(label) ~= "string" or label == "" then return label end
	local entry = get_model_index()[label]
	if not entry then return label end
	return (is_mlx and entry.mlx or entry.ollama) or label
end

--- Resolves the current model name based on active backend.
--- @return string The model name for the active backend (Ollama or MLX).
function M.get_current_model()
	local label = CoreState.use_mlx and CoreState.llm_model_mlx or CoreState.llm_model_ollama
	return resolve_model_for_backend(label, CoreState.use_mlx)
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
function M.set_user_profiles(profiles_table)
    if type(profiles_table) == "table" then
        CoreState.user_profiles = profiles_table
    end
end

--- Returns the active API engine
local function get_api()
    return CoreState.use_mlx and ApiMlx or ApiOllama
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
function M.fetch_llm_prediction(full_text, tail_text, model_name, temperature,
                                  max_predict, num_predictions, on_success, on_fail, sequential_mode, force, request_id_provider)

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
            api.fetch_parallel(full_text, tail_text, model_name, temperature, max_predict, num_predictions, profile, on_success, on_fail, request_id_provider)
        else
            api.fetch_sequential(full_text, tail_text, model_name, temperature, max_predict, num_predictions, profile, on_success, on_fail, request_id_provider)
        end
    else
        api.fetch_batch(full_text, tail_text, model_name, temperature, max_predict, num_predictions, profile, on_success, on_fail, request_id_provider)
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
