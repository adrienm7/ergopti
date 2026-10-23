--- tests/unit/ui/menu/menu_llm/profiles/test_profile_editor_save_retry.lua

--- ==============================================================================
--- MODULE: Profile Editor Save Retry Regression
--- DESCRIPTION:
--- A refused profile transaction keeps the same public editor draft retryable.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.ui.menu.menu_llm.profiles.profile_editor_retry_fixture")

--- Opens one profile editor through its normal menu action and native navigation.
--- @param kind string edit, clone or create.
--- @param fixture table Existing transaction fixture.
--- @param native table Real editor observations over native UI ports.
local function open_editor(kind, fixture, native)
	local rows = fixture.manager.get_menu_item().menu
	local row
	if kind == "edit" then
		row = Fixture.find_child_row(rows, "Original", "menu.profiles.edit_profile")
	else
		row = Fixture.find_row(rows, kind == "clone" and "menu.profiles.clone_builtin"
			or "menu.profiles.create_profile")
	end
	helpers.assert_type(row and row.action, "function")
	helpers.assert_true(row.action())
	fixture.fire_timer()
	helpers.assert_eq(#native.views, 1)
	native.views[1].options.on_navigation("didFinishNavigation")
	helpers.assert_type(native.context, "table")
end

helpers.describe("profile editor rejected Save remains retryable", function()
	helpers.it("(profile-editor-save-retry) refuses direct in-flight Save reentry before readiness effects", function()
		Fixture.with_fixture({}, function(fixture, native)
			open_editor("create", fixture, native)
			local attempted, nested = false, nil
			fixture.deps.script_control.is_paused = function()
				if not attempted then
					attempted = true
					nested = native.save_callbacks[1]({ id = assert(native.last_save_payload).id,
						label = "Nested draft", raw_prompt = "nested" })
				end
				return false
			end
			native.save("Outer draft")
			helpers.assert_true(attempted, "the real Save must read its current admission")
			helpers.assert_eq(nested, false, "one business Save callback cannot reenter its own transaction")
			helpers.assert_eq(fixture.save_count(), 1)
			helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
			helpers.assert_eq(fixture.durable().llm_user_profiles[1].label, "Outer draft")
			helpers.assert_eq(native.deletes, 1)
		end)
	end)

	helpers.it("(profile-editor-save-retry) drains retained rollback debt before accepting a later Save", function()
		local original = { id = "custom", label = "Original" }
		Fixture.with_fixture({ initial_profiles = { original } }, function(fixture, native)
			open_editor("edit", fixture, native)
			fixture.plan_set_profiles({ { mode = "false" }, { mode = "false", mutate = false } })
			native.save("Unaccepted draft")
			helpers.assert_eq(native.deletes, 0)
			helpers.assert_eq(fixture.save_count(), 0)
			helpers.assert_true(fixture.state.llm_user_profiles[1] == original)
			helpers.assert_eq(fixture.manager.scope_idle(), false, "a refused native rollback retains its exact owner")
			local before = #fixture.set_profiles_calls()
			fixture.plan_set_profiles({ { mode = "false", mutate = false } })
			native.save("Still blocked draft")
			helpers.assert_eq(#fixture.set_profiles_calls(), before + 1,
				"retry must reach the retained rollback owner before another mutation")
			helpers.assert_eq(fixture.save_count(), 0)
			helpers.assert_eq(native.deletes, 0)
			fixture.plan_set_profiles({})
			native.save("Recovered draft")
			helpers.assert_eq(fixture.save_count(), 1)
			helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
			helpers.assert_eq(fixture.durable().llm_user_profiles[1].label, "Recovered draft")
			helpers.assert_eq(native.deletes, 1)
			helpers.assert_true(fixture.manager.scope_idle())
		end)
	end)

	for _, kind in ipairs({ "edit", "clone", "create" }) do
		for _, refusal in ipairs({ "false", "throw" }) do
			helpers.it("(profile-editor-save-retry) retries " .. kind .. " after a preference " .. refusal, function()
				local initial = kind == "edit" and { { id = "custom", label = "Original" } } or {}
				Fixture.with_fixture({ initial_profiles = initial }, function(fixture, native)
					open_editor(kind, fixture, native)
					local context = native.context
					local accepted = Fixture.clone(fixture.state.llm_user_profiles)
					local original = fixture.state.llm_user_profiles[1]
					fixture.plan_save({ { mode = refusal } })
					native.save("Refused draft")
					helpers.assert_eq(native.deletes, 0, "a refused Save keeps its public editor open")
					helpers.assert_eq(fixture.state.llm_user_profiles, accepted)
					helpers.assert_true(fixture.state.llm_user_profiles[1] == original,
						"completed rollback retains the exact accepted profile table")
					local before = fixture.save_count()
					native.save("Accepted retry")
					helpers.assert_eq(fixture.save_count(), before + 1,
						"the same editor draft must reach one healthy preference commit after refusal")
					helpers.assert_true(native.context == context, "retry keeps the original page target and epoch")
					helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
					helpers.assert_eq(fixture.state.llm_user_profiles[1].label, "Accepted retry")
					helpers.assert_eq(fixture.durable().llm_user_profiles[1].label, "Accepted retry")
					helpers.assert_eq(fixture.rendered().llm_user_profiles[1].label, "Accepted retry")
					helpers.assert_eq(native.deletes, 1, "successful retry closes the original native editor")
					local saved = fixture.save_count()
					helpers.assert_eq(native.save_callbacks[1]({ id = fixture.state.llm_user_profiles[1].id,
						label = "Duplicate", raw_prompt = "duplicate" }), false)
					helpers.assert_eq(fixture.save_count(), saved, "a committed callback cannot publish twice")
				end)
			end)
		end

		helpers.it("(profile-editor-save-retry) preserves healthy " .. kind .. " Save and exact close", function()
			local initial = kind == "edit" and { { id = "custom", label = "Original" } } or {}
			Fixture.with_fixture({ initial_profiles = initial }, function(fixture, native)
				open_editor(kind, fixture, native)
				local before = fixture.save_count()
				native.save("Healthy draft")
				helpers.assert_eq(fixture.save_count(), before + 1)
				helpers.assert_eq(#fixture.state.llm_user_profiles, 1)
				helpers.assert_eq(fixture.durable().llm_user_profiles[1].label, "Healthy draft")
				helpers.assert_eq(native.deletes, 1)
				helpers.assert_true(native.editor.scope_idle())
			end)
		end)
	end
end)
