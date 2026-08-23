--- tests/unit/ui/menu/menu_llm/test_warmup_controller_runtime_gate.lua

--- ==============================================================================
--- MODULE: Regression — WarmupCtrl.warmup/warmup_model gated on runtime enable (M-12)
--- DESCRIPTION:
--- WarmupCtrl.warmup and WarmupCtrl.warmup_model called llm_mod.warmup_model
--- unconditionally. Backend and API panel actions in the menu are reachable while
--- the LLM feature is off (the greying policy keeps them clickable for pre-config).
--- Clicking "API backend" with LLM off triggered a paid remote POST via the
--- warmup chain — a revenue/privacy violation the user never opted into.
---
--- Fix: both WarmupCtrl functions now check llm_mod.get_runtime_llm_enabled()
--- at their entry point and return early (DEBUG log) when the feature is off.
---
--- Two tests:
---   1. warmup() does NOT call llm_mod.warmup_model when runtime disabled.
---   2. warmup_model() does NOT call llm_mod.warmup_model when runtime disabled.
---   3. warmup() DOES call llm_mod.warmup_model when runtime enabled.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Build a fake llm_mod with configurable gate and a spy on warmup_model
local function make_llm_stub(runtime_enabled, active_model, mode)
	local warmup_calls = {}
	return {
		get_runtime_llm_enabled = function() return runtime_enabled end,
		get_current_model       = function() return active_model or "test-model" end,
		warmup_model            = function(m)
			warmup_calls[#warmup_calls + 1] = m
			if mode == "throw" then error("injected warmup refusal") end
			if mode == "nil" then return nil end
			if mode == "false" then return false end
			return true
		end,
		get_warmup_calls        = function() return warmup_calls end,
	}
end

local function load_wc(llm_stub)
	package.loaded["ui.menu.menu_llm.warmup_controller"] = nil
	package.loaded["modules.llm"] = llm_stub
	local wc = helpers.load_with_stubs("ui.menu.menu_llm.warmup_controller", {
		["modules.llm"] = llm_stub,
	})
	return wc, llm_stub
end




-- ====================================================================
-- ====================================================================
-- ======= 1/ M.warmup() gated on runtime enable (M-12) ==============
-- ====================================================================
-- ====================================================================

helpers.describe("M-12: WarmupCtrl.warmup gated on runtime LLM enable", function()

	helpers.it("warmup() does NOT call llm_mod.warmup_model when runtime disabled", function()
		local llm_stub = make_llm_stub(false, "mlx-community/model")
		local wc = load_wc(llm_stub)
		wc.warmup("backend-switch")
		helpers.assert_eq(#llm_stub.get_warmup_calls(), 0,
			"warmup_model must NOT be called when get_runtime_llm_enabled returns false")
	end)

	helpers.it("warmup() DOES call llm_mod.warmup_model when runtime enabled", function()
		local llm_stub = make_llm_stub(true, "mlx-community/model")
		local wc = load_wc(llm_stub)
		wc.warmup("backend-switch")
		helpers.assert_true(#llm_stub.get_warmup_calls() >= 1,
			"warmup_model must be called when get_runtime_llm_enabled returns true")
	end)

	for _, mode in ipairs({"false", "nil", "throw"}) do
		helpers.it("warmup() propagates strict backend " .. mode, function()
			local llm_stub = make_llm_stub(true, "mlx-community/model", mode)
			local wc = load_wc(llm_stub)
			helpers.assert_eq(wc.warmup("backend-switch"), false)
			helpers.assert_eq(#llm_stub.get_warmup_calls(), 1)
		end)
	end
end)




-- ====================================================================
-- ====================================================================
-- ======= 2/ M.warmup_model() gated on runtime enable (M-12) ========
-- ====================================================================
-- ====================================================================

helpers.describe("M-12: WarmupCtrl.warmup_model gated on runtime LLM enable", function()

	helpers.it("warmup_model() does NOT call llm_mod.warmup_model when runtime disabled", function()
		local llm_stub = make_llm_stub(false)
		local wc = load_wc(llm_stub)
		wc.warmup_model("mlx-community/model", "api-panel")
		helpers.assert_eq(#llm_stub.get_warmup_calls(), 0,
			"warmup_model must NOT be called when get_runtime_llm_enabled returns false")
	end)

	helpers.it("warmup_model() DOES call llm_mod.warmup_model when runtime enabled", function()
		local llm_stub = make_llm_stub(true)
		local wc = load_wc(llm_stub)
		wc.warmup_model("mlx-community/model", "api-panel")
		helpers.assert_true(#llm_stub.get_warmup_calls() >= 1,
			"warmup_model must be called when get_runtime_llm_enabled returns true")
	end)
end)
