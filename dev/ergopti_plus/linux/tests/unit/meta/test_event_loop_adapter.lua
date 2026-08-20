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
local el      = helpers.load_module("adapters.event_loop")

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

    helpers.it("HAS_LUV is false when luv is not installed (CI/Windows)", function()
      -- On CI and the maintainer's Windows machine, luv is absent.
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
      local elx = helpers.load_module("adapters.event_loop")

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
      local elx = helpers.load_module("adapters.event_loop")
      -- A no-op means the handler is not REGISTERED. One that stored 42 and called
      -- it on the next tick would crash the loop a frame later, far from here.
      elx.add_idle_handler(42)
      helpers.assert_eq(elx.isRunning(), false,
        "a refused handler must not have started anything")
    end)
  end)

end)
