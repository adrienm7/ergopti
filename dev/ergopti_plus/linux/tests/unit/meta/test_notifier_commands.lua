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

  -- Every case below inspects the command the notifier composes, through its
  -- own _set_runner seam. The previous version asserted only that send() did
  -- not crash — but io.popen never raises on unescaped input, it EXECUTES it,
  -- so removing the escaping was a silent regression and a real command
  -- injection hole that these tests passed either way.

  --- Captures the command a single send() would run.
  --- @param title string
  --- @param opts table|nil
  --- @return string|nil
  local function captured(title, opts)
    local seen
    notifier._set_runner(function(cmd) seen = cmd end)
    local ok, err = pcall(function() notifier.send(title, opts) end)
    notifier._reset_runner()
    if not ok then error(err, 0) end
    return seen
  end

  --- Counts non-overlapping occurrences of a plain substring.
  local function count_of(haystack, needle)
    local n, pos = 0, 1
    while true do
      local at = haystack:find(needle, pos, true)
      if not at then return n end
      n = n + 1
      pos = at + #needle
    end
  end

  helpers.describe("send() command composition", function()
    helpers.it("passes the title and body through to notify-send", function()
      local cmd = captured("Titre", { body = "Corps" })
      helpers.assert_true(cmd ~= nil, "a command must be composed")
      helpers.assert_true(cmd:find("notify-send", 1, true) ~= nil,
        "notify-send must be the program invoked")
      helpers.assert_true(cmd:find("Titre", 1, true) ~= nil, "the title must reach the command")
      helpers.assert_true(cmd:find("Corps", 1, true) ~= nil, "the body must reach the command")
    end)

    helpers.it("maps the kind to an urgency", function()
      helpers.assert_true(captured("t", { kind = "error" }):find("--urgency=critical", 1, true) ~= nil,
        "an error notification must be critical, or it is silently indistinguishable from routine noise")
      helpers.assert_true(captured("t", { kind = "info" }):find("--urgency=normal", 1, true) ~= nil,
        "info maps to normal")
      helpers.assert_true(captured("t", { kind = "banana" }):find("--urgency=normal", 1, true) ~= nil,
        "an unknown kind must fall back to normal rather than composing an invalid flag")
    end)

    helpers.it("escapes a single quote in the title instead of ending the argument", function()
      local cmd = captured("l'ami", {})
      -- The POSIX close-escape-reopen idiom. A raw quote terminates the
      -- single-quoted argument and hands the remainder to the shell as syntax.
      helpers.assert_true(cmd:find("'\\''", 1, true) ~= nil,
        "an embedded quote must be closed, escaped and reopened — left raw, the rest of the title reaches the shell as code rather than as text")
      local at = cmd:find("'\\''", 1, true)
      helpers.assert_true(cmd:byte(at + 1) == 92,
        "the escape must be a real backslash (byte 92), not a lookalike character")
    end)

    helpers.it("escapes a single quote in the body as well", function()
      local cmd = captured("t", { body = "d'accord" })
      helpers.assert_true(cmd:find("'\\''", 1, true) ~= nil,
        "the body is just as attacker-controlled as the title — a hotstring replacement or an app name can reach it")
    end)

    helpers.it("escapes every quote, not just the first", function()
      local cmd = captured("a'b'c", { body = "d'e'f" })
      helpers.assert_true(count_of(cmd, "'\\''") >= 4,
        "gsub must replace all occurrences — one unescaped quote anywhere is enough to break out of the argument")
    end)

    helpers.it("keeps a command-substitution payload inside the quoted argument", function()
      -- $(...) is inert inside a correctly quoted argument. This pins that the
      -- escaping is what makes it inert, not the characters themselves.
      local cmd = captured("x'$(id)'y", {})
      helpers.assert_true(count_of(cmd, "'\\''") >= 2,
        "both quotes delimiting the payload must be escaped — leaving one raw is what would let the $(...) be executed instead of displayed")
    end)

    helpers.it("composes a command even with no body", function()
      local cmd = captured("seul", nil)
      helpers.assert_true(cmd ~= nil and cmd:find("notify-send", 1, true) ~= nil,
        "a title-only notification must still be sent — the body defaults to empty, not to a skipped call")
    end)
  end)

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
