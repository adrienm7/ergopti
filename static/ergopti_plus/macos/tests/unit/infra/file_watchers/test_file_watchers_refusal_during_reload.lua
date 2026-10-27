--- tests/unit/infra/file_watchers/test_file_watchers_refusal_during_reload.lua

--- ==============================================================================
--- MODULE: infra/file_watchers refusal during a reload
--- DESCRIPTION:
--- One `git pull` reaches both source watchers. On the field run (2026-10-27
--- 19:47:04, 21:06:55) infra/file_watchers won and the menu watcher's refused
--- request warned; ledger L45 lowered that one to INFO but left this sibling, so
--- the same race lost the other way still warned. Its message also printed the
--- request's result after "remains pending for retry:", which read
--- "pending for retry: false" — a lost retry — although the burst is re-armed.
---
--- ROOT CAUSE ENCODED:
--- 1. A refusal while a reload or quit already owns the process is expected:
---    INFO, and the burst stays owned.
--- 2. Any other refusal still warns once, and its text states that the burst
---    stays pending instead of printing a boolean after "pending for retry".
--- ==============================================================================

local helpers = require("tests.helpers")

local Fixture = require("tests.support.file_watcher_self_write_fixture")

--- Runs one refused reload with the coordinator reporting `terminating`.
--- @param terminating boolean Coordinator answer.
--- @return table lines Captured `{ level, template }` pairs from file_watchers.
--- @return boolean rearmed True when the burst kept a poll owner.
local function refused_reload(terminating)
	local previous = package.loaded["infra.termination_coordinator"]
	package.loaded["infra.termination_coordinator"] = {
		terminal_in_progress = function() return terminating end,
	}
	local lines = {}
	local logger = helpers.make_logger_stub()
	local function record(level)
		return function(_, message)
			if tostring(message):find("Reload request ", 1, true) then
				lines[#lines + 1] = { level = level, template = tostring(message) }
			end
		end
	end
	logger.info, logger.warn, logger.debug = record("info"), record("warn"), record("debug")
	local rearmed = false
	local ok, err = pcall(Fixture.with_watchers, function(w)
		w.set_clock(1000)
		w.fire({ "/fake/base/modules/changed.lua" })
		w.set_clock(2000)
		w.poll()
		helpers.assert_eq(w.reloads(), 1, "fixture: the settled burst must reach the reload request")
		rearmed = type(w.scheduled()) == "function"
	end, { logger = logger, reload = function() return false end })
	package.loaded["infra.termination_coordinator"] = previous
	if not ok then error(err, 0) end
	return lines, rearmed
end

helpers.describe("infra/file_watchers — refused reload during a reload (watcher-reload-sibling)", function()
	helpers.it("logs a refusal during a reload or quit at INFO and keeps the burst", function()
		local lines, rearmed = refused_reload(true)
		helpers.assert_true(rearmed, "the refused burst must stay owned")
		helpers.assert_eq(#lines, 1, "one line for one refusal")
		helpers.assert_eq(lines[1].level, "info",
			"the other watcher's reload of the same burst is under way; this is not a failure")
	end)

	helpers.it("warns for any other refusal without printing the result as a pending flag", function()
		local lines, rearmed = refused_reload(false)
		helpers.assert_true(rearmed, "the refused burst must stay owned")
		helpers.assert_eq(lines[1].level, "warn", "an unexplained refusal must still warn")
		helpers.assert_true(lines[1].template:find("pending for retry: %s", 1, true) == nil,
			"the request result must not read as the retry state")
		helpers.assert_true(lines[1].template:find("stays pending and is retried", 1, true) ~= nil,
			"the warning must say the burst is retained")
	end)
end)
