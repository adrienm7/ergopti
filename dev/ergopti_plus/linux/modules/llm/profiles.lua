--- modules/llm/profiles.lua

--- ==============================================================================
--- MODULE: LLM Profiles (Linux)
--- DESCRIPTION:
--- Manages LLM model profiles for the Linux driver. Loads built-in model
--- definitions, queries the running Ollama instance for available models,
--- and exposes the currently selected model to the prediction engine.
--- Ported from the macOS profiles.lua module — single source of truth for
--- profile data is _shared/lua/llm/profile_selector.lua.
---
--- FEATURES & RATIONALE:
--- 1. Single source: delegates profile resolution to shared profile_selector
---    so all three drivers (macOS, Windows, Linux) use the same model list.
--- 2. Ollama-only backend: Linux targets Ollama exclusively (no MLX, no
---    remote API). Models are fetched from the local Ollama instance.
--- 3. Lazy loading: profile data is loaded on first access, not at import
---    time, so the daemon starts even when Ollama is not running.
--- 4. Current model state: get_current_model() returns the user-selected
---    model; set_model() updates it and persists to a config file.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local LOG = "modules.llm.profiles"

-- Optional dependencies (may fail if modules not available).
local Selector = nil
local ok_sel, sel_mod = pcall(require, "llm.profile_selector")
if ok_sel then Selector = sel_mod end

local HttpBridge = nil
local ok_bridge, bridge_mod = pcall(require, "infra.llm_bridge")
if ok_bridge then HttpBridge = bridge_mod end


-- =========================================
-- =========================================
-- ======= 1/ State ========================
-- =========================================
-- =========================================

-- Currently selected model name.
local _current_model = nil

-- Whether the LLM feature is enabled.
local _enabled = false

-- Cached list of available models from Ollama.
local _available_models = {}

-- Base URL for Ollama (default port 11434).
local _base_url = nil

--- Persists one profile value before its in-memory counterpart is published.
--- @param key string
--- @param value any
--- @return boolean
local function persist(key, value)
	local ok, storage = pcall(require, "adapters.storage")
	if not ok or not storage or type(storage.set) ~= "function" then
		Logger.error(LOG, "No storage adapter — '%s' was not changed.", key)
		return false
	end
	if not storage.set(key, value) then
		Logger.error(LOG, "Could not persist '%s' — the active value was not changed.", key)
		return false
	end
	return true
end


-- =========================================
-- =========================================
-- ======= 2/ Initialisation ===============
-- =========================================
-- =========================================

--- Initialises the profile state, loading persisted settings from storage.
--- @param opts table { port?, model? }
---              port  number  Ollama port (default 11434).
---              model string  Override default model.
function M.init(opts)
	local options = type(opts) == "table" and opts or {}
	-- The bridge owns both the canonical origin and operation paths. A profile
	-- stores only the origin; callers ask the bridge for /api/tags or /api/chat.
	local default_port = HttpBridge and HttpBridge.OLLAMA_DEFAULT_PORT or nil
	local default_host = HttpBridge and HttpBridge.OLLAMA_DEFAULT_HOST or nil
	local port = type(options.port) == "number" and options.port or default_port
	_base_url = HttpBridge and HttpBridge.resolve_base_url(port, default_host) or nil

	-- Load persisted model and enabled state from storage.
	local ok_st, storage = pcall(require, "adapters.storage")
	if ok_st and storage then
		_current_model = type(options.model) == "string" and options.model
			or storage.get("llm.model", nil)
		_enabled = storage.get("llm.enabled", false)
	else
		_current_model = type(options.model) == "string" and options.model or nil
		_enabled = false
	end

	Logger.info(LOG, "LLM profiles initialised (base_url=%s, model=%s, enabled=%s).",
		_base_url or "(unavailable)", _current_model or "(auto-detect)", tostring(_enabled))
end


-- =========================================
-- =========================================
-- ======= 3/ Model Management =============
-- =========================================
-- =========================================

--- Fetches the list of available models from the Ollama API.
--- Returns cached value if already fetched; call refresh_models() to force refresh.
--- @return table Array of model name strings.
function M.get_models()
	if #_available_models > 0 then return _available_models end

	-- Try to fetch from Ollama.
	M.refresh_models()
	return _available_models
end

--- Refreshes the model list from the Ollama /api/tags endpoint.
--- @return table Array of model name strings (may be empty if Ollama unreachable).
function M.refresh_models()
	_available_models = {}

	if not _base_url or not HttpBridge then
		Logger.warn(LOG, "refresh_models(): no HTTP bridge or base URL — cannot fetch models.")
		return {}
	end

	local url = HttpBridge.ollama_endpoint(_base_url, "tags")
	if not url then
		Logger.error(LOG, "refresh_models(): invalid Ollama origin — cannot build the tags endpoint.")
		return {}
	end
	local ok, result = pcall(function()
		-- Use the http_client adapter when available; fall back to direct curl.
		local raw = nil
		local ok_http, http_client = pcall(require, "adapters.http_client")
		if ok_http and http_client and http_client.get then
			-- http_client doesn't have a simple GET — use direct curl for now.
			-- TODO: add M.get() to http_client adapter.
		end
		local pipe = io.popen(string.format(
			"curl -s --max-time 5 '%s' 2>/dev/null", url:gsub("'", "'\\''")))
		if not pipe then return {} end
		raw = pipe:read("*a")
		pipe:close()

		-- Parse JSON response: { "models": [ { "name": "llama3:latest" }, ... ] }
		if not raw or raw == "" then return {} end
		local models = {}
		for name in raw:gmatch('"name"%s*:%s*"([^"]+)"') do
			models[#models + 1] = name
		end
		return models
	end)

	if not ok then
		Logger.warn(LOG, "refresh_models(): HTTP error — %s", tostring(result))
		return {}
	end

	_available_models = result or {}
	Logger.info(LOG, "Fetched %d model(s) from Ollama.", #_available_models)

	-- Auto-select first available model if none is set.
	if not _current_model and #_available_models > 0 then
		_current_model = _available_models[1]
	end

	return _available_models
end

--- Returns the currently selected model name.
--- @return string|nil
function M.get_current_model()
	if not _current_model then
		M.refresh_models()
	end
	return _current_model
end

---- Sets the current model and persists the choice.
--- @param model_name string Model name as reported by Ollama.
--- @return boolean
function M.set_model(model_name)
	if type(model_name) ~= "string" or model_name == "" then return false end
	if not persist("llm.model", model_name) then return false end
	_current_model = model_name
	Logger.info(LOG, "Model set to: %s", model_name)
	return true
end


-- =========================================
-- =========================================
-- ======= 4/ State ========================
-- =========================================
-- =========================================

--- Returns whether the LLM feature is enabled.
--- @return boolean
function M.is_enabled()
	return _enabled
end

--- Enables the LLM feature and persists.
function M.enable()
	if not persist("llm.enabled", true) then return false end
	_enabled = true
	Logger.info(LOG, "LLM enabled.")
	return true
end

--- Disables the LLM feature and persists.
function M.disable()
	if not persist("llm.enabled", false) then return false end
	_enabled = false
	Logger.info(LOG, "LLM disabled.")
	return true
end

--- Toggles the LLM feature on/off and persists.
function M.toggle()
	if _enabled then return M.disable() end
	return M.enable()
end

--- Returns the Ollama base URL (e.g. "http://localhost:11434").
--- @return string|nil
function M.get_base_url()
	return _base_url
end

return M
