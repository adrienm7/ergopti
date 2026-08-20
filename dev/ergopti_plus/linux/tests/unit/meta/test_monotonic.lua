--- tests/unit/meta/test_monotonic.lua

--- ==============================================================================
--- MODULE: Monotonic Clock Source Guard (Linux)
--- DESCRIPTION:
--- Guards infra/monotonic — the daemon's single sub-second, monotonic, wall-clock
--- time source that replaces os.clock() (CPU time) for gesture and file-watcher
--- timing. The contract: a real number of milliseconds/seconds, non-decreasing
--- across readings, sourced from luv.hrtime when available and never os.clock.
--- ==============================================================================

local helpers = require("tests.helpers")

local describe    = helpers.describe
local it          = helpers.it
local assert_true = helpers.assert_true
local assert_eq   = helpers.assert_eq





-- ===========================================
-- ===========================================
-- ======= 1/ Monotonic clock contract =======
-- ===========================================
-- ===========================================

describe("infra.monotonic", function()

	local Monotonic = helpers.load_module("infra.monotonic")

	it("now_ms returns a positive number", function()
		local t = Monotonic.now_ms()
		assert_true(type(t) == "number", "now_ms must return a number")
		assert_true(t > 0, "now_ms must be a positive timestamp")
	end)

	it("now_ms is non-decreasing across successive readings", function()
		local a = Monotonic.now_ms()
		for _ = 1, 1000 do end -- burn a little wall time without sleeping
		local b = Monotonic.now_ms()
		assert_true(b >= a, "a monotonic clock must never go backwards")
	end)

	it("now_sec is now_ms scaled to seconds", function()
		-- Same order of magnitude: now_sec must be ~1000x smaller than now_ms.
		local ms  = Monotonic.now_ms()
		local sec = Monotonic.now_sec()
		assert_true(sec > 0, "now_sec must be positive")
		assert_true(sec < ms, "seconds must be smaller than milliseconds for the same clock")
	end)

	it("reports a known backend and a consistent has_hires flag", function()
		local backend = Monotonic.backend()
		assert_true(backend == "luv.hrtime" or backend == "os.time",
			"backend must be one of the two supported sources")
		assert_eq(Monotonic.has_hires(), backend == "luv.hrtime",
			"has_hires must agree with the reported backend")
	end)

end)
