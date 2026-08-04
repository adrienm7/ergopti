--- adapters/event_loop.lua

--- ==============================================================================
--- MODULE: EventLoop Adapter (Linux)
--- DESCRIPTION:
--- Abstraction over the daemon event loop. When luv (libuv Lua binding) is
--- available, runs a full async event loop via luv.run() with idle callbacks
--- for keyboard-hook/tray pumping and a repeating timer for process-lifecycle
--- tick. When luv is absent, falls back to a pump-based loop with a 1 ms sleep
--- between iterations to avoid 100 % CPU busy-wait.
---
--- This adapter is the runtime counterpart to the TimerScheduler adapter — the
--- scheduler creates luv timers; the event loop is what runs them.
---
--- FEATURES & RATIONALE:
--- 1. Graceful degradation: the pump-with-sleep fallback works identically to
---    the old tight while loop but without saturating a core.
--- 2. Single run() entry point: callers pass {onIdle, onPeriodic, periodSec}
---    instead of writing their own while loop. The adapter owns the loop.
--- 3. process_lifecycle integration: the periodic callback drives M.tick() at
---    the adapter's own FOCUS_POLL_S interval (250 ms), so the daemon no longer
---    needs to manually thread a tick counter.
--- 4. stop() for clean shutdown: sets a flag; the next loop iteration exits.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local LOG = "adapters.event_loop"


-- =========================================
-- =========================================
-- ======= 1/ luv Detection ================
-- =========================================
-- =========================================

local ok_luv, luv = pcall(require, "luv")
if not ok_luv then luv = nil end

--- A sleep that neither forks nor spins, bound once.
---
--- The pump fallback below runs when luv is absent, and it used to fork
--- /bin/sleep once per iteration. FFI is a hard requirement of this driver
--- already, so nanosleep is always available where the daemon actually runs;
--- the forked form survives only for an interpreter with neither.
--- @return function sleep(seconds)
local nap = (function()
	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi or type(ffi) ~= "table" then
		return function(seconds)
			pcall(os.execute, string.format("sleep %.3f", seconds))
		end
	end
	local ok_cdef, cdef_err = pcall(ffi.cdef, [[
		struct timespec { long tv_sec; long tv_nsec; };
		int nanosleep(const struct timespec *req, struct timespec *rem);
	]])
	if not ok_cdef and not tostring(cdef_err):find("redefin", 1, true) then
		return function(seconds)
			pcall(os.execute, string.format("sleep %.3f", seconds))
		end
	end
	local req = ffi.new("struct timespec[1]")
	return function(seconds)
		req[0].tv_sec = math.floor(seconds)
		req[0].tv_nsec = math.floor((seconds % 1) * 1e9)
		ffi.C.nanosleep(req, nil)
	end
end)()

--- True when the luv library is available and the event loop is native.
M.HAS_LUV = (luv ~= nil)


-- =========================================
-- =========================================
-- ======= 2/ Internal State ===============
-- =========================================
-- =========================================

local _running    = false   -- Set by run(), cleared by stop() or on exit.
local _idle_handle = nil    -- luv idle handle (only with luv).
local _timer_handle = nil   -- luv timer handle for periodic callback (only with luv).
local _idle_handlers = {}   -- Extra per-tick idle callbacks (e.g. GTK context pump).


-- =========================================
-- =========================================
-- ======= 3/ luv-based Loop ===============
-- =========================================
-- =========================================

--- Runs an idle callback. Exceptions are caught and logged so one bad callback
--- never crashes the event loop.
--- @param onIdle function|nil
local function _safe_idle(onIdle)
	if type(onIdle) ~= "function" then return end
	local ok, err = pcall(onIdle)
	if not ok then
		Logger.error(LOG, "onIdle callback raised: %s", tostring(err))
	end
end

--- Runs every idle handler registered via M.add_idle_handler(). Each handler is
--- wrapped in pcall so one raising handler (e.g. a GTK context that throws)
--- never starves the others nor crashes the loop.
local function _run_idle_handlers()
	for i = 1, #_idle_handlers do
		local ok, err = pcall(_idle_handlers[i])
		if not ok then
			Logger.error(LOG, "Idle handler #%d raised: %s", i, tostring(err))
		end
	end
