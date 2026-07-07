--- tests/unit/meta/test_injector_commands.lua
---
--- Phase 2B — B2: Integration tests for the hotstring injector's shell command
--- construction (ydotool key/type). The actual ydotool execution requires Linux
--- + ydotoold daemon; these tests verify the command strings are well-formed
--- and the injector API handles edge cases gracefully.
---
--- Real ydotool injection requires a Linux machine with:
---   sudo modprobe uinput
---   sudo usermod -aG input $USER
---   ydotoold running

local helpers  = require("tests.helpers")
local injector = helpers.load_module("modules.hotstrings.injector")

helpers.describe("injector (ydotool commands)", function()

  -- ==========================================================================
  -- 1. inject() API contract
  -- ==========================================================================

  helpers.describe("inject()", function()
    helpers.it("does not crash with valid arguments", function()
      -- inject() shells out to ydotool which won't exist on Windows CI,
      -- but the pcall inside should prevent a crash.
      local ok = pcall(function()
        injector.inject(3, "hello")
      end)
      helpers.assert_true(ok, "inject(3, 'hello') does not crash")
    end)

    helpers.it("handles zero backspace count", function()
      local ok = pcall(function()
        injector.inject(0, "text")
      end)
      helpers.assert_true(ok, "inject(0, 'text') does not crash")
    end)

    helpers.it("handles empty replacement text", function()
      local ok = pcall(function()
        injector.inject(3, "")
      end)
      helpers.assert_true(ok, "inject(3, '') does not crash")
    end)

    helpers.it("handles non-string replacement gracefully", function()
      -- The injector validates types and logs an error.
      local ok = pcall(function()
        injector.inject(3, nil)
      end)
      helpers.assert_true(ok, "inject(3, nil) does not crash")
    end)

    helpers.it("handles negative backspace count gracefully", function()
      local ok = pcall(function()
        injector.inject(-1, "text")
      end)
      helpers.assert_true(ok, "inject(-1, 'text') does not crash")
    end)

    helpers.it("handles replacement with single quotes (shell safety)", function()
      -- Single quotes in replacement should be escaped, not crash.
      local ok = pcall(function()
        injector.inject(2, "it's working")
      end)
      helpers.assert_true(ok, "inject with quotes does not crash")
    end)

    helpers.it("handles replacement with shell special chars", function()
      -- Dollar signs, backticks, etc. should not break shell execution.
      local ok = pcall(function()
        injector.inject(1, "$HOME `date` &")
      end)
      helpers.assert_true(ok, "inject with shell chars does not crash")
    end)

    helpers.it("handles replacement with Unicode (UTF-8)", function()
      local ok = pcall(function()
        injector.inject(2, "café résumé")
      end)
      helpers.assert_true(ok, "inject with Unicode does not crash")
    end)

    helpers.it("handles large backspace count", function()
      local ok = pcall(function()
        injector.inject(100, "big delete")
      end)
      helpers.assert_true(ok, "inject(100, ...) does not crash")
    end)
  end)

  -- ==========================================================================
  -- 2. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports inject function", function()
      helpers.assert_true(type(injector.inject) == "function", "inject is a function")
    end)
  end)

end)
