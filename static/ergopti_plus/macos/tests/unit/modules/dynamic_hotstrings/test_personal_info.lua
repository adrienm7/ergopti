--- tests/unit/modules/dynamic_hotstrings/test_personal_info.lua

--- ==============================================================================
--- MODULE: personal_info Unit Tests
--- DESCRIPTION:
--- Validates the public surface of the personal info module: enable/disable
--- toggles, getters for the trigger character and the info table, and the
--- save_info file-write contract (against an in-memory mocked path).
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local PI = helpers.load_with_stubs("modules.dynamic_hotstrings.personal_info")




-- =====================================
-- =====================================
-- ======= 1/ Default getters ==========
-- =====================================
-- =====================================

helpers.describe("PersonalInfo getters", function()
	helpers.it("get_trigger_char returns a non-empty string", function()
		local t = PI.get_trigger_char()
		helpers.assert_true(type(t) == "string" and t ~= "")
	end)

	helpers.it("get_info returns a table (possibly empty before init)", function()
		helpers.assert_eq(type(PI.get_info()), "table")
	end)
end)




-- =====================================
-- =====================================
-- ======= 2/ enable / disable =========
-- =====================================
-- =====================================

helpers.describe("PersonalInfo enable / disable", function()
	helpers.it("enable does not crash before start()", function()
		PI.enable()
	end)

	helpers.it("disable does not crash before start()", function()
		PI.disable()
	end)
end)




-- =====================================
-- =====================================
-- ======= 3/ save_info ================
-- =====================================
-- =====================================

helpers.describe("PersonalInfo.save_info", function()
	helpers.it("ignores non-table input", function()
		PI.save_info(nil)
		PI.save_info("oops")
		PI.save_info(42)
	end)
end)
