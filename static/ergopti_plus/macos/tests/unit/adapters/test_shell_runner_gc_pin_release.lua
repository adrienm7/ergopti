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
--- F35 originally treated a successful SIGTERM request as process settlement
--- and released the GC pin immediately. Hammerspoon documents terminate() as
--- signal-only; releasing before on_done loses the sole native-exit capability.
---
--- Fix (2026-06-19): changed wrapped_on_done signature to (exit_code, stdout,
---     stderr) and used the closure upvalue '_task' for pin release;
---     native task and pin now remain owned until wrapped_on_done observes exit.
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

	helpers.it("wrapped_on_done captures and releases the exact closure task", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/adapters/shell_runner.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open shell_runner.lua")
		local src = fh:read("*a")
		fh:close()

		-- Capture the closure task before clearing the mutable upvalue. The callback's
		-- first argument is only an exit code, never the native task object.
		local fn_start = src:find("local function wrapped_on_done", 1, true)
		helpers.assert_true(fn_start ~= nil, "wrapped_on_done not found")
		local region = src:sub(fn_start, fn_start + 500)
		helpers.assert_true(
			region:find("local completed_task = _task", 1, true) ~= nil
				and region:find("M._active_tasks[completed_task]", 1, true) ~= nil,
			"wrapped_on_done must release the exact task captured from its closure"
		)
	end)

	helpers.it("_safe_terminate retains the exact task until native termination succeeds", function()
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
		local region = src:sub(fn_start, fn_start + 1200)
		helpers.assert_true(
			region:find("local task = _task", 1, true) ~= nil
				and region:find("M._active_tasks[task]", 1, true) ~= nil,
			"_safe_terminate must retain and then release the exact captured task"
		)
	end)

	helpers.it("terminate failure and accepted SIGTERM keep the task pinned until completion", function()
		local attempts = 0
		local fake_task, captured_done
		local ShellRunner = helpers.load_with_stubs("adapters.shell_runner", {
			task = {
				new = function(_exe, done_cb)
					captured_done = done_cb
					fake_task = {
						start = function(self) return self end,
						terminate = function(self)
							attempts = attempts + 1
							if attempts == 1 then error("synthetic terminate failure") end
							return self
						end,
					}
					return fake_task
				end,
			},
		})

		local handle = ShellRunner.spawn("/usr/bin/defaults", {}, function() end)
		helpers.assert_true(handle.start())
		helpers.assert_eq(handle.terminate(), false,
			"a native exception must not be reported as settled")
		helpers.assert_true(ShellRunner._active_tasks[fake_task] == true,
			"the exact retry capability must remain GC-pinned after failure")
		local accepted, state = handle.terminate()
		helpers.assert_eq(accepted, true,
			"the compatibility boolean reports that SIGTERM was accepted")
		helpers.assert_eq(state, "pending")
		helpers.assert_eq(attempts, 2)
		helpers.assert_true(ShellRunner._active_tasks[fake_task] == true,
			"an accepted signal must retain the exact native-exit capability")
		captured_done(15, "", "")
		helpers.assert_nil(ShellRunner._active_tasks[fake_task])
		helpers.assert_eq(handle.terminate(), true,
			"only the completion callback settles termination ownership")
	end)

	-- Behavioural regression for the signal-versus-settlement race. The process
	-- may continue after terminate() returns, so the native handle must remain
	-- pinned and its eventual completion must be the only release boundary.
	helpers.it("accepted termination retains the exact task until native completion", function()
		local captured_done, fake_task
		local ShellRunner = helpers.load_with_stubs("adapters.shell_runner", {
			task = {
				new = function(_exe, done_cb, _a3, _a4)
					captured_done = done_cb
					fake_task = {
						start = function(self) return self end,
						terminate = function(self) return self end,
					}
					return fake_task
				end,
			},
		})

		local handle = ShellRunner.spawn("/usr/bin/curl", { "-s", "-N" }, function() end)
		helpers.assert_true(handle.start(), "the fake task must reach the live state")
		helpers.assert_true(ShellRunner._active_tasks[fake_task] == true,
			"the live task must be pinned before termination")
		local accepted, state = handle.terminate()
		helpers.assert_eq(accepted, true,
			"a live caller must not mistake an accepted SIGTERM for cancellation failure")
		helpers.assert_eq(state, "pending")
		helpers.assert_true(ShellRunner._active_tasks[fake_task] == true,
			"SIGTERM acceptance must not be laundered into native exit")

		helpers.assert_true(type(captured_done) == "function",
			"the spawn wrapper must register a completion callback")
		-- The OS fires the completion callback only after the terminated task exits.
		captured_done(15, "", "")  -- 15 = SIGTERM
		helpers.assert_nil(ShellRunner._active_tasks[fake_task],
			"a completion arriving after terminate() must still RELEASE the pin — a task "
				.. "left pinned is never collected, and the process holds its pipes for the "
				.. "rest of the session")
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
		helpers.assert_true(ok, "spawn() must not raise when hs.task.new returns nil: " .. tostring(err))
		helpers.assert_nil(err, "and must report no error")

		helpers.assert_true(ShellRunner._active_tasks[nil] == nil,
			"a nil task must never be pinned in _active_tasks")

		-- The handle must still honour its contract so callers need no nil checks.
		helpers.assert_true(type(handle) == "table", "spawn() must still return a handle")
		-- Called directly: a raise fails with the real error. What the contract
		-- promises is that the handle stays USABLE, so callers need no nil checks —
		-- that is observable as both methods still being there afterwards.
		handle.start()
		handle.terminate()
		helpers.assert_eq(type(handle.start), "function",
			"handle.start() must survive being called when no task was created")
		helpers.assert_eq(type(handle.terminate), "function",
			"and terminate() likewise")
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
		-- The stub models the REAL hs.task:start(), which returns the task object on
		-- success. It previously returned nil, which quietly required the
		-- implementation to IGNORE the return value — cementing the very defect the
		-- case below now covers.
		local ShellRunner = helpers.load_with_stubs("adapters.shell_runner", {
			task = {
				new = function(_exe, _done_cb, _a3, _a4)
					local task = { terminate = function() end }
					task.start = function(self) return self end
					return task
				end,
			},
		})

		local handle = ShellRunner.spawn("/bin/echo", { "hi" }, function() end)
		helpers.assert_eq(true, handle.start(),
			"start() must report true so a caller keeps its in-flight latch armed")
	end)

	-- Regression: hs.task:start() reports a refused launch by RETURNING false, not
	-- by raising. _safe_start wrapped it in `pcall(function() _task:start() end)` —
	-- a closure with no `return` — so the value was discarded and only a raise could
	-- be detected. The most common real failure (missing or non-executable binary)
	-- therefore reported SUCCESS, and callers such as network_info kept their
	-- in-flight latch armed for the process lifetime.
	helpers.it("handle.start() returns false when start() returns false without raising", function()
		local ShellRunner = helpers.load_with_stubs("adapters.shell_runner", {
			task = {
				new = function(_exe, _done_cb, _a3, _a4)
					return { start = function() return false end, terminate = function() end }
				end,
			},
		})

		local handle = ShellRunner.spawn("/usr/bin/curl", {}, function() end)
		helpers.assert_eq(false, handle.start(),
			"start() must report false when hs.task:start() returns false — it does not raise "
			.. "on a refused launch, so a pcall that only catches a throw sees success")
	end)

	helpers.it("normal completion releases the GC pin and forwards (exit, out, err)", function()
		local captured_done, fake_task
		local ShellRunner = helpers.load_with_stubs("adapters.shell_runner", {
			task = {
				new = function(_exe, done_cb, _a3, _a4)
					captured_done = done_cb
					-- start() returns TRUE, as the real hs.task does. A stub returning nil
					-- makes a refused launch indistinguishable from a successful one, and
					-- this file's own history records that shape cementing the defect its
					-- test claimed to lock.
					fake_task = { start = function() return true end, terminate = function() end }
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
		-- Called directly — a raise here should fail with its own error.
		captured_done(0, "hi\n", "")
		helpers.assert_true(ShellRunner._active_tasks[fake_task] == nil,
			"wrapped_on_done must release the GC pin once the subprocess exits")
		helpers.assert_eq(seen.code, 0)
		helpers.assert_eq(seen.out, "hi\n")
		helpers.assert_eq(seen.err, "")
	end)
end)




-- ==================================================================
-- ==================================================================
-- ======= A refused launch must not leak its GC pin ================
-- ==================================================================
-- ==================================================================

--- The pin is taken at construction so the task cannot be collected mid-run, and
--- released by the completion callback. That callback never fires for a task
--- that never launched, so every refused launch left a dead hs.task and its
--- captured closures in _active_tasks for the life of the process — and that
--- table is the one GC root nothing ever prunes.
helpers.describe("ShellRunner: a task that refuses to launch is unpinned", function()

	helpers.it("releases the pin when start() returns false", function()
		local fake_task
		local ShellRunner = helpers.load_with_stubs("adapters.shell_runner", {
			task = {
				new = function(_bin, _done, _stream)
					fake_task = { start = function() return false end, terminate = function() end }
					return fake_task
				end,
			},
		})

		local handle = ShellRunner.spawn("/nonexistent/binary", {}, function() end)
		local started = handle.start()

		helpers.assert_true(started == false, "a refused launch must be reported to the caller")
		helpers.assert_true(ShellRunner._active_tasks[fake_task] == nil,
			"the completion callback that normally releases the pin never fires for a task "
			.. "that never ran, so the release has to happen on the failure path itself")
	end)

end)
