--- tests/unit/ui/menu/menu_llm/test_settings_numeric_validation_feedback.lua

--- ==============================================================================
--- MODULE: LLM Numeric Setting Validation Feedback
--- DESCRIPTION:
--- Ensures every numeric prompt reports rejected input to the user before
--- returning, without mutating runtime or persisted settings.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"adapters.storage",
	"infra.dialog_util",
	"infra.i18n",
	"infra.logger",
	"infra.notifications",
	"modules.llm",
	"modules.llm.api_mlx",
	"ui.menu.menu_llm.settings_manager",
}

--- Runs one settings-manager fixture with isolated module dependencies.
--- @param raw string Prompt result.
--- @param callback function Receives the manager and observation state.
local function with_fixture(raw, callback)
	local saved = {}
	for _, name in ipairs(MODULES) do
		saved[name] = package.loaded[name]
		package.loaded[name] = nil
	end

	local observations = {
		applications = {},
		notifications = {},
		port_sets = 0,
	}
	package.loaded["modules.llm"] = {
		DEFAULT_STATE = {
			llm_context_length = 1500,
			llm_debounce = 0.35,
			llm_max_words = 20,
			llm_min_words = 4,
			llm_temperature = 0.1,
		},
	}
	package.loaded["modules.llm.api_mlx"] = {
		get_default_port = function() return 8081 end,
		get_port = function() return 8081 end,
		get_port_bounds = function() return 1024, 65535 end,
		set_port = function()
			observations.port_sets = observations.port_sets + 1
			return true
		end,
	}
	package.loaded["adapters.storage"] = {
		delete_exact = function() return true end,
		get = function() return nil end,
		read_exact = function() return true, nil end,
		set = function() return true end,
	}
	package.loaded["infra.dialog_util"] = {
		text_prompt = function() return "button.ok", raw end,
	}
	package.loaded["infra.i18n"] = {
		get = function(key) return key end,
	}
	package.loaded["infra.logger"] = {
		callback = function(_, _, fn, ...)
			local results = table.pack(xpcall(fn, debug.traceback, ...))
			return table.unpack(results, 1, results.n)
		end,
		debug = function() end,
		error = function() end,
		info = function() end,
		warn = function() end,
	}
	package.loaded["infra.notifications"] = {
		notify = function(title, body, kind)
			observations.notifications[#observations.notifications + 1] = {
				title = title,
				body = body,
				kind = kind,
			}
			return true
		end,
	}

	local Settings = require("ui.menu.menu_llm.settings_manager")
	local manager = Settings.new({
		state = {
			llm_context_length = 300,
			llm_debounce = 0.5,
			llm_max_words = 7,
			llm_min_words = 2,
			llm_temperature = 0.2,
		},
		keymap = {},
		save_prefs = function() return true end,
		update_menu = function() return true end,
	})
	manager.apply_setting_transaction = function(options)
		observations.applications[#observations.applications + 1] = options
		return true
	end

	local ok, err = xpcall(function()
		callback(manager, observations)
	end, debug.traceback)
	for _, name in ipairs(MODULES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

local INVALID_ROUTES = {
	{
		name = "temperature decimal comma",
		raw = "0,8",
		title = "menu.settings.temperature_title",
		invoke = function(manager) return manager.set_temperature() end,
	},
	{
		name = "context length garbage",
		raw = "garbage",
		title = "menu.settings.context_length_title",
		invoke = function(manager) return manager.set_context_length() end,
	},
	{
		name = "debounce garbage",
		raw = "garbage",
		title = "menu.settings.delay_title",
		invoke = function(manager) return manager.set_debounce() end,
	},
	{
		name = "debounce overflow",
		raw = "1e999",
		title = "menu.settings.delay_title",
		body = "numeric_prompt.out_of_range",
		invoke = function(manager) return manager.set_debounce() end,
	},
	{
		name = "unsupported negative debounce",
		raw = "-2",
		title = "menu.settings.delay_title",
		body = "numeric_prompt.out_of_range",
		invoke = function(manager) return manager.set_debounce() end,
	},
	{
		name = "fractional maximum word count",
		raw = "1.5",
		title = "menu.settings.max_words_title",
		invoke = function(manager) return manager.set_max_words() end,
	},
	{
		name = "negative minimum word count",
		raw = "-2",
		title = "menu.settings.min_words_title",
		invoke = function(manager) return manager.set_min_words() end,
	},
	{
		name = "MLX port garbage",
		raw = "garbage",
		title = "menu.llm.mlx_port_title",
		invoke = function(manager) return manager.set_mlx_port() end,
	},
	{
		name = "MLX port outside its range",
		raw = "70000",
		title = "menu.llm.mlx_port_title",
		body = "numeric_prompt.out_of_range",
		invoke = function(manager) return manager.set_mlx_port() end,
	},
}

helpers.describe("settings_manager numeric validation feedback", function()
	for _, route in ipairs(INVALID_ROUTES) do
		helpers.it("reports " .. route.name .. " without mutating settings", function()
			with_fixture(route.raw, function(manager, observations)
				local result = route.invoke(manager)
				helpers.assert_eq(#observations.applications, 0)
				helpers.assert_eq(observations.port_sets, 0)
				helpers.assert_eq(#observations.notifications, 1)
				helpers.assert_eq(observations.notifications[1].title, route.title)
				helpers.assert_eq(observations.notifications[1].body,
					route.body or "numeric_prompt.not_a_number")
				helpers.assert_eq(observations.notifications[1].kind, "warning")
				helpers.assert_eq(result, false)
			end)
		end)
	end

	helpers.it("keeps valid temperature input on the mutation path without a warning", function()
		with_fixture("0.75", function(manager, observations)
			helpers.assert_eq(manager.set_temperature(), true)
			helpers.assert_eq(#observations.applications, 1)
			helpers.assert_eq(observations.applications[1].key, "llm_temperature")
			helpers.assert_eq(observations.applications[1].value, 0.75)
			helpers.assert_eq(#observations.notifications, 0)
		end)
	end)
end)
