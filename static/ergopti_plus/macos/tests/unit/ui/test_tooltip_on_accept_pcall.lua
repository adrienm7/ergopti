--- tests/unit/ui/test_tooltip_on_accept_pcall.lua

--- Regression test for ui-tooltip-1: every _state.on_accept() call site in
--- tooltip_llm.lua must be dispatched after the eventtap callback. The shared
--- SyntheticInput FIFO owns the xpcall/logger boundary; the behavioural proof
--- (including a throwing callback) lives in test_tooltip_action_epoch_guard.lua.
---
--- Pre-fix: acceptance ran inline and a callback that throws() propagated into
--- the eventtap infrastructure. Post-fix: every acceptance is nested inside a
--- `defer_runtime_action(...)` closure, whose retained FIFO isolates failures.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to ui/tooltip/tooltip_llm.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function refresh_chain_timing")
helpers.assert_true(src ~= nil, "ui/tooltip/tooltip_llm.lua source must be locatable")

local accept_calls = 0
local cursor = 1
while true do
	local accept_at = src:find("_state%.on_accept%(", cursor)
	if not accept_at then break end
	accept_calls = accept_calls + 1
	local context_start = math.max(1, accept_at - 260)
	local context = src:sub(context_start, accept_at)
	helpers.assert_true(
		context:find("defer_runtime_action%(") ~= nil and context:find("function%(%)") ~= nil,
		"every on_accept invocation must be nested in a deferred runtime action"
	)
	cursor = accept_at + 1
end

helpers.assert_eq(accept_calls, 4,
	"Tab, both Enter modes, and numbered acceptance must all use the deferred boundary")

local adapter_src = helpers.read_driver_source("local function drain_deferred_lifecycle")
helpers.assert_true(adapter_src ~= nil, "adapters/synthetic_input.lua source must be locatable")
helpers.assert_true(adapter_src:find("run_logged%(call%.label, call%.callback") ~= nil,
	"the deferred FIFO must keep its shared xpcall/logger boundary")

print("[PASS] test_tooltip_on_accept_pcall")
