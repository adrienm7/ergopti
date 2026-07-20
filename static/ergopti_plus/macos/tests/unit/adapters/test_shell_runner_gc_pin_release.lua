--- tests/unit/adapters/test_shell_runner_gc_pin_release.lua

--- ==============================================================================
--- MODULE: Regression — ShellRunner GC pin is always released
--- DESCRIPTION:
--- Guards against two related bugs in shell_runner.lua:
---
--- F7: wrapped_on_done(task, exit_code, stdout, stderr) — the hs.task completion
---     callback signature is (exitCode, stdOut, stdErr) with NO task object as
---     first arg. So 'task' was the exit code integer, and M._active_tasks[task]
---     (an integer key) was a no-op. The GC pin on the real task object was
---     never released. Table grew unbounded across all spawned commands.
---
--- F35: _safe_terminate() called _task:terminate() without first removing
---     M._active_tasks[_task]. If on_done never fired, the pin leaked.
---
--- Fix (2026-06-19): changed wrapped_on_done signature to (exit_code, stdout,
---     stderr) and used the closure upvalue '_task' for pin release;
---     added M._active_tasks[_task] = nil in _safe_terminate() before terminating.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =====================================================================
-- =====================================================================
-- ======= 1/ ShellRunner source: correct on_done signature ============
-- =====================================================================
-- =====================================================================

