--- ui/paths_editor/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Paths / Config Editor
--- DESCRIPTION:
--- Implements the exact protocol emitted by _shared/ui/paths_editor/script.js.
--- Bridge name: "hsPaths".
--- ==============================================================================

local M = {}
M.bridge_name = "hsPaths"

local Json = require("json")
local Logger = require("logger.shim")
local ConfigDirPicker = require("ui.config_dir_picker")
local Version = require("infra.version")
local LOG = "bridge.hsPaths"
local APP_NAME = "paths_editor"

local function dependency(state, field, module_name)
	if type(state[field]) == "table" then return state[field] end
	local ok, module = pcall(require, module_name)
	return ok and type(module) == "table" and module or nil
end

local function push(state, function_name, payload)
	local manager = dependency(state, "webview_manager", "ui.webview_manager")
	if not manager or type(manager.eval_js) ~= "function" then return false end
	local ok, encoded = pcall(Json.encode, payload)
	if not ok or type(encoded) ~= "string" then
		Logger.error(LOG, "Could not encode the %s paths-editor payload.", function_name)
		return false
	end
	local pushed, accepted = pcall(manager.eval_js, APP_NAME,
		"if(window." .. function_name .. ") window." .. function_name .. "(" .. encoded .. ")")
	return pushed and accepted == true
end

local function build_strings(i18n)
	local keys = {
		"menu.paths.window_title",
		"paths_editor.heading", "paths_editor.subtitle", "paths_editor.label_config_dir",
		"paths_editor.tag_default", "paths_editor.tag_modified",
		"paths_editor.btn_browse", "paths_editor.btn_reset",
		"paths_editor.btn_cancel", "paths_editor.btn_save",
	}
	local strings = {}
	for _, key in ipairs(keys) do
		strings[key] = type(i18n) == "table" and type(i18n.get) == "function"
			and i18n.get(key) or key
	end
	return strings
end

--- Builds the exact payload consumed by window.initData().
--- @param state table Daemon state and optional test-injected authorities.
--- @return table|nil payload
local function build_initial_payload(state)
	local config_paths = dependency(state, "config_paths", "infra.config_paths")
	if not config_paths or type(config_paths.get_config_dir) ~= "function"
		or type(config_paths.default_config_dir) ~= "function" then
		return nil
	end
	return {
		configDir = config_paths.get_config_dir(),
		defaultConfigDir = config_paths.default_config_dir(),
		version = state._version or Version.VERSION,
		strings = build_strings(dependency(state, "i18n", "infra.i18n")),
	}
end

local function hide(state)
	local manager = dependency(state, "webview_manager", "ui.webview_manager")
	if not manager or type(manager.hide) ~= "function" then return false end
	local ok, hidden = pcall(manager.hide, APP_NAME)
	return ok and hidden ~= false
end

--- Handles an incoming JS message.
--- @param payload any Action table from host_bridge.js.
--- @param state table Daemon state and optional test-injected authorities.
--- @return table|nil Diagnostic response; page data is pushed through eval_js.
function M.on_message(payload, state)
	state = type(state) == "table" and state or {}
	if type(payload) ~= "table" then return nil end
	local action = payload.action
	if action == "ready" then
		local data = build_initial_payload(state)
		if not data then return { pushed = false } end
		return { pushed = push(state, "initData", data), data = data }
	elseif action == "browse" then
		local config_paths = dependency(state, "config_paths", "infra.config_paths")
		local current = payload.current
		if current == nil and config_paths and type(config_paths.get_config_dir) == "function" then
			current = config_paths.get_config_dir()
		end
		local selected, select_err = ConfigDirPicker.pick(
			dependency(state, "shell", "adapters.shell_runner"),
			config_paths,
			dependency(state, "i18n", "infra.i18n"),
			current
		)
		if not selected then
			Logger.debug(LOG, "Folder picker returned no directory: %s.", tostring(select_err))
			return { picked = false }
		end
		return {
			picked = true,
			path = selected,
			pushed = push(state, "applyBrowseResult", selected),
		}
	elseif action == "save" then
		local config_paths = dependency(state, "config_paths", "infra.config_paths")
		local saved = config_paths and type(config_paths.set_config_dir) == "function"
			and config_paths.set_config_dir(payload.configDir) == true
		if not saved then
        Logger.error(LOG, "Configuration directory was not persisted; editor remains open.")
			return { saved = false }
		end
		local hidden = hide(state)
		local reloaded = false
		if type(state.on_reload) == "function" then
			local ok, accepted = pcall(state.on_reload)
			reloaded = ok and accepted ~= false
			if not reloaded then Logger.error(LOG, "Configuration reload was refused after save.") end
		else
			Logger.warn(LOG, "Configuration directory saved; daemon reload is unavailable.")
		end
		Logger.success(LOG, "Configuration directory persisted: %s", config_paths.get_config_dir())
		return { saved = true, hidden = hidden, reloaded = reloaded }
	elseif action == "cancel" then
		return { cancelled = true, hidden = hide(state) }
	end

	Logger.debug(LOG, "Unknown action: %s", tostring(action))
	return nil
end

M._build_initial_payload = build_initial_payload

return M
