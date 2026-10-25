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
--- 3. exec()/exec_line()/exec_checked(): capture stdout without every caller
---    re-implementing the io.popen open/read/close dance and its nil-pipe guard.
---    The checked form preserves exit status so empty output is not confused
---    with a command that failed before producing output.
--- 4. has_command(): availability probe built on run(), so backend detection
---    cannot regress into the "== 0 only" form again.
--- 5. run_async(): runs a program without a shell and without blocking the
---    event loop that reads the grabbed keyboard; libuv owns the child, its
---    pipes and its deadline. Without libuv it refuses rather than falling
---    back to a blocking call.
--- 6. Test seam: composed commands can be captured instead of executed. io.popen
---    never RAISES on unescaped input — it EXECUTES it — so a test that only
---    checks "nothing crashed" passes whether or not the quoting exists. Handing
---    the command over is the only way a test can assert the quoting at all.
--- ==============================================================================

local M = {}
local TableUtil = require("table_util")
local TextUtils = require("text_utils")

local Logger = require("logger.shim")
local Heredoc = require("shell.heredoc")
local Monotonic = require("infra.monotonic")
local RuntimeLog = require("diagnostics.runtime_log")
local Perf = require("infra.perf_counters")
local PhaseStats = require("infra.phase_stats")
local NumberPolicy = require("number_policy")
local OwnedProcess = require("adapters.owned_process")
local ok_luv, luv = pcall(require, "luv")
if not ok_luv then luv = nil end

local LOG = "adapters.shell_runner"

-- os.execute() reports success as the exit code 0 under Lua 5.1/LuaJIT and as
-- the boolean true from Lua 5.2 onwards. Both spellings must be accepted.
local EXIT_SUCCESS = 0

-- Written only after the stdout transmitter succeeds, beyond caller bytes.
local CHECKED_CAPTURE_TRAILER = "\nERGOPTI_CAPTURE_COMPLETE\n"

-- Default opening token of a stdin heredoc for this driver. The framing itself
-- lives in _shared/lua/shell/heredoc.lua.
local HEREDOC_BASE_TOKEN = "ERGOPTI_STDIN"

-- Set by M._set_runner(). Declared above every closure that reads it so it can
-- never be captured as a nil global: in Lua the scope of a local starts AFTER
-- the statement that declares it.
local _test_runner = nil

-- Every real exit is reported through one throttled recorder: the program name,
-- the status and the duration, never the command line, which can carry user
-- text in a heredoc. A child that hung or failed used to leave no trace at all.
local _log_exit = RuntimeLog.new_process_log(Logger, LOG, Monotonic.now_ms)

--- Counts the child (the forks per key and per startup are the figure that
--- matters), times it as the phase process.<program> exactly as the macOS
--- driver does, then reports its exit as above. The phase name is the program
--- basename that RuntimeLog.program_name sanitised, never the command line.
local function _record_exit(name, status, duration_ms)
	Perf.count("shell.spawns")
	local program = (type(name) == "string" and name ~= "") and name or "unknown"
	PhaseStats.add_ms("process." .. program, duration_ms)
	return _log_exit(name, status, duration_ms)
end





-- ================================
-- ================================
-- ======= 1/ Shell Quoting =======
-- ================================
-- ================================

