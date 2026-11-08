--- tests/unit/infra/preferences/test_layout_emulation_preferences_refusal.lua

--- ==============================================================================
--- MODULE: Layout Emulation Preference Refusal
--- DESCRIPTION:
--- The layout emulation rows publish through one direct save_prefs call. A save
--- that answers anything but true must leave every leaf it changed as it was,
--- or the menu would show, and the next save would write, a refused choice.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.layout_emulation_preferences", "infra.preferences", "infra.logger", "logger.shim" }

--- Runs `body` with a fresh writer module and a silent logger.
--- @param body function Receives the writer and the flat key resolver.
local function with_writer(body)
	helpers.with_stub_scope(MODULES, function()
		local logger = helpers.make_logger_stub()
		package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
		package.loaded["infra.layout_emulation_preferences"] = nil
		local writer = require("infra.layout_emulation_preferences")
		local Preferences = require("infra.preferences")
		body(writer, function(path) return assert(Preferences.flat_key_for(path)) end)
	end)
end

local KEY = require("config_keys").KEY

helpers.describe("layout emulation preferences fail closed", function()
	for _, answer in ipairs({ false, "nil", "true" }) do
		local label = answer == "nil" and "nil" or answer == "true" and "the string true" or "false"
		helpers.it("restores a switch the save answered " .. label .. " to", function()
			with_writer(function(writer, flat_key)
				local key = flat_key(KEY.LAYOUT_EMULATE_TOP_ROW)
				local state, saves = { [key] = false }, 0
				local committed = writer.set_switch(state, function()
					saves = saves + 1
					if answer == "nil" then return nil end
					return answer
				end, KEY.LAYOUT_EMULATE_TOP_ROW, true)
				helpers.assert_eq(committed, false)
				helpers.assert_eq(saves, 1)
				helpers.assert_eq(state[key], false)
			end)
		end)
	end

	helpers.it("restores every leaf of a refused layout choice, absent ones included", function()
		with_writer(function(writer, flat_key)
			local base, variant = flat_key(KEY.LAYOUT_ERGOPTI_BASE), flat_key(KEY.LAYOUT_ERGOPTI_VARIANT)
			local state = { [base] = false }
			local committed = writer.choose(state, function() return false end, "ergopti")
			helpers.assert_eq(committed, false)
			helpers.assert_eq(state[base], false)
			helpers.assert_eq(rawget(state, variant), nil)
		end)
	end)

	helpers.it("keeps the choice once the save acknowledges it exactly", function()
		with_writer(function(writer, flat_key)
			local key = flat_key(KEY.LAYOUT_EMULATE_TOP_ROW)
			local state = { [key] = false }
			helpers.assert_eq(writer.set_switch(state, function() return true end, KEY.LAYOUT_EMULATE_TOP_ROW, true), true)
			helpers.assert_eq(state[key], true)
		end)
	end)
end)
