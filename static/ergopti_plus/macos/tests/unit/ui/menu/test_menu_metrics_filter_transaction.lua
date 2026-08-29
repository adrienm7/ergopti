--- tests/unit/ui/menu/test_menu_metrics_filter_transaction.lua

--- ==============================================================================
--- MODULE: Metrics Filter Toggle Transaction
--- DESCRIPTION:
--- Proves that the private, secure-field, and system-auth filter rows keep the
--- menu state, runtime filter, and persisted preferences on one outcome.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"hs.fs",
	"infra.app_picker",
	"infra.dialog_util",
	"infra.i18n",
	"infra.logger",
	"infra.manifest_menu",
	"infra.text_utils",
	"modules.keylogger",
	"ui.menu.menu_metrics",
}

local FILTERS = {
	{
		command = "filter_private",
		field = "keylogger_private_filter_enabled",
		setter = "set_private_filter_enabled",
	},
	{
		command = "filter_secure",
		field = "keylogger_secure_filter_enabled",
		setter = "set_secure_field_filter_enabled",
	},
	{
		command = "filter_sysauth",
		field = "keylogger_system_auth_filter_enabled",
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
	local keylogger = {
		DEFAULT_STATE = {
			keylogger_disabled_apps = {},
			keylogger_enabled = false,
			keylogger_encrypt = false,
			keylogger_float_colors = false,
			keylogger_float_graph = false,
			keylogger_float_wpm = false,
			keylogger_menubar_colors = false,
			keylogger_menubar_wpm = false,
			keylogger_private_filter_enabled = true,
			keylogger_secure_filter_enabled = true,
			keylogger_system_auth_filter_enabled = true,
		},
	}
	keylogger[filter.setter] = function(value)
		observations.setter_values[#observations.setter_values + 1] = value
		observations.runtime = value
		if options.setter_throws and #observations.setter_values == 1 then
			error("FILTER_SETTER_THROW")
		end
	end

	local captured_commands
	package.loaded["hs.fs"] = {}
	package.loaded["infra.app_picker"] = { build_menu = function() return {} end }
	package.loaded["infra.dialog_util"] = {}
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.logger"] = {
		error = function(_, message, ...)
			observations.errors[#observations.errors + 1] = string.format(message, ...)
		end,
		warn = function() end,
	}
	package.loaded["infra.manifest_menu"] = {
		build = function(_, _, _, _, ctx)
			captured_commands = ctx.commands
			return {}
		end,
		resolve_disabled_when = function() return false end,
	}
	package.loaded["infra.text_utils"] = {}
	package.loaded["modules.keylogger"] = keylogger

	local state = {
		keylogger_disabled_apps = {},
		keylogger_enabled = false,
		keylogger_encrypt = false,
		keylogger_float_colors = false,
		keylogger_float_graph = false,
		keylogger_float_wpm = false,
		keylogger_menubar_colors = false,
		keylogger_menubar_wpm = false,
		keylogger_private_filter_enabled = true,
		keylogger_secure_filter_enabled = true,
		keylogger_system_auth_filter_enabled = true,
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
			helpers.assert_eq(state.keylogger_private_filter_enabled, true)
			helpers.assert_eq(observations.runtime, true)
			helpers.assert_eq(observations.setter_values[2], true)
			helpers.assert_eq(observations.updates, 1)
		end)
	end)
end)
