--- tests/unit/modules/keystats/lifecycle/test_watchers_lifecycle_transaction.lua

--- ==============================================================================
--- MODULE: Keystats Watcher Lifecycle Transaction Regression Tests
--- DESCRIPTION:
--- Drives the real keystats hardware watcher layer through partial startup,
--- teardown refusal, and a wake continuation queued immediately before stop.
--- These failures were previously silent because every native return value was
--- ignored and the 50 ms AX callback had no lifecycle owner.
---
--- FEATURES & RATIONALE:
--- 1. Composite Startup: A sibling start refusal rolls back every earlier native
---    watcher and reports false to the keystats startup transaction.
--- 2. Exact Teardown: Stop refusal retains and retries the original capability;
---    stale native callbacks are already generation-fenced.
--- 3. Wake Ownership: TimerScheduler cancellation plus generation and enabled
---    gates prevent a queued AX refresh from resurrecting logging after stop.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================
-- ===========================================
-- ======= 1/ Adversarial Fixture ============
-- ===========================================
-- ===========================================

local MODULE_NAMES = {
	"adapters.task_lifecycle",
	"adapters.timer_scheduler",
	"infra.logger",
	"infra.timings",
	"modules.keystats.context_tracker",
	"modules.keystats.log_manager",
	"modules.keystats.watchers",
}

--- Creates one object-style Hammerspoon watcher with injectable lifecycle results.
--- @param label string Watcher diagnostic label.
--- @param callback function Native callback.
--- @param options table Fixture options.
--- @param watchers table All constructed watcher handles.
--- @return table watcher Native watcher stub.
local function make_object_watcher(label, callback, options, watchers)
	local watcher = {
		label = label,
		callback = callback,
		running = false,
		start_calls = 0,
		stop_calls = 0,
	}
	function watcher:start()
		self.start_calls = self.start_calls + 1
		self.running = true
		local result = options.start_results
			and options.start_results[label]
		if result == "throw" then error(label .. " start exploded") end
		if result == false then return false end
		return self
	end
	function watcher:stop()
		self.stop_calls = self.stop_calls + 1
		local sequence = options.stop_results and options.stop_results[label]
		local result = sequence and sequence[self.stop_calls]
		if result == "throw" then error(label .. " stop exploded") end
		if result == false then return false end
		self.running = false
		return self
	end
	watchers[label] = watcher
	return watcher
end

