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
---    lifecycle and streaming-input methods. Supports both the 3-arg form (no
---    streaming callback) and the 4-arg form (streaming chunk callback). Used
---    for curl streaming, supervised helpers, and discovery probes.
--- 3. All hs.task interactions are wrapped in pcall so a task failure never
---    propagates to the caller as an unhandled exception.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")

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
--- terminate() distinguishes an accepted SIGTERM that is still pending from
--- native exit settlement; only the completion callback proves the latter.
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
	local _input_closed = false
	local _lifecycle = "constructing"

	local function _safe_terminate()
		if not _task then return true, "settled" end
		local task = _task
		if _lifecycle == "prepared" or _lifecycle == "start_failed" then
			-- No process was launched, so releasing the prepared object is exact
			-- settlement and requires no signal or completion callback.
			_task = nil
			_input_closed = true
			_lifecycle = "terminated"
			M._active_tasks[task] = nil
			return true, "settled"
		end
		if _lifecycle == "terminating" then return true, "pending" end

		local stopped, stop_result = pcall(function() return task:terminate() end)
		if not stopped or stop_result == false or stop_result == nil then
			-- Keep both the native task and its GC pin: this handle is the only exact
			-- capability that can retry termination without process discovery.
			Logger.error(LOG, "spawn.terminate(): native task stop failed; retained for retry — %s",
				tostring(stop_result))
			return false, "refused"
		end
		_input_closed = true
		-- hs.task:terminate() only sends SIGTERM. The callback may run
		-- synchronously in a hostile double, but the real task normally exits
		-- later. Retain the exact handle and GC pin until wrapped_on_done observes
		-- that exit; otherwise a successor can overlap native side effects.
		if _task ~= task or _lifecycle == "completed" then return true, "settled" end
		_lifecycle = "terminating"
		return true, "pending"
	end

	--- Starts the underlying task, reporting the outcome to the caller.
	--- Callers that latch an "in flight" flag before calling this MUST branch on
	--- the return value: this function never raises, so a logged-only failure is
	--- invisible to pcall and would leave such a flag set for the process lifetime.
	--- @return boolean True when the subprocess was started, false on any failure.
	local function _safe_start()
		if _lifecycle == "starting" or _lifecycle == "started" then return true end
		if not _task then
			Logger.error(LOG, "spawn.start(): task was not created for %s", tostring(executable))
			return false
		end
		local task = _task
		_lifecycle = "starting"
		-- The closure MUST return the value: hs.task:start() reports a refused launch
		-- by RETURNING false, not by raising, so a pcall that only captures the raise
		-- reported success for the most common real failure (missing or non-executable
		-- binary) — exactly the case this function's contract exists to surface.
		local ok, started = pcall(function() return task:start() end)
		-- Release the GC pin on BOTH failure paths. The pin is taken at
		-- construction so the task cannot be collected mid-run, and is released by
		-- the completion callback — which never fires for a task that never
		-- launched. Without this, every refused launch left a dead hs.task and its
		-- captured closures in the GC root for the life of the process, and the
		-- root is the one table that is never pruned.
		if not ok then
			if _lifecycle ~= "completed" then
				M._active_tasks[task] = nil
				if _task == task then _task = nil end
				_input_closed = true
				_lifecycle = "start_failed"
			end
			Logger.error(LOG, "spawn.start(): hs.task:start() failed — %s", tostring(started))
			return false
		end
		if not started then
			if _lifecycle ~= "completed" then
				M._active_tasks[task] = nil
				if _task == task then _task = nil end
				_input_closed = true
				_lifecycle = "start_failed"
			end
			Logger.error(LOG, "spawn.start(): hs.task:start() refused to launch %s", tostring(executable))
			return false
		end
		if _lifecycle == "starting" then _lifecycle = "started" end
		return true
	end

	--- Writes bytes to a live streaming task without exposing its native handle.
	--- Multiple native writes are deliberately not queued here because the task
	--- API discards input that has not yet drained. Protocol owners must serialize
	--- writes with acknowledgements before calling this method again.
	--- @param data string Bytes to forward to the task's standard input.
	--- @return boolean True when the native task accepted the input.
	local function _safe_set_input(data)
		if not _task or _input_closed then
			Logger.error(LOG, "spawn.set_input(): no writable task exists for %s.", tostring(executable))
			return false
		end
		if type(data) ~= "string" or data == "" then
			Logger.error(LOG, "spawn.set_input(): input must be a non-empty string for %s.", tostring(executable))
			return false
		end
		local ok, result = pcall(function() return _task:setInput(data) end)
		if not ok or result == false or result == nil then
			Logger.error(LOG, "spawn.set_input(): task input failed for %s — %s",
				tostring(executable), tostring(result))
			return false
		end
		return true
	end

	--- Closes a streaming task's standard input, delivering EOF exactly once.
	--- @return boolean True when EOF was delivered or had already been delivered.
	local function _safe_close_input()
		if _input_closed then return true end
		if not _task then
			Logger.error(LOG, "spawn.close_input(): no live task exists for %s.", tostring(executable))
			return false
		end
		local ok, result = pcall(function() return _task:closeInput() end)
		if not ok or result == false or result == nil then
			Logger.error(LOG, "spawn.close_input(): closing task input failed for %s — %s",
				tostring(executable), tostring(result))
			return false
		end
		_input_closed = true
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
	-- The nil guard contains a duplicate or hostile completion after another
	-- terminal path has already released the task.
	local function wrapped_on_done(exit_code, stdout, stderr)
		if _lifecycle == "completed" then
			Logger.warn(LOG, "Ignoring duplicate completion callback for '%s'.", tostring(executable))
			return
		end
		local completed_task = _task
		if completed_task then M._active_tasks[completed_task] = nil end
		_task = nil
		_input_closed = true
		_lifecycle = "completed"
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
		_lifecycle = "prepared"
		-- Pin the task in M._active_tasks so the GC cannot collect it while
		-- the subprocess is still running (shell-runner-gc-kill fix).
		M._active_tasks[_task] = true
	end

	--- Starts the spawned subprocess. Returns true on success, false on failure.
	handle.start = _safe_start

	--- Writes one already-framed input payload to a streaming subprocess.
	handle.set_input = _safe_set_input

	--- Closes the subprocess input so a supervised helper observes EOF.
	handle.close_input = _safe_close_input

	--- Requests subprocess termination. Idempotent and retryable.
	--- @return boolean accepted True when SIGTERM was accepted or no task remains.
	--- @return string state `settled`, `pending`, or `refused`.
	handle.terminate = _safe_terminate

	return handle
