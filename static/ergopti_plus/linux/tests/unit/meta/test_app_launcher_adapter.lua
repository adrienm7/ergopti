--- tests/unit/meta/test_app_launcher_adapter.lua
---
--- Integration tests for the app_launcher adapter.
--- (nohup/pgrep stubs). Tests AL_Launch/AL_LaunchWithArgs/AL_IsRunning
--- without requiring real processes.
---
--- Real app launching requires:
---   pgrep + nohup (Linux)

local helpers = require("tests.helpers")

-- The observable effect of every function here is the SHELL COMMAND it issues,
-- so the shell runner is replaced by a recorder BEFORE the adapter is loaded —
-- the adapter binds it as an upvalue at require time.
--
-- Every case below used to assert a pcall status: "does not crash". That is true
-- of a function that does nothing at all, and it is true of one that runs an
-- unquoted path straight through /bin/sh. Recording the command turns each case
-- into a statement about what actually reaches the system.
local real_shell = require("adapters.shell_runner")
local issued = {}
package.loaded["adapters.shell_runner"] = setmetatable({
	run = function(cmd)
		issued[#issued + 1] = cmd
		return ""
	end,
}, { __index = real_shell })

local al = helpers.load_module("adapters.app_launcher")

--- Clears the recorder and returns the command list for the next call.
local function reset()
	issued = {}
	return issued
end

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
    helpers.it("issues a detached nohup command for a plausible app name", function()
      reset()
      al.AL_Launch("firefox")
      helpers.assert_eq(#issued, 1, "exactly one command must be issued")
      helpers.assert_true(issued[1]:find("nohup", 1, true) ~= nil,
        "the launch must be detached with nohup, or the app dies with the driver")
      helpers.assert_true(issued[1]:find("firefox", 1, true) ~= nil,
        "and it must actually name the app")
      helpers.assert_true(issued[1]:sub(-1) == "&",
        "and background it, or Shell.run blocks the driver until the app exits")
    end)

    helpers.it("issues NOTHING for an empty app path", function()
      reset()
      al.AL_Launch("")
      helpers.assert_eq(#issued, 0,
        "an empty path must not reach the shell — `nohup  >/dev/null &` starts a "
          .. "background shell for no reason")
    end)

    helpers.it("issues NOTHING for nil", function()
      reset()
      al.AL_Launch(nil)
      helpers.assert_eq(#issued, 0, "a nil path must not reach the shell")
    end)

    helpers.it("issues NOTHING for a non-string", function()
      reset()
      al.AL_Launch(42)
      helpers.assert_eq(#issued, 0, "a numeric path must not reach the shell")
    end)

    helpers.it("quotes a path containing spaces", function()
      reset()
      al.AL_Launch("/path/with spaces/app")
      helpers.assert_eq(#issued, 1, "the launch must still be issued")
      helpers.assert_true(issued[1]:find("'/path/with spaces/app'", 1, true) ~= nil,
        "the path must be single-quoted — unquoted, the shell splits it at the space "
          .. "and launches /path/with instead")
    end)

    -- The one that matters. "does not crash" was the entire assertion here, and a
    -- function that pastes this straight into /bin/sh does not crash either — it
    -- deletes the user's home directory.
    helpers.it("neutralises shell metacharacters in the path", function()
      reset()
      al.AL_Launch("$HOME/app; rm -rf /")
      helpers.assert_eq(#issued, 1, "the launch must still be issued")
      local cmd = issued[1]
      helpers.assert_true(cmd:find("'$HOME/app; rm -rf /'", 1, true) ~= nil,
        "the whole path must sit inside single quotes, so neither $HOME nor the "
          .. "semicolon is interpreted: " .. cmd)
    end)
  end)

  -- ==========================================================================
  -- 3. AL_LaunchWithArgs() — launch with arguments
  -- ==========================================================================

  helpers.describe("AL_LaunchWithArgs()", function()
    helpers.it("quotes the executable but passes args verbatim", function()
      reset()
      al.AL_LaunchWithArgs("gedit", "--new-window")
      helpers.assert_eq(#issued, 1, "exactly one command must be issued")
      local cmd = issued[1]
      helpers.assert_true(cmd:find("'gedit'", 1, true) ~= nil,
        "the executable must be quoted")
      -- Deliberately NOT quoted: callers pass a ready-made argument string, and
      -- quoting would collapse "--new-window -e echo hi" into one argument.
      helpers.assert_true(cmd:find("--new-window", 1, true) ~= nil,
        "the argument string must survive verbatim, unquoted, or a multi-argument "
          .. "string collapses into a single meaningless one")
    end)

    helpers.it("treats nil args as empty rather than the string 'nil'", function()
      reset()
      al.AL_LaunchWithArgs("app", nil)
      helpers.assert_eq(#issued, 1, "the launch must still be issued")
      helpers.assert_true(issued[1]:find("nil", 1, true) == nil,
        "a nil argument string must not be stringified into the command line: " .. issued[1])
    end)

    helpers.it("issues NOTHING for an empty app_path", function()
      reset()
      al.AL_LaunchWithArgs("", "--flag")
      helpers.assert_eq(#issued, 0, "an empty executable must not reach the shell")
    end)

    helpers.it("stringifies numeric args into the command line", function()
      reset()
      al.AL_LaunchWithArgs("app", 123)
      helpers.assert_eq(#issued, 1, "the launch must still be issued")
      helpers.assert_true(issued[1]:find("123", 1, true) ~= nil,
        "a numeric argument must reach the command line as its digits")
    end)

    -- Args are verbatim BY CONTRACT, so this documents the boundary rather than
    -- claiming safety: a caller that interpolates untrusted text into the
    -- argument string is the one holding the hazard, and the test says where it
    -- lives instead of asserting a "does not crash" that hides it.
    helpers.it("does not quote the argument string — the caller owns its contents", function()
      reset()
      al.AL_LaunchWithArgs("app", "; rm -rf /")
      helpers.assert_eq(#issued, 1, "the launch must still be issued")
      helpers.assert_true(issued[1]:find("; rm -rf /", 1, true) ~= nil,
        "args reach the shell verbatim by contract — every caller must therefore pass a "
          .. "literal it wrote itself, never interpolated user text")
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

    helpers.it("quotes the process name it passes to pgrep", function()
      reset()
      al.AL_IsRunning("; rm -rf /")
      helpers.assert_eq(#issued, 1, "the probe must still be issued")
      helpers.assert_true(issued[1]:find("'; rm -rf /'", 1, true) ~= nil,
        "the process name must sit inside single quotes — unquoted, the semicolon "
          .. "ends the pgrep command and the rest runs as its own: " .. issued[1])
    end)
  end)

  -- ==========================================================================
  -- 5. Edge cases
  -- ==========================================================================

  helpers.describe("edge cases", function()
    helpers.it("three chained calls issue three distinct commands", function()
      reset()
      al.AL_Launch("xterm")
      al.AL_LaunchWithArgs("xterm", "-e echo hello")
      al.AL_IsRunning("xterm")
      helpers.assert_eq(#issued, 3,
        "each call must issue exactly one command — a dropped or duplicated launch is "
          .. "invisible to a check that only asks whether the chain threw")
      helpers.assert_true(issued[3]:find("pgrep", 1, true) ~= nil,
        "and the last one must be the pgrep probe, not a third launch")
    end)
  end)

end)
