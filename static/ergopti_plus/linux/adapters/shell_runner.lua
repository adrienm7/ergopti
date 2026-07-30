--- adapters/shell_runner.lua

--- ==============================================================================
--- MODULE: ShellRunner Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the ShellRunner adapter that macOS
--- (adapters/shell_runner.lua) and Windows (adapters/shell_runner.ahk) already
--- ship. The Linux driver is the one that shells out the most, yet it was the
--- only driver deriving its argument quoting and its exit-code handling anew at
--- every call site — so both were silently wrong in several places.
---
--- FEATURES & RATIONALE:
--- 1. quote(): the single source of truth for turning an arbitrary Lua string
---    into one inert POSIX shell word. It is the only escaping the driver is
---    allowed to use; string.format("%q") is a LUA literal quoter, not a shell
---    one — it leaves $, ` and $( ) live inside the double quotes it emits, so
---    every call site that used it executed its own input.
--- 2. run(): normalises os.execute() across Lua versions. Lua 5.1/LuaJIT report
---    success as the exit code 0, Lua 5.2+ as the boolean true, so a call site
---    comparing against only one of the two is dead on the other interpreter.
---    CI runs LuaJIT and developers run 5.4, which is exactly how such a bug
---    stays invisible on both sides.
--- 3. exec()/exec_line(): capture stdout without every caller re-implementing
---    the io.popen open/read/close dance and its nil-pipe guard.
--- 4. has_command(): availability probe built on run(), so backend detection
---    cannot regress into the "== 0 only" form again.
--- 5. Test seam: composed commands can be captured instead of executed. io.popen
---    never RAISES on unescaped input — it EXECUTES it — so a test that only
---    checks "nothing crashed" passes whether or not the quoting exists. Handing
---    the command over is the only way a test can assert the quoting at all.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Heredoc = require("shell.heredoc")

local LOG = "adapters.shell_runner"

-- POSIX close-escape-reopen sequence. A single-quoted shell word cannot contain
-- a single quote at all, so the quote is emitted by closing the word, escaping
-- a bare quote outside it, and reopening: 'it'\''s' reads back as "it's".
local QUOTE_ESCAPE = "'\\''"

-- os.execute() reports success as the exit code 0 under Lua 5.1/LuaJIT and as
-- the boolean true from Lua 5.2 onwards. Both spellings must be accepted.
local EXIT_SUCCESS = 0

-- Default opening token of a stdin heredoc for this driver. The framing itself
-- lives in _shared/lua/shell/heredoc.lua.
local HEREDOC_BASE_TOKEN = "ERGOPTI_STDIN"

-- Set by M._set_runner(). Declared above every closure that reads it so it can
-- never be captured as a nil global: in Lua the scope of a local starts AFTER
-- the statement that declares it.
local _test_runner = nil




-- ================================
-- ================================
-- ======= 1/ Shell Quoting =======
-- ================================
-- ================================

--- Turns an arbitrary value into exactly one inert POSIX shell word.
--- Everything inside the returned word is literal: $, `, $( ), ;, &, newlines
--- and spaces all lose their meaning to the shell. This is the ONLY quoting the
--- Linux driver may use when interpolating data into a command string.
--- @param value any Value to quote; nil and non-strings become the empty word.
--- @return string A single-quoted shell word, always non-empty ("''" at least).
function M.quote(value)
	if value == nil then return "''" end
	local s = (type(value) == "string") and value or tostring(value)
	return "'" .. (s:gsub("'", QUOTE_ESCAPE)) .. "'"
end




-- =====================================
-- =====================================
-- ======= 2/ Command Execution ========
-- =====================================
-- =====================================

