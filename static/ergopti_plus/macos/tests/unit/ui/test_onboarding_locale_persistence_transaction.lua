--- tests/unit/ui/test_onboarding_locale_persistence_transaction.lua

--- ==============================================================================
--- MODULE: Onboarding Locale Persistence Transaction Tests
--- DESCRIPTION:
--- Drives the real onboarding finish-message handler with controlled persistence
--- boundaries. A locale write refusal must stop config publication, completion,
--- notification, and reload scheduling instead of vanishing inside a bare pcall.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ======================================
-- ======================================
-- ======= 1/ Production Fixture ========
-- ======================================
-- ======================================

local MODULE_NAMES = {
	"adapters.file_system",
	"adapters.storage",
	"infra.deferred_work",
	"infra.dialog_util",
	"infra.i18n",
	"infra.logger",
	"infra.manifest_reader",
	"infra.notifications",
	"infra.paths",
	"infra.text_utils",
	"infra.toml.codec",
	"infra.toml.writer",
	"ui.onboarding",
}

--- Returns one named upvalue and its numeric slot.
--- @param fn function
--- @param target string
--- @return any value
--- @return integer|nil index
local function named_upvalue(fn, target)
	for index = 1, 100 do
		local name, value = debug.getupvalue(fn, index)
		if name == nil then break end
		if name == target then return value, index end
	end
	return nil, nil
end

--- Runs the real finish handler with one controlled locale persistence outcome.
--- @param mode string true|false|nil|throw
--- @param scenario function
local function with_fixture(mode, scenario)
	local saved = {}
	for _, name in ipairs(MODULE_NAMES) do
		saved[name] = package.loaded[name]
		package.loaded[name] = nil
	end

	local state = {
		alerts = {},
		completed = 0,
		deferred = 0,
		locale_persists = 0,
		locale_switches = 0,
		notifications = 0,
		writes = 0,
	}
	local function noop() end
	package.loaded["infra.logger"] = setmetatable({}, { __index = function() return noop end })
	package.loaded["infra.paths"] = { shared = function() return "/tmp/shared" end }
	package.loaded["infra.text_utils"] = { applescript_format = string.format }
	package.loaded["infra.manifest_reader"] = { default_for = function() return "★" end }
	package.loaded["infra.toml.codec"] = { decode = function() return {} end }
	package.loaded["adapters.file_system"] = {
		read_with_status = function() return nil, "absent" end,
	}
	package.loaded["infra.toml.writer"] = {
		batch_write = function()
			state.writes = state.writes + 1
			return true
		end,
	}
	package.loaded["adapters.storage"] = {
		set = function(key)
			if key == "onboarding.completed" then state.completed = state.completed + 1 end
			return true
		end,
	}
	package.loaded["infra.notifications"] = {
		notify = function() state.notifications = state.notifications + 1; return true end,
	}
	package.loaded["infra.deferred_work"] = {
		after = function()
			state.deferred = state.deferred + 1
			return true
		end,
	}
	package.loaded["infra.dialog_util"] = {
		block_alert = function(title, body, button)
			state.alerts[#state.alerts + 1] = { title = title, body = body, button = button }
			return true
		end,
	}
	package.loaded["infra.i18n"] = {
		get = function(key) return key end,
		set_locale_no_reload = function()
			state.locale_switches = state.locale_switches + 1
			return true
		end,
		persist_locale = function()
			state.locale_persists = state.locale_persists + 1
			if mode == "throw" then error("injected locale persistence failure") end
			if mode == "nil" then return nil end
			return mode == "true"
		end,
	}

	local onboarding = require("ui.onboarding")
	local handle_message = named_upvalue(onboarding.run, "handle_message")
	helpers.assert_type(handle_message, "function",
		"the regression must drive the production onboarding message handler")
	local _, config_path_index = named_upvalue(onboarding.run, "_config_path")
	helpers.assert_not_nil(config_path_index,
		"the fixture must assign the real commit destination upvalue")
	debug.setupvalue(onboarding.run, config_path_index, "/tmp/onboarding-config.toml")

	local ok, err = xpcall(function()
		handle_message({ action = "finish", answers = { locale = "de", magic_key = "★" } })
		scenario(state)
	end, debug.traceback)
	for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end





-- ========================================
-- ========================================
-- ======= 2/ Exact Commit Boundary =======
-- ========================================
-- ========================================

helpers.describe("onboarding locale persistence is a required commit boundary", function()
	helpers.it("stops every success-only side effect on false, nil, and throw", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			with_fixture(mode, function(state)
				helpers.assert_eq(state.locale_switches, 1)
				helpers.assert_eq(state.locale_persists, 1)
				helpers.assert_eq(state.writes, 0,
					mode .. " persistence must stop config publication")
				helpers.assert_eq(state.completed, 0)
				helpers.assert_eq(state.notifications, 0)
				helpers.assert_eq(state.deferred, 0,
					mode .. " persistence must not schedule the final reload")
				helpers.assert_eq(#state.alerts, 1)
				helpers.assert_eq(state.alerts[1].body,
					"onboarding.error.locale_persist_failed")
			end)
		end
	end)

	helpers.it("continues exactly once after an explicit persistence acknowledgement", function()
		with_fixture("true", function(state)
			helpers.assert_eq(state.locale_persists, 1)
			helpers.assert_eq(state.writes, 1)
			helpers.assert_eq(state.completed, 1)
			helpers.assert_eq(state.notifications, 1)
			helpers.assert_eq(state.deferred, 1)
			helpers.assert_eq(#state.alerts, 0)
		end)
	end)
end)
