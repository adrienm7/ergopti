--- adapters/process_runner.lua

--- ==============================================================================
--- MODULE: Asynchronous Process Runner (Linux)
--- DESCRIPTION:
--- Runs one program with an argument vector in a libuv child process and
--- reports its exit code and bounded output. The daemon owns the grabbed
--- keyboard: a blocking io.popen() of a slow program (the .keylayout to XKB
--- converter takes about a second) would freeze typing for that long.
---
--- FEATURES & RATIONALE:
--- 1. No shell: the program and its arguments reach execve(2) as they are, and
---    the vector is validated by index before spawning (ShellRunner).
--- 2. One terminal callback per run, with a deadline that terminates the whole
---    process group; late libuv callbacks are inert.
--- 3. A program that cannot be started is reported as such (not_found), so a
---    caller can tell a missing interpreter from a failing one.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ShellRunner = require("adapters.shell_runner")
local LibuvExit = require("infra.libuv_exit")
local NativeTimer = require("infra.native_timer")
local LOG = "adapters.process_runner"

local ok_luv, luv = pcall(require, "luv")
if not ok_luv then luv = nil end





-- ====================================
-- ====================================
-- ======= 1/ Constants ===============
-- ====================================
-- ====================================

local DEFAULT_TIMEOUT_MS = 30000
local DEFAULT_MAX_OUTPUT_BYTES = 65536

M.HAS_ASYNC = luv ~= nil





-- ====================================
-- ====================================
-- ======= 2/ Lifecycle ===============
-- ====================================
-- ====================================

--- Closes one libuv handle at most once.
--- @param handle any
local function close_handle(handle)
	if not handle or not luv then return end
	local closing = false
	if type(luv.is_closing) == "function" then
		local ok, value = pcall(luv.is_closing, handle)
		closing = ok and value == true
	end
	if not closing then pcall(luv.close, handle) end
end

--- Terminates the run's whole process group.
--- @param run table
local function terminate_group(run)
	-- Reaping the leader does not release descendants or their inherited pipes.
	if not run.pid or type(luv.kill) ~= "function" then return end
	pcall(luv.kill, -run.pid, "sigterm")
	pcall(luv.kill, -run.pid, "sigkill")
end

--- Publishes the terminal result once and releases every handle.
--- @param run table
--- @param result table { exit_code, stdout, stderr, error, not_found }
local function finish(run, result)
	if run.terminal then return end
	run.terminal = true
	if run.timer then
		pcall(luv.timer_stop, run.timer)
		close_handle(run.timer)
		run.timer = nil
	end
	for _, field in ipairs({ "stdout", "stderr" }) do
		if run[field] then
			if type(luv.read_stop) == "function" then pcall(luv.read_stop, run[field]) end
			close_handle(run[field])
			run[field] = nil
		end
	end
	if run.process and run.exited then
		close_handle(run.process)
		run.process = nil
	end
	local ok, callback_error = pcall(run.callback, result)
	if not ok then Logger.error(LOG, "Process callback raised: %s.", tostring(callback_error)) end
end

--- Completes once the child and both of its streams ended.
--- @param run table
local function maybe_complete(run)
	if run.terminal or not run.exited or not run.stdout_eof or not run.stderr_eof then return end
	finish(run, {
		exit_code = run.exit_code,
		stdout = run.stdout_text,
		stderr = run.stderr_text,
		error = run.exit_code ~= 0 and (run.program .. " exited with code " .. tostring(run.exit_code)) or nil,
	})
end





-- ====================================
-- ====================================
-- ======= 3/ Public API ==============
-- ====================================
-- ====================================