--- Runs one isolated watcher-lifecycle scenario.
--- @param options table|nil Native and scheduler behavior controls.
--- @param scenario function Scenario receiving module, fixture, and state.
local function with_fixture(options, scenario)
	options = options or {}
	local saved = {}
	for _, name in ipairs(MODULE_NAMES) do
		saved[name] = package.loaded[name]
		package.loaded[name] = nil
	end
	local saved_hs = _G.hs

	local fixture = {
		watchers = {},
		system_events = {},
		log_entries = {},
		passive_periods = {},
		timers = {},
		cancel_calls = {},
		capture_calls = 0,
		flush_calls = 0,
		error_lines = {},
		now_ms = options.now_ms or 1000,
	}
	local audio = {
		callback = nil,
		running = false,
		start_calls = 0,
		stop_calls = 0,
	}
	function audio.setCallback(callback)
		audio.callback = callback
		if callback ~= nil and options.audio_set_callback_throw then
			error("audio callback setter exploded after mutation")
		end
	end
	function audio.start()
		audio.start_calls = audio.start_calls + 1
		audio.running = true
		if options.audio_start == "throw" then error("audio start exploded") end
	end
	function audio.stop()
		audio.stop_calls = audio.stop_calls + 1
		local result = options.audio_stop_results
			and options.audio_stop_results[audio.stop_calls]
		if result == "throw" then error("audio stop exploded") end
		if result == false then return false end
		audio.running = false
		return audio
	end
	function audio.isRunning() return audio.running end
	fixture.audio = audio
	local device = { running = false, callback = nil, stop_calls = 0 }
	function device:uid() return "output-1" end
	function device:volume() return 40 end
	function device:muted() return false end
	function device:watcherCallback(cb) self.callback = cb; return self end
	function device:watcherStart() self.running = true; return self end
	function device:watcherStop() self.stop_calls = self.stop_calls + 1; self.running = false; return self end
	function device:watcherIsRunning() return self.running end
	fixture.audio_device = device

	local hs_stub = {
		timer = { absoluteTime = function() return fixture.now_ms * 1000000 end },
		mouse = { absolutePosition = function() return fixture.mouse_position or { x = 0, y = 0 } end },
		caffeinate = {
			watcher = {
				systemWillSleep = 1,
				screensDidSleep = 2,
				systemDidWake = 3,
				screensDidWake = 4,
				screensDidLock = 5,
				screensDidUnlock = 6,
			},
		},
		wifi = {
			currentNetwork = function() return "Test Wi-Fi" end,
			watcher = {
				new = function(callback)
					return make_object_watcher("wifi", callback, options, fixture.watchers)
				end,
			},
		},
		battery = {
			percentage = function() return 75 end,
			isCharging = function() return true end,
			powerSource = function() return "AC Power" end,
			watcher = {
				new = function(callback)
					return make_object_watcher("battery", callback, options, fixture.watchers)
				end,
			},
		},
		spaces = {
			watcher = {
				new = function(callback)
					return make_object_watcher("spaces", callback, options, fixture.watchers)
				end,
			},
		},
		audiodevice = {
			watcher = audio,
			defaultOutputDevice = function() return fixture.audio_device end,
		},
	}
	_G.hs = hs_stub

	local function noop() end
	package.loaded["infra.logger"] = setmetatable({
		error = function(_, format_string, ...)
			fixture.error_lines[#fixture.error_lines + 1] = string.format(format_string, ...)
		end,
	}, { __index = function() return noop end })
	package.loaded["infra.timings"] = {
		ms = function(_, key)
			return options.timings and options.timings[key] or 1
		end,
	}
	package.loaded["adapters.task_lifecycle"] = {
		native = function() return nil end,
		start = function() return false end,
	}
	local scheduler = {}
	function scheduler.hotstring_time() return (fixture.elapsed_ms or fixture.now_ms) / 1000 end
	function scheduler.after(_, callback)
		local mode = options.after_mode or "commit"
		if mode == "throw" then error("context timer constructor exploded") end
		if mode == "nil" then return nil, false end
		local handle = { callback = callback, active = true, timer = {} }
		fixture.timers[#fixture.timers + 1] = handle
		return handle, mode == "commit"
	end
	function scheduler.cancel(handle)
		fixture.cancel_calls[#fixture.cancel_calls + 1] = handle
		local result = options.cancel_results
			and options.cancel_results[#fixture.cancel_calls]
		if result == "throw" then error("context timer cancel exploded") end
		if result == false then return false end
		handle.active = false
		handle.timer = nil
		return true
	end
	package.loaded["adapters.timer_scheduler"] = scheduler
	package.loaded["modules.keystats.log_manager"] = {
		append_log = function(entry)
			fixture.log_entries[#fixture.log_entries + 1] = entry
		end,
		flush_buffer = function()
			fixture.flush_calls = fixture.flush_calls + 1
			return true
		end,
		day_rollover = function() return true end,
		log_app_switch = noop,
		log_passive_period = function(kind, duration)
			fixture.passive_period = { kind = kind, duration = duration }
			fixture.passive_periods[#fixture.passive_periods + 1] = fixture.passive_period
		end,
		log_system_event = function(kind, payload)
			fixture.system_events[#fixture.system_events + 1] = {
				kind = kind,
				payload = payload,
			}
		end,
	}
	package.loaded["modules.keystats.context_tracker"] = {
		capture_frontmost_app = function()
			fixture.capture_calls = fixture.capture_calls + 1
			return true
		end,
	}

	local state = {
		is_enabled = true,
		is_secure_field = false,
		active_app_name = nil,
		active_app_start = 0,
		current_battery_level = nil,
		buffer_events = {},
		last_mouse_pos = nil,
		mouse_distance_px = 0,
		session_last_active = 0,
	}
	local watchers = require("modules.keystats.watchers")
	helpers.assert_eq(watchers.init(state, function()
		if options.pause_throw then error("pause predicate exploded") end
		return false
	end), true)
	local ok, err = xpcall(function()
		scenario(watchers, fixture, state)
	end, debug.traceback)
	watchers.stop_hardware_watchers()
	_G.hs = saved_hs
	for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end





-- =================================================
-- =================================================
-- ======= 2/ Composite Watcher Transactions =======
-- =================================================
-- =================================================

helpers.describe("keystats hardware watchers form one exact transaction", function()
	helpers.it("does not count pointer travel while watchers are stopped", function()
		with_fixture({}, function(watchers, fixture, state)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			fixture.mouse_position = { x = 0, y = 0 }
			watchers.perform_maintenance()
			helpers.assert_eq(watchers.stop_hardware_watchers(), true)
			fixture.mouse_position = { x = 300, y = 400 }
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			watchers.perform_maintenance()
			helpers.assert_eq(state.mouse_distance_px, 0)
			fixture.mouse_position = { x = 303, y = 404 }
			watchers.perform_maintenance()
			helpers.assert_eq(state.mouse_distance_px, 5)
		end)
	end)

	helpers.it("forgets an open lock across watcher shutdown and restart", function()
		with_fixture({}, function(watchers, fixture, state)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			fixture.now_ms = 1000
			watchers.caffeinate_cb(hs.caffeinate.watcher.screensDidLock)
			helpers.assert_eq(watchers.stop_hardware_watchers(), true)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			fixture.now_ms = 5000
			watchers.caffeinate_cb(hs.caffeinate.watcher.systemDidWake)
			helpers.assert_eq(state.passive_kind, nil)
			helpers.assert_eq(fixture.passive_period, nil)
			helpers.assert_eq(#fixture.timers, 1)
		end)
	end)

	helpers.it("includes suspended time in a sleep interval", function()
		with_fixture({}, function(watchers, fixture)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			fixture.now_ms, fixture.elapsed_ms = 1000, 1000
			watchers.caffeinate_cb(hs.caffeinate.watcher.systemWillSleep)
			fixture.now_ms, fixture.elapsed_ms = 1100, 61000
			watchers.caffeinate_cb(hs.caffeinate.watcher.systemDidWake)
			helpers.assert_eq(fixture.passive_period.duration, 60000)
		end)
	end)

	helpers.it("keeps a lock interval open when the system wakes before screen unlock", function()
		with_fixture({}, function(watchers, fixture, state)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			fixture.now_ms = 1000
			watchers.caffeinate_cb(hs.caffeinate.watcher.screensDidLock)
			fixture.now_ms = 2000
			watchers.caffeinate_cb(hs.caffeinate.watcher.systemWillSleep)
			fixture.now_ms = 3000
			watchers.caffeinate_cb(hs.caffeinate.watcher.systemDidWake)
			helpers.assert_eq(fixture.passive_period, nil)
			helpers.assert_eq(state.passive_kind, "lock")
			fixture.now_ms = 4000
			watchers.caffeinate_cb(hs.caffeinate.watcher.screensDidUnlock)
			helpers.assert_eq(fixture.passive_period.kind, "lock")
			helpers.assert_eq(fixture.passive_period.duration, 3000)
		end)
	end)

	helpers.it("keeps the original sleep start across screen and system sleep events", function()
		with_fixture({}, function(watchers, fixture)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			fixture.now_ms = 1000
			watchers.caffeinate_cb(hs.caffeinate.watcher.screensDidSleep)
			fixture.now_ms = 4000
			watchers.caffeinate_cb(hs.caffeinate.watcher.systemWillSleep)
			fixture.now_ms = 9000
			watchers.caffeinate_cb(hs.caffeinate.watcher.systemDidWake)
			helpers.assert_eq(fixture.passive_period.kind, "sleep")
			helpers.assert_eq(fixture.passive_period.duration, 8000)
		end)
	end)

	helpers.it("supports a default output device without a UID", function()
		with_fixture({}, function(watchers, fixture)
			local device = fixture.audio_device
			device.uid = function() return nil end
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			device.callback(nil, "vmvc", "outp", 0)
			helpers.assert_eq(#fixture.system_events, 1)
			helpers.assert_eq(watchers.stop_hardware_watchers(), true)
		end)
	end)

	helpers.it("rebinds the device watcher on default-output change", function()
		with_fixture({}, function(watchers, fixture)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			local first = fixture.audio_device
			local stale = first.callback
			local second = { running = false }
			function second:uid() return "output-2" end
			function second:volume() return 65 end
			function second:muted() return true end
			function second:watcherCallback(cb) self.callback = cb; return self end
			function second:watcherStart() self.running = true; return self end
			function second:watcherStop() self.running = false; return self end
			function second:watcherIsRunning() return self.running end
			fixture.audio_device = second
			fixture.audio.callback("dOut")
			helpers.assert_eq(first.running, false)
			helpers.assert_eq(second.running, true)
			local count = #fixture.system_events
			stale("output-1", "vmvc", "outp", 0)
			helpers.assert_eq(#fixture.system_events, count)
			second.callback("output-2", "mute", "outp", 0)
			helpers.assert_eq(#fixture.system_events, count + 1)
			helpers.assert_eq(fixture.system_events[#fixture.system_events].payload.volume, 65)
			helpers.assert_eq(watchers.stop_hardware_watchers(), true)
		end)
	end)

	helpers.it("retries a refused device stop before rebinding the new output", function()
		with_fixture({}, function(watchers, fixture)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			local first, stop = fixture.audio_device, fixture.audio_device.watcherStop
			local refused = true
			first.watcherStop = function(self) if refused then return nil end; return stop(self) end
			local second = { running = false }
			function second:uid() return "output-2" end
			function second:volume() return 65 end
			function second:muted() return false end
			function second:watcherCallback(cb) self.callback = cb; return self end
			function second:watcherStart() self.running = true; return self end
			function second:watcherStop() self.running = false; return self end
			function second:watcherIsRunning() return self.running end
			fixture.audio_device = second
			fixture.audio.callback("dOut")
			helpers.assert_eq(first.running, true)
			helpers.assert_eq(second.running, false)
			refused = false
			watchers.check_idle()
			helpers.assert_eq(first.running, false)
			helpers.assert_eq(second.running, true)
			helpers.assert_eq(watchers.stop_hardware_watchers(), true)
		end)
	end)

	helpers.it("retains an output watcher when stop refuses and retries the exact owner", function()
		with_fixture({}, function(watchers, fixture)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			local device, stop = fixture.audio_device, fixture.audio_device.watcherStop
			local refused = true
			device.watcherStop = function(self) if refused then return nil end; return stop(self) end
			local stale = device.callback
			helpers.assert_eq(watchers.stop_hardware_watchers(), false)
			stale("output-1", "vmvc", "outp", 0)
			helpers.assert_eq(#fixture.system_events, 0)
			refused = false
			helpers.assert_eq(watchers.stop_hardware_watchers(), true)
			helpers.assert_eq(device.stop_calls, 1)
			helpers.assert_eq(device.running, false)
		end)
	end)

	helpers.it("rolls back if the default output changes during watcher acquisition", function()
		with_fixture({}, function(watchers, fixture)
			local device, start = fixture.audio_device, fixture.audio_device.watcherStart
			device.watcherStart = function(self)
				local result = start(self)
				fixture.audio_device = { uid = function() return "successor" end }
				return result
			end
			helpers.assert_eq(watchers.init_hardware_watchers(), false)
			helpers.assert_eq(device.running, false)
			helpers.assert_eq(device.callback, nil)
			helpers.assert_eq(fixture.audio.running, false)
		end)
	end)

	helpers.it("removes a callback installed before device setup raises", function()
		with_fixture({}, function(watchers, fixture)
			local device = fixture.audio_device
			device.watcherCallback = function(self, callback)
				self.callback = callback
				if callback then error("callback installed before failure") end
				return self
			end
			helpers.assert_eq(watchers.init_hardware_watchers(), false)
			helpers.assert_eq(device.callback, nil)
			helpers.assert_eq(fixture.audio.running, false)
		end)
	end)

	helpers.it("rejects an equal but nonidentical device start receipt", function()
		with_fixture({}, function(watchers, fixture)
			local device = fixture.audio_device
			local identity = { __eq = function() return true end }
			setmetatable(device, identity)
			local other = setmetatable({}, identity)
			device.watcherStart = function(self) self.running = true; return other end
			helpers.assert_eq(device == other, true)
			helpers.assert_eq(watchers.init_hardware_watchers(), false)
			helpers.assert_eq(device.running, false)
			helpers.assert_eq(device.stop_calls, 1)
		end)
	end)

	helpers.it("retains the owner when stop returns an equal but nonidentical device", function()
		with_fixture({}, function(watchers, fixture)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			local device, stop = fixture.audio_device, fixture.audio_device.watcherStop
			local identity = { __eq = function() return true end }
			setmetatable(device, identity)
			local other = setmetatable({}, identity)
			device.watcherStop = function(self) stop(self); return other end
			helpers.assert_eq(watchers.stop_hardware_watchers(), false)
			device.watcherStop = stop
			helpers.assert_eq(watchers.stop_hardware_watchers(), true)
			helpers.assert_eq(device.stop_calls, 2)
		end)
	end)

	helpers.it("rolls back the exact device after watcher start refuses", function()
		with_fixture({}, function(watchers, fixture)
			local device = fixture.audio_device
			device.watcherStart = function(self) self.running = true; return nil end
			helpers.assert_eq(watchers.init_hardware_watchers(), false)
			helpers.assert_eq(device.stop_calls, 1)
			helpers.assert_eq(device.running, false)
			helpers.assert_eq(device.callback, nil)
			helpers.assert_eq(fixture.audio.running, false)
		end)
	end)

	helpers.it("observes output device volume and mute while fencing stale callbacks", function()
		with_fixture({}, function(watchers, fixture, state)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			local device = fixture.audio_device
			helpers.assert_eq(device.running, true)
			local callback = device.callback
			state.current_audio_volume = nil
			callback("output-1", "vmvc", "inpt", 0)
			callback("other-device", "mute", "outp", 0)
			helpers.assert_eq(#fixture.system_events, 0)
			callback("output-1", "vmvc", "outp", 0)
			callback("output-1", "mute", "outp", 0)
			helpers.assert_eq(state.current_audio_volume, 40)
			helpers.assert_eq(#fixture.system_events, 2)
			helpers.assert_eq(watchers.stop_hardware_watchers(), true)
			helpers.assert_eq(device.running, false)
			callback("output-1", "vmvc", "outp", 0)
			helpers.assert_eq(#fixture.system_events, 2)
		end)
	end)

	helpers.it("observes the documented default output device change event", function()
		with_fixture({}, function(watchers, fixture, state)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			state.current_audio_volume = nil
			fixture.audio.callback("dOut")
			helpers.assert_eq(state.current_audio_volume, 40)
			helpers.assert_eq(#fixture.system_events, 1)
			helpers.assert_eq(fixture.system_events[1].kind, "audio_change")
			helpers.assert_eq(fixture.system_events[1].payload.event_code, "dOut")
			helpers.assert_eq(watchers.stop_hardware_watchers(), true)
		end)
	end)

	helpers.it("rolls back earlier siblings when a later watcher refuses startup", function()
		with_fixture({ start_results = { battery = false } }, function(watchers, fixture)
			helpers.assert_eq(watchers.init_hardware_watchers(), false)
			helpers.assert_eq(fixture.watchers.wifi.stop_calls, 1,
				"Wi-Fi must roll back when the battery sibling cannot commit")
			helpers.assert_eq(fixture.watchers.battery.stop_calls, 1,
				"the active-then-false battery candidate must also be released")
			helpers.assert_eq(fixture.watchers.spaces, nil,
				"startup must abort before acquiring later siblings")

			fixture.watchers.wifi.callback()
			helpers.assert_eq(#fixture.system_events, 0,
				"a callback queued before rollback must be generation-fenced")
		end)
	end)

	helpers.it("retains one refusing watcher while stopping and fencing every sibling", function()
		with_fixture({ stop_results = { spaces = { false, true } } },
			function(watchers, fixture)
				helpers.assert_eq(watchers.init_hardware_watchers(), true)
				local stale_wifi = fixture.watchers.wifi.callback
				helpers.assert_eq(watchers.stop_hardware_watchers(), false,
					"one native refusal must make aggregate teardown report false")
				helpers.assert_eq(fixture.watchers.spaces.running, true,
					"the exact refusing watcher must remain retained")
				helpers.assert_eq(fixture.watchers.wifi.running, false)
				helpers.assert_eq(fixture.watchers.battery.running, false)
				helpers.assert_eq(fixture.audio.running, false)
				stale_wifi()
				helpers.assert_eq(#fixture.system_events, 0,
					"all callbacks must be logically dead before native cleanup completes")

				helpers.assert_eq(watchers.stop_hardware_watchers(), true)
				helpers.assert_eq(fixture.watchers.spaces.stop_calls, 2,
					"a later stop must retry the original spaces watcher")
				helpers.assert_eq(fixture.watchers.spaces.running, false)
			end)
	end)

	helpers.it("rolls back an audio callback setter that mutates before throwing", function()
		with_fixture({ audio_set_callback_throw = true }, function(watchers, fixture)
			helpers.assert_eq(watchers.init_hardware_watchers(), false)
			helpers.assert_eq(fixture.audio.start_calls, 0,
				"startup must stop at the throwing callback setter")
			helpers.assert_eq(fixture.audio.callback, nil,
				"rollback must remove a callback installed before the native throw")
			helpers.assert_eq(fixture.watchers.wifi.running, false)
			helpers.assert_eq(fixture.watchers.battery.running, false)
			helpers.assert_eq(fixture.watchers.spaces.running, false)
		end)
	end)

	helpers.it("contains a throwing pause predicate inside native watcher callbacks", function()
		with_fixture({ pause_throw = true }, function(watchers, fixture, state)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			local errors_before = #fixture.error_lines
			local ok, errors_after_or_err = pcall(function()
				fixture.watchers.wifi.callback()
				return #fixture.error_lines
			end)
			helpers.assert_eq(ok, true,
				"a first-line pause failure must not escape into Hammerspoon Console")
			helpers.assert_true(errors_after_or_err > errors_before,
				"the protected callback must causally emit a central error record")
			helpers.assert_eq(#fixture.system_events, 0)
			helpers.assert_true(#fixture.error_lines > 0,
				"the contained predicate error must reach the central logger")

			helpers.assert_eq(watchers.caffeinate_cb(3), false)
			helpers.assert_eq(state.is_secure_field, true,
				"caffeinate predicate failure must fail closed for persistence")
		end)
	end)
end)





-- ===========================================
-- ===========================================
-- ======= 3/ Bounded Idle Persistence =======
-- ===========================================
-- ===========================================

helpers.describe("keystats idle persistence uses the timing registry", function()
	helpers.it("flushes a typing run only after the configured auto-flush threshold", function()
		with_fixture({
			now_ms = 1000,
			timings = {
				micro_idle_timeout_ms = 100,
				auto_flush_idle_ms = 200,
				session_timeout_ms = 500,
				system_load_poll_ms = 100000,
			},
		}, function(watchers, fixture, state)
			state.session_start_time = 500
			state.session_last_active = 800
			state.buffer_events = { { "a", 20, {} } }

			watchers.check_idle()
			helpers.assert_eq(fixture.flush_calls, 0,
				"the exact threshold must retain the active typing run")

			fixture.now_ms = 1001
			watchers.check_idle()
			helpers.assert_eq(fixture.flush_calls, 1,
				"the registry value must drive the live auto-flush boundary")
			helpers.assert_eq(state.session_last_active, 800,
				"auto-flush must not falsely terminate the active session")
		end)
	end)
end)





-- =========================================
-- =========================================
-- ======= 4/ Wake Continuation Ownership ==
-- =========================================
-- =========================================

helpers.describe("keystats wake refresh is lifecycle-owned", function()
	helpers.it("stop retains timer cleanup debt and fences an already queued AX refresh", function()
		with_fixture({ cancel_results = { false, true } }, function(watchers, fixture, state)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			helpers.assert_eq(watchers.caffeinate_cb(3), true)
			helpers.assert_eq(#fixture.timers, 1,
				"wake must acquire one TimerScheduler continuation")
			local wake_timer = fixture.timers[1]

			state.is_enabled = false
			helpers.assert_eq(watchers.stop_hardware_watchers(), false,
				"timer stop refusal must remain visible to keystats teardown")
			helpers.assert_eq(wake_timer.active, true,
				"the exact refused timer must remain retained for retry")
			wake_timer.callback()
			helpers.assert_eq(fixture.capture_calls, 0,
				"a queued callback must not perform AX work after keystats stop")

			helpers.assert_eq(watchers.stop_hardware_watchers(), true)
			helpers.assert_eq(fixture.cancel_calls[2], wake_timer,
				"the next teardown pass must retry the same timer capability")
			helpers.assert_eq(wake_timer.active, false)
		end)
	end)

	helpers.it("partial wake-timer acquisition remains inert and retryable", function()
		with_fixture({ after_mode = "partial", cancel_results = { false, true } },
			function(watchers, fixture, state)
				helpers.assert_eq(watchers.init_hardware_watchers(), true)
				helpers.assert_eq(watchers.caffeinate_cb(6), true)
				local partial = fixture.timers[1]
				helpers.assert_eq(state.is_secure_field, true,
					"unowned context refresh must fail closed for persistence")
				partial.callback()
				helpers.assert_eq(fixture.capture_calls, 0,
					"an uncommitted continuation must never reach AX")

				state.is_enabled = false
				helpers.assert_eq(watchers.stop_hardware_watchers(), true)
				helpers.assert_eq(fixture.cancel_calls[2], partial)
			end)
	end)

	helpers.it("a committed wake continuation still refreshes foreground context", function()
		with_fixture({}, function(watchers, fixture)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			helpers.assert_eq(watchers.caffeinate_cb(3), true)
			local wake_timer = fixture.timers[1]
			-- Mirror TimerScheduler.after(): native stop settles before user callback
			wake_timer.active = false
			wake_timer.timer = nil
			wake_timer.callback()
			helpers.assert_eq(fixture.capture_calls, 1,
				"lifecycle fencing must preserve the intended post-wake refresh")
		end)
	end)
end)





-- =============================================================
-- =============================================================
-- ======= 3/ User Metrics Pause (HS-004 / MM-001) =============
-- =============================================================
-- =============================================================

helpers.describe("keystats sensors stay silent during the user's metrics pause (HS-004)", function()
	helpers.it("records no space change while collection is suspended", function()
		with_fixture({}, function(watchers, fixture, state)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			local spaces = fixture.watchers.spaces
			state.collection_suspended = true
			spaces.callback(7)
			helpers.assert_eq(#fixture.system_events, 0,
				"a paused collection must not log identifying space changes")
			state.collection_suspended = false
			spaces.callback(8)
			helpers.assert_eq(#fixture.system_events, 1)
			helpers.assert_eq(fixture.system_events[1].kind, "space_change")
		end)
	end)

	helpers.it("never credits pointer travel made during the pause after resume", function()
		with_fixture({}, function(watchers, fixture, state)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			fixture.mouse_position = { x = 0, y = 0 }
			watchers.perform_maintenance()
			state.collection_suspended = true
			fixture.mouse_position = { x = 600, y = 800 }
			watchers.perform_maintenance()
			helpers.assert_eq(state.mouse_distance_px, 0)
			state.collection_suspended = false
			watchers.perform_maintenance()
			helpers.assert_eq(state.mouse_distance_px, 0,
				"the first sample after resume reseeds instead of crediting paused travel")
			fixture.mouse_position = { x = 603, y = 804 }
			watchers.perform_maintenance()
			helpers.assert_eq(state.mouse_distance_px, 5)
		end)
	end)

	helpers.it("opens no passive interval that spans the pause", function()
		with_fixture({}, function(watchers, fixture, state)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			state.collection_suspended = true
			fixture.now_ms = 1000
			watchers.caffeinate_cb(hs.caffeinate.watcher.screensDidLock)
			state.collection_suspended = false
			fixture.now_ms = 9000
			watchers.caffeinate_cb(hs.caffeinate.watcher.screensDidUnlock)
			helpers.assert_eq(#fixture.passive_periods, 0)
			helpers.assert_eq(#fixture.system_events, 1,
				"only the post-pause unlock edge is recorded")
		end)
	end)
end)






-- =============================================================
-- =============================================================
-- ======= 4/ Nested Passive Intervals (HS-007 / MM-004) =======
-- =============================================================
-- =============================================================

--- Sums the measured passive intervals by kind.
--- @param periods table Captured passive periods.
--- @return table totals Milliseconds per kind plus the grand total.
local function passive_totals(periods)
	local totals = { sleep = 0, lock = 0, all = 0 }
	for _, period in ipairs(periods) do
		totals[period.kind] = (totals[period.kind] or 0) + period.duration
		totals.all = totals.all + period.duration
	end
	return totals
end

helpers.describe("keystats passive intervals partition nested sleep and lock (HS-007)", function()
	helpers.it("closes an open sleep segment when the screen locks", function()
		with_fixture({}, function(watchers, fixture)
			local w = hs.caffeinate.watcher
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			fixture.now_ms = 1000
			watchers.caffeinate_cb(w.screensDidSleep)
			fixture.now_ms = 6000
			watchers.caffeinate_cb(w.screensDidLock)
			fixture.now_ms = 10000
			watchers.caffeinate_cb(w.screensDidWake)
			fixture.now_ms = 13000
			watchers.caffeinate_cb(w.screensDidUnlock)
			local totals = passive_totals(fixture.passive_periods)
			helpers.assert_eq(totals.sleep, 5000, "the display-off part before the lock is kept")
			helpers.assert_eq(totals.lock, 7000)
			helpers.assert_eq(totals.all, 12000, "the segments partition the whole interval")
		end)
	end)

	helpers.it("keeps the first lock start across a repeated lock edge", function()
		with_fixture({}, function(watchers, fixture)
			local w = hs.caffeinate.watcher
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			fixture.now_ms = 1000
			watchers.caffeinate_cb(w.screensDidLock)
			fixture.now_ms = 4000
			watchers.caffeinate_cb(w.screensDidLock)
			fixture.now_ms = 9000
			watchers.caffeinate_cb(w.screensDidUnlock)
			helpers.assert_eq(#fixture.passive_periods, 1)
			helpers.assert_eq(fixture.passive_periods[1].kind, "lock")
			helpers.assert_eq(fixture.passive_periods[1].duration, 8000)
		end)
	end)

	helpers.it("loses no time across lock, both sleeps, both wakes and unlock", function()
		with_fixture({}, function(watchers, fixture)
			local w = hs.caffeinate.watcher
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			local edges = { w.screensDidLock, w.screensDidSleep, w.systemWillSleep,
				w.systemDidWake, w.screensDidWake, w.screensDidUnlock }
			for index, edge in ipairs(edges) do
				fixture.now_ms = index * 1000
				watchers.caffeinate_cb(edge)
			end
			helpers.assert_eq(passive_totals(fixture.passive_periods).all, 5000,
				"the measured segments cover lock to unlock exactly once")
		end)
	end)
end)
