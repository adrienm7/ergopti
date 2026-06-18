--- tests/unit/ui/test_api_panel_add_gen_guard.lua

--- Regression test for ui-menu-llm-core-4: api_panel.lua add-entry callbacks
--- had no generation guard. If entry A's check_availability probe was slow
--- and the user selected a different entry B while it was in flight, A's
--- on_missing callback would unconditionally revert the active selection back
--- to previous_active_id, clobbering the user's choice of B.
---
--- Fix: added _add_gen counter, captured as my_add_gen before each probe.
--- Both on_ok and on_missing bail out when my_add_gen ~= _add_gen.
--- The rollback only calls set_active_entry_id(previous_active_id) when the
--- current active id is still the entry being rolled back.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/menu/menu_llm/api_panel.lua"
local fh = io.open(src_path, "r")
if not fh then error("api_panel.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: _add_gen counter must be declared.
local has_add_gen = src:find("local _add_gen", 1, true) ~= nil
helpers.assert_true(
	has_add_gen,
	"api_panel.lua must declare _add_gen generation counter (ui-menu-llm-core-4)"
)

-- Test 2: my_add_gen must be captured and the counter bumped before the probe.
local has_my_gen = src:find("local my_add_gen = _add_gen", 1, true) ~= nil
helpers.assert_true(
	has_my_gen,
	"api_panel.lua must capture local my_add_gen = _add_gen before check_availability (ui-menu-llm-core-4)"
)

-- Test 3: on_missing callback must check my_add_gen before reverting.
local on_missing_pos = src:find("function(_unreachable)", 1, true)
helpers.assert_true(on_missing_pos ~= nil, "api_panel.lua must define on_missing callback (ui-menu-llm-core-4)")
local on_missing_body = src:sub(on_missing_pos, on_missing_pos + 1000)
local has_gen_check = on_missing_body:find("my_add_gen ~= _add_gen", 1, true) ~= nil
helpers.assert_true(
	has_gen_check,
	"on_missing callback must guard on my_add_gen ~= _add_gen (ui-menu-llm-core-4)"
)

-- Test 4: rollback must only revert active id when it is still the staged entry.
local has_cur_id_check = on_missing_body:find("cur_id == id", 1, true) ~= nil
helpers.assert_true(
	has_cur_id_check,
	"rollback must only call set_active_entry_id when cur_id == id (ui-menu-llm-core-4)"
)

print("[PASS] test_api_panel_add_gen_guard")
