--- tests/unit/ui/menu/menu_llm/test_profile_delete_transaction.lua

--- ==============================================================================
--- MODULE: LLM Shortcut and Profile Deletion Transactions
--- DESCRIPTION:
--- Exercises the primary/profile shortcut owner and the real confirmed profile
--- Delete action through refusal-capable registrar seams. Real Hammerspoon-shaped
--- doubles keep enable=self|nil, disable=self, and delete=void|throw contracts.
--- Tests preserve handle identity and invoke retained callbacks so a
--- bookkeeping-only rollback cannot pass.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fixture = require("tests.support.profile_delete_fixture")
local with_trigger_fixture = Fixture.with_trigger_fixture
local with_delete_fixture = Fixture.with_delete_fixture

--- Seeds one shortcut family and returns uniform accessors for the matrix.
--- @param fixture table Trigger fixture.
--- @param family string primary or profile.
--- @return table slot
local function seed_family(fixture, family)
	if family == "primary" then
		fixture.state.llm_trigger_shortcut = false
		helpers.assert_eq(fixture.orchestrator.apply_llm_shortcut({"ctrl"}, "a", {
			persist = false,
		}), true)
		fixture.acknowledge()
		return {
			apply = function(mods, key, opts)
				return fixture.orchestrator.apply_llm_shortcut(mods, key, opts)
			end,
			get_handle = fixture.get_trigger_hk,
			get_pref = function() return fixture.state.llm_trigger_shortcut end,
		}
	end

	fixture.state.llm_profile_shortcuts = {}
	helpers.assert_eq(fixture.orchestrator.apply_llm_profile_shortcut(
		"user_p", {"ctrl"}, "a", {persist = false}), true)
	fixture.acknowledge()
	return {
		apply = function(mods, key, opts)
			return fixture.orchestrator.apply_llm_profile_shortcut("user_p", mods, key, opts)
		end,
		get_handle = function() return fixture.get_profile_hk("user_p") end,
		get_pref = function() return fixture.state.llm_profile_shortcuts.user_p end,
	}
end

--- Seeds one configured shortcut whose native delivery is intentionally inactive.
--- @param fixture table Trigger fixture.
--- @param family string primary or profile.
--- @return table slot
local function seed_inactive_family(fixture, family)
	if family == "primary" then
		fixture.set_startup_silence(true)
		helpers.assert_eq(fixture.orchestrator.apply_llm_shortcut({"ctrl"}, "a", {
			persist = false,
		}), true)
		fixture.set_startup_silence(false)
		return {
			get_handle = fixture.get_trigger_hk,
			get_pref = function() return fixture.state.llm_trigger_shortcut end,
		}
	end

	helpers.assert_eq(fixture.orchestrator.apply_llm_profile_shortcut(
		"user_p", {"ctrl"}, "a", {persist = false, silent = true}), true)
	return {
		get_handle = function() return fixture.get_profile_hk("user_p") end,
		get_pref = function() return fixture.state.llm_profile_shortcuts.user_p end,
	}
end

