--- tests/unit/ui/test_healthcheck_error_persistence.lua

--- ==============================================================================
--- MODULE: Healthcheck Session Issues Regression
--- DESCRIPTION:
--- The window's "Last recorded error" always said "No error recorded" on
--- macOS: M.record_error existed, but nothing in production ever called it —
--- only this test did, so it stayed green over a dead path. The "Session
--- counters" were counted inside the 200-line ring, which DEBUG lines evict
--- within minutes. Both now come from the logger's own session counters, so
--- the test drives a real Logger.error / Logger.warn and forgets the ring
--- before taking the snapshot (healthcheck-last-error-wired).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the real logger and the real healthcheck with its native probes
--- replaced by empty collectors, then runs the callback.
--- @param callback function Receives (Logger, Healthcheck, counts) where counts
---   tallies every warn/error line the logger actually emitted.
local function with_real_logger(callback)
	helpers.with_stub_scope({
		"infra.logger", "logger", "ui.healthcheck.core", "ui.healthcheck.helpers",
	}, function()
		local Logger = helpers.load_with_stubs("infra.logger")
		Logger.set_level("DEBUG")
		Logger.reset_dedup()
		Logger.ring_buffer_clear()
		local counts = { warn = 0, error = 0 }
		Logger.set_sink(function(_, variant)
			if counts[variant] ~= nil then counts[variant] = counts[variant] + 1 end
		end)
		-- Preserve the actual collector surface while isolating unrelated native
		-- probes; run() stays the real production function
		local collectors = helpers.load_with_stubs("ui.healthcheck.helpers")
		for name, value in pairs(collectors) do
			if type(value) == "function" then collectors[name] = function() return {} end end
		end
		local healthcheck = helpers.load_with_stubs("ui.healthcheck.core")
		local ok, err = xpcall(callback, debug.traceback, Logger, healthcheck, counts)
		Logger.set_sink(nil)
		if not ok then error(err, 0) end
	end)
end

helpers.describe("healthcheck session issues (healthcheck-last-error-wired)", function()
	helpers.it("surfaces a real Logger.error after the ring has forgotten it (healthcheck-last-error-wired)", function()
		with_real_logger(function(Logger, healthcheck)
			Logger.error("probe", "boom %d", 42)
			Logger.ring_buffer_clear()
			local snapshot = healthcheck.run()
			helpers.assert_contains(tostring(snapshot.sections.issues.last_error), "[ERROR] [probe] boom 42",
				"the last error must come from the logger, not from a dead record_error path")
		end)
	end)

	helpers.it("keeps the last error across snapshots until a newer error replaces it (healthcheck-last-error-wired)", function()
		with_real_logger(function(Logger, healthcheck)
			Logger.error("probe", "first diagnostic failure")
			helpers.assert_contains(tostring(healthcheck.run().sections.issues.last_error), "first diagnostic failure")
			helpers.assert_contains(tostring(healthcheck.run().sections.issues.last_error), "first diagnostic failure",
				"a second snapshot must not consume the recorded error")
			Logger.error("probe", "replacement diagnostic failure")
			helpers.assert_contains(tostring(healthcheck.run().sections.issues.last_error), "replacement diagnostic failure")
		end)
	end)

	helpers.it("counts every warning and error of the session, not the ring's (healthcheck-last-error-wired)", function()
		with_real_logger(function(Logger, healthcheck, counts)
			local first = healthcheck.run()
			local warns_before, errors_before = counts.warn, counts.error
			Logger.warn("probe", "session warning marker")
			Logger.error("probe", "session error marker")
			Logger.ring_buffer_clear()
			local second = healthcheck.run()
			helpers.assert_eq(second.sections.issues.warn_count - first.sections.issues.warn_count, counts.warn - warns_before,
				"every emitted warning between two snapshots must be counted once")
			helpers.assert_eq(second.sections.issues.err_count - first.sections.issues.err_count, counts.error - errors_before,
				"every emitted error between two snapshots must be counted once")
			helpers.assert_true(counts.error - errors_before >= 1, "the marker error must have been emitted")
		end)
	end)

	-- Phase A logged its own overrun of the 5 ms budget as a WARNING, which the
	-- next snapshot counted among the session's problems: the window inflated
	-- the counts it reports, and the case above failed whenever a loaded
	-- machine made one collection slower than the next. The duration stays in
	-- the report's developer section (phase-a-budget-not-a-warning).
	helpers.it("never counts its own duration among the session's warnings (phase-a-budget-not-a-warning)", function()
		with_real_logger(function(_, healthcheck, counts)
			-- Every collection overruns a negative budget
			healthcheck.config().schema.phase_a_budget_ms = -1
			local warns_before = counts.warn
			local first = healthcheck.run()
			local second = healthcheck.run()
			helpers.assert_eq(counts.warn - warns_before, 0, "an over-budget collection logged a warning")
			helpers.assert_eq(second.sections.issues.warn_count, first.sections.issues.warn_count,
				"the first collection's duration was counted by the second")
			helpers.assert_true(type(second.sections.developer.phase_a_ms) == "number",
				"the duration stays in the developer section")
		end)
	end)
end)
