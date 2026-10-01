--- linux/tests/unit/meta/test_updater_check_schedule.lua

--- ==============================================================================
--- MODULE: Updater Check Schedule (Linux)
--- DESCRIPTION:
--- The background update check follows the persisted check record and the
--- wall clock, not the daemon start. The manager used to fire a check
--- min(30 s, interval) after every start and then every interval on a luv
--- timer: a machine powered off every evening checked at each boot even on a
--- weekly setting, a suspend delayed the next check by the time spent asleep
--- (luv timers are monotonic), and a paused driver still checked.
---
--- Each case builds a fresh manager over a recording timer, a fake Storage port,
--- a temporary config.toml and an injected clock; check_for_updates is replaced
--- by a spy, so a dispatch is observed without any network.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

local SEED = "7f3a9c21e5b04d68"
local T0 = 1700000000

--- Builds a fresh manager and runs body(ctx). ctx: M, timers (every armed
--- timer, in order), storage, clock, dispatches (spied check callbacks),
--- config_path. The manager is an installed build's unless opts.source_run
--- says otherwise: the suite itself runs from a checkout, which checks for
--- nothing on its own.
local function with_manager(opts, body)
	local Installation = require("infra.installation")
	local real_is_source_run = Installation.is_source_run
	Installation.is_source_run = function() return opts.source_run == true end
	local previous = {}
	for _, name in ipairs({ "adapters.timer_scheduler", "adapters.storage", "modules.updater.manager" }) do
		previous[name] = package.loaded[name]
	end
	local ctx = { timers = {}, dispatches = {}, clock = { now = opts.now }, available = {} }
	local timer = { HAS_ASYNC = true }
	function timer.after(delay, fn)
		local handle = { armed = true, delay = delay, fn = fn }
		ctx.timers[#ctx.timers + 1] = handle
		return handle
	end
	function timer.cancel(handle)
		handle.armed = false
		return true
	end
	package.loaded["adapters.timer_scheduler"] = timer
	local initial = {}
	ctx.state_key = nil
	package.loaded["adapters.storage"] = nil
	package.loaded["modules.updater.manager"] = nil
	local probe = require("modules.updater.manager")
	ctx.state_key = probe.CHECK_STATE_KEY
	if opts.record then initial[ctx.state_key] = opts.record end
	ctx.storage = Fakes.storage({ initial = initial })
	package.loaded["adapters.storage"] = ctx.storage
	package.loaded["modules.updater.manager"] = nil
	ctx.M = require("modules.updater.manager")
	for name, value in pairs(previous) do package.loaded[name] = value end

	ctx.config_path = os.tmpname()
	pcall(os.remove, ctx.config_path)
	if opts.config then
		local handle = assert(io.open(ctx.config_path, "w"))
		handle:write(opts.config)
		handle:close()
	end
	ctx.M._now = function() return ctx.clock.now end
	ctx.M.current_version = function() return "1.0.0" end
	ctx.M.check_for_updates = function(_, callback)
		ctx.dispatches[#ctx.dispatches + 1] = callback
		return true
	end
	local ok, err = pcall(function()
		ctx.M.init({
			config_path = ctx.config_path,
			is_paused = function() return opts.paused == true end,
			on_available = function(release)
				ctx.available[#ctx.available + 1] = release.tag
				if ctx.notification_refusal == "throw" then error("notification unavailable") end
				return ctx.notification_refusal ~= "false"
			end,
		})
		body(ctx)
	end)
	ctx.M.stop_background_checks()
	Installation.is_source_run = real_is_source_run
	pcall(os.remove, ctx.config_path)
	if not ok then error(err, 0) end
end

--- The last armed timer.
local function last_timer(ctx)
	return ctx.timers[#ctx.timers]
end

--- Fires the last armed timer at the current clock.
local function fire(ctx)
	local handle = last_timer(ctx)
	helpers.assert_true(handle ~= nil and handle.armed == true, "a timer must be armed")
	handle.armed = false
	handle.fn()
end

local function record(ctx)
	return ctx.storage.get(ctx.state_key)
end

helpers.describe("updater (linux): the check schedule follows the persisted record", function()
	-- A local version run from source has no installation to update. It used
	-- to check on the schedule all the same, and announce releases it could
	-- not install; the tray now greys its update rows and nothing is armed.
	helpers.it("(update-rows-greyed-on-local-2026-10-01) a local version run from source arms no automatic check", function()
		with_manager({ now = T0, source_run = true }, function(ctx)
			helpers.assert_eq(#ctx.timers, 0, "no check is scheduled on a source run")
			helpers.assert_eq(#ctx.dispatches, 0, "and none is dispatched")
		end)
		with_manager({ now = T0 }, function(ctx)
			helpers.assert_true(#ctx.timers > 0, "an installed build still schedules its check")
		end)
	end)

	helpers.it("notification refusal leaves the release retryable", function()
		for _, refusal in ipairs({ "false", "throw" }) do
			with_manager({ now = T0, record = { seed = SEED } }, function(ctx)
				ctx.notification_refusal = refusal
				ctx.clock.now = ctx.clock.now + ctx.M.TIMING.boot_check_delay_sec
				fire(ctx)
				ctx.dispatches[1](true, { tag = "v1.4.0" }, nil)
				helpers.assert_eq(#ctx.available, 1, "the refusal must occur at the notification boundary")
				helpers.assert_nil(record(ctx).last_notified_tag,
					"a refused notification must not consume the release: " .. refusal)
				ctx.notification_refusal = nil
				ctx.clock.now = ctx.clock.now + 2 * 86400
				fire(ctx)
				ctx.clock.now = ctx.clock.now + ctx.M.TIMING.boot_check_delay_sec
				fire(ctx)
				ctx.dispatches[2](true, { tag = "v1.4.0" }, nil)
				helpers.assert_eq(#ctx.available, 2, "the next successful check must retry the announcement")
				helpers.assert_eq(record(ctx).last_notified_tag, "v1.4.0")
			end)
		end
	end)

	helpers.it("a restart mid-interval does not check at boot", function()
		with_manager({ now = T0 + 3600, record = { seed = SEED, last_check_at = T0, failures = 0 } }, function(ctx)
			local reevaluate = ctx.M.TIMING.reevaluate_sec
			helpers.assert_eq(last_timer(ctx).delay, reevaluate,
				"a far due time is re-evaluated after the bounded period, not after the boot delay")
			ctx.clock.now = ctx.clock.now + reevaluate
			fire(ctx)
			helpers.assert_eq(#ctx.dispatches, 0, "a check done an hour ago is not due")
			helpers.assert_true(last_timer(ctx).armed, "the schedule keeps one armed timer")
		end)
	end)

	helpers.it("an overdue check catches up after the boot delay and is recorded", function()
		with_manager({
			now = T0 + 10 * 86400,
			config = "[updater]\ncheck_interval_seconds = 604800\n",
			record = { seed = SEED, last_check_at = T0, failures = 0 },
		}, function(ctx)
			local boot = ctx.M.TIMING.boot_check_delay_sec
			helpers.assert_eq(ctx.M.get_check_interval(), 604800, "the interval is read from config.toml")
			helpers.assert_eq(last_timer(ctx).delay, boot, "an overdue weekly check waits for the boot delay")
			ctx.clock.now = ctx.clock.now + boot
			fire(ctx)
			helpers.assert_eq(#ctx.dispatches, 1, "the overdue check is dispatched")
			helpers.assert_eq(last_timer(ctx).delay, ctx.M.TIMING.reevaluate_sec,
				"a due evaluation re-arms for the bounded period")
			ctx.dispatches[1](false, nil, nil)
			local saved = record(ctx)
			helpers.assert_eq(saved.last_check_at, ctx.clock.now, "the completed check is recorded")
			helpers.assert_eq(saved.last_success_at, ctx.clock.now)
			helpers.assert_eq(saved.failures, 0)
			helpers.assert_eq(saved.seed, SEED, "the install seed survives every record")
		end)
	end)

	helpers.it("a failed check retries on the shared backoff", function()
		with_manager({ now = T0, record = { seed = SEED, last_check_at = T0 - 2 * 86400 } }, function(ctx)
			ctx.clock.now = ctx.clock.now + ctx.M.TIMING.boot_check_delay_sec
			fire(ctx)
			helpers.assert_eq(#ctx.dispatches, 1)
			ctx.dispatches[1](false, nil, "offline")
			local saved = record(ctx)
			helpers.assert_eq(saved.failures, 1, "a failure is counted")
			helpers.assert_nil(saved.last_success_at, "a failure is not a success")
			ctx.clock.now = ctx.clock.now + ctx.M.TIMING.failure_backoff_sec[1]
			fire(ctx)
			helpers.assert_eq(#ctx.dispatches, 2, "the first backoff has passed: the check runs again")
		end)
	end)

	helpers.it("a paused driver dispatches nothing and leaves the record", function()
		local before = { seed = SEED, last_check_at = T0 - 2 * 86400, failures = 0 }
		with_manager({ now = T0, paused = true, record = before }, function(ctx)
			ctx.clock.now = ctx.clock.now + ctx.M.TIMING.boot_check_delay_sec
			fire(ctx)
			helpers.assert_eq(#ctx.dispatches, 0, "the pause holds the due check")
			helpers.assert_eq(record(ctx).last_check_at, T0 - 2 * 86400, "the record is left as it is")
			helpers.assert_true(last_timer(ctx).armed, "the schedule survives the pause")
		end)
	end)

	helpers.it("a wake restarts the boot delay before a catch-up check", function()
		with_manager({ now = T0 + 3600, record = { seed = SEED, last_check_at = T0, failures = 0 } }, function(ctx)
			local armed = last_timer(ctx).delay
			-- The monotonic timer slept with the machine: it fires on the timer's
			-- schedule while the wall clock moved two days.
			ctx.clock.now = ctx.clock.now + 2 * 86400
			fire(ctx)
			helpers.assert_eq(#ctx.dispatches, 0, "the network gets the boot delay after the wake")
			helpers.assert_eq(last_timer(ctx).delay, ctx.M.TIMING.boot_check_delay_sec,
				"the overdue check waits for the boot delay from the wake")
			helpers.assert_true(armed > 0)
			ctx.clock.now = ctx.clock.now + ctx.M.TIMING.boot_check_delay_sec
			fire(ctx)
			helpers.assert_eq(#ctx.dispatches, 1, "the catch-up check runs after the delay")
		end)
	end)

	helpers.it("a release is announced once, across restarts", function()
		local previous = { seed = SEED, last_check_at = T0 - 2 * 86400, last_notified_tag = "v1.3.0" }
		with_manager({ now = T0, record = previous }, function(ctx)
			ctx.clock.now = ctx.clock.now + ctx.M.TIMING.boot_check_delay_sec
			fire(ctx)
			ctx.dispatches[1](true, { tag = "v1.3.0" }, nil)
			helpers.assert_eq(#ctx.available, 0, "a release announced before the restart is not announced again")
			-- A day and more later (a wake, then the boot delay), the next check.
			ctx.clock.now = ctx.clock.now + 2 * 86400
			fire(ctx)
			ctx.clock.now = ctx.clock.now + ctx.M.TIMING.boot_check_delay_sec
			fire(ctx)
			helpers.assert_eq(#ctx.dispatches, 2, "the next check ran")
			ctx.dispatches[2](true, { tag = "v1.4.0" }, nil)
			helpers.assert_eq(ctx.available, { "v1.4.0" }, "a new release is announced once")
			helpers.assert_eq(record(ctx).last_notified_tag, "v1.4.0", "and persisted")
		end)
	end)

	helpers.it("the interval lives in config.toml and snaps to a preset", function()
		with_manager({ now = T0, config = "[updater]\ncheck_interval_seconds = 7200\n" }, function(ctx)
			helpers.assert_eq(ctx.M.get_check_interval(), 3600, "a retired 2 hours snaps to 1 hour")
			helpers.assert_true(ctx.M.set_check_interval(21600))
			local handle = assert(io.open(ctx.config_path, "r"))
			local decoded = require("toml_codec").decode(handle:read("*a"))
			handle:close()
			helpers.assert_eq(decoded.updater.check_interval_seconds, 21600, "the choice is written to config.toml")
			local marked = {}
			ctx.M.mark_config_reads(decoded, function(...) marked[#marked + 1] = table.concat({ ... }, ".") end)
			helpers.assert_eq(marked, { "updater.check_interval_seconds" },
				"the unused-key cleanup must not offer the interval")
		end)
	end)
end)
