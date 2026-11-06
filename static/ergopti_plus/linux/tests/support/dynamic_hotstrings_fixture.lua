--- tests/support/dynamic_hotstrings_fixture.lua

--- ==============================================================================
--- MODULE: Explicit Dynamic Hotstring Families Fixture
--- DESCRIPTION:
--- Functional expansion tests select every family through its real preference
--- owner, whose canonical leaves are routed to a private config.toml that is
--- removed after the test module.
--- ==============================================================================

local M = {}

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
	local uv = require("luv")
	local dir = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-dynamic-families-XXXXXX"))
	local path = dir .. "/config.toml"
	if not Preferences._set_file_for_test(path) then
		assert(uv.fs_rmdir(dir))
		error("the preference owner must accept a private file")
	end
	return function()
		Preferences._set_file_for_test(nil)
		os.remove(path)
		os.remove(path .. ".tmp")
		assert(uv.fs_rmdir(dir))
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

--- Calls the real single-field manager with a live fixture-owned destination.
--- @param manager table Dynamic hotstrings manager.
--- @param buffer string Current engine buffer.
--- @param trigger string Configured trigger character.
--- @param start_is_boundary boolean|nil Retained engine boundary.
--- @return boolean fired
--- @return table|nil event
function M.trigger(manager, buffer, trigger, start_is_boundary)
	local fired, event
	require("tests.support.text_owner_fixture").with(function(guard)
		fired, event = manager.on_trigger(buffer, trigger, start_is_boundary,
			assert(guard.capture_text_owner()), function() return true end)
	end)
	return fired, event
end

return M
