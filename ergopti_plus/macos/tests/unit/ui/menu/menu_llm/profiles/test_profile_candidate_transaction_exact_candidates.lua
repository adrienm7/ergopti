--- tests/unit/ui/menu/menu_llm/profiles/test_profile_candidate_transaction_exact_candidates.lua

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
local assert_clean_refusal = Fixture.assert_clean_refusal
local clone = Fixture.clone
local find_child_row = Fixture.find_child_row
local find_row = Fixture.find_row
local retain_clone_candidate = Fixture.retain_clone_candidate
local with_fixture = Fixture.with_fixture





helpers.describe("HS-034 profile candidates are exact recoverable transactions", function()
	local retained_editor_timer_cases = {
		{
			name = "Clone",
			options = {},
			invoke = function(fixture)
				return find_row(fixture.manager.get_menu_item().menu,
					"menu.profiles.clone_builtin").action()
			end,
		},
		{
			name = "Edit",
			options = {initial_profiles = {{id = "custom", label = "Custom"}}},
			invoke = function(fixture)
				return find_child_row(fixture.manager.get_menu_item().menu,
					"Custom", "menu.profiles.edit_profile").action()
			end,
		},
		{
			name = "Create",
			options = {},
			invoke = function(fixture)
				return find_row(fixture.manager.get_menu_item().menu,
					"menu.profiles.create_profile").action()
			end,
		},
	}
	for _, case in ipairs(retained_editor_timer_cases) do
		helpers.it("HS-017 retains the " .. case.name
			.. " editor timer after its caller drops the handle", function()
			local options = clone(case.options)
			options.weak_timer_registry = true
			with_fixture(options, function(fixture)
				helpers.assert_eq(case.invoke(fixture), true)
				helpers.assert_eq(fixture.timer_count(), 1,
					"the deferred editor must own one live native timer")
				fixture.collect_timers()
				helpers.assert_eq(fixture.timer_count(), 1,
					"GC must not erase a fire-and-forget editor continuation")
				fixture.fire_timer()
				helpers.assert_eq(fixture.editor_open_count(), 1,
					"the retained continuation must open the editor exactly once")
			end)
		end)
	end

	helpers.it("HS-034 removes a refused Clone candidate after clean runtime compensation", function()
		with_fixture({}, function(fixture)
			fixture.plan_runtime({
				{mode = "throw"},
				{mode = "ok"},
			})
			local clone_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.clone_builtin")
			helpers.assert_type(clone_row and clone_row.action, "function")

			helpers.assert_eq(clone_row.action(), false)
			assert_clean_refusal(fixture)
			helpers.assert_eq(fixture.editor_open_count(), 0,
				"a refused Clone must not open its follow-up editor")
			helpers.assert_eq(fixture.timer_count(), 0)
		end)
	end)

	helpers.it("HS-034 removes a refused Create candidate inside the editor timer", function()
		local candidate = {id = "user_created", label = "Created"}
		with_fixture({created_profiles = {candidate}}, function(fixture)
			fixture.plan_runtime({
				{mode = "throw"},
				{mode = "ok"},
			})
			local create_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.create_profile")
			helpers.assert_type(create_row and create_row.action, "function")

			create_row.action()
			helpers.assert_eq(fixture.timer_count(), 1)
			fixture.fire_timer()
			assert_clean_refusal(fixture)
			helpers.assert_eq(fixture.editor_open_count(), 1)
			helpers.assert_eq(fixture.editor_calls[1], false,
				"Create must obtain the candidate from the nil-profile editor")
		end)
	end)

	helpers.it("HS-034 retains one live candidate until compensation settles before a sibling Create", function()
		local successor = {id = "user_successor", label = "Successor"}
		with_fixture({created_profiles = {successor}}, function(fixture)
			fixture.plan_runtime({
				{mode = "throw"},
				{mode = "false", mutate = false},
				{mode = "false", mutate = false},
				{mode = "ok"},
				{mode = "ok"},
			})
			local rows = fixture.manager.get_menu_item().menu
			local clone_row = find_row(rows, "menu.profiles.clone_builtin")
			local create_row = find_row(rows, "menu.profiles.create_profile")
			helpers.assert_type(clone_row and clone_row.action, "function")
			helpers.assert_type(create_row and create_row.action, "function")

			helpers.assert_eq(clone_row.action(), false)
			helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
			local retained = fixture.state.llm_user_profiles[1]
			helpers.assert_true(fixture.get_runtime_profile() == retained,
				"the exact runtime-live candidate must remain owned")
			helpers.assert_eq(fixture.save_count(), 0)
			helpers.assert_eq(fixture.menu_count(), 0)

			helpers.assert_eq(create_row.action(), false)
			helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
			helpers.assert_true(fixture.state.llm_user_profiles[1] == retained,
				"a refused entry gate must block the sibling candidate insertion")
			helpers.assert_true(fixture.get_runtime_profile() == retained)
			helpers.assert_eq(fixture.timer_count(), 0,
				"a blocked Create must not even acquire its editor timer")
			helpers.assert_eq(fixture.save_count(), 0)
			helpers.assert_eq(fixture.menu_count(), 0)

			helpers.assert_eq(create_row.action(), true)
			fixture.fire_timer()
			helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
			helpers.assert_true(fixture.state.llm_user_profiles[1] == successor,
				"settlement must retire only the old candidate before the sibling commits")
			helpers.assert_true(fixture.state.llm_user_profiles[1] ~= retained)
			helpers.assert_true(fixture.get_runtime_profile() == successor)
			helpers.assert_eq(fixture.save_count(), 1)
			helpers.assert_eq(fixture.menu_count(), 1)
			helpers.assert_eq(fixture.notifications(), 1)
		end)
	end)

	local void_refusal_modes = {"false", "nil", "throw"}
	for _, mode in ipairs(void_refusal_modes) do
		helpers.it("HS-034 contains a " .. mode .. " runtime activation refusal", function()
			with_fixture({}, function(fixture)
				fixture.plan_runtime({
					{mode = mode},
					{mode = "ok"},
				})
				local clone_row = find_row(fixture.manager.get_menu_item().menu,
					"menu.profiles.clone_builtin")
				helpers.assert_eq(clone_row.action(), false)
				assert_clean_refusal(fixture)
				helpers.assert_eq(fixture.editor_open_count(), 0)
			end)
		end)

		helpers.it("HS-034 contains a " .. mode .. " menu refusal", function()
			with_fixture({}, function(fixture)
				fixture.plan_runtime({
					{mode = "ok"},
					{mode = "ok"},
				})
				fixture.plan_menu({{mode = mode}})
				local clone_row = find_row(fixture.manager.get_menu_item().menu,
					"menu.profiles.clone_builtin")
				helpers.assert_eq(clone_row.action(), false)
				assert_clean_refusal(fixture, {saves = 3, menus = 3})
				helpers.assert_eq(fixture.editor_open_count(), 0)
			end)
		end)
	end

	local strict_refusal_modes = {"false", "nil", "throw"}
	for _, mode in ipairs(strict_refusal_modes) do
		helpers.it("HS-034 contains a " .. mode .. " preference refusal", function()
			with_fixture({}, function(fixture)
				fixture.plan_runtime({
					{mode = "ok"},
					{mode = "ok"},
				})
				fixture.plan_save({{mode = mode}})
				local clone_row = find_row(fixture.manager.get_menu_item().menu,
					"menu.profiles.clone_builtin")
				helpers.assert_eq(clone_row.action(), false)
				assert_clean_refusal(fixture, {saves = 3})
				helpers.assert_eq(fixture.editor_open_count(), 0)
			end)
		end)

		helpers.it("HS-034 contains a " .. mode .. " runtime-registry publication refusal", function()
			with_fixture({}, function(fixture)
				fixture.plan_set_profiles({{mode = mode}})
				local clone_row = find_row(fixture.manager.get_menu_item().menu,
					"menu.profiles.clone_builtin")
				helpers.assert_eq(clone_row.action(), false)
				assert_clean_refusal(fixture)
				helpers.assert_eq(fixture.editor_open_count(), 0)
			end)
		end)
	end

	helpers.it("HS-034 rejects nil from the strict public profile transaction", function()
		with_fixture({}, function(fixture)
			fixture.deps.set_llm_profile = function() return nil end
			local clone_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.clone_builtin")
			helpers.assert_eq(clone_row.action(), false)
			assert_clean_refusal(fixture)
			helpers.assert_eq(fixture.editor_open_count(), 0)
		end)
	end)

	for _, gate_key in ipairs({
		"settle_profile_delete_recovery",
		"settle_profile_candidate_recovery",
		"settle_profile_edit_recovery",
		"settle_llm_switcher_recovery",
	}) do
		helpers.it("HS-034 rejects nil from the strict " .. gate_key .. " gate", function()
			with_fixture({}, function(fixture)
				fixture.deps[gate_key] = function() return nil end
				local clone_row = find_row(fixture.manager.get_menu_item().menu,
					"menu.profiles.clone_builtin")
				helpers.assert_eq(clone_row.action(), false)
				assert_clean_refusal(fixture)
				helpers.assert_eq(fixture.timer_count(), 0)
			end)
		end)
	end

	helpers.it("HS-034 accepts nil only from the editor after exact runtime and menu commits", function()
		local candidate = {id = "user_void_success", label = "Void Success"}
		with_fixture({
			created_profiles = {candidate},
			editor_returns_nil = true,
		}, function(fixture)
			fixture.plan_runtime({{mode = "ok"}})
			fixture.plan_menu({{mode = "ok"}})
			local create_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.create_profile")
			helpers.assert_eq(create_row.action(), true)
			fixture.fire_timer()
			helpers.assert_true(fixture.state.llm_user_profiles[1] == candidate)
			helpers.assert_true(fixture.runtime_profiles()[1] == candidate)
			helpers.assert_eq(fixture.state.llm_active_profile, candidate.id)
			helpers.assert_eq(fixture.get_runtime_profile().id, candidate.id)
			helpers.assert_eq(fixture.durable().llm_user_profiles[1].id, candidate.id)
			helpers.assert_eq(fixture.rendered().llm_user_profiles[1].id, candidate.id)
			helpers.assert_eq(fixture.save_count(), 1)
			helpers.assert_eq(fixture.menu_count(), 1)
			helpers.assert_eq(fixture.notifications(), 1)
		end)
	end)

	helpers.it("HS-034 survives the real in-place preference rollback mutating its candidate table", function()
		with_fixture({}, function(fixture)
			fixture.plan_runtime({
				{mode = "ok"},
				{mode = "ok"},
			})
			fixture.plan_save({{mode = "false"}})
			local clone_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.clone_builtin")
			helpers.assert_eq(clone_row.action(), false)
			local publication = fixture.set_profiles_calls()[1]
			helpers.assert_type(publication, "table")
			helpers.assert_eq(#publication.profiles, 0,
				"PreferencesTransaction must have restored the published table in place")
			assert_clean_refusal(fixture, {saves = 3})
		end)
	end)

	helpers.it("HS-034 removes only the exact same-ID candidate and preserves the prior table identity", function()
		local previous = {id = "user_created", label = "Previous"}
		local old_registry = {previous}
		local candidate = {id = "user_created", label = "Candidate"}
		with_fixture({
			initial_profiles = old_registry,
			created_profiles = {candidate},
		}, function(fixture)
			fixture.plan_set_profiles({{mode = "false"}})
			local create_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.create_profile")
			helpers.assert_eq(create_row.action(), true)
			fixture.fire_timer()
			assert_clean_refusal(fixture, {profiles = {previous}})
			helpers.assert_true(fixture.state.llm_user_profiles == old_registry)
			helpers.assert_true(fixture.state.llm_user_profiles[1] == previous)
			helpers.assert_true(fixture.state.llm_user_profiles[1] ~= candidate)
		end)
	end)

	helpers.it("HS-034 latches duplicate native timer and Create editor callbacks", function()
		local first = {id = "user_first", label = "First"}
		local duplicate = {id = "user_duplicate", label = "Duplicate"}
		with_fixture({
			created_profiles = {first, duplicate},
			timer_double_callback = true,
			editor_double_callback = true,
		}, function(fixture)
			local create_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.create_profile")
			helpers.assert_eq(create_row.action(), true)
			helpers.assert_eq(fixture.timer_count(), 1)
			fixture.fire_timer()
			helpers.assert_eq(fixture.editor_open_count(), 1)
			helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
			helpers.assert_true(fixture.state.llm_user_profiles[1] == first)
			helpers.assert_true(fixture.state.llm_user_profiles[1] ~= duplicate)
			helpers.assert_eq(fixture.notifications(), 1)
			helpers.assert_eq(fixture.save_count(), 1)
			helpers.assert_eq(fixture.menu_count(), 1)
		end)
	end)

	helpers.it("HS-075 refuses a duplicate Edit callback inside a refusing transaction", function()
		local original = {id = "custom", label = "Original"}
		local updated = {id = "custom", label = "Updated"}
		with_fixture({
			initial_profiles = {original},
			editor_update = updated,
			editor_reentrant_callback = true,
		}, function(fixture)
			fixture.plan_save({
				{mode = "false"},
				{mode = "ok"},
			})
			local edit_row = find_child_row(fixture.manager.get_menu_item().menu,
				"Original", "menu.profiles.edit_profile")
			helpers.assert_eq(edit_row.action(), true)
			fixture.fire_timer()

			helpers.assert_eq(#fixture.editor_reentrant_results, 1,
				"the duplicate must arrive before the first preference refusal returns")
			helpers.assert_eq(fixture.editor_reentrant_results[1], false)
			helpers.assert_eq(fixture.state.llm_user_profiles[1], original,
				"an in-flight duplicate must not escape the refused edit rollback")
			helpers.assert_true(fixture.state.llm_user_profiles[1] == original,
				"the refused edit must preserve the exact original profile identity")
			helpers.assert_eq(fixture.notifications(), 0,
				"a refused edit must not become a later duplicate success")
			helpers.assert_eq(fixture.save_count(), 2,
				"only the failed publication and its rollback may reach persistence")
		end)
	end)

	for _, mode in ipairs(strict_refusal_modes) do
		helpers.it("HS-034 retains registry debt when its cleanup save " .. mode
			.. " refuses, then retries exactly", function()
			with_fixture({}, function(fixture)
				fixture.plan_runtime({
					{mode = "ok"},
					{mode = "ok"},
				})
				fixture.plan_save({
					{mode = "ok"},
					{mode = "ok"},
					{mode = mode},
					{mode = "ok"},
				})
				fixture.plan_menu({
					{mode = "false"},
					{mode = "ok"},
					{mode = "ok"},
				})
				local clone_row = find_row(fixture.manager.get_menu_item().menu,
					"menu.profiles.clone_builtin")
				helpers.assert_eq(clone_row.action(), false)
				helpers.assert_eq(#fixture.state.llm_user_profiles, 0,
					"live state is reasserted even while durable cleanup remains pending")
				helpers.assert_eq(#fixture.durable().llm_user_profiles, 1,
					"the failed cleanup save must remain visible as durable debt")
				helpers.assert_eq(fixture.deps.settle_profile_candidate_recovery(), true)
				assert_clean_refusal(fixture, {saves = 4, menus = 3})
			end)
		end)
	end

	helpers.it("HS-034 retains cleanup debt when the strict save callback returns nil", function()
		with_fixture({}, function(fixture)
			fixture.plan_runtime({
				{mode = "ok"},
				{mode = "ok"},
			})
			fixture.plan_menu({
				{mode = "false"},
				{mode = "ok"},
				{mode = "ok"},
			})
			local transactional_save = fixture.deps.save_prefs
			fixture.deps.save_prefs = function() return nil end
			local clone_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.clone_builtin")
			helpers.assert_eq(clone_row.action(), false)
			helpers.assert_eq(#fixture.state.llm_user_profiles, 0)
			helpers.assert_eq(#fixture.durable().llm_user_profiles, 1)
			helpers.assert_eq(fixture.deps.settle_profile_candidate_recovery(), false,
				"a literal nil cleanup result must retain the exact registry debt")
			fixture.deps.save_prefs = transactional_save
			helpers.assert_eq(fixture.deps.settle_profile_candidate_recovery(), true)
			assert_clean_refusal(fixture, {saves = 3, menus = 3})
		end)
	end)

	for _, mode in ipairs(strict_refusal_modes) do
		helpers.it("HS-034 retries a " .. mode .. " exact runtime-registry rollback", function()
			with_fixture({}, function(fixture)
				fixture.plan_set_profiles({
					{mode = "false"},
					{mode = mode, mutate = false},
					{mode = "ok"},
				})
				local clone_row = find_row(fixture.manager.get_menu_item().menu,
					"menu.profiles.clone_builtin")
				helpers.assert_eq(clone_row.action(), false)
				helpers.assert_eq(#fixture.runtime_profiles(), 1,
					"a mutate-then-refuse publication remains the exact runtime debt")
				helpers.assert_eq(fixture.deps.settle_profile_candidate_recovery(), true)
				assert_clean_refusal(fixture)
			end)
		end)
	end

	for _, mode in ipairs(strict_refusal_modes) do
		helpers.it("HS-034 retries a " .. mode
			.. " switcher preference compensation before candidate cleanup", function()
			with_fixture({}, function(fixture)
				fixture.plan_runtime({
					{mode = "ok"},
					{mode = "ok"},
					{mode = "ok"},
					{mode = "ok"},
				})
				fixture.plan_save({
					{mode = "ok"},
					{mode = mode},
					{mode = "ok"},
					{mode = "ok"},
				})
				fixture.plan_menu({
					{mode = "false"},
					{mode = "ok"},
					{mode = "ok"},
				})
				local clone_row = find_row(fixture.manager.get_menu_item().menu,
					"menu.profiles.clone_builtin")
				helpers.assert_eq(clone_row.action(), false)
				helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
				helpers.assert_eq(fixture.deps.settle_profile_candidate_recovery(), true)
				assert_clean_refusal(fixture, {saves = 4, menus = 3})
			end)
		end)
	end

	helpers.it("HS-034 retries a refused switcher menu compensation before candidate cleanup", function()
		with_fixture({}, function(fixture)
			fixture.plan_runtime({
				{mode = "ok"},
				{mode = "ok"},
			})
			fixture.plan_save({
				{mode = "ok"},
				{mode = "ok"},
				{mode = "ok"},
			})
			fixture.plan_menu({
				{mode = "false"},
				{mode = "false"},
				{mode = "ok"},
				{mode = "ok"},
			})
			local clone_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.clone_builtin")
			helpers.assert_eq(clone_row.action(), false)
			helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
			helpers.assert_eq(fixture.deps.settle_profile_candidate_recovery(), true)
			assert_clean_refusal(fixture, {saves = 3, menus = 4})
		end)
	end)

	local sibling_entry_specs = {
		{
			name = "built-in selection",
			invoke = function(_, rows)
				return find_row(rows, "Advanced").action()
			end,
		},
		{
			name = "Auto-detect",
			invoke = function(_, rows)
				return find_row(rows, "menu.profiles.auto_detect").action()
			end,
		},
		{
			name = "shortcut editor",
			invoke = function(_, rows, retained)
				return find_child_row(rows, retained.label,
					"menu.profiles.shortcut_prefix").action()
			end,
		},
		{
			name = "profile editor",
			invoke = function(_, rows, retained)
				return find_child_row(rows, retained.label,
					"menu.profiles.edit_profile").action()
			end,
		},
		{
			name = "Delete",
			invoke = function(_, rows, retained)
				return find_child_row(rows, retained.label,
					"menu.profiles.delete_profile").action()
			end,
		},
		{
			name = "Clone",
			invoke = function(_, rows)
				return find_row(rows, "menu.profiles.clone_builtin").action()
			end,
		},
		{
			name = "Create",
			invoke = function(_, rows)
				return find_row(rows, "menu.profiles.create_profile").action()
			end,
		},
	}
	for _, spec in ipairs(sibling_entry_specs) do
		helpers.it("HS-034 gates sibling " .. spec.name .. " before its first effect", function()
			with_fixture({}, function(fixture)
				local retained = retain_clone_candidate(fixture)
				fixture.plan_runtime({{mode = "false", mutate = false}})
				local rows = fixture.manager.get_menu_item().menu
				helpers.assert_eq(spec.invoke(fixture, rows, retained), false)
				helpers.assert_true(fixture.state.llm_user_profiles[1] == retained)
				helpers.assert_eq(fixture.shortcut_prompt_count(), 0)
				helpers.assert_eq(fixture.timer_count(), 0)
				helpers.assert_eq(fixture.delete_dialog_count(), 0)
				helpers.assert_eq(fixture.notifications(), 0)
				helpers.assert_eq(fixture.requirements_count(), 0)
			end)
		end)
	end

	helpers.it("HS-034 gates the deferred shortcut continuation", function()
		local custom = {id = "custom", label = "Custom"}
		with_fixture({initial_profiles = {custom}}, function(fixture)
			local shortcut_row = find_child_row(fixture.manager.get_menu_item().menu,
				"Custom", "menu.profiles.shortcut_prefix")
			helpers.assert_eq(shortcut_row.action(), false)
			local spec = fixture.last_shortcut_spec()
			helpers.assert_type(spec and spec.on_apply, "function")
			-- The prompt caption comes from the shared native presentation, never
			-- a title the menu code labels itself (native-menu-rows census).
			helpers.assert_eq(spec.native_presentation_id, "profile_shortcut_dialog")
			helpers.assert_nil(spec.title)
			retain_clone_candidate(fixture)
			fixture.plan_runtime({{mode = "false", mutate = false}})
			helpers.assert_eq(spec.on_apply({"ctrl"}, "k"), false)
			helpers.assert_eq(fixture.shortcut_apply_count(), 0)
		end)
	end)

	helpers.it("HS-034 gates the deferred Edit continuation before opening the editor", function()
		local custom = {id = "custom", label = "Custom"}
		with_fixture({initial_profiles = {custom}}, function(fixture)
			local edit_row = find_child_row(fixture.manager.get_menu_item().menu,
				"Custom", "menu.profiles.edit_profile")
			helpers.assert_eq(edit_row.action(), true)
			helpers.assert_eq(fixture.timer_count(), 1)
			retain_clone_candidate(fixture)
			fixture.plan_runtime({{mode = "false", mutate = false}})
			fixture.fire_timer()
			helpers.assert_eq(fixture.editor_open_count(), 0)
		end)
	end)

	helpers.it("HS-034 gates the deferred Create continuation before opening the editor", function()
		with_fixture({}, function(fixture)
			local create_row = find_row(fixture.manager.get_menu_item().menu,
				"menu.profiles.create_profile")
			helpers.assert_eq(create_row.action(), true)
			helpers.assert_eq(fixture.timer_count(), 1)
			retain_clone_candidate(fixture)
			fixture.plan_runtime({{mode = "false", mutate = false}})
			fixture.fire_timer()
			helpers.assert_eq(fixture.editor_open_count(), 0)
		end)
	end)

	helpers.it("HS-034 gates switch_model before requirements dispatch", function()
		with_fixture({}, function(fixture)
			local retained = retain_clone_candidate(fixture)
			fixture.plan_runtime({{mode = "false", mutate = false}})
			helpers.assert_eq(fixture.switcher.switch_model("B"), false)
			helpers.assert_true(fixture.state.llm_user_profiles[1] == retained)
			helpers.assert_eq(fixture.requirements_count(), 0)
			helpers.assert_eq(#fixture.keymap_model_calls, 0)
			helpers.assert_eq(#fixture.keymap_display_calls, 0)
		end)
	end)

	helpers.it("HS-034 gates No Model before runtime publication", function()
		with_fixture({}, function(fixture)
			local retained = retain_clone_candidate(fixture)
			fixture.plan_runtime({{mode = "false", mutate = false}})
			helpers.assert_eq(fixture.switcher.disable_model(), false)
			helpers.assert_true(fixture.state.llm_user_profiles[1] == retained)
			helpers.assert_eq(#fixture.keymap_model_calls, 0)
			helpers.assert_eq(#fixture.keymap_display_calls, 0)
		end)
	end)

	helpers.it("HS-034 gates a pending model success continuation", function()
		with_fixture({}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			helpers.assert_eq(fixture.requirements_count(), 1)
			local callback = fixture.requirements_callbacks[1].on_ok
			local retained = retain_clone_candidate(fixture)
			fixture.plan_runtime({{mode = "false", mutate = false}})
			helpers.assert_eq(callback(), false)
			helpers.assert_true(fixture.state.llm_user_profiles[1] == retained)
			helpers.assert_eq(fixture.state.llm_model, "A")
			helpers.assert_eq(#fixture.keymap_model_calls, 0)
			helpers.assert_eq(#fixture.keymap_display_calls, 0)
		end)
	end)

	helpers.it("HS-034 settles candidate recovery before a pending model continuation commits", function()
		with_fixture({}, function(fixture)
			helpers.assert_eq(fixture.switcher.switch_model("B"), true)
			local callback = fixture.requirements_callbacks[1].on_ok
			retain_clone_candidate(fixture)
			fixture.plan_runtime({{mode = "ok"}})
			helpers.assert_eq(callback(), true)
			helpers.assert_eq(#fixture.state.llm_user_profiles, 0)
			helpers.assert_eq(#fixture.runtime_profiles(), 0)
			helpers.assert_eq(fixture.state.llm_model, "B")
			helpers.assert_eq(fixture.keymap_model_calls, {"B"})
			helpers.assert_eq(fixture.keymap_display_calls, {"B"})
		end)
	end)
end)
