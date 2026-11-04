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
		local restore_checked = false
		local facade = {
			get_shortcut_actions = function() return { slot = runtime } end,
			set_shortcut_action = function(_, value) runtime = value; return true end,
		}
		local save = require("ui.menu.preferences_transaction").bind({}, {
			state = state, initial_state = { script_control_shortcuts = { slot = "none" } },
			initial_preferences = {},
			read_only_reason = function() runtime = "foreign"; return "read-only" end,
			restore_runtime = function()
				local restored = owner.restore_runtime()
				restore_checked = true
				if not restored then return false end
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
		helpers.assert_true(restore_checked, "preference rollback must actually check the inverse")
		helpers.assert_eq(runtime, "foreign")
		helpers.assert_true(claim.pending())
	end)

	helpers.it("refuses a foreign runtime action before ordinary sync can overwrite it", function()
		local state = { script_control_shortcuts = { slot = "none" } }
		local runtime, owner, claim = "none", nil, nil
		local restore_result = "not called"
		local facade = {
			get_shortcut_actions = function() return { slot = runtime } end,
			set_shortcut_action = function(_, value) runtime = value; return true end,
		}
		owner = require("ui.menu.script_action_transaction").new({
			state = state, script_control = facade, paused = function() return false end,
			admission = function(_, fn, retained) claim = retained; return fn() end,
			save_prefs = function()
				runtime = "foreign"
				restore_result = owner.restore_runtime()
				return false
			end,
		})
		helpers.assert_eq(owner.assign("slot", "save"), false)
		helpers.assert_eq(restore_result, false, "the protected callback must refuse the foreign action")
		helpers.assert_eq(runtime, "foreign")
		helpers.assert_true(claim.pending(), "the unresolved inverse remains globally owned")
		helpers.assert_eq(claim.retry_restore(), false)
		helpers.assert_eq(runtime, "foreign")
	end)

	helpers.it("retains the inverse across the projected whole-state sync", function()
		local state = { script_control_shortcuts = { slot = "none" } }
		local runtime, owner, claim = "none", nil, nil
		local observation = {}
		local facade = {
			get_shortcut_actions = function() return { slot = runtime } end,
			set_shortcut_action = function(_, value) runtime = value; return true end,
		}
		owner = require("ui.menu.script_action_transaction").new({
			state = state, script_control = facade, paused = function() return false end,
			admission = function(_, fn, retained) claim = retained; return fn() end,
			save_prefs = function()
				observation.restored = owner.restore_runtime()
				observation.pending_before = claim.pending()
				local projection = owner.rollback_modules({ shortcuts_mod = facade })
				observation.projected = projection.shortcuts_mod.set_shortcut_action("slot", "save")
				observation.runtime = runtime
				observation.pending_after = claim.pending()
				return false
			end,
		})
		helpers.assert_eq(owner.assign("slot", "save"), false)
		helpers.assert_eq(observation, { restored = true, pending_before = true,
			projected = true, runtime = "none", pending_after = true },
			"the protected save callback must complete and preserve its inverse")
		helpers.assert_eq(runtime, "none")
		helpers.assert_eq(state.script_control_shortcuts.slot, "none")
		helpers.assert_eq(claim.pending(), false)
	end)
end)
