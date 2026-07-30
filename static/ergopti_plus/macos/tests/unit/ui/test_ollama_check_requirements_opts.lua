--- tests/unit/ui/test_ollama_check_requirements_opts.lua

--- Regression test for ui-menu-llm-models-3: models_manager_ollama.lua
--- check_requirements() signature was (target_model, on_success, on_cancel)
--- without an `opts` parameter. The shared models_manager.lua dispatcher and
--- callers in init.lua pass a fourth argument `{ silent_notifications = true }`
--- which was silently dropped, causing model-repair toasts to always fire even
--- when the caller explicitly requested silence.
---
--- Fix: added `opts` as a fourth parameter and propagated `silent_notifications`
--- to the repair toast call.

local helpers = require("tests.helpers")

-- Selected by a declaration unique to ui/menu/menu_llm/models_manager_ollama.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function get_ollama_path")
helpers.assert_true(src ~= nil, "ui/menu/menu_llm/models_manager_ollama.lua source must be locatable")

-- Locate the check_requirements function.
local fn_start = src:find("function obj.check_requirements", 1, true)
helpers.assert_true(
	fn_start ~= nil,
	"models_manager_ollama.lua must define check_requirements (ui-menu-llm-models-3)"
)
local fn_sig = src:sub(fn_start, fn_start + 100)

-- Test 1: The function must accept a fourth `opts` parameter.
local has_opts = fn_sig:find("opts", 1, true) ~= nil
helpers.assert_true(
	has_opts,
	"models_manager_ollama.lua check_requirements must accept an opts parameter (ui-menu-llm-models-3)"
)

-- Test 2: silent_notifications must be read from opts inside the function body.
local fn_body = src:sub(fn_start, fn_start + 3000)
local has_silent_read = fn_body:find("silent_notifications", 1, true) ~= nil
helpers.assert_true(
	has_silent_read,
	"models_manager_ollama.lua check_requirements must read opts.silent_notifications (ui-menu-llm-models-3)"
)

-- Test 3: The repair toast must be guarded by the silent flag.
local has_silent_guard = fn_body:find("if not silent then", 1, true) ~= nil
helpers.assert_true(
	has_silent_guard,
	"models_manager_ollama.lua check_requirements must guard the repair toast with 'if not silent then' (ui-menu-llm-models-3)"
)

print("[PASS] test_ollama_check_requirements_opts")