--- Runs a command for its exit status only, discarding its output.
--- @param cmd string Fully composed shell command (quote every interpolation).
--- @return boolean True when the command exited 0, false on any failure.
function M.run(cmd)
	if type(cmd) ~= "string" or cmd == "" then
		Logger.warn(LOG, "run(): empty command — ignored.")
		return false
	end
	if _test_runner then
		-- A runner that returns a boolean is simulating the exit status, so a
		-- test can drive the failure branch too; anything else means the runner
		-- only wanted to observe the command.
		local simulated = _test_runner(cmd)
		if type(simulated) == "boolean" then return simulated end
		return true
	end
	local ok, code = pcall(os.execute, cmd)
	if not ok then
		Logger.error(LOG, "run(): os.execute failed — %s", tostring(code))
		return false
	end
	return code == true or code == EXIT_SUCCESS
end

--- Runs a command and returns everything it wrote to stdout.
--- Never raises: a missing binary or a refused pipe yields the empty string.
--- @param cmd string Fully composed shell command (quote every interpolation).
--- @return string Captured stdout, or "" on any failure.
function M.exec(cmd)
	if type(cmd) ~= "string" or cmd == "" then
		Logger.warn(LOG, "exec(): empty command — ignored.")
		return ""
	end
	if _test_runner then
		local captured = _test_runner(cmd)
		return type(captured) == "string" and captured or ""
	end
	local ok, out = pcall(function()
		local pipe = io.popen(cmd, "r")
		if not pipe then return "" end
		local content = pipe:read("*a")
		pipe:close()
		return content
	end)
	if not ok then
		Logger.error(LOG, "exec(): io.popen failed — %s", tostring(out))
		return ""
	end
	return type(out) == "string" and out or ""
end

--- Runs a command and returns only its first line of stdout.
--- Mirrors the read("*l") shape callers need when a tool prints one value.
--- @param cmd string Fully composed shell command (quote every interpolation).
--- @return string|nil The first line without its newline, or nil when empty.
function M.exec_line(cmd)
	local out = M.exec(cmd)
	if out == "" then return nil end
	local line = out:match("^([^\r\n]*)")
	if line == nil or line == "" then return nil end
	return line
end




-- ========================================
-- ========================================
-- ======= 3/ Environment Probing =========
-- ========================================
-- ========================================

--- Reports whether an executable is resolvable on PATH.
--- @param binary string Executable name, e.g. "yad".
--- @return boolean True when the binary exists and is executable.
function M.has_command(binary)
	if type(binary) ~= "string" or binary == "" then return false end
	return M.run("command -v " .. M.quote(binary) .. " >/dev/null 2>&1")
end




-- ===================================
-- ===================================
-- ======= 4/ Standard Input =========
-- ===================================
-- ===================================

--- Returns a heredoc terminator that cannot appear as a line of `text`.
--- Delegates to the shared framing: macOS shells out with the same user text,
--- and a second copy of the collision rule is a second place for it to be wrong.
--- @param text string Payload the terminator will delimit.
--- @param base string|nil Starting token.
--- @return string
function M.heredoc_token(text, base)
	return Heredoc.token(text, base or HEREDOC_BASE_TOKEN)
end

--- Appends a quoted heredoc carrying `input` to a composed command.
--- @param cmd        string Fully composed command.
--- @param input      string Payload for the command's standard input.
--- @param token_base string|nil Starting terminator token.
--- @return string The command with its heredoc attached.
function M.with_stdin(cmd, input, token_base)
	return Heredoc.with_stdin(cmd, input, token_base or HEREDOC_BASE_TOKEN)
end

--- Runs a command with `input` on its standard input and captures stdout.
--- @param cmd   string Fully composed command (quote every interpolation).
--- @param input string Payload for standard input.
--- @return string Captured stdout, or "" on any failure.
function M.exec_stdin(cmd, input)
	return M.exec(M.with_stdin(cmd, input))
end




-- ==============================
-- ==============================
-- ======= 5/ Test Seam =========
-- ==============================
-- ==============================

--- Installs a test runner: composed commands are handed to `fn` instead of
--- being executed. `fn` may return a string, which exec() reports as stdout,
--- or a boolean, which run() reports as the simulated exit status.
--- @param fn function|nil Receives the command string; nil resets.
function M._set_runner(fn)
	_test_runner = (type(fn) == "function") and fn or nil
end

--- Restores real execution.
function M._reset_runner()
	_test_runner = nil
end

return M