end

--- Runs the periodic callback.  Same exception isolation as _safe_idle.
--- @param onPeriodic function|nil
local function _safe_periodic(onPeriodic)
	if type(onPeriodic) ~= "function" then return end
	local ok, err = pcall(onPeriodic)
	if not ok then
		Logger.error(LOG, "onPeriodic callback raised: %s", tostring(err))
	end
end

--- Starts a native luv event loop with idle + periodic callbacks.
--- @param opts table { onIdle = function, onPeriodic = function, periodSec = number }
local function _run_luv(opts)
	local onIdle     = opts.onIdle
	local onPeriodic = opts.onPeriodic
	local periodSec  = tonumber(opts.periodSec) or 0.25

	-- Idle handle: fires whenever the event loop has nothing else to do.
	-- This replaces the tight while loop for keyboard-hook + tray pumping.
	_idle_handle = luv.new_idle()
	luv.idle_start(_idle_handle, function()
		if not _running then
			if _idle_handle then
				luv.idle_stop(_idle_handle)
				luv.close(_idle_handle)
				_idle_handle = nil
			end
			return
		end
		_safe_idle(onIdle)
		_run_idle_handlers()
	end)

	-- Periodic timer: drives process_lifecycle.tick() at a fixed interval.
	if onPeriodic then
		local periodMs = math.max(1, math.floor(periodSec * 1000))
		_timer_handle = luv.new_timer()
		luv.timer_start(_timer_handle, periodMs, periodMs, function()
			if not _running then
				if _timer_handle then
					luv.timer_stop(_timer_handle)
					luv.close(_timer_handle)
					_timer_handle = nil
				end
				return
			end
			_safe_periodic(onPeriodic)
		end)
	end

	-- This call blocks until stop() is called and all handles are closed.
	luv.run()

	-- Cleanup any handles that were not already stopped.
	if _idle_handle then
		pcall(function() luv.idle_stop(_idle_handle); luv.close(_idle_handle) end)
		_idle_handle = nil
	end
	if _timer_handle then
		pcall(function() luv.timer_stop(_timer_handle); luv.close(_timer_handle) end)
		_timer_handle = nil
	end
end


-- =========================================
-- =========================================
-- ======= 4/ Pump-based Fallback ==========
-- =========================================
-- =========================================

--- Fallback loop when luv is not available.  Pumps onIdle every iteration,
--- calls onPeriodic every periodSec seconds, and sleeps 1 ms between pumps
--- so the loop does not burn a full core.
--- @param opts table { onIdle = function, onPeriodic = function, periodSec = number }
local function _run_pump(opts)
	local onIdle     = opts.onIdle
	local onPeriodic = opts.onPeriodic
	local periodSec  = tonumber(opts.periodSec) or 0.25

	local last_tick = os.clock()
	local iteration = 0

	-- Iteration-based fallback for the periodic gate. When os.clock() returns
	-- CPU-time (some Lua builds on CI) instead of wall-clock, the periodSec
	-- condition never fires and onPeriodic is starved — the failing test
	-- "onPeriodic exception is caught" relies on the callback being called at
	-- least once. Derive from periodSec so a tiny test value (0.001 s) fires
	-- on the very first idle tick while the default (0.25 s) fires every
	-- ~250 ticks at ~1 ms each — proportional to the intended interval.
	local PERIODIC_ITER_FALLBACK = math.max(1, math.ceil(periodSec * 1000))

	while _running do
		_safe_idle(onIdle)
		_run_idle_handlers()
		iteration = iteration + 1

		-- Drive the periodic callback when enough wall-clock has elapsed.
		local now = os.clock()
		if onPeriodic and (now - last_tick >= periodSec or iteration >= PERIODIC_ITER_FALLBACK) then
			_safe_periodic(onPeriodic)
			last_tick = now
			iteration = 0
		end

		-- Yield the CPU for ~1 ms.  This drops usage from 100 % to < 1 %
		-- on any modern kernel while keeping latency low enough for real-time
		-- keyboard input.  GNU coreutils sleep accepts fractional seconds.
		--
		-- Note: keyboard_hook.pump() already blocks on pipe:read("*l") when
		-- there is no input, so this sleep only costs cycles during burst
		-- periods (rare).  The pcall guard means a missing sleep binary is
		-- silently tolerated — the loop becomes a controlled busy-wait,
		-- which is still correct (the pipe read provides natural backpressure).
		pcall(function()
			-- nanosleep through FFI, not a fork. This ran once per loop
			-- iteration — a thousand times a second on an idle daemon — and
			-- forking /bin/sleep at that rate is a measurable share of a core
			-- spent doing nothing. LuaJIT FFI is already a hard requirement of
			-- this driver (uinput, evdev), so this is not a new dependency; luv
			-- remains the preferred path and this is what runs without it.
			nap(0.001)
		end)
	end
