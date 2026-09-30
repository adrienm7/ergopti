--- tests/unit/ui/test_login_items_guide.lua

--- ==============================================================================
--- MODULE: Login Items approval guide (guardian-approval-steps)
--- DESCRIPTION:
--- Tap-holds stayed off until the remap guardian was allowed in System
--- Settings > General > Login Items & Extensions, and the user could not guess
--- it. The guide now shows the numbered steps in the permission dialog once per
--- launch, never over the Accessibility steps, and closes them by itself once
--- the guardian is ready, with a bounded poll stopped on every close.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"ui.permission_dialog.login_items_guide", "ui.permission_dialog", "adapters.timer_scheduler",
	"infra.logger", "infra.i18n", "infra.notifications",
}

--- Installs the recording doubles of the guide's dependencies.
--- @param h table Harness receiving the recordings.
local function install_doubles(h)
	h.logs = {}
	local logger = helpers.make_logger_stub()
	for _, level in ipairs({ "debug", "info", "start", "success", "warn", "error" }) do
		logger[level] = function(_, message, ...)
			h.logs[#h.logs + 1] = { level = level, message = string.format(message, ...) }
		end
	end
	package.loaded["infra.logger"] = logger
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	h.notices = {}
	package.loaded["infra.notifications"] = {
		notify = function(message, _, kind)
			h.notices[#h.notices + 1] = { message = message, kind = kind }
			return true
		end,
	}

	-- One dialog owner, as in production: at most one kind is open.
	h.shows, h.closes, h.open = {}, 0, nil
	h.accessibility_open = false
	package.loaded["ui.permission_dialog"] = {
		show = function(spec)
			h.shows[#h.shows + 1] = spec
			if h.show_fails then return false end
			if h.open == nil or h.open.kind ~= spec.kind then h.open = spec end
			return true
		end,
		close = function(kind)
			local open = h.open
			if open == nil or open.kind ~= kind then return true end
			h.open = nil
			h.closes = h.closes + 1
			local on_closed = open.on_closed
			open.on_closed = nil
			if on_closed then on_closed() end
			return true
		end,
		is_open = function(kind)
			if kind == "accessibility" then return h.accessibility_open end
			return h.open ~= nil and h.open.kind == kind
		end,
	}

	h.timers = {}
	package.loaded["adapters.timer_scheduler"] = {
		every = function(seconds, fn)
			local handle = { seconds = seconds, fn = fn, cancelled = false }
			h.timers[#h.timers + 1] = handle
			return handle, true
		end,
		cancel = function(handle)
			handle.cancelled = true
			return true
		end,
	}

	h.remap = { state = "requires_approval", opens = 0, open_ok = true, tap_holds = true }
	function h.remap.guardian_state() return h.remap.state end
	function h.remap.get_tap_holds_enabled() return h.remap.tap_holds end
	function h.remap.open_login_items(on_done)
		h.remap.opens = h.remap.opens + 1
		on_done(h.remap.open_ok, h.remap.open_ok and "opened" or "open-exited-non-zero")
		return true
	end
end

--- Runs one case against a fresh guide over recording doubles.
--- @param body function Receives the harness.
local function with_guide(body)
	helpers.with_fresh_modules(MODULES, function()
		local h = {}
		install_doubles(h)
		h.guide = require("ui.permission_dialog.login_items_guide")
		--- Fires the live poll once, as its timer would.
		function h.tick()
			local timer = h.timers[#h.timers]
			if timer and not timer.cancelled then timer.fn() end
		end
		--- Closes the steps as the user does, with Later or the close button.
		function h.user_closes()
			local open = h.open
			h.open = nil
			if open and open.on_closed then
				local on_closed = open.on_closed
				open.on_closed = nil
				on_closed()
			end
		end
		--- Counts the log lines of one level.
		function h.count(level)
			local count = 0
			for _, entry in ipairs(h.logs) do
				if entry.level == level then count = count + 1 end
			end
			return count
		end
		body(h)
	end)
end

helpers.describe("Login Items approval guide (guardian-approval-steps)", function()
	helpers.it("shows the steps once per launch while the guardian awaits approval", function()
		with_guide(function(h)
			helpers.assert_true(h.guide.offer(h.remap) == true, "the first approval answer shows the steps")
			helpers.assert_eq(#h.shows, 1)
			helpers.assert_eq(h.shows[1].kind, "login_items", "the same dialog, its Login Items variant")
			helpers.assert_eq(#h.timers, 1, "a poll watches for the approval")
			helpers.assert_eq(h.timers[1].seconds, h.guide.POLL_SECONDS)

			helpers.assert_true(h.guide.offer(h.remap) == false, "a second automatic offer is declined")
			h.user_closes()
			helpers.assert_true(h.guide.offer(h.remap) == false, "Later is not undone by the next answer")
			helpers.assert_eq(#h.shows, 1, "the steps were shown once in this launch")

			helpers.assert_true(h.guide.reopen(h.remap) == true, "the menu row brings them back on request")
			helpers.assert_eq(#h.shows, 2)
			helpers.assert_eq(h.count("error"), 0, "an approval not given yet is not an error")
		end)
	end)

	helpers.it("leaves the banner to a user whose Tap-Holds are off", function()
		with_guide(function(h)
			h.remap.tap_holds = false
			helpers.assert_true(h.guide.offer(h.remap) == false,
				"without Tap-Holds the menu has no guardian row to come back to")
			helpers.assert_eq(#h.shows, 0)
			helpers.assert_eq(#h.timers, 0, "no poll is armed for steps not shown")
			h.remap.tap_holds = true
			helpers.assert_true(h.guide.offer(h.remap) == true, "the declined offer does not spend the launch's one")
		end)
	end)

	helpers.it("shows nothing when the guardian is ready or the integration is off", function()
		with_guide(function(h)
			for _, state in ipairs({ "ready", "not_used", "unavailable", "unknown" }) do
				h.remap.state = state
				helpers.assert_true(h.guide.offer(h.remap) == false, state .. " needs no approval steps")
				helpers.assert_true(h.guide.reopen(h.remap) == false, state .. " has no steps to reopen")
			end
			helpers.assert_eq(#h.shows, 0)
			helpers.assert_eq(#h.timers, 0, "nothing to wait for arms no poll")
			h.remap.state = "requires_approval"
			helpers.assert_true(h.guide.offer(h.remap) == true, "a declined offer does not spend the launch's one")
		end)
	end)

	helpers.it("closes itself and stops polling once the guardian is ready", function()
		with_guide(function(h)
			h.guide.offer(h.remap)
			h.tick()
			helpers.assert_true(h.open ~= nil, "the steps stay while approval is missing")
			h.remap.state = "unknown"
			h.tick()
			helpers.assert_true(h.open ~= nil, "a failed probe is not an approval")
			h.remap.state = "ready"
			h.tick()
			helpers.assert_nil(h.open, "the guardian's approval closes the steps")
			helpers.assert_true(h.timers[1].cancelled, "the poll stops with them")
			helpers.assert_eq(h.count("start"), 1)
			helpers.assert_eq(h.count("success"), 1, "the wait is logged as a start/success pair")
			helpers.assert_true(h.guide.is_active() == false)
			helpers.assert_eq(h.count("error"), 0)
		end)
	end)

	helpers.it("closes the steps when the switch is turned off meanwhile", function()
		with_guide(function(h)
			h.guide.offer(h.remap)
			h.remap.state = "not_used"
			h.tick()
			helpers.assert_nil(h.open)
			helpers.assert_true(h.timers[1].cancelled)
		end)
	end)

	helpers.it("stops polling as soon as the user closes the steps", function()
		with_guide(function(h)
			h.guide.offer(h.remap)
			h.user_closes()
			helpers.assert_true(h.timers[1].cancelled, "Later stops the poll at once, not at its next tick")
			helpers.assert_true(h.guide.is_active() == false)
			helpers.assert_eq(h.count("error"), 0, "closing the steps for later is not an error")
			helpers.assert_eq(h.count("warn"), 1, "the pending approval stays visible in the log")
		end)
	end)

	helpers.it("waits for the Accessibility steps to close before showing its own", function()
		with_guide(function(h)
			h.accessibility_open = true
			helpers.assert_true(h.guide.offer(h.remap) == true, "the steps are queued, not dropped")
			helpers.assert_eq(#h.shows, 0, "never shown while the Accessibility steps are open")
			h.tick()
			helpers.assert_eq(#h.shows, 0)
			h.accessibility_open = false
			h.tick()
			helpers.assert_eq(#h.shows, 1, "shown right after the Accessibility steps close")
			helpers.assert_eq(h.shows[1].kind, "login_items")
			helpers.assert_true(h.guide.offer(h.remap) == false, "the queued steps were this launch's offer")
		end)
	end)

	helpers.it("drops queued steps when the guardian is approved first", function()
		with_guide(function(h)
			h.accessibility_open = true
			h.guide.offer(h.remap)
			h.remap.state = "ready"
			h.tick()
			h.accessibility_open = false
			h.tick()
			helpers.assert_eq(#h.shows, 0, "steps for an approval already given never open")
			helpers.assert_true(h.timers[1].cancelled)
		end)
	end)

	helpers.it("closes the steps and stops polling at its deadline", function()
		with_guide(function(h)
			h.guide.offer(h.remap)
			local ticks = h.guide.DEADLINE_SECONDS / h.guide.POLL_SECONDS
			for _ = 1, ticks - 1 do h.tick() end
			helpers.assert_true(h.open ~= nil, "still open before the deadline")
			h.tick()
			helpers.assert_nil(h.open, "a forgotten dialog does not stay up for good")
			helpers.assert_true(h.timers[1].cancelled, "the poll is bounded")
			helpers.assert_eq(h.count("error"), 0)
		end)
	end)

	helpers.it("opens Login Items from its button and says so when it cannot", function()
		with_guide(function(h)
			h.guide.offer(h.remap)
			helpers.assert_true(h.shows[1].open_settings() == true)
			helpers.assert_eq(h.remap.opens, 1, "the button reuses the Login Items opener")
			helpers.assert_eq(#h.notices, 0)
			h.remap.open_ok = false
			h.shows[1].open_settings()
			helpers.assert_eq(#h.notices, 1)
			helpers.assert_eq(h.notices[1].message, "karabiner.guardian_settings_open_failed")
		end)
	end)

	helpers.it("keeps no poll when the steps cannot be shown", function()
		with_guide(function(h)
			h.show_fails = true
			helpers.assert_true(h.guide.offer(h.remap) == false, "the notice keeps its banner")
			helpers.assert_true(h.timers[1].cancelled, "a guide without steps polls nothing")
			helpers.assert_true(h.guide.is_active() == false)
		end)
	end)

	helpers.it("refuses a remap facade without its state and opener", function()
		with_guide(function(h)
			helpers.assert_true(not pcall(h.guide.offer, {}), "an incomplete facade must fail fast")
			helpers.assert_true(not pcall(h.guide.reopen, nil))
		end)
	end)
end)

-- A controlled reload or quit ends with TimerScheduler.cancelAll(); the poll
-- is a scheduler timer, so it is stopped there like every other one.
helpers.describe("the Login Items poll ends with a reload (guardian-approval-steps)", function()
	helpers.it("is owned by the scheduler that reload cancels", function()
		helpers.with_stub_scope(MODULES, function()
			local h = {}
			install_doubles(h)
			package.loaded["adapters.timer_scheduler"] = nil
			local Scheduler = helpers.load_with_stubs("adapters.timer_scheduler")
			local guide = require("ui.permission_dialog.login_items_guide")
			helpers.assert_true(guide.offer(h.remap) == true)
			local natives = hs.timer.__timers
			local native = natives[#natives]
			helpers.assert_true(native ~= nil and native.running == true, "the poll is a live scheduler timer")
			helpers.assert_eq(Scheduler.activeCount(), 1)
			helpers.assert_true(Scheduler.cancelAll() == true, "the reload teardown stops it")
			helpers.assert_true(native.running == false)
			helpers.assert_eq(Scheduler.activeCount(), 0)
		end)
	end)
end)
