--- tests/unit/meta/test_event_loop_adapter.lua
---
--- Unit tests for the event_loop adapter (luv/pump dual-path).
--- Tests the full API surface (run/stop/isRunning/HAS_LUV) with mock callbacks
--- so the adapter can be verified without luv or a real daemon.
---
--- Strategy:
--- 1. Structural: verify module shape (exports, HAS_LUV boolean).
--- 2. Pump fallback: run() with mock onIdle + onPeriodic, call stop() from
---    inside onIdle on the N-th iteration, assert callback counts.
--- 3. Edge cases: double-run is no-op, stop-when-not-running is safe,
---    callback exceptions don't crash the loop.

local helpers = require("tests.helpers")
local native_ok, native_luv = pcall(require, "luv")
local function load_pump_loop()
  return helpers.load_module_with_dependency("adapters.event_loop", "luv", false)
end
local el = load_pump_loop()

--- Models libuv stop admission while an independently owned handle stays live.
local function stop_fixture(source)
	local state = { handles = {}, stops = 0, waited = false }
	local backend = {}
	local function new_handle(kind)
		local handle = { kind = kind, active = false }
		state.handles[#state.handles + 1] = handle
		return handle
	end
	function backend.new_idle() return new_handle("idle") end
	function backend.new_timer() return new_handle("timer") end
	function backend.idle_start(handle, callback) handle.active, handle.callback = true, callback; return 0 end
	function backend.timer_start(handle, _, _, callback) handle.active, handle.callback = true, callback; return 0 end
	function backend.idle_stop(handle) handle.active = false; return 0 end
	function backend.timer_stop(handle) handle.active = false; return 0 end
	function backend.close(handle) handle.closed = true end
	function backend.stop() state.stops = state.stops + 1 end
	function backend.run()
		local stops_before = state.stops
		for _, handle in ipairs(state.handles) do
			if not handle.closed and handle.kind == (source == "periodic" and "timer" or "idle") then
				handle.callback()
				break
			end
		end
		-- Stopping the adapter's own idle/timer cannot retire a foreign owner.
		state.waited = state.stops == stops_before
	end
	local previous_backend, previous_loop = package.loaded.luv, package.loaded["adapters.event_loop"]
	package.loaded.luv, package.loaded["adapters.event_loop"] = backend, nil
	local ok, loop = pcall(require, "adapters.event_loop")
	package.loaded.luv, package.loaded["adapters.event_loop"] = previous_backend, previous_loop
	if not ok then error(loop, 0) end
	return loop, state
end

helpers.describe("linux-event-stop-receipts", function()
	for _, source in ipairs({ "idle", "periodic", "deferred" }) do
		helpers.it("linux-event-stop-receipts: " .. source .. " signals native stop without stealing handles", function()
			local loop, state = stop_fixture(source)
			local calls = 0
			local function stop() calls = calls + 1; loop.stop(); loop.stop() end
			local options = {}
			if source == "idle" then options.onIdle = stop
			elseif source == "periodic" then options.onPeriodic = stop
			else
				helpers.assert_true(loop.defer(stop))
				options.onIdle = function() end
			end
			loop.run(options)
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(state.stops, 1, "native run needs explicit stop while foreign owners remain")
			helpers.assert_true(not state.waited)
			helpers.assert_true(not loop.isRunning())
			for _, handle in ipairs(state.handles) do
				helpers.assert_true(handle.closed and not handle.active, "adapter releases its own handles")
			end
		end)
	end
	helpers.it("linux-event-stop-receipts: repeated runs acquire independent stop ownership", function()
		local loop, state = stop_fixture("idle")
		for _ = 1, 2 do
			loop.run({ onIdle = function() loop.stop() end })
			helpers.assert_true(not state.waited)
		end
		helpers.assert_eq(state.stops, 2)
		helpers.assert_true(not loop.isRunning())
		for _, handle in ipairs(state.handles) do helpers.assert_true(handle.closed) end
	end)
	helpers.it("linux-event-stop-receipts: inactive stop cannot interrupt the native owner", function()
		local loop, state = stop_fixture("idle")
		loop.stop()
		loop.stop()
		helpers.assert_eq(state.stops, 0)
		helpers.assert_eq(#state.handles, 0)
	end)
end)

helpers.describe("event_loop adapter", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports run, stop, isRunning, HAS_LUV", function()
      helpers.assert_true(type(el.run)       == "function", "run is a function")
      helpers.assert_true(type(el.stop)      == "function", "stop is a function")
      helpers.assert_true(type(el.isRunning) == "function", "isRunning is a function")
      helpers.assert_true(type(el.HAS_LUV)   == "boolean",  "HAS_LUV is a boolean")
    end)

    helpers.it("exports a checked millisecond wait", function()
      helpers.assert_true(type(el.sleep_ms) == "function", "sleep_ms is a function")
      helpers.assert_true(not el.sleep_ms(-1), "negative waits must be rejected")
      helpers.assert_true(not el.sleep_ms("1"), "non-numeric waits must be rejected")
    end)

    helpers.it("HAS_LUV is false when the dependency is explicitly unavailable", function()
      helpers.assert_true(el.HAS_LUV == false, "HAS_LUV is false (luv absent)")
    end)
  end)

  -- ==========================================================================
  -- 2. Pump fallback — run() with mock callbacks
  -- ==========================================================================

  helpers.describe("pump fallback (luv absent)", function()

    helpers.it("calls onIdle repeatedly until stop() is called from inside onIdle", function()
      local idle_count = 0
      local max_idle   = 5

      el.run({
        onIdle = function()
          idle_count = idle_count + 1
          if idle_count >= max_idle then
            el.stop()
          end
        end,
      })

      helpers.assert_true(idle_count >= max_idle,
        string.format("onIdle called at least %d times (got %d)", max_idle, idle_count))
      helpers.assert_true(el.isRunning() == false, "isRunning is false after loop exits")
    end)

    helpers.it("calls onPeriodic at least once when periodSec is very small", function()
      local periodic_count = 0

      -- Use a tiny period so onPeriodic fires within the first few idle ticks.
      el.run({
        onIdle = function()
          -- Stop after enough ticks for one periodic fire.
          if periodic_count >= 1 then
            el.stop()
          end
        end,
        onPeriodic = function()
          periodic_count = periodic_count + 1
        end,
        periodSec = 0.001,  -- fire almost immediately
      })

      helpers.assert_true(periodic_count >= 1,
        string.format("onPeriodic called at least once (got %d)", periodic_count))
    end)

    helpers.it("onPeriodic is NOT called when omitted from opts", function()
      local idle_count   = 0
      local periodic_ran = false

      el.run({
        onIdle = function()
          idle_count = idle_count + 1
          if idle_count >= 10 then el.stop() end
        end,
        -- onPeriodic intentionally omitted
      })

      -- The loop ran; since we never set periodic_ran, it must still be false.
      helpers.assert_true(periodic_ran == false, "onPeriodic was never invoked (nil callback)")
    end)
  end)

  -- ==========================================================================
  -- 3. Edge cases
  -- ==========================================================================

  helpers.describe("edge cases", function()

    helpers.it("run() with empty opts returns immediately (guard against infinite loop)", function()
      local start = os.clock()
      el.run({})
      local elapsed = os.clock() - start
      helpers.assert_true(elapsed < 0.1,
        string.format("run({}) returned in < 100 ms (got %.3f s)", elapsed))
      helpers.assert_true(el.isRunning() == false, "isRunning is false after empty-run return")
    end)

    helpers.it("run() with nil opts returns immediately", function()
      local start = os.clock()
      el.run(nil)
      local elapsed = os.clock() - start
      helpers.assert_true(elapsed < 0.1,
        string.format("run(nil) returned in < 100 ms (got %.3f s)", elapsed))
    end)

    helpers.it("stop() when not running is safe (idempotent)", function()
      -- Ensure any previous test's loop is done.
      -- Called directly. A stop that never started must leave the loop runnable:
      -- the shutdown path stops defensively, and a wedged loop takes the daemon
      -- with it on the next start.
      el.stop()
      helpers.assert_eq(el.isRunning(), false, "and must report itself stopped")

      -- Double stop is also safe.
      ok = pcall(function() el.stop() end)
      helpers.assert_true(ok, "double stop() does not crash")
    end)

    helpers.it("callback exceptions are caught and do not crash the loop", function()
      local idle_count = 0

      el.run({
        onIdle = function()
          idle_count = idle_count + 1
          if idle_count == 1 then
            error("BANG — this must not crash the loop")
          end
          if idle_count >= 5 then
            el.stop()
          end
        end,
      })

      helpers.assert_true(idle_count >= 5,
        string.format("loop survived exception and ran %d idle iterations", idle_count))
    end)

    helpers.it("onPeriodic exception is caught and does not crash the loop", function()
      local idle_count     = 0
      local periodic_count = 0

      el.run({
        onIdle = function()
          idle_count = idle_count + 1
          if idle_count >= 10 then el.stop() end
        end,
        onPeriodic = function()
          periodic_count = periodic_count + 1
          error("PERIODIC BANG — must not crash the loop")
        end,
        periodSec = 0.001,
      })

      helpers.assert_true(periodic_count >= 1,
        string.format("onPeriodic was called %d times despite exceptions", periodic_count))
      helpers.assert_true(idle_count >= 10,
        "onIdle continued to fire after periodic exceptions")
    end)
  end)

  -- ==========================================================================
  -- 4. Integration contract — daemon-level callbacks
  -- ==========================================================================

  helpers.describe("daemon integration contract", function()

    helpers.it("supports the canonical {onIdle, onPeriodic, periodSec} shape", function()
      local idle_ran     = false
      local periodic_ran = false

      el.run({
        onIdle = function()
          idle_ran = true
          el.stop()
        end,
        onPeriodic = function()
          periodic_ran = true
        end,
        periodSec = 0.001,
      })

      helpers.assert_true(idle_ran,     "onIdle was invoked")
      -- onPeriodic may or may not fire before stop() in one idle tick;
      -- we only assert it doesn't crash.
    end)
  end)

  -- ==========================================================================
  -- 5. Idle handler registration — GTK/WebKit2GTK context pump
  -- ==========================================================================

  helpers.describe("idle handler registration (webview pump)", function()

    helpers.it("exposes add_idle_handler so webview_manager can pump the GTK context", function()
      helpers.assert_true(type(el.add_idle_handler) == "function",
        "add_idle_handler is a function")
    end)

    helpers.it("pumps registered idle handlers every tick even under clock starvation", function()
      -- Fresh module instance so no handler leaks in from or out to other tests.
      local elx = load_pump_loop()

      -- Register the GTK-context pump BEFORE touching the clock: if the API is
      -- missing (the pre-fix regression) this line raises and the frozen clock
      -- below is never installed, so no state leaks into later tests.
      local pumps = 0
      elx.add_idle_handler(function() pumps = pumps + 1 end)

      -- Freeze the wall clock so the periodSec gate can never advance. The ONLY
      -- thing that can still drive the GTK context is the per-iteration idle
      -- pump — this reproduces the CPU-time clock stall that would otherwise
      -- freeze WebKit2GTK webviews; the handler must fire on every tick anyway.
      local real_clock = os.clock
      os.clock = function() return 42 end

      local ticks = 0
      local ok, err = pcall(function()
        elx.run({
          onIdle = function()
            ticks = ticks + 1
            if ticks >= 5 then elx.stop() end
          end,
          onPeriodic = function() end,   -- present but must stay starved
          periodSec  = 1000,
        })
      end)

      os.clock = real_clock  -- always restore, even if run() raised

      helpers.assert_true(ok, "loop ran to completion without raising: " .. tostring(err))
      helpers.assert_true(pumps >= 5,
        string.format("idle handler pumped every tick despite frozen clock (got %d over %d ticks)", pumps, ticks))
    end)

    helpers.it("rejects a non-function handler (fail-fast) without crashing", function()
      local elx = load_pump_loop()
      -- A no-op means the handler is not REGISTERED. One that stored 42 and called
      -- it on the next tick would crash the loop a frame later, far from here.
      elx.add_idle_handler(42)
      helpers.assert_eq(elx.isRunning(), false,
        "a refused handler must not have started anything")
    end)
  end)

end)

