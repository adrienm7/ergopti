--- _shared/lua/healthcheck/unavailable.lua

--- ==============================================================================
--- MODULE: Diagnostics Feature Availability
--- DESCRIPTION:
--- Builds the diagnostics `unavailable` section from the generated features
--- manifest: every feature this driver lacks, with the platforms that have it
--- and the reason key the page translates.
---
--- FEATURES & RATIONALE:
--- 1. One collector for every Lua driver: macOS published this section alone,
---    so a Linux user could not ask the diagnostics page why a documented
---    feature is missing from their menu.
--- 2. Every absence is listed, explained or not: a list of only the explained
---    ones would look complete while hiding the ones that matter most.
--- 3. An unknown platform code fails loudly instead of printing a raw code.
--- ==============================================================================

local M = {}

-- The display names of the manifest's platform codes
local PLATFORM_NAMES = { ahk = "Windows", hs = "macOS", linux = "Linux" }




-- =================================
-- =================================
-- ======= 1/ Public API ===========
-- =================================
-- =================================

--- Collects the section from a bound manifest reader.
--- @param reader table A manifest reader exposing coverage_gaps().
--- @return table { items = { { feature, platforms, reason } } }
function M.collect(reader)
	if type(reader) ~= "table" or type(reader.coverage_gaps) ~= "function" then
		error("the availability section needs a manifest reader", 2)
	end
	local explained, silent = reader.coverage_gaps()
	local items = {}
	for _, gaps in ipairs({ explained, silent }) do
		for _, gap in ipairs(gaps) do
			local names = {}
			for _, code in ipairs(gap.platforms or {}) do
				local name = PLATFORM_NAMES[code]
				if not name then error("the manifest names an unknown platform: " .. tostring(code)) end
				names[#names + 1] = name
			end
			items[#items + 1] = {
				feature   = gap.path,
				platforms = table.concat(names, ", "),
				reason    = (type(gap.reason_key) == "string" and gap.reason_key ~= "") and gap.reason_key or nil,
			}
		end
	end
	table.sort(items, function(a, b) return a.feature < b.feature end)
	return { items = items }
end

return M
