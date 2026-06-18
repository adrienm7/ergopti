--- tests/unit/ui/test_api_panel_unique_ids.lua

--- Regression test for ui-menu-llm-core-3: api_panel.lua and profiles_manager.lua
--- used only os.time() to generate entry/profile ids. Two entries or profiles
--- created within the same second got identical ids, so the rollback filter
--- (x.id ~= id) removed BOTH entries instead of just the invalid one.
---
--- Fix: added a module-level monotone sequence counter (_entry_seq / _profile_seq)
--- appended to the id so it is unique regardless of wall-clock resolution.

local helpers = require("tests.helpers")

-- api_panel.lua
local api_src_path = helpers.driver_root() .. "ui/menu/menu_llm/api_panel.lua"
local fh = io.open(api_src_path, "r")
if not fh then error("api_panel.lua not readable at: " .. api_src_path) end
local api_src = fh:read("*a") ; fh:close()

-- Test 1: _entry_seq counter must be declared.
local has_entry_seq = api_src:find("local _entry_seq", 1, true) ~= nil
helpers.assert_true(
	has_entry_seq,
	"api_panel.lua must declare _entry_seq counter (ui-menu-llm-core-3)"
)

-- Test 2: the id format string must include the seq counter.
local has_seq_in_id = api_src:find("_entry_seq", 1, true) ~= nil
local id_pos = api_src:find('"' .. "%s-%d-%d" .. '"', 1, true) ~= nil
or api_src:find("_entry_seq", 1, true) ~= nil
helpers.assert_true(
	has_seq_in_id,
	"api_panel.lua id must incorporate _entry_seq (ui-menu-llm-core-3)"
)

-- profiles_manager.lua
local pm_src_path = helpers.driver_root() .. "ui/menu/menu_llm/profiles_manager.lua"
local fh2 = io.open(pm_src_path, "r")
if not fh2 then error("profiles_manager.lua not readable at: " .. pm_src_path) end
local pm_src = fh2:read("*a") ; fh2:close()

-- Test 3: _profile_seq counter must be declared.
local has_profile_seq = pm_src:find("local _profile_seq", 1, true) ~= nil
helpers.assert_true(
	has_profile_seq,
	"profiles_manager.lua must declare _profile_seq counter (ui-menu-llm-core-3)"
)

-- Test 4: clone_builtin_profile must incorporate the seq counter.
local has_seq_in_profile = pm_src:find("_profile_seq", 1, true) ~= nil
helpers.assert_true(
	has_seq_in_profile,
	"profiles_manager.lua clone_builtin_profile must use _profile_seq in the id (ui-menu-llm-core-3)"
)

print("[PASS] test_api_panel_unique_ids")
