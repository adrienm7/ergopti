--- tests/unit/meta/test_timer_scheduler_adapter.lua
---
--- Integration tests for the timer_scheduler adapter (luv stub).
--- Tests the full API surface (after/every/cancel/cancelAll) without requiring
--- the luv library. On CI without luv, the stub path returns handles without
--- actually scheduling timers — these tests verify the stub is safe.
---
--- Real luv timers require:
---   sudo apt install lua-luv  (or luarocks install luv)

local helpers = require("tests.helpers")
local ts      = helpers.load_module("adapters.timer_scheduler")

helpers.describe("timer_scheduler adapter", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports after", function()
      helpers.assert_true(type(ts.after) == "function", "after is a function")
    end)
    helpers.it("exports every", function()
      helpers.assert_true(type(ts.every) == "function", "every is a function")
    end)
    helpers.it("exports cancel", function()
      helpers.assert_true(type(ts.cancel) == "function", "cancel is a function")
    end)
    helpers.it("exports cancelAll", function()
      helpers.assert_true(type(ts.cancelAll) == "function", "cancelAll is a function")
    end)
  end)

  -- ==========================================================================
  -- 2. after() — one-shot timer
  -- ==========================================================================

  helpers.describe("after()", function()
    helpers.it("returns an opaque handle", function()
      local handle = ts.after(1.0, function() end)
      helpers.assert_true(type(handle) == "table", "after returns a table")
      helpers.assert_true(handle.fired ~= nil, "handle has fired field")
      helpers.assert_true(handle.id ~= nil, "handle has id field")
    end)

    helpers.it("returns unique IDs across calls", function()
      local h1 = ts.after(1.0, function() end)
      local h2 = ts.after(2.0, function() end)
      helpers.assert_true(h1.id ~= h2.id, "handle IDs are unique")
    end)

    helpers.it("does not crash with zero delay", function()
      local ok = pcall(function()
        ts.after(0, function() end)
      end)
      helpers.assert_true(ok, "after(0, fn) does not crash")
    end)

    helpers.it("does not crash with negative delay", function()
      local ok = pcall(function()
        ts.after(-1, function() end)
      end)
      helpers.assert_true(ok, "after(-1, fn) does not crash")
    end)

    helpers.it("does not crash with nil callback", function()
      local ok = pcall(function()
        ts.after(1.0, nil)
      end)
      helpers.assert_true(ok, "after(1, nil) does not crash (stub path)")
    end)

    helpers.it("does not crash with non-function callback", function()
      local ok = pcall(function()
        ts.after(1.0, "hello")
      end)
      helpers.assert_true(ok, "after(1, 'hello') does not crash")
    end)
  end)

  -- ==========================================================================
  -- 3. every() — repeating timer
  -- ==========================================================================

  helpers.describe("every()", function()
    helpers.it("returns an opaque handle", function()
      local handle = ts.every(5.0, function() end)
      helpers.assert_true(type(handle) == "table", "every returns a table")
    end)

    helpers.it("does not crash with zero interval", function()
      local ok = pcall(function()
        ts.every(0, function() end)
      end)
      helpers.assert_true(ok, "every(0, fn) does not crash")
    end)

    helpers.it("does not crash with very large interval", function()
      local ok = pcall(function()
        ts.every(86400, function() end)
      end)
      helpers.assert_true(ok, "every(86400, fn) does not crash")
    end)
  end)

  -- ==========================================================================
  -- 4. cancel() — cancel a single timer
  -- ==========================================================================

  helpers.describe("cancel()", function()
    helpers.it("cancel on valid handle does not crash", function()
      local h = ts.after(10.0, function() end)
      local ok = pcall(function() ts.cancel(h) end)
      helpers.assert_true(ok, "cancel(handle) does not crash")
    end)

    helpers.it("cancel on nil is safe", function()
      local ok = pcall(function() ts.cancel(nil) end)
      helpers.assert_true(ok, "cancel(nil) does not crash")
    end)

    helpers.it("cancel on non-table is safe", function()
      local ok = pcall(function() ts.cancel("not a handle") end)
      helpers.assert_true(ok, "cancel('string') does not crash")
    end)

    helpers.it("cancel on empty table is safe", function()
      local ok = pcall(function() ts.cancel({}) end)
      helpers.assert_true(ok, "cancel({}) does not crash")
    end)

    helpers.it("cancel on already-cancelled handle is safe (idempotent)", function()
      local h = ts.after(10.0, function() end)
      ts.cancel(h)
      local ok = pcall(function() ts.cancel(h) end)
      helpers.assert_true(ok, "double cancel does not crash")
    end)
  end)

  -- ==========================================================================
  -- 5. cancelAll() — cancel everything
  -- ==========================================================================

  helpers.describe("cancelAll()", function()
    helpers.it("cancelAll when empty does not crash", function()
      local ok = pcall(function() ts.cancelAll() end)
      helpers.assert_true(ok, "cancelAll empty does not crash")
    end)

    helpers.it("cancelAll with active timers does not crash", function()
      ts.after(1.0, function() end)
      ts.after(2.0, function() end)
      ts.every(3.0, function() end)
      local ok = pcall(function() ts.cancelAll() end)
      helpers.assert_true(ok, "cancelAll with timers does not crash")
    end)
  end)

  -- ==========================================================================
  -- 6. Edge cases
  -- ==========================================================================

  helpers.describe("edge cases", function()
    helpers.it("multiple concurrent after calls", function()
      local handles = {}
      for i = 1, 20 do
        handles[i] = ts.after(i * 0.1, function() end)
      end
      helpers.assert_eq(#handles, 20, "20 handles created")
      ts.cancelAll()
    end)

    helpers.it("mixed after and every active simultaneously", function()
      ts.after(1.0, function() end)
      ts.every(2.0, function() end)
      ts.after(3.0, function() end)
      ts.every(4.0, function() end)
      local ok = pcall(function() ts.cancelAll() end)
      helpers.assert_true(ok, "cancelAll mixed does not crash")
    end)
  end)

end)
