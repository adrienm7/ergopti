--- tests/unit/meta/test_text_sender_adapter.lua
---
--- Integration tests for the text_sender adapter.
--- (ydotool/xdotool/xclip stubs). Tests the full API surface
--- (send/eraseChars/pressKey) without requiring ydotool or xdotool.
---
--- Real text injection requires:
---   ydotool (uinput) or xdotool + xclip (X11)

local helpers = require("tests.helpers")

-- The adapter runs its commands through a file-local shell_run built on
-- os.execute, and pipes clipboard payloads through io.popen. Both are replaced
-- here BEFORE the module loads, so every case can state what reaches the system.
--
-- The cases below used to assert a pcall status: "does not crash". os.execute
-- does not raise on a malformed command — it RUNS it. A send that pasted an
-- unescaped payload into `ydotool type -- '…'` would not crash either; it would
-- execute whatever the payload contained. The two are indistinguishable to a
-- pcall, and this adapter exists to build exactly that command.
local real_execute = os.execute
local real_popen   = io.popen
local issued, piped = {}, {}

os.execute = function(cmd)
	issued[#issued + 1] = cmd
	return true
end
io.popen = function(cmd, mode)
	issued[#issued + 1] = cmd
	return {
		write = function(_, data) piped[#piped + 1] = data end,
		close = function() return true end,
		read  = function() return "" end,
		lines = function() return function() return nil end end,
	}
end

local sender = helpers.load_module("adapters.text_sender")

-- Restore immediately: only the adapter's module-level bindings had to see the
-- stubs, and leaving os.execute replaced would silently reshape every later file.
os.execute = real_execute
io.popen   = real_popen

--- Clears both recorders before a case.
local function reset()
	issued, piped = {}, {}
end

--- Runs fn with the recorders installed, then restores the real functions.
--- @param fn function
local function recording(fn)
	reset()
	local saved_exec, saved_popen = os.execute, io.popen
	os.execute = function(cmd) issued[#issued + 1] = cmd ; return true end
	io.popen = function(cmd)
		issued[#issued + 1] = cmd
		return {
			write = function(_, data) piped[#piped + 1] = data end,
			close = function() return true end,
		}
	end
	local ok, err = pcall(fn)
	os.execute, io.popen = saved_exec, saved_popen
	-- Re-raised, not swallowed: a throw here is a real failure and must arrive
	-- with its own stack rather than as a boolean.
	if not ok then error(err, 0) end
end

--- The single command issued by the call, or nil when none was.
local function only_command()
	helpers.assert_eq(#issued, 1, "exactly one command must be issued (saw " .. #issued .. ")")
	return issued[1]
end

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
    helpers.it("types plain text through ydotool in direct mode", function()
      recording(function() sender.send("hello") end)
      local cmd = only_command()
      helpers.assert_true(cmd:find("ydotool type", 1, true) ~= nil,
        "a short payload takes the direct uinput path: " .. cmd)
      helpers.assert_true(cmd:find("hello", 1, true) ~= nil, "and carries the text")
    end)

    helpers.it("still issues a command for an empty string", function()
      recording(function() sender.send("") end)
      helpers.assert_eq(#issued, 1,
        "an empty payload must not silently skip the call — the caller has already "
          .. "committed to an insertion at this point")
    end)

    -- The one that matters: ydotool's argument is single-quoted, so an
    -- apostrophe in the payload closes it and the rest is parsed as shell.
    -- "Does not crash" is precisely what that looks like from outside.
    helpers.it("escapes a single quote so it cannot end the ydotool argument", function()
      recording(function() sender.send("it's a test") end)
      local cmd = only_command()
      helpers.assert_true(cmd:find("'\\''", 1, true) ~= nil,
        "the apostrophe must be closed, escaped and reopened: " .. cmd)
    end)

    helpers.it("keeps shell metacharacters inside the quoted argument", function()
      recording(function() sender.send("$HOME `date` $(cmd)") end)
      local cmd = only_command()
      helpers.assert_true(cmd:find("$HOME `date` $(cmd)", 1, true) ~= nil,
        "the payload must appear verbatim, not expanded: " .. cmd)
      local quotes = select(2, cmd:gsub("'", ""))
      helpers.assert_true(quotes % 2 == 0,
        "the quotes must balance, or the argument runs into the shell: " .. cmd)
    end)

    helpers.it("passes UTF-8 through byte for byte", function()
      recording(function() sender.send("café résumé 日本語") end)
      helpers.assert_true(only_command():find("café résumé 日本語", 1, true) ~= nil,
        "accented and CJK text must survive composition unchanged")
    end)

    helpers.it("auto mode below the threshold uses ydotool, not the clipboard", function()
      recording(function() sender.send("test", { mode = "auto" }) end)
      helpers.assert_true(only_command():find("ydotool", 1, true) ~= nil,
        "a short payload must not take the clipboard path — it would clobber the "
          .. "user's clipboard for four characters")
    end)

    helpers.it("explicit direct mode uses ydotool", function()
      recording(function() sender.send("test", { mode = "direct" }) end)
      helpers.assert_true(only_command():find("ydotool type", 1, true) ~= nil,
        "mode='direct' must take the uinput path")
    end)

    helpers.it("explicit clipboard mode pipes to xclip then pastes", function()
      recording(function() sender.send("test", { mode = "clipboard" }) end)
      helpers.assert_eq(#issued, 2, "the clipboard path is two commands: the pipe and the paste")
      helpers.assert_true(issued[1]:find("xclip", 1, true) ~= nil, "first the payload goes to xclip")
      helpers.assert_true(issued[2]:find("ctrl+v", 1, true) ~= nil, "then Ctrl+V pastes it")
      helpers.assert_eq(piped[1], "test",
        "and the text must reach xclip through the PIPE, never through the command line, "
          .. "where it would need quoting")
    end)

    helpers.it("auto mode above the threshold switches to the clipboard", function()
      local long = string.rep("x", 1500)
      recording(function() sender.send(long, { mode = "auto" }) end)
      helpers.assert_true(issued[1]:find("xclip", 1, true) ~= nil,
        "a 1500-character payload exceeds CLIPBOARD_THRESHOLD and must take the "
          .. "clipboard path — typing it character by character would take seconds")
      helpers.assert_eq(#piped[1], 1500, "the whole payload must be piped, not truncated")
    end)

    helpers.it("coerces nil text to an empty payload rather than the string 'nil'", function()
      recording(function() sender.send(nil) end)
      helpers.assert_true(only_command():find("nil", 1, true) == nil,
        "a nil payload must not be stringified and typed into the user's document: "
          .. only_command())
    end)

    helpers.it("invokes the completion callback", function()
      local called = false
      recording(function() sender.send("test", {}, function() called = true end) end)
      helpers.assert_true(called, "the callback must fire — callers chain on it")
    end)

    helpers.it("a non-function callback is ignored, and the send still happens", function()
      recording(function() sender.send("test", {}, "not a function") end)
      helpers.assert_eq(#issued, 1,
        "a bad callback must not prevent the insertion the caller asked for")
    end)

    helpers.it("an unknown mode falls back to the direct path", function()
      recording(function() sender.send("test", { mode = "quantum" }) end)
      helpers.assert_true(only_command():find("ydotool", 1, true) ~= nil,
        "an unrecognised mode must resolve to a real strategy, not to no command at all")
    end)
  end)

  -- ==========================================================================
  -- 3. eraseChars() — backspace injection
  -- ==========================================================================

  helpers.describe("eraseChars()", function()
    helpers.it("emits exactly the requested number of backspaces", function()
      recording(function() sender.eraseChars(5) end)
      local cmd = only_command()
      helpers.assert_true(cmd:find("--repeat=5", 1, true) ~= nil,
        "the repeat count must be the count asked for — one too many eats a character "
          .. "the user typed, one too few leaves a character the driver meant to remove: "
          .. cmd)
      helpers.assert_true(cmd:find("14:1 14:0", 1, true) ~= nil,
        "and it must be the Backspace keycode, pressed and released")
    end)

    -- Every guard below is asserted as SILENCE, not as "did not throw". A count
    -- that slipped through as 0, -3 or "not a number" would compose
    -- `ydotool key --repeat=<junk>`, and ydotool's own parsing decides what
    -- happens to the user's document next.
    helpers.it("issues nothing for a count of zero", function()
      recording(function() sender.eraseChars(0) end)
      helpers.assert_eq(#issued, 0, "zero backspaces means no command at all")
    end)

    helpers.it("issues nothing for a negative count", function()
      recording(function() sender.eraseChars(-3) end)
      helpers.assert_eq(#issued, 0, "a negative count must not reach ydotool")
    end)

    helpers.it("issues nothing for nil", function()
      recording(function() sender.eraseChars(nil) end)
      helpers.assert_eq(#issued, 0, "a nil count must not reach ydotool")
    end)

    helpers.it("issues nothing for a non-number", function()
      recording(function() sender.eraseChars("not a number") end)
      helpers.assert_eq(#issued, 0, "a string count must not reach ydotool")
    end)

    helpers.it("passes a large count through unchanged", function()
      recording(function() sender.eraseChars(9999) end)
      helpers.assert_true(only_command():find("--repeat=9999", 1, true) ~= nil,
        "a large count is not clamped here — the caller owns how much it erases")
    end)
  end)

  -- ==========================================================================
  -- 4. pressKey() — single keystroke injection
  -- ==========================================================================

  helpers.describe("pressKey()", function()
    helpers.it("emits a bare key with no modifier prefix", function()
      recording(function() sender.pressKey("Return") end)
      local cmd = only_command()
      helpers.assert_true(cmd:find("xdotool key Return", 1, true) ~= nil,
        "a plain key must reach xdotool with no leading + : " .. cmd)
    end)

    helpers.it("prefixes a single modifier", function()
      recording(function() sender.pressKey("c", { "ctrl" }) end)
      helpers.assert_true(only_command():find("ctrl+c", 1, true) ~= nil,
        "xdotool joins modifiers to the key with + — a missing join sends the key "
          .. "WITHOUT the modifier, which is how Ctrl+C becomes a literal c")
    end)

    helpers.it("joins several modifiers in order", function()
      recording(function() sender.pressKey("Tab", { "ctrl", "shift", "alt" }) end)
      helpers.assert_true(only_command():find("ctrl+shift+alt+Tab", 1, true) ~= nil,
        "all three modifiers must be present and joined: " .. only_command())
    end)

    helpers.it("an empty modifier list adds no trailing +", function()
      recording(function() sender.pressKey("Escape", {}) end)
      local cmd = only_command()
      helpers.assert_true(cmd:find("key Escape", 1, true) ~= nil,
        "an empty list must not leave a dangling +, which xdotool reads as a "
          .. "modifier named nothing: " .. cmd)
    end)

    helpers.it("nil modifiers behave like an empty list", function()
      recording(function() sender.pressKey("F1", nil) end)
      helpers.assert_true(only_command():find("key F1", 1, true) ~= nil,
        "nil and {} must compose the same command")
    end)
  end)

end)
