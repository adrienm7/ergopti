--- tests/support/gesture_runtime_fixture.lua

--- ==============================================================================
--- MODULE: Gesture Native Runtime Fixture
--- DESCRIPTION:
--- Loads a fresh modules.gestures.init over native-faithful touchdevice, primer
--- eventtap, wake watcher and recurring-timer doubles. Start and stop can return
--- normally without changing running state, matching the private module's
--- observable failure contract, and every native owner stays inspectable so a
--- test can prove which capabilities are live after a lifecycle transition.
--- ==============================================================================

local M = {}





-- =======================================
-- =======================================
-- ======= 1/ Isolated Runtime Run =======
-- =======================================
-- =======================================

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
function M.with_fixture(options, scenario)
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
		frame_callback_registrations = 0,
		device_enumerations = 0,
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
		runtime.frame_callback_registrations = runtime.frame_callback_registrations + 1
		runtime.frame_callback = callback
		reenter_suspend("touch_factory")
		if options.frame_callback_mode == "throw" then error("callback registration refused") end
		if options.frame_callback_mode == "nil" then return nil end
		return watcher
	end

	package.loaded["hs._asm.undocumented.touchdevice"] = {
		devices = function()
			runtime.device_enumerations = runtime.device_enumerations + 1
			return { 42 }
		end,
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

return M
