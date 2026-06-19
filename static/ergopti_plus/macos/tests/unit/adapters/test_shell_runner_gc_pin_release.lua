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
end)
