--- tests/unit/lib/test_logger_stall_recovery.lua

--- ==============================================================================
--- MODULE: Logger native stall recovery
--- DESCRIPTION:
--- The transport now survives a slow native worker instead of exiting. That
--- only helps if the stall stays visible: the log must say how long the worker
--- was stuck and how many low-importance lines were shed meanwhile, once, and a
--- shed line must not be recorded as a logger failure.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fixture = require("tests.support.logger_async_sink_fixture")

--- Acknowledges the last batch the fixture socket carried.
--- @param fixture table Logger asynchronous sink fixture.
local function acknowledge_last_batch(fixture)
	local request = fixture.hs.json.decode(fixture.sent[#fixture.sent])
	local records = request.records or {}
	fixture.receive(fixture.hs.json.encode({
		v = 1,
		kind = "ack",
		token = request.token,
		session = request.session,
		ack = records[#records].sequence,
	}))
end

helpers.describe("logger: native logger stall recovery", function()
	helpers.it("(logger-stall-recovery) logs a recovered stall once, with its duration and shed lines", function()
		local clock = 100
		Fixture.with_fixture(function(fixture)
			local Logger = fixture.Logger
			local seen = {}
			Logger.set_sink(function(line, variant)
				seen[#seen + 1] = { line = line, variant = variant }
			end)

			Logger.info("probe", "Head of line before the stall.")
			for _ = 1, 16 do
				fixture.pump()
				if #fixture.sent > 0 then break end
			end
			helpers.assert_eq(#fixture.sent, 1, "the head batch must be in flight")
			clock = 100.5
			fixture.pump()
			helpers.assert_eq(#fixture.sent, 2, "the missed ACK deadline resends the head")
			local status = Logger.async_sink_status()
			helpers.assert_eq(status.stalled, true)

			local limit = status.stalled_sheddable_limit
			helpers.assert_true(type(limit) == "number" and limit > 0)
			for index = 1, limit + 20 do
				Logger.debug("probe", "Stalled debug line %d.", index)
			end
			status = Logger.async_sink_status()
			-- The in-flight INFO head already holds one non-critical slot.
			helpers.assert_eq(status.stall_shed, 21)
			helpers.assert_nil(status.last_error, "a shed line is policy, not a logger failure")

			clock = 100.6
			acknowledge_last_batch(fixture)
			fixture.pump()
			local warnings = {}
			for _, entry in ipairs(seen) do
				if entry.variant == "warn" then warnings[#warnings + 1] = entry.line end
			end
			helpers.assert_eq(#warnings, 1, "one recovery is one WARN line")
			helpers.assert_contains(warnings[1], "[logger]")
			helpers.assert_contains(warnings[1], "stalled 600 ms")
			helpers.assert_contains(warnings[1], "21 DEBUG/TRACE/DONE line(s)")

			fixture.pump()
			local later = 0
			for _, entry in ipairs(seen) do
				if entry.variant == "warn" then later = later + 1 end
			end
			helpers.assert_eq(later, 1, "the recovery is not reported again")
		end, { clock = function() return clock end })
	end)
end)
