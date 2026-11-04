--- _shared/lua/toml_codec/source_memo.lua

--- ==============================================================================
--- MODULE: TOML Source Memo (shared)
--- DESCRIPTION:
--- Keeps the newest results of a pure function of one TOML text, so the many
--- independent owners of one configuration save stop re-deriving the same
--- structure from the same bytes. A result is a pure function of its exact
--- text and variant, which is the whole invalidation contract.
---
--- FEATURES & RATIONALE:
--- 1. Private copies: the stored result is never handed out. Every caller gets
---    a deep copy, so a caller that mutates its document cannot reach another.
--- 2. Identity-keyed receipts survive: one clone map copies tables used as keys
---    too, so a receipt keyed by a result table names the copy's own table.
--- 3. Bounded: each memo holds a fixed number of texts, newest first.
--- 4. Refusals are not stored: a build that returns nil is repeated next time.
--- ==============================================================================

local M = {}

--- Deep-copies a table graph, cloning keys through the same map so tables
--- shared or used as keys stay shared in the copy.
--- @param value any Value to copy.
--- @param seen table Original table -> copy.
--- @return any copy
local function clone_graph(value, seen)
	if type(value) ~= "table" then return value end
	local copy = seen[value]
	if copy then return copy end
	copy = {}
	seen[value] = copy
	for key, child in pairs(value) do copy[clone_graph(key, seen)] = clone_graph(child, seen) end
	return copy
end

--- Creates one bounded memo.
--- @param capacity number Texts kept, at least one.
--- @return table memo With fetch(content, variant, build).
function M.new(capacity)
	assert(type(capacity) == "number" and capacity >= 1 and capacity % 1 == 0,
		"capacity must be a positive integer")
	-- Newest first: { content = exact text, variant = option key, value = pristine result }.
	local entries = {}
	local memo = {}

	--- Returns a private copy of build()'s result for this exact text.
	--- @param content string Exact source text.
	--- @param variant any Option key that changes the result (false when none).
	--- @param build function Zero-argument pure derivation of content.
	--- @return any copy The copied result, or nil when build refused.
	--- @return any detail build's refusal detail.
	function memo.fetch(content, variant, build)
		local entry = nil
		for index, candidate in ipairs(entries) do
			if candidate.variant == variant and candidate.content == content then
				entry = table.remove(entries, index)
				break
			end
		end
		if entry == nil then
			local value, detail = build()
			if value == nil then return nil, detail end
			entry = { content = content, variant = variant, value = value }
		end
		table.insert(entries, 1, entry)
		entries[capacity + 1] = nil
		return clone_graph(entry.value, {})
	end

	return memo
end

return M
