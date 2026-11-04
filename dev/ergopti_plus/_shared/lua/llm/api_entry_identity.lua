--- _shared/lua/llm/api_entry_identity.lua

--- ==============================================================================
--- MODULE: Durable API Entry Identity Allocation
--- DESCRIPTION:
--- A process-local sequence cannot exclude IDs persisted by an earlier process
--- in the same clock second. Both Lua API editors consult the durable entry
--- list before allocating; Windows separately rejects duplicate candidates
--- through its existing atomic API-entry owner.
--- ==============================================================================

local M = {}





-- ================================
-- ================================
-- ======= 1/ Public API ==========
-- ================================
-- ================================

--- Allocates an unused legacy-format ID without mutating existing entries.
--- @param provider string Provider identifier.
--- @param now integer Captured clock second.
--- @param sequence integer Process-local last sequence.
--- @param entries table Existing durable entries.
--- @return string id, integer sequence Next unused identifier and sequence.
function M.next(provider, now, sequence, entries)
	assert(type(provider) == "string" and provider ~= "", "provider identity is required")
	assert(type(now) == "number" and now == math.floor(now), "clock second must be an integer")
	assert(type(sequence) == "number" and sequence >= 0 and sequence == math.floor(sequence), "sequence must be a nonnegative integer")
	assert(type(entries) == "table", "durable entry list is required")
	local owned = {}
	for _, entry in ipairs(entries) do owned[entry.id] = true end
	local id
	repeat
		sequence = sequence + 1
		id = string.format("%s-%d-%d", provider, now, sequence)
	until not owned[id]
	return id, sequence
end

return M
