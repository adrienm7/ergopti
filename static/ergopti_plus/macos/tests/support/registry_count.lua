--- tests/support/registry_count.lua

--- ==============================================================================
--- MODULE: Shared Timings Registry Reader For Stubbed Suites
--- DESCRIPTION:
--- A suite that replaces infra.timings with fixed durations still reads the
--- registry's non-duration values (timings.count) from the real shared file, so
--- a stub never carries its own copy of a value the registry owns, such as the
--- [gestures] swipe minimums (maintainer decision GSD-3 of 11 November 2026).
--- The suites that need it stub hs itself, so the file is read with io, not
--- through infra.paths.
--- ==============================================================================

local REGISTRY = (debug.getinfo(1, "S").source:sub(2):match("^(.*)/macos/tests/support/[^/]+$")
	or error("registry_count is outside the macOS test tree")) .. "/_shared/core/timing/data/constants.toml"

--- Reads one numeric `[section] key = value` of the registry.
--- @param section string Registry section.
--- @param key string Registry key.
--- @return number value
return function(section, key)
	local file = assert(io.open(REGISTRY, "r"))
	local current, found
	for line in file:lines() do
		local header = line:match("^%[([%w_%.]+)%]%s*$")
		if header then current = header
		elseif current == section then
			local name, value = line:match("^([%w_]+)%s*=%s*([%d%.]+)%s*$")
			if name == key then found = tonumber(value) end
		end
	end
	file:close()
	if type(found) ~= "number" then error(string.format("no [%s].%s in the registry", section, key), 2) end
	return found
end