helpers.describe("event loop backend isolation", function()
  helpers.it("dependency fixtures restore cached and preload values after success", function()
    local loaded, preload = package.loaded.luv, package.preload.luv
    local native = helpers.load_module_with_dependency("adapters.event_loop", "luv", {})
    helpers.assert_true(native.HAS_LUV, "present dependency selects the native backend")
    helpers.assert_true(package.loaded.luv == loaded, "restore the exact original cache")
    helpers.assert_true(package.preload.luv == preload, "restore the exact original loader")
    helpers.assert_true(not load_pump_loop().HAS_LUV, "absent dependency selects polling independently")
    helpers.assert_true(package.loaded.luv == loaded, "polling must not conceal installed luv")
  end)

  helpers.it("dependency fixtures restore values and preserve a throwing module error", function()
    local name = "tests.fixture_backend_load_failure"
    local old_loaded, old_preload = package.loaded[name], package.preload[name]
    local loaded, preload = package.loaded.luv, package.preload.luv
    package.preload[name] = function()
      require("luv")
      error("backend fixture load failure")
    end
    local ok, err = pcall(helpers.load_module_with_dependency, name, "luv", {})
    package.loaded[name], package.preload[name] = old_loaded, old_preload
    helpers.assert_true(not ok, "module failure must propagate")
    helpers.assert_contains(tostring(err), "backend fixture load failure")
    helpers.assert_true(package.loaded.luv == loaded, "restore cache after a failed require")
    helpers.assert_true(package.preload.luv == preload, "restore loader after a failed require")
  end)

  -- The isolated child uses the POSIX transport of this Linux driver.
  if native_ok and package.config:sub(1, 1) == "/" then
    helpers.it("installed luv dispatches callbacks, closes its handles and waits through child exits", function()
      -- libuv's default loop is process-wide: other tests may own active handles.
      local executable = assert(arg and arg[-1], "the running Lua interpreter must be identifiable")
      local fixture = helpers.driver_root() .. "/tests/fixtures/native_event_loop.lua"
      local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end
      local result = os.execute(quote(executable) .. " " .. quote(fixture))
      helpers.assert_true(result == true or result == 0, "isolated native loop fixture must succeed")
    end)
  else
    print("  [native luv POSIX integration unavailable; explicit backend fixtures still run]")
  end
end)
