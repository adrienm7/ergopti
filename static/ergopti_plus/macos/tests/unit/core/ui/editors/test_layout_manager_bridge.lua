--- tests/unit/core/ui/editors/test_layout_manager_bridge.lua

--- ==============================================================================
--- MODULE: Layout Manager Bridge (shared, replayed on macOS)
--- DESCRIPTION:
--- The layout manager page may only ask for the allowlisted actions, each
--- checked against the catalogue or the installed layouts, and every refresh
--- or operation pushes the page the same state on every driver
--- (layout-manager-bridge). These tests drive the shared controller
--- (_shared/layouts/engine/manager_bridge.lua) with a fake registry client and
--- record what it pushes, opens and closes.
--- ==============================================================================

local helpers = require("tests.helpers")
local ManagerBridge = require("layouts.engine.manager_bridge")

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
		helpers.assert_eq(state.pushes[1].payload.state.shortcut_menu_path, "shortcuts/menu.lua",
			"the page counts the menu file this driver loads")
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

	-- macOS 26 lists the layout and turns it on at the next login (composer-macos26).
	helpers.it("reports a layout macOS turns on at the next login as pending, not as a missing step", function()
		local instance, state = controller()
		helpers.assert_true(instance.on_message({ action = "install", id = "ergol" }))
		state.pending[1](true, { entry = INDEX.layouts[1], enabled = false, pending_activation = true })
		helpers.assert_eq(state.pushes[#state.pushes].payload.result.warning, "pending_logout")
		helpers.assert_true(instance.on_message({ action = "update", id = "ergol" }))
		-- macOS asks to allow a keyboard it has not seen: the page says so.
		state.pending[2](true, { entry = INDEX.layouts[1], enabled = true, consent = true })
		helpers.assert_eq(state.pushes[#state.pushes].payload.result.warning, "macos_consent")
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

helpers.describe("layout manager bridge: the layout editor's navigation layer", function()
	--- A controller whose host applies the navigation layer, or none.
	local function nav_controller(apply_nav)
		local pushes, logs = {}, {}
		local instance = ManagerBridge.new({
			registry = { snapshot = function() return { platform = "macos", installed = {} } end,
				refresh = function() end },
			push = function(name, payload) pushes[#pushes + 1] = { name = name, payload = payload }; return true end,
			strings = function() return {} end,
			open_url = function() end, close = function() end,
			log = function(level, message) logs[#logs + 1] = level .. ": " .. message end,
			apply_nav = apply_nav,
		})
		return instance, pushes, logs
	end

	helpers.it("routes nav_save to the host's navigation layer save and answers navResult (layout-editor-nav-apply)", function()
		local texts = {}
		local instance, pushes = nav_controller(function(text, on_done)
			texts[#texts + 1] = text
			on_done({ saved = true, applied = false, errors = {} })
		end)
		helpers.assert_true(instance.on_message({ action = "ready" }))
		helpers.assert_eq(pushes[1].payload.nav_apply, true)
		helpers.assert_true(instance.on_message({ action = "nav_save", text = "[layers]\n" }))
		helpers.assert_eq(texts[1], "[layers]\n")
		local answer = pushes[#pushes]
		helpers.assert_eq(answer.name, "navResult")
		helpers.assert_eq(answer.payload.saved, true)
		helpers.assert_eq(answer.payload.applied, false)
		helpers.assert_true(instance.on_message({ action = "nav_save", text = 3 }) == false, "a non-text save is refused")
		helpers.assert_eq(#texts, 1)
	end)

	helpers.it("refuses nav_save on a host without the navigation layer save (layout-editor-nav-apply)", function()
		local instance, pushes, logs = nav_controller(nil)
		helpers.assert_true(instance.on_message({ action = "ready" }))
		helpers.assert_eq(pushes[1].payload.nav_apply, false)
		helpers.assert_true(instance.on_message({ action = "nav_save", text = "x" }) == false)
		helpers.assert_true(#logs >= 1, "the refusal is logged")
	end)
end)

--- A bridge whose host records layout changes and answers its pause state.
--- @param paused table { value = boolean }
--- @return table instance, table changed
local function host_bridge(paused)
	local changed = {}
	local snapshot = { platform = "macos", index = INDEX, source = "network", installed = { ergol = { id = "ergol" } }, active = "" }
	local instance = ManagerBridge.new({
		registry = {
			snapshot = function() return snapshot end,
			refresh = function(on_done) on_done({}) end,
			install = function(_, on_done) on_done(true, {}) end,
			uninstall = function(_, on_done) on_done(true, {}) end,
			select = function(_, on_done) on_done(true, {}) end,
			composer_save = function(_, on_done) on_done(true) end,
			composer_remove = function(on_done) on_done(true) end,
		},
		push = function() return true end,
		strings = function() return {} end,
		open_url = function() end,
		close = function() end,
		log = function() end,
		layout_changed = function(id) changed[#changed + 1] = id end,
		is_paused = function() return paused.value end,
	})
	return instance, changed
end

helpers.describe("layout manager bridge: the emulation follows a changed layout", function()
	helpers.it("(lmh-001-002-emulation-reload) tells the host of every install, update, uninstall and composition", function()
		local instance, changed = host_bridge({ value = false })
		helpers.assert_true(instance.on_message({ action = "install", id = "ergol" }))
		helpers.assert_true(instance.on_message({ action = "update", id = "ergol" }))
		helpers.assert_true(instance.on_message({ action = "uninstall", id = "ergol" }))
		helpers.assert_true(instance.on_message({ action = "select", id = "ergol" }))
		helpers.assert_true(instance.on_message({ action = "composer_remove" }))
		helpers.assert_true(instance.on_message({ action = "composer_save", source = "src", keylayout = "kl" }))
		helpers.assert_eq(changed, { "ergol", "ergol", "ergol", "composed", "composed" },
			"a select changes no layout; every other success reaches the emulation")
	end)

	-- EDD-1 (maintainer, 2026-11-12): a pause stops typing, not configuration.
	helpers.it("(edd1-paused-writes) runs page commands while the driver is paused", function()
		local paused = { value = true }
		local instance, changed = host_bridge(paused)
		helpers.assert_true(instance.on_message({ action = "ready" }))
		helpers.assert_true(instance.on_message({ action = "install", id = "ergol" }), "an install runs while paused")
		helpers.assert_true(instance.on_message({ action = "uninstall", id = "ergol" }))
		helpers.assert_eq(changed, { "ergol", "ergol" })
		local host = assert(helpers.read_module_source("ui.layout_manager"))
		helpers.assert_nil(host:find("is_paused", 1, true), "the macOS host reads no pause")
	end)

	helpers.it("(lmh-004-extension-reload) a layout shipping an extension reloads the driver", function()
		local changed, reloads, logs = {}, {}, {}
		local snapshot = { platform = "macos", source = "network", active = "",
			index = { layouts = { { id = "ergol", name = "Ergol" }, { id = "kaladrius", name = "K", extension = { root = "x" } } } },
			installed = { ergol = { id = "ergol" }, bepo = { id = "bepo", extension = { root = "y" } } } }
		local instance = ManagerBridge.new({
			registry = {
				snapshot = function() return snapshot end,
				refresh = function(on_done) on_done({}) end,
				install = function(_, on_done) on_done(true, {}) end,
				uninstall = function(_, on_done) on_done(true, {}) end,
				select = function(_, on_done) on_done(true, {}) end,
			},
			push = function() return true end, strings = function() return {} end,
			open_url = function() end, close = function() end,
			log = function(level, message) logs[#logs + 1] = level .. ":" .. message end,
			layout_changed = function(id) changed[#changed + 1] = id end,
			reload_extensions = function(id) reloads[#reloads + 1] = id; return true end,
		})
		helpers.assert_true(instance.on_message({ action = "install", id = "kaladrius" }))
		helpers.assert_true(instance.on_message({ action = "uninstall", id = "bepo" }))
		helpers.assert_true(instance.on_message({ action = "select", id = "bepo" }))
		helpers.assert_true(instance.on_message({ action = "install", id = "ergol" }))
		helpers.assert_eq(reloads, { "kaladrius", "bepo" }, "catalogue and installed extensions both reload; a select changes no extension")
		helpers.assert_eq(changed, { "ergol" }, "a layout without an extension only reloads the emulation")
		helpers.assert_eq(#logs, 0)
	end)

	helpers.it("(lmh-001-002-emulation-reload) the macOS host reloads the emulated layout and the menu", function()
		local menu = assert(helpers.read_module_source("ui.menu"))
		helpers.assert_contains(menu, 'require("ui.layout_manager").set_layout_change_handler(function(id)')
		helpers.assert_contains(menu, "if Emulation.status().id ~= id then return end")
		local host = assert(helpers.read_module_source("ui.layout_manager"))
		helpers.assert_contains(menu, 'require("ui.layout_manager").set_extension_reloader(function()')
		helpers.assert_contains(host, "reload_extensions = function(id) return _extension_reloader ~= nil and _extension_reloader(id) == true end")
		helpers.assert_contains(host, "if _layout_change_handler then _layout_change_handler(id) end")
	end)
end)

