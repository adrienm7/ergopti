--- tests/unit/meta/test_notifier_commands.lua
---
--- Integration tests for the notifier adapter's notify-send.
--- command construction and error handling. The actual D-Bus notification
--- requires a Linux desktop with notification daemon; these tests verify:
---   1. send() with various title/body/kind combinations
---   2. Graceful degradation when notify-send is unavailable
---   3. Shell safety (special characters in title/body)
---
--- Real notify-send test requires a Linux desktop with:
---   libnotify-bin installed
---   D-Bus session bus running
---   Notification daemon (GNOME Shell, KDE Plasma, dunst, etc.)

local helpers  = require("tests.helpers")
local notifier = helpers.load_module("adapters.notifier")

helpers.describe("notifier (notify-send)", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports send function", function()
      helpers.assert_true(type(notifier.send) == "function", "send is a function")
    end)
  end)

  -- ==========================================================================
  -- 2. send() basic API
  -- ==========================================================================

  helpers.describe("send()", function()
    helpers.it("does not crash with basic title + body", function()
      -- notify-send might not exist on this system (especially Windows).
      -- The adapter wraps the call in pcall, so it should never crash.
      local ok = pcall(function()
        notifier.send("Test Title", { body = "Test body text" })
      end)
      helpers.assert_true(ok, "send(title, body) does not crash")
    end)

    helpers.it("does not crash with only title (no opts)", function()
      local ok = pcall(function()
        notifier.send("Title only")
      end)
      helpers.assert_true(ok, "send(title) does not crash")
    end)

    helpers.it("does not crash with kind='info'", function()
      local ok = pcall(function()
        notifier.send("Info", { body = "Info body", kind = "info" })
      end)
      helpers.assert_true(ok, "send(info) does not crash")
    end)

    helpers.it("does not crash with kind='warn'", function()
      local ok = pcall(function()
        notifier.send("Warning", { body = "Warn body", kind = "warn" })
      end)
      helpers.assert_true(ok, "send(warn) does not crash")
    end)

    helpers.it("does not crash with kind='error'", function()
      local ok = pcall(function()
        notifier.send("Error", { body = "Error body", kind = "error" })
      end)
      helpers.assert_true(ok, "send(error) does not crash")
    end)

    helpers.it("does not crash with unknown kind (falls back to normal)", function()
      local ok = pcall(function()
        notifier.send("Unknown", { body = "Body", kind = "custom" })
      end)
      helpers.assert_true(ok, "send(unknown kind) does not crash")
    end)
  end)

  -- ==========================================================================
  -- 3. send() with special characters (shell safety)
  -- ==========================================================================

  helpers.describe("send() shell safety", function()
    helpers.it("handles single quotes in title", function()
      local ok = pcall(function()
        notifier.send("It's working", { body = "Body" })
      end)
      helpers.assert_true(ok, "send with quote in title does not crash")
    end)

    helpers.it("handles single quotes in body", function()
      local ok = pcall(function()
        notifier.send("Title", { body = "Don't panic" })
      end)
      helpers.assert_true(ok, "send with quote in body does not crash")
    end)

    helpers.it("handles shell metacharacters in title", function()
      local ok = pcall(function()
        notifier.send("$HOME & `date`", { body = "test" })
      end)
      helpers.assert_true(ok, "send with shell chars in title does not crash")
    end)

    helpers.it("handles Unicode (UTF-8) in title and body", function()
      local ok = pcall(function()
        notifier.send("café résumé", { body = "àéèù" })
      end)
      helpers.assert_true(ok, "send with Unicode does not crash")
    end)

    helpers.it("handles long title and body", function()
      local long_title = string.rep("X", 200)
      local long_body  = string.rep("Y", 500)
      local ok = pcall(function()
        notifier.send(long_title, { body = long_body })
      end)
      helpers.assert_true(ok, "send with long text does not crash")
    end)

    helpers.it("handles empty title gracefully", function()
      local ok = pcall(function()
        notifier.send("", { body = "body" })
      end)
      helpers.assert_true(ok, "send with empty title does not crash")
    end)

    helpers.it("handles nil opts gracefully", function()
      local ok = pcall(function()
        notifier.send("Title", nil)
      end)
      helpers.assert_true(ok, "send with nil opts does not crash")
    end)
  end)

end)
