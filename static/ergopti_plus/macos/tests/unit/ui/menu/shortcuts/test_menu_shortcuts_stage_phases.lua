--- tests/unit/ui/menu/shortcuts/test_menu_shortcuts_stage_phases.lua

--- ==============================================================================
--- MODULE: Shortcuts submenu — named stage phases
--- DESCRIPTION:
--- The 2026-11-06 field report held the main thread 537 ms in one menu
--- rebuild, right after a layout switch to French: menu_item.shortcuts took
--- 341.9 ms against 30 to 47 ms in every other rebuild of the session, and the
--- hold report could name nothing inside it. The keyboard layout row already
--- records one phase per stage (menu_keyboard_layout.*); each provider of the
--- Shortcuts submenu now records its own (menu_shortcuts.*), so the next hold
--- names the stage that costs before anything there is changed
--- (menu-shortcuts-stage-phases).
--- ==============================================================================

local helpers = require("tests.helpers")

local names = {
	"ui.menu.menu_keyboard_slots", "ui.menu.menu_tap_keys", "ui.menu.menu_shortcuts",
	"modules.shortcuts", "modules.shortcuts.tap_keys", "modules.shortcuts.bindings",
	"modules.shortcuts.actions.text", "core.i18n.engine.i18n", "core.logger.engine.logger", "infra.manifest_menu",
	"core.timing.engine.deferred_work", "adapters.input_source_broker", "ui.menu.menu_utils",
	"core.fs.engine.paths", "menu.engine.renderer", "infra.phase_stats",
}

helpers.describe("menu_shortcuts: each provider records a named phase (menu-shortcuts-stage-phases)", function()
	helpers.it("a build records one phase per provider, even a raising one (menu-shortcuts-stage-phases)", function()
		helpers.with_fresh_modules(names, function()
			local recorded = {}
			package.loaded["infra.phase_stats"] = {
				now = function() return 0 end,
				stop = function(name) recorded[name] = (recorded[name] or 0) + 1 end,
				count = function() end,
			}
			local shortcuts = { DEFAULT_STATE = { shortcuts = true } }
			package.loaded["modules.shortcuts"] = shortcuts
			package.loaded["modules.shortcuts.tap_keys"] = {}
			package.loaded["modules.shortcuts.bindings"] = {}
			package.loaded["modules.shortcuts.actions.text"] = {}
			package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
			package.loaded["core.timing.engine.deferred_work"] = {}
			package.loaded["adapters.input_source_broker"] = { subscribe = function() return true end }
			package.loaded["ui.menu.menu_utils"] = {}
			package.loaded["core.fs.engine.paths"] = { shared = helpers.shared }
			local actual_manifest = require("infra.manifest_menu")
			local invoked = {}
			package.loaded["infra.manifest_menu"] = {
				group_receiver = actual_manifest.group_receiver,
				template_rows = actual_manifest.template_rows,
				build = function(key, _, _, groups, _, providers)
					if key ~= "shortcuts_menu" then return {} end
					-- Every stage runs; one that raises must still be timed
					for name, fn in pairs(groups or {}) do invoked[#invoked + 1] = name; pcall(fn) end
					for name, fn in pairs(providers or {}) do invoked[#invoked + 1] = name; pcall(fn, {}) end
					return {}
				end,
			}
			local ctx = { gestures = {}, shortcuts = shortcuts, updateMenu = function() end,
				state = { shortcuts = true } }
			pcall(require("ui.menu.menu_shortcuts").build, ctx)
			helpers.assert_true(#invoked >= 5, "the stub invoked too few stages to prove anything")
			for _, name in ipairs(invoked) do
				helpers.assert_eq(recorded["menu_shortcuts." .. name], 1, "stage '" .. name .. "' recorded no phase")
			end
		end)
	end)
end)
