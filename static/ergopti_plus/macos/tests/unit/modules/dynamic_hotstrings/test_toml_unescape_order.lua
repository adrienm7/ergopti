--- tests/unit/modules/dynamic_hotstrings/test_toml_unescape_order.lua

--- ==============================================================================
--- MODULE: TOML unescape order regression tests
--- DESCRIPTION:
--- Regression for dynhotstrings-2: the chained-gsub unescape in
--- personal_info.lua and hotstrings_config.lua processed \\n as newline because
--- the \n → newline pass ran BEFORE the \\ → \ pass, so a TOML value of \\n
--- (backslash followed by n) was incorrectly decoded as a newline character.
--- The fix uses a single-pass \\(.) → replacement-function pass instead.
---
--- FEATURES & RATIONALE:
--- 1. Source Invariant (personal_info): verifies the buggy chained gsub is
---    absent and the single-pass pattern is present.
--- 2. Source Invariant (hotstrings_config): same check for the word_delimiters
---    unescape path.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ========================================================================================
-- ========================================================================================
-- ======= 1/ personal_info parse_toml_section unescape order (dynhotstrings-2) ==========
-- ========================================================================================
-- ========================================================================================

helpers.describe("personal_info.lua TOML unescape — single-pass pattern (dynhotstrings-2 regression)", function()

	helpers.it("does NOT use the chained gsub that corrupts \\\\n sequences", function()
		-- Selected by a declaration unique to modules/dynamic_hotstrings/personal_info.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function parse_toml_section")
		helpers.assert_true(src ~= nil, "modules/dynamic_hotstrings/personal_info.lua source must be locatable")

		-- The buggy pattern: \\n replacement runs before \\\\ replacement.
		-- If this pattern is present it will corrupt any TOML value containing \\n
		-- (e.g. a Windows path "C:\\new" → "C:\<newline>ew").
		local has_buggy = src:find('gsub("\\\\n"', 1, true) ~= nil
		helpers.assert_true(
			not has_buggy,
			"personal_info.lua must NOT use chained gsub starting with the \\n replacement — "
			.. "it corrupts \\\\n in TOML values (dynhotstrings-2)"
		)
	end)

	helpers.it("uses the single-pass \\\\(.) replacement-function pattern", function()
		-- Selected by a declaration unique to modules/dynamic_hotstrings/personal_info.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function parse_toml_section")
		helpers.assert_true(src ~= nil, "modules/dynamic_hotstrings/personal_info.lua source must be locatable")

		-- The correct pattern processes all escape sequences in one left-to-right pass
		-- so \\n is seen as (\\)(n) → backslash + n, not as the two-char sequence matched
		-- by an earlier \\n → newline substitution.
		local has_single_pass = src:find("gsub('\\\\(.)'", 1, true) ~= nil
		helpers.assert_true(
			has_single_pass,
			"personal_info.lua must use gsub('\\\\.', fn) for single-pass TOML unescape"
		)
	end)

end)




-- ==========================================================================================
-- ==========================================================================================
-- ======= 2/ hotstrings_config word_delimiters unescape order (dynhotstrings-2) ===========
-- ==========================================================================================
-- ==========================================================================================

helpers.describe("hotstrings_config.lua word_delimiters unescape — single-pass (dynhotstrings-2 regression)", function()

	helpers.it("does NOT use the chained gsub that corrupts \\\\n in word_delimiters", function()
		-- Selected by a declaration unique to modules/hotstrings/hotstrings_config.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("function M.get_global_default_delay_ms")
		helpers.assert_true(src ~= nil, "modules/hotstrings/hotstrings_config.lua source must be locatable")

		-- Find the word_delimiters unescape context (inside parse_overrides).
		-- The buggy code had:  wd:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub("\\\\", "\\")
		-- We check that the chained form is absent from the word_delimiters path.
		local has_buggy = src:find('wd:gsub("\\\\n"', 1, true) ~= nil
		helpers.assert_true(
			not has_buggy,
			"hotstrings_config.lua must NOT use chained gsub for word_delimiters unescape (dynhotstrings-2)"
		)
	end)

	helpers.it("uses the single-pass \\\\(.) replacement-function for word_delimiters", function()
		-- Selected by a declaration unique to modules/hotstrings/hotstrings_config.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("function M.get_global_default_delay_ms")
		helpers.assert_true(src ~= nil, "modules/hotstrings/hotstrings_config.lua source must be locatable")

		local has_single_pass = src:find("gsub('\\\\(.)'", 1, true) ~= nil
		helpers.assert_true(
			has_single_pass,
			"hotstrings_config.lua must use gsub('\\\\.', fn) for single-pass TOML unescape"
		)
	end)

end)
