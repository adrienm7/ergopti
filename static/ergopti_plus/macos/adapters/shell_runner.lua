--- adapters/shell_runner.lua

--- ==============================================================================
--- MODULE: ShellRunner Adapter (Hammerspoon)
--- DESCRIPTION:
--- Wraps hs.execute (synchronous shell) and hs.task (async subprocess) behind
--- a stable adapter surface so domain modules can run shell commands and spawn
--- subprocesses without a direct dependency on those hs.* APIs.
---
--- FEATURES & RATIONALE:
--- 1. exec(): synchronous shell execution via hs.execute. Returns the stdout
---    string. Best-effort — failures return "" rather than raising. Used for
---    fire-and-forget operations (mkdir, pkill, nohup daemon starts, stat calls).
--- 2. spawn(): async subprocess via hs.task. Returns an opaque handle with
---    start() and terminate() methods. Supports both the 3-arg form (no streaming
---    callback) and the 4-arg form (streaming chunk callback). Used for curl
---    streaming, zombie-kill bash tasks, and discovery probes.
--- 3. All hs.task interactions are wrapped in pcall so a task failure never
---    propagates to the caller as an unhandled exception.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "adapters.shell_runner"

-- Holds strong references to every live hs.task so Lua's GC cannot kill
-- a subprocess before its on_done callback fires (Hammerspoon GC pitfall:
-- an hs.task not referenced from a GC root is collected and the OS process
-- is killed silently mid-run).
M._active_tasks = {}


-- =========================================
-- =========================================
-- ======= 1/ Synchronous Shell ============
-- =========================================
-- =========================================

--- Executes a shell command synchronously and returns its stdout.
--- Wraps hs.execute(). The command is run via /bin/sh -c.
--- Failures return an empty string — the adapter never raises.
--- @param cmd string Shell command string.
--- @return string stdout output, or "" on any error.
function M.exec(cmd)
	if type(cmd) ~= "string" or cmd == "" then return "" end
	local ok, result = pcall(hs.execute, cmd)
	if not ok then
		Logger.error(LOG, "exec() failed: %s", tostring(result))
		return ""
	end
	return type(result) == "string" and result or ""
end


-- =========================================
-- =========================================
-- ======= 2/ Async Subprocess =============
-- =========================================
-- =========================================

