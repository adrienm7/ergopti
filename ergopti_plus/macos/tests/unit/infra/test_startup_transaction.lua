--- tests/unit/infra/test_startup_transaction.lua

--- ==============================================================================
--- MODULE: Ordered Startup Transaction Regression
--- DESCRIPTION:
--- Exercises the real startup coordinator against exact success, optional
--- unavailability, explicit refusal, exceptions, and rollback failures.
---
--- The boot entry point itself needs a live Hammerspoon runtime and cannot be
--- loaded headlessly. These behavioural cases therefore pin the transaction
--- mechanism used by that entry point rather than merely scanning for a pcall.
--- ==============================================================================

local helpers = require("tests.helpers")

local function load_subject()
	package.loaded["infra.startup_transaction"] = nil
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	return require("infra.startup_transaction")
end

--- Builds one observable lifecycle descriptor.
--- @param events table Ordered event sink.
--- @param name string Stable step name.
--- @param start_result any Value returned by start.
--- @param mode string|nil Optional `start_throw` or `stop_throw` mode.
--- @return table step Transaction descriptor.
local function step(events, name, start_result, mode)
	return {
		name = name,
		start = function()
			events[#events + 1] = "start:" .. name
			if mode == "start_throw" then error("START_THROW:" .. name) end
			return start_result
		end,
		stop = function()
			events[#events + 1] = "stop:" .. name
			if mode == "stop_throw" then error("STOP_THROW:" .. name) end
			return true
		end,
	}
end





-- ================================================
-- ================================================
-- ======= 1/ Exact Startup Commit Contract =======
-- ================================================
-- ================================================

helpers.describe("startup transaction: exact commit and availability", function()
	helpers.it("commits required steps in declaration order", function()
		local subject = load_subject()
		local events = {}
		local result = subject.run({
			step(events, "gestures", true),
			step(events, "shortcuts", true),
			step(events, "script_control", true),
		})

		helpers.assert_eq(result, true)
		helpers.assert_eq(table.concat(events, ","),
			"start:gestures,start:shortcuts,start:script_control")
	end)

	helpers.it("accepts nil only for an explicitly optional capability", function()
		local subject = load_subject()
		local events = {}
		local optional = step(events, "gestures", nil)
		optional.allow_unavailable = true

		helpers.assert_eq(subject.run({
			optional,
			step(events, "shortcuts", true),
		}), true)
		helpers.assert_eq(table.concat(events, ","), "start:gestures,start:shortcuts")
	end)

	helpers.it("rejects nil from a required step and cleans that step", function()
		local subject = load_subject()
		local events = {}

		helpers.assert_eq(subject.run({step(events, "shortcuts", nil)}), false)
		helpers.assert_eq(table.concat(events, ","), "start:shortcuts,stop:shortcuts")
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 2/ Partial Activation Rollback =======
-- ==============================================
-- ==============================================

helpers.describe("startup transaction: partial activation rollback", function()
	helpers.it("rolls back an exact false before prior owners in reverse order", function()
		local subject = load_subject()
		local events = {}

		local result = subject.run({
			step(events, "gestures", true),
			step(events, "shortcuts", true),
			step(events, "script_control", false),
			step(events, "unreachable", true),
		})

		helpers.assert_eq(result, false)
		helpers.assert_eq(table.concat(events, ","), table.concat({
			"start:gestures",
			"start:shortcuts",
			"start:script_control",
			"stop:script_control",
			"stop:shortcuts",
			"stop:gestures",
		}, ","))
	end)

	helpers.it("contains a start exception and performs the same rollback", function()
		local subject = load_subject()
		local events = {}

		local result = subject.run({
			step(events, "gestures", true),
			step(events, "shortcuts", nil, "start_throw"),
		})

		helpers.assert_eq(result, false)
		helpers.assert_eq(table.concat(events, ","),
			"start:gestures,start:shortcuts,stop:shortcuts,stop:gestures")
	end)

	helpers.it("continues rolling back siblings after one cleanup raises", function()
		local subject = load_subject()
		local events = {}

		local result = subject.run({
			step(events, "gestures", true, "stop_throw"),
			step(events, "shortcuts", false),
		})

		helpers.assert_eq(result, false)
		helpers.assert_eq(table.concat(events, ","),
			"start:gestures,start:shortcuts,stop:shortcuts,stop:gestures")
	end)
end)

return true
