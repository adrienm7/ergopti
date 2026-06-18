--- tests/unit/ui/menu/menu_llm/test_models_manager_abort_leak.lua

--- Regression test for ui-menu-llm-models-1: when the user aborts a download
--- and then launches a new one, the stale download_aborted flag was not cleared,
--- silently making all update_icon() calls in the new download no-ops (the
--- menubar remained frozen in the aborted state).
---
--- Fix: clear_download_abort() is called before do_download() inside
--- shared_system_check so every new download starts with a clean abort state.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "ui/menu/menu_llm/models_manager.lua"
local fh = io.open(src_path, "r")
if not fh then error("models_manager.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: clear_download_abort is called before do_download() in the
-- shared_system_check download path.
-- We detect this by asserting that clear_download_abort appears somewhere
-- BEFORE `do_download()` in the source (both appear once in this block).
local clear_pos = src:find("clear_download_abort", 1, true)
local do_pos    = src:find("do_download()", 1, true)

helpers.assert_true(
	clear_pos ~= nil,
	"models_manager.lua must reference clear_download_abort (ui-menu-llm-models-1)"
)
helpers.assert_true(
	do_pos ~= nil,
	"models_manager.lua must contain a do_download() call (expected download path)"
)
helpers.assert_true(
	clear_pos < do_pos,
	"clear_download_abort must appear before do_download() in models_manager.lua"
		.. " (pre-fix: stale abort flag not cleared before new download)"
)

-- Test 2: the pattern is a guarded call (type-check before pcall), not bare.
local guarded = src:find('type(deps.clear_download_abort) == "function"', 1, true) ~= nil
helpers.assert_true(
	guarded,
	"models_manager.lua must guard clear_download_abort with a type-check (ui-menu-llm-models-1)"
)

print("[PASS] test_models_manager_abort_leak")
