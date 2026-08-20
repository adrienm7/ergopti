--- tests/meta/test_menu_preference_calls_fail_closed.lua

--- ==============================================================================
--- MODULE: Menu Preference Call-Site Transaction Guard
--- DESCRIPTION:
--- Enumerates the full class of menu persistence calls. Every direct call must
--- test the exact true result before success-only effects. A protected call is
--- accepted only when it preserves and checks both pcall status and the writer's
--- exact result; discarding either value would turn false or a throw into success.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("menu preference call sites fail closed", function()
	helpers.it("guards every save_prefs call with exact success", function()
		local source = helpers.read_driver_source("save_prefs(")
		helpers.assert_type(source, "string")
		source = source:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")

		local calls, guarded = 0, 0
		local unguarded = {}
		local lines = {}
		for line in source:gmatch("[^\n]+") do lines[#lines + 1] = line end
		for index, line in ipairs(lines) do
			if line:match("pcall%s*%(%s*[%w_%.]*save_prefs%s*%)") then
				calls = calls + 1
				local status_name, result_name = line:match(
					"local%s+([%w_]+)%s*,%s*([%w_]+)%s*=%s*pcall%s*%(%s*[%w_%.]*save_prefs%s*%)")
				local guard = lines[index + 1] or ""
				if status_name and result_name
					and guard:match("if%s+not%s+" .. status_name .. "%s+or%s+"
						.. result_name .. "%s*~=%s*true%s+then") then
					guarded = guarded + 1
				else
					unguarded[#unguarded + 1] = line .. " || " .. guard
				end
			elseif line:match("[%w_%.]*save_prefs%s*%(%s*%)")
				and not line:match("local%s+function%s+save_prefs")
				and not line:match("return%s+transactional_save_prefs") then
				calls = calls + 1
				if line:match("save_prefs%s*%(%s*%)%s*~=%s*true%s+then") then
					guarded = guarded + 1
				elseif line:match("local%s+[%w_]+%s*=%s*[%w_%.]*save_prefs%s*%(%s*%)%s*==%s*true") then
					guarded = guarded + 1
				else
					unguarded[#unguarded + 1] = line
				end
			end
		end

		helpers.assert_true(calls >= 100,
			"the class scan must enumerate the large sibling set, not a token sample")
		helpers.assert_eq(guarded, calls,
			"every menu preference writer must stop success-only effects on false, nil, or throw; unguarded: "
				.. table.concat(unguarded, " | "))
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