end





-- ===============================================
-- ===============================================
-- ======= 3/ Non-blocking OS Conveniences =======
-- ===============================================
-- ===============================================

-- These two exist so the interactive layer — everything that runs in response to
-- a live keystroke or gesture — has a non-blocking way to do the two things it
-- used `hs.execute` and `hs.osascript.applescript` for. Both of those APIs are
-- synchronous: they hold the single Hammerspoon runloop until the child exits, so
-- the keyboard tap receives nothing for the duration and macOS can disable it for
-- missing its deadline. `hs.timer.doAfter(0, …)` does not help — the timer body
-- runs on that same runloop, which moves the freeze instead of removing it.

-- Absolute paths: the interactive layer must not depend on the inherited PATH,
-- which differs between a login shell and the Hammerspoon process.
local OPEN_BIN      = "/usr/bin/open"
local OSASCRIPT_BIN = "/usr/bin/osascript"

--- Invokes a caller-supplied callback so a throw inside it is LOGGED, not eaten.
---
--- `pcall` is deliberately not used: it returns the error and discards it, which
--- is the swallowing pattern `wrapped_on_done` was fixed for and that
--- `tests/unit/adapters/test_shell_runner_on_done_visible.lua` pins against. These
--- callbacks run from an hs.task completion, where a bare throw is invisible.
--- @param label string Identifies the call site in the log line.
--- @param fn function|nil The callback. Nothing happens when it is absent.
--- @param ... any Arguments forwarded to the callback.
local function invoke_guarded(label, fn, ...)
	if type(fn) ~= "function" then return end
	local args = table.pack(...)
	local ok, err = xpcall(function() return fn(table.unpack(args, 1, args.n)) end, debug.traceback)
	if not ok then
		Logger.error(LOG, "%s callback threw: %s", tostring(label), tostring(err))
	end
