--- tests/unit/adapters/test_event_tap_guard.lua

--- ==============================================================================
--- MODULE: Regression — the disabled-tap guard restarts and reports, behaviourally
--- DESCRIPTION:
--- The meta guard next to this file asserts that every tap owner REFERENCES a
--- recovery path. That alone would be satisfied by a recovery path that does
--- nothing, so this drives the shared guard itself: a disable notification must
--- restart the tap and leave a WARNING, and an ordinary keystroke must pass
--- through untouched.
---
--- ROOT CAUSE ENCODED:
--- macOS reports the disable THROUGH the callback, as an event type the callback
--- never compared against. The assertions below therefore feed the guard real
--- event objects and observe the tap and the log, never the shape of the code.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Arbitrary distinct values; the guard must compare against the table it reads
-- from hs, not against hardcoded numbers.
local TYPE_KEY_DOWN            = 10
local TYPE_DISABLED_BY_TIMEOUT = 4294967294
local TYPE_DISABLED_BY_USER    = 4294967295


--- Installs the hs stub the guard needs and a capturing logger.
--- @return table guard, table tap, table captured
local function load_guard()
	local captured = { warn = {}, error = {}, info = {} }
	local function sink(level)
		return function(_log, fmt, ...)
			local ok, line = pcall(string.format, fmt, ...)
			table.insert(captured[level], ok and line or tostring(fmt))
		end
	end
	package.loaded["infra.logger"] = {
		warn = sink("warn"), error = sink("error"), info = sink("info"),
		debug = function() end, trace = function() end, done = function() end,
		start = function() end, success = function() end,
	}

	_G.hs = _G.hs or {}
	_G.hs.eventtap = {
		event = {
			types = {
				keyDown                 = TYPE_KEY_DOWN,
				tapDisabledByTimeout    = TYPE_DISABLED_BY_TIMEOUT,
				tapDisabledByUserInput  = TYPE_DISABLED_BY_USER,
			},
		},
	}

	package.loaded["adapters.event_tap_guard"] = nil
	local guard = require("adapters.event_tap_guard")
	local tap = { starts = 0 }
	tap.start = function(self) self.starts = self.starts + 1 end
	return guard, tap, captured
end


--- Builds a fake event whose getType() returns the given value.
--- @param t number
--- @return table
local function event_of_type(t)
	return { getType = function() return t end }
end


--- @param lines table
--- @param needle string
--- @return boolean
local function any_contains(lines, needle)
	for _, l in ipairs(lines) do
		if l:find(needle, 1, true) then return true end
	end
	return false
end




-- ==================================================================
-- ==================================================================
-- ======= 1/ A disable notification restarts the tap ===============
-- ==================================================================
-- ==================================================================

helpers.describe("event tap guard: a disabled tap is restarted and reported", function()

	helpers.it("restarts the tap on a timeout disable", function()
		local guard, tap, captured = load_guard()

		local handled = guard.handle_disabled(event_of_type(TYPE_DISABLED_BY_TIMEOUT), tap, "keymap.main")

		helpers.assert_true(handled,
			"the callback must be told this was a disable notification, not a keystroke")
		helpers.assert_eq(tap.starts, 1,
			"macOS never re-enables a tap it disabled and raises nothing when it does so; "
			.. "without this restart the tap is deaf for the rest of the session")
		helpers.assert_true(any_contains(captured.warn, "keymap.main"),
			"and the owner must be named at WARNING level — a disable is the visible symptom "
			.. "of a callback that overran the deadline, which is otherwise unmeasurable")
	end)

	helpers.it("restarts the tap on a user-input disable too", function()
		local guard, tap = load_guard()
		local handled = guard.handle_disabled(event_of_type(TYPE_DISABLED_BY_USER), tap, "gestures.click")
		helpers.assert_true(handled, "the accessibility-toggle disable is the same class of failure")
		helpers.assert_eq(tap.starts, 1, "and needs the same restart")
	end)

	helpers.it("distinguishes the two causes in the log", function()
		local _, _, c1 = select(1, load_guard())
		local g1, t1, cap1 = load_guard()
		g1.handle_disabled(event_of_type(TYPE_DISABLED_BY_TIMEOUT), t1, "a")
		local g2, t2, cap2 = load_guard()
		g2.handle_disabled(event_of_type(TYPE_DISABLED_BY_USER), t2, "a")

		helpers.assert_true(cap1.warn[1] ~= cap2.warn[1],
			"a timeout means our own latency and a user-input disable means the permission "
			.. "was toggled; collapsing them into one message sends the reader down the wrong path")
		helpers.assert_true(c1 ~= nil, "guard loader must return its capture table")
	end)

end)




-- ==================================================================
-- ==================================================================
-- ======= 2/ Ordinary events are not touched =======================
-- ==================================================================
-- ==================================================================

helpers.describe("event tap guard: real events pass straight through", function()

	helpers.it("does not claim an ordinary keystroke", function()
		local guard, tap, captured = load_guard()

		local handled = guard.handle_disabled(event_of_type(TYPE_KEY_DOWN), tap, "keymap.main")

		helpers.assert_true(not handled,
			"without this case the assertions above would pass against a guard that swallows "
			.. "every event, which would silently break every tap it was added to")
		helpers.assert_eq(tap.starts, 0, "and it must not restart a healthy tap on every keystroke")
		helpers.assert_eq(#captured.warn, 0, "nor flood the log at typing speed")
	end)

	helpers.it("never matches a nil event type", function()
		local guard, tap, captured = load_guard()
		-- Both sides of the comparison can be nil in the field: an event object
		-- that does not answer getType, and a Hammerspoon build that does not
		-- publish these constants. `nil == nil` is true, so an unguarded compare
		-- declares every event a disable and swallows the entire tap.
		local handled = guard.handle_disabled({ getType = function() return nil end }, tap, "nil_type")

		helpers.assert_true(not handled,
			"a nil type must never be read as a disable notification — that turns the guard "
			.. "into a total outage on every event the tap receives")
		helpers.assert_eq(tap.starts, 0, "and must not restart the tap on every event")
		helpers.assert_eq(#captured.warn, 0, "nor log at event rate")
	end)

	helpers.it("does not match when the constants are absent", function()
		local guard, tap = load_guard()
		_G.hs.eventtap.event.types.tapDisabledByTimeout   = nil
		_G.hs.eventtap.event.types.tapDisabledByUserInput = nil
		package.loaded["adapters.event_tap_guard"] = nil
		local fresh = require("adapters.event_tap_guard")

		local handled = fresh.handle_disabled(event_of_type(TYPE_KEY_DOWN), tap, "no_constants")

		helpers.assert_true(not handled,
			"a build without these constants must degrade to doing nothing, not to matching "
			.. "everything")
		helpers.assert_eq(tap.starts, 0, "and must leave the tap alone")
	end)

	helpers.it("reports the condition even when the owner passes no handle", function()
		local guard, _, captured = load_guard()

		local handled = guard.handle_disabled(event_of_type(TYPE_DISABLED_BY_TIMEOUT), nil, "orphan")

		helpers.assert_true(handled, "the event is still a disable notification")
		helpers.assert_true(any_contains(captured.error, "orphan"),
			"a tap owner that cannot name its own handle loses the restart, so it must at "
			.. "least not also lose the diagnostic")
	end)

end)
