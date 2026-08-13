--- tests/unit/ui/test_wpm_lifecycle_transactions.lua

--- ==============================================================================
--- MODULE: WPM Runtime Lifecycle Transaction Tests
--- DESCRIPTION:
--- Drives the floating and menubar WPM owners through timer/eventtap acquisition,
--- teardown refusal, and stale delivery. The tests assert user-visible lifecycle
--- truth rather than merely checking that native constructors were called.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the WPM menubar with exact scheduler and stats spies.
--- @param scheduler table TimerScheduler test double.
--- @param stats_calls table Mutable call counter.
--- @return table module Fresh menubar module.
local function load_menubar(scheduler, stats_calls)
	package.loaded["adapters.timer_scheduler"] = scheduler
	package.loaded["modules.keylogger"] = {
		get_live_stats = function()
			stats_calls.count = stats_calls.count + 1
			return {}
		end,
	}
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	return helpers.load_with_stubs("ui.wpm.wpm_menubar", {
		timer = { absoluteTime = function() return 0 end },
	})
end

helpers.describe("WPM menubar recurring timer transaction", function()
	helpers.it("fails closed when timer acquisition throws or returns nil", function()
		for _, case in ipairs({
			{ label = "throw", every = function() error("timer constructor exploded") end },
			{ label = "nil", every = function() return nil, nil end },
		}) do
			local stats_calls = { count = 0 }
			local menubar = load_menubar({
				every = case.every,
				cancel = function() error("no handle exists to cancel") end,
			}, stats_calls)
			local ok, committed = pcall(menubar.start)
			helpers.assert_true(ok, case.label .. " acquisition failure must not escape the menu action")
			helpers.assert_eq(committed, false)
			helpers.assert_eq(stats_calls.count, 0,
				case.label .. " acquisition failure must not publish a first render")
		end
	end)

	helpers.it("rejects an uncommitted timer and retains refused cleanup debt", function()
		local candidate = { timer = {} }
		local acquisitions = 0
		local cancellations = 0
		local scheduler = {
			every = function()
				acquisitions = acquisitions + 1
				return candidate, false
			end,
			cancel = function()
				cancellations = cancellations + 1
				return false
			end,
		}
		local stats_calls = { count = 0 }
		local menubar = load_menubar(scheduler, stats_calls)

		helpers.assert_eq(menubar.start(), false)
		helpers.assert_eq(stats_calls.count, 0,
			"an uncommitted poller must not publish the first menubar render")
		helpers.assert_eq(menubar.start(), false,
			"a refused exact cleanup must block a conflicting successor")
		helpers.assert_eq(acquisitions, 1)
		helpers.assert_true(cancellations >= 2,
			"each retry must target the retained exact timer")
	end)

	helpers.it("generation-fences a queued callback after stop", function()
		local callback = nil
		local candidate = { timer = {} }
		local scheduler = {
			every = function(_delay, fn) callback = fn; return candidate, true end,
			cancel = function(handle) handle.timer = nil; return true end,
		}
		local stats_calls = { count = 0 }
		local menubar = load_menubar(scheduler, stats_calls)

		helpers.assert_eq(menubar.start(), true)
		helpers.assert_eq(stats_calls.count, 1)
		helpers.assert_eq(menubar.stop(), true)
		callback()
		helpers.assert_eq(stats_calls.count, 1,
			"a queued callback from the stopped generation must be inert")
	end)
end)

--- Loads the floating widget with a controlled scheduler and eventtap.
--- @param scheduler table TimerScheduler test double.
--- @param eventtap table Native eventtap test double.
--- @return table module Fresh widget module.
local function load_widget(scheduler, eventtap)
	package.loaded["adapters.timer_scheduler"] = scheduler
	package.loaded["modules.keylogger"] = { get_live_stats = function() return {} end }
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	return helpers.load_with_stubs("ui.wpm.wpm_widget", {
		timer = { absoluteTime = function() return 0 end },
		eventtap = eventtap,
	})
end

local EVENT_TYPES = {
	mouseMoved = 1,
	leftMouseDown = 2,
	rightMouseDown = 3,
	scrollWheel = 4,
}

helpers.describe("WPM floating widget capability transaction", function()
	helpers.it("rolls back the timer when eventtap start does not enable the tap", function()
		local timer = { timer = {} }
		local timer_cancels = 0
		local scheduler = {
			every = function() return timer, true end,
			cancel = function(handle)
				timer_cancels = timer_cancels + 1
				handle.timer = nil
				return true
			end,
		}
		local tap = { enabled = false }
		tap.start = function(self) return self end
		tap.stop = function(self) self.enabled = false; return self end
		tap.isEnabled = function(self) return self.enabled end
		local widget = load_widget(scheduler, {
			event = { types = EVENT_TYPES },
			new = function() return tap end,
		})

		helpers.assert_eq(widget.start(false), false)
		helpers.assert_eq(timer_cancels, 1,
			"a disabled eventtap must roll back its committed sibling timer")
	end)

	helpers.it("retains an eventtap that remains enabled after stop", function()
		local timer_count = 0
		local scheduler = {
			every = function()
				timer_count = timer_count + 1
				return { timer = {} }, true
			end,
			cancel = function(handle) handle.timer = nil; return true end,
		}
		local tap = { enabled = false }
		tap.start = function(self) self.enabled = true; return self end
		tap.stop = function(self) return self end
		tap.isEnabled = function(self) return self.enabled end
		local widget = load_widget(scheduler, {
			event = { types = EVENT_TYPES },
			new = function() return tap end,
		})

		helpers.assert_eq(widget.start(false), true)
		helpers.assert_eq(widget.stop(), false)
		helpers.assert_eq(widget.start(false), false,
			"an enabled teardown-debt tap must block a successor")
		helpers.assert_eq(timer_count, 1,
			"the conflicting timer must not be acquired while tap cleanup is unsettled")
	end)
end)