end

--- Opens a file, folder or URL with Launch Services, without blocking.
---
--- `open` waits for Launch Services to resolve the handler and, on a cold start,
--- for the target application to finish launching — seconds, not milliseconds.
---
--- @param target string Path or URL to open. Passed as an argv entry, so it needs
---        no shell quoting and cannot be re-interpreted by a shell.
--- @param on_done function|nil Optional fn(ok) called with true on exit code 0.
--- @return boolean True when the subprocess was started.
function M.open(target, on_done)
	if type(target) ~= "string" or target == "" then
		Logger.error(LOG, "open(): target must be a non-empty string — nothing opened.")
		invoke_guarded("open.reject", on_done, false)
		return false
	end
	Logger.trace(LOG, "Opening '%s' asynchronously…", target)
	-- No shell is involved, so a target containing a space, a quote or a `$` is
	-- delivered verbatim — the argv form removes the whole shell-quoting class of
	-- bug that `hs.execute("open " .. quote(path))` had to defend against.
	local handle = M.spawn(OPEN_BIN, { target }, function(exit_code)
		local ok = (exit_code == 0)
		if ok then
			Logger.done(LOG, "Opened '%s'.", target)
		else
			Logger.warn(LOG, "open('%s') exited with code %s.", target, tostring(exit_code))
		end
		invoke_guarded("open.done", on_done, ok)
	end)
	local started = handle.start()
	if not started then
		Logger.error(LOG, "open(): could not start %s for '%s'.", OPEN_BIN, target)
		-- A task that never launched never calls back, so a caller waiting on the
		-- callback would wait forever.
		invoke_guarded("open.launch_failed", on_done, false)
	end
	return started
end

--- Runs an AppleScript without blocking, reporting its result to a callback.
---
--- @param script string The AppleScript source.
--- @param on_done function|nil fn(ok, output) where ok is true on exit code 0 and
---        output is stdout with the trailing newline `osascript` always appends
---        stripped — callers compare against bare tokens like "ok", and the raw
---        stdout never equals one.
--- @return boolean True when the subprocess was started.
function M.applescript(script, on_done)
	if type(script) ~= "string" or script == "" then
		Logger.error(LOG, "applescript(): script must be a non-empty string — nothing run.")
		invoke_guarded("applescript.reject", on_done, false, nil)
		return false
	end
	Logger.trace(LOG, "Running AppleScript asynchronously (%d bytes)…", #script)
	local handle = M.spawn(OSASCRIPT_BIN, { "-e", script }, function(exit_code, stdout, stderr)
		local ok  = (exit_code == 0)
		local out = type(stdout) == "string" and stdout:gsub("%s+$", "") or nil
		if ok then
			Logger.done(LOG, "AppleScript completed.")
		else
			Logger.warn(LOG, "AppleScript failed (code %s): %s",
				tostring(exit_code), tostring(stderr):gsub("%s+$", ""))
		end
		invoke_guarded("applescript.done", on_done, ok, out)
	end)
	local started = handle.start()
	if not started then
		Logger.error(LOG, "applescript(): could not start %s.", OSASCRIPT_BIN)
		-- The completion callback never fires for a task that never launched, so
		-- a caller waiting on it would hang forever on its "in flight" branch.
		invoke_guarded("applescript.launch_failed", on_done, false, nil)
	end
	return started
end

return M
