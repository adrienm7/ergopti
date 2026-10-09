--- ui/layout_manager/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Layout Manager
--- DESCRIPTION:
--- Implements the protocol of _shared/ui/layout_manager/script.js on Linux.
--- Bridge name: "layout_manager_bridge". The message rules and the page state
--- are shared with macOS (_shared/lua/layouts/manager_bridge.lua); this file
--- wires them to the Linux registry client, the WebKitGTK window and xdg-open.
--- ==============================================================================

local M = {}
M.bridge_name = "layout_manager_bridge"

local Json          = require("json")
local Logger        = require("logger.shim")
local Paths         = require("infra.paths")
local FileSystem    = require("adapters.file_system")
local ManagerBridge = require("layouts.manager_bridge")

local LOG = "bridge.layout_manager"
local APP_NAME = "layout_manager"
-- Every string the page shows, declared next to it.
local STRINGS_FILE = "ui/layout_manager/strings.json"

-- One controller per daemon: the window manager keeps at most one page.
local _controller = nil

--- A dependency injected by tests, or the production module.
--- @param state table
--- @param field string
--- @param module_name string
--- @return table|nil
local function dependency(state, field, module_name)
	if type(state[field]) == "table" then return state[field] end
	local ok, module = pcall(require, module_name)
	return ok and type(module) == "table" and module or nil
end

--- The translated strings the page shows.
--- @param i18n table|nil
--- @return table
local function page_strings(i18n)
	local path = Paths.shared(STRINGS_FILE)
	local raw = type(path) == "string" and FileSystem.read(path) or nil
	local ok, doc = pcall(Json.decode, raw or "")
	local strings = {}
	if not ok or type(doc) ~= "table" or type(doc.keys) ~= "table" then
		Logger.error(LOG, "The layout manager strings list %s is unreadable.", tostring(path))
		return strings
	end
	for _, key in ipairs(doc.keys) do
		strings[key] = type(i18n) == "table" and type(i18n.get) == "function" and i18n.get(key) or key
	end
	return strings
end

--- The controller wired to this daemon.
--- @param state table
--- @return table
local function controller(state)
	if _controller and not state.fresh_controller then return _controller end
	local manager = dependency(state, "webview_manager", "ui.webview_manager")
	local shell = dependency(state, "shell", "adapters.shell_runner")
	local i18n = dependency(state, "i18n", "infra.i18n")
	_controller = ManagerBridge.new({
		registry = dependency(state, "layout_registry", "modules.keymap.layout_registry"),
		push = function(function_name, payload)
			local ok, encoded = pcall(Json.encode, payload)
			if not ok or type(encoded) ~= "string" or not manager then
				Logger.error(LOG, "The layout manager %s payload could not be pushed.", function_name)
				return false
			end
			local pushed, accepted = pcall(manager.eval_js, APP_NAME,
				"if(window." .. function_name .. ") window." .. function_name .. "(" .. encoded .. ")")
			return pushed and accepted == true
		end,
		strings = function() return page_strings(i18n) end,
		open_url = function(url)
			if not shell or not shell.has_command("xdg-open") then
				Logger.error(LOG, "xdg-open is unavailable — the layout homepage cannot be opened.")
				return
			end
			shell.run("xdg-open " .. shell.quote(url) .. " >/dev/null 2>&1 &")
		end,
		close = function()
			if manager and type(manager.hide) == "function" then pcall(manager.hide, APP_NAME) end
		end,
		log = function(level, message, ...) Logger[level](LOG, message, ...) end,
	})
	return _controller
end

--- Handles an incoming JS message.
--- @param payload any Action table from host_bridge.js.
--- @param state table Daemon state and optional test-injected authorities.
--- @return table|nil Diagnostic response; page data is pushed through eval_js.
function M.on_message(payload, state)
	state = type(state) == "table" and state or {}
	local handled = controller(state).on_message(payload)
	return { handled = handled }
end

--- Test seam: forgets the controller.
function M._reset()
	_controller = nil
end

return M
