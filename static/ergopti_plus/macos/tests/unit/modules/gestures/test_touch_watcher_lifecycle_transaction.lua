--- tests/unit/modules/gestures/test_touch_watcher_lifecycle_transaction.lua

--- ==============================================================================
--- MODULE: Gesture Touch-Watcher Lifecycle Transaction Regression Tests
--- DESCRIPTION:
--- Exercises the private touchdevice watcher through the public gesture lifecycle
--- with native-faithful refusal states. It proves startup commits only a running
--- watcher, teardown retains an exact live capability until release settles, and
--- queued frames become inert before engine teardown.
---
--- FEATURES & RATIONALE:
--- 1. Native-State Doubles: Start and stop can return normally without changing
---    running state, matching the private module's observable failure contract.
--- 2. Exact Cleanup Retry: A refused watcher remains owned and the next stop call
---    retries the same object rather than forgetting or replacing it.
--- 3. Dormancy Preservation: A running watcher with alive false remains valid
---    before the kernel delivers the first physical touch.
--- ==============================================================================

local helpers = require("tests.helpers")





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

--- Runs one watcher fault scenario against a fresh gesture module.
--- @param options table Fault modes for frame callback, start, stop, and alive.
--- @param scenario function Scenario receiving gestures and captured native state.
local function with_fixture(options, scenario)
	options = options or {}
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

	local runtime = {
		engine_process_calls = 0,
		engine_stop_calls = 0,
		action_cleanup_calls = 0,
		action_resume_calls = 0,
		errors = {},
		suspend_results = {},
		primer_handles = {},
		wake_handles = {},
	}
	local gestures
	local function reenter_suspend(boundary)
		if options.reenter_boundary ~= boundary or not gestures then return end
		options.reenter_boundary = nil
		runtime.suspend_results[#runtime.suspend_results + 1] = gestures.suspend()
	end

	local function noop() end
	local logger = setmetatable({
		error = function(_, message, ...)
			runtime.errors[#runtime.errors + 1] = string.format(message, ...)
		end,
		pcall = function(_, fn, ...)
			return pcall(fn, ...)
		end,
	}, { __index = function() return noop end })
	package.loaded["infra.logger"] = logger
	package.loaded["infra.manifest_reader"] = { default_for = function() return false end }
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
		force_cleanup = function()
			runtime.action_cleanup_calls = runtime.action_cleanup_calls + 1
			return true
		end,
		resume_after_cleanup = function()
			runtime.action_resume_calls = runtime.action_resume_calls + 1
			return true
		end,
	}, { __index = function() return noop end })
	package.loaded["modules.gestures.engine"] = setmetatable({
		init = function() return true end,
		process_frame = function() runtime.engine_process_calls = runtime.engine_process_calls + 1 end,
		stop = function()
			runtime.engine_stop_calls = runtime.engine_stop_calls + 1
			return true
		end,
		cancel_current_gesture = function() return true end,
		emergency_reset = noop,
	}, { __index = function() return noop end })
	package.loaded["modules.gestures.conflicts"] = setmetatable({}, {
		__index = function() return noop end,
	})

	local scheduler = { handles = {} }
	function scheduler.every(_, callback)
		local handle = { active = true, callback = callback }
		scheduler.handles[#scheduler.handles + 1] = handle
		reenter_suspend("timer_factory")
		return handle, true
	end
	function scheduler.cancel(handle)
		if handle then handle.active = false end
		return true
	end
	package.loaded["adapters.timer_scheduler"] = scheduler

	local watcher = {
		running_state = false,
		alive_state = options.alive_state == true,
		start_mode = options.start_mode or "commit",
		stop_mode = options.stop_mode or "commit",
		start_calls = 0,
		stop_calls = 0,
	}
	function watcher:start()
		self.start_calls = self.start_calls + 1
		if self.start_mode == "partial_throw" then
			self.running_state = true
			error("native start raised after activation")
		end
		if self.start_mode == "throw" then error("native start refused") end
		if self.start_mode == "commit" then self.running_state = true end
		if self.start_mode == "nil" then return nil end
		if self.start_mode == "false" then return false end
		reenter_suspend("touch_start")
		return self
	end
	function watcher:stop()
		self.stop_calls = self.stop_calls + 1
		if self.stop_mode == "throw" then error("native stop refused") end
		if self.stop_mode == "nil" then return nil end
		if self.stop_mode == "commit" then self.running_state = false end
		return self.stop_mode == "false" and false or self
	end
	function watcher:running() return self.running_state end
	function watcher:alive() return self.alive_state end
	local watcher_userdata = nil
	local watcher_userdata_metatable = nil
	if options.watcher_kind == "userdata" then
		local watcher_backing = watcher
		watcher_userdata = assert(io.tmpfile())
		watcher_userdata_metatable = debug.getmetatable(watcher_userdata)
		debug.setmetatable(watcher_userdata, {
			__index = watcher_backing,
			__newindex = watcher_backing,
		})
		watcher = watcher_userdata
	end

	local device = {
		deviceID = function() return 42 end,
		builtin = function() return true end,
		alive = function() return options.alive_state == true end,
		running = function() return watcher.running_state end,
		MTHIDDevice = function() return true end,
		driverReady = function() return true end,
		productName = function() return "Test Trackpad" end,
	}
	function device:frameCallback(callback)
		runtime.frame_callback = callback
		reenter_suspend("touch_factory")
		if options.frame_callback_mode == "throw" then error("callback registration refused") end
		if options.frame_callback_mode == "nil" then return nil end
		return watcher
	end

	package.loaded["hs._asm.undocumented.touchdevice"] = {
		devices = function() return { 42 } end,
		forDeviceID = function() return device end,
	}

	hs_stub.eventtap.new = function(_, callback)
		local handle = { callback = callback, running = false }
		runtime.primer_handles[#runtime.primer_handles + 1] = handle
		function handle:start()
			self.running = true
			reenter_suspend("primer_start")
			return self
		end
		function handle:stop()
			local mode = options.primer_stop_mode
			if mode == "throw" then error("primer stop refused") end
			if mode == "false" then return false end
			if mode == "nil" then return nil end
			self.running = false
			return self
		end
		function handle:isEnabled() return self.running end
		reenter_suspend("primer_factory")
		return handle
	end
	package.loaded["hs.caffeinate.watcher"] = {
		systemDidWake = 1,
		screensDidUnlock = 2,
		new = function(callback)
			local handle = { callback = callback, running = false }
			runtime.wake_handles[#runtime.wake_handles + 1] = handle
			function handle:start()
				self.running = true
				reenter_suspend("wake_start")
				return self
			end
			function handle:stop()
				local mode = options.wake_stop_mode
				if mode == "throw" then error("wake stop refused") end
				if mode == "false" then return false end
				if mode == "nil" then return nil end
				self.running = false
				return self
			end
			reenter_suspend("wake_factory")
			return handle
		end,
	}

	gestures = require("modules.gestures.init")
	local ok, err = xpcall(function()
		scenario(gestures, runtime, watcher, device)
	end, debug.traceback)
	if watcher_userdata then
		debug.setmetatable(watcher_userdata, watcher_userdata_metatable)
		io.close(watcher_userdata)
	end

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





-- ===========================================
-- ===========================================
-- ======= 2/ Watcher Commit Contracts =======
-- ===========================================
-- ===========================================

helpers.describe("gesture touch watchers are exact lifecycle transactions", function()
	for _, start_mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("rejects native watcher start mode " .. start_mode, function()
			with_fixture({ start_mode = start_mode }, function(gestures, _, watcher)
				helpers.assert_eq(gestures.start(), false,
					"gesture startup must reject a watcher that never becomes running")
				helpers.assert_eq(watcher.running_state, false)
				helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], nil,
					"a fully rolled-back start refusal must not remain published")
			end)
		end)
	end

	for _, frame_mode in ipairs({ "nil", "throw" }) do
		helpers.it("rejects frame callback registration mode " .. frame_mode, function()
			with_fixture({ frame_callback_mode = frame_mode }, function(gestures)
				helpers.assert_eq(gestures.start(), false,
					"missing native callback ownership must reject gesture startup")
				helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], nil)
			end)
		end)
	end

	helpers.it("commits running watcher while preserving pre-touch dormancy", function()
		with_fixture({ alive_state = false }, function(gestures, _, watcher)
			helpers.assert_eq(gestures.start(), true,
				"running true and alive false is the valid kernel-gated state")
			helpers.assert_eq(watcher.running_state, true)
			helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], watcher)
			helpers.assert_eq(gestures.stop(), true)
		end)
	end)

	helpers.it("accepts the native userdata watcher capability", function()
		with_fixture({ watcher_kind = "userdata" }, function(gestures, _, watcher)
			helpers.assert_eq(type(watcher), "userdata")
			helpers.assert_eq(gestures.start(), true)
			helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], watcher)
			helpers.assert_eq(gestures.stop(), true)
			helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], nil)
		end)
	end)

	helpers.it("refuses start under suspension without constructing successor owners", function()
		with_fixture({}, function(gestures, runtime, watcher)
			helpers.assert_eq(gestures.start(), true)
			helpers.assert_eq(gestures.suspend(), true)
			local watcher_starts = watcher.start_calls
			local primer = _G.ERGOPTI_GESTURE_PRIMER
			local wake_watcher = _G.ERGOPTI_SLEEP_WATCHER
			local cleanup_before = runtime.action_cleanup_calls
			local resumes_before = runtime.action_resume_calls

			helpers.assert_eq(gestures.start(), false,
				"ScriptControl suspension must be admission-authoritative")
			helpers.assert_eq(gestures.is_suspended(), true)
			helpers.assert_eq(gestures.is_enabled(), true,
				"a refused duplicate start must preserve the feature snapshot")
			helpers.assert_eq(runtime.action_cleanup_calls, cleanup_before + 1)
			helpers.assert_eq(runtime.action_resume_calls, resumes_before)
			helpers.assert_eq(watcher.start_calls, watcher_starts)
			helpers.assert_true(_G.ERGOPTI_GESTURE_PRIMER == primer)
			helpers.assert_true(_G.ERGOPTI_SLEEP_WATCHER == wake_watcher)
			helpers.assert_eq(gestures.stop(), true)
		end)
	end)

	helpers.it("retains a partially activated start until exact rollback settles", function()
		with_fixture({ start_mode = "partial_throw", stop_mode = "false" },
			function(gestures, runtime, watcher, device)
				helpers.assert_eq(gestures.start(), false)
				helpers.assert_eq(watcher.running_state, true)
				helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], watcher)
				helpers.assert_eq(_G.ERGOPTI_TOUCH_DEVICES[42], device)
				local process_calls = runtime.engine_process_calls
				runtime.frame_callback(nil, { {} }, nil, nil)
				helpers.assert_eq(runtime.engine_process_calls, process_calls,
					"a never-committed callback must remain inert during cleanup debt")

				watcher.stop_mode = "commit"
				local stop_calls_before_retry = watcher.stop_calls
				helpers.assert_eq(gestures.stop(), true)
				helpers.assert_eq(watcher.stop_calls, stop_calls_before_retry + 1,
					"module stop must retry the exact rollback-refused candidate")
				helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], nil)
			end)
	end)

	for _, stop_mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains and retries native watcher stop mode " .. stop_mode, function()
			with_fixture({}, function(gestures, runtime, watcher, device)
				helpers.assert_eq(gestures.start(), true)
				local captured_callback = runtime.frame_callback
				watcher.stop_mode = stop_mode

				helpers.assert_eq(gestures.stop(), false,
					"a still-running watcher must keep teardown unsettled")
				helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], watcher,
					"the exact live watcher must remain owned for retry")
				helpers.assert_eq(_G.ERGOPTI_TOUCH_DEVICES[42], device,
					"the exact device owner must remain pinned with cleanup debt")
				helpers.assert_eq(watcher.running_state, true)
				local process_calls = runtime.engine_process_calls
				captured_callback(nil, { {} }, nil, nil)
				helpers.assert_eq(runtime.engine_process_calls, process_calls,
					"a queued frame must be inert after stop fencing")

				watcher.stop_mode = "commit"
				helpers.assert_eq(gestures.stop(), true,
					"teardown must retry and settle the same retained watcher")
				helpers.assert_eq(watcher.stop_calls, 2)
				helpers.assert_eq(watcher.running_state, false)
				helpers.assert_eq(_G.ERGOPTI_TOUCH_WATCHERS[42], nil)
				helpers.assert_eq(_G.ERGOPTI_TOUCH_DEVICES[42], nil)
			end)
		end)
	end

	for _, boundary in ipairs({
		"primer_factory", "primer_start", "touch_factory", "touch_start",
		"timer_factory", "wake_factory", "wake_start",
	}) do
		helpers.it("rolls back and rebuilds an ON startup when " .. boundary
			.. " reenters suspend", function()
			with_fixture({ reenter_boundary = boundary },
				function(gestures, runtime, watcher)
					helpers.assert_eq(gestures.start(), false)
					helpers.assert_eq(runtime.suspend_results, { true })
					helpers.assert_eq(gestures.is_enabled(), true,
						"the exact ON feature snapshot must survive startup rollback")
					helpers.assert_eq(gestures.is_suspended(), true)
					for _, handle in ipairs(runtime.primer_handles) do
						local scheduler_count = #require("adapters.timer_scheduler").handles
						handle.callback({ getType = function() return 0 end })
						helpers.assert_eq(#require("adapters.timer_scheduler").handles,
							scheduler_count, "a rolled-back primer callback must stay inert")
					end

					helpers.assert_eq(gestures.resume(), true,
						"RESUME must reconstruct every native owner after interrupted startup")
					helpers.assert_eq(gestures.is_enabled(), true)
					helpers.assert_eq(gestures.is_suspended(), false)
					helpers.assert_true(_G.ERGOPTI_GESTURE_PRIMER ~= nil)
					helpers.assert_true(_G.ERGOPTI_GESTURE_PRIMER.running)
					helpers.assert_true(_G.ERGOPTI_SLEEP_WATCHER ~= nil)
					helpers.assert_true(_G.ERGOPTI_SLEEP_WATCHER.running)
					helpers.assert_eq(watcher.running_state, true)
					helpers.assert_eq(gestures.stop(), true)
				end)
		end)
	end

	for _, stop_mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("retains exact primer rollback debt after reentrant suspend mode "
			.. stop_mode, function()
			local options = {
				reenter_boundary = "primer_start",
				primer_stop_mode = stop_mode,
			}
			with_fixture(options, function(gestures, runtime)
				helpers.assert_eq(gestures.start(), false)
				local retained = runtime.primer_handles[1]
				helpers.assert_true(_G.ERGOPTI_GESTURE_PRIMER == retained,
					"the exact stop-refused primer must remain owned")
				helpers.assert_eq(retained.running, true)
				local scheduler_count = #require("adapters.timer_scheduler").handles
				retained.callback({ getType = function() return 0 end })
				helpers.assert_eq(#require("adapters.timer_scheduler").handles,
					scheduler_count, "cleanup-debt callbacks must remain fenced")

				options.primer_stop_mode = "commit"
				helpers.assert_eq(gestures.resume(), true,
					"RESUME retries the retained primer before constructing a successor")
				helpers.assert_true(_G.ERGOPTI_GESTURE_PRIMER ~= retained)
				helpers.assert_eq(retained.running, false)
				helpers.assert_eq(gestures.is_enabled(), true)
				helpers.assert_eq(gestures.is_suspended(), false)
				helpers.assert_eq(gestures.stop(), true)
			end)
		end)
	end

	for _, stop_mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("settles interrupted startup debt before OFF and rebuilds on later ON mode "
			.. stop_mode, function()
			local options = {
				reenter_boundary = "primer_start",
				primer_stop_mode = stop_mode,
			}
			with_fixture(options, function(gestures, _, watcher)
				helpers.assert_eq(gestures.start(), false)
				helpers.assert_eq(gestures.disable_all(), false,
					"OFF may not commit while interrupted-start native debt refuses")
				helpers.assert_eq(gestures.is_enabled(), true)
				helpers.assert_eq(gestures.is_suspended(), true)

				options.primer_stop_mode = "commit"
				helpers.assert_eq(gestures.disable_all(), true)
				helpers.assert_eq(gestures.is_enabled(), false)
				helpers.assert_eq(gestures.resume(), true)
				helpers.assert_eq(gestures.is_enabled(), false)
				helpers.assert_eq(gestures.is_suspended(), false)
				helpers.assert_eq(_G.ERGOPTI_GESTURE_PRIMER, nil)
				helpers.assert_eq(_G.ERGOPTI_SLEEP_WATCHER, nil)

				helpers.assert_eq(gestures.enable_all(), true,
					"a later ON must reconstruct the native runtime, not only action admission")
				helpers.assert_eq(gestures.is_enabled(), true)
				helpers.assert_true(_G.ERGOPTI_GESTURE_PRIMER ~= nil)
				helpers.assert_true(_G.ERGOPTI_SLEEP_WATCHER ~= nil)
				helpers.assert_eq(watcher.running_state, true)
				helpers.assert_eq(gestures.stop(), true)
			end)
		end)
	end
end)
