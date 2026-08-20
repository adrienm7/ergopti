--- tests/unit/modules/llm/test_mlx_deps_reentrancy_nil_cb.lua

--- ==============================================================================
--- MODULE: Regression — mlx_deps_checker reentrancy guard with nil callback
--- DESCRIPTION:
--- Guards against the bug where the reentrancy guard in ensure_bootstrap()
--- used `#_pending_callbacks > 0` to detect a running task. When on_complete
--- is nil (most internal callers), no entry is added to the queue, so the
--- guard never fired — allowing two concurrent bootstrap processes to race
--- and both write the same .venv directory.
---
--- Fix (2026-06-19): added `_task_running` boolean, set to true before
--- task:start() and cleared in fire_pending_callbacks(), so nil-callback
--- callers are also blocked by the reentrancy guard.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================================================
-- ===========================================================================
-- ======= 1/ Reentrancy guard activates even for nil-callback callers =======
-- ===========================================================================
-- ===========================================================================

helpers.describe("mlx_deps_checker: reentrancy guard with nil callback", function()
	helpers.it("source uses _task_running boolean guard, not #_pending_callbacks", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/modules/llm/mlx_deps_checker.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open mlx_deps_checker.lua at: " .. src_file)
		local src = fh:read("*a")
		fh:close()

		-- The guard must use _task_running, not #_pending_callbacks
		helpers.assert_true(
			src:find("_task_running", 1, true) ~= nil,
			"mlx_deps_checker must declare _task_running boolean"
		)
		helpers.assert_true(
			src:find("if _task_running then", 1, true) ~= nil,
			"reentrancy guard must check 'if _task_running then'"
		)

		-- Must NOT use #_pending_callbacks as the primary guard
		-- (it is still allowed for other uses, but not as the if-guard)
		local guard_pos = src:find("if _task_running then", 1, true)
		local old_guard_pos = src:find("if #_pending_callbacks > 0 then", 1, true)
		helpers.assert_true(
			old_guard_pos == nil,
			"old guard 'if #_pending_callbacks > 0' must be replaced by '_task_running'"
		)
		helpers.assert_true(guard_pos ~= nil, "_task_running guard position must be found")
	end)

	helpers.it("_task_running is set before task:start() and cleared in fire_pending_callbacks", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local base = src_path:match("^(.+)[/\\]tests[/\\]") or ""
		local src_file = base .. "/modules/llm/mlx_deps_checker.lua"

		local fh = io.open(src_file, "r")
		helpers.assert_true(fh ~= nil, "Cannot open mlx_deps_checker.lua")
		local src = fh:read("*a")
		fh:close()

		-- _task_running = true must appear before the strict native-start call
		local set_true_pos   = src:find("_task_running = true", 1, true)
		local task_start_pos = src:find("TaskLifecycle.start(task, \"MLX dependency bootstrap\")", 1, true)
		helpers.assert_true(set_true_pos ~= nil, "_task_running = true must be set before task:start()")
		helpers.assert_true(task_start_pos ~= nil,
			"the strict TaskLifecycle start contract must exist in source")
		helpers.assert_true(
			set_true_pos < task_start_pos,
			"_task_running = true must appear before the strict native-start call"
		)

		-- _task_running = false must appear inside fire_pending_callbacks body
		-- (not just as the initial `local _task_running = false` declaration)
		local fire_pos = src:find("local function fire_pending_callbacks", 1, true)
		helpers.assert_true(fire_pos ~= nil, "fire_pending_callbacks must exist in source")
		local after_fire = src:sub(fire_pos)
		local clear_in_body = after_fire:find("_task_running = false", 1, true)
		helpers.assert_true(
			clear_in_body ~= nil,
			"_task_running = false must appear in the body of fire_pending_callbacks"
		)
	end)
end)