helpers.describe("HS-033 exact LLM shortcut transactions", function()
	for _, family in ipairs({"primary", "profile"}) do
		for _, outcome in ipairs({"false", "nil", "throw"}) do
			helpers.it("HS-033 " .. family .. " fresh bind rejects new " .. outcome, function()
				with_trigger_fixture({}, function(fixture)
					fixture.backend.plan("new", {outcome})
					local apply
					local get_handle
					local get_pref
					if family == "primary" then
						apply = fixture.orchestrator.apply_llm_shortcut
						get_handle = fixture.get_trigger_hk
						get_pref = function() return fixture.state.llm_trigger_shortcut end
					else
						apply = function(mods, key)
							return fixture.orchestrator.apply_llm_profile_shortcut("user_p", mods, key)
						end
						get_handle = function() return fixture.get_profile_hk("user_p") end
						get_pref = function() return fixture.state.llm_profile_shortcuts.user_p end
					end
					local result = apply({"ctrl"}, "b")
					helpers.assert_nil(get_handle())
					helpers.assert_true(get_pref() == false or get_pref() == nil)
					helpers.assert_eq(fixture.get_save_count(), 0)
					helpers.assert_eq(fixture.get_menu_count(), 0)
					helpers.assert_eq(result, false)
				end)
			end)

			helpers.it("HS-033 " .. family .. " fresh bind rejects enable " .. outcome, function()
				with_trigger_fixture({}, function(fixture)
					fixture.backend.plan("enable", {outcome})
					local result
					local handle
					local pref
					if family == "primary" then
						result = fixture.orchestrator.apply_llm_shortcut({"ctrl"}, "b")
						handle = fixture.get_trigger_hk()
						pref = fixture.state.llm_trigger_shortcut
					else
						result = fixture.orchestrator.apply_llm_profile_shortcut("user_p", {"ctrl"}, "b")
						handle = fixture.get_profile_hk("user_p")
						pref = fixture.state.llm_profile_shortcuts.user_p
					end
					helpers.assert_nil(handle)
					helpers.assert_true(pref == false or pref == nil)
					helpers.assert_eq(fixture.get_save_count(), 0)
					helpers.assert_eq(result, false)
				end)
			end)

			helpers.it("HS-033 " .. family .. " fresh bind rejects staging disable " .. outcome, function()
				with_trigger_fixture({}, function(fixture)
					fixture.backend.plan("disable", {outcome})
					local result
					local handle
					local pref
					if family == "primary" then
						result = fixture.orchestrator.apply_llm_shortcut({"ctrl"}, "b")
						handle = fixture.get_trigger_hk()
						pref = fixture.state.llm_trigger_shortcut
					else
						result = fixture.orchestrator.apply_llm_profile_shortcut(
							"user_p", {"ctrl"}, "b")
						handle = fixture.get_profile_hk("user_p")
						pref = fixture.state.llm_profile_shortcuts.user_p
					end
					helpers.assert_nil(handle)
					helpers.assert_true(pref == false or pref == nil)
					helpers.assert_eq(fixture.get_save_count(), 0)
					helpers.assert_eq(result, false)
				end)
			end)
		end

		for _, boundary in ipairs({"new", "disable", "enable"}) do
			for _, outcome in ipairs({"false", "nil", "throw"}) do
				helpers.it("HS-033 " .. family .. " rebind retains the exact old owner when "
					.. boundary .. " returns " .. outcome, function()
					with_trigger_fixture({}, function(fixture)
						local slot = seed_family(fixture, family)
						local old_handle = slot.get_handle()
						local old_chord = old_handle.chord
						local old_preference = slot.get_pref()
						local old_shortcuts = fixture.state.llm_profile_shortcuts
						fixture.reset_observations()
						fixture.backend.plan(boundary, {outcome})

						local result = slot.apply({"ctrl"}, "b")
						helpers.assert_true(slot.get_handle() == old_handle)
						helpers.assert_eq(old_handle.chord, old_chord)
						helpers.assert_true(slot.get_pref() == old_preference)
						if family == "profile" then
							helpers.assert_true(fixture.state.llm_profile_shortcuts == old_shortcuts)
						end
						helpers.assert_eq(fixture.get_save_count(), 0)
						helpers.assert_eq(fixture.get_menu_count(), 0)
						fixture.fire(old_handle)
						helpers.assert_eq(fixture.get_prediction_count(), 1,
							"a rejected successor must never disturb the old callback")
						helpers.assert_eq(result, false)
					end)
				end)
			end
		end

		helpers.it("HS-033 " .. family .. " retries an inert rejected-candidate cleanup debt", function()
			with_trigger_fixture({}, function(fixture)
				fixture.backend.plan("disable", {"throw", "throw"})
				fixture.backend.plan("delete", {"false"})
				local function apply(opts)
					if family == "primary" then
						return fixture.orchestrator.apply_llm_shortcut({"ctrl"}, "b", opts)
					end
					return fixture.orchestrator.apply_llm_profile_shortcut(
						"user_p", {"ctrl"}, "b", opts)
				end
				local function get_owner()
					if family == "primary" then return fixture.get_trigger_hk() end
					return fixture.get_profile_hk("user_p")
				end

				local first_result = apply({persist = false})
				local rejected_native = fixture.get_last_native_handle()
				helpers.assert_nil(get_owner())
				helpers.assert_eq(rejected_native.deleted, false)
				helpers.assert_true(rejected_native.enabled,
					"the fixture must reach the Lua callback gate, not stop at native state")
				fixture.fire(rejected_native)
				helpers.assert_eq(fixture.get_prediction_count(), 0)
				helpers.assert_eq(first_result, false)

				helpers.assert_eq(apply({persist = false}), true)
				helpers.assert_true(rejected_native.deleted)
				helpers.assert_true(get_owner() ~= rejected_native)
			end)
		end)

		helpers.it("HS-033 " .. family .. " disable releases a live owner despite a stale disabled preference", function()
			with_trigger_fixture({}, function(fixture)
				local slot = seed_family(fixture, family)
				local old_handle = slot.get_handle()
				if family == "primary" then
					fixture.state.llm_trigger_shortcut = false
				else
					fixture.state.llm_profile_shortcuts.user_p = nil
				end

				helpers.assert_eq(slot.apply(nil, nil, {persist = false}), true)
				helpers.assert_nil(slot.get_handle())
				helpers.assert_true(old_handle.deleted)
				fixture.fire(old_handle)
				helpers.assert_eq(fixture.get_prediction_count(), 0)
			end)
		end)

		for _, outcome in ipairs({"false", "nil", "throw"}) do
			helpers.it("HS-033 " .. family .. " retains an inactive owner when activation " .. outcome, function()
				with_trigger_fixture({}, function(fixture)
					local slot = seed_inactive_family(fixture, family)
					local handle = slot.get_handle()
					local preference = slot.get_pref()
					fixture.reset_observations()
					fixture.backend.plan("enable", {outcome})

					local result = fixture.orchestrator.activate_hotkey(handle)
					helpers.assert_true(slot.get_handle() == handle)
					helpers.assert_true(slot.get_pref() == preference)
					fixture.fire(handle)
					helpers.assert_eq(fixture.get_prediction_count(), 0,
						"a refused activation must keep the callback gate closed")
					helpers.assert_eq(result, false)
					helpers.assert_eq(fixture.orchestrator.activate_hotkey(handle), true)
					fixture.fire(handle)
					helpers.assert_eq(fixture.get_prediction_count(), 1)
				end)
			end)
		end

		for _, outcome in ipairs({"false", "nil", "throw"}) do
			helpers.it("HS-033 " .. family .. " same-chord silent pass fences and retries disable "
				.. outcome, function()
				with_trigger_fixture({}, function(fixture)
					local slot = seed_family(fixture, family)
					local owner = slot.get_handle()
					local preference = slot.get_pref()
					fixture.reset_observations()
					fixture.backend.plan("disable", {outcome})

					if family == "primary" then fixture.set_startup_silence(true) end
					local result = slot.apply({"ctrl"}, "a", {
						persist = false,
						silent = family == "profile",
					})
					if family == "primary" then fixture.set_startup_silence(false) end

					helpers.assert_true(slot.get_handle() == owner)
					helpers.assert_true(slot.get_pref() == preference)
					fixture.fire(owner)
					helpers.assert_eq(fixture.get_prediction_count(), 0,
						"a refused same-chord suspension must close logical delivery")
					helpers.assert_eq(result, false)

					if family == "primary" then fixture.set_startup_silence(true) end
					helpers.assert_eq(slot.apply({"ctrl"}, "a", {
						persist = false,
						silent = family == "profile",
					}), true)
					if family == "primary" then fixture.set_startup_silence(false) end
					fixture.fire(owner)
					helpers.assert_eq(fixture.get_prediction_count(), 0)

					helpers.assert_eq(fixture.orchestrator.activate_hotkey(owner), true)
					fixture.fire(owner)
					helpers.assert_eq(fixture.get_prediction_count(), 1)
				end)
			end)
		end

		helpers.it("HS-033 " .. family .. " rebind preserves the exact old owner on persistence refusal", function()
			with_trigger_fixture({}, function(fixture)
				local slot = seed_family(fixture, family)
				local old_handle = slot.get_handle()
				local old_chord = old_handle.chord
				local old_pref = slot.get_pref()
				local old_profile_shortcuts = fixture.state.llm_profile_shortcuts
				fixture.reset_observations()
				fixture.plan_save({"restore_false", "ok"})

				local result = slot.apply({"ctrl"}, "b")
				helpers.assert_true(slot.get_handle() == old_handle)
				helpers.assert_eq(slot.get_handle().chord, old_chord)
				helpers.assert_true(slot.get_pref() == old_pref,
					"rollback must restore the exact prior preference object")
				helpers.assert_eq(fixture.durable().llm_trigger_shortcut,
					family == "primary" and old_pref or false)
				if family == "profile" then
					helpers.assert_true(fixture.state.llm_profile_shortcuts
						== old_profile_shortcuts)
					helpers.assert_eq(fixture.durable().llm_profile_shortcuts.user_p, old_pref)
				end
				helpers.assert_eq(fixture.get_menu_snapshot().llm_trigger_shortcut,
					family == "primary" and old_pref or false)
				if family == "profile" then
					helpers.assert_eq(fixture.get_menu_snapshot().llm_profile_shortcuts.user_p,
						old_pref)
				end
				fixture.fire(old_handle)
				helpers.assert_eq(fixture.get_prediction_count(), 1,
					"the exact prior handle must still deliver after rollback")
				helpers.assert_eq(result, false)
			end)
		end)

		helpers.it("HS-033 " .. family .. " gates the successor through persistence and menu", function()
			with_trigger_fixture({}, function(fixture)
				local slot = seed_family(fixture, family)
				local old_handle = slot.get_handle()
				fixture.reset_observations()
				fixture.plan_save({"fire_all_ok"})
				fixture.plan_menu({"fire_all_ok"})

				helpers.assert_eq(slot.apply({"ctrl"}, "b"), true)
				helpers.assert_eq(fixture.get_prediction_count(), 0,
					"neither prior nor successor callback may publish before every boundary commits")
				local successor = slot.get_handle()
				helpers.assert_true(successor ~= old_handle)
				fixture.fire(successor)
				helpers.assert_eq(fixture.get_prediction_count(), 1)
			end)
		end)

		for _, outcome in ipairs({"false", "throw"}) do
			helpers.it("HS-033 " .. family .. " rebind rolls back menu " .. outcome, function()
				with_trigger_fixture({}, function(fixture)
					local slot = seed_family(fixture, family)
					local old_handle = slot.get_handle()
					local old_pref = slot.get_pref()
					fixture.reset_observations()
					fixture.plan_save({"ok", "ok"})
					fixture.plan_menu({outcome, "ok"})

					local result = slot.apply({"ctrl"}, "b")
					helpers.assert_true(slot.get_handle() == old_handle)
					helpers.assert_true(slot.get_pref() == old_pref)
					helpers.assert_eq(fixture.get_menu_snapshot().llm_trigger_shortcut,
						family == "primary" and old_pref or false)
					fixture.fire(old_handle)
					helpers.assert_eq(fixture.get_prediction_count(), 1)
					helpers.assert_eq(fixture.get_menu_count(), 2,
						"candidate and rollback menu publications must both be observed")
					helpers.assert_eq(result, false)
				end)
			end)
		end

		helpers.it("HS-033 " .. family .. " accepts a nil-returning menu publisher", function()
			with_trigger_fixture({}, function(fixture)
				local slot = seed_family(fixture, family)
				local old_handle = slot.get_handle()
				fixture.reset_observations()
				fixture.plan_save({"ok"})
				fixture.plan_menu({"nil"})

				helpers.assert_eq(slot.apply({"ctrl"}, "b"), true)
				helpers.assert_true(slot.get_handle() ~= old_handle)
				helpers.assert_true(old_handle.deleted)
				helpers.assert_eq(fixture.get_save_count(), 1)
				helpers.assert_eq(fixture.get_menu_count(), 1)
			end)
		end)

		for _, outcome in ipairs({"false", "nil", "throw"}) do
			helpers.it("HS-033 " .. family .. " rebind rejects old disable " .. outcome, function()
				with_trigger_fixture({}, function(fixture)
					local slot = seed_family(fixture, family)
					local old_handle = slot.get_handle()
					local old_pref = slot.get_pref()
					fixture.reset_observations()
					fixture.backend.plan("disable", {"ok", outcome})

					local result = slot.apply({"ctrl"}, "b")
					helpers.assert_true(slot.get_handle() == old_handle)
					helpers.assert_true(slot.get_pref() == old_pref)
					helpers.assert_eq(fixture.get_save_count(), 0)
					fixture.fire(old_handle)
					helpers.assert_eq(fixture.get_prediction_count(), 1)
					helpers.assert_eq(result, false)
				end)
			end)

			helpers.it("HS-033 " .. family .. " rebind rolls back registrar-seam delete " .. outcome, function()
				with_trigger_fixture({}, function(fixture)
					local slot = seed_family(fixture, family)
					local old_handle = slot.get_handle()
					local old_pref = slot.get_pref()
					fixture.reset_observations()
					fixture.backend.plan("delete", {outcome})
					fixture.plan_save({"ok", "ok"})

					local result = slot.apply({"ctrl"}, "b")
					helpers.assert_true(slot.get_handle() == old_handle)
					helpers.assert_true(slot.get_pref() == old_pref)
					fixture.fire(old_handle)
					helpers.assert_eq(fixture.get_prediction_count(), 1)
					helpers.assert_eq(result, false)
				end)
			end)
		end

		for _, outcome in ipairs({"false", "nil", "throw"}) do
			helpers.it("HS-033 " .. family .. " disable rolls back registrar-seam delete " .. outcome, function()
				with_trigger_fixture({}, function(fixture)
					local slot = seed_family(fixture, family)
					local old_handle = slot.get_handle()
					local old_pref = slot.get_pref()
					fixture.reset_observations()
					fixture.backend.plan("delete", {outcome})
					fixture.plan_save({"ok", "ok"})

					local result = slot.apply(nil, nil)
					helpers.assert_true(slot.get_handle() == old_handle)
					helpers.assert_true(slot.get_pref() == old_pref)
					fixture.fire(old_handle)
					helpers.assert_eq(fixture.get_prediction_count(), 1)
					helpers.assert_eq(result, false)
				end)
			end)
		end

		helpers.it("HS-033 " .. family .. " retries retained rollback debt before disabling", function()
			with_trigger_fixture({}, function(fixture)
				local slot = seed_family(fixture, family)
				local old_handle = slot.get_handle()
				fixture.reset_observations()
				fixture.backend.plan("delete", {"false", "ok"})
				fixture.plan_save({"ok", "false", "ok", "ok"})

				local first_result = slot.apply(nil, nil)
				helpers.assert_true(slot.get_handle() == old_handle)
				helpers.assert_eq(first_result, false)
				helpers.assert_eq(slot.apply(nil, nil), true)
				helpers.assert_nil(slot.get_handle())
				helpers.assert_true(slot.get_pref() == false or slot.get_pref() == nil)
				helpers.assert_true(old_handle.deleted)
			end)
		end)

		helpers.it("HS-033 " .. family .. " retains registrar rollback debt until old enable settles", function()
			with_trigger_fixture({}, function(fixture)
				local slot = seed_family(fixture, family)
				local old_handle = slot.get_handle()
				fixture.reset_observations()
				fixture.backend.plan("delete", {"false", "ok"})
				fixture.backend.plan("enable", {"false"})
				fixture.plan_save({"ok", "ok", "ok"})

				local first_result = slot.apply(nil, nil)
				helpers.assert_true(slot.get_handle() == old_handle)
				fixture.fire(old_handle)
				helpers.assert_eq(fixture.get_prediction_count(), 0,
					"the unsettled native rollback must remain fail-closed")
				helpers.assert_eq(first_result, false)

				helpers.assert_eq(slot.apply(nil, nil), true)
				helpers.assert_true(old_handle.deleted)
				helpers.assert_nil(slot.get_handle())
			end)
		end)
	end
end)

