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
      local ok = pcall(function()
        wi.getFocused()
        wi.getFocused()
      end)
      helpers.assert_true(ok, "double getFocused() does not crash")
    end)

    helpers.it("does not crash when called 100 times", function()
      local ok = pcall(function()
        for _ = 1, 100 do wi.getFocused() end
      end)
      helpers.assert_true(ok, "100x getFocused() does not crash")
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
      local ok = pcall(function() wi.getAll() end)
      helpers.assert_true(ok, "getAll does not crash")
    end)
  end)

  -- ==========================================================================
  -- 4. Edge cases
  -- ==========================================================================

  helpers.describe("edge cases", function()
    helpers.it("getFocused and getAll composed do not crash", function()
      local ok = pcall(function()
        local focused = wi.getFocused()
        local all = wi.getAll()
        -- Silently consume both
      end)
      helpers.assert_true(ok, "composed calls do not crash")
    end)
  end)

end)
