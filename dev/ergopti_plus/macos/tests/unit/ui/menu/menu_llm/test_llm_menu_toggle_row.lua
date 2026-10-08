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
--- the IA suggestions could not be switched on from the menu bar at all. The
--- parent now carries no action at all, and the row stays drawn — greyed — while
--- the switch cannot run.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_activation = require("tests.support.llm_activation_fixture")

--- Builds the real IA item for one enabled state.
--- @param enabled boolean The IA preference while the menu is built.
--- @param paused boolean|nil Whether the script is paused while it is built.
--- @return table item, table|nil render_ctx
local function build_item(enabled, paused)
	local item, render_ctx
	with_activation("ollama", { true }, nil, function(_action, state, calls)
		state.llm_enabled = enabled
		if paused then calls.set_paused(true) end
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
		helpers.assert_nil(item.action, "the IA parent opens a submenu, so it must carry no action")
		local toggle = render_ctx.commands and render_ctx.commands["llm_toggle"]
		helpers.assert_type(toggle, "function", "the llm_toggle command must be registered")
		local rows = render(render_ctx)
		helpers.assert_true(type(rows[1]) == "table" and rows[1].fn == toggle,
			"the IA submenu must open with its on/off row")
		helpers.assert_nil(rows[1].disabled, "a ready switch is live")
		helpers.assert_eq(rows[1].title, "menu.llm.enable", "the IA switch is labelled by its one key")
		helpers.assert_eq(rows[1].checked, false, "a disabled IA shows an unticked switch")
	end)

	helpers.it("keeps the switch drawn, greyed, while the script is paused", function()
		local _, render_ctx = build_item(true, true)
		local rows = render(render_ctx)
		helpers.assert_eq(rows[1] and rows[1].title, "menu.llm.enable",
			"the switch must stay in the IA submenu while paused rather than vanish")
		helpers.assert_eq(rows[1].disabled, true, "and be greyed, since it cannot run its transaction")
		helpers.assert_eq(rows[1].fn(), false, "a click that still reaches it is refused")
	end)

	helpers.it("ticks the same switch once the suggestions are on", function()
		local _, render_ctx = build_item(true)
		local rows = render(render_ctx)
		helpers.assert_eq(rows[1] and rows[1].title, "menu.llm.enable")
		helpers.assert_eq(rows[1] and rows[1].checked, true)
	end)

	-- ai-menu-no-clear: « Tout effacer (comportement du système) » sat under the
	-- switch and cleared a section with nothing for the system to do in its
	-- place; the maintainer retired it, and « Restaurer les valeurs conseillées »
	-- stays the only row between the switch and the separator.
	helpers.it("draws the restore row under the switch and no clear row", function()
		local _, render_ctx = build_item(true)
		helpers.assert_nil(render_ctx.commands["scope_clear"], "the AI menu registers no clear command")
		local rows = render(render_ctx)
		helpers.assert_eq(rows[2] and rows[2].title, "common.restore_recommended",
			"the restore row follows the switch")
		helpers.assert_eq(type(rows[2].fn), "function", "the restore row runs its scope command")
		for index, row in ipairs(rows) do
			helpers.assert_true(row.title ~= "common.clear_to_system",
				"row " .. index .. " of the AI submenu is a clear row")
		end
	end)
end)


