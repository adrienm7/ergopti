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
--- times and on a nil/dead task.
---
--- @param executable string Absolute path to the binary (e.g. "/usr/bin/curl").
--- @param args        table  Array of string arguments (no shell expansion).
--- @param on_done     function|nil Completion callback: fn(task, exit_code, stdout).
--- @param on_chunk    function|nil Streaming callback: fn(task, stdout_chunk, stderr_chunk).
---        When nil, the 3-argument hs.task.new() form is used (no streaming).
--- @return table Handle with start() and terminate() methods.
function M.spawn(executable, args, on_done, on_chunk)
	local handle = {}
	local _task  = nil

	local function _safe_terminate()
		if _task then
			pcall(function() _task:terminate() end)
			_task = nil
		end
	end

	local function _safe_start()
		if not _task then
			Logger.error(LOG, "spawn.start(): task was not created for %s", tostring(executable))
			return
		end
		local ok, err = pcall(function() _task:start() end)
		if not ok then
			Logger.error(LOG, "spawn.start(): hs.task:start() failed — %s", tostring(err))
		end
	end

	-- Build the hs.task — choose 3-arg or 4-arg form depending on on_chunk.
	local ok, task_or_err
	if type(on_chunk) == "function" then
		ok, task_or_err = pcall(hs.task.new, executable, on_done, on_chunk, args)
	else
		ok, task_or_err = pcall(hs.task.new, executable, on_done, args)
	end

	if not ok then
		Logger.error(LOG, "spawn(): hs.task.new('%s') failed — %s", tostring(executable), tostring(task_or_err))
	else
		_task = task_or_err
	end

	--- Starts the spawned subprocess.
	handle.start = _safe_start

	--- Terminates the subprocess if it is still running. Idempotent.
	handle.terminate = _safe_terminate

	return handle
end

return M
