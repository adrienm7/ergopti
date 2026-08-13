--- tests/unit/ui/menu/menu_llm/test_models_selector_pause_gate.lua

--- ==============================================================================
--- MODULE: Regression — models_selector rows disabled when paused (M-16)
--- DESCRIPTION:
--- ModelsSelector.build() previously lacked a `paused` parameter and its rows had
--- no `disabled` field. While paused, clicking any model row called switch_model()
--- → guarded_check_requirements() which triggered backend warmup mid-pause —
--- violating the suspend-pause invariant.
---
--- Fix: thread `paused` into M.build(ctx) and set `disabled = paused or nil` on
--- every model-selection row (no_model, backend_default, user rows, preset rows).
---
--- Test: call build({paused=true}) with a minimal fake context and assert that
--- every menu item without a `menu` (direct action row) has disabled=true or fn
--- raises no error before switch_model could be reached (because disabled items are
--- greyed-out and macOS/hs won't invoke their fn). The simplest contract:
--- build returns a table of items all with disabled=true (or nil fn for non-switch
--- rows).
--- ==============================================================================

local helpers = require("tests.helpers")

-- Build a minimal fake context that satisfies ModelsSelector.build() I/O contract
local function make_ctx(paused)
	local switch_calls = {}
	local disable_calls = 0
	return {
		state = {
			llm_model   = "",
			llm_backend = "mlx",
		},
		models_mgr = {
			get_installed_models = function() return {} end,
			get_presets          = function() return {} end,
			get_model_info       = function() return nil end,
			get_model_ram        = function() return 0 end,
			is_model_installed   = function() return false end,
		},
		switch_model  = function(m) switch_calls[#switch_calls + 1] = m end,
		disable_model = function() disable_calls = disable_calls + 1; return true end,
		save_prefs    = function() end,
		update_menu   = function() end,
		DEFAULT_STATE = { llm_model_mlx = "", llm_model_ollama = "" },
		paused        = paused,
		get_switch_calls = function() return switch_calls end,
		get_disable_calls = function() return disable_calls end,
	}
end





-- ==============================================================================
-- ==============================================================================
-- ======= 1/ All direct model rows have disabled=true when paused (M-16) =======
-- ==============================================================================
-- ==============================================================================

helpers.describe("M-16: models_selector rows disabled when paused", function()

	helpers.it("build({paused=true}) — every actionable row has disabled=true", function()
		package.loaded["ui.menu.menu_llm.models_selector"] = nil
		local MS = helpers.load_with_stubs("ui.menu.menu_llm.models_selector")
		local ctx = make_ctx(true)
		local menu = MS.build(ctx)

		helpers.assert_true(type(menu) == "table", "build must return a table")
		helpers.assert_true(#menu > 0, "build must return at least one item")

		-- Provider rows since 2026-08-06: {label, action, items} rather than
		-- {title, fn, menu}, because the LLM model row is a manifest `list` slot
		-- and the shared renderer materialises what this file returns. The gate
		-- being checked is unchanged — an actionable row must be greyed while the
		-- script is paused — so the assertion follows the field names rather than
		-- being dropped with them.
		local checked = 0
		for i, item in ipairs(menu) do
			if type(item.label) == "string" and not item.separator and type(item.action) == "function" then
				checked = checked + 1
				helpers.assert_true(item.disabled == true,
					string.format("row %d ('%s') must have disabled=true when paused", i, item.label))
			end
		end
		helpers.assert_true(checked > 0,
			"no actionable row was inspected — a loop that matches nothing agrees with any output, "
				.. "which is exactly how a renamed field turns this test green over a broken gate")
	end)

	helpers.it("build({paused=false}) — rows are NOT disabled", function()
		package.loaded["ui.menu.menu_llm.models_selector"] = nil
		local MS = helpers.load_with_stubs("ui.menu.menu_llm.models_selector")
		local ctx = make_ctx(false)
		local menu = MS.build(ctx)

		-- At least one actionable row should be enabled
		local found_enabled = false
		for _, item in ipairs(menu) do
			if type(item.label) == "string" and not item.separator and type(item.action) == "function" then
				if item.disabled ~= true then found_enabled = true end
			end
		end
		helpers.assert_true(found_enabled,
			"at least one model row must be enabled when paused=false")
	end)

	helpers.it("(no-model-runtime) the No Model row delegates the runtime transaction to the model switcher", function()
		package.loaded["ui.menu.menu_llm.models_selector"] = nil
		local MS = helpers.load_with_stubs("ui.menu.menu_llm.models_selector")
		local ctx = make_ctx(false)
		local menu = MS.build(ctx)
		local no_model
		for _, item in ipairs(menu) do
			if item.checked == true and type(item.action) == "function" then
				no_model = item
				break
			end
		end
		helpers.assert_not_nil(no_model, "the checked No Model action must be reachable")
		helpers.assert_eq(no_model.action(), true)
		helpers.assert_eq(ctx.get_disable_calls(), 1,
			"the selector must not mutate preferences without clearing runtime model state")
	end)
end)
