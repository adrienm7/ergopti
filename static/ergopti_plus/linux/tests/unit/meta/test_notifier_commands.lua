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

  -- The block below used to call the REAL notify-send and assert a pcall status.
  -- Thirteen cases, thirteen "does not crash" — on a machine without libnotify
  -- the adapter's own pcall swallows the failure, so every one of them passed
  -- while sending nothing at all. They go through the same _set_runner seam as
  -- the composition tests above, so each now states what the command contains.
  helpers.describe("send() composes a command for every input shape", function()
    helpers.it("title and body both reach the command", function()
      local cmd = captured("Test Title", { body = "Test body text" })
      helpers.assert_true(cmd:find("Test Title", 1, true) ~= nil, "the title must reach the command")
      helpers.assert_true(cmd:find("Test body text", 1, true) ~= nil, "the body must reach the command")
    end)

    helpers.it("a title with no opts still composes a call", function()
      local cmd = captured("Title only")
      helpers.assert_true(cmd:find("notify-send", 1, true) ~= nil,
        "a title-only notification must still invoke notify-send")
    end)

    helpers.it("each kind maps to its own urgency", function()
      helpers.assert_true(captured("Info", { kind = "info" }):find("--urgency=normal", 1, true) ~= nil,
        "info is normal")
      helpers.assert_true(captured("Warning", { kind = "warn" }):find("--urgency=", 1, true) ~= nil,
        "warn must carry an urgency flag")
      helpers.assert_true(captured("Error", { kind = "error" }):find("--urgency=critical", 1, true) ~= nil,
        "error must be critical, or a failure is indistinguishable from routine noise")
      helpers.assert_true(captured("Unknown", { kind = "custom" }):find("--urgency=normal", 1, true) ~= nil,
        "an unknown kind falls back to normal rather than composing an invalid flag")
    end)
  end)

  -- ==========================================================================
  -- 3. send() with special characters (shell safety)
  -- ==========================================================================

  -- io.popen does not RAISE on unescaped input, it EXECUTES it. "Does not crash"
  -- is therefore exactly what a command-injection hole looks like from the
  -- outside, which is why every case here asserts the escaping instead.
  helpers.describe("send() shell safety", function()
    helpers.it("escapes a single quote in the title", function()
      local cmd = captured("It's working", { body = "Body" })
      helpers.assert_true(cmd:find("'\\''", 1, true) ~= nil,
        "the apostrophe must be escaped as '\\'' — raw, it closes the quoted argument "
          .. "and everything after it is parsed as shell: " .. cmd)
    end)

    helpers.it("escapes a single quote in the body", function()
      local cmd = captured("Title", { body = "Don't panic" })
      helpers.assert_true(cmd:find("'\\''", 1, true) ~= nil,
        "the body is quoted the same way as the title: " .. cmd)
    end)

    helpers.it("renders shell metacharacters inert", function()
      local cmd = captured("$HOME & `date`", { body = "test" })
      helpers.assert_true(cmd:find("$HOME & `date`", 1, true) ~= nil,
        "the payload must appear verbatim inside the quoting, not expanded: " .. cmd)
      -- The whole payload sits between the quotes that open and close that one
      -- argument, so neither & nor the backticks terminate it.
      helpers.assert_true(count_of(cmd, "'") % 2 == 0,
        "the quotes must balance — an odd count means one argument runs into the next: " .. cmd)
    end)

    helpers.it("passes UTF-8 through unchanged", function()
      local cmd = captured("café résumé", { body = "àéèù" })
      helpers.assert_true(cmd:find("café résumé", 1, true) ~= nil,
        "accented characters must survive composition byte for byte")
      helpers.assert_true(cmd:find("àéèù", 1, true) ~= nil, "and so must the body")
    end)

    helpers.it("does not truncate a long title or body", function()
      local long_title = string.rep("X", 200)
      local long_body  = string.rep("Y", 500)
      local cmd = captured(long_title, { body = long_body })
      helpers.assert_true(cmd:find(long_title, 1, true) ~= nil,
        "a 200-character title must reach the command whole")
      helpers.assert_true(cmd:find(long_body, 1, true) ~= nil,
        "a 500-character body must reach the command whole")
    end)

    helpers.it("still composes a call for an empty title", function()
      local cmd = captured("", { body = "body" })
      helpers.assert_true(cmd:find("notify-send", 1, true) ~= nil,
        "an empty title must not silently skip the notification")
      helpers.assert_true(cmd:find("body", 1, true) ~= nil, "and the body must still be carried")
    end)

    helpers.it("treats nil opts as an empty body", function()
      local cmd = captured("Title", nil)
      helpers.assert_true(cmd:find("notify-send", 1, true) ~= nil, "the call must still compose")
      helpers.assert_true(cmd:find("nil", 1, true) == nil,
        "a nil opts table must not stringify into the command line: " .. cmd)
    end)
  end)

end)
