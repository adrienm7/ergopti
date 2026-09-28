--- tests/unit/modules/gestures/test_periodic_logs_on_change.lua

--- ==============================================================================
--- MODULE: Gesture Periodic Loops Log On Change Only
--- DESCRIPTION:
--- The gestures module runs three recurring diagnostics: the 30 s health check,
--- the primer eventtap that sees every scroll and gesture event, and the touch
--- frame callback that fires about a hundred times a second while a finger is
--- down. Each logged on every pass, with a changing counter in the text, so a
--- day at DEBUG level wrote thousands of lines that the logger could not
--- deduplicate and that said nothing new.
---
--- ROOT CAUSE ENCODED:
--- A poll logged its pass instead of its news. The rule pinned here is the one
--- the Windows idle gate already follows: log a state when it changes.
--- 1. The health check reports its settled watcher count once, then only when
---    that count changes, and each change survives repeat collapsing, which
---    would otherwise fold every change into the first report's streak.
--- 2. The primer's per-event line exists to diagnose touchdevice dormancy, so it
---    logs only before the first frame arrived.
--- 3. The frame heartbeat logs at most once per touch session (fingers down to
---    all fingers lifted), not every 120 frames.
--- ==============================================================================

local helpers = require("tests.helpers")
local Replay  = require("tests.support.repeat_collapsing_replay")





-- ===========================================
-- ===========================================
-- ======= 1/ Isolated Runtime Fixture =======
-- ===========================================
-- ===========================================

local MODULE_NAMES = {
	"adapters.timer_scheduler",
	"hs",
	"hs._asm.undocumented.touchdevice",
	"hs.caffeinate.watcher",
	"infra.logger",
	"infra.manifest_reader",
	"infra.notifications",
	"infra.timings",
	"modules.gestures",
	"modules.gestures.actions",
	"modules.gestures.conflicts",
	"modules.gestures.engine",
	"modules.gestures.init",
	"tests.stubs.hs",
}

