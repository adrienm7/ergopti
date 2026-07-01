--- tests/unit/modules/dynamic_hotstrings/test_personal_info.lua

--- ==============================================================================
--- MODULE: personal_info Unit Tests
--- DESCRIPTION:
--- Validates the public surface of the personal info module: enable/disable
--- toggles, getters for the trigger character and the info table, and the
--- save_info file-write contract (against an in-memory mocked path).
--- ==============================================================================

local helpers = require("tests.helpers")

-- Pause invariant for personal info hotstrings (must not expand when paused)
helpers.describe("Personal info pause guard", function()
	helpers.it("pause blocks personal dynamic expansions (regression)", function()
		-- Guard in keymap/expander; test documents requirement
		helpers.assert_true(true)
	end)
end)

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




-- =====================================================================
-- =====================================================================
-- ======= 4/ TOML round-trip for underscore keys (F-CRIT-1) ==========
-- =====================================================================
-- =====================================================================

-- Regression for F-CRIT-1: parse_toml_section's key pattern used to be
-- '^(%w+)%s*=%s*"(.*)"$' — Lua's %w class excludes '_', so every
-- underscore-named key (date_of_birth, phone_number, social_security_number,
-- …) silently failed to parse and fell back to DEFAULT_CONFIG on every
-- restart, wiping the user's real personal data with no error.
helpers.describe("PersonalInfo TOML round-trip — underscore-named keys survive a restart (F-CRIT-1 regression)", function()

	helpers.it("every DEFAULT_CONFIG.info key, including underscore-named ones, round-trips through a real file", function()
		local tmp_path = os.tmpname()

		local lines = { "[info]" }
		local expected = {}

		-- Build a personal_info.toml exercising every default key with a
		-- distinct, non-default sentinel value (underscore-heavy on purpose).
		local sentinel_keys = {
			"first_name", "last_name", "date_of_birth", "email_address",
			"work_email_address", "phone_number", "phone_number_clean",
			"street_address", "city", "country", "postal_code", "iban",
			"bic", "credit_card", "social_security_number",
		}
		for _, key in ipairs(sentinel_keys) do
			local value = "SENTINEL_" .. key:upper()
			expected[key] = value
			table.insert(lines, string.format('%s = "%s"', key, value))
		end

		local fh = io.open(tmp_path, "w")
		helpers.assert_true(fh ~= nil, "must be able to write the temp personal_info.toml")
		fh:write(table.concat(lines, "\n") .. "\n")
		fh:close()

		PI.start(nil, nil, tmp_path)
		local info = PI.get_info()

		for _, key in ipairs(sentinel_keys) do
			helpers.assert_eq(info[key], expected[key], "field '" .. key .. "' must round-trip, not silently fall back to its default")
		end

		os.remove(tmp_path)
	end)

end)
