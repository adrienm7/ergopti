--- tests/unit/modules/keymap/test_repeat_feature_arm_time.lua

--- ==============================================================================
--- MODULE: try_repeat_feature arm time regression test
--- DESCRIPTION:
--- Guards against the regression where try_repeat_feature() set
--- expected_synthetic_chars but did not update last_synthetic_arm_time.
---
--- The stuck-counter reset guard in onKeyDownRaw wipes expected_synthetic_chars
--- when more than 0.5 s have elapsed since last_synthetic_arm_time. If
--- try_repeat_feature arms the counter but leaves last_synthetic_arm_time stale
--- (e.g. it was set by a previous expansion 2 s ago), the next key event fires
--- the reset guard and wipes the counter before the repeated char echo arrives —
--- corrupting the keymap buffer.
---
--- Fix: try_repeat_feature now updates last_synthetic_arm_time immediately after
--- setting expected_synthetic_chars, matching the pattern in perform_text_replacement.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_source(rel)
	local fh = io.open(helpers.driver_root() .. rel, "r")
	assert(fh, "cannot open " .. rel)
	local src = fh:read("*a")
	fh:close()
	return src
end

local function strip_comments(src)
	local out = {}
	for line in src:gmatch("[^\n]*") do
		if not line:match("^%s*%-%-") then out[#out + 1] = line end
	end
	return table.concat(out, "\n")
end





-- ======================================================================
-- =====================================================================
-- ======= 1/ try_repeat_feature updates last_synthetic_arm_time =======
-- =====================================================================
-- ======================================================================

helpers.describe("keymap/expander.lua: try_repeat_feature arm time", function()

	helpers.it("try_repeat_feature updates last_synthetic_arm_time after arming", function()
		local src = strip_comments(read_source("modules/keymap/expander.lua"))

		-- Locate try_repeat_feature function body
		local fn_start = src:find("function M%.try_repeat_feature")
		helpers.assert_true(fn_start ~= nil, "try_repeat_feature must exist in expander.lua")

		-- After the function definition, last_synthetic_arm_time must be set
		local after_fn = src:sub(fn_start)
		helpers.assert_true(
			after_fn:find("last_synthetic_arm_time%s*=%s*hs%.timer%.secondsSinceEpoch") ~= nil,
			"try_repeat_feature must update last_synthetic_arm_time after arming expected_synthetic_chars")
	end)

	helpers.it("last_synthetic_arm_time is set AFTER expected_synthetic_chars in try_repeat_feature", function()
		local src = strip_comments(read_source("modules/keymap/expander.lua"))
		local fn_start = src:find("function M%.try_repeat_feature")
		helpers.assert_true(fn_start ~= nil)
		local after_fn = src:sub(fn_start)

		local chars_pos = after_fn:find("expected_synthetic_chars")
		local arm_pos   = after_fn:find("last_synthetic_arm_time")
		helpers.assert_true(chars_pos ~= nil and arm_pos ~= nil,
			"both expected_synthetic_chars and last_synthetic_arm_time must be set")
		helpers.assert_true(chars_pos < arm_pos,
			"last_synthetic_arm_time must be set after expected_synthetic_chars")
	end)

end)