--- Spawns an async subprocess and returns an opaque handle.
--- The handle exposes start() and terminate() — both are safe to call multiple
--- times and on a nil/dead task. start() returns a boolean the caller must check
--- when it latches an "in flight" flag, since a launch failure is only logged.
---
--- @param executable string Absolute path to the binary (e.g. "/usr/bin/curl").
--- @param args        table  Array of string arguments (no shell expansion).
--- @param on_done     function|nil Completion callback: fn(exit_code, stdout, stderr).
--- @param on_chunk    function|nil Streaming callback: fn(task, stdout_chunk, stderr_chunk).
---        When nil, the 3-argument hs.task.new() form is used (no streaming).
--- @return table Handle with start() (returns boolean) and terminate() methods.
function M.spawn(executable, args, on_done, on_chunk)
	local handle = {}
	local _task  = nil

	local function _safe_terminate()
		if _task then
			-- Release the GC pin before terminate() in case on_done never fires.
			M._active_tasks[_task] = nil
			pcall(function() _task:terminate() end)
			_task = nil
		end
	end

	--- Starts the underlying task, reporting the outcome to the caller.
	--- Callers that latch an "in flight" flag before calling this MUST branch on
	--- the return value: this function never raises, so a logged-only failure is
	--- invisible to pcall and would leave such a flag set for the process lifetime.
	--- @return boolean True when the subprocess was started, false on any failure.
	local function _safe_start()
		if not _task then
			Logger.error(LOG, "spawn.start(): task was not created for %s", tostring(executable))
			return false
		end
		local ok, err = pcall(function() _task:start() end)
		if not ok then
			Logger.error(LOG, "spawn.start(): hs.task:start() failed — %s", tostring(err))
			return false
		end
		return true
	end

	--- Forwards a callback's throw to the log + crash reporter, deferring the
	--- reporter call off the current callback's stack frame so a long report build
	--- never runs inline from an hs.task completion/streaming callback. This is now
	--- the ONE live path into the reporter: the logger's timer guard deliberately
	--- stops at the errors sink, because a timer-callback throw is recoverable and
	--- crash_reports/ is reserved for genuine fatals. If this call ever disappears,
	--- the reporter becomes unreachable dead code again (F-HIGH-5).
	--- @param label string Identifies which callback threw, for the log line.
	--- @param err any The error value captured by xpcall.
	local function report_callback_throw(label, err)
		Logger.error(LOG, "%s callback threw for '%s': %s", label, tostring(executable), tostring(err))
		if type(_G.ergopti_report_crash) == "function" then
			local report_ctx = "shell_runner." .. label .. ": " .. tostring(err)
			if type(hs.timer) == "table" and type(hs.timer.doAfter) == "function" then
				hs.timer.doAfter(0, function() pcall(_G.ergopti_report_crash, report_ctx) end)
			else
				pcall(_G.ergopti_report_crash, report_ctx)
			end
		end
	end

	-- Wrap on_done to release the GC-root reference once the subprocess exits.
	-- hs.task completion callback signature is (exitCode, stdOut, stdErr) — no
	-- task object is passed. Use the closure upvalue `_task` for the GC-pin release,
	-- not the first argument (which would be the exit code integer).
	-- The nil guard is essential: terminate() nils `_task` before the OS delivers
	-- the SIGTERM completion callback, so without it this fires `M._active_tasks[nil]`
	-- — a "table index is nil" error on every superseded/cancelled stream.
	local function wrapped_on_done(exit_code, stdout, stderr)
		if _task then M._active_tasks[_task] = nil end
		if type(on_done) == "function" then
			-- xpcall instead of pcall so a throw in on_done is surfaced (not swallowed).
			-- A silently-swallowed throw here is the root cause of the "vert mais aucune
			-- prédiction" class of bugs — the entire callback body aborts on its first
			-- line with no log line anywhere.
			local ok, err = xpcall(function() on_done(exit_code, stdout, stderr) end, debug.traceback)
			if not ok then
				report_callback_throw("on_done", err)
			end
		end
	end

	-- Wrap on_chunk the same way wrapped_on_done wraps on_done. Before this fix,
	-- on_chunk was passed raw into hs.task.new — a throw inside SSE-chunk
	-- handling (e.g. api_ollama/api_mlx_inference's streaming parsers) was
	-- swallowed to the HS Console only, reintroducing the "vert mais aucune
	-- prédiction" silent-failure class specifically for the streaming path
	-- (F-HIGH-21). hs.task's streaming callback contract expects a boolean
	-- return (true = keep streaming, false = stop); default to true on a
	-- caught throw so a single bad chunk does not also kill the whole stream
	-- (the real production on_chunk closures already re-check their own
	-- generation guards on the next chunk).
	local function wrapped_on_chunk(task, stdout_chunk, stderr_chunk)
		if type(on_chunk) ~= "function" then return true end
		local ok, result_or_err = xpcall(function() return on_chunk(task, stdout_chunk, stderr_chunk) end, debug.traceback)
		if not ok then
			report_callback_throw("on_chunk", result_or_err)
			return true
		end
		return result_or_err
	end

	-- Build the hs.task — choose 3-arg or 4-arg form depending on on_chunk.
	local ok, task_or_err
	if type(on_chunk) == "function" then
		ok, task_or_err = pcall(hs.task.new, executable, wrapped_on_done, wrapped_on_chunk, args)
	else
		ok, task_or_err = pcall(hs.task.new, executable, wrapped_on_done, args)
	end

	-- A pcall SUCCESS is not proof a task exists: hs.task.new() RETURNS nil rather
	-- than raising when the launch path is not an executable file. Without the nil
	-- test the else branch below evaluates `M._active_tasks[nil] = true`, which
	-- throws "table index is nil" straight out of spawn(), past every pcall here.
	if not ok or task_or_err == nil then
		Logger.error(LOG, "spawn(): hs.task.new('%s') returned no task — %s", tostring(executable), tostring(task_or_err))
	else
		_task = task_or_err
		-- Pin the task in M._active_tasks so the GC cannot collect it while
		-- the subprocess is still running (shell-runner-gc-kill fix).
		M._active_tasks[_task] = true
	end

	--- Starts the spawned subprocess. Returns true on success, false on failure.
	handle.start = _safe_start

	--- Terminates the subprocess if it is still running. Idempotent.
	handle.terminate = _safe_terminate

	return handle
end

return M
