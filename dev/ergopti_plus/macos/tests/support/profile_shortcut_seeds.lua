--- tests/support/profile_shortcut_seeds.lua

--- ==============================================================================
--- MODULE: Profile Shortcut Scenario Seeds
--- DESCRIPTION:
--- Shares active and inactive shortcut setup across owner and registrar scenarios.
--- Profile shortcuts are the owner's only family: the primary trigger shortcut is
--- retired in favour of the llm_generate_prediction keyboard-slot action.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Refuses a family the owner no longer has, so a stale matrix fails loudly.
--- @param family string The requested family.
local function require_profile_family(family)
	if family ~= "profile" then
		error("unknown shortcut family '" .. tostring(family) .. "': only profile shortcuts remain", 2)
	end
end

--- Seeds one shortcut family and returns uniform accessors for the matrix.
--- @param fixture table Trigger fixture.
--- @param family string Always "profile".
--- @return table slot
local function seed_family(fixture, family)
	require_profile_family(family)
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
--- @param family string Always "profile".
--- @return table slot
local function seed_inactive_family(fixture, family)
	require_profile_family(family)
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
