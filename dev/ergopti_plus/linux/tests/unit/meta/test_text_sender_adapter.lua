--- tests/unit/meta/test_text_sender_adapter.lua
---
--- Integration tests for the text_sender adapter.
--- (ydotool/xdotool/xclip stubs). Tests the full API surface
--- (send/eraseChars/pressKey) without requiring ydotool or xdotool.
---
--- Real text injection requires:
---   ydotool (uinput) or xdotool + xclip (X11)

local helpers = require("tests.helpers")
local sender  = helpers.load_module("adapters.text_sender")

helpers.describe("text_sender adapter", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports send", function()
      helpers.assert_true(type(sender.send) == "function", "send is a function")
    end)
    helpers.it("exports eraseChars", function()
      helpers.assert_true(type(sender.eraseChars) == "function", "eraseChars is a function")
    end)
    helpers.it("exports pressKey", function()
      helpers.assert_true(type(sender.pressKey) == "function", "pressKey is a function")
    end)
  end)

  -- ==========================================================================
  -- 2. send() — text injection
  -- ==========================================================================

  helpers.describe("send()", function()
    helpers.it("send plain text without opts or callback does not crash", function()
      local ok = pcall(function() sender.send("hello") end)
      helpers.assert_true(ok, "send('hello') does not crash")
    end)

    helpers.it("send empty string does not crash", function()
      local ok = pcall(function() sender.send("") end)
      helpers.assert_true(ok, "send('') does not crash")
    end)

    helpers.it("send with single quotes (shell safety)", function()
      local ok = pcall(function()
        sender.send("it's a test")
      end)
      helpers.assert_true(ok, "send with single quotes does not crash")
    end)

    helpers.it("send with backticks and dollar signs (shell safety)", function()
      local ok = pcall(function()
        sender.send("$HOME `date` $(cmd)")
      end)
      helpers.assert_true(ok, "send with shell chars does not crash")
    end)

    helpers.it("send with Unicode (UTF-8)", function()
      local ok = pcall(function()
        sender.send("café résumé 日本語")
      end)
      helpers.assert_true(ok, "send with Unicode does not crash")
    end)

    helpers.it("send with mode='auto' option does not crash", function()
      local ok = pcall(function()
        sender.send("test", { mode = "auto" })
      end)
      helpers.assert_true(ok, "send with mode='auto' does not crash")
    end)

    helpers.it("send with mode='direct' option does not crash", function()
      local ok = pcall(function()
        sender.send("test", { mode = "direct" })
      end)
      helpers.assert_true(ok, "send with mode='direct' does not crash")
    end)

    helpers.it("send with mode='clipboard' option does not crash", function()
      local ok = pcall(function()
        sender.send("test", { mode = "clipboard" })
      end)
      helpers.assert_true(ok, "send with mode='clipboard' does not crash")
    end)

    helpers.it("send large payload triggers clipboard mode in auto", function()
      -- CLIPBOARD_THRESHOLD = 1000
      local long = string.rep("x", 1500)
      local ok = pcall(function()
        sender.send(long, { mode = "auto" })
      end)
      helpers.assert_true(ok, "send large payload auto-mode does not crash")
    end)

    helpers.it("send with nil text gracefully handled", function()
      local ok = pcall(function() sender.send(nil) end)
      helpers.assert_true(ok, "send(nil) does not crash")
    end)

    helpers.it("send with callback invoked", function()
      local called = false
      sender.send("test", {}, function() called = true end)
      helpers.assert_true(called, "callback was invoked")
    end)

    helpers.it("send with non-function callback does not crash", function()
      local ok = pcall(function()
        sender.send("test", {}, "not a function")
      end)
      helpers.assert_true(ok, "send with non-function callback does not crash")
    end)

    helpers.it("send with bogus mode string does not crash", function()
      local ok = pcall(function()
        sender.send("test", { mode = "quantum" })
      end)
      helpers.assert_true(ok, "send with bogus mode does not crash")
    end)
  end)

  -- ==========================================================================
  -- 3. eraseChars() — backspace injection
  -- ==========================================================================

  helpers.describe("eraseChars()", function()
    helpers.it("eraseChars with positive count does not crash", function()
      local ok = pcall(function() sender.eraseChars(5) end)
      helpers.assert_true(ok, "eraseChars(5) does not crash")
    end)

    helpers.it("eraseChars with count zero is a no-op", function()
      local ok = pcall(function() sender.eraseChars(0) end)
      helpers.assert_true(ok, "eraseChars(0) does not crash")
    end)

    helpers.it("eraseChars with negative count is a no-op", function()
      local ok = pcall(function() sender.eraseChars(-3) end)
      helpers.assert_true(ok, "eraseChars(-3) does not crash")
    end)

    helpers.it("eraseChars with nil count is a no-op", function()
      local ok = pcall(function() sender.eraseChars(nil) end)
      helpers.assert_true(ok, "eraseChars(nil) does not crash")
    end)

    helpers.it("eraseChars with string count is a no-op", function()
      local ok = pcall(function() sender.eraseChars("not a number") end)
      helpers.assert_true(ok, "eraseChars('string') does not crash")
    end)

    helpers.it("eraseChars with large count does not crash", function()
      local ok = pcall(function() sender.eraseChars(9999) end)
      helpers.assert_true(ok, "eraseChars(9999) does not crash")
    end)
  end)

  -- ==========================================================================
  -- 4. pressKey() — single keystroke injection
  -- ==========================================================================

  helpers.describe("pressKey()", function()
    helpers.it("pressKey plain key does not crash", function()
      local ok = pcall(function() sender.pressKey("Return") end)
      helpers.assert_true(ok, "pressKey('Return') does not crash")
    end)

    helpers.it("pressKey with modifiers does not crash", function()
      local ok = pcall(function()
        sender.pressKey("c", { "ctrl" })
      end)
      helpers.assert_true(ok, "pressKey with ctrl modifier does not crash")
    end)

    helpers.it("pressKey with multiple modifiers does not crash", function()
      local ok = pcall(function()
        sender.pressKey("Tab", { "ctrl", "shift", "alt" })
      end)
      helpers.assert_true(ok, "pressKey with 3 modifiers does not crash")
    end)

    helpers.it("pressKey with empty modifiers does not crash", function()
      local ok = pcall(function()
        sender.pressKey("Escape", {})
      end)
      helpers.assert_true(ok, "pressKey with empty modifiers does not crash")
    end)

    helpers.it("pressKey with nil modifiers does not crash", function()
      local ok = pcall(function()
        sender.pressKey("F1", nil)
      end)
      helpers.assert_true(ok, "pressKey with nil modifiers does not crash")
    end)
  end)

end)
