--- tests/unit/meta/test_clipboard_adapter.lua
---
--- Integration tests for the clipboard adapter.
--- (xclip/xsel/wl-paste stubs). Tests the full API surface
--- (read/write/save/restore) without requiring a real clipboard backend.
---
--- Real clipboard access requires:
---   xclip or xsel (X11) or wl-paste/wl-copy (Wayland)

local helpers   = require("tests.helpers")
-- The clipboard adapter's whole job is to compose a shell pipeline — printf into
-- wl-copy, xclip or xsel — so the interesting question is never "did it throw"
-- but "what reached the shell". io.popen does not raise on a malformed command,
-- it RUNS it, and Shell.quote is the only thing standing between clipboard text
-- and the shell interpreting it.
--
-- Both primitives are recorded before the module loads, and each case below now
-- states the command instead of asserting a pcall status.
-- The adapter resolves its backend ONCE at load time from Shell.has_command, and
-- this suite runs on a machine with no clipboard tool at all — so without this
-- the module would load with _backend = nil and every method would return early
-- having issued nothing. The tests would then pass over the degenerate path
-- while asserting nothing about the one a Linux user actually takes.
--
-- xclip is forced because it is the X11 default; the wayland and xsel branches
-- differ only in the program name.
local issued = {}
local canned_read = ""