helpers.describe("ShellRunner: GC pin release", function()
	helpers.it("wrapped_on_done uses (exit_code, stdout, stderr) signature", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/adapters/shell_runner.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open shell_runner.lua at: " .. src_file)
		local src = fh:read("*a")
		fh:close()

		-- The corrected signature must NOT have 4 params starting with task
		helpers.assert_true(
			src:find("local function wrapped_on_done(task, exit_code,", 1, true) == nil,
			"wrapped_on_done must not have task as first param (hs.task gives no task object)"
		)
		-- Must have the 3-param form
		helpers.assert_true(
			src:find("local function wrapped_on_done(exit_code, stdout, stderr)", 1, true) ~= nil,
			"wrapped_on_done must have signature (exit_code, stdout, stderr)"
		)
	end)

	helpers.it("wrapped_on_done releases pin via closure _task, not the first arg", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/adapters/shell_runner.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open shell_runner.lua")
		local src = fh:read("*a")
		fh:close()

		-- Find wrapped_on_done function body and verify it uses _task for the pin
		local fn_start = src:find("local function wrapped_on_done", 1, true)
		helpers.assert_true(fn_start ~= nil, "wrapped_on_done not found")
		local region = src:sub(fn_start, fn_start + 200)
		helpers.assert_true(
			region:find("M._active_tasks[_task]", 1, true) ~= nil,
			"wrapped_on_done must release pin via M._active_tasks[_task], not M._active_tasks[task]"
		)
	end)

	helpers.it("_safe_terminate releases GC pin before terminating", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/adapters/shell_runner.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open shell_runner.lua")
		local src = fh:read("*a")
		fh:close()

		-- Find _safe_terminate and verify it clears the GC pin
		local fn_start = src:find("local function _safe_terminate", 1, true)
		helpers.assert_true(fn_start ~= nil, "_safe_terminate not found")
		local region = src:sub(fn_start, fn_start + 300)
		helpers.assert_true(
			region:find("M._active_tasks[_task]", 1, true) ~= nil,
			"_safe_terminate must remove M._active_tasks[_task] to prevent GC pin leak"
		)
	end)

	-- Behavioural regression for the streaming-supersede crash: terminate() nils the
	-- closure `_task`, then the OS delivers the SIGTERM completion callback. Without a
	-- nil guard, wrapped_on_done evaluates `M._active_tasks[nil] = nil` and raises
	-- "table index is nil" on every superseded/cancelled stream (seen on each LLM
	-- prediction in the field logs).
	helpers.it("wrapped_on_done tolerates a nil _task after terminate (no 'table index is nil')", function()
		local captured_done
		local ShellRunner = helpers.load_with_stubs("adapters.shell_runner", {
			task = {
				new = function(_exe, done_cb, _a3, _a4)
					captured_done = done_cb
					return { start = function() end, terminate = function() end }
				end,
			},
		})

		local handle = ShellRunner.spawn("/usr/bin/curl", { "-s", "-N" }, function() end)
		handle.start()
		handle.terminate()  -- supersede: clears the closure `_task`

		helpers.assert_true(type(captured_done) == "function",
			"the spawn wrapper must register a completion callback")
		-- The OS fires the completion callback for the terminated task AFTER _task was nilled.
		local ok = pcall(captured_done, 15, "", "")  -- 15 = SIGTERM
		helpers.assert_true(ok,
			"wrapped_on_done must not raise when _task was already cleared by terminate()")
	end)

	-- Regression: hs.task.new() RETURNS nil (it does not raise) when the launch
	-- path is not an executable file, so pcall reported ok == true with a nil task
	-- and spawn() ran `M._active_tasks[nil] = true` — a "table index is nil" throw
	-- that escaped spawn() entirely, past every pcall in the function.
	helpers.it("spawn() survives hs.task.new returning nil (no 'table index is nil')", function()
		local ShellRunner = helpers.load_with_stubs("adapters.shell_runner", {
			task = { new = function(_exe, _done_cb, _a3, _a4) return nil end },
		})

		local handle
		local ok, err = pcall(function()
			handle = ShellRunner.spawn("/nonexistent/binary", { "-x" }, function() end)
		end)
		helpers.assert_true(ok,
			"spawn() must not raise when hs.task.new returns nil for a non-executable path: " .. tostring(err))

		helpers.assert_true(ShellRunner._active_tasks[nil] == nil,
			"a nil task must never be pinned in _active_tasks")

		-- The handle must still honour its contract so callers need no nil checks.
		helpers.assert_true(type(handle) == "table", "spawn() must still return a handle")
		local ok_start = pcall(function() return handle.start() end)
		helpers.assert_true(ok_start, "handle.start() must be safe to call when no task was created")
		local ok_term = pcall(function() return handle.terminate() end)
		helpers.assert_true(ok_term, "handle.terminate() must be safe to call when no task was created")
	end)

	-- Regression (latch release): _safe_start logs a launch failure but never
	-- raises, so a consumer's pcall(handle.start) always reports success. Callers
	-- such as network_info latch an "in flight" flag before starting and need the
	-- return value to know the launch failed, or the flag stays set forever.
	helpers.it("handle.start() returns false when no task was created", function()
		local ShellRunner = helpers.load_with_stubs("adapters.shell_runner", {
			task = { new = function(_exe, _done_cb, _a3, _a4) return nil end },
		})

		local handle = ShellRunner.spawn("/nonexistent/binary", {}, function() end)
		helpers.assert_eq(false, handle.start(),
			"start() must report false so a caller can release its in-flight latch")
	end)

	helpers.it("handle.start() returns false when the task refuses to start", function()
		local ShellRunner = helpers.load_with_stubs("adapters.shell_runner", {
			task = {
				new = function(_exe, _done_cb, _a3, _a4)
					return {
						start     = function() error("launch refused by the OS") end,
						terminate = function() end,
					}
				end,
			},
		})

		local handle = ShellRunner.spawn("/usr/bin/curl", {}, function() end)
		helpers.assert_eq(false, handle.start(),
			"start() must report false when the underlying start throws")
	end)

	helpers.it("handle.start() returns true on a successful launch", function()
		local ShellRunner = helpers.load_with_stubs("adapters.shell_runner", {
			task = {
				new = function(_exe, _done_cb, _a3, _a4)
					return { start = function() end, terminate = function() end }
				end,
			},
		})

		local handle = ShellRunner.spawn("/bin/echo", { "hi" }, function() end)
		helpers.assert_eq(true, handle.start(),
			"start() must report true so a caller keeps its in-flight latch armed")
	end)

	helpers.it("normal completion releases the GC pin and forwards (exit, out, err)", function()
		local captured_done, fake_task
		local ShellRunner = helpers.load_with_stubs("adapters.shell_runner", {
			task = {
				new = function(_exe, done_cb, _a3, _a4)
					captured_done = done_cb
					fake_task = { start = function() end, terminate = function() end }
					return fake_task
				end,
			},
		})

		local seen = {}
		local handle = ShellRunner.spawn("/bin/echo", { "hi" }, function(code, out, err)
			seen.code, seen.out, seen.err = code, out, err
		end)
		handle.start()

		-- The task is pinned while running so the GC cannot kill it mid-flight.
		helpers.assert_true(ShellRunner._active_tasks[fake_task] == true,
			"a running task must be pinned in _active_tasks against premature GC")

		-- Normal (non-terminated) completion: pin released, callback forwarded verbatim.
		local ok = pcall(captured_done, 0, "hi\n", "")
		helpers.assert_true(ok, "completion callback must not raise on a normal exit")
		helpers.assert_true(ShellRunner._active_tasks[fake_task] == nil,
			"wrapped_on_done must release the GC pin once the subprocess exits")
		helpers.assert_eq(seen.code, 0)
		helpers.assert_eq(seen.out, "hi\n")
		helpers.assert_eq(seen.err, "")
	end)
end)
