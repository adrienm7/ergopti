--- ui/layout_manager/bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Layout Manager
--- DESCRIPTION:
--- Implements the protocol of _shared/ui/layout_manager/script.js on Linux.
--- Bridge name: "layout_manager_bridge". The message rules and the page state
--- are shared with macOS (_shared/layouts/engine/manager_bridge.lua); this file
--- wires them to the Linux registry client, the WebKitGTK window and xdg-open.
--- The layout editor has its own window (_shared/ui/layout_editor_window, bridge
--- "layout_editor_window_bridge"): M.editor is its handler, built by the same
--- factory, and the manager page's open_editor shows it.
--- ==============================================================================

local Json          = require("core.text.engine.json")
local Logger        = require("core.logger.engine.shim")
local Paths         = require("infra.paths")
local FileSystem    = require("adapters.file_system")
local ManagerBridge = require("layouts.engine.manager_bridge")

local LOG = "bridge.layout_manager"

-- The two windows: the app (a directory of _shared/ui), its bridge, the strings
-- its page declares and whether it is the layout editor's own window.
local MANAGER_SPEC = {
	app_name = require("settings.engine.keys").COMMAND.LAYOUT_MANAGER,
	bridge_name = "layout_manager_bridge",
	strings_file = "ui/layout_manager/strings.json",
	editor_window = false,
}
local EDITOR_SPEC = {
	app_name = "layout_editor_window",
	bridge_name = "layout_editor_window_bridge",
	strings_file = "ui/layout_editor_window/strings.json",
	editor_window = true,
}

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

--- The translated strings a page shows.
--- @param i18n table|nil
--- @param strings_file string The page's strings.json under _shared.
--- @return table
local function page_strings(i18n, strings_file)
	local path = Paths.shared(strings_file)
	local raw = type(path) == "string" and FileSystem.read(path) or nil
	local ok, doc = pcall(Json.decode, raw or "")
	local strings = {}
	if not ok or type(doc) ~= "table" or type(doc.keys) ~= "table" then
		Logger.error(LOG, "The layout window strings list %s is unreadable.", tostring(path))
		return strings
	end
	for _, key in ipairs(doc.keys) do
		strings[key] = type(i18n) == "table" and type(i18n.get) == "function" and i18n.get(key) or key
	end
	return strings
end

