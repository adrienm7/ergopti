--- tests/unit/infra/config/test_shared_timings.lua

--- ==============================================================================
--- MODULE: Shared Timings Reader Tests (macOS)
--- DESCRIPTION:
--- Pins the shared timings reader (_shared/lua/timings.lua) that
--- infra/timings.lua binds: an unreachable shared tree, an unreadable or empty
--- registry, a missing section and a non-numeric key all raise naming the
--- cause, and the seconds and count helpers read the same value as the
--- millisecond accessor. The driver binding reads the real registry.
--- ==============================================================================

local helpers = require("tests.helpers")
local Timings = require("timings")

local function ports(overrides)
	local logged = {}
	local built = {
		logger = { done = function(_, fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end },
		log = "test.timings",
		loaded_level = "done",
		shared_path = function() return "/shared/constants.toml" end,
		parse = function() return { sections = { ui = { delay_ms = 1500, retention_days = 30, label = "x" } } } end,
	}
	for key, value in pairs(overrides or {}) do built[key] = value end
	return built, logged
end

local function raised(fn)
	return tostring(helpers.assert_throws(fn))
end

helpers.describe("shared timings reader (macOS)", function()
	helpers.it("reads milliseconds, seconds and counts from one value", function()
		local built, logged = ports()
		local timings = Timings.new(built)
		helpers.assert_eq(timings.ms("ui", "delay_ms"), 1500)
		helpers.assert_eq(timings.sec("ui", "delay_ms"), 1.5)
		helpers.assert_eq(timings.count("ui", "retention_days"), 30)
		helpers.assert_eq(#logged, 1)
	end)

	helpers.it("raises for an unreachable shared tree", function()
		helpers.assert_contains(raised(function() Timings.new(ports({ shared_path = function() return nil end })) end),
			"the _shared/ tree is unreachable")
		helpers.assert_contains(raised(function() Timings.new(ports({ shared_path = function() return "" end })) end),
			"the _shared/ tree is unreachable")
	end)

	helpers.it("raises for an empty or unreadable registry", function()
		for _, parsed in ipairs({ { sections = {} }, { sections = false }, false }) do
			local failure = raised(function() Timings.new(ports({ parse = function() return parsed end })) end)
			helpers.assert_contains(failure, "constants.toml is missing or empty: /shared/constants.toml")
		end
	end)

	helpers.it("raises for a missing section and for a non-numeric key", function()
		local timings = Timings.new(ports())
		helpers.assert_contains(raised(function() timings.ms("absent", "delay_ms") end), "missing section [absent]")
		helpers.assert_contains(raised(function() timings.ms("ui", "label") end), "missing or non-numeric key [ui].label")
		helpers.assert_contains(raised(function() timings.sec("ui", "absent") end), "[ui].absent")
	end)

	helpers.it("refuses a reader built without its ports", function()
		helpers.assert_contains(raised(function() Timings.new({}) end), "needs a logger")
	end)

	helpers.it("binds the driver to the real registry", function()
		local driver = require("infra.timings")
		helpers.assert_true(type(driver.ms("gestures", "tap_max_ms")) == "number")
		helpers.assert_eq(driver.sec("gestures", "tap_max_ms"), driver.ms("gestures", "tap_max_ms") / 1000)
	end)
end)
