--- tests/unit/ui/test_api_panel_add_gen_guard.lua

--- Regression test for ui-menu-llm-core-4: api_panel.lua add-entry callbacks
--- had no generation guard. If entry A's check_availability probe was slow
--- and the user selected a different entry B while it was in flight, A's
--- on_missing callback would unconditionally revert the active selection back
--- to previous_active_id, clobbering the user's choice of B.
---
--- Fix: every entry mutation advances the same generation. Validation and
--- persistence callbacks bail out when another menu action supersedes them.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to ui/menu/menu_llm/api_panel.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("function M.build_model_picker")
helpers.assert_true(src ~= nil, "ui/menu/menu_llm/api_panel.lua source must be locatable")

-- Test 1: _add_gen counter must be declared.
local has_add_gen = src:find("local _add_gen", 1, true) ~= nil
helpers.assert_true(
	has_add_gen,
	"api_panel.lua must declare _add_gen generation counter (ui-menu-llm-core-4)"
)

-- Test 2: my_add_gen must be captured and the counter bumped before the probe.
local has_my_gen = src:find("local my_add_gen = begin_mutation()", 1, true) ~= nil
helpers.assert_true(
	has_my_gen,
	"api_panel.lua must acquire the mutation lease before check_availability (ui-menu-llm-core-4)"
)

-- Test 3: on_missing callback must check my_add_gen before reverting.
local on_missing_pos = src:find("function(_unreachable)", 1, true)
helpers.assert_true(on_missing_pos ~= nil, "api_panel.lua must define on_missing callback (ui-menu-llm-core-4)")
local on_missing_body = src:sub(on_missing_pos, on_missing_pos + 1000)
local has_gen_check = on_missing_body:find("mutation_is_current(my_add_gen)", 1, true) ~= nil
helpers.assert_true(
	has_gen_check,
	"on_missing callback must own the live mutation lease before rollback (ui-menu-llm-core-4)"
)

-- Test 4: every sibling identity mutation must invalidate the add callback,
-- not only the next Add action. Five increments cover list selection, add,
-- delete, No Model, and picker selection across both menu surfaces.
local mutation_count = 0
for _ in src:gmatch("begin_mutation%(%s*%)") do mutation_count = mutation_count + 1 end
helpers.assert_true(mutation_count >= 5,
	"every remote-entry mutation must acquire the shared async lease; found "
		.. tostring(mutation_count))

-- Test 5: durable persistence completion is itself generation-fenced before
-- warmup, success notification, or menu publication.
local persist_pos = src:find('persist_entries("persist_api_entries(add_entry_ok)"', 1, true)
helpers.assert_true(persist_pos ~= nil, "validated Add must enter callback-based persistence")
local persist_body = src:sub(persist_pos, persist_pos + 1500)
helpers.assert_true(persist_body:find("mutation_is_current(my_add_gen)", 1, true) ~= nil,
	"Add persistence callback must discard a superseded completion")

helpers.assert_true(src:find("if _mutation_owner ~= nil then return false end", 1, true) ~= nil,
	"captured actions must reject re-entry even when their old row was enabled")

print("[PASS] test_api_panel_add_gen_guard")