helpers.describe("Active download shortcut shared frame", function()
	helpers.it("retains all three actual task predicates and the held focus callback", function()
		with_activation("ollama", { true }, nil, function(_, _, calls)
			local predecessor = package.loaded["ui.download_window"]
			local focused = 0
			local owner = { focus = function() focused = focused + 1 end }
			local ok, detail = xpcall(function()
				package.loaded["ui.download_window"] = owner
				helpers.assert_nil(calls.handler.build_download_item())
				for _, task in ipairs({ "download", "download_tail", "install" }) do
					calls.root_deps.active_tasks[task] = true
					local row = calls.handler.build_download_item()
					helpers.assert_eq(row.title, "menu.llm.show_download_window")
					helpers.assert_type(row.fn, "function")
					helpers.assert_nil(row.disabled)
					helpers.assert_nil(row.menu)
					row.fn()
					calls.root_deps.active_tasks[task] = nil
				end
				helpers.assert_eq(focused, 3)
				helpers.assert_eq(calls.saves, 0)
				helpers.assert_eq(calls.updates, 0)
			end, debug.traceback)
			package.loaded["ui.download_window"] = predecessor
			helpers.assert_eq(rawequal(package.loaded["ui.download_window"], predecessor), true)
			if not ok then error(detail, 0) end
		end)
	end)
	helpers.it("refuses an unbound declaration without losing the active task or triggering effects", function()
		with_activation("ollama", { true }, nil, function(_, _, calls)
			local renderer = package.loaded["infra.manifest_menu"]
			local rows = renderer.get_array("llm_download_shortcut_frame")
			local original = rows[1]
			helpers.assert_not_nil(original)
			calls.root_deps.active_tasks.download = true
			local before = calls.handler.build_download_item()
			helpers.assert_eq(before.title, "menu.llm.show_download_window")
			local ok, detail = xpcall(function()
				rows[1] = { type = "command", id = "missing_download_owner", i18n = "menu.llm.show_download_window" }
				helpers.assert_nil(calls.handler.build_download_item())
				helpers.assert_eq(calls.root_deps.active_tasks.download, true)
				helpers.assert_eq(calls.saves, 0)
				helpers.assert_eq(calls.updates, 0)
				helpers.assert_eq(calls.notifications, 0)
			end, debug.traceback)
			rows[1] = original
			if not ok then error(detail, 0) end
			local repaired = calls.handler.build_download_item()
			helpers.assert_eq(repaired.title, before.title)
			helpers.assert_type(repaired.fn, "function")
			calls.root_deps.active_tasks.download = nil
			helpers.assert_nil(calls.handler.build_download_item())
		end)
	end)
end)


helpers.describe("Genuine temperature fixture dependency", function()
	helpers.it("binds real callbacks and refuses withdrawn declarations before parent publication", function()
		with_activation("ollama", { true }, nil, function(_, state, calls)
			local panel = package.loaded["ui.menu.menu_llm.temperature_panel"]
			helpers.assert_eq(rawequal(panel.build, calls.temperature_builder), true)
			local sets, resets = 0, 0
			local set = function() sets = sets + 1; return true end
			local reset = function() resets = resets + 1; return true end
			local ctx = { state = state, is_disabled = false,
				settings_mgr = { set_temperature = set, reset_temperature = reset,
					apply_setting_transaction = function() error("construction must not apply") end } }
			local rows = {}
			helpers.assert_type(panel.build(ctx, rows), "table")
			helpers.assert_eq(#rows, 1)
			helpers.assert_type(rows[1].action, "function")
			helpers.assert_eq(rows[1].action(), true)
			helpers.assert_eq(sets, 1)
			helpers.assert_eq(resets, 0)
			local declaration = package.loaded["infra.manifest_menu"].get_array("llm_generation_temperature_control")
			local original = declaration[1]
			local ok, detail = xpcall(function()
				declaration[1] = { type = "command", id = "missing_temperature_owner", i18n = original.i18n }
				local refused = {}
				helpers.assert_nil(panel.build(ctx, refused))
				helpers.assert_eq(refused, {})
				helpers.assert_eq(calls.handler.build_item(), {})
				helpers.assert_eq(sets, 1)
				helpers.assert_eq(resets, 0)
				helpers.assert_eq(calls.saves, 0)
				helpers.assert_eq(calls.updates, 0)
			end, debug.traceback)
			declaration[1] = original
			if not ok then error(detail, 0) end
			helpers.assert_type(calls.handler.build_item().submenu, "table")
			local repaired = {}
			helpers.assert_type(panel.build(ctx, repaired), "table")
			helpers.assert_eq(repaired[1].action(), true)
			helpers.assert_eq(sets, 2)
		end)
	end)
end)
