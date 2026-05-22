--- tests/unit/modules/keymap/test_state.lua

--- ==============================================================================
--- MODULE: keymap.state Unit Tests
--- DESCRIPTION:
--- Validates the CoreState factory: required fields, seeded defaults from the
--- supplied DEFAULT_STATE / DELAYS_DEFAULT tables, the bound suppress_rescan
--- closures, and the WORD_TIMEOUT_SEC computation rule.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local State = helpers.load_with_stubs("modules.keymap.state")

local function make_defaults()
	return {
		trigger_char    = "★",
		expansion_delay = 0.4,
	}
end




-- =====================================
--- ======================================
-- ======= 1/ Argument Validation =======
--- ======================================
-- =====================================

helpers.describe("State.new: argument validation", function()
	helpers.it("errors when defaults is not a table", function()
		local ok = pcall(State.new, "oops", {})
		helpers.assert_eq(ok, false)
	end)

	helpers.it("errors when delays_default is not a table", function()
		local ok = pcall(State.new, make_defaults(), "oops")
		helpers.assert_eq(ok, false)
	end)
end)




-- =====================================
-- =====================================
-- ======= 2/ Seeded fields =============
-- =====================================
-- =====================================

helpers.describe("State.new: seeded fields", function()
	helpers.it("seeds the magic_key from defaults", function()
		local s = State.new(make_defaults(), { autocorrection = 0.3 })
		helpers.assert_eq(s.magic_key, "★")
	end)

	helpers.it("seeds BASE_DELAY_SEC from defaults", function()
		local s = State.new(make_defaults(), { autocorrection = 0.3 })
		helpers.assert_eq(s.BASE_DELAY_SEC, 0.4)
	end)

	helpers.it("starts with empty buffer and zero counters", function()
		local s = State.new(make_defaults(), { autocorrection = 0.3 })
		helpers.assert_eq(s.buffer, "")
		helpers.assert_eq(s.seq_counter, 0)
		helpers.assert_eq(s.expected_synthetic_chars, "")
		helpers.assert_eq(s.expected_synthetic_deletes, 0)
	end)

	helpers.it("creates empty mapping containers", function()
		local s = State.new(make_defaults(), { autocorrection = 0.3 })
		helpers.assert_eq(#s.mappings, 0)
		helpers.assert_eq(next(s.mappings_lookup), nil)
		helpers.assert_eq(next(s.mappings_by_tail_char), nil)
		helpers.assert_eq(next(s.mappings_by_star_tail_char), nil)
	end)
end)




-- =====================================
-- =====================================
-- ======= 3/ Delay seeding =============
-- =====================================
-- =====================================

helpers.describe("State.new: delays and word timeout", function()
	helpers.it("copies all delays from defaults", function()
		local s = State.new(make_defaults(), { autocorrection = 0.3, dynamichotstrings = 0.4 })
		helpers.assert_eq(s.DELAYS.autocorrection, 0.3)
		helpers.assert_eq(s.DELAYS.dynamichotstrings, 0.4)
	end)

	helpers.it("computes WORD_TIMEOUT_SEC = max_delay + 0.5", function()
		local s = State.new(make_defaults(), { a = 0.3, b = 0.4 })
		helpers.assert_eq(s.WORD_TIMEOUT_SEC, 0.9)
	end)

	helpers.it("uses 0 (infinite) when any delay is 0", function()
		local s = State.new(make_defaults(), { a = 0.3, b = 0 })
		helpers.assert_eq(s.WORD_TIMEOUT_SEC, 0)
	end)
end)




-- =====================================
-- =====================================
-- ======= 4/ suppress_rescan closures =
-- =====================================
-- =====================================

helpers.describe("State.new: suppress_rescan", function()
	helpers.it("clears the buffer when called", function()
		local s = State.new(make_defaults(), { a = 0.3 })
		s.buffer = "abc"
		s.suppress_rescan(0.5)
		helpers.assert_eq(s.buffer, "")
		helpers.assert_true(s.no_rescan_until > 0)
	end)

	helpers.it("keeps the buffer when called via _keep_buffer variant", function()
		local s = State.new(make_defaults(), { a = 0.3 })
		s.buffer = "abc"
		s.suppress_rescan_keep_buffer(0.5)
		helpers.assert_eq(s.buffer, "abc")
	end)

	helpers.it("uses the default when duration is omitted", function()
		local s = State.new(make_defaults(), { a = 0.3 })
		s.suppress_rescan()
		-- no_rescan_until set to ~now+0.5
		helpers.assert_true(s.no_rescan_until > 0)
	end)
end)
