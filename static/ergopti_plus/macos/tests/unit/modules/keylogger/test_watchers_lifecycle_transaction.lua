--- tests/unit/modules/keylogger/test_watchers_lifecycle_transaction.lua

--- ==============================================================================
--- MODULE: Keylogger Watcher Lifecycle Transaction Regression Tests
--- DESCRIPTION:
--- Drives the real keylogger hardware watcher layer through partial startup,
--- teardown refusal, and a wake continuation queued immediately before stop.
--- These failures were previously silent because every native return value was
--- ignored and the 50 ms AX callback had no lifecycle owner.
---
--- FEATURES & RATIONALE:
--- 1. Composite Startup: A sibling start refusal rolls back every earlier native
---    watcher and reports false to the keylogger startup transaction.
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
	"modules.keylogger.context_tracker",
	"modules.keylogger.log_manager",
	"modules.keylogger.watchers",
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

	local hs_stub = {
		timer = { absoluteTime = function() return fixture.now_ms * 1000000 end },
		mouse = { absolutePosition = function() return { x = 0, y = 0 } end },
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
			defaultOutputDevice = function()
				return {
					volume = function() return 40 end,
					muted = function() return false end,
				}
			end,
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
	package.loaded["modules.keylogger.log_manager"] = {
		append_log = function(entry)
			fixture.log_entries[#fixture.log_entries + 1] = entry
		end,
		flush_buffer = function()
			fixture.flush_calls = fixture.flush_calls + 1
			return true
		end,
		day_rollover = function() return true end,
		log_app_switch = noop,
		log_passive_period = noop,
		log_system_event = function(kind, payload)
			fixture.system_events[#fixture.system_events + 1] = {
				kind = kind,
				payload = payload,
			}
		end,
	}
	package.loaded["modules.keylogger.context_tracker"] = {
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
	local watchers = require("modules.keylogger.watchers")
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

helpers.describe("keylogger hardware watchers form one exact transaction", function()
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

helpers.describe("keylogger idle persistence uses the timing registry", function()
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

helpers.describe("keylogger wake refresh is lifecycle-owned", function()
	helpers.it("stop retains timer cleanup debt and fences an already queued AX refresh", function()
		with_fixture({ cancel_results = { false, true } }, function(watchers, fixture, state)
			helpers.assert_eq(watchers.init_hardware_watchers(), true)
			helpers.assert_eq(watchers.caffeinate_cb(3), true)
			helpers.assert_eq(#fixture.timers, 1,
				"wake must acquire one TimerScheduler continuation")
			local wake_timer = fixture.timers[1]

			state.is_enabled = false
			helpers.assert_eq(watchers.stop_hardware_watchers(), false,
				"timer stop refusal must remain visible to keylogger teardown")
			helpers.assert_eq(wake_timer.active, true,
				"the exact refused timer must remain retained for retry")
			wake_timer.callback()
			helpers.assert_eq(fixture.capture_calls, 0,
				"a queued callback must not perform AX work after keylogger stop")

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
