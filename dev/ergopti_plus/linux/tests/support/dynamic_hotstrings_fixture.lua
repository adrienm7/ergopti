--- tests/support/dynamic_hotstrings_fixture.lua

--- ==============================================================================
--- MODULE: Explicit Dynamic Hotstring Families Fixture
--- DESCRIPTION:
--- Functional expansion tests select every family through its real preference
--- owner, whose canonical leaves are routed to a private config.toml that is
--- removed after the test module.
--- ==============================================================================

local M = {}
local _sequence = 0

--- Selects the declared families through the current preference owner.
--- @param manager table Dynamic hotstrings owner.
function M.prefer_families(manager)
	for _, family in ipairs(manager.RULE_FAMILIES) do
		if family.section then
			assert(manager.set_rule_enabled(family.section, true), "fixture family must persist: " .. family.section)
		end
	end
end

--- Routes the preference owner to a private file for one test module.
--- @return function restore Removes the file and restores production routing.
--- @return string path The private configuration file.
function M.route()
	local Preferences = require("infra.hotstring_preferences")
	_sequence = _sequence + 1
	local path = string.format("%s/ergopti_dynamic_families_%d_%d_%d.toml",
		(os.getenv("TMPDIR") or "/tmp"):gsub("/+$", ""), os.time(), math.random(100000, 999999), _sequence)
	assert(Preferences._set_file_for_test(path), "the preference owner must accept a private file")
	return function()
		Preferences._set_file_for_test(nil)
		os.remove(path)
		os.remove(path .. ".tmp")
	end, path
end

--- Installs isolated family preferences and returns the exact restoration action.
--- The families are selected in the routed owner itself: a manager instance an
--- earlier test left loaded may be bound to another owner.
--- @return function restore
function M.install()
	local restore = M.route()
	local ok, detail = pcall(function()
		local Preferences = require("infra.hotstring_preferences")
		for _, family in ipairs(require("modules.dynamic_hotstrings.manager").RULE_FAMILIES) do
			if family.id then
				assert(Preferences.set("hotstrings.dynamic." .. family.id .. ".enabled", true),
					"fixture family must persist: " .. family.id)
			end
		end
	end)
	if not ok then restore(); error(detail, 0) end
	return restore
end

return M