--- Builds the bridge handler of one window.
--- @param spec table MANAGER_SPEC or EDITOR_SPEC.
--- @return table handler { bridge_name, on_message, on_window_closed, _reset }
local function new_handler(spec)
	local H = { bridge_name = spec.bridge_name }
	-- Registry work can outlive a page; its UI callbacks retain that exact owner.
	local _controller, _controller_owner, _registry_observer = nil, nil, nil

	--- The controller wired to this daemon.
	--- @param state table
	--- @return table
	local function controller(state, context)
		local manager = dependency(state, "webview_manager", "ui.webview_manager")
		local epoch = type(context) == "table" and context.epoch or nil
		if epoch ~= nil and (type(epoch) ~= "number" or context.app_name ~= spec.app_name) then return nil end
		local native_current = manager and manager.page_current
		local function page_current()
			if epoch == nil then return true end
			if type(native_current) ~= "function" or manager.page_current ~= native_current then return false end
			local called, current = pcall(native_current, spec.app_name, epoch)
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
		-- The composer's and the layout editor's operations take their callback last.
		for _, method in ipairs({ "composer_open", "composer_save", "composer_remove", "composer_emulate", "source_open",
			"source_save" }) do
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
		local layer_editor = dependency(state, "layer_editor_bridge", "ui.layer_editor.bridge")
		if layer_editor and type(layer_editor.apply_text) ~= "function" then layer_editor = nil end
		local preferences = dependency(state, "layout_emulation_preferences", "infra.layout_emulation_preferences")
		local emulation = dependency(state, "layout_emulation", "modules.keymap.layout_emulation")
		if not (preferences and type(preferences.choose) == "function" and emulation
			and type(emulation.reload_if_started) == "function") then
			preferences, emulation = nil, nil
		end
		local function push(function_name, payload)
			if not current() then return false end
			local ok, encoded = pcall(Json.encode, payload)
			if not ok or type(encoded) ~= "string" or not manager then
				Logger.error(LOG, "The layout manager %s payload could not be pushed.", function_name)
				return false
			end
			if not current() then return false end
			local pushed, accepted = pcall(manager.eval_js, spec.app_name,
				"if(window." .. function_name .. ") window." .. function_name .. "(" .. encoded .. ")")
			return pushed and accepted == true
		end
		_controller = ManagerBridge.new({
			registry = owned_registry,
			push = push,
			strings = function() return page_strings(i18n, spec.strings_file) end,
			editor_window = spec.editor_window,
			-- The manager page's « Layout editor » shows the editor's own window.
			open_editor_window = not spec.editor_window and function()
				if not current() or type(manager.show) ~= "function" then return false end
				return manager.show(EDITOR_SPEC.app_name) ~= false
			end or nil,
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
				if type(manager.hide) == "function" then return manager.hide(spec.app_name, epoch) == true end
				return false
			end,
			log = function(level, message, ...) Logger[level](LOG, message, ...) end,
			-- A layout that changed while it is the emulated one reloads the
			-- emulation: an uninstalled one stays chosen and stops, a reinstalled one
			-- resumes (maintainer decision, 2026-11-12), and the tray shows its state
			-- (LMH-001, LMH-002).
			layout_changed = function(id)
				if not emulation or type(emulation.status) ~= "function" or emulation.status().id ~= id then return end
				emulation.reload_if_started()
				if type(state.on_config_changed) == "function" then state.on_config_changed() end
			end,
			-- The extension catalogue is read once per boot: a layout whose
			-- extension was installed or removed loads or drops its hotstrings
			-- through a daemon reload, as Windows' _LayMgrWeb_After does (LMH-004).
			reload_extensions = function()
				if type(state.on_reload) ~= "function" then return false end
				return state.on_reload() == true
			end,
			-- The layout editor applies a source's navigation layer through the
			-- navigation layer editor's own save (ui/layer_editor/bridge.lua).
			apply_nav = layer_editor and function(text, done)
				if not current() then return false end
				local result = layer_editor.apply_text(text, state)
				if current() then done(result) end
			end or nil,
			-- « Emulate without installing »: the composed layout becomes the emulated
			-- one, as the menu's « Layout to emulate » stores it, and the emulation
			-- reloads at once (modules/keymap/layout_emulation.lua).
			emulate = preferences and function(id, done)
				if not current() then return false end
				if not preferences.choose(id) then
					done(false, "emulate_not_saved", "the layout emulation settings were not saved")
					return
				end
				if emulation.reload_if_started() == false then
					done(false, "emulate_failed", "the layout emulation did not reload the composed layout")
					return
				end
				-- The tray ticks the newly emulated layout, as the menu row and macOS
				-- do (LMH-005).
				if type(state.on_config_changed) == "function" then state.on_config_changed() end
				if current() then done(true) end
			end or nil,
		})
		owner.registry, owner.controller, owner.current = registry, _controller, current
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
	function H.on_message(payload, state, context)
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
	function H.on_window_closed(epoch)
		if not _controller_owner or (epoch ~= nil and _controller_owner.epoch ~= epoch) then return end
		if _registry_observer == _controller_owner then _registry_observer = nil end
		_controller, _controller_owner = nil, nil
	end

	--- Test seam: forgets the controller and revokes all retained callbacks.
	function H._reset()
		_controller, _controller_owner, _registry_observer = nil, nil, nil
	end

	return H
end

local M = new_handler(MANAGER_SPEC)
M.editor = new_handler(EDITOR_SPEC)

--- Opens the layout editor in its own window (the menu's « Create or edit a
--- layout… »), or brings the open one to the front: its controller answers the
--- page's ready with the last saved source, and an open editor keeps its work.
--- @param manager table The webview manager (ui.webview_manager).
--- @return boolean shown
function M.open_editor_window(manager)
	if type(manager) ~= "table" or type(manager.show) ~= "function" then
		Logger.error(LOG, "No webview manager — the layout editor window cannot open.")
		return false
	end
	return manager.show(EDITOR_SPEC.app_name) ~= false
end

return M
