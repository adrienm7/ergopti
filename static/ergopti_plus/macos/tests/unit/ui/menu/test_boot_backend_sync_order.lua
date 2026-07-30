--- tests/unit/ui/menu/test_boot_backend_sync_order.lua

--- ==============================================================================
--- MODULE: Boot LLM backend sync order (regression)
--- DESCRIPTION:
--- Locks the boot ordering that makes the MLX server usable at startup.
---
--- ROOT CAUSE ENCODED: sync_state_to_modules() pushes the persisted model into the
--- engine via set_llm_model / set_llm_enabled, each of which schedules a backend
--- warmup against whatever backend the core llm module currently holds. The LLM
--- handler only asserts the persisted backend later (menu_llm.start -> set_backend).
--- So when the core backend was still the default at sync time, an MLX user warmed
--- Ollama: the MLX server was launched but never primed (no endpoint discovery / no
--- warmup), and predictions only started after a manual model switch re-asserted the
--- backend. The fix calls core_llm.set_backend(state.llm_backend) AFTER
--- merge_saved_data() (state hydrated) and BEFORE sync_state_to_modules() so the
--- boot warmup targets the right backend.
---
--- This is a source-ordering assertion: the boot path runs at Hammerspoon startup
--- and is not exercised by the headless unit harness, so we pin the structural
--- invariant (set_backend sits between merge_saved_data and sync_state_to_modules).
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("boot: core backend is synced before the model is pushed to the engine", function()
	local function read_menu_init()
		-- Selected by a declaration unique to ui/menu/init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function safe_require")
		helpers.assert_true(src ~= nil, "ui/menu/init.lua source must be locatable")
		return src
	end

	helpers.it("calls set_backend between merge_saved_data() and sync_state_to_modules()", function()
		local src = read_menu_init()

		local merge_pos = src:find("Preferences.merge_saved_data(state, saved)", 1, true)
		helpers.assert_true(merge_pos ~= nil, "merge_saved_data call must be present")

		-- The boot backend sync: core_llm.set_backend(state.llm_backend).
		local set_backend_pos = src:find("set_backend, state.llm_backend", merge_pos, true)
		helpers.assert_true(set_backend_pos ~= nil,
			"boot must call core_llm.set_backend(state.llm_backend) so the warmup targets the persisted backend")

		-- Search AFTER merge so we hit the CALL, not the earlier function definition.
		local sync_pos = src:find("sync_state_to_modules(saved, config_absent)", merge_pos, true)
		helpers.assert_true(sync_pos ~= nil, "sync_state_to_modules call must be present")

		helpers.assert_true(merge_pos < set_backend_pos,
			"set_backend must run AFTER merge_saved_data so state.llm_backend is hydrated")
		helpers.assert_true(set_backend_pos < sync_pos,
			"set_backend must run BEFORE sync_state_to_modules so set_llm_model/warmup see the right backend")
	end)
end)

helpers.describe("set_llm_model resolves the backend at call time (not capture time)", function()
	-- Behavioural guard on the engine contract the boot fix relies on: set_llm_model
	-- must read core_llm.get_backend() when it runs, so asserting the backend before
	-- the model is pushed is what routes the warmup correctly.
	helpers.it("set_llm_model reads core_llm.get_backend() inside the function body", function()
		-- Selected by a declaration unique to modules/llm/prediction_engine.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function compute_adaptive_debounce")
		helpers.assert_true(src ~= nil, "modules/llm/prediction_engine.lua source must be locatable")

		local fn_start = src:find("function M.set_llm_model(model_name)", 1, true)
		helpers.assert_true(fn_start ~= nil, "set_llm_model must exist")
		local region = src:sub(fn_start, fn_start + 220)
		helpers.assert_true(region:find("core_llm.get_backend()", 1, true) ~= nil,
			"set_llm_model must resolve the backend via core_llm.get_backend() at call time")
	end)
end)
