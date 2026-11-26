--- ui/user_workflows_bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: User Workflows Editor (Linux)
--- DESCRIPTION:
--- Hosts _shared/ui/user_workflows (bridge "hsWorkflows") on WebKitGTK: the
--- messages go to the shared editor host
--- (_shared/shortcuts/engine/workflows/editor_host.lua) with the Linux ports:
--- the page push through the webview manager, the native file dialogs for an
--- import and an export, and the parameterless actions of the gesture
--- catalogue for the « Ergopti action » step.
---
--- FEATURES & RATIONALE:
--- 1. One host per open page: a message of a page the manager no longer shows
---    (an older epoch) is ignored, so a closed window never saves.
--- 2. The dialogs run through ui/modal like every tray dialog, which hands the
---    grabbed keyboard back to the desktop while they are open.
--- ==============================================================================

local M = {}
M.bridge_name = "hsWorkflows"

local Json = require("core.text.engine.json")
local Logger = require("core.logger.engine.shim")

local LOG = "bridge.hsWorkflows"
local APP_NAME = require("shortcuts.engine.workflows.editor_host").APP_ID

local _host = nil

--- @param state table
--- @param field string
--- @param module_name string
--- @return table|nil The injected authority, else the module.
local function dependency(state, field, module_name)
	if type(state[field]) == "table" then return state[field] end
	local ok, module = pcall(require, module_name)
	return ok and type(module) == "table" and module or nil
end

--- The parameterless, runnable action ids of the Linux catalogue.
--- @param state table
--- @return table
local function action_ids(state)
	local gestures = dependency(state, "gestures", "gestures.engine.manager")
	local ids = {}
	for _, id in ipairs(gestures.get_action_names()) do
		if gestures.get_action_parameter_spec(id) == nil and gestures.is_runnable(id) then ids[#ids + 1] = id end
	end
	return ids
end

--- Asks the user for a file to read or to write.
--- @param state table
--- @param save boolean
--- @param default_name string|nil
--- @param pattern string The file filter ("*.json", "*.png").
--- @return string|nil path
local function pick_file(state, save, default_name, pattern)
	local shell = dependency(state, "shell", "core.process.adapters.shell_runner")
	local i18n = dependency(state, "i18n", "core.i18n.engine.i18n")
	local start = require("settings.engine.paths").home() .. "/" .. (default_name or "")
	local title = i18n.get(save and "workflows.editor.export" or "workflows.editor.import")
	local chosen, why = require("apps.ui.chooser").pick_path(shell, title, false, start, state.modal,
		{ save = save, filter = pattern })
	if not chosen then Logger.info(LOG, "No workflow file chosen: %s.", tostring(why)) end
	return chosen
end

--- The shared editor host with the Linux ports, built for the open page.
--- @param state table
--- @return table host
local function host_for(state)
	if _host then return _host end
	local manager = dependency(state, "webview_manager", "core.ui.ui.webview_manager")
	local i18n = dependency(state, "i18n", "core.i18n.engine.i18n")
	local FileSystem = dependency(state, "file_system", "core.fs.adapters.file_system")
	_host = require("shortcuts.engine.workflows.editor_host").new({
		workflows = dependency(state, "workflows", "modules.shortcuts.workflows"),
		push = function(function_name, payload)
			local ok, encoded = pcall(Json.encode, payload)
			if not ok then
				Logger.error(LOG, "Could not encode the %s workflow-editor payload.", function_name)
				return
			end
			manager.eval_js(APP_NAME, "if(window." .. function_name .. ") window." .. function_name .. "(" .. encoded .. ")")
		end,
		translate = function(key) return i18n.get(key) end,
		action_ids = function() return action_ids(state) end,
		save_path = function(default_name) return pick_file(state, true, default_name, "*.json") end,
		open_path = function(kind) return pick_file(state, false, nil, kind == "png" and "*.png" or "*.json") end,
		read_file = function(path)
			local body, status = FileSystem.read_with_status(path)
			if status ~= "ok" then return nil end
			return body
		end,
		write_file = function(path, text) return FileSystem.write(path, text) == true end,
		close = function()
			_host = nil
			manager.hide(APP_NAME)
		end,
	})
	return _host
end

--- Handles an incoming message of the page.
--- @param payload any Action table from host_bridge.js.
--- @param state table Daemon state and optional test-injected authorities.
--- @param context table|nil { app_name, epoch } from the manager.
function M.on_message(payload, state, context)
	state = type(state) == "table" and state or {}
	if type(payload) ~= "table" then return nil end
	local manager = dependency(state, "webview_manager", "core.ui.ui.webview_manager")
	if type(context) == "table" and context.epoch ~= nil and type(manager.current_epoch) == "function" then
		local ok, observed = pcall(manager.current_epoch, APP_NAME)
		if not ok or observed ~= context.epoch then
			Logger.info(LOG, "A message of a closed workflow editor page was ignored.")
			return nil
		end
	end
	if payload.action == "ready" then _host = nil end
	host_for(state).on_message(payload)
	return nil
end

--- Opens the window (the Shortcuts menu row).
--- @param state table|nil
--- @return boolean shown
function M.open(state)
	local manager = dependency(state or {}, "webview_manager", "core.ui.ui.webview_manager")
	local shown = manager.show(APP_NAME)
	if shown == false then Logger.warn(LOG, "The workflow editor window could not be opened.") end
	return shown ~= false
end

--- Forgets the host (the manager closed the window).
function M.reset() _host = nil end

return M
