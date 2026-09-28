--- tests/support/dynamic_hotstrings_fixture.lua

--- ==============================================================================
--- MODULE: Explicit Dynamic Hotstring Families Fixture
--- DESCRIPTION:
--- Functional expansion tests select every family through its real preference
--- owner, using in-memory storage that is restored after the test module.
--- ==============================================================================

local M = {}

--- Selects the declared families in the current test storage.
--- @param manager table Dynamic hotstrings owner.
function M.prefer_families(manager)
	for _, family in ipairs(manager.RULE_FAMILIES) do
		if family.section then
			assert(manager.set_rule_enabled(family.section, true), "fixture family must persist: " .. family.section)
		end
	end
end

--- Installs isolated family preferences and returns the exact restoration action.
--- @return function restore
function M.install()
	local previous = package.loaded["adapters.storage"]
	package.loaded["adapters.storage"] = require("tests.fakes").storage()
	local ok, detail = pcall(M.prefer_families, require("modules.dynamic_hotstrings.manager"))
	if not ok then package.loaded["adapters.storage"] = previous; error(detail, 0) end
	return function() package.loaded["adapters.storage"] = previous end
end

return M
