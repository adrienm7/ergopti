--- tests/unit/infra/logger/test_key_event_health.lua

--- ==============================================================================
--- MODULE: key_event_health Unit Tests
--- DESCRIPTION:
--- Pins the per-session key pairing counters the next macOS issue report
--- carries (issues #99 and #100: swallowed keys and an accent popup on a plain
--- tap, with no log line able to say whether a key-down or a key-up went
--- missing). Lost key-ups, orphan key-ups, stuck keys, long holds across a rule
--- switch, late tap callbacks and lease failures are counted; no key code or
--- character ever reaches a log line.
--- ==============================================================================

local helpers = require("tests.helpers")

local function noop() end

helpers.describe("infra.key_event_health (key-event-pairing)", function()
	local saved = {
		logger = package.loaded["infra.logger"],
		deferred = package.loaded["infra.deferred_work"],
		timer = package.loaded["adapters.timer_scheduler"],
		clock = package.loaded["adapters.event_clock"],
		subject = package.loaded["infra.key_event_health"],
		hs = _G.hs,
	}
	local lines = {}
	local deferred = {}
	local host_ns = 0
	package.loaded["infra.logger"] = {
		warn = function(_, fmt, ...) lines[#lines + 1] = { level = "warn", text = string.format(fmt, ...) } end,
		info = function(_, fmt, ...) lines[#lines + 1] = { level = "info", text = string.format(fmt, ...) } end,
		debug = noop, error = noop,
	}
	package.loaded["infra.deferred_work"] = {
		after = function(_, callback) deferred[#deferred + 1] = callback; return true end,
	}
	package.loaded["adapters.timer_scheduler"] = { now_ns = function() return host_ns end }
	_G.hs = { timer = { absoluteTime = function() return host_ns end } }
	package.loaded["adapters.event_clock"] = nil
	package.loaded["infra.key_event_health"] = nil
	local EventClock = require("adapters.event_clock")
	local Health = require("infra.key_event_health")

	local UPTIME_NS = 3600 * 1e9
	local KEY_A = 0
	local KEY_E = 14

	--- A physical event stamped `ms_ago` milliseconds before the host clock, on
	--- an Apple silicon Mac whose stamps are 125/3 ns ticks.
	local function stamped(ms_ago)
		local stamp = math.floor((host_ns - ms_ago * 1e6) * 3 / 125)
		return { timestamp = function() return stamp end }
	end

	local function observe(phase, key, ms_ago, autorepeat)
		local lateness, stamp = EventClock.lateness_ms(stamped(ms_ago or 0))
		Health.observe(phase, key, autorepeat == true, true, lateness, stamp)
	end

	--- What the keymap tap watchdog does every second, off the taps.
	local function flush()
		helpers.assert_eq(#deferred, 0, "recording never arms a timer inside the event tap")
		Health.flush()
	end

	local function reset()
		Health.reset()
		EventClock.reset()
		lines, deferred = {}, {}
		host_ns = UPTIME_NS
	end

	helpers.it("reads lateness under the clock scale that makes the age plausible", function()
		reset()
		helpers.assert_eq(EventClock.lateness_ms(stamped(2)), 0, "a fresh event is never late")
		local lateness = EventClock.lateness_ms(stamped(42))
		helpers.assert_true(lateness ~= nil and math.abs(lateness - 40) < 0.01, tostring(lateness))
		EventClock.reset()
		local intel_stamp = math.floor(host_ns - 12 * 1e6)
		helpers.assert_eq(EventClock.lateness_ms({ timestamp = function() return intel_stamp end }), 0)
		local late_intel = math.floor(host_ns - 312 * 1e6)
		local intel_late = EventClock.lateness_ms({ timestamp = function() return late_intel end })
		helpers.assert_true(intel_late ~= nil and math.abs(intel_late - 300) < 0.01, tostring(intel_late))
		helpers.assert_nil(EventClock.lateness_ms({ timestamp = function() return 0 end }),
			"a synthesized event (stamp 0) has no provable age")
		helpers.assert_nil(EventClock.lateness_ms({}), "an event without a stamp has no age")
	end)

	helpers.it("reads the right scale half a minute after boot", function()
		reset()
		host_ns = 30 * 1e9
		helpers.assert_eq(EventClock.lateness_ms(stamped(1)), 0)
		local lateness = EventClock.lateness_ms(stamped(301))
		helpers.assert_true(lateness ~= nil and math.abs(lateness - 300) < 0.01,
			"the wrong scale reads a tick stamp as the whole uptime and must lose: " .. tostring(lateness))
	end)

	helpers.it("cancels a constant offset between the stamp clock and the host clock", function()
		reset()
		-- Every event reads 20 s old, as a stamp domain that also counted a
		-- short sleep would: none of them is late.
		for _ = 1, 3 do
			helpers.assert_eq(EventClock.lateness_ms(stamped(20000)), 0)
			host_ns = host_ns + 100 * 1e6
		end
		local lateness = EventClock.lateness_ms(stamped(20500))
		helpers.assert_true(math.abs(lateness - 500) < 0.01, tostring(lateness))
	end)

	helpers.it("pairs a normal tap and logs nothing", function()
		reset()
		observe("down", KEY_A, 1)
		host_ns = host_ns + 80 * 1e6
		observe("up", KEY_A, 1)
		flush()
		local counts = Health.counts()
		helpers.assert_eq(counts.downs, 1)
		helpers.assert_eq(counts.ups, 1)
		helpers.assert_eq(counts.ups_without_down + counts.downs_without_up + counts.stuck, 0)
		helpers.assert_eq(#lines, 0, "a healthy tap is not news")
	end)

	helpers.it("counts a lost key-up, an orphan key-up and a stuck key, never naming the key", function()
		reset()
		observe("down", KEY_A, 1)
		host_ns = host_ns + 50 * 1e6
		observe("down", KEY_A, 1)
		observe("up", KEY_E, 1)
		host_ns = host_ns + (Health.STUCK_MS + 10) * 1e6
		observe("down", KEY_E, 1)
		flush()
		local counts = Health.counts()
		helpers.assert_eq(counts.downs_without_up, 1, "a second press of a key still down lost a key-up")
		helpers.assert_eq(counts.ups_without_down, 1, "a key-up with no press before it")
		helpers.assert_eq(counts.stuck, 1, "a key silent for STUCK_MS lost its key-up")
		helpers.assert_true(#lines >= 3, "each anomaly is one deferred line")
		for _, line in ipairs(lines) do
			helpers.assert_eq(line.level, "warn")
			helpers.assert_true(line.text:find("session totals:", 1, true) ~= nil, line.text)
			helpers.assert_nil(line.text:find("keycode", 1, true), line.text)
			helpers.assert_nil(line.text:find(" 14", 1, true), "no key code in the line: " .. line.text)
		end
	end)

	helpers.it("logs a long character hold with its autorepeats and the rule switch it crossed", function()
		reset()
		observe("down", KEY_A, 1)
		host_ns = host_ns + 300 * 1e6
		observe("down", KEY_A, 1, true)
		Health.note_transition("a karabiner.json reload")
		host_ns = host_ns + 400 * 1e6
		observe("up", KEY_A, 1)
		helpers.assert_eq(#lines, 0, "nothing is written inside the event tap")
		flush()
		local counts = Health.counts()
		helpers.assert_eq(counts.long_holds, 1)
		helpers.assert_eq(counts.long_holds_across_transition, 1)
		helpers.assert_eq(counts.repeats, 1)
		helpers.assert_eq(#lines, 1)
		helpers.assert_eq(lines[1].level, "info")
		helpers.assert_true(lines[1].text:find("stayed down 700 ms", 1, true) ~= nil, lines[1].text)
		helpers.assert_true(lines[1].text:find("1 autorepeat(s), across a karabiner.json reload", 1, true) ~= nil,
			lines[1].text)
	end)

	helpers.it("measures a hold with the window server's stamps, not the late callbacks", function()
		reset()
		-- A tap that is 80 ms long for macOS, both edges seen 900 ms late after a
		-- main-thread stall: no long hold, two late callbacks.
		observe("down", KEY_E, 1)
		observe("up", KEY_E, 1)
		host_ns = host_ns + 900 * 1e6
		observe("down", KEY_A, 900)
		host_ns = host_ns + 80 * 1e6
		observe("up", KEY_A, 900)
		flush()
		local counts = Health.counts()
		helpers.assert_eq(counts.long_holds, 0)
		helpers.assert_eq(counts.late_downs, 1)
		helpers.assert_eq(counts.late_ups, 1)
		helpers.assert_true(math.abs(counts.max_late_ms - 899) < 0.01, "measured from the freshest recent event")
		helpers.assert_eq(#lines, 1, "one line per turn for a burst of late events")
		helpers.assert_true(lines[1].text:find("(2 times)", 1, true) ~= nil, lines[1].text)
	end)

	helpers.it("counts lease failures by kind in the session totals", function()
		reset()
		observe("down", KEY_A, 1)
		Health.note_lease_failure("timeout waiting for PONG 221")
		Health.note_lease_failure("timeout waiting for READY")
		Health.note_lease_failure("watchdog exited unexpectedly (exit 73): ")
		flush()
		local counts = Health.counts()
		helpers.assert_eq(counts.lease.pong, 1)
		helpers.assert_eq(counts.lease.ready, 1)
		helpers.assert_eq(counts.lease.worker_exit, 1)
		helpers.assert_true(Health.summary():find("3 Karabiner lease failure(s) (pong=1, ready=1, worker_exit=1)", 1, true) ~= nil,
			Health.summary())
	end)

	package.loaded["infra.logger"] = saved.logger
	package.loaded["infra.deferred_work"] = saved.deferred
	package.loaded["adapters.timer_scheduler"] = saved.timer
	package.loaded["adapters.event_clock"] = saved.clock
	package.loaded["infra.key_event_health"] = saved.subject
	_G.hs = saved.hs
end)