--- Runs one scenario against a fresh gesture module with every log line
--- captured, and restores every global and module afterwards.
--- @param scenario function Receives (gestures, runtime).
local function with_fixture(scenario)
	local saved_modules = {}
	for _, name in ipairs(MODULE_NAMES) do
		saved_modules[name] = package.loaded[name]
		package.loaded[name] = nil
	end
	local saved_hs = _G.hs
	local saved_devices = _G.ERGOPTI_TOUCH_DEVICES
	local saved_watchers = _G.ERGOPTI_TOUCH_WATCHERS
	local saved_tokens = _G.ERGOPTI_TOUCH_WATCHER_TOKENS
	local saved_sleep = _G.ERGOPTI_SLEEP_WATCHER
	local saved_primer = _G.ERGOPTI_GESTURE_PRIMER
	local saved_first_frame = _G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME

	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	_G.ERGOPTI_TOUCH_DEVICES = {}
	_G.ERGOPTI_TOUCH_WATCHERS = {}
	_G.ERGOPTI_TOUCH_WATCHER_TOKENS = {}
	_G.ERGOPTI_SLEEP_WATCHER = nil
	_G.ERGOPTI_GESTURE_PRIMER = nil
	local saved_epoch = hs_stub.timer.secondsSinceEpoch

	local runtime = { lines = {}, device_ids = { 42 }, timers = {}, primer_handles = {} }

	local function noop() end
	local function capture(level)
		return function(module_name, message, ...)
			local text = select("#", ...) > 0 and string.format(message, ...) or tostring(message)
			-- The raw call is kept too, so a test can replay it through the core
			-- with repeat collapsing armed and see what the log really keeps.
			runtime.lines[#runtime.lines + 1] = {
				level = level, text = text,
				module = module_name, msg = message, args = table.pack(...),
			}
		end
	end
	local logger = setmetatable({
		debug = capture("debug"), trace = capture("trace"), done = capture("done"),
		info = capture("info"), start = capture("start"), success = capture("success"),
		warn = capture("warn"), error = capture("error"),
		pcall = function(_, fn, ...) return pcall(fn, ...) end,
	}, { __index = function() return noop end })
	package.loaded["infra.logger"] = logger
	package.loaded["infra.manifest_reader"] = {
		default_for = function() return false end,
		recommended_for = function() return "none" end,
	}
	package.loaded["infra.notifications"] = { notify = noop }
	package.loaded["infra.timings"] = {
		sec = function(_, key)
			if key == "health_check_interval_ms" then return 30 end
			if key == "startup_phase_timeout_ms" then return 10 end
			return 5
		end,
	}
	package.loaded["modules.gestures.actions"] = setmetatable({
		AX_NAMES = {},
		SG_NAMES = {},
		init = noop,
		force_cleanup = function() return true end,
		resume_after_cleanup = function() return true end,
	}, { __index = function() return noop end })
	package.loaded["modules.gestures.engine"] = setmetatable({
		init = function() return true end,
		process_frame = noop,
		stop = function() return true end,
		cancel_current_gesture = function() return true end,
		emergency_reset = noop,
	}, { __index = function() return noop end })
	package.loaded["modules.gestures.conflicts"] = setmetatable({}, {
		__index = function() return noop end,
	})

	local scheduler = {}
	function scheduler.every(interval_sec, callback)
		local handle = { active = true, callback = callback, interval_sec = interval_sec }
		runtime.timers[#runtime.timers + 1] = handle
		return handle, true
	end
	function scheduler.cancel(handle)
		if handle then handle.active = false end
		return true
	end
	package.loaded["adapters.timer_scheduler"] = scheduler

	-- One running watcher per device, as a healthy touchdevice delivers.
	local function new_watcher()
		local watcher = { running_state = false }
		function watcher:start() self.running_state = true return self end
		function watcher:stop() self.running_state = false return self end
		function watcher:running() return self.running_state end
		function watcher:alive() return true end
		return watcher
	end
	local function new_device(id)
		local device = {
			deviceID = function() return id end,
			builtin = function() return true end,
			alive = function() return true end,
			running = function() return true end,
			MTHIDDevice = function() return true end,
			driverReady = function() return true end,
			productName = function() return "Test Trackpad" end,
		}
		function device:frameCallback(callback)
			runtime.frame_callback = callback
			return new_watcher()
		end
		return device
	end
	package.loaded["hs._asm.undocumented.touchdevice"] = {
		devices = function() return runtime.device_ids end,
		forDeviceID = function(id) return new_device(id) end,
	}

	hs_stub.eventtap.new = function(_, callback)
		local handle = { callback = callback, running = false }
		runtime.primer_handles[#runtime.primer_handles + 1] = handle
		function handle:start() self.running = true return self end
		function handle:stop() self.running = false return self end
		function handle:isEnabled() return self.running end
		return handle
	end
	package.loaded["hs.caffeinate.watcher"] = {
		systemDidWake = 1,
		screensDidUnlock = 2,
		new = function(callback)
			local handle = { callback = callback, running = false }
			function handle:start() self.running = true return self end
			function handle:stop() self.running = false return self end
			return handle
		end,
	}

	local gestures = require("modules.gestures.init")
	local ok, err = xpcall(function() scenario(gestures, runtime) end, debug.traceback)
	pcall(gestures.stop)
	hs_stub.timer.secondsSinceEpoch = saved_epoch

	_G.hs = saved_hs
	_G.ERGOPTI_TOUCH_DEVICES = saved_devices
	_G.ERGOPTI_TOUCH_WATCHERS = saved_watchers
	_G.ERGOPTI_TOUCH_WATCHER_TOKENS = saved_tokens
	_G.ERGOPTI_SLEEP_WATCHER = saved_sleep
	_G.ERGOPTI_GESTURE_PRIMER = saved_primer
	_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME = saved_first_frame
	for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = saved_modules[name] end

	if not ok then error(err, 0) end
end

--- Counts captured lines whose text contains `needle`, optionally at one level.
--- @param runtime table
--- @param needle string
--- @param level string|nil
--- @return number
local function count_lines(runtime, needle, level)
	local count = 0
	for _, line in ipairs(runtime.lines) do
		if line.text:find(needle, 1, true) and (level == nil or line.level == level) then
			count = count + 1
		end
	end
	return count
end

--- One frame with `n` fingers, shaped like touchdevice's payload.
--- @param n number
--- @return table
local function touches(n)
	local list = {}
	for i = 1, n do
		list[i] = { absoluteVector = { position = { x = 10 * i, y = 20 } } }
	end
	return list
end





-- ===============================
-- ===============================
-- ======= 2/ Health Check =======
-- ===============================
-- ===============================

helpers.describe("gestures health check logs on change only", function()
	helpers.it("reports the watcher count once, then only when it changes", function()
		with_fixture(function(gestures, runtime)
			helpers.assert_eq(gestures.start(), true, "fixture: gestures must start")
			_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME = true
			runtime.timers[1].callback()
			local health = runtime.timers[#runtime.timers]
			helpers.assert_eq(health.interval_sec, 30, "fixture: the health-check loop must be armed")

			runtime.lines = {}
			for _ = 1, 10 do health.callback() end
			helpers.assert_eq(count_lines(runtime, "Health-check tick"), 0,
				"a stable tick must not log its pass")
			helpers.assert_eq(count_lines(runtime, "Health-check: 1 watcher(s) attached"), 1,
				"the first tick reports the settled watcher count exactly once")
			local stable = #runtime.lines
			helpers.assert_eq(stable, 1, "ten stable ticks must write one line in total")

			-- A second trackpad appears: the count changes and is reported once.
			runtime.device_ids = { 42, 43 }
			health.callback()
			health.callback()
			helpers.assert_eq(count_lines(runtime, "Health-check: 2 watcher(s) attached", "info"), 1,
				"a changed watcher count must be reported once, at info")
		end)
	end)

	helpers.it("keeps every watcher-count change in the log once repeat collapsing is armed", function()
		with_fixture(function(gestures, runtime)
			helpers.assert_eq(gestures.start(), true, "fixture: gestures must start")
			_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME = true
			runtime.timers[1].callback()
			local health = runtime.timers[#runtime.timers]

			runtime.lines = {}
			health.callback()
			runtime.device_ids = { 42, 43 }
			health.callback()
			runtime.device_ids = { 42, 43, 44 }
			health.callback()

			local calls = {}
			for _, line in ipairs(runtime.lines) do
				if line.text:find("Health-check:", 1, true) then
					calls[#calls + 1] = { variant = line.level, module = line.module, msg = line.msg, args = line.args }
				end
			end
			helpers.assert_eq(#calls, 3, "fixture: three different watcher counts must be reported")
			-- Collapsing keys an info line on its unformatted template: a change
			-- passed as format arguments would fold into the first report's streak
			-- and reach the log only as a summary up to a window later.
			helpers.assert_eq(#Replay.delivered(calls), 3,
				"each watcher-count change is news and must be written when it happens")
		end)
	end)

	helpers.it("reports the settled count again when the loop is re-entered", function()
		with_fixture(function(gestures, runtime)
			helpers.assert_eq(gestures.start(), true, "fixture: gestures must start")
			_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME = true
			runtime.timers[1].callback()
			local health = runtime.timers[#runtime.timers]
			health.callback()
			helpers.assert_eq(count_lines(runtime, "Health-check: 1 watcher(s) attached"), 1,
				"fixture: the first loop reports its settled count")

			-- The frame stream is lost, the startup probe takes over, frames flow
			-- again and the loop is re-entered with the same count.
			_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME = false
			health.callback()
			local probe = runtime.timers[#runtime.timers]
			helpers.assert_true(probe ~= health, "fixture: a lost stream must re-arm the startup probe")
			_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME = true
			probe.callback()
			local again = runtime.timers[#runtime.timers]
			helpers.assert_true(again ~= probe, "fixture: the first frame must re-enter the health-check loop")
			again.callback()
			helpers.assert_eq(count_lines(runtime, "Health-check: 1 watcher(s) attached"), 2,
				"the recovered loop must report the count it reached, even when it did not change")
		end)
	end)
end)





-- =========================
-- =========================
-- ======= 3/ Primer =======
-- =========================
-- =========================

helpers.describe("gestures primer logs only before the first frame", function()
	helpers.it("is silent for every event once frames are flowing", function()
		with_fixture(function(gestures, runtime)
			helpers.assert_eq(gestures.start(), true, "fixture: gestures must start")
			local primer = runtime.primer_handles[#runtime.primer_handles]
			local event = { getType = function() return 29 end }
			-- Each event arrives a full second after the previous one, so the old
			-- 5-per-second throttle can never be what keeps the log quiet.
			local now = 1000
			hs.timer.secondsSinceEpoch = function() now = now + 1 return now end

			runtime.lines = {}
			_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME = false
			primer.callback(event)
			helpers.assert_true(count_lines(runtime, "PRIMER") >= 1,
				"before the first frame the primer is the dormancy diagnostic and must log")

			runtime.lines = {}
			_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME = true
			for _ = 1, 20 do primer.callback(event) end
			helpers.assert_eq(count_lines(runtime, "PRIMER"), 0,
				"after the first frame every scroll and gesture event passes through the primer; "
				.. "logging them says nothing and floods the log")
		end)
	end)
end)





-- ==================================
-- ==================================
-- ======= 4/ Frame Heartbeat =======
-- ==================================
-- ==================================

helpers.describe("gestures frame heartbeat logs once per touch session", function()
	helpers.it("logs one line per session however long the fingers stay down", function()
		with_fixture(function(gestures, runtime)
			helpers.assert_eq(gestures.start(), true, "fixture: gestures must start")
			local frame = runtime.frame_callback
			helpers.assert_true(type(frame) == "function", "fixture: the frame callback must be registered")

			runtime.lines = {}
			for _ = 1, 300 do frame(nil, touches(2), nil, nil) end
			for _ = 1, 3 do frame(nil, touches(0), nil, nil) end
			helpers.assert_eq(count_lines(runtime, "Touch session", "debug"), 1,
				"three hundred frames of one session must log one heartbeat, not one per 120 frames")

			for _ = 1, 300 do frame(nil, touches(1), nil, nil) end
			helpers.assert_eq(count_lines(runtime, "Touch session", "debug"), 2,
				"lifting every finger ends the session, so the next touch logs once more")
			helpers.assert_eq(count_lines(runtime, "frame#"), 1,
				"only the one-shot first-frame success line may still carry a frame number")
		end)
	end)
end)
