--- tests/unit/ui/test_model_switcher_refuse_profile.lua

--- Regression test for ui-menu-llm-core-5: apply_recommended_prompt_profile()
--- refuse-branch called `state.llm_active_profile = cur_profile` followed by
--- `llm_mod.set_active_profile(cur_profile)` without calling save_prefs() or
--- update_menu(). Since the profile was already cur_profile, the setter was
--- redundant, but calling it without persisting left LLM internal state
--- (profile parameters loaded by set_active_profile) out of sync with what
--- was on disk.
---
--- Fix: removed the redundant setter call in the refuse-branch. The profile
--- did not change, so no setter, save, or menu update is needed.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/menu/menu_llm/model_switcher.lua"
local fh = io.open(src_path, "r")
if not fh then error("model_switcher.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Locate the refuse branch by finding "Profile kept at" log message.
local refuse_pos = src:find("Profile kept at", 1, true)
helpers.assert_true(
	refuse_pos ~= nil,
	"model_switcher.lua must contain the 'Profile kept at' log (ui-menu-llm-core-5)"
)

-- Extract a window around the refuse branch.
local refuse_block = src:sub(refuse_pos - 50, refuse_pos + 200)

-- Test 1: The redundant set_active_profile(cur_profile) must not appear in the refuse block.
local has_redundant_setter = refuse_block:find("set_active_profile(cur_profile)", 1, true) ~= nil
helpers.assert_true(
	not has_redundant_setter,
	"model_switcher.lua refuse-branch must not call set_active_profile(cur_profile) (ui-menu-llm-core-5)"
)

-- Test 2: save_prefs() must not be called in the refuse block either (profile unchanged).
local has_save_in_refuse = refuse_block:find("save_prefs()", 1, true) ~= nil
helpers.assert_true(
	not has_save_in_refuse,
	"model_switcher.lua refuse-branch must not call save_prefs() — profile unchanged (ui-menu-llm-core-5)"
)

-- Test 3: The accept-branch must still call save_prefs() and update_menu().
local accept_pos = src:find("Profile changed to", 1, true)
helpers.assert_true(accept_pos ~= nil, "model_switcher.lua must contain the 'Profile changed to' accept log (ui-menu-llm-core-5)")
local accept_block = src:sub(accept_pos, accept_pos + 200)
local has_save = accept_block:find("save_prefs()", 1, true) ~= nil
local has_menu = accept_block:find("update_menu()", 1, true) ~= nil
helpers.assert_true(
	has_save and has_menu,
	"model_switcher.lua accept-branch must still call save_prefs() and update_menu() (ui-menu-llm-core-5)"
)

print("[PASS] test_model_switcher_refuse_profile")
