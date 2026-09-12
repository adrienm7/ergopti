--- tests/unit/ui/menu/menu_llm/test_profile_delete_transaction.lua

--- ==============================================================================
--- MODULE: LLM Profile Deletion Transactions
--- DESCRIPTION:
--- Exercises the primary/profile shortcut owner and the real confirmed profile
--- Delete action through refusal-capable registrar seams. Real Hammerspoon-shaped
--- doubles keep enable=self|nil, disable=self, and delete=void|throw contracts.
--- Tests preserve handle identity and invoke retained callbacks so a
--- bookkeeping-only rollback cannot pass.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fixture = require("tests.support.profile_delete_fixture")
local with_delete_fixture = Fixture.with_delete_fixture

helpers.describe("HS-033 profile deletion transaction", function()
	for _, outcome in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-033 confirmed Delete keeps the exact profile owner when registrar delete " .. outcome, function()
			with_delete_fixture({active_profile = "basic"}, function(fixture, delete_action, old_handle)
				local old_profiles = fixture.state.llm_user_profiles
				local old_shortcut = fixture.state.llm_profile_shortcuts.user_p
				local old_chord = old_handle.chord
				fixture.backend.plan("delete", {outcome})
				fixture.plan_save({"ok", "ok"})

				local result = delete_action()
				helpers.assert_true(fixture.get_profile_hk("user_p") == old_handle)
				helpers.assert_eq(old_handle.chord, old_chord)
				helpers.assert_true(fixture.state.llm_profile_shortcuts.user_p == old_shortcut)
				helpers.assert_true(fixture.state.llm_user_profiles == old_profiles,
					"rollback must restore the exact registry table")
				helpers.assert_true(fixture.get_runtime_profiles() == old_profiles)
				helpers.assert_eq(fixture.durable().llm_user_profiles,
					{{id = "user_p", label = "Profile P"}})
				helpers.assert_eq(fixture.durable().llm_profile_shortcuts.user_p,
					{mods = {"ctrl"}, key = "p"})
				helpers.assert_eq(fixture.get_menu_snapshot().llm_user_profiles,
					{{id = "user_p", label = "Profile P"}})
				helpers.assert_eq(fixture.get_menu_snapshot().llm_profile_shortcuts.user_p,
					{mods = {"ctrl"}, key = "p"})
				fixture.fire(old_handle)
				helpers.assert_eq(fixture.get_prediction_count(), 1,
					"the retained native callback must still resolve the old profile")
				helpers.assert_eq(result, false)
			end)
		end)
	end

	for _, outcome in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-033 Delete rolls back a set_user_profiles " .. outcome .. " refusal", function()
			with_delete_fixture({active_profile = "basic"}, function(fixture, delete_action, old_handle)
				local old_profiles = fixture.state.llm_user_profiles
				fixture.plan_profiles({outcome, "ok"})
				fixture.plan_save({"ok"})

				local result = delete_action()
				helpers.assert_true(fixture.get_profile_hk("user_p") == old_handle)
				helpers.assert_true(fixture.state.llm_user_profiles == old_profiles)
				helpers.assert_true(fixture.get_runtime_profiles() == old_profiles)
				helpers.assert_eq(fixture.get_menu_snapshot().llm_user_profiles,
					{{id = "user_p", label = "Profile P"}})
				helpers.assert_eq(fixture.get_save_count(), 0,
					"a runtime-registry refusal must not reach persistence")
				helpers.assert_eq(result, false)
			end)
		end)
	end

	for _, outcome in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-033 Delete restores every boundary after save " .. outcome, function()
			with_delete_fixture({active_profile = "basic"}, function(fixture, delete_action, old_handle)
				local old_profiles = fixture.state.llm_user_profiles
				local old_shortcuts = fixture.state.llm_profile_shortcuts
				fixture.plan_save({outcome == "false" and "restore_false" or outcome, "ok"})

				local result = delete_action()
				helpers.assert_true(fixture.get_profile_hk("user_p") == old_handle)
				helpers.assert_true(fixture.state.llm_user_profiles == old_profiles)
				helpers.assert_true(fixture.state.llm_profile_shortcuts == old_shortcuts)
				helpers.assert_true(fixture.get_runtime_profiles() == old_profiles)
				helpers.assert_eq(fixture.durable().llm_user_profiles,
					{{id = "user_p", label = "Profile P"}})
				helpers.assert_eq(old_handle.deleted, false)
				helpers.assert_eq(fixture.get_menu_snapshot().llm_user_profiles,
					{{id = "user_p", label = "Profile P"}})
				helpers.assert_eq(result, false)
			end)
		end)
	end

	helpers.it("HS-033 active Delete rolls the real profile owner back after parent save refusal", function()
		with_delete_fixture({active_profile = "user_p", real_switcher = true},
			function(fixture, delete_action, old_handle)
				local old_profiles = fixture.state.llm_user_profiles
				local old_shortcuts = fixture.state.llm_profile_shortcuts
				local old_shortcut = fixture.state.llm_profile_shortcuts.user_p
				fixture.plan_save({"restore_false", "ok"})

				local result = delete_action()
				helpers.assert_true(fixture.get_profile_hk("user_p") == old_handle)
				helpers.assert_true(fixture.state.llm_user_profiles == old_profiles)
				helpers.assert_true(fixture.state.llm_profile_shortcuts == old_shortcuts)
				helpers.assert_true(fixture.state.llm_profile_shortcuts.user_p == old_shortcut)
				helpers.assert_eq(fixture.state.llm_active_profile, "user_p")
				helpers.assert_eq(fixture.get_runtime_profile(), "user_p")
				helpers.assert_eq(fixture.durable().llm_active_profile, "user_p")
				helpers.assert_eq(fixture.get_menu_snapshot().llm_active_profile, "user_p")
				helpers.assert_eq(fixture.get_save_count(), 2)
				helpers.assert_eq(fixture.get_menu_count(), 0)
				helpers.assert_eq(result, false)
			end)
	end)

	for _, outcome in ipairs({"false", "nil", "throw"}) do
		helpers.it("HS-033 Delete restores every boundary after menu " .. outcome, function()
			with_delete_fixture({active_profile = "basic"}, function(fixture, delete_action, old_handle)
				local old_profiles = fixture.state.llm_user_profiles
				local old_shortcut = fixture.state.llm_profile_shortcuts.user_p
				fixture.plan_save({"ok", "ok"})
				fixture.plan_menu({outcome, "ok"})

				local result = delete_action()
				helpers.assert_true(fixture.get_profile_hk("user_p") == old_handle)
				helpers.assert_true(fixture.state.llm_user_profiles == old_profiles)
				helpers.assert_true(fixture.state.llm_profile_shortcuts.user_p == old_shortcut)
				helpers.assert_true(fixture.get_runtime_profiles() == old_profiles)
				helpers.assert_eq(old_handle.deleted, false)
				helpers.assert_eq(fixture.get_menu_snapshot().llm_user_profiles,
					{{id = "user_p", label = "Profile P"}})
				helpers.assert_eq(result, false)
			end)
		end)
	end

	helpers.it("HS-033 Delete commits fallback, registry, shortcut, and exact release once", function()
		with_delete_fixture({active_profile = "user_p", real_switcher = true}, function(fixture, delete_action, old_handle)
			fixture.plan_save({"ok"})
			fixture.plan_menu({"ok"})

			local result = delete_action()
			helpers.assert_eq(fixture.state.llm_active_profile, "basic")
			helpers.assert_eq(fixture.get_runtime_profile(), "basic")
			helpers.assert_eq(#fixture.state.llm_user_profiles, 0)
			helpers.assert_eq(#fixture.get_runtime_profiles(), 0)
			helpers.assert_nil(fixture.state.llm_profile_shortcuts.user_p)
			helpers.assert_nil(fixture.get_profile_hk("user_p"))
			helpers.assert_true(old_handle.deleted)
			helpers.assert_eq(#fixture.durable().llm_user_profiles, 0)
			helpers.assert_eq(fixture.durable().llm_active_profile, "basic")
			helpers.assert_eq(fixture.get_save_count(), 1,
				"the parent deletion must own the only persistence publication")
			helpers.assert_eq(fixture.get_menu_count(), 1,
				"the parent deletion must own the only menu publication")
			helpers.assert_eq(#fixture.get_menu_snapshot().llm_user_profiles, 0)
			helpers.assert_eq(#fixture.get_set_profiles_calls(), 1,
				"the replacement registry must publish through set_user_profiles exactly once")
			helpers.assert_true(fixture.get_set_profiles_calls()[1]
				== fixture.state.llm_user_profiles)
			fixture.fire(old_handle)
			helpers.assert_eq(fixture.get_prediction_count(), 0)
			helpers.assert_eq(result, true)
		end)
	end)

	helpers.it("HS-033 failed active Delete cancels deferred intent before a pending recommendation", function()
		with_delete_fixture({
			active_profile = "user_p",
			pending_model = true,
			real_switcher = true,
		}, function(fixture, delete_action)
			helpers.assert_eq(fixture.switcher.switch_model("starcoder2-3b"), true)
			helpers.assert_type(fixture.pending["starcoder2-3b"], "table")
			fixture.plan_save({"restore_false", "ok"})

			helpers.assert_eq(delete_action(), false)
			helpers.assert_eq(fixture.state.llm_active_profile, "user_p")
			helpers.assert_eq(fixture.get_runtime_profile(), "user_p")
			helpers.assert_eq(fixture.pending["starcoder2-3b"].success(), true)
			helpers.assert_eq(fixture.state.llm_model, "starcoder2-3b")
			helpers.assert_eq(fixture.state.llm_active_profile, "raw",
				"a rolled-back Delete must not suppress the older pending recommendation")
			helpers.assert_eq(fixture.get_runtime_profile(), "raw")
		end)
	end)

	helpers.it("HS-033 committed active Delete commits deferred intent before a pending recommendation", function()
		with_delete_fixture({
			active_profile = "user_p",
			pending_model = true,
			real_switcher = true,
		}, function(fixture, delete_action)
			helpers.assert_eq(fixture.switcher.switch_model("starcoder2-3b"), true)
			helpers.assert_type(fixture.pending["starcoder2-3b"], "table")
			fixture.plan_save({"ok"})

			helpers.assert_eq(delete_action(), true)
			helpers.assert_eq(fixture.state.llm_active_profile, "basic")
			helpers.assert_eq(fixture.pending["starcoder2-3b"].success(), true)
			helpers.assert_eq(fixture.state.llm_model, "starcoder2-3b")
			helpers.assert_eq(fixture.state.llm_active_profile, "basic",
				"the committed Delete intent must suppress its older recommendation")
			helpers.assert_eq(fixture.get_runtime_profile(), "basic")
		end)
	end)

	helpers.it("HS-033 sibling selection refuses retained Delete debt before it can publish", function()
		with_delete_fixture({active_profile = "basic", real_switcher = true},
			function(fixture, delete_action, old_handle, _, advanced_action)
				fixture.backend.plan("delete", {"false", "ok"})
				fixture.plan_save({"ok", "false", "false", "ok", "ok"})

				helpers.assert_eq(delete_action(), false)
				helpers.assert_true(fixture.get_profile_hk("user_p") == old_handle)
				helpers.assert_eq(fixture.state.llm_active_profile, "basic")
				helpers.assert_eq(advanced_action(), false)
				helpers.assert_eq(fixture.state.llm_active_profile, "basic",
					"a sibling selection must not publish over retained Delete debt")
				helpers.assert_eq(fixture.get_runtime_profile(), "basic")
				helpers.assert_true(fixture.get_profile_hk("user_p") == old_handle)

				helpers.assert_eq(advanced_action(), true)
				helpers.assert_eq(fixture.state.llm_active_profile, "advanced")
				helpers.assert_eq(fixture.get_runtime_profile(), "advanced")
				helpers.assert_eq(delete_action(), true)
				helpers.assert_eq(fixture.state.llm_active_profile, "advanced",
					"settled rollback must never replay stale active-profile state")
				helpers.assert_nil(fixture.get_profile_hk("user_p"))
				helpers.assert_true(old_handle.deleted)
			end)
	end)

	helpers.it("HS-033 recommendation no-op gates Delete debt before opening a dialog", function()
		with_delete_fixture({active_profile = "basic", real_switcher = true},
			function(fixture, delete_action, old_handle)
				fixture.backend.plan("delete", {"false"})
				fixture.plan_save({"ok", "false", "false", "ok"})

				helpers.assert_eq(delete_action(), false)
				helpers.assert_eq(fixture.switcher.apply_recommended_prompt_profile("A", {
					force_dialog = true,
				}), false)
				helpers.assert_eq(fixture.get_recommendation_dialog_count(), 0,
					"an unsettled Delete owner must fence the recommendation UI")
				helpers.assert_eq(fixture.state.llm_active_profile, "basic")
				helpers.assert_true(fixture.get_profile_hk("user_p") == old_handle)

				helpers.assert_eq(fixture.switcher.apply_recommended_prompt_profile("A", {
					force_dialog = true,
				}), true)
				helpers.assert_eq(fixture.get_recommendation_dialog_count(), 1)
				helpers.assert_eq(fixture.state.llm_active_profile, "basic")
			end)
	end)

	helpers.it("HS-033 inactive Delete settles real switcher debt before registry or native mutation", function()
		with_delete_fixture({active_profile = "basic", real_switcher = true},
			function(fixture, delete_action, old_handle)
				local old_profiles = fixture.state.llm_user_profiles
				fixture.plan_save({"false", "false"})
				helpers.assert_eq(fixture.switcher.set_llm_profile("advanced"), false)
				helpers.assert_eq(fixture.state.llm_active_profile, "basic")
				helpers.assert_eq(fixture.get_runtime_profile(), "basic")

				fixture.reset_observations()
				fixture.plan_save({"false", "ok", "ok"})
				helpers.assert_eq(delete_action(), false)
				helpers.assert_true(fixture.state.llm_user_profiles == old_profiles)
				helpers.assert_true(fixture.get_profile_hk("user_p") == old_handle)
				helpers.assert_eq(#fixture.get_set_profiles_calls(), 0,
					"Delete must not publish a registry over switcher debt")
				helpers.assert_eq(#fixture.backend.calls, 0,
					"Delete must not acquire or suspend a shortcut over switcher debt")
				helpers.assert_eq(fixture.get_save_count(), 1,
					"only the pre-existing switcher compensation may retry")

				helpers.assert_eq(delete_action(), true)
				helpers.assert_nil(fixture.get_profile_hk("user_p"))
				helpers.assert_true(old_handle.deleted)
			end)
	end)

	helpers.it("HS-033 Delete retries retained persistence/native debt before a new attempt", function()
		with_delete_fixture({active_profile = "basic"}, function(fixture, delete_action, old_handle)
			fixture.backend.plan("delete", {"false", "ok"})
			fixture.plan_save({"ok", "false", "ok", "ok"})

			local first_result = delete_action()
			helpers.assert_true(fixture.get_profile_hk("user_p") == old_handle)
			helpers.assert_eq(first_result, false)
			helpers.assert_eq(delete_action(), true)
			helpers.assert_nil(fixture.get_profile_hk("user_p"))
			helpers.assert_true(old_handle.deleted)
			helpers.assert_eq(#fixture.state.llm_user_profiles, 0)
			helpers.assert_eq(#fixture.durable().llm_user_profiles, 0)
			local final_profiles = fixture.state.llm_user_profiles
			local final_publications = 0
			for _, profiles in ipairs(fixture.get_set_profiles_calls()) do
				if profiles == final_profiles then final_publications = final_publications + 1 end
			end
			helpers.assert_eq(final_publications, 1,
				"the retried successor registry must commit exactly once")
		end)
	end)
end)


return true
