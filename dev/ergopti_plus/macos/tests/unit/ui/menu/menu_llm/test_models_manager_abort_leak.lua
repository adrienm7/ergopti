--- tests/unit/ui/menu/menu_llm/test_models_manager_abort_leak.lua

--- Regression test for ui-menu-llm-models-1: when the user aborts a download
--- and then launches a new one, the stale download_aborted flag was not cleared,
--- silently making all update_icon() calls in the new download no-ops (the
--- menubar remained frozen in the aborted state).
---
--- Fix: clear_download_abort() is called before do_download() inside
--- shared_system_check so every new download starts with a clean abort state.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to ui/menu/menu_llm/models_manager.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function get_actual_model_name")
helpers.assert_true(src ~= nil, "ui/menu/menu_llm/models_manager.lua source must be locatable")

-- Test 1: clear_download_abort is called before the contextual do_download
-- callback dispatch in the shared_system_check download path.
-- We detect this by asserting that clear_download_abort appears somewhere
-- BEFORE the uniquely labelled callback boundary in the source.
local clear_pos = src:find("clear_download_abort", 1, true)
local do_pos    = src:find('"Approved model download", do_download', 1, true)

helpers.assert_true(
	clear_pos ~= nil,
	"models_manager.lua must reference clear_download_abort (ui-menu-llm-models-1)"
)
helpers.assert_true(
	do_pos ~= nil,
	"models_manager.lua must dispatch do_download through the contextual callback boundary"
)
helpers.assert_true(
	clear_pos < do_pos,
	"clear_download_abort must appear before the do_download dispatch in models_manager.lua"
		.. " (pre-fix: stale abort flag not cleared before new download)"
)

-- Test 2: the pattern is a guarded call (type-check before pcall), not bare.
local guarded = src:find('type(deps.clear_download_abort) == "function"', 1, true) ~= nil
helpers.assert_true(
	guarded,
	"models_manager.lua must guard clear_download_abort with a type-check (ui-menu-llm-models-1)"
)

print("[PASS] test_models_manager_abort_leak")
