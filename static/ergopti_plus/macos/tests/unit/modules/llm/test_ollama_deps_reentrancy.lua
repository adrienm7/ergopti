--- tests/unit/modules/llm/test_ollama_deps_reentrancy.lua

--- Regression test for lib-deps-1: check_and_install_deps() had no reentrancy
--- guard. Calling it while a task was already running created a second
--- concurrent hs.task — two bootstrap scripts running simultaneously,
--- potentially corrupting shared install state.
---
--- Fix: a module-level _task_running flag guards the entry point. A second
--- call while a task is live is silently ignored.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to modules/llm/ollama_deps_checker.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function resolve_project_root")
helpers.assert_true(src ~= nil, "modules/llm/ollama_deps_checker.lua source must be locatable")

-- Test 1: reentrancy flag declared at module level.
local flag_pos = src:find("local _task_running", 1, true)
helpers.assert_true(
	flag_pos ~= nil,
	"ollama_deps_checker.lua must declare _task_running at module level (lib-deps-1)"
)

-- Test 2: guard at entry point of check_and_install_deps().
local guard_pos = src:find("if _task_running then", 1, true)
helpers.assert_true(
	guard_pos ~= nil,
	"ollama_deps_checker.lua must have 'if _task_running then' reentrancy guard (lib-deps-1)"
)

-- Test 3: flag is set to true before task:start() and cleared in the callback.
local set_true = src:find("_task_running = true", 1, true)
local set_false = src:find("_task_running = false", 1, true)
helpers.assert_true(
	set_true ~= nil,
	"ollama_deps_checker.lua must set _task_running = true before starting the task (lib-deps-1)"
)
helpers.assert_true(
	set_false ~= nil,
	"ollama_deps_checker.lua must set _task_running = false in the task completion callback (lib-deps-1)"
)

print("[PASS] test_ollama_deps_reentrancy")
