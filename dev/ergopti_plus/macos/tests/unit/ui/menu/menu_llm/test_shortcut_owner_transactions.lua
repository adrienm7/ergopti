--- tests/unit/ui/menu/menu_llm/test_shortcut_owner_transactions.lua

--- ==============================================================================
--- MODULE: LLM Shortcut Owner Transactions
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
local Seeds = require("tests.support.profile_shortcut_seeds")
local seed_family = Seeds.seed_family
local seed_inactive_family = Seeds.seed_inactive_family

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


return true
