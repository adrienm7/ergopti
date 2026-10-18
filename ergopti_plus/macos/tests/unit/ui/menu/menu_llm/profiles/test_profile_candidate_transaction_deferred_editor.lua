--- tests/unit/ui/menu/menu_llm/profiles/test_profile_candidate_transaction_deferred_editor.lua

--- ==============================================================================
--- MODULE: LLM Profile Candidate Transactions
--- DESCRIPTION:
--- Drives the real ProfilesManager and ModelSwitcher across Clone and Create.
--- Runtime doubles preserve exact profile-table identity and can mutate before
--- throwing so candidate cleanup, retained compensation, persistence, and menu
--- publication are observed behaviorally rather than inferred from source text.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.ui.menu.menu_llm.profiles.profile_candidate_transaction_fixture"] = nil
local Fixture = require("tests.support.ui.menu.menu_llm.profiles.profile_candidate_transaction_fixture")
local clone = Fixture.clone
local find_child_row = Fixture.find_child_row
local find_row = Fixture.find_row
local with_fixture = Fixture.with_fixture





helpers.describe("LLM scope deferred editor admission", function()
	helpers.it("refuses queued and open editors until both existing owners are idle", function()
		local options = { initial_profiles = { { id = "custom", label = "Custom" } } }
		with_fixture(options, function(fixture)
			helpers.assert_eq(fixture.manager.scope_idle(), true)
			local row = find_child_row(fixture.manager.get_menu_item().menu, "Custom", "menu.profiles.edit_profile")
			helpers.assert_eq(row.action(), true)
			helpers.assert_eq(fixture.manager.scope_idle(), false)
			options.editor_busy = true
			fixture.fire_timer()
			helpers.assert_eq(fixture.editor_open_count(), 1)
			helpers.assert_eq(fixture.manager.scope_idle(), false)
			options.editor_busy = false
			helpers.assert_eq(fixture.manager.scope_idle(), true)
		end)
	end)
end)

helpers.describe("shared Create Profile command", function()
	helpers.it("shared Create Profile follows the changed declaration without a native label", function()
		with_fixture({ create_label_key = "button.cancel" }, function(fixture)
			local rows = fixture.manager.get_menu_item().menu
			helpers.assert_eq(find_row(rows, "menu.profiles.create_profile"), nil)
			local row = find_row(rows, "button.cancel")
			helpers.assert_type(row, "table")
			helpers.assert_eq(row.action(), true)
			fixture.fire_timer()
			helpers.assert_eq(fixture.state.llm_active_profile, "user_created")
			helpers.assert_eq(fixture.save_count(), 1)
		end)
	end)

	helpers.it("shared Create Profile refuses a retained row after the live native pause owner changes", function()
		local options = {}
		with_fixture(options, function(fixture)
			local row = find_row(fixture.manager.get_menu_item().menu, "menu.profiles.create_profile")
			helpers.assert_type(row.action, "function")
			options.paused = true
			helpers.assert_eq(row.action(), false)
			helpers.assert_eq(fixture.timer_count(), 0)
			helpers.assert_eq(fixture.editor_open_count(), 0)
			helpers.assert_eq(fixture.save_count(), 0)
		end)
	end)

	helpers.it("shared Create Profile refuses the actual deferred editor opening after pause", function()
		local options = {}
		with_fixture(options, function(fixture)
			local row = find_row(fixture.manager.get_menu_item().menu, "menu.profiles.create_profile")
			helpers.assert_eq(row.action(), true)
			options.paused = true
			fixture.fire_timer()
			helpers.assert_eq(fixture.editor_open_count(), 0)
			helpers.assert_eq(fixture.save_count(), 0)
			helpers.assert_eq(#fixture.runtime_calls(), 0)
		end)
	end)

	helpers.it("shared Create Profile refuses a native editor save after pause without candidate publication", function()
		local options = {}
		options.before_editor_save = function() options.paused = true end
		with_fixture(options, function(fixture)
			local row = find_row(fixture.manager.get_menu_item().menu, "menu.profiles.create_profile")
			helpers.assert_eq(row.action(), true)
			fixture.fire_timer()
			helpers.assert_eq(fixture.editor_open_count(), 1)
			helpers.assert_eq(fixture.save_count(), 0)
			helpers.assert_eq(#fixture.runtime_calls(), 0)
			helpers.assert_eq(fixture.state.llm_active_profile, "basic")
			helpers.assert_eq(fixture.notifications(), 0)
		end)
	end)
end)

helpers.describe("shared Clone Profile command", function()
	helpers.it("shared Clone Profile follows its declaration and retains the real activation owner", function()
		with_fixture({ clone_label_key = "button.cancel" }, function(fixture)
			local rows = fixture.manager.get_menu_item().menu
			helpers.assert_eq(find_row(rows, "menu.profiles.clone_builtin"), nil)
			local row = find_row(rows, "button.cancel")
			helpers.assert_type(row.action, "function")
			helpers.assert_eq(row.action(), true)
			helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
			helpers.assert_true(fixture.state.llm_active_profile:match("^user_basic_") ~= nil)
			helpers.assert_eq(fixture.save_count(), 1)
		end)
	end)

	helpers.it("shared Clone Profile refuses retained clicks before clone publication after pause", function()
		local options = {}
		with_fixture(options, function(fixture)
			local row = find_row(fixture.manager.get_menu_item().menu, "menu.profiles.clone_builtin")
			options.paused = true
			helpers.assert_eq(row.action(), false)
			helpers.assert_eq(#fixture.state.llm_user_profiles, 0)
			helpers.assert_eq(#fixture.runtime_calls(), 0)
			helpers.assert_eq(fixture.save_count(), 0)
			helpers.assert_eq(fixture.timer_count(), 0)
		end)
	end)

	helpers.it("shared Clone Profile retires deferred editing after pause without repeating its acknowledged clone", function()
		local options = {}
		with_fixture(options, function(fixture)
			local row = find_row(fixture.manager.get_menu_item().menu, "menu.profiles.clone_builtin")
			helpers.assert_eq(row.action(), true)
			helpers.assert_eq(fixture.save_count(), 1)
			local acknowledged = fixture.state.llm_user_profiles[1]
			options.paused = true
			fixture.fire_timer()
			helpers.assert_eq(fixture.editor_open_count(), 0)
			helpers.assert_eq(fixture.save_count(), 1)
			helpers.assert_eq(fixture.state.llm_user_profiles[1], acknowledged)
		end)
	end)

	helpers.it("shared Clone Profile refuses a held editor save after pause and preserves its acknowledged clone", function()
		local options = {}
		options.before_clone_editor_save = function() options.paused = true; options.clone_save_observed = true end
		with_fixture(options, function(fixture)
			local row = find_row(fixture.manager.get_menu_item().menu, "menu.profiles.clone_builtin")
			helpers.assert_eq(row.action(), true)
			local acknowledged = fixture.state.llm_user_profiles[1]
			options.editor_update = clone(acknowledged)
			options.editor_update.label = "Edited clone"
			fixture.fire_timer()
			helpers.assert_eq(options.clone_save_observed, true)
			helpers.assert_eq(options.clone_save_result, false)
			helpers.assert_eq(fixture.editor_open_count(), 1)
			helpers.assert_eq(fixture.save_count(), 1)
			helpers.assert_eq(fixture.state.llm_user_profiles[1], acknowledged)
			helpers.assert_eq(fixture.notifications(), 0)
		end)
	end)
end)