--- Turns an arbitrary value into exactly one inert POSIX shell word.
--- Everything inside the returned word is literal: $, `, $( ), ;, &, newlines
--- and spaces all lose their meaning to the shell. This is the ONLY quoting the
--- Linux driver may use when interpolating data into a command string; the
--- close-escape-reopen of a single quote is text_utils.shell_quote's.
--- @param value any Value to quote; nil becomes the empty word, any other
--- non-string its tostring() text.
--- @return string A single-quoted shell word, always non-empty ("''" at least).
function M.quote(value)
	if value == nil then return "''" end
	return TextUtils.shell_quote(value)
end

--- Validates an argv vector destined for luv.spawn (or any execve(2) boundary).
---
--- quote() above is forgiving because it composes a SHELL STRING, where tostring
--- is a meaningful conversion. An argv array is not a string: libuv hands each
--- element to execve as a C string and rejects anything else, without naming the
--- offending slot. The Windows driver lost its metrics worker for sixteen days to
--- exactly that -- six Integer timing constants spliced into a vector -- and the
--- argument index was the only diagnostic that ever located it. Every driver
--- therefore refuses by index at this boundary
--- (keystats-worker-timings-must-be-strings).
---
--- Numbers are refused rather than coerced on purpose: the caller knows the
--- intended text (seconds? milliseconds? padded?), this function does not.
---
--- @param executable any Expected: a non-empty string.
--- @param args any Expected: a pure array of strings; nil means "no arguments".
--- @return string Empty when admissible, otherwise the refusal reason.
function M.validate_spawn_args(executable, args)
	if type(executable) ~= "string" or executable == "" then
		return "executable must be a non-empty string"
	end
	-- execve receives C strings: libuv silently truncates embedded NUL rather
	-- than refusing a different executable or argv value. Reject before spawn.
	if executable:find("\0", 1, true) then return "executable cannot contain NUL" end
	if args == nil then return "" end
	if type(args) ~= "table" then
		return "args must be a table, got " .. type(args)
	end
	if TableUtil.count(args) ~= #args then
		return "args must be a pure array, not a keyed or sparse table"
	end
	for index = 1, #args do
		if type(args[index]) ~= "string" then
			return string.format("argument %d must be a string, got %s",
				index, type(args[index]))
		end
		if args[index]:find("\0", 1, true) then
			return string.format("argument %d cannot contain NUL", index)
		end
	end
	return ""
end

--- Applies the same execve byte boundary to libc's implicit sh -c argv.
--- popen/system silently shorten an embedded NUL before the shell sees it.
--- @param command any Composed shell command.
--- @param operation string Constant operation name for diagnostics.
--- @return boolean admitted, string|nil refusal
local function valid_shell_command(command, operation)
	if type(command) ~= "string" or command == "" then
		Logger.warn(LOG, "%s(): empty command — ignored.", operation)
		return false, "empty command"
	end
	local refusal = M.validate_spawn_args("sh", { "-c", command })
	if refusal ~= "" then
		Logger.error(LOG, "%s(): %s.", operation, refusal)
		return false, refusal
	end
	return true
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
	if not valid_shell_command(cmd, "run") then return false end
	if _test_runner then
		-- A runner that returns a boolean is simulating the exit status, so a
		-- test can drive the failure branch too; anything else means the runner
		-- only wanted to observe the command.
		local simulated = _test_runner(cmd)
		if type(simulated) == "boolean" then return simulated end
		return true
	end
	local started_ms = Monotonic.now_ms()
	local ok, code, _, exit_code = pcall(os.execute, cmd)
	if not ok then
		Logger.error(LOG, "run(): os.execute failed for '%s' — %s",
			RuntimeLog.program_name(cmd), tostring(code))
		return false
	end
	-- Lua 5.2+ reports (true|nil, "exit", code); LuaJIT reports the raw status.
	_record_exit(RuntimeLog.program_name(cmd), exit_code or code,
		Monotonic.now_ms() - started_ms)
	return code == true or code == EXIT_SUCCESS
end

--- Runs a command and returns everything it wrote to stdout.
--- Never raises: a missing binary or a refused pipe yields the empty string.
--- @param cmd string Fully composed shell command (quote every interpolation).
--- @return string Captured stdout, or "" on any failure.
function M.exec(cmd)
	if not valid_shell_command(cmd, "exec") then return "" end
	if _test_runner then
		local captured = _test_runner(cmd)
		return type(captured) == "string" and captured or ""
	end
	local started_ms = Monotonic.now_ms()
	local status = nil
	local ok, out = pcall(function()
		local pipe = io.popen(cmd, "r")
		if not pipe then return "" end
		local content = pipe:read("*a")
		local closed, _, code = pipe:close()
		status = code or closed
		return content
	end)
	if not ok then
		Logger.error(LOG, "exec(): io.popen failed for '%s' — %s",
			RuntimeLog.program_name(cmd), tostring(out))
		return ""
	end
	_record_exit(RuntimeLog.program_name(cmd), status, Monotonic.now_ms() - started_ms)
	return type(out) == "string" and out or ""
end

--- Runs a command and preserves both stdout and its exit status.
--- Use this wherever an empty successful result has a different meaning from a
--- failed command, such as snapshotting an empty clipboard before replacement.
--- @param cmd string Fully composed shell command (quote every interpolation).
--- @param options table|nil { output_dir? } Native receipt staging directory.
--- @return boolean ok
--- @return string output Captured stdout, including the empty string.
--- @return string|nil error_message
function M.exec_checked(cmd, options)
	local admitted, refusal = valid_shell_command(cmd, "exec_checked")
	if not admitted then return false, "", refusal end
	if options ~= nil and type(options) ~= "table" then return false, "", "invalid checked command options" end
	local output_dir = options and options.output_dir
	if output_dir ~= nil and (type(output_dir) ~= "string" or output_dir == "" or output_dir:find("\0", 1, true)) then
		return false, "", "invalid checked output directory"
	end
	if _test_runner then
		local result = _test_runner(cmd)
		if type(result) == "table" then
			return result.ok == true,
				type(result.output) == "string" and result.output or "",
				result.error
		end
		if type(result) == "string" then return true, result, nil end
		return result == true, "", result == true and nil or "simulated command failure"
	end

	local started_ms = Monotonic.now_ms()
	local call_ok, command_ok, output, error_message = pcall(function()
		-- LuaJIT's io.popen handle does not preserve a child's non-zero status on
		-- every libc/runtime combination. Run the caller's command in a nested
		-- shell, buffer stdout in an atomically-created file, and frame the result
		-- with an unambiguous status/byte-count header and completion trailer.
		-- A cat can emit every byte and still fail; only its successful completion
		-- admits the trailer, even when LuaJIT drops the outer shell's exit code.
		-- An owner with a selected runtime directory can stage its receipt there,
		-- independently of a different TMPDIR that may be unavailable.
		local wrapper = table.concat({
			output_dir and 'output=$(mktemp -p "$2") || exit 125' or "output=$(mktemp) || exit 125",
			"trap 'rm -f -- \"$output\"' EXIT HUP INT TERM",
			"sh -c \"$1\" >\"$output\"",
			"status=$?",
			"byte_count=$(wc -c <\"$output\") || exit 125",
			"printf '%s %s\\n' \"$status\" \"$byte_count\"",
			"cat -- \"$output\" || exit 125",
			"printf '%s' " .. M.quote(CHECKED_CAPTURE_TRAILER),
		}, "\n")
		local framed_command = "sh -c " .. M.quote(wrapper)
			.. " ergopti-exec-checked " .. M.quote(cmd)
		if output_dir then framed_command = framed_command .. " " .. M.quote(output_dir) end
		-- libc/Lua may prefix a popen error with the entire composed command,
		-- including caller text. Keep the native errno, never that raw message.
		local pipe, _, open_errno = io.popen(framed_command, "r")
		if not pipe then
			local code = type(open_errno) == "number" and tostring(open_errno) or "unavailable"
			return false, "", "pipe open failed (errno " .. code .. ")"
		end
		-- Close even when reading raises: pclose also reaps the native child.
		-- Native error text may contain the command, so retain only fixed reasons.
		local read_ok, framed, read_error = pcall(pipe.read, pipe, "*a")
		local close_ok, closed = pcall(pipe.close, pipe)
		if not read_ok or read_error ~= nil or type(framed) ~= "string" then
			return false, "", "native pipe read failed"
		end
		local status, byte_count, payload
		if type(framed) == "string" then
			status, byte_count, payload = framed:match("^(%d+) (%d+)\n(.*)$")
		end
		if not status then
			return false, "", "checked command did not return a status frame"
		end
		local count = tonumber(byte_count)
		local content = payload:sub(1, count)
		if #content ~= count then
			return false, content, "checked command output was truncated"
		end
		if not close_ok then return false, "", "native pipe close failed" end
		if closed ~= true and closed ~= EXIT_SUCCESS then
			return false, content, "native pipe close failed"
		end
		if payload:sub(count + 1) ~= CHECKED_CAPTURE_TRAILER then
			return false, content, "checked command capture did not complete"
		end
		if tonumber(status) ~= EXIT_SUCCESS then
			return false, content, "command exited with status " .. status
		end
		return true, content, nil
	end)
	if not call_ok then
		-- Exceptions from open/read/close can carry the same private arguments.
		Logger.error(LOG, "exec_checked(): native capture raised for '%s'.", RuntimeLog.program_name(cmd))
		return false, "", "native command capture raised"
	end
	_record_exit(RuntimeLog.program_name(cmd), command_ok and 0 or tostring(error_message),
		Monotonic.now_ms() - started_ms)
	return command_ok, output, error_message
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
--- @param binary string Executable name, e.g. "xclip".
--- @param external_only boolean|nil True when the caller requires an external tool.
--- @return boolean True when the binary exists and is executable.
function M.has_command(binary, external_only)
	if type(binary) ~= "string" or binary == "" or binary:find("\0", 1, true) then return false end
	if _test_runner then return M.run("command -v " .. M.quote(binary) .. " >/dev/null 2>&1") end
	if external_only == true and luv
		and type(luv.fs_access) == "function" and type(luv.fs_stat) == "function" then
		-- A picker checks many external tools while the keyboard loop waits.
		-- Native access avoids one shell child per capability. Read PATH and the
		-- filesystem on every request: installations and permissions can change.
		local function executable(path)
			if not luv.fs_access(path, "X") then return false end
			local attributes = luv.fs_stat(path)
			return attributes ~= nil and attributes.type == "file"
		end
		if binary:find("/", 1, true) then return executable(binary) end
		local path = os.getenv("PATH")
		if path ~= nil then
			for directory in (path .. ":"):gmatch("(.-):") do
				if executable((directory == "" and "." or directory) .. "/" .. binary) then return true end
			end
			return false
		end
		-- An unset PATH uses the shell's system default; an empty PATH above
		-- deliberately searches only the current directory.
	end
	if external_only == true then
		-- The shell initializes its own default when PATH was not inherited.
		-- Inspect external files explicitly: command -v also admits builtins
		-- such as ".", and empty PATH components must still search cwd.
		return M.run(table.concat({
			-- Keep the process diagnostic's first word independent of caller bytes.
			"command :",
			"ergopti_probe_binary=" .. M.quote(binary),
			'case "$ergopti_probe_binary" in',
			'  */*) [ -f "$ergopti_probe_binary" ] && [ -x "$ergopti_probe_binary" ]; exit $? ;;',
			"esac",
			"ergopti_probe_path=$PATH",
			"while :; do",
			'  ergopti_probe_directory=${ergopti_probe_path%%:*}',
			'  ergopti_probe_candidate=${ergopti_probe_directory:-.}/$ergopti_probe_binary',
			'  if [ -f "$ergopti_probe_candidate" ] && [ -x "$ergopti_probe_candidate" ]; then exit 0; fi',
			'  case "$ergopti_probe_path" in',
			'    *:*) ergopti_probe_path=${ergopti_probe_path#*:} ;;',
			"    *) exit 1 ;;",
			"  esac",
			"done",
		}, "\n"))
	end
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

--- Appends a heredoc delivering EXACTLY the bytes of `input`.
--- @param cmd        string Fully composed command.
--- @param input      string Payload for the command's standard input.
--- @param token_base string|nil Starting terminator token.
--- @return string The command with its byte-exact heredoc attached.
function M.with_exact_stdin(cmd, input, token_base)
	return Heredoc.with_exact_stdin(cmd, input, token_base or HEREDOC_BASE_TOKEN)
end

--- Runs a command with EXACTLY the bytes of `input` on its standard input.
--- The plain exec_stdin() normalises the payload's trailing newlines away, which
--- is fine for a SQL script and silent corruption for a value being encrypted.
--- @param cmd   string Fully composed command (quote every interpolation).
--- @param input string Payload for standard input, delivered byte for byte.
--- @return string Captured stdout, or "" on any failure.
function M.exec_exact_stdin(cmd, input)
	return M.exec(M.with_exact_stdin(cmd, input))
end





-- ==========================================
-- ==========================================
-- ======= 5/ Asynchronous Execution ========
-- ==========================================
-- ==========================================

-- libuv owns the child, its pipes and its deadline; without it there is no
-- asynchronous child at all, and callers must not fall back to a blocking one
M.HAS_ASYNC = luv ~= nil

-- What an asynchronous child may print before it is stopped: the callers read
-- a version line or a df row, never a stream
local ASYNC_MAX_OUTPUT_BYTES = require("llm.process_limits").defaults().max_output_bytes

--- Runs a program without a shell and without blocking the event loop.
--- @param executable string Program name or absolute path.
--- @param args table Array of string arguments.
--- @param options table|nil { timeout_ms }
--- @param callback function Receives { ok, code, stdout, stderr, error } once.
--- @return table|nil handle { cancel = function() } — nil when admission failed.
--- @return string|nil error Why admission failed; the completion callback stays silent.
function M.run_async(executable, args, options, callback)
	if not luv then return nil, "asynchronous execution needs libuv" end
	local refusal = M.validate_spawn_args(executable, args)
	if refusal ~= "" then return nil, refusal end
	if type(callback) ~= "function" then return nil, "a callback is required" end
	local timeout_ms = type(options) == "table" and tonumber(options.timeout_ms) or nil
	if not NumberPolicy.within_timer_ceiling(timeout_ms) or timeout_ms <= 0 then
		return nil, "a positive timeout_ms within the timer ceiling is required"
	end
	local request = { name = executable, started = Monotonic.now_ms(), constructing = true, admitted = false }
	local pending
	local function record(result)
		if request.recorded then return end
		request.recorded = true
		_record_exit(request.name, result.exit_code or -1, Monotonic.now_ms() - request.started)
	end
	local function publish(result)
		if request.constructing then pending = result; return end
		if not request.admitted then return end
		local reason = result.error
		local code = result.exit_code
		if reason == "process deadline exceeded" then reason, code = "timeout", nil
		elseif reason == "process output exceeds its bound" then
			reason, code = "output over " .. ASYNC_MAX_OUTPUT_BYTES .. " bytes", nil
		elseif reason == "process exited unsuccessfully" then reason = "exit code " .. tostring(code) end
		local answer = { ok = result.ok, code = code, stdout = result.stdout, stderr = result.stderr, error = reason }
		record(result)
		local ok, err = pcall(callback, answer)
		if not ok then Logger.error(LOG, "run_async() callback for %s raised: %s.", request.name, tostring(err)) end
	end
	local operation = OwnedProcess.start(executable, args, {
		owner = "shell_runner:" .. tostring(request), timeout_ms = timeout_ms,
		max_output_bytes = ASYNC_MAX_OUTPUT_BYTES,
	}, publish)
	request.constructing = false
	-- Cancellation suppresses business delivery, not native exit diagnostics.
	operation:on_settled(function() record(operation.result) end)
	if not operation.started or operation.error ~= nil then
		local reason = operation.error or "native process admission refused"
		if reason == "native handle allocation failed" then reason = "handle allocation failed"
		elseif reason == "native process deadline refused" then reason = "timeout activation failed"
		elseif reason == "native output watch refused" then reason = "pipe activation failed"
		elseif reason == "native process dispatch failed" then
			reason = "spawn failed: " .. (operation.spawn_error_code or reason)
		end
		return nil, reason
	end
	request.admitted = true
	if pending then publish(pending) end
	return { cancel = function() return operation:cancel() end }

end





-- ==============================
-- ==============================
-- ======= 6/ Test Seam =========
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