helpers.describe("HS-033 real hotkey registrar composition", function()
	for _, family in ipairs({"primary", "profile"}) do
		helpers.it("HS-033 " .. family .. " retains and retries after native enable returns nil", function()
			with_trigger_fixture({real_registrar = true}, function(fixture)
				local slot = seed_inactive_family(fixture, family)
				local owner = slot.get_handle()
				local native = fixture.get_last_native_handle()
				local preference = slot.get_pref()
				fixture.reset_observations()
				fixture.backend.plan("native_enable", {"nil"})

				helpers.assert_eq(fixture.orchestrator.activate_hotkey(owner), false)
				helpers.assert_true(slot.get_handle() == owner)
				helpers.assert_true(slot.get_pref() == preference)
				helpers.assert_eq(native.deleted, false)
				fixture.fire(native)
				helpers.assert_eq(fixture.get_prediction_count(), 0)

				helpers.assert_eq(fixture.orchestrator.activate_hotkey(owner), true)
				helpers.assert_true(slot.get_handle() == owner)
				fixture.fire(native)
				helpers.assert_eq(fixture.get_prediction_count(), 1)
			end)
		end)

		helpers.it("HS-033 " .. family .. " retains the real opaque owner after native delete throws", function()
			with_trigger_fixture({real_registrar = true}, function(fixture)
				local slot = seed_family(fixture, family)
				local old_owner = slot.get_handle()
				local old_native = fixture.get_last_native_handle()
				local old_chord = old_native.chord
				local old_preference = slot.get_pref()
				fixture.reset_observations()
				fixture.backend.plan("native_delete", {"throw"})

				local result = slot.apply(nil, nil, {persist = false})
				helpers.assert_true(slot.get_handle() == old_owner)
				helpers.assert_eq(old_native.chord, old_chord)
				helpers.assert_true(slot.get_pref() == old_preference)
				helpers.assert_eq(old_native.deleted, false)
				fixture.fire(old_native)
				helpers.assert_eq(fixture.get_prediction_count(), 1)
				helpers.assert_eq(result, false)

				helpers.assert_eq(slot.apply(nil, nil, {persist = false}), true)
				helpers.assert_nil(slot.get_handle())
				helpers.assert_true(old_native.deleted)
			end)
		end)
	end
end)

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

