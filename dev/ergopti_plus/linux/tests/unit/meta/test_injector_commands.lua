--- tests/unit/meta/test_injector_commands.lua
---
--- Integration tests for the hotstring injector's shell command.
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

  -- Every assertion below drives the REAL command builders through the module's
  -- own _set_runner seam and inspects what they emit. The previous version
  -- wrapped each call in pcall and asserted only that nothing crashed — while
  -- its header claimed it "verifies the command strings are well-formed".
  -- Nothing crashes here regardless: a miscounted backspace deletes the wrong
  -- number of characters and a lost escape is a shell-injection hole, and both
  -- passed.

  --- Captures every command the injector would run.
  --- @param fn function Body to execute with the runner installed.
  --- @return table Array of command strings, in emission order.
  local function capture(fn)
    local cmds = {}
    injector._set_runner(function(cmd)
      cmds[#cmds + 1] = cmd
      return true
    end)
    local ok, err = pcall(fn)
    injector._reset_runner()
    if not ok then error(err, 0) end
    return cmds
  end

  --- Counts non-overlapping occurrences of a plain substring.
  --- @param haystack string
  --- @param needle string
  --- @return number
  local function count_of(haystack, needle)
    local n, pos = 0, 1
    while true do
      local at = haystack:find(needle, pos, true)
      if not at then return n end
      n = n + 1
      pos = at + #needle
    end
  end

  helpers.describe("inject()", function()
    helpers.it("emits exactly one down/up pair per backspace", function()
      local cmds = capture(function() injector.inject(3, "hello") end)

      local key_cmd
      for _, c in ipairs(cmds) do
        if c:find("ydotool key", 1, true) then key_cmd = c end
      end
      helpers.assert_true(key_cmd ~= nil,
        "a backspace count of 3 must produce a ydotool key command")

      -- 14 is KEY_BACKSPACE. Three deletions is three down/up pairs: a
      -- miscount here deletes the wrong number of characters, which is the
      -- single most visible way an expansion can corrupt the user's text.
      helpers.assert_eq(count_of(key_cmd, "14:1"), 3,
        "exactly three key-down events must be emitted for inject(3, ...)")
      helpers.assert_eq(count_of(key_cmd, "14:0"), 3,
        "and exactly three key-up events — an unmatched down leaves the key logically held")
    end)

    helpers.it("emits no key command at all for a zero count", function()
      local cmds = capture(function() injector.inject(0, "text") end)
      for _, c in ipairs(cmds) do
        helpers.assert_true(c:find("ydotool key", 1, true) == nil,
          "a zero backspace count must emit no key command — spawning ydotool to press nothing is pure latency on the injection path")
      end
    end)

    helpers.it("emits no key command for a negative count", function()
      local cmds = capture(function() injector.inject(-1, "text") end)
      for _, c in ipairs(cmds) do
        helpers.assert_true(c:find("ydotool key", 1, true) == nil,
          "a negative count must be treated as nothing to delete, never as a loop bound")
      end
    end)

    helpers.it("types the replacement text", function()
      local cmds = capture(function() injector.inject(0, "bonjour") end)
      local type_cmd
      for _, c in ipairs(cmds) do
        if c:find("ydotool type", 1, true) then type_cmd = c end
      end
      helpers.assert_true(type_cmd ~= nil, "the replacement must be typed")
      helpers.assert_true(type_cmd:find("bonjour", 1, true) ~= nil,
        "and the text must reach the command intact")
    end)

    helpers.it("passes the text after -- so a leading hyphen is not read as a flag", function()
      local cmds = capture(function() injector.inject(0, "-n") end)
      local type_cmd
      for _, c in ipairs(cmds) do
        if c:find("ydotool type", 1, true) then type_cmd = c end
      end
      helpers.assert_true(type_cmd ~= nil, "the replacement must be typed")
      local sep_at = type_cmd:find("--", 1, true)
      helpers.assert_true(sep_at ~= nil,
        "the argument separator must be present, or a replacement starting with a hyphen is parsed as ydotool flags instead of typed")
    end)

    helpers.it("escapes a single quote instead of ending the shell string", function()
      local cmds = capture(function() injector.inject(0, "l'ami") end)
      local type_cmd
      for _, c in ipairs(cmds) do
        if c:find("ydotool type", 1, true) then type_cmd = c end
      end
      helpers.assert_true(type_cmd ~= nil, "the replacement must be typed")

      -- The POSIX close-escape-reopen idiom. A raw quote here would terminate
      -- the single-quoted argument and hand the remainder of the replacement to
      -- the shell as syntax — the difference between typing text and executing
      -- it. Checked bytewise: byte 92 is the backslash the idiom requires.
      helpers.assert_true(type_cmd:find("'\\''", 1, true) ~= nil,
        "an embedded single quote must be closed, escaped and reopened — a raw quote ends the argument and the rest of the replacement reaches the shell as code")
      helpers.assert_true(type_cmd:byte(type_cmd:find("'\\''", 1, true) + 1) == 92,
        "the escape must be a real backslash, not a lookalike character")
    end)

    helpers.it("neutralises a command-substitution attempt", function()
      -- The payload only becomes dangerous if the quoting breaks; inside a
      -- correctly quoted argument $( ) is literal text. This pins that the
      -- dangerous case is the ESCAPING one, not the characters themselves.
      local cmds = capture(function() injector.inject(0, "a'$(id)'b") end)
      local type_cmd
      for _, c in ipairs(cmds) do
        if c:find("ydotool type", 1, true) then type_cmd = c end
      end
      helpers.assert_true(type_cmd ~= nil, "the replacement must be typed")
      helpers.assert_true(count_of(type_cmd, "'\\''") >= 2,
        "every embedded quote must be escaped — leaving one raw is what would let the $(...) it delimits be executed rather than typed")
    end)

    helpers.it("orders the deletions before the replacement", function()
      local cmds = capture(function() injector.inject(2, "xy") end)
      local key_at, type_at
      for i, c in ipairs(cmds) do
        if not key_at and c:find("ydotool key", 1, true) then key_at = i end
        if not type_at and c:find("ydotool type", 1, true) then type_at = i end
      end
      helpers.assert_true(key_at ~= nil and type_at ~= nil,
        "both commands must be emitted for a replacement with deletions")
      helpers.assert_true(key_at < type_at,
        "the backspaces must precede the text, or the replacement is typed first and then partly deleted")
    end)

    helpers.it("emits nothing for a non-string replacement", function()
      local cmds = capture(function() injector.inject(3, nil) end)
      helpers.assert_eq(#cmds, 0,
        "an invalid replacement must be rejected before anything is emitted — deleting three characters and then failing to type the replacement destroys the user's text")
    end)
  end)

  helpers.describe("inter-phase delay", function()
    helpers.it("injector never uses the CPU-time clock (no os.clock busy-wait)", function()
      local fh = assert(io.open(helpers.driver_root() .. "/modules/hotstrings/injector.lua", "r"))
      local src = fh:read("*a"); fh:close()
      helpers.assert_true(src:find("os.clock", 1, true) == nil,
        "injector.lua must not use os.clock() — it would burn a core on the input path")
    end)

    helpers.it("sleep_ms prefers luv.sleep (yielding, no fork on the hot path)", function()
      local fh = assert(io.open(helpers.driver_root() .. "/modules/hotstrings/injector.lua", "r"))
      local src = fh:read("*a"); fh:close()
      helpers.assert_true(src:find("luv.sleep", 1, true) ~= nil,
        "sleep_ms must call luv.sleep on the primary (non-fork) path")
    end)
  end)

  -- ==========================================================================
  -- 3. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports inject function", function()
      helpers.assert_true(type(injector.inject) == "function", "inject is a function")
    end)
  end)

end)
