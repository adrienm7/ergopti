--- tests/unit/ui/test_healthcheck_last_error_wired.lua

--- ==============================================================================
--- MODULE: Healthcheck Session Issues Are Wired (Linux)
--- DESCRIPTION:
--- The bridge's M.record_error had no production caller, so "Last recorded
--- error" stayed empty however many errors the daemon logged, and its warning
--- and error counts were read from the 200-line ring that DEBUG lines evict
--- within minutes while the page labels them "Session counters". The snapshot
--- now reads the logger core's own session counters; these cases drive a real
--- Logger.error / Logger.warn and forget the ring before asking
--- (healthcheck-last-error-wired).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs the callback with the real logger core and a fresh bridge, counting
--- every warn/error line the core actually emitted.
--- @param callback function Receives (Logger, Bridge, counts).
local function with_real_logger(callback)
	local Logger = require("logger")
	local previous_level = Logger.get_level()
	Logger.set_level("debug")
	Logger.reset_dedup()
	Logger.ring_buffer_clear()
	local counts = { warn = 0, error = 0 }
	Logger.set_sink(function(_, variant)
		if counts[variant] ~= nil then counts[variant] = counts[variant] + 1 end
	end)
	local Bridge = helpers.load_module("ui.healthcheck.bridge")
	local ok, err = pcall(callback, Logger, Bridge, counts)
	Logger.set_sink(nil)
	Logger.set_level(previous_level)
	if not ok then error(err, 0) end
end

helpers.describe("healthcheck (linux): session issues (healthcheck-last-error-wired)", function()
	helpers.it("surfaces a real Logger.error after the ring has forgotten it (healthcheck-last-error-wired)", function()
		with_real_logger(function(Logger, Bridge)
			Logger.error("probe", "boom %d", 42)
			Logger.ring_buffer_clear()
			local snapshot = Bridge.on_message("ready", {})
			helpers.assert_contains(tostring(snapshot.last_error), "[ERROR] [probe] boom 42",
				"the last error must come from the logger, not from a dead record_error path")
		end)
	end)

	helpers.it("counts every warning and error of the session, not the ring's (healthcheck-last-error-wired)", function()
		with_real_logger(function(Logger, Bridge, counts)
			local first = Bridge.on_message("ready", {})
			local warns_before, errors_before = counts.warn, counts.error
			Logger.warn("probe", "session warning marker")
			Logger.error("probe", "session error marker")
			Logger.ring_buffer_clear()
			local second = Bridge.on_message("refresh", {})
			helpers.assert_eq(second.warn_count - first.warn_count, counts.warn - warns_before,
				"every emitted warning between two snapshots must be counted once")
			helpers.assert_eq(second.err_count - first.err_count, counts.error - errors_before,
				"every emitted error between two snapshots must be counted once")
			helpers.assert_true(counts.error - errors_before >= 1, "the marker error must have been emitted")
		end)
	end)
end)
