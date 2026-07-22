--- tests/unit/ui/test_tooltip_on_accept_pcall.lua

--- Regression test for ui-tooltip-1: every _state.on_accept() call site in
--- tooltip_llm.lua must be guarded with pcall so a throwing callback cannot
--- propagate errors out of the eventtap keyDown handler.
---
--- Pre-fix: four bare `_state.on_accept(_state.current_index)` (and one
--- `_state.on_accept(pred_index)`) calls. A callback that throws() would
--- propagate the error to the eventtap infrastructure and crash the watcher.
--- Post-fix: all call sites wrapped in pcall(_state.on_accept, ...) with an
--- explicit Logger.error on failure.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/tooltip/tooltip_llm.lua"
local fh = io.open(src_path, "r")
if not fh then error("tooltip_llm.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: no bare _state.on_accept( invocations (lines without pcall on same line).
-- The state declaration `on_accept = nil` does not contain `on_accept(` so it
-- is not matched. Only invocations (with `(`) trigger the check.
local bare_calls = 0
for line in src:gmatch("[^\n]+") do
	if line:find("_state%.on_accept%(", 1, false) then
		if not line:find("pcall%(", 1, false) then
			bare_calls = bare_calls + 1
		end
	end
end

helpers.assert_true(
	bare_calls == 0,
	"tooltip_llm.lua has " .. bare_calls
		.. " bare _state.on_accept(...) call(s) not wrapped in pcall — ui-tooltip-1 regression"
)

-- Test 2: at least 4 pcall-guarded call sites (Tab, Enter, Enter-nav, hotkey-number).
local pcall_count = 0
for _ in src:gmatch("pcall%(_state%.on_accept,") do pcall_count = pcall_count + 1 end

helpers.assert_true(
	pcall_count >= 4,
	"tooltip_llm.lua must have at least 4 pcall(_state.on_accept, ...) sites, found: " .. pcall_count
)

print("[PASS] test_tooltip_on_accept_pcall")
