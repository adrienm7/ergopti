--- tests/unit/ui/menu/shortcuts/test_shortcuts_toggle_pause_gated.lua

--- ==============================================================================
--- MODULE: Regression — the Shortcuts master toggle under a pause
--- DESCRIPTION:
--- Toggling « Raccourcis » while the script was paused either did nothing that
--- survived, or bound every hotkey during a pause.
---
--- ROOT CAUSE ENCODED:
--- Pause owns the bindings axis for the whole pause window: pause_all() snapshots
--- is_bindings_started() and resume_all() restores the bindings from that
--- snapshot. A toggle made in between writes state.shortcuts and calls
--- pause_bindings/resume_bindings, but resume_all() later overwrites that with
--- the pre-pause snapshot — so the user's choice is silently discarded. Worse,
--- toggling ON binds every hotkey immediately, breaking the « pause = tout
--- éteint » invariant the pause exists to guarantee.
---
--- WHY IT WAS SILENT:
--- The menu item still rendered enabled, still flipped its checkmark, and still
--- fired its notification — every visible signal reported success. Only the
--- resume, seconds or minutes later, quietly undid it.
---
--- EDD-1 (maintainer decision 2026-11-12, a pause stops typing, not
--- configuration) replaced the refusal: under a pause the switch records its
--- intent through shortcuts.set_feature_intent_under_pause(), which binds
--- nothing, and never calls pause_bindings/resume_bindings itself.
---
--- The switch is the command registered for the manifest's `shortcuts_toggle`
--- row since the parent row stopped carrying it (a row that opens a submenu is
--- never clicked). So this builds the real menu module over doubles and calls
--- that command, rather than scanning the parent's item table: the guard is on
--- what the click does. `checked` must keep reporting the stored preference.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds the Shortcuts submenu for a paused script and returns what matters.
--- @return table item, function|nil toggle, table state, table calls
local function build_paused()
	local calls = { pause = 0, resume = 0, intents = {} }
	local shortcuts = {
		pause_bindings = function() calls.pause = calls.pause + 1; return true end,
		resume_bindings = function() calls.resume = calls.resume + 1; return true end,
		set_feature_intent_under_pause = function(enabled)
			calls.intents[#calls.intents + 1] = enabled
			return true
		end,
	}
	local render_ctx, render_lists = nil, nil
	helpers.load_with_stubs("infra.logger")
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["core.fs.engine.dir"] = { entries = function() return {} end }
	package.loaded["infra.dialog_util"] = {}
	package.loaded["modules.shortcuts"] = {
		DEFAULT_STATE = { chatgpt_url = "https://example.test", shortcuts = true },
	}
	package.loaded["modules.shortcuts.actions.text"] = {
		WRAP_GROUPS = {},
		build_active_wrap_pairs = function() return {} end,
	}
	package.loaded["infra.i18n"] = {
		get = function(key) return key end,
		section = function(key) return key end,
		decorate_section = function(value) return value end,
	}
	package.loaded["ui.menu.menu_utils"] = {}
	package.loaded["infra.manifest_menu"] = require("tests.support.declared_menu_parent_fixture").stub(function(_, _, _, _, ctx, lists)
		render_ctx, render_lists = ctx, lists
		return {}
	end)
	package.loaded["ui.menu.shortcut_utils"] = {}
	package.loaded["ui.menu.menu_keyboard_slots"] = { provide_rows = function() return {} end }
	package.loaded["infra.manifest_reader"] = { default_for = function() return "★" end }
	package.loaded["ui.menu.menu_tap_keys"] = {
		provide_rows = function(_, disabled) calls.tap_keys_disabled = disabled; return {} end,
	}
	package.loaded["ui.menu.menu_shortcuts"] = nil
	local MenuShortcuts = require("ui.menu.menu_shortcuts")
	local state = {
		shortcuts = true,
		chatgpt_url = "https://example.test",
		wrap_symbol_states = {},
		custom_wrap_symbols = {},
	}
	local item = MenuShortcuts.build({
		shortcuts = shortcuts,
		state = state,
		paused = true,
		applyTriggerChar = function(value) return value end,
		save_prefs = function() return true end,
		notify_feature = function() end,
		updateMenu = function() end,
		commands = {},
		state_getters = {},
	})
	local toggle = render_ctx and render_ctx.commands and render_ctx.commands["shortcuts_toggle"]
	return item, toggle, state, calls, render_lists
end

helpers.describe("the Shortcuts master toggle under a pause", function()
	-- A pause stops typing, not configuration (EDD-1, maintainer decision
	-- 2026-11-12): the submenu opens; the switch itself still refuses below.
	helpers.it("keeps the parent row reachable while paused (edd1-paused-writes)", function()
		local item = build_paused()
		helpers.assert_true(item.disabled ~= true, "the Shortcuts row stays reachable while paused")
		helpers.assert_nil(item.action, "the parent opens a submenu and carries no action")
	end)

	helpers.it("records the switch while paused without binding anything (edd1-paused-writes)", function()
		local _, toggle, state, calls = build_paused()
		helpers.assert_type(toggle, "function", "the switch must be registered even while paused")
		helpers.assert_eq(toggle(), true, "the switch commits while paused")
		helpers.assert_eq(state.shortcuts, false, "the stored preference follows the click")
		helpers.assert_eq(calls.intents, { false }, "only the pause-safe recorder runs")
		helpers.assert_eq(calls.pause + calls.resume, 0,
			"the switch never binds or unbinds hotkeys itself under a pause")
		helpers.assert_eq(toggle(), true)
		helpers.assert_eq(state.shortcuts, true)
		helpers.assert_eq(calls.intents, { false, true })
	end)

	helpers.it("keeps the tap-key rows editable while paused (edd1-paused-writes)", function()
		local _, _, _, calls, lists = build_paused()
		helpers.assert_type(lists and lists.tap_keys, "function")
		lists.tap_keys()
		helpers.assert_nil(calls.tap_keys_disabled, "a pause does not grey the tap-key rows")
	end)

	helpers.it("leaves `checked` reporting the stored preference", function()
		local item = build_paused()
		helpers.assert_eq(item.checked, true,
			"`checked` must NOT consult the pause state — a paused script still has a stored "
			.. "Shortcuts preference, and blanking the checkmark would misreport it as off")
	end)
end)
