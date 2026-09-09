--- tests/unit/ui/menu/menu_llm/test_shortcut_registrar_composition.lua

--- ==============================================================================
--- MODULE: LLM Shortcut Registrar Composition
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


return true