local real_shell = require("adapters.shell_runner")
package.loaded["adapters.shell_runner"] = setmetatable({
	has_command = function(name) return name == "xclip" end,
	-- The WRITE path goes through Shell.run, the read path through io.popen.
	-- Both are recorded into the same list, so a case can assert the command
	-- whichever primitive carried it.
	run = function(cmd)
		issued[#issued + 1] = cmd
		return true
	end,
}, { __index = real_shell })

local real_popen = io.popen

io.popen = function(cmd, mode)
	issued[#issued + 1] = cmd
	if mode == "r" or mode == nil then
		local consumed = false
		return {
			read = function()
				if consumed then return nil end
				consumed = true
				return canned_read
			end,
			lines = function() return function() return nil end end,
			close = function() return true end,
		}
	end
	return {
		write = function() end,
		close = function() return true end,
	}
end

local clipboard = helpers.load_module("adapters.clipboard")


io.popen = real_popen
package.loaded["adapters.shell_runner"] = real_shell

--- Runs fn with io.popen recording, then restores it.
--- @param fn function
local function recording(fn)
	issued = {}
	local saved = io.popen
	io.popen = function(cmd, mode)
		issued[#issued + 1] = cmd
		if mode == "r" or mode == nil then
			local consumed = false
			return {
				read = function()
					if consumed then return nil end
					consumed = true
					return canned_read
				end,
				lines = function() return function() return nil end end,
				close = function() return true end,
			}
		end
		return { write = function() end, close = function() return true end }
	end
	-- Re-raised, not swallowed: a throw here is a real failure and must arrive
	-- with its own stack rather than as a boolean.
	local ok, err = pcall(fn)
	io.popen = saved
	if not ok then error(err, 0) end
end

helpers.describe("clipboard adapter", function()

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports read", function()
      helpers.assert_true(type(clipboard.read) == "function", "read is a function")
    end)
    helpers.it("exports write", function()
      helpers.assert_true(type(clipboard.write) == "function", "write is a function")
    end)
    helpers.it("exports save", function()
      helpers.assert_true(type(clipboard.save) == "function", "save is a function")
    end)
    helpers.it("exports restore", function()
      helpers.assert_true(type(clipboard.restore) == "function", "restore is a function")
    end)
  end)

  -- ==========================================================================
  -- 2. read() — clipboard read
  -- ==========================================================================

  helpers.describe("read()", function()
    helpers.it("read issues one backend command and returns its output", function()
      canned_read = "hello from the clipboard"
      recording(function()
        local result = clipboard.read()
        helpers.assert_eq(result, "hello from the clipboard",
          "read must return what the backend printed, not a copy of the command")
      end)
      helpers.assert_eq(#issued, 1, "exactly one command per read")
      helpers.assert_true(
        issued[1]:find("wl%-paste") or issued[1]:find("xclip") or issued[1]:find("xsel"),
        "the command must invoke a real clipboard backend: " .. issued[1])
    end)

    helpers.it("reading twice issues two commands and does not cache", function()
      canned_read = "first"
      recording(function()
        clipboard.read()
        canned_read = "second"
        local second = clipboard.read()
        helpers.assert_eq(second, "second",
          "the clipboard changes under us — a cached read would hand back stale text "
            .. "and paste the wrong thing")
      end)
      helpers.assert_eq(#issued, 2, "each read must ask the backend again")
    end)
  end)

  -- ==========================================================================
  -- 3. write() — clipboard write
  -- ==========================================================================

  helpers.describe("write()", function()
    helpers.it("write pipes the text through printf into the backend", function()
      recording(function() clipboard.write("test") end)
      helpers.assert_eq(#issued, 1, "exactly one command per write")
      local cmd = issued[1]
      helpers.assert_true(cmd:find("printf", 1, true) ~= nil,
        "the payload goes through printf, not echo — echo mangles backslashes and "
          .. "leading dashes: " .. cmd)
      helpers.assert_true(cmd:find("'test'", 1, true) ~= nil, "and the text is quoted")
    end)

    helpers.it("an empty string is still written, not skipped", function()
      recording(function() clipboard.write("") end)
      helpers.assert_eq(#issued, 1,
        "clearing the clipboard by writing empty is a legitimate operation — the "
          .. "clipboard-mode paste restores the user's original this way")
    end)

    helpers.it("write(nil) returns false and issues NOTHING", function()
      recording(function()
        helpers.assert_eq(clipboard.write(nil), false, "a nil payload must report failure")
      end)
      helpers.assert_eq(#issued, 0, "and must not reach the shell at all")
    end)

    helpers.it("write(42) returns false and issues NOTHING", function()
      recording(function()
        helpers.assert_eq(clipboard.write(42), false, "a non-string payload must report failure")
      end)
      helpers.assert_eq(#issued, 0, "and must not reach the shell either")
    end)

    helpers.it("UTF-8 survives into the command", function()
      recording(function() clipboard.write("café résumé") end)
      helpers.assert_true(issued[1]:find("café résumé", 1, true) ~= nil,
        "accented text must reach the backend byte for byte: " .. issued[1])
    end)

    -- The one that matters. The clipboard carries whatever the user copied, so
    -- this payload is entirely attacker-controlled by construction.
    helpers.it("shell metacharacters in the payload are neutralised", function()
      recording(function() clipboard.write("it's $(id); rm -rf /") end)
      local cmd = issued[1]
      helpers.assert_true(cmd:find("'\\''", 1, true) ~= nil,
        "the apostrophe must be closed, escaped and reopened, or everything after it "
          .. "is parsed as shell: " .. cmd)
      helpers.assert_true(cmd:find("$(id); rm -rf /", 1, true) ~= nil,
        "and the rest must appear verbatim inside the quoting, not expanded")
    end)

    helpers.it("a long payload is not truncated", function()
      local long = string.rep("clipboard test ", 200)
      recording(function() clipboard.write(long) end)
      helpers.assert_true(issued[1]:find(long, 1, true) ~= nil,
        "a 3000-character payload must reach the command whole")
    end)
  end)

  -- ==========================================================================
  -- 4. save() / restore() — clipboard save/restore cycle
  -- ==========================================================================

  helpers.describe("save/restore cycle", function()
    helpers.it("save reads the current contents", function()
      canned_read = "user's own clipboard"
      recording(function()
        helpers.assert_eq(clipboard.save(), "user's own clipboard",
          "save must return what is on the clipboard — this value is what gets put "
            .. "back after a clipboard-mode paste, so losing it loses the user's data")
      end)
      helpers.assert_eq(#issued, 1, "save is one read")
    end)

    helpers.it("restore(nil) clears by writing an empty payload", function()
      recording(function()
        helpers.assert_eq(clipboard.restore(nil), true, "clearing must report success")
      end)
      helpers.assert_eq(#issued, 1, "clearing still issues a write")
      helpers.assert_true(issued[1]:find("printf", 1, true) ~= nil,
        "and it goes through the same write path")
    end)

    helpers.it("restore('') writes an empty payload", function()
      recording(function() clipboard.restore("") end)
      helpers.assert_eq(#issued, 1, "an empty restore is still a write")
    end)

    helpers.it("restore quotes the text it puts back", function()
      recording(function() clipboard.restore("restored 'text'") end)
      helpers.assert_true(issued[1]:find("'\''", 1, true) ~= nil,
        "the saved clipboard is user data and must be quoted on the way back too: "
          .. issued[1])
    end)

    helpers.it("restore(123) issues nothing", function()
      recording(function() clipboard.restore(123) end)
      helpers.assert_eq(#issued, 0,
        "a non-string restore must not reach the shell — the saved value came from "
          .. "save(), so a number here means the caller lost it")
    end)

    helpers.it("save → restore cycle does not crash", function()
      local ok = pcall(function()
        local saved = clipboard.save()
        clipboard.restore(saved)
      end)
      helpers.assert_true(ok, "save-restore cycle does not crash")
    end)
  end)

  -- ==========================================================================
  -- 5. Edge cases
  -- ==========================================================================

  helpers.describe("edge cases", function()
    helpers.it("many save calls in a row does not crash", function()
      local ok = pcall(function()
        for _ = 1, 10 do clipboard.save() end
      end)
      helpers.assert_true(ok, "10x save does not crash")
    end)

    helpers.it("interleaved read/write does not crash", function()
      local ok = pcall(function()
        clipboard.write("a")
        clipboard.read()
        clipboard.write("b")
        clipboard.read()
      end)
      helpers.assert_true(ok, "interleaved read/write does not crash")
    end)
  end)

end)
