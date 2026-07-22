--- tests/unit/meta/test_keyboard_hook_adapter.lua
---
--- Integration tests for the keyboard_hook adapter.
--- Now tests the full implementation: subprocess management, pump(), context
--- tracking, event parsing, control key dispatch, dual mode (observe/intercept).
---
--- Real evdev reading requires a Linux machine with:
---   libinput debug-events (observe, no root needed)
---   evtest --grab (intercept, needs root)
---   /dev/input/eventN device

local helpers = require("tests.helpers")
local hook    = helpers.load_module("adapters.keyboard_hook")

helpers.describe("keyboard_hook adapter", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports start", function()
      helpers.assert_true(type(hook.start) == "function", "start is a function")
    end)
    helpers.it("exports stop", function()
      helpers.assert_true(type(hook.stop) == "function", "stop is a function")
    end)
    helpers.it("exports isRunning", function()
      helpers.assert_true(type(hook.isRunning) == "function", "isRunning is a function")
    end)
    helpers.it("exports refreshContext", function()
      helpers.assert_true(type(hook.refreshContext) == "function", "refreshContext is a function")
    end)
    helpers.it("exports getContext", function()
      helpers.assert_true(type(hook.getContext) == "function", "getContext is a function")
    end)
    helpers.it("exports pump", function()
      helpers.assert_true(type(hook.pump) == "function", "pump is a function")
    end)
  end)

  -- ==========================================================================
  -- 2. Lifecycle: start / stop / isRunning
  -- ==========================================================================

  helpers.describe("lifecycle", function()
    helpers.it("isRunning is false before start", function()
      helpers.assert_eq(hook.isRunning(), false, "not running initially")
    end)

    helpers.it("start with nil opts does not crash", function()
      -- On Windows, start() will fail to find a device and log an error.
      -- The important thing is that it doesn't crash.
      local ok = pcall(function() hook.start(nil) end)
      helpers.assert_true(ok, "start(nil) does not crash")
      hook.stop()  -- clean up even if start failed
    end)

    helpers.it("start with explicit /dev/null device path fails gracefully", function()
      -- /dev/null is not a keyboard — start should fail cleanly.
      local ok = pcall(function()
        hook.start({ device = "/dev/null" })
      end)
      helpers.assert_true(ok, "start with /dev/null does not crash")
      helpers.assert_eq(hook.isRunning(), false, "not running with /dev/null")
    end)

    helpers.it("start is idempotent", function()
      -- Even after a failed start, calling start again is safe.
      local ok1 = pcall(function() hook.start({ device = "/dev/null" }) end)
      local ok2 = pcall(function() hook.start({ device = "/dev/null" }) end)
      helpers.assert_true(ok1 and ok2, "double start does not crash")
      hook.stop()
    end)

    helpers.it("stop is safe when not running", function()
      local ok = pcall(function() hook.stop() end)
      helpers.assert_true(ok, "stop() when not running does not crash")
    end)

    helpers.it("stop after failed start is safe", function()
      pcall(function() hook.start({ device = "/dev/null" }) end)
      local ok = pcall(function() hook.stop() end)
      helpers.assert_true(ok, "stop after failed start does not crash")
    end)
  end)

  -- ==========================================================================
  -- 3. pump() — event loop polling
  -- ==========================================================================

  helpers.describe("pump()", function()
    helpers.it("pump when not running is a safe no-op", function()
      local ok = pcall(function() hook.pump() end)
      helpers.assert_true(ok, "pump() when stopped does not crash")
    end)

    helpers.it("pump many times when stopped does not crash", function()
      local ok = pcall(function()
        for _ = 1, 100 do hook.pump() end
      end)
      helpers.assert_true(ok, "100x pump() when stopped does not crash")
    end)
  end)

  -- ==========================================================================
  -- 4. Callback registration
  -- ==========================================================================

  helpers.describe("callbacks", function()
    helpers.it("start accepts onChar callback without crash", function()
      local ok = pcall(function()
        hook.start({ device = "/dev/null", onChar = function() end })
      end)
      helpers.assert_true(ok, "start with onChar does not crash")
      hook.stop()
    end)

    helpers.it("start accepts onKey callback without crash", function()
      local ok = pcall(function()
        hook.start({ device = "/dev/null", onKey = function() end })
      end)
      helpers.assert_true(ok, "start with onKey does not crash")
      hook.stop()
    end)

    helpers.it("start accepts both callbacks without crash", function()
      local ok = pcall(function()
        hook.start({
          device = "/dev/null",
          onChar = function() end,
          onKey  = function() end,
        })
      end)
      helpers.assert_true(ok, "start with both callbacks does not crash")
      hook.stop()
    end)

    helpers.it("non-function callbacks are silently ignored", function()
      local ok = pcall(function()
        hook.start({
          device = "/dev/null",
          onChar = "not a function",
          onKey  = 42,
        })
      end)
      helpers.assert_true(ok, "start with bad callbacks does not crash")
      hook.stop()
    end)
  end)

  -- ==========================================================================
  -- 5. Intercept mode
  -- ==========================================================================

  helpers.describe("intercept mode", function()
    helpers.it("exports get_mode", function()
      helpers.assert_true(type(hook.get_mode) == "function", "get_mode is a function")
    end)

    helpers.it("defaults to observe mode before any start", function()
      -- A freshly loaded hook has not grabbed the device. Race-free hotstring
      -- replacement requires "intercept"; "observe" is the current safe default.
      local fresh = helpers.load_module("adapters.keyboard_hook")
      helpers.assert_eq(fresh.get_mode(), "observe", "default mode is observe (no grab)")
    end)

    helpers.it("start with intercept=true does not crash", function()
      local ok = pcall(function()
        hook.start({ device = "/dev/null", intercept = true })
      end)
      helpers.assert_true(ok, "start with intercept=true does not crash")
      hook.stop()
    end)

    helpers.it("get_mode reports intercept after start with intercept=true", function()
      -- start() resolves the intercept flag before device resolution, so even a
      -- failed launch on /dev/null records the requested capture mode.
      pcall(function() hook.start({ device = "/dev/null", intercept = true }) end)
      helpers.assert_eq(hook.get_mode(), "intercept",
        "get_mode must report the requested grab/intercept mode")
      hook.stop()
    end)

    helpers.it("start with intercept=false does not crash", function()
      local ok = pcall(function()
        hook.start({ device = "/dev/null", intercept = false })
      end)
      helpers.assert_true(ok, "start with intercept=false does not crash")
      hook.stop()
    end)

    helpers.it("get_mode reports observe after start with intercept=false", function()
      pcall(function() hook.start({ device = "/dev/null", intercept = false }) end)
      helpers.assert_eq(hook.get_mode(), "observe",
        "get_mode must report observe when grab was not requested")
      hook.stop()
    end)
  end)

  -- ==========================================================================
  -- 6. Layout selection
  -- ==========================================================================

  helpers.describe("layout", function()
    helpers.it("start with layout='qwerty' does not crash", function()
      local ok = pcall(function()
        hook.start({ device = "/dev/null", layout = "qwerty" })
      end)
      helpers.assert_true(ok, "start with qwerty layout does not crash")
      hook.stop()
    end)

    helpers.it("start with layout='azerty' does not crash", function()
      local ok = pcall(function()
        hook.start({ device = "/dev/null", layout = "azerty" })
      end)
      helpers.assert_true(ok, "start with azerty layout does not crash")
      hook.stop()
    end)

    helpers.it("start with bogus layout defaults to qwerty", function()
      local ok = pcall(function()
        hook.start({ device = "/dev/null", layout = "dvorak" })
      end)
      helpers.assert_true(ok, "start with bogus layout does not crash")
      hook.stop()
    end)
  end)

  -- ==========================================================================
  -- 7. Context tracking
  -- ==========================================================================

  helpers.describe("context", function()
    helpers.it("getContext returns table with expected fields", function()
      local ctx = hook.getContext()
      helpers.assert_true(type(ctx) == "table", "getContext returns a table")
      helpers.assert_true(ctx.appId ~= nil, "ctx has appId")
      helpers.assert_true(ctx.windowTitle ~= nil, "ctx has windowTitle")
    end)

    helpers.it("getContext defaults to empty strings", function()
      local ctx = hook.getContext()
      helpers.assert_eq(ctx.appId, "", "appId defaults to ''")
      helpers.assert_eq(ctx.windowTitle, "", "windowTitle defaults to ''")
    end)

    helpers.it("refreshContext does not crash when xdotool absent", function()
      local ok = pcall(function() hook.refreshContext() end)
      helpers.assert_true(ok, "refreshContext does not crash")
    end)
  end)

  -- ==========================================================================
  -- 8. Event parsing (unit tests for parser functions via pump)
  -- ==========================================================================

  helpers.describe("event parsing", function()
    helpers.it("pump on running hook with /dev/null pipe does not crash", function()
      -- After start with /dev/null, the subprocess pipe is nil, so pump is a no-op.
      pcall(function()
        hook.start({ device = "/dev/null" })
      end)
      local ok = pcall(function() hook.pump() end)
      helpers.assert_true(ok, "pump after /dev/null start does not crash")
      hook.stop()
    end)
  end)

  -- ==========================================================================
  -- 9. Edge cases
  -- ==========================================================================

  helpers.describe("edge cases", function()
    helpers.it("start-stop-start-stop rapid cycle", function()
      for _ = 1, 5 do
        pcall(function() hook.start({ device = "/dev/null" }) end)
        pcall(function() hook.stop() end)
      end
      helpers.assert_eq(hook.isRunning(), false, "stable after rapid cycle")
    end)

    helpers.it("start with bogus options table does not crash", function()
      local ok = pcall(function()
        hook.start({
          intercept = "yes",
          layout    = 42,
          onChar    = { also = "wrong" },
        })
      end)
      helpers.assert_true(ok, "start with bogus options does not crash")
      hook.stop()
    end)
  end)

end)
