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
--- task:start() and cleared only after the exact native terminal callback, so
--- nil-callback callers and pending termination debt remain blocked.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================================================
-- ===========================================================================
-- ======= 1/ Reentrancy guard activates even for nil-callback callers =======
-- ===========================================================================
-- ===========================================================================

helpers.describe("mlx_deps_checker: reentrancy guard with nil callback", function()
	helpers.it("source uses _task_running boolean guard, not #_pending_callbacks", function()
		local src = helpers.read_driver_source(
			"owner_name = \"mlx_dependency_bootstrap\"")
		helpers.assert_not_nil(src)

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

	helpers.it("clears _task_running only from exact task settlement", function()
		local src = helpers.read_driver_source(
			"owner_name = \"mlx_dependency_bootstrap\"")
		helpers.assert_not_nil(src)

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

		local release_pos = src:find("local function release_task_owner", 1, true)
		helpers.assert_true(release_pos ~= nil)
		local release_body = src:sub(release_pos, release_pos + 700)
		helpers.assert_true(release_body:find("_task_running = false", 1, true) ~= nil,
			"only the first exact native terminal delivery may clear the guard")
		local fire_pos = src:find("fire_pending_callbacks = function", 1, true)
		helpers.assert_true(fire_pos ~= nil)
		local fire_body = src:sub(fire_pos, fire_pos + 350)
		helpers.assert_true(fire_body:find("_task_running = false", 1, true) == nil,
			"business callback fan-out is not native task settlement")
	end)
end)
