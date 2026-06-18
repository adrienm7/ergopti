--- tests/unit/modules/llm/test_warmup_single_chain.lua

--- Regression test for llm-api-support-2: warmup_controller.lua
--- schedule_warmup_with_retry() had no generation guard. Calling it twice
--- before the backend became ready launched two concurrent, non-cancellable
--- retry chains. Both chains would keep firing warmup_model() indefinitely.
---
--- Fix: added a module-level _warmup_gen counter. Each call bumps the counter
--- and captures my_gen; try_warmup() bails out immediately when my_gen !=
--- _warmup_gen, ensuring only the latest chain is active.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "modules/llm/warmup_controller.lua"
local fh = io.open(src_path, "r")
if not fh then error("warmup_controller.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: _warmup_gen state variable must exist.
local has_gen = src:find("local _warmup_gen", 1, true) ~= nil
helpers.assert_true(
	has_gen,
	"warmup_controller.lua must declare _warmup_gen generation counter (llm-api-support-2)"
)

-- Test 2: schedule_warmup_with_retry must bump the counter before spawning.
local sched_pos = src:find("function M.schedule_warmup_with_retry", 1, true)
helpers.assert_true(sched_pos ~= nil, "schedule_warmup_with_retry must be defined (llm-api-support-2)")
local sched_body = src:sub(sched_pos, sched_pos + 2000)
local has_bump = sched_body:find("_warmup_gen = _warmup_gen + 1", 1, true) ~= nil
helpers.assert_true(
	has_bump,
	"schedule_warmup_with_retry must increment _warmup_gen before spawning (llm-api-support-2)"
)

-- Test 3: try_warmup must guard on my_gen != _warmup_gen.
local has_gen_check = sched_body:find("my_gen ~= _warmup_gen", 1, true) ~= nil
helpers.assert_true(
	has_gen_check,
	"try_warmup closure must check my_gen ~= _warmup_gen (llm-api-support-2)"
)

-- Test 4: M.stop() must exist and bump the counter.
local stop_pos = src:find("function M.stop()", 1, true)
helpers.assert_true(
	stop_pos ~= nil,
	"warmup_controller.lua must expose M.stop() (llm-api-support-2)"
)
local stop_body = src:sub(stop_pos, stop_pos + 200)
local has_stop_bump = stop_body:find("_warmup_gen = _warmup_gen + 1", 1, true) ~= nil
helpers.assert_true(
	has_stop_bump,
	"M.stop() must increment _warmup_gen to cancel the active chain (llm-api-support-2)"
)

print("[PASS] test_warmup_single_chain")
