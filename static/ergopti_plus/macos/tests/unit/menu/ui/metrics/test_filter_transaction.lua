--- tests/unit/menu/ui/metrics/test_filter_transaction.lua

--- ==============================================================================
--- MODULE: Metrics Filter Toggle Transaction
--- DESCRIPTION:
--- Proves that the private, secure-field, and system-auth filter rows keep the
--- menu state, runtime filter, and persisted preferences on one outcome.
--- ==============================================================================

local helpers = require("tests.helpers")
local MetricsState = require("infra.metrics_state_keys")

local MODULES = {
	"hs.fs",
	"apps.engine.picker",
	"core.ui.engine.dialog_util",
	"core.i18n.engine.i18n",
	"core.logger.engine.logger",
	"menu.engine.manifest_reader",
	"menu.engine.manifest_menu",
	"core.text.engine.utils",
	"modules.keystats",
	"ui.menu.menu_metrics",
}

local FILTERS = {
	{
		command = "filter_private",
		field = MetricsState.PRIVATE_FILTER_ENABLED,
		setter = "set_private_filter_enabled",
	},
	{
		command = "filter_secure",
		field = MetricsState.SECURE_FILTER_ENABLED,
		setter = "set_secure_field_filter_enabled",
	},
	{
		command = "filter_sysauth",
		field = MetricsState.SYSTEM_AUTH_FILTER_ENABLED,
		setter = "set_system_auth_filter_enabled",
	},
}