--- Runs one program asynchronously.
--- callback(result) is called exactly once with { exit_code, stdout, stderr,
--- error, not_found }: error is nil only for exit code 0, and not_found is true
--- when the program could not be started at all.
--- @param program string Program name or absolute path (looked up in PATH).
--- @param args table Argument vector (strings only).
--- @param options table|nil { timeout_ms?, max_output_bytes? }
--- @param callback function Terminal callback.
--- @return boolean dispatched Whether the child was started.
function M.run(program, args, options, callback)
	local function reject(message, not_found)
		Logger.error(LOG, "Cannot run %s: %s.", tostring(program), message)
		pcall(callback, { exit_code = -1, stdout = "", stderr = "", error = message, not_found = not_found == true })
		return false
	end
	if type(callback) ~= "function" then error("ProcessRunner.run(): callback must be a function", 2) end
	local refusal = ShellRunner.validate_spawn_args(program, args)
	if refusal ~= "" then return reject("argument vector refused: " .. refusal) end
	if not luv or type(luv.spawn) ~= "function" then return reject("asynchronous processes are unavailable") end
	options = type(options) == "table" and options or {}
	local timeout_ms = tonumber(options.timeout_ms) or DEFAULT_TIMEOUT_MS
	local max_output = tonumber(options.max_output_bytes) or DEFAULT_MAX_OUTPUT_BYTES

	local run = {
		program = program,
		callback = callback,
		stdout_text = "",
		stderr_text = "",
		stdout_eof = false,
		stderr_eof = false,
		exited = false,
		terminal = false,
	}
	local handles_ok = pcall(function()
		-- Capture ownership immediately: later constructor exceptions must not
		-- hide earlier handles from the terminal cleanup path.
		run.stdout = luv.new_pipe(false)
		if not run.stdout then error("stdout allocation refused", 0) end
		run.stderr = luv.new_pipe(false)
		if not run.stderr then error("stderr allocation refused", 0) end
		run.timer = luv.new_timer()
		if not run.timer then error("timer allocation refused", 0) end
	end)
	if not handles_ok or not run.stdout or not run.stderr or not run.timer then
		finish(run, { exit_code = -1, stdout = "", stderr = "", error = "libuv handle allocation failed" })
		return false
	end
	local spawn_ok, process, pid = pcall(luv.spawn, program, {
		args = args,
		stdio = { nil, run.stdout, run.stderr },
		detached = true,
	}, function(code, signal)
		run.exited = true
		run.exit_code = LibuvExit.status(code, signal)
		maybe_complete(run)
		-- A run already finished by its deadline still owns this handle.
		if run.terminal and run.process then
			close_handle(run.process)
			run.process = nil
		end
	end)
	if not spawn_ok or not process then
		-- libuv answers ENOENT when the program is not in PATH.
		local detail = tostring(pid or process)
		finish(run, {
			exit_code = -1, stdout = "", stderr = "",
			error = "cannot start " .. program .. ": " .. detail,
			not_found = detail:find("ENOENT", 1, true) ~= nil,
		})
		return false
	end
	run.process = process
	run.pid = pid

	local timer_ok, timer_started = pcall(NativeTimer.start, luv, run.timer, timeout_ms, 0, function()
		if run.terminal then return end
		terminate_group(run)
		finish(run, { exit_code = -1, stdout = run.stdout_text, stderr = run.stderr_text,
			error = program .. " did not finish within " .. tostring(timeout_ms) .. " ms" })
	end)
	local function consume(field, eof_field, err, chunk)
		if run.terminal then return end
		if err then
			terminate_group(run)
			finish(run, { exit_code = -1, stdout = "", stderr = "", error = tostring(err) })
		elseif chunk == nil then
			run[eof_field] = true
			maybe_complete(run)
		elseif #run[field] + #chunk > max_output then
			terminate_group(run)
			finish(run, { exit_code = -1, stdout = "", stderr = "", error = program .. " output exceeds its limit" })
		else
			run[field] = run[field] .. chunk
		end
	end
	local out_ok, stdout_started = pcall(luv.read_start, run.stdout, function(err, chunk)
		consume("stdout_text", "stdout_eof", err, chunk)
	end)
	local err_ok, stderr_started = pcall(luv.read_start, run.stderr, function(err, chunk)
		consume("stderr_text", "stderr_eof", err, chunk)
	end)
	-- Libuv returns nil/error on native refusal without raising. Its successful
	-- zero receipt is truthy in Lua; pcall status alone admits unsupervised runs.
	if not timer_ok or not timer_started or not out_ok or not stdout_started
		or not err_ok or not stderr_started then
		terminate_group(run)
		finish(run, { exit_code = -1, stdout = "", stderr = "", error = "process supervision could not start" })
		return false
	end
	Logger.debug(LOG, "Started %s asynchronously (pid=%d).", program, pid)
	return true
end

return M
