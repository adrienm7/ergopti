--- tests/unit/ui/menu/menu_llm/test_llm_menu_toggle_row.lua

--- ==============================================================================
--- MODULE: Regression — the IA submenu carries its own on/off row
--- DESCRIPTION:
--- Builds the real IA menu item, hands the context it gives the renderer to the
--- real shared renderer, and requires the manifest's `llm_toggle` row, wired to
--- the same activation transaction as the parent.
---
--- WHY IT EXISTS: the macOS menu registered no command for `llm_toggle`, so the
--- shared renderer skipped the row and only the checked parent was left to
--- toggle. A macOS menu item that opens a submenu never sends its action, and
--- the renderer drops a provider row's action when the row has a submenu, so
--- the IA suggestions could not be switched on from the menu bar at all.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_activation = require("tests.support.llm_activation_fixture")

--- Builds the real IA item for one enabled state.
--- @param enabled boolean The IA preference while the menu is built.
--- @return table item, table|nil render_ctx
local function build_item(enabled)
	local item, render_ctx
	with_activation("ollama", { true }, nil, function(_action, state, calls)
		state.llm_enabled = enabled
		item = calls.handler.build_item()
		render_ctx = calls.render_ctx
	end)
	return item, render_ctx
end

--- Renders the IA submenu through the real shared renderer.
--- @param render_ctx table The context the IA menu handed to the renderer.
--- @return table Rendered hs.menubar rows.
local function render(render_ctx)
	return helpers.with_fresh_modules({ "infra.manifest_menu", "menu.renderer" }, function()
		local ManifestMenu = helpers.load_with_stubs("infra.manifest_menu")
		-- Every dynamic row answers with nothing: only the gate is under test here.
		local handlers = setmetatable({}, { __index = function() return function() end end })
		return ManifestMenu.build("llm_menu", "LLM", handlers, nil, render_ctx, {})
	end)
end

helpers.describe("IA submenu on/off row", function()
	helpers.it("draws the declared toggle first, wired to the activation transaction", function()
		local item, render_ctx = build_item(false)
		helpers.assert_type(render_ctx, "table", "the IA menu must hand the renderer a context")
		helpers.assert_type(item.action, "function")
		helpers.assert_true(render_ctx.commands and render_ctx.commands.llm_toggle == item.action,
			"the llm_toggle command must run the parent's activation transaction")
		local rows = render(render_ctx)
		helpers.assert_true(type(rows[1]) == "table" and rows[1].fn == item.action,
			"the IA submenu must open with its on/off row")
		helpers.assert_eq(rows[1].title, "menu.llm.toggle_enable",
			"a disabled IA must offer to enable the suggestions")
	end)

	helpers.it("offers to disable once the suggestions are on", function()
		local _, render_ctx = build_item(true)
		local rows = render(render_ctx)
		helpers.assert_eq(rows[1] and rows[1].title, "menu.llm.toggle_disable")
	end)
end)