end


-- =========================================
-- =========================================
-- ======= 5/ Public API ===================
-- =========================================
-- =========================================

--- Starts the event loop.  Blocks until stop() is called from within a
--- callback or the idle/periodic callbacks signal exit (by calling stop()).
---
--- When neither onIdle nor onPeriodic is provided, returns immediately
--- (there is nothing to pump — an empty loop would spin forever).
---
--- @param opts table|nil
---   .onIdle     function  Called on every loop iteration (pump keyboard, tray, etc.).
---   .onPeriodic function  Called every periodSec seconds (process_lifecycle.tick, etc.).
---   .periodSec  number    Interval in seconds for onPeriodic (default 0.25).
function M.run(opts)
	if _running then
		Logger.warn(LOG, "run() called while already running — no-op.")
		return
	end

	local options = type(opts) == "table" and opts or {}

	-- Guard: an empty loop would spin forever with nothing to stop it.
	if type(options.onIdle) ~= "function" and type(options.onPeriodic) ~= "function" then
		Logger.debug(LOG, "run() called with no callbacks — returning immediately.")
		return
	end

	_running = true

	if luv then
		Logger.debug(LOG, "Starting luv native event loop (idle + periodic @ %.2fs).",
			tonumber(options.periodSec) or 0.25)
		_run_luv(options)
	else
		Logger.debug(LOG, "Starting pump fallback loop (1 ms sleep, periodic @ %.2fs).",
			tonumber(options.periodSec) or 0.25)
		_run_pump(options)
	end

	_running = false
	Logger.debug(LOG, "Event loop exited.")
end

--- Signals the event loop to stop at the next safe point.
--- Safe to call from any callback or external thread (luv: async; pump: flag).
--- Idempotent: has no effect when the loop is not running.
function M.stop()
	if not _running then return end
	_running = false

	-- In luv mode we must also stop the watchers so luv.run() returns.
	if luv then
		if _idle_handle then
			pcall(function() luv.idle_stop(_idle_handle) end)
		end
		if _timer_handle then
			pcall(function() luv.timer_stop(_timer_handle) end)
		end
		-- luv.stop() is NOT called — stopping handles is sufficient; luv.run()
		-- will return on its own when no active handles remain.
	end

	Logger.debug(LOG, "stop() called — event loop will exit at next iteration.")
end

--- Returns true when the event loop is running (blocking in run()).
--- @return boolean
function M.isRunning()
	return _running
end

--- Registers an idle handler invoked on every loop iteration, in addition to the
--- primary onIdle callback. Used to pump secondary event sources — notably the
--- GTK main context (g_main_context_iteration) that keeps WebKit2GTK webviews
--- responsive. Fail-fast: a non-function argument is logged as an ERROR and
--- ignored, never silently stored.
--- @param fn function Callback invoked once per idle tick.
function M.add_idle_handler(fn)
	if type(fn) ~= "function" then
		Logger.error(LOG, "add_idle_handler() requires a function — got %s; ignoring.", type(fn))
		return
	end
	_idle_handlers[#_idle_handlers + 1] = fn
	Logger.debug(LOG, "Idle handler registered (%d total).", #_idle_handlers)
end

return M