--- Loads the real metrics menu while replacing only its external boundaries.
--- @param filter table Filter descriptor.
--- @param options table Failure-mode options.
--- @param callback function Receives the command result and observations.
local function with_filter(filter, options, callback)
	local saved = {}
	for _, name in ipairs(MODULES) do
		saved[name] = package.loaded[name]
		package.loaded[name] = nil
	end

	local observations = {
		errors = {},
		runtime = true,
		saves = 0,
		setter_values = {},
		updates = 0,
	}
	local keystats = {
		DEFAULT_STATE = {
			keystats_disabled_apps = {},
			keystats_enabled = false,
			keystats_encrypt = false,
			keystats_float_colors = false,
			keystats_float_graph = false,
			keystats_float_wpm = false,
			keystats_menubar_colors = false,
			keystats_menubar_wpm = false,
			keystats_private_filter_enabled = true,
			keystats_secure_filter_enabled = true,
			keystats_system_auth_filter_enabled = true,
		},
	}
	keystats.set_disabled_apps = function(value)
		observations.apps = value
		observations.app_sets = (observations.app_sets or 0) + 1
		if options.on_apps_set then options.on_apps_set(observations) end
		if options.apps_setter_throws and observations.app_sets == 1 then error("app setter failed") end
	end
	keystats[filter.setter] = function(value)
		observations.setter_values[#observations.setter_values + 1] = value
		observations.runtime = value
		if options.setter_throws and #observations.setter_values == 1 then
			error("FILTER_SETTER_THROW")
		end
	end

	local captured_commands
	package.loaded["hs.fs"] = {}
	package.loaded["apps.engine.picker"] = { build_menu = function(_, on_change)
		observations.change_apps = on_change
		return {}
	end }
	package.loaded["core.ui.engine.dialog_util"] = {}
	package.loaded["core.i18n.engine.i18n"] = { get = function(key) return key end }
	package.loaded["core.logger.engine.logger"] = {
		error = function(_, message, ...)
			observations.errors[#observations.errors + 1] = string.format(message, ...)
		end,
		warn = function() end,
		done = function() end,
	}
	package.loaded["menu.engine.manifest_menu"] = {
		build = function(_, _, _, _, ctx, providers)
			captured_commands = ctx.commands
			providers.exclude_apps()
			return {}
		end,
		resolve_disabled_when = function() return false end,
	}
	package.loaded["core.text.engine.utils"] = {}
	package.loaded["modules.keystats"] = keystats

	local state = {
		keystats_disabled_apps = {},
		keystats_enabled = false,
		keystats_encrypt = false,
		keystats_float_colors = false,
		keystats_float_graph = false,
		keystats_float_wpm = false,
		keystats_menubar_colors = false,
		keystats_menubar_wpm = false,
		keystats_private_filter_enabled = true,
		keystats_secure_filter_enabled = true,
		keystats_system_auth_filter_enabled = true,
	}
	local MenuMetrics = require("ui.menu.menu_metrics")
	MenuMetrics.build({
		state = state,
		save_prefs = function()
			observations.saves = observations.saves + 1
			if options.save_throws then error("FILTER_SAVE_THROW") end
			return options.save_result ~= false
		end,
		updateMenu = function()
			observations.updates = observations.updates + 1
			return true
		end,
	})

	local ok, result = xpcall(captured_commands[filter.command], debug.traceback)
	local callback_ok, callback_err = xpcall(function()
		callback(ok, result, state, observations)
	end, debug.traceback)
	for _, name in ipairs(MODULES) do package.loaded[name] = saved[name] end
	if not callback_ok then error(callback_err, 0) end
end

helpers.describe("menu_metrics filter toggles are transactional", function()
	helpers.it("restores the excluded-app privacy list when saving fails", function()
		with_filter(FILTERS[1], { save_result = false }, function(_, _, state, observations)
			local original = state.keystats_disabled_apps
			local candidate = { { name = "Private", appPath = "/Applications/Private.app" } }
			helpers.assert_eq(observations.change_apps(candidate), false)
			helpers.assert_true(rawequal(state.keystats_disabled_apps, original), "failed save must restore menu state")
			helpers.assert_true(rawequal(observations.apps, original), "failed save must restore the runtime filter")
		end)
	end)
	helpers.it("restores the excluded-app list after a runtime setter raises", function()
		with_filter(FILTERS[1], { apps_setter_throws = true }, function(_, _, state, observations)
			local original, before_saves = state.keystats_disabled_apps, observations.saves
			helpers.assert_eq(observations.change_apps({ { name = "Private" } }), false)
			helpers.assert_true(rawequal(state.keystats_disabled_apps, original))
			helpers.assert_true(rawequal(observations.apps, original))
			helpers.assert_eq(observations.saves, before_saves)
		end)
	end)
	helpers.it("rejects a reentrant excluded-app update while publishing another", function()
		local nested
		with_filter(FILTERS[1], { on_apps_set = function(observations)
			nested = observations.change_apps({ { name = "Nested" } })
		end }, function(_, _, state, observations)
			local candidate = { { name = "Original" } }
			helpers.assert_true(observations.change_apps(candidate))
			helpers.assert_eq(nested, false)
			helpers.assert_true(rawequal(state.keystats_disabled_apps, candidate))
			helpers.assert_true(rawequal(observations.apps, candidate))
		end)
	end)
	for _, filter in ipairs(FILTERS) do
		helpers.it(filter.command .. " compensates a setter that mutates then raises", function()
			with_filter(filter, { setter_throws = true }, function(ok, result, state, observations)
				helpers.assert_eq(ok, true)
				helpers.assert_eq(result, false)
				helpers.assert_eq(state[filter.field], true)
				helpers.assert_eq(observations.runtime, true)
				helpers.assert_eq(#observations.setter_values, 2)
				helpers.assert_eq(observations.setter_values[1], false)
				helpers.assert_eq(observations.setter_values[2], true)
				helpers.assert_eq(observations.saves, 0)
				helpers.assert_eq(observations.updates, 1)
				helpers.assert_true(#observations.errors >= 1)
			end)
		end)

		helpers.it(filter.command .. " restores runtime and state when persistence refuses", function()
			with_filter(filter, { save_result = false }, function(ok, result, state, observations)
				helpers.assert_eq(ok, true)
				helpers.assert_eq(result, false)
				helpers.assert_eq(state[filter.field], true)
				helpers.assert_eq(observations.runtime, true)
				helpers.assert_eq(#observations.setter_values, 2)
				helpers.assert_eq(observations.setter_values[1], false)
				helpers.assert_eq(observations.setter_values[2], true)
				helpers.assert_eq(observations.saves, 1)
				helpers.assert_eq(observations.updates, 1)
				helpers.assert_true(#observations.errors >= 1)
			end)
		end)

		helpers.it(filter.command .. " commits all three surfaces together", function()
			with_filter(filter, {}, function(ok, result, state, observations)
				helpers.assert_eq(ok, true)
				helpers.assert_eq(result, true)
				helpers.assert_eq(state[filter.field], false)
				helpers.assert_eq(observations.runtime, false)
				helpers.assert_eq(#observations.setter_values, 1)
				helpers.assert_eq(observations.saves, 1)
				helpers.assert_eq(observations.updates, 1)
				helpers.assert_eq(#observations.errors, 0)
			end)
		end)
	end

	helpers.it("contains a persistence exception and restores the private filter", function()
		with_filter(FILTERS[1], { save_throws = true }, function(ok, result, state, observations)
			helpers.assert_eq(ok, true)
			helpers.assert_eq(result, false)
			helpers.assert_eq(state.keystats_private_filter_enabled, true)
			helpers.assert_eq(observations.runtime, true)
			helpers.assert_eq(observations.setter_values[2], true)
			helpers.assert_eq(observations.updates, 1)
		end)
	end)
end)
