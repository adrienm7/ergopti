--- ui/onboarding/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Onboarding Wizard (first-run setup)
--- Handles JS→Lua messages from _shared/ui/onboarding/.
--- Bridge name: "hsOnboarding"
--- Persists user choices (layout, locale, LLM) to ~/.config/ergopti/config.toml
--- via the shared toml_codec.writer.batch_write().
--- ==============================================================================

local M = {}
M.bridge_name = "hsOnboarding"

local Logger = require("logger.shim")
local LOG = "bridge.onboarding"

-- Lazy-loaded writer for config.toml persistence.
local _writer = nil
local function _get_writer()
	if _writer then return _writer end
	local ok, mod = pcall(require, "toml_codec.writer")
	if ok and type(mod.batch_write) == "function" then _writer = mod end
	return _writer
end

-- Path to the daemon config file.
local function _config_path()
	local home = require("infra.config_paths").home()
	return home .. "/.config/ergopti/config.toml"
end

--- Resolves the active UI locale so the onboarding wizard opens in the user's
--- language instead of a hardcoded 'fr'. Falls back to 'fr' only if lib.i18n
--- truly fails to load or expose get_locale — a fail-safe default, not a silent
--- override of the persisted locale.
--- @return string Locale code (e.g. "de"), or "fr" on failure.
local function _resolve_locale()
	local ok, i18n = pcall(require, "infra.i18n")
	if ok and type(i18n) == "table" and type(i18n.get_locale) == "function" then
		local ok2, loc = pcall(i18n.get_locale)
		if ok2 and type(loc) == "string" and loc ~= "" then return loc end
	end
	return "fr"
end

-- Forward declarations.
local _handle_init, _handle_layout, _handle_language, _handle_llm_setup, _handle_complete

local function _handle_init(state)
	local layout = state.layout or "qwerty"
	local locale = _resolve_locale()
	return {
		current_layout = layout,
		current_locale = locale,
		llm_available = state.llm ~= nil,
	}
end

local function _handle_layout(data, _)
	Logger.info(LOG, "Onboarding layout selected: %s", tostring(data.layout))
	local writer = _get_writer()
	if writer and data.layout then
		local ok, err = writer.batch_write(_config_path(), {
			{ section = "script", key = "layout", value = data.layout },
		})
		if ok then
			Logger.success(LOG, "Layout persisted: %s", data.layout)
		else
			Logger.error(LOG, "Failed to persist layout: %s", tostring(err))
		end
	end
	return { accepted = true }
end

local function _handle_language(data, _)
	Logger.info(LOG, "Onboarding language selected: %s", tostring(data.locale))
	local writer = _get_writer()
	if writer and data.locale then
		local ok, err = writer.batch_write(_config_path(), {
			{ section = "script", key = "locale", value = data.locale },
		})
		if ok then
			Logger.success(LOG, "Locale persisted: %s", data.locale)
		else
			Logger.error(LOG, "Failed to persist locale: %s", tostring(err))
		end
	end
	return { accepted = true }
end

local function _handle_llm_setup(data, state)
	Logger.info(LOG, "Onboarding LLM setup: model=%s url=%s",
		tostring(data.model), tostring(data.url))
	if state.llm and data.model and type(state.llm.set_model) == "function" then
		pcall(state.llm.set_model, data.model)
	end
	-- Persist LLM settings.
	local writer = _get_writer()
	if writer then
		local updates = {}
		if data.model then
			updates[#updates + 1] = { section = "llm", key = "model", value = data.model }
		end
		if data.url then
			updates[#updates + 1] = { section = "llm", key = "ollama_url", value = data.url }
		end
		if #updates > 0 then
			local ok, err = writer.batch_write(_config_path(), updates)
			if ok then
				Logger.success(LOG, "LLM config persisted.")
			else
				Logger.error(LOG, "Failed to persist LLM config: %s", tostring(err))
			end
		end
	end
	return { accepted = true }
end

local function _handle_complete(data, _)
	Logger.success(LOG, "Onboarding complete — daemon ready.")
	local writer = _get_writer()
	if writer then
		local ok, err = writer.batch_write(_config_path(), {
			{ section = "script", key = "onboarding_done", value = true },
		})
		if ok then
			Logger.success(LOG, "Onboarding flag persisted.")
		else
			Logger.error(LOG, "Failed to persist onboarding flag: %s", tostring(err))
		end
	end
	return { done = true }
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state { engine, keylogger, config, llm, layout }.
--- @return any|nil  Response to send back to JS.
function M.on_message(payload, state)
	if type(payload) ~= "table" then
		local ok, data = pcall(function()
			local json_mod = require("json")
			return json_mod.decode(tostring(payload))
		end)
		if not ok or type(data) ~= "table" then return nil end
		payload = data
	end

	local step = payload.step
	local data = payload.data or {}

	if step == "init" then
		return _handle_init(state)
	elseif step == "layout" then
		return _handle_layout(data, state)
	elseif step == "language" then
		return _handle_language(data, state)
	elseif step == "llm_setup" then
		return _handle_llm_setup(data, state)
	elseif step == "complete" then
		return _handle_complete(data, state)
	end

	Logger.debug(LOG, "Unknown step: %s", tostring(step))
	return nil
end

return M
