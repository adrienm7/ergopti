--- tests/unit/ui/test_layout_manager_bridge.lua

--- ==============================================================================
--- MODULE: Layout Manager Bridge (Linux)
--- DESCRIPTION:
--- The Linux host of the layout manager page wires the shared controller
--- (_shared/lua/layouts/manager_bridge.lua) to the WebKitGTK window, the Linux
--- registry client and xdg-open (layout-manager-bridge). These tests inject
--- each authority and pin the wiring: pushes reach the layout_manager window as
--- window.<function>(<json>), the strings are the ones strings.json declares,
--- a homepage opens through a quoted xdg-open, and close hides the window.
--- ==============================================================================

local helpers = require("tests.helpers")

local INDEX = { layouts = { { id = "ergol", name = "Ergo-L", homepage = "https://ergol.org" } } }

--- The bridge with every authority injected.
--- @return table bridge, table state, table daemon_state
local function bridge()
	local Bridge = helpers.load_module("ui.layout_manager.bridge")
	Bridge._reset()
	local state = { pushes = {}, hidden = {}, commands = {}, calls = {} }
	local daemon_state = {
		webview_manager = {
			eval_js = function(app, js) state.pushes[#state.pushes + 1] = { app = app, js = js }; return true end,
			hide = function(app) state.hidden[#state.hidden + 1] = app; return true end,
		},
		shell = {
			has_command = function(name) return name == "xdg-open" end,
			quote = function(value) return "'" .. value .. "'" end,
			run = function(command) state.commands[#state.commands + 1] = command; return true end,
		},
		i18n = { get = function(key) return "translated:" .. key end },
		layout_registry = {
			snapshot = function() return { platform = "linux", index = INDEX, installed = {}, source = "cache" } end,
			refresh = function(on_done) state.calls[#state.calls + 1] = "refresh"; on_done({}) end,
			install = function(id, on_done) state.calls[#state.calls + 1] = "install " .. id; on_done(true, {}) end,
			uninstall = function() end,
			select = function() end,
		},
	}
	return Bridge, state, daemon_state
end

helpers.describe("layout manager bridge (Linux)", function()
	helpers.it("pushes the page state into the layout_manager window (layout-manager-bridge)", function()
		local Bridge, state, daemon_state = bridge()
		helpers.assert_eq(Bridge.bridge_name, "layout_manager_bridge")
		local result = Bridge.on_message({ action = "ready" }, daemon_state)
		helpers.assert_true(result.handled)
		helpers.assert_eq(state.pushes[1].app, "layout_manager")
		helpers.assert_contains(state.pushes[1].js, "window.initData(")
		helpers.assert_contains(state.pushes[1].js, '"layout_manager.window_title":"translated:layout_manager.window_title"')
		helpers.assert_contains(state.pushes[1].js, '"platform":"linux"')
		helpers.assert_contains(state.pushes[2].js, "window.updateState(")
		helpers.assert_eq(state.calls[1], "refresh")
	end)

	helpers.it("opens the catalogue homepage through xdg-open and hides on close (layout-manager-bridge)", function()
		local Bridge, state, daemon_state = bridge()
		helpers.assert_true(Bridge.on_message({ action = "open_homepage", id = "ergol" }, daemon_state).handled)
		helpers.assert_eq(state.commands[1], "xdg-open 'https://ergol.org' >/dev/null 2>&1 &")
		helpers.assert_true(Bridge.on_message({ action = "close" }, daemon_state).handled)
		helpers.assert_eq(state.hidden[1], "layout_manager")
		helpers.assert_true(Bridge.on_message({ action = "shell", id = "ergol" }, daemon_state).handled == false,
			"an action outside the allowlist is refused")
	end)
end)
