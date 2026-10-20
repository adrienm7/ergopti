--- tests/unit/infra/logger/test_keystroke_integrity.lua

--- ==============================================================================
--- MODULE: keystroke_integrity Unit Tests
--- DESCRIPTION:
--- Pins the dropped-key diagnostic: the ring keeps only decisions and their
--- time, summarizes a bounded recent window, refuses unknown decisions, and
--- turns every swallowed key into one deferred WARNING per cause.
--- ==============================================================================

local helpers = require("tests.helpers")

local warnings = {}
local deferred = {}
local function noop() end

helpers.describe("infra.keystroke_integrity", function()
	local saved = {
		logger = package.loaded["infra.logger"],
		deferred = package.loaded["infra.deferred_work"],
		timer = package.loaded["adapters.timer_scheduler"],
		subject = package.loaded["infra.keystroke_integrity"],
	}
	local now_ms = 0
	package.loaded["infra.logger"] = {
		warn = function(tag, fmt, ...)
			warnings[#warnings + 1] = { tag = tag, text = string.format(fmt, ...) }
		end,
		info = noop, debug = noop, error = noop,
	}
	package.loaded["infra.deferred_work"] = {
		after = function(delay, callback, label)
			deferred[#deferred + 1] = { delay = delay, callback = callback, label = label }
			return true
		end,
	}
	package.loaded["adapters.timer_scheduler"] = { now_ns = function() return now_ms * 1e6 end }
	package.loaded["infra.keystroke_integrity"] = nil
	local Integrity = require("infra.keystroke_integrity")

	helpers.it("summarizes only recent decisions and never stores key content", function()
		Integrity.reset()
		now_ms = 1000
		Integrity.record("passed")
		now_ms = 30000
		for _ = 1, Integrity.RING_SIZE + 5 do Integrity.record("passed") end
		Integrity.record("replay_queued")
		helpers.assert_eq(Integrity.summary(), "passed=63, replay_queued=1",
			"the ring is bounded and its oldest decisions are overwritten")
		now_ms = 30000 + Integrity.SUMMARY_WINDOW_MS + 1
		helpers.assert_eq(Integrity.summary(), "none")
		local ok = pcall(Integrity.record, "a")
		helpers.assert_eq(ok, false, "only named decisions are accepted, never a character")
	end)

	helpers.it("reports swallowed keys once per cause, after the event tap returns", function()
		Integrity.reset()
		warnings, deferred = {}, {}
		now_ms = 50000
		Integrity.record("replay_queued")
		Integrity.report_drop("their delayed replay ended failed before it was posted (x)")
		Integrity.report_drop("their delayed replay ended failed before it was posted (x)")
		helpers.assert_eq(#warnings, 0, "nothing may be logged inside the event tap")
		helpers.assert_eq(#deferred, 1, "reports of one turn share one deferred write")
		deferred[1].callback()
		helpers.assert_eq(#warnings, 1)
		helpers.assert_true(warnings[1].text:find("^2 typed key%(s%) swallowed") ~= nil, warnings[1].text)
		helpers.assert_true(warnings[1].text:find("replay_queued=1", 1, true) ~= nil, warnings[1].text)
		helpers.assert_eq(Integrity.drop_count(), 2)
	end)

	package.loaded["infra.logger"] = saved.logger
	package.loaded["infra.deferred_work"] = saved.deferred
	package.loaded["adapters.timer_scheduler"] = saved.timer
	package.loaded["infra.keystroke_integrity"] = saved.subject
end)
