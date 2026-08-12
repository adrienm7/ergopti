--- tests/meta/test_menu_preference_calls_fail_closed.lua

--- ==============================================================================
--- MODULE: Menu Preference Call-Site Transaction Guard
--- DESCRIPTION:
--- Enumerates the full class of menu persistence calls. Every call must test the
--- exact true result and return before any success-only effects; pcall wrappers
--- are forbidden because they discard the writer's false result.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu preference call sites fail closed", function()
	helpers.it("guards every save_prefs call with exact success", function()
		local source = helpers.read_driver_source("save_prefs(")
		helpers.assert_type(source, "string")
		source = source:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")

		helpers.assert_nil(source:match("pcall%s*%(%s*[%w_%.]*save_prefs"),
			"save_prefs must expose false to its caller, never be discarded by pcall")

		local calls, guarded = 0, 0
		for line in source:gmatch("[^\n]+") do
			if line:match("[%w_%.]*save_prefs%s*%(%s*%)")
				and not line:match("local%s+function%s+save_prefs")
				and not line:match("return%s+transactional_save_prefs") then
				calls = calls + 1
				if line:match("save_prefs%s*%(%s*%)%s*~=%s*true%s+then") then
					guarded = guarded + 1
				end
			end
		end

		helpers.assert_true(calls >= 100,
			"the class scan must enumerate the large sibling set, not a token sample")
		helpers.assert_eq(guarded, calls,
			"every menu preference writer must stop success-only effects on non-true save")
	end)

	helpers.it("restores core backend identity before keymap warmup setters", function()
		local source, err = helpers.read_driver_unit("Restore the backend/profile/model identity")
		helpers.assert_not_nil(source, err)
		local backend = source:find('fn = "set_backend"', 1, true)
		local keymap = source:find('fn = "set_llm_enabled"', 1, true)
		helpers.assert_true(backend ~= nil and keymap ~= nil and backend < keymap,
			"rollback must restore the core backend before keymap setters can schedule warmup")
	end)
end)

return true
