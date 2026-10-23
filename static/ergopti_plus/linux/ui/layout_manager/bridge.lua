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

-- Registry work can outlive a page; its UI callbacks retain that exact owner.
local _controller, _controller_owner, _registry_observer = nil, nil, nil

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
local function controller(state, context)
	local manager = dependency(state, "webview_manager", "ui.webview_manager")
	local epoch = type(context) == "table" and context.epoch or nil
	if epoch ~= nil and (type(epoch) ~= "number" or context.app_name ~= APP_NAME) then return nil end
	local native_current = manager and manager.page_current
	local function page_current()
		if epoch == nil then return true end
		if type(native_current) ~= "function" or manager.page_current ~= native_current then return false end
		local called, current = pcall(native_current, APP_NAME, epoch)
		return called and current == true and manager.page_current == native_current
	end
	if not page_current() then return nil end
	if _controller and not state.fresh_controller and _controller_owner.manager == manager
		and _controller_owner.state == state and _controller_owner.epoch == epoch then return _controller end
	local registry = dependency(state, "layout_registry", "modules.keymap.layout_registry")
	if not manager or type(manager.eval_js) ~= "function" or type(registry) ~= "table" then return nil end
	for _, method in ipairs({ "snapshot", "refresh", "install", "uninstall", "select" }) do
		if type(registry[method]) ~= "function" then
			Logger.error(LOG, "The layout registry exposes no %s operation.", method)
			return nil
		end
	end
	local owner = { manager = manager, state = state, epoch = epoch }
	_controller_owner = owner
	local function current()
		return _controller_owner == owner and page_current() and _controller_owner == owner
	end
	-- Keep global install/refresh work running, but revoke its retired page callback
	-- before the shared controller can read a snapshot or publish an old result.
	local owned_registry = { snapshot = registry.snapshot }
	owned_registry.refresh = function(done)
		if not current() then return false end
		return registry.refresh(function(...) if current() then done(...) end end)
	end
	for _, method in ipairs({ "install", "uninstall", "select" }) do
		local operation = registry[method]
		owned_registry[method] = function(id, done)
			if not current() then return false end
			local settled = false
			return operation(id, function(...)
				if settled then return end
				settled = true
				if current() then return done(...) end
				-- A replacement explicitly observes global busy state on ready.
				-- Publish its fresh snapshot, never this retired operation's result.
				local observer = _registry_observer
				if observer and observer.registry == registry then observer.publish() end
			end)
		end
	end
	-- The composer's operations take their callback last (open, save, remove).
	for _, method in ipairs({ "composer_open", "composer_save", "composer_remove" }) do
		local operation = registry[method]
		if type(operation) == "function" then
			owned_registry[method] = function(...)
				if not current() then return false end
				local args = { ... }
				local done = args[#args]
				args[#args] = function(...)
					if current() then return done(...) end
				end
				return operation((table.unpack or unpack)(args))
			end
		end
	end
	local shell = dependency(state, "shell", "adapters.shell_runner")
	local i18n = dependency(state, "i18n", "infra.i18n")
	local function push(function_name, payload)
		if not current() then return false end
		local ok, encoded = pcall(Json.encode, payload)
		if not ok or type(encoded) ~= "string" or not manager then
			Logger.error(LOG, "The layout manager %s payload could not be pushed.", function_name)
			return false
		end
		if not current() then return false end
		local pushed, accepted = pcall(manager.eval_js, APP_NAME,
			"if(window." .. function_name .. ") window." .. function_name .. "(" .. encoded .. ")")
		return pushed and accepted == true
	end
	_controller = ManagerBridge.new({
		registry = owned_registry,
		push = push,
		strings = function() return page_strings(i18n) end,
		open_url = function(url)
			if not current() then return false end
			if not shell or not shell.has_command("xdg-open") then
				Logger.error(LOG, "xdg-open is unavailable — the layout homepage cannot be opened.")
				return
			end
			if not current() then return false end
			shell.run("xdg-open " .. shell.quote(url) .. " >/dev/null 2>&1 &")
		end,
		close = function()
			if not current() then return false end
			if type(context) == "table" and type(context.close_owned_window) == "function" then
				return context.close_owned_window() == true
			end
			if type(manager.hide) == "function" then return manager.hide(APP_NAME, epoch) == true end
			return false
		end,
		log = function(level, message, ...) Logger[level](LOG, message, ...) end,
	})
	owner.registry, owner.controller = registry, _controller
	owner.publish = function()
		if not current() then return false end
		local snapshot = registry.snapshot()
		if not current() then return false end
		return push("updateState", ManagerBridge.page_state(snapshot, owner.controller.result))
	end
	return _controller
end

--- Handles an incoming JS message.
--- @param payload any Action table from host_bridge.js.
--- @param state table Daemon state and optional test-injected authorities.
--- @param context table|nil Trusted native app and page epoch.
--- @return table|nil Diagnostic response; page data is pushed through eval_js.
function M.on_message(payload, state, context)
	state = type(state) == "table" and state or {}
	local active = controller(state, context)
	if active and type(payload) == "table" and payload.action == "ready" then
		_registry_observer = _controller_owner
	end
	local handled = active ~= nil and active.on_message(payload)
	return { handled = handled }
end

--- Revokes only callbacks belonging to the exact retired native page.
--- @param epoch number|nil
function M.on_window_closed(epoch)
	if not _controller_owner or (epoch ~= nil and _controller_owner.epoch ~= epoch) then return end
	if _registry_observer == _controller_owner then _registry_observer = nil end
	_controller, _controller_owner = nil, nil
end

--- Test seam: forgets the controller and revokes all retained callbacks.
function M._reset()
	_controller, _controller_owner, _registry_observer = nil, nil, nil
end

return M
