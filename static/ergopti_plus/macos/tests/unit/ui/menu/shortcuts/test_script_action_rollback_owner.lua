--- tests/unit/ui/menu/shortcuts/test_script_action_rollback_owner.lua

--- ==============================================================================
--- MODULE: Script Action Rollback Owner
--- DESCRIPTION:
--- The ordinary whole-state rollback must not overwrite an unrelated runtime
--- action and must route the owned slot through its retained inverse.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("script action whole-state rollback", function()
	helpers.it("preserves a foreign action during the real preference rollback", function()
		local state = { script_control_shortcuts = { slot = "none" } }
		local runtime, owner, claim = "none", nil, nil
		local facade = {
			get_shortcut_actions = function() return { slot = runtime } end,
			set_shortcut_action = function(_, value) runtime = value; return true end,
		}
		local save = require("ui.menu.preferences_transaction").bind({}, {
			state = state, initial_state = { script_control_shortcuts = { slot = "none" } },
			initial_preferences = {},
			read_only_reason = function() runtime = "foreign"; return "read-only" end,
			restore_runtime = function()
				if not owner.restore_runtime() then return false end
				local projection = owner.rollback_modules({ shortcuts_mod = facade })
				return projection.shortcuts_mod.set_shortcut_action("slot", "none")
			end,
		})
		owner = require("ui.menu.script_action_transaction").new({
			state = state, script_control = facade, paused = function() return false end,
			admission = function(_, fn, retained) claim = retained; return fn() end,
			save_prefs = save,
		})
		helpers.assert_eq(owner.assign("slot", "save"), false)
		helpers.assert_eq(runtime, "foreign")
		helpers.assert_true(claim.pending())
	end)

	helpers.it("refuses a foreign runtime action before ordinary sync can overwrite it", function()
		local state = { script_control_shortcuts = { slot = "none" } }
		local runtime, owner, claim = "none", nil, nil
		local facade = {
			get_shortcut_actions = function() return { slot = runtime } end,
			set_shortcut_action = function(_, value) runtime = value; return true end,
		}
		owner = require("ui.menu.script_action_transaction").new({
			state = state, script_control = facade, paused = function() return false end,
			admission = function(_, fn, retained) claim = retained; return fn() end,
			save_prefs = function()
				runtime = "foreign"
				helpers.assert_eq(owner.restore_runtime(), false)
				return false
			end,
		})
		helpers.assert_eq(owner.assign("slot", "save"), false)
		helpers.assert_eq(runtime, "foreign")
		helpers.assert_true(claim.pending(), "the unresolved inverse remains globally owned")
		helpers.assert_eq(claim.retry_restore(), false)
		helpers.assert_eq(runtime, "foreign")
	end)

	helpers.it("retains the inverse across the projected whole-state sync", function()
		local state = { script_control_shortcuts = { slot = "none" } }
		local runtime, owner, claim = "none", nil, nil
		local facade = {
			get_shortcut_actions = function() return { slot = runtime } end,
			set_shortcut_action = function(_, value) runtime = value; return true end,
		}
		owner = require("ui.menu.script_action_transaction").new({
			state = state, script_control = facade, paused = function() return false end,
			admission = function(_, fn, retained) claim = retained; return fn() end,
			save_prefs = function()
				helpers.assert_true(owner.restore_runtime())
				helpers.assert_true(claim.pending())
				local projection = owner.rollback_modules({ shortcuts_mod = facade })
				helpers.assert_true(projection.shortcuts_mod.set_shortcut_action("slot", "save"))
				helpers.assert_eq(runtime, "none", "whole-state sync cannot reapply the candidate")
				helpers.assert_true(claim.pending())
				return false
			end,
		})
		helpers.assert_eq(owner.assign("slot", "save"), false)
		helpers.assert_eq(runtime, "none")
		helpers.assert_eq(state.script_control_shortcuts.slot, "none")
		helpers.assert_eq(claim.pending(), false)
	end)
end)
