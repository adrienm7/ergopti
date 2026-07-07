--- tests/unit/meta/test_keyboard_hook_adapter.lua
---
--- Phase 2B — B1 (extended): Integration tests for the keyboard_hook adapter
--- (libinput / evdev stub). Tests the lifecycle (start/stop/isRunning),
--- context tracking (refreshContext/getContext), and edge cases without
--- requiring a real /dev/input/eventN device.
---
--- Real evdev reading requires a Linux machine with:
---   sudo modprobe uinput
---   A USB keyboard at /dev/input/eventN

local helpers  = require("tests.helpers")
local hook     = helpers.load_module("adapters.keyboard_hook")

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
  end)

  -- ==========================================================================
  -- 2. Lifecycle: start / stop / isRunning
  -- ==========================================================================

  helpers.describe("lifecycle", function()
    helpers.it("isRunning is false before start", function()
      helpers.assert_eq(hook.isRunning(), false, "not running initially")
    end)

    helpers.it("start with empty opts sets running flag", function()
      hook.start({})
      helpers.assert_true(hook.isRunning(), "running after start({})")
      hook.stop()
    end)

    helpers.it("start with nil opts sets running flag", function()
      hook.start(nil)
      helpers.assert_true(hook.isRunning(), "running after start(nil)")
      hook.stop()
    end)

    helpers.it("start is idempotent", function()
      hook.start({})
      local ok = pcall(function() hook.start({}) end)
      helpers.assert_true(ok, "second start() does not crash")
      helpers.assert_true(hook.isRunning(), "still running after double start")
      hook.stop()
    end)

    helpers.it("stop clears running flag", function()
      hook.start({})
      hook.stop()
      helpers.assert_eq(hook.isRunning(), false, "not running after stop()")
    end)

    helpers.it("stop is safe when not running", function()
      local ok = pcall(function() hook.stop() end)
      helpers.assert_true(ok, "stop() when not running does not crash")
    end)

    helpers.it("full start-stop-start cycle works", function()
      hook.start({})
      helpers.assert_true(hook.isRunning(), "cycle: running 1")
      hook.stop()
      helpers.assert_eq(hook.isRunning(), false, "cycle: stopped")
      hook.start({})
      helpers.assert_true(hook.isRunning(), "cycle: running 2")
      hook.stop()
    end)
  end)

  -- ==========================================================================
  -- 3. Callback registration
  -- ==========================================================================

  helpers.describe("callbacks", function()
    helpers.it("start accepts onChar callback without crash", function()
      local char_count = 0
      local ok = pcall(function()
        hook.start({ onChar = function() char_count = char_count + 1 end })
      end)
      helpers.assert_true(ok, "start with onChar does not crash")
      hook.stop()
    end)

    helpers.it("start accepts onKey callback without crash", function()
      local ok = pcall(function()
        hook.start({ onKey = function() end })
      end)
      helpers.assert_true(ok, "start with onKey does not crash")
      hook.stop()
    end)

    helpers.it("start accepts both callbacks without crash", function()
      local ok = pcall(function()
        hook.start({ onChar = function() end, onKey = function() end })
      end)
      helpers.assert_true(ok, "start with both callbacks does not crash")
      hook.stop()
    end)

    helpers.it("non-function callbacks are silently ignored", function()
      local ok = pcall(function()
        hook.start({ onChar = "not a function", onKey = 42 })
      end)
      helpers.assert_true(ok, "start with bad callbacks does not crash")
      hook.stop()
    end)
  end)

  -- ==========================================================================
  -- 4. Context tracking
  -- ==========================================================================

  helpers.describe("context", function()
    helpers.it("getContext returns table with expected fields before start", function()
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

    helpers.it("refreshContext does not crash", function()
      local ok = pcall(function() hook.refreshContext() end)
      helpers.assert_true(ok, "refreshContext does not crash")
    end)

    helpers.it("getContext after refreshContext still returns valid table", function()
      hook.refreshContext()
      local ctx = hook.getContext()
      helpers.assert_true(type(ctx) == "table", "context is still a table")
    end)
  end)

  -- ==========================================================================
  -- 5. Edge cases
  -- ==========================================================================

  helpers.describe("edge cases", function()
    helpers.it("start with bogus options table does not crash", function()
      local ok = pcall(function()
        hook.start({ intercept = "yes", onChar = { also = "wrong" } })
      end)
      helpers.assert_true(ok, "start with bogus options does not crash")
      hook.stop()
    end)

    helpers.it("start-stop-start-stop rapid cycle", function()
      for _ = 1, 5 do
        hook.start({})
        hook.stop()
      end
      helpers.assert_eq(hook.isRunning(), false, "stable after rapid cycle")
    end)
  end)

end)
