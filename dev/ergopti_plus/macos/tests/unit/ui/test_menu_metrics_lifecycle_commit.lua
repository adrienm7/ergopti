--- tests/unit/ui/test_menu_metrics_lifecycle_commit.lua

--- ==============================================================================
--- MODULE: Metrics menu lifecycle commitment
--- DESCRIPTION:
--- Drives the real top-level Metrics action with a keylogger whose strict start
--- returns false. The click must compensate the already-persisted ON preference,
--- keep WPM producers stopped, and repaint an unchecked menu.
--- ==============================================================================

local helpers = require("tests.helpers")

local function load_menu(start_result)
	local ctx = { saves = 0, updates = 0, menubar_starts = 0, widget_starts = 0 }
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["hs.fs"] = hs_stub.fs

	local defaults = {
		keylogger_enabled = false, keylogger_disabled_apps = {}, keylogger_encrypt = false,
		keylogger_menubar_wpm = true, keylogger_menubar_colors = false,
		keylogger_float_wpm = true, keylogger_float_graph = false,
		keylogger_float_colors = false, keylogger_private_filter_enabled = true,
		keylogger_secure_filter_enabled = true, keylogger_system_auth_filter_enabled = true,
	}
	package.loaded["modules.keylogger"] = setmetatable({
		DEFAULT_STATE = defaults,
		start = function() return start_result end,
		set_options = function() end,
		set_disabled_apps = function() end,
	}, { __index = function() return function() end end })
	package.loaded["infra.app_picker"] = { build_menu = function() return {} end }
	package.loaded["infra.dialog_util"] = {
		block_alert = function() return "button.activate" end,
	}
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.manifest_menu"] = {
		build = function() return {} end,
		resolve_disabled_when = function() return false end,
	}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["ui.wpm.wpm_menubar"] = {
		start = function() ctx.menubar_starts = ctx.menubar_starts + 1 end,
		stop = function() end, set_use_source_colors = function() end,
	}
	package.loaded["ui.wpm.wpm_widget"] = {
		start = function() ctx.widget_starts = ctx.widget_starts + 1 end,
		stop = function() end, set_use_source_colors = function() end,
	}
	package.loaded["ui.menu.menu_metrics"] = nil
	local MenuMetrics = require("ui.menu.menu_metrics")

	ctx.state = {}
	for key, value in pairs(defaults) do ctx.state[key] = value end
	ctx.item = MenuMetrics.build({
		state = ctx.state,
		save_prefs = function() ctx.saves = ctx.saves + 1; return true end,
		updateMenu = function() ctx.updates = ctx.updates + 1 end,
		script_control = { is_paused = function() return false end },
	})
	return ctx
end

helpers.describe("menu_metrics: strict keylogger lifecycle reaches the checkmark", function()
	helpers.it("compensates a rejected activation before reporting Metrics enabled", function()
		local ctx = load_menu(false)
		local result = ctx.item.action()

		helpers.assert_eq(false, result,
			"the click must report that runtime activation did not commit")
		helpers.assert_eq(false, ctx.state.keylogger_enabled,
			"the rendered and persisted switch must roll back to disabled")
		helpers.assert_eq(2, ctx.saves,
			"the initial ON publication needs one compensating OFF publication")
		helpers.assert_eq(1, ctx.updates,
			"the menu must repaint the compensating unchecked state")
		helpers.assert_eq(0, ctx.menubar_starts,
			"WPM menubar cannot start when the keylogger security watcher failed")
		helpers.assert_eq(0, ctx.widget_starts,
			"WPM widget cannot start when the keylogger security watcher failed")
	end)
end)
