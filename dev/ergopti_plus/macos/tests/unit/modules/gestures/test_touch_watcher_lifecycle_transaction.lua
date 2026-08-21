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
		errors = {},
	}

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
		force_cleanup = function() return true end,
	}, { __index = function() return noop end })
	package.loaded["modules.gestures.engine"] = setmetatable({
		init = function() return true end,
		process_frame = function() runtime.engine_process_calls = runtime.engine_process_calls + 1 end,
		stop = function()
			runtime.engine_stop_calls = runtime.engine_stop_calls + 1
			return true
		end,
		emergency_reset = noop,
	}, { __index = function() return noop end })
	package.loaded["modules.gestures.conflicts"] = setmetatable({}, {
		__index = function() return noop end,
	})

	local scheduler = { handles = {} }
	function scheduler.every(_, callback)
		local handle = { active = true, callback = callback }
		scheduler.handles[#scheduler.handles + 1] = handle
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
		return self.start_mode == "false" and false or self
	end
	function watcher:stop()
		self.stop_calls = self.stop_calls + 1
		if self.stop_mode == "throw" then error("native stop refused") end
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
	for _, start_mode in ipairs({ "false", "throw" }) do
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

	for _, stop_mode in ipairs({ "false", "throw" }) do
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
end)
