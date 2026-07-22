--- tests/unit/meta/test_app_launcher_adapter.lua
---
--- Integration tests for the app_launcher adapter.
--- (nohup/pgrep stubs). Tests AL_Launch/AL_LaunchWithArgs/AL_IsRunning
--- without requiring real processes.
---
--- Real app launching requires:
---   pgrep + nohup (Linux)

local helpers = require("tests.helpers")
local al      = helpers.load_module("adapters.app_launcher")

helpers.describe("app_launcher adapter", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports AL_Launch", function()
      helpers.assert_true(type(al.AL_Launch) == "function", "AL_Launch is a function")
    end)
    helpers.it("exports AL_LaunchWithArgs", function()
      helpers.assert_true(type(al.AL_LaunchWithArgs) == "function", "AL_LaunchWithArgs is a function")
    end)
    helpers.it("exports AL_IsRunning", function()
      helpers.assert_true(type(al.AL_IsRunning) == "function", "AL_IsRunning is a function")
    end)
  end)

  -- ==========================================================================
  -- 2. AL_Launch() — fire-and-forget app launch
  -- ==========================================================================

  helpers.describe("AL_Launch()", function()
    helpers.it("does not crash with a plausible app name", function()
      local ok = pcall(function() al.AL_Launch("firefox") end)
      helpers.assert_true(ok, "AL_Launch('firefox') does not crash")
    end)

    helpers.it("does not crash with empty string", function()
      local ok = pcall(function() al.AL_Launch("") end)
      helpers.assert_true(ok, "AL_Launch('') does not crash")
    end)

    helpers.it("does not crash with nil", function()
      local ok = pcall(function() al.AL_Launch(nil) end)
      helpers.assert_true(ok, "AL_Launch(nil) does not crash")
    end)

    helpers.it("does not crash with number", function()
      local ok = pcall(function() al.AL_Launch(42) end)
      helpers.assert_true(ok, "AL_Launch(42) does not crash")
    end)

    helpers.it("does not crash with path containing spaces", function()
      local ok = pcall(function()
        al.AL_Launch("/path/with spaces/app")
      end)
      helpers.assert_true(ok, "AL_Launch with spaces does not crash")
    end)

    helpers.it("does not crash with shell special characters", function()
      local ok = pcall(function()
        al.AL_Launch("$HOME/app; rm -rf /")
      end)
      helpers.assert_true(ok, "AL_Launch with shell injection does not crash")
    end)
  end)

  -- ==========================================================================
  -- 3. AL_LaunchWithArgs() — launch with arguments
  -- ==========================================================================

  helpers.describe("AL_LaunchWithArgs()", function()
    helpers.it("does not crash with app and args", function()
      local ok = pcall(function()
        al.AL_LaunchWithArgs("gedit", "--new-window")
      end)
      helpers.assert_true(ok, "AL_LaunchWithArgs does not crash")
    end)

    helpers.it("does not crash with nil args", function()
      local ok = pcall(function()
        al.AL_LaunchWithArgs("app", nil)
      end)
      helpers.assert_true(ok, "AL_LaunchWithArgs(nil args) does not crash")
    end)

    helpers.it("does not crash with empty app_path", function()
      local ok = pcall(function()
        al.AL_LaunchWithArgs("", "--flag")
      end)
      helpers.assert_true(ok, "AL_LaunchWithArgs('', ...) does not crash")
    end)

    helpers.it("does not crash with number args", function()
      local ok = pcall(function()
        al.AL_LaunchWithArgs("app", 123)
      end)
      helpers.assert_true(ok, "AL_LaunchWithArgs(number args) does not crash")
    end)

    helpers.it("does not crash with shell injection in args", function()
      local ok = pcall(function()
        al.AL_LaunchWithArgs("app", "; rm -rf /")
      end)
      helpers.assert_true(ok, "AL_LaunchWithArgs shell injection does not crash")
    end)
  end)

  -- ==========================================================================
  -- 4. AL_IsRunning() — process existence check
  -- ==========================================================================

  helpers.describe("AL_IsRunning()", function()
    helpers.it("returns a boolean", function()
      local result = al.AL_IsRunning("nonexistent-process-99999")
      helpers.assert_true(type(result) == "boolean", "returns boolean")
    end)

    helpers.it("returns false for empty process name", function()
      helpers.assert_eq(al.AL_IsRunning(""), false, "empty name returns false")
    end)

    helpers.it("returns false for nil process name", function()
      helpers.assert_eq(al.AL_IsRunning(nil), false, "nil name returns false")
    end)

    helpers.it("returns false for number", function()
      helpers.assert_eq(al.AL_IsRunning(42), false, "number returns false")
    end)

    helpers.it("does not crash with shell injection in process name", function()
      local ok = pcall(function()
        al.AL_IsRunning("; rm -rf /")
      end)
      helpers.assert_true(ok, "shell injection in name does not crash")
    end)
  end)

  -- ==========================================================================
  -- 5. Edge cases
  -- ==========================================================================

  helpers.describe("edge cases", function()
    helpers.it("chained calls do not crash", function()
      local ok = pcall(function()
        al.AL_Launch("xterm")
        al.AL_LaunchWithArgs("xterm", "-e echo hello")
        al.AL_IsRunning("xterm")
      end)
      helpers.assert_true(ok, "chained calls do not crash")
    end)
  end)

end)
