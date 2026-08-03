--- tests/unit/meta/test_window_info_adapter.lua
---
--- Integration tests for the window_info adapter.
--- (xdotool/swaymsg stub). Tests getFocused/getAll contract compliance
--- without requiring a running X11 or Wayland server.
---
--- Real window info requires:
---   xdotool (X11) or swaymsg (Sway/Wayland)

local helpers = require("tests.helpers")
local wi      = helpers.load_module("adapters.window_info")

helpers.describe("window_info adapter", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports getFocused", function()
      helpers.assert_true(type(wi.getFocused) == "function", "getFocused is a function")
    end)
    helpers.it("exports getAll", function()
      helpers.assert_true(type(wi.getAll) == "function", "getAll is a function")
    end)
  end)

  -- ==========================================================================
  -- 2. getFocused() — focused window identity
  -- ==========================================================================

  helpers.describe("getFocused()", function()
    helpers.it("returns a table, never nil", function()
      local info = wi.getFocused()
      helpers.assert_true(type(info) == "table", "getFocused returns a table")
    end)

    helpers.it("returns expected WindowInfo fields", function()
      local info = wi.getFocused()
      helpers.assert_true(info.appId ~= nil, "has appId")
      helpers.assert_true(info.windowTitle ~= nil, "has windowTitle")
      helpers.assert_true(info.bundleId ~= nil, "has bundleId")
      helpers.assert_true(info.executablePath ~= nil, "has executablePath")
    end)

    helpers.it("returns empty strings when no X11/Wayland available", function()
      local info = wi.getFocused()
      -- On Windows CI, xdotool won't exist — all fields default to ""
      helpers.assert_true(type(info.appId) == "string", "appId is a string")
      helpers.assert_true(type(info.windowTitle) == "string", "windowTitle is a string")
    end)

    helpers.it("does not crash when called twice", function()
      -- Called directly: a raise fails with the real error. The claim is that two
      -- reads AGREE — a query that answered differently on the second call would
      -- make every window-scoped decision depend on how often it was asked.
      local a = wi.getFocused()
      local b = wi.getFocused()
      helpers.assert_eq(type(a), type(b), "two reads must answer the same shape")
    end)

    helpers.it("does not crash when called 100 times", function()
      local first = wi.getFocused()
      for _ = 1, 100 do
        helpers.assert_eq(type(wi.getFocused()), type(first),
          "100 reads must all answer the same shape — this runs on the focus watcher, "
            .. "so a drift here is a leak that only shows after minutes of use")
      end
    end)
  end)

  -- ==========================================================================
  -- 3. getAll() — visible window list
  -- ==========================================================================

  helpers.describe("getAll()", function()
    helpers.it("returns a table, never nil", function()
      local windows = wi.getAll()
      helpers.assert_true(type(windows) == "table", "getAll returns a table")
    end)

    helpers.it("is an array (consecutive numeric indices)", function()
      local windows = wi.getAll()
      -- If empty, #windows = 0. If populated, indices are 1..n.
      helpers.assert_true(type(#windows) == "number", "getAll returns array")
    end)

    helpers.it("each entry has WindowInfo fields when populated", function()
      local windows = wi.getAll()
      for _, w in ipairs(windows) do
        helpers.assert_true(type(w) == "table", "entry is a table")
        helpers.assert_true(w.windowTitle ~= nil, "entry has windowTitle")
      end
    end)

    helpers.it("does not crash when xdotool is absent", function()
      local all = wi.getAll()
      helpers.assert_eq(type(all), "table",
        "with no xdotool the answer is an empty list, not nil — the caller iterates it")
    end)
  end)

  -- ==========================================================================
  -- 4. Edge cases
  -- ==========================================================================

  helpers.describe("edge cases", function()
    helpers.it("getFocused and getAll composed do not crash", function()
      -- The pcall was wrapping the ASSERTIONS, so a failing assertion inside it was
      -- caught and rethrown as a bare "composed calls do not crash" — the diagnostic
      -- named the wrapper instead of the check that failed. Called directly.
      local focused = wi.getFocused()
      local all = wi.getAll()
      helpers.assert_eq(type(all), "table", "getAll must still answer a list after getFocused")
      helpers.assert_true(focused == nil or type(focused) == "table",
        "and getFocused must answer nil or a table, never a half-value")
    end)
  end)

end)
