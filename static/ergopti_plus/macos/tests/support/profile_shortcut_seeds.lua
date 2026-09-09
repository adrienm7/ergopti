--- tests/support/profile_shortcut_seeds.lua

--- ==============================================================================
--- MODULE: Profile Shortcut Scenario Seeds
--- DESCRIPTION:
--- Shares active and inactive shortcut setup across owner and registrar scenarios.
--- ==============================================================================

local helpers = require("tests.helpers")

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

return {
	seed_family = seed_family,
	seed_inactive_family = seed_inactive_family,
}
