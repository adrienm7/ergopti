--- _shared/lua/menu/wrap_mutation.lua

--- ==============================================================================
--- MODULE: Wrap Preference Mutation Ownership
--- DESCRIPTION:
--- Owns detached wrap candidates while the existing native preference writer
--- acknowledges them. Input readers retain the prior view until acknowledgement.
--- ==============================================================================

local M = {}
local FIELDS = { "wrap_symbol_states", "custom_wrap_symbols" }
local claims = setmetatable({}, { __mode = "k" })

local function clone(value)
	return require("toml_codec.leaf_rows").clone_value(value)
end

--- Reports whether another wrap callback owns this state's publication.
--- @param state table Menu state.
--- @return boolean pending
function M.pending(state)
	return claims[state] ~= nil
end

--- Supplies acknowledged wrap fields to the native input getter during a save.
--- @param state table Menu state.
--- @return table view Current state or the retained pre-publication fields.
function M.view(state)
	local claim = claims[state]
	return claim and claim.view or state
end

--- Commits a detached candidate through the existing native save authority.
--- @param state table Menu state; only the two wrap preference fields are owned.
--- @param mutate function Changes detached fields and returns literal true to save.
--- @param save function Existing zero-argument native preference save owner.
--- @return boolean committed True only after literal durable acknowledgement.
--- @return string|nil reason Refusal classification.
function M.commit(state, mutate, save)
	if type(state) ~= "table" or type(mutate) ~= "function" or type(save) ~= "function" then
		return false, "missing mutation capability"
	end
	if claims[state] then return false, "wrap publication already owned" end
	local prior, candidate = {}, {}
	for _, field in ipairs(FIELDS) do
		local value = rawget(state, field)
		if value ~= nil and type(value) ~= "table" then return false, "invalid wrap preference fields" end
		prior[field] = value
		candidate[field] = clone(value or {})
	end
	claims[state] = { view = clone(prior) }
	local called, changed = pcall(mutate, candidate)
	if not called or changed ~= true then
		claims[state] = nil
		return false, called and "wrap mutation cancelled" or "wrap mutation failed"
	end
	for _, field in ipairs(FIELDS) do
		if type(candidate[field]) ~= "table" then
			claims[state] = nil
			return false, "invalid wrap candidate"
		end
		if rawget(state, field) ~= prior[field] then
			claims[state] = nil
			return false, "wrap state changed during candidate construction"
		end
	end
	for _, field in ipairs(FIELDS) do rawset(state, field, candidate[field]) end
	local saved, acknowledged = pcall(save)
	if not saved or acknowledged ~= true then
		-- The native writer may already have restored its complete checkpoint.
		-- Only reverse fields still held by this exact candidate; a replacement
		-- published by another owner remains attached to its successor state.
		for _, field in ipairs(FIELDS) do
			if rawget(state, field) == candidate[field] then rawset(state, field, prior[field]) end
		end
		claims[state] = nil
		return false, saved and "preference save refused" or "preference save failed"
	end
	local owned = true
	for _, field in ipairs(FIELDS) do
		if rawget(state, field) ~= candidate[field] then owned = false end
	end
	claims[state] = nil
	if not owned then return false, "wrap candidate ownership changed" end
	return true
end

return M
