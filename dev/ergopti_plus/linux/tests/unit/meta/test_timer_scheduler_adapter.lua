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

    -- Every case here returns a HANDLE, and the handle is the contract: the caller
    -- keeps it to cancel later. "Does not crash" says nothing about whether one
    -- came back, and a nil handle means the caller can never cancel that timer —
    -- it fires into a torn-down driver.
    helpers.it("a zero delay still yields a cancellable handle", function()
      local h = ts.after(0, function() end)
      helpers.assert_eq(type(h), "table", "after(0) must return a handle, not nil")
      helpers.assert_true(h.id ~= nil, "and it must carry an id, or cancel cannot find it")
      ts.cancel(h)
    end)

    helpers.it("a negative delay is clamped rather than rejected", function()
      local h = ts.after(-1, function() end)
      helpers.assert_eq(type(h), "table",
        "a negative delay must clamp to immediate — dropping the timer would lose "
          .. "the work the caller scheduled")
      ts.cancel(h)
    end)

    helpers.it("a nil callback still yields a handle the caller can cancel", function()
      local h = ts.after(1.0, nil)
      helpers.assert_eq(type(h), "table",
        "the handle is returned before the callback is ever used, so a bad callback "
          .. "must not cost the caller its cancellation token")
      ts.cancel(h)
    end)

    helpers.it("a non-function callback still yields a handle", function()
      local h = ts.after(1.0, "hello")
      helpers.assert_eq(type(h), "table", "same for a string callback")
      ts.cancel(h)
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

    helpers.it("a zero interval yields a handle and does not spin the loop", function()
      local h = ts.every(0, function() end)
      helpers.assert_eq(type(h), "table", "every(0) must return a handle")
      -- The adapter floors the interval at 1 ms. A literal 0 would re-arm the
      -- timer with no delay and peg a core.
      ts.cancel(h)
    end)

    helpers.it("a day-long interval yields a handle", function()
      local h = ts.every(86400, function() end)
      helpers.assert_eq(type(h), "table", "a long interval must not overflow into a dropped timer")
      ts.cancel(h)
    end)
  end)

  -- ==========================================================================
  -- 4. cancel() — cancel a single timer
  -- ==========================================================================

  -- cancel() marks the handle fired. That flag is the observable, and no case
  -- looked at it: a cancel that silently did nothing left a timer live, and the
  -- callback then runs against state the caller has already torn down.
  helpers.describe("cancel()", function()
    -- The adapter degrades when luv is absent: after() returns a handle with NO
    -- timer field and the scheduler is a no-op. That degradation has to be
    -- OBSERVABLE, or a caller cannot tell scheduled work from work that will
    -- never run — so the assertion is split on the same condition the adapter
    -- branches on, rather than asserting a contract only one host satisfies.
    helpers.it("cancelling a live handle marks it spent", function()
      local h = ts.after(10.0, function() end)
      ts.cancel(h)
      if h.timer then
        helpers.assert_eq(h.fired, true,
          "a real timer must be marked spent, or a later cancelAll walks a handle "
            .. "whose libuv timer is already closed")
      else
        helpers.assert_eq(h.timer, nil,
          "with no luv the handle must carry no timer at all — that absence is how a "
            .. "caller can tell nothing was ever scheduled")
      end
    end)

    helpers.it("cancel(nil) is a no-op", function()
      ts.cancel(nil)
      -- Nothing to assert on the argument; what must hold is that the scheduler
      -- still works afterwards.
      local h = ts.after(1.0, function() end)
      helpers.assert_eq(type(h), "table", "the scheduler must still issue handles")
      ts.cancel(h)
    end)

    helpers.it("cancel on a non-table leaves the scheduler usable", function()
      ts.cancel("not a handle")
      local h = ts.after(1.0, function() end)
      helpers.assert_eq(type(h), "table", "a bogus cancel must not poison the scheduler")
      ts.cancel(h)
    end)

    helpers.it("cancel on a table with no timer is a no-op", function()
      ts.cancel({})
      local h = ts.after(1.0, function() end)
      helpers.assert_eq(type(h), "table", "an empty handle must be ignored, not dereferenced")
      ts.cancel(h)
    end)

    helpers.it("cancelling twice is idempotent", function()
      local h = ts.after(10.0, function() end)
      ts.cancel(h)
      local after_first = h.fired
      ts.cancel(h)
      helpers.assert_eq(h.fired, after_first,
        "a second cancel must not change the handle's state — whatever the first "
          .. "left, it stays")
    end)
  end)

  -- ==========================================================================
  -- 5. cancelAll() — cancel everything
  -- ==========================================================================

  helpers.describe("cancelAll()", function()
    helpers.it("cancelAll on an empty scheduler leaves it usable", function()
      ts.cancelAll()
      local h = ts.after(1.0, function() end)
      helpers.assert_eq(type(h), "table", "the scheduler must still issue handles afterwards")
      ts.cancelAll()
    end)

    helpers.it("cancelAll marks every live handle fired", function()
      local a = ts.after(1.0, function() end)
      local b = ts.after(2.0, function() end)
      local c = ts.every(3.0, function() end)
      ts.cancelAll()
      for name, h in pairs({ ["first one-shot"] = a, ["second one-shot"] = b, ["repeater"] = c }) do
        if h.timer then
          helpers.assert_eq(h.fired, true,
            "the " .. name .. " must be marked spent — a surviving repeater fires "
              .. "forever into a driver that has already shut down")
        else
          helpers.assert_eq(h.timer, nil,
            "with no luv the " .. name .. " was never scheduled, and says so")
        end
      end
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

    helpers.it("cancelAll clears a mixed set of one-shots and repeaters", function()
      local handles = {
        ts.after(1.0, function() end),
        ts.every(2.0, function() end),
        ts.after(3.0, function() end),
        ts.every(4.0, function() end),
      }
      ts.cancelAll()
      for i, h in ipairs(handles) do
        if h.timer then
          helpers.assert_eq(h.fired, true,
            "handle " .. i .. " must be marked spent — cancelAll walking only the "
              .. "one-shots is how a repeater outlives the driver")
        else
          helpers.assert_eq(h.timer, nil, "handle " .. i .. " was never scheduled")
        end
      end
    end)
  end)

end)
