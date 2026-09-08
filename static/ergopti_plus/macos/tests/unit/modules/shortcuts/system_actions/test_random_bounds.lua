--- tests/unit/modules/shortcuts/system_actions/test_random_bounds.lua

--- ==============================================================================
--- MODULE: System Action Regression Tests
--- DESCRIPTION:
--- Exercises system actions while preserving exact native and dependency ownership.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.system_actions_fixture")
local with_fixture = fixture.with_fixture

helpers.describe("shortcuts.actions.system: schedule_awake_tick float random bounds (shortcuts-actions-3 regression)", function()

	helpers.it("source: uses math.random() (no-arg) not math.random(m, n) for the tick interval", function()
		with_fixture(function()
			-- Selected by a declaration unique to modules/shortcuts/actions/system.lua rather than by
			-- path, so moving or splitting the module cannot turn this invariant
			-- into a path error.
			local src = helpers.read_driver_source("local function read_wrap_ax_selection_cached")
			helpers.assert_true(src ~= nil, "modules/shortcuts/actions/system.lua source must be locatable")
			if not src then return end

			-- The buggy form passes the float bounds directly to math.random(m, n).
			local has_buggy = src:find("math.random(AWAKE_TICK_MIN_SEC, AWAKE_TICK_MAX_SEC)", 1, true) ~= nil
			helpers.assert_true(
				not has_buggy,
				"system.lua must NOT use math.random(AWAKE_TICK_MIN_SEC, AWAKE_TICK_MAX_SEC) — "
				.. "that form requires integer bounds and raises on float values (shortcuts-actions-3)"
			)

			-- The float-safe form uses the zero-arg math.random() for a [0,1) uniform draw.
			local has_float_safe = src:find("math.random()", 1, true) ~= nil
			helpers.assert_true(
				has_float_safe,
				"system.lua must use math.random() (no-arg) for the tick interval to support float bounds"
			)
		end)
	end)

	helpers.it("source: span variable is computed before the interval assignment", function()
		with_fixture(function()
			-- Selected by a declaration unique to modules/shortcuts/actions/system.lua rather than by
			-- path, so moving or splitting the module cannot turn this invariant
			-- into a path error.
			local src = helpers.read_driver_source("local function read_wrap_ax_selection_cached")
			helpers.assert_true(src ~= nil, "modules/shortcuts/actions/system.lua source must be locatable")
			if not src then return end

			-- The float-safe pattern requires a span = max - min intermediate variable.
			local span_pos    = src:find("local span = AWAKE_TICK_MAX_SEC", 1, true)
			local interval_pos = src:find("AWAKE_TICK_MIN_SEC + math.random()", 1, true)
			helpers.assert_true(span_pos ~= nil,
				"system.lua must compute 'local span = AWAKE_TICK_MAX_SEC - AWAKE_TICK_MIN_SEC'")
			helpers.assert_true(interval_pos ~= nil,
				"system.lua must compute interval as AWAKE_TICK_MIN_SEC + math.random() * span")
			helpers.assert_true(span_pos < interval_pos,
				"span must be computed before the interval assignment")
		end)
	end)

end)
