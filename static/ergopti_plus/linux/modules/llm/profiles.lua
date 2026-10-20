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

-- The cooperative constructor captures one engine owner, not a later compatible export.
local ResponseEngine = require("modules.llm.prediction_engine")
local ResponseCapture, ResponseCurrent = ResponseEngine.capture_runtime_response, ResponseEngine.runtime_response_current
assert(type(ResponseCapture) == "function" and type(ResponseCurrent) == "function",
	"original runtime response owner unavailable")

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

-- One initialized inventory retains its exact deferred and HTTP cleanup debt.
local _inventory = nil
local _initializing = false

-- Base URL for Ollama (default port 11434).
local _base_url = nil

--- Persists one profile value before its in-memory counterpart is published.
--- @param key string
--- @param value any
--- @param expected_source table|nil Captured exact preference source.
--- @param admission function|nil Captured final writer admission.
--- @return boolean
local function persist(key, value, expected_source, admission)
	local ok, storage = pcall(require, "infra.llm_preferences")
	if not ok or not storage or type(storage.set) ~= "function" then
		Logger.error(LOG, "No storage adapter — '%s' was not changed.", key)
		return false
	end
	local committed = expected_source and storage.set_many({ [key] = value }, expected_source, admission)
		or (expected_source == nil and admission == nil and storage.set(key, value))
	if committed ~= true then
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
	if _initializing then return false end
	_initializing = true
	local origin, model, enabled, inventory
	-- Constructor failures must release reentry admission without publishing a
	-- partial replacement or acknowledging the previous inventory's native debt.
	local ok, initialized = pcall(function()
		if _inventory and _inventory.cancel() ~= true then return false end
		local options = type(opts) == "table" and opts or {}
		-- The bridge owns both the canonical origin and operation paths. A profile
		-- stores only the origin; callers ask the bridge for /api/tags or /api/chat.
		local default_port = HttpBridge and HttpBridge.OLLAMA_DEFAULT_PORT or nil
		local default_host = HttpBridge and HttpBridge.OLLAMA_DEFAULT_HOST or nil
		local port = type(options.port) == "number" and options.port or default_port
		origin = HttpBridge and HttpBridge.resolve_base_url(port, default_host) or nil

		local values = require("infra.llm_preferences").get_many({ "llm.models.ollama", "llm.enabled" })
		model, enabled = options.model ~= nil and options.model or values["llm.models.ollama"], values["llm.enabled"]
		assert(type(model) == "string" and model ~= "", "the configured Ollama model must be nonempty")
		assert(type(enabled) == "boolean", "AI consent must be boolean")
		inventory = require("modules.llm.model_inventory").new({
			engine = ResponseEngine, capture = ResponseCapture, current = ResponseCurrent, origin = origin,
			retained = function()
				return package.loaded["modules.llm.profiles"] == M and _inventory == inventory and _base_url == origin
			end,
			changed = type(options.on_models_changed) == "function" and options.on_models_changed or nil,
		})
		return true
	end)
	_initializing = false
	if not ok then error(initialized, 0) end
	if not initialized then return false end
	_base_url, _current_model, _enabled, _inventory = origin, model, enabled, inventory

	Logger.info(LOG, "LLM profiles initialised (base_url=%s, model=%s, enabled=%s).",
		_base_url or "(unavailable)", _current_model or "(auto-detect)", tostring(_enabled))
	return true
end


-- =========================================
-- =========================================
-- ======= 3/ Model Management =============
-- =========================================
-- =========================================


--- Projects the cache immediately, reserving one deferred cold acquisition.
--- @return table Array of model name strings.
function M.get_models()
	return _inventory and _inventory.get() or {}
end

--- Projects only the validated cache without scheduling HTTP.
--- @return table Array of model name strings.
function M.get_cached_models()
	return _inventory and _inventory.peek() or {}
end

--- Requests a deferred refresh, coalescing with retained work.
--- @return table Immediate array projection.
function M.refresh_models()
	return _inventory and _inventory.refresh() or {}
end

--- Requests an inventory observation that begins after a successful model install.
--- @return table Immediate array projection.
function M.refresh_models_after_mutation()
	return _inventory and _inventory.refresh_after_mutation() or {}
end

--- Revokes inventory publication and waits for its exact native resources.
--- @return boolean acknowledged Physical deferred and HTTP settlement.
function M.cancel_model_inventory()
	return not _inventory or _inventory.cancel()
end

--- Reports inventory construction or retained cleanup debt.
--- @return boolean pending
function M.model_inventory_pending()
	return _inventory ~= nil and _inventory.pending()
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
--- @param expected_source table|nil Exact preference image used for guarded selection.
--- @param admission function|nil Pure final native writer admission.
--- @return boolean
function M.set_model(model_name, expected_source, admission)
	if type(model_name) ~= "string" or model_name == "" then return false end
	if not persist("llm.models.ollama", model_name, expected_source, admission) then return false end
	if admission and admission() ~= true then return false end
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

--- Enables the LLM feature only after its existing writer acknowledges.
--- @param expected_source table|nil Exact source used by an enable admission.
--- @param admission function|nil Captured final writer admission.
--- @return boolean
function M.enable(expected_source, admission)
	if not persist("llm.enabled", true, expected_source, admission) then return false end
	_enabled = true
	Logger.info(LOG, "LLM enabled.")
	return true
end

--- Disables the LLM feature after its existing writer acknowledges.
--- @param expected_source table|nil Exact source used for conditional compensation.
--- @param admission function|nil Captured final writer admission.
--- @return boolean acknowledged
function M.disable(expected_source, admission)
	if not persist("llm.enabled", false, expected_source, admission) then return false end
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

--- Marks the exact model and consent consumed by the canonical owner.
--- @param document table Parsed canonical configuration.
--- @param mark function Consumed-key collector.
function M.mark_config_reads(document, mark)
	local preferences = require("infra.llm_preferences")
	preferences.mark_config_read(document, "llm.models.ollama", mark)
	preferences.mark_config_read(document, "llm.enabled", mark)
end

--- Captures dormant model identity and the existing consent gate.
--- @return table snapshot
function M.configuration_snapshot() return { model = _current_model, enabled = _enabled } end

--- Restores or publishes model identity without starting downloads or inference.
--- @param snapshot table Owner-issued desired state.
--- @return boolean applied
function M.restore_configuration(snapshot)
	if type(snapshot.enabled) ~= "boolean" then return false end
	_current_model, _enabled = snapshot.model, snapshot.enabled
	return true
end

--- Reads the detached canonical candidate without changing available models.
--- @return boolean applied
function M.reload_configuration()
	local values = require("infra.llm_preferences").get_many({ "llm.models.ollama", "llm.enabled" })
	if type(values["llm.models.ollama"]) ~= "string" or values["llm.models.ollama"] == "" then return false end
	return M.restore_configuration({ model = values["llm.models.ollama"], enabled = values["llm.enabled"] })
end

return M
