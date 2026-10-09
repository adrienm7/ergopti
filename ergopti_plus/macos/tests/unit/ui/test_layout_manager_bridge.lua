--- tests/unit/ui/test_layout_manager_bridge.lua

--- ==============================================================================
--- MODULE: Layout Manager Bridge (shared, replayed on macOS)
--- DESCRIPTION:
--- The layout manager page may only ask for the allowlisted actions, each
--- checked against the catalogue or the installed layouts, and every refresh
--- or operation pushes the page the same state on every driver
--- (layout-manager-bridge). These tests drive the shared controller
--- (_shared/lua/layouts/manager_bridge.lua) with a fake registry client and
--- record what it pushes, opens and closes.
--- ==============================================================================

local helpers = require("tests.helpers")
local ManagerBridge = require("layouts.manager_bridge")

local INDEX = {
	layouts = {
		{ id = "ergol", name = "Ergo-L", homepage = "https://ergol.org", sha256 = "b", version = "1.0.2" },
		{ id = "plain", name = "Plain", homepage = "http://insecure.example.org", sha256 = "c", version = "1.0.0" },
	},
}

--- A controller over a fake registry client.
--- @param installed table Installed entries by id.
--- @return table controller, table state
local function controller(installed)
	local state = { pushes = {}, calls = {}, opened = {}, closed = 0, logs = {}, pending = {} }
	local snapshot = {
		platform = "macos", index = INDEX, source = "network", installed = installed or {}, active = "",
	}
	local registry = {
		snapshot = function() return snapshot end,
		refresh = function(on_done) state.calls[#state.calls + 1] = "refresh"; on_done({}) end,
		install = function(id, on_done)
			state.calls[#state.calls + 1] = "install " .. id
			state.pending[#state.pending + 1] = on_done
		end,
		uninstall = function(id, on_done) state.calls[#state.calls + 1] = "uninstall " .. id; on_done(true, { id = id }) end,
		select = function(id, on_done) state.calls[#state.calls + 1] = "select " .. id; on_done(false, "select_failed", "no") end,
	}
	local instance = ManagerBridge.new({
		registry = registry,
		push = function(name, payload) state.pushes[#state.pushes + 1] = { name = name, payload = payload }; return true end,
		strings = function() return { ["layout_manager.window_title"] = "Keyboard layouts" } end,
		open_url = function(url) state.opened[#state.opened + 1] = url end,
		close = function() state.closed = state.closed + 1 end,
		log = function(level, message) state.logs[#state.logs + 1] = level .. ": " .. message end,
	})
	return instance, state
end

helpers.describe("layout manager bridge: what the page may ask", function()
	helpers.it("answers ready with the strings and the state, then the refreshed state (layout-manager-bridge)", function()
		local instance, state = controller()
		helpers.assert_true(instance.on_message({ action = "ready" }))
		helpers.assert_eq(state.pushes[1].name, "initData")
		helpers.assert_eq(state.pushes[1].payload.strings["layout_manager.window_title"], "Keyboard layouts")
		helpers.assert_eq(state.pushes[1].payload.state.platform, "macos")
		helpers.assert_eq(state.pushes[1].payload.state.index, INDEX)
		helpers.assert_eq(state.calls[1], "refresh")
		helpers.assert_eq(state.pushes[2].name, "updateState")
	end)

	helpers.it("refuses anything outside the allowlist or naming an unknown layout (layout-manager-bridge)", function()
		local instance, state = controller()
		for _, payload in ipairs({
			"install", {}, { action = "rm -rf" }, { action = "install" }, { action = "install", id = "../evil" },
			{ action = "install", id = "absent" }, { action = "uninstall", id = "ergol" }, { action = "select", id = "ergol" },
			{ action = "open_homepage", id = "plain" },
		}) do
			helpers.assert_true(instance.on_message(payload) == false, "accepted: " .. tostring(payload.action))
		end
		helpers.assert_eq(#state.calls, 0, "no refused message reaches the registry")
		helpers.assert_eq(#state.opened, 0, "no refused message opens anything")
		helpers.assert_true(#state.logs >= 8, "every refusal is logged")
	end)

	helpers.it("installs a catalogue layout and reports the result once it settles (layout-manager-bridge)", function()
		local instance, state = controller()
		helpers.assert_true(instance.on_message({ action = "install", id = "ergol" }))
		helpers.assert_eq(state.calls[1], "install ergol")
		helpers.assert_eq(state.pushes[#state.pushes].payload.result, nil, "no result before the operation settles")
		state.pending[1](true, { entry = INDEX.layouts[1], enabled = false })
		local result = state.pushes[#state.pushes].payload.result
		helpers.assert_eq(result.id, "ergol")
		helpers.assert_eq(result.ok, true)
		helpers.assert_eq(result.warning, "not_enabled", "an installed but not enabled layout says so")
		helpers.assert_true(instance.on_message({ action = "update", id = "ergol" }))
		state.pending[2](false, "download_failed", "HTTP 404 for x")
		result = state.pushes[#state.pushes].payload.result
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(result.code, "download_failed")
		helpers.assert_eq(result.detail, "HTTP 404 for x")
	end)

	helpers.it("uninstalls and selects installed layouts only (layout-manager-bridge)", function()
		local instance, state = controller({ ergol = INDEX.layouts[1] })
		helpers.assert_true(instance.on_message({ action = "uninstall", id = "ergol" }))
		helpers.assert_true(instance.on_message({ action = "select", id = "ergol" }))
		helpers.assert_eq(state.calls[1], "uninstall ergol")
		helpers.assert_eq(state.calls[2], "select ergol")
		local result = state.pushes[#state.pushes].payload.result
		helpers.assert_eq(result.action, "select")
		helpers.assert_eq(result.code, "select_failed")
	end)

	helpers.it("opens only the https homepage the catalogue gives, and closes on request (layout-manager-bridge)", function()
		local instance, state = controller()
		helpers.assert_true(instance.on_message({ action = "open_homepage", id = "ergol", url = "https://evil.test" }))
		helpers.assert_eq(state.opened[1], "https://ergol.org", "the page never chooses the URL")
		helpers.assert_true(instance.on_message({ action = "close" }))
		helpers.assert_eq(state.closed, 1)
	end)
end)