--- Loads the real shared shortcut prompt around a deterministic dialog result.
--- @param raw string Prompt input.
--- @param body function Test callback receiving the real utility.
local function with_real_shortcut_prompt(raw, body)
	local saved_dialog = package.loaded["infra.dialog_util"]
	local saved_i18n = package.loaded["infra.i18n"]
	local saved_logger = package.loaded["infra.logger"]
	local saved_shortcuts = package.loaded["ui.menu.shortcut_utils"]
	local ok, err = xpcall(function()
		package.loaded["infra.dialog_util"] = {
			text_prompt = function() return "OK", raw end,
			alert = function() return true end,
		}
		package.loaded["infra.i18n"] = {get = function(key) return key end}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["ui.menu.shortcut_utils"] = nil
		body(require("ui.menu.shortcut_utils"))
	end, debug.traceback)
	package.loaded["infra.dialog_util"] = saved_dialog
	package.loaded["infra.i18n"] = saved_i18n
	package.loaded["infra.logger"] = saved_logger
	package.loaded["ui.menu.shortcut_utils"] = saved_shortcuts
	if not ok then error(err, 0) end
end

helpers.describe("HS-033 shortcut prompt settlement propagation", function()
	for _, raw in ipairs({"ctrl+b", ""}) do
		for _, outcome in ipairs({"false", "nil", "throw"}) do
			helpers.it("HS-033 prompt returns refusal for " .. outcome .. " callback on '" .. raw .. "'", function()
				with_real_shortcut_prompt(raw, function(shortcuts)
					local function refuse()
						if outcome == "throw" then error("apply refused", 0) end
						if outcome == "false" then return false end
						return nil
					end
					helpers.assert_eq(shortcuts.prompt_shortcut({on_apply = refuse}), false)
				end)
			end)
		end
	end

	helpers.it("HS-033 prompt reports literal committed callback success", function()
		with_real_shortcut_prompt("ctrl+b", function(shortcuts)
			helpers.assert_eq(shortcuts.prompt_shortcut({
				on_apply = function() return true end,
			}), true)
		end)
	end)

	helpers.it("HS-033 profile shortcut menu action propagates prompt refusal", function()
		with_delete_fixture({active_profile = "basic"},
			function(_, _, _, shortcut_action)
				package.loaded["ui.menu.shortcut_utils"].prompt_shortcut = function()
					return false
				end
				helpers.assert_eq(shortcut_action(), false)
			end)
	end)

	helpers.it("HS-033 primary shortcut menu action propagates prompt refusal", function()
		local saved_app_picker = package.loaded["infra.app_picker"]
		local saved_i18n = package.loaded["infra.i18n"]
		local saved_logger = package.loaded["infra.logger"]
		local saved_manifest = package.loaded["infra.manifest_menu"]
		local saved_llm = package.loaded["modules.llm"]
		local saved_shortcuts = package.loaded["ui.menu.shortcut_utils"]
		local saved_panel = package.loaded["ui.menu.menu_llm.trigger_panel"]
		local ok, err = xpcall(function()
			package.loaded["infra.app_picker"] = {build_menu = function() return {} end}
			package.loaded["infra.i18n"] = {get = function(key) return key end}
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.manifest_menu"] = {render_rows = function(rows) return rows end}
			package.loaded["modules.llm"] = {
				DEFAULT_STATE = {llm_debounce = 0.2},
			}
			package.loaded["ui.menu.shortcut_utils"] = {
				prompt_shortcut = function() return false end,
				shortcut_to_label = function() return "None" end,
			}
			package.loaded["ui.menu.menu_llm.trigger_panel"] = nil
			local rows = require("ui.menu.menu_llm.trigger_panel").build({
				state = {},
				is_disabled = false,
				settings_mgr = {},
				apply_llm_shortcut = function() return false end,
			})
			helpers.assert_type(rows[1] and rows[1].action, "function")
			helpers.assert_eq(rows[1].action(), false)
		end, debug.traceback)
		package.loaded["infra.app_picker"] = saved_app_picker
		package.loaded["infra.i18n"] = saved_i18n
		package.loaded["infra.logger"] = saved_logger
		package.loaded["infra.manifest_menu"] = saved_manifest
		package.loaded["modules.llm"] = saved_llm
		package.loaded["ui.menu.shortcut_utils"] = saved_shortcuts
		package.loaded["ui.menu.menu_llm.trigger_panel"] = saved_panel
		if not ok then error(err, 0) end
	end)
end)

return true
