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

local Logger = require("logger.shim")
local Heredoc = require("shell.heredoc")
local Monotonic = require("infra.monotonic")
local RuntimeLog = require("diagnostics.runtime_log")
local LibuvExit = require("infra.libuv_exit")

local LOG = "adapters.shell_runner"

-- POSIX close-escape-reopen sequence. A single-quoted shell word cannot contain
-- a single quote at all, so the quote is emitted by closing the word, escaping
-- a bare quote outside it, and reopening: 'it'\''s' reads back as "it's".
local QUOTE_ESCAPE = "'\\''"

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
local _record_exit = RuntimeLog.new_process_log(Logger, LOG, Monotonic.now_ms)





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

--- Validates an argv vector destined for luv.spawn (or any execve(2) boundary).
---
--- quote() above is forgiving because it composes a SHELL STRING, where tostring
--- is a meaningful conversion. An argv array is not a string: libuv hands each
--- element to execve as a C string and rejects anything else, without naming the
--- offending slot. The Windows driver lost its metrics worker for sixteen days to
--- exactly that -- six Integer timing constants spliced into a vector -- and the
--- argument index was the only diagnostic that ever located it. Every driver
--- therefore refuses by index at this boundary
--- (keylogger-worker-timings-must-be-strings).
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
	local keys = 0
	for _ in pairs(args) do keys = keys + 1 end
	if keys ~= #args then
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
local ok_luv, luv = pcall(require, "luv")
if not ok_luv then luv = nil end
M.HAS_ASYNC = luv ~= nil

-- What an asynchronous child may print before it is stopped: the callers read
-- a version line or a df row, never a stream
local ASYNC_MAX_OUTPUT_BYTES = 65536

--- Closes one libuv handle at most once.
--- @param handle any
local function close_handle(handle)
	if not handle then return end
	local ok, closing = pcall(luv.is_closing, handle)
	if not (ok and closing == true) then pcall(luv.close, handle) end
end

--- Stops a child's whole process group.
--- @param request table
local function stop_group(request)
	-- A descendant can retain the pipes after libuv reaps the group leader.
	-- The deadline and cancellation still own that group until terminal cleanup.
	if not request.pid then return end
	pcall(luv.kill, -request.pid, "sigterm")
	-- A deadline must also retire children that ignore SIGTERM, or libuv keeps
	-- their process handles alive indefinitely. The other argv runner does this too.
	local ok, status, detail, code = pcall(luv.kill, -request.pid, "sigkill")
	if not ok or (status == nil and code ~= "ESRCH") then
		Logger.error(LOG, "run_async(): could not stop pid %s — %s.",
			tostring(request.pid), tostring(detail or status))
	end
end

--- Publishes one terminal result and releases every handle.
--- @param request table
--- @param result table { ok, code, stdout, stderr, error }
local function finish_async(request, result)
	if request.terminal then return end
	request.terminal = true
	pcall(luv.timer_stop, request.timer)
	close_handle(request.timer)
	for _, field in ipairs({ "stdout", "stderr" }) do
		if request[field] then
			pcall(luv.read_stop, request[field])
			close_handle(request[field])
		end
	end
	if request.exited then close_handle(request.process) end
	_record_exit(request.name, result.code or -1, Monotonic.now_ms() - request.started)
	if request.silent then return end
	local ok, err = pcall(request.callback, result)
	if not ok then Logger.error(LOG, "run_async() callback for %s raised: %s.", request.name, tostring(err)) end
end

--- Completes once the child has exited and both pipes have ended.
--- @param request table
local function maybe_finish(request)
	if request.terminal or not request.exited or not request.stdout_eof or not request.stderr_eof then return end
	finish_async(request, {
		ok     = request.code == 0,
		code   = request.code,
		stdout = request.stdout_text,
		stderr = request.stderr_text,
		error  = request.code ~= 0 and ("exit code " .. tostring(request.code)) or nil,
	})
end

--- Runs a program without a shell and without blocking the event loop.
--- @param executable string Program name or absolute path.
--- @param args table Array of string arguments.
--- @param options table|nil { timeout_ms }
--- @param callback function Receives { ok, code, stdout, stderr, error } once.
--- @return table|nil handle { cancel = function() } — nil when nothing started.
--- @return string|nil error Why nothing started.
function M.run_async(executable, args, options, callback)
	if not luv then return nil, "asynchronous execution needs libuv" end
	local refusal = M.validate_spawn_args(executable, args)
	if refusal ~= "" then return nil, refusal end
	if type(callback) ~= "function" then return nil, "a callback is required" end
	local timeout_ms = type(options) == "table" and tonumber(options.timeout_ms) or nil
	if not timeout_ms or timeout_ms <= 0 then return nil, "a positive timeout_ms is required" end
	local request = {
		name = executable, callback = callback, started = Monotonic.now_ms(),
		stdout_text = "", stderr_text = "", stdout_eof = false, stderr_eof = false,
		exited = false, terminal = false, silent = false,
	}
	request.stdout, request.stderr, request.timer = luv.new_pipe(false), luv.new_pipe(false), luv.new_timer()
	luv.timer_start(request.timer, timeout_ms, 0, function()
		stop_group(request)
		finish_async(request, { ok = false, error = "timeout" })
	end)
	local spawned, process, pid = pcall(luv.spawn, executable, {
		args = args, stdio = { nil, request.stdout, request.stderr }, detached = true,
	}, function(code, signal)
		request.exited = true
		request.code = LibuvExit.status(code, signal)
		maybe_finish(request)
		if request.terminal then close_handle(request.process) end
	end)
	if not spawned or not process then
		-- No child was dispatched. Callers handle this synchronous refusal from
		-- the return value; invoking their completion callback would report twice.
		local reason = "spawn failed: " .. tostring(pid or process)
		request.silent = true
		finish_async(request, { ok = false, error = reason })
		return nil, reason
	end
	request.process, request.pid = process, pid
	for _, stream in ipairs({ { "stdout", "stdout_text", "stdout_eof" }, { "stderr", "stderr_text", "stderr_eof" } }) do
		local field, text, eof = stream[1], stream[2], stream[3]
		luv.read_start(request[field], function(err, chunk)
			if request.terminal then return end
			if err then
				stop_group(request)
				finish_async(request, { ok = false, error = tostring(err) })
			elseif chunk == nil then
				request[eof] = true
				maybe_finish(request)
			elseif #request[text] + #chunk > ASYNC_MAX_OUTPUT_BYTES then
				stop_group(request)
				finish_async(request, { ok = false, error = "output over " .. ASYNC_MAX_OUTPUT_BYTES .. " bytes" })
			else
				request[text] = request[text] .. chunk
			end
		end)
	end
	return {
		cancel = function()
			if request.terminal then return end
			request.silent = true
			stop_group(request)
			finish_async(request, { ok = false, error = "cancelled" })
		end,
	}
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
