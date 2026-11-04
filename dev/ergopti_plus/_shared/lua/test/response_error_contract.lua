--- _shared/lua/test/response_error_contract.lua

--- ==============================================================================
--- MODULE: Shared Lua Provider Error Response Contract
--- DESCRIPTION:
--- Explicit expectations for Lua completion extraction with retained JSON error
--- fields. Linux registered provider tests, native public HTTP receipts and the
--- macOS response classifier consume these independent values; other JSON
--- adapters and classifiers require their own native validation before adopting
--- this contract. Existing universal parser
--- corpora and their first-part selection remain unchanged.
--- ==============================================================================

local M = {}

M.vectors = {
	{
		name = "openai top-level object error",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"decoy completion\"}}],\"error\":{\"message\":\"Provider refused fixture request\"}}",
	},
	{
		name = "openai top-level string error",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"decoy completion\"}}],\"error\":\"provider refused\"}",
	},
	{
		name = "openai top-level false error",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"decoy completion\"}}],\"error\":false}",
	},
	{
		name = "openai top-level null error",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"decoy completion\"}}],\"error\":null}",
	},
	{
		name = "openai healthy retry",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"decoy completion\"}}]}",
		expected = "decoy completion",
	},
	{
		name = "openai nested error metadata",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"decoy completion\"}}],\"metadata\":{\"error\":{\"message\":\"not a provider envelope\"}}}",
		expected = "decoy completion",
	},
	{
		name = "anthropic top-level object error",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"decoy completion\"}],\"error\":{\"message\":\"Provider refused fixture request\"}}",
	},
	{
		name = "anthropic top-level string error",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"decoy completion\"}],\"error\":\"provider refused\"}",
	},
	{
		name = "anthropic top-level false error",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"decoy completion\"}],\"error\":false}",
	},
	{
		name = "anthropic top-level null error",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"decoy completion\"}],\"error\":null}",
	},
	{
		name = "anthropic healthy retry",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"decoy completion\"}]}",
		expected = "decoy completion",
	},
	{
		name = "anthropic nested error metadata",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"decoy completion\"}],\"metadata\":{\"error\":{\"message\":\"not a provider envelope\"}}}",
		expected = "decoy completion",
	},
	{
		name = "gemini top-level object error",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"decoy completion\"}]}}],\"error\":{\"message\":\"Provider refused fixture request\"}}",
	},
	{
		name = "gemini top-level string error",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"decoy completion\"}]}}],\"error\":\"provider refused\"}",
	},
	{
		name = "gemini top-level false error",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"decoy completion\"}]}}],\"error\":false}",
	},
	{
		name = "gemini top-level null error",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"decoy completion\"}]}}],\"error\":null}",
	},
	{
		name = "gemini healthy retry",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"decoy completion\"}]}}]}",
		expected = "decoy completion",
	},
	{
		name = "gemini nested error metadata",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"decoy completion\"}]}}],\"metadata\":{\"error\":{\"message\":\"not a provider envelope\"}}}",
		expected = "decoy completion",
	},
	{
		name = "anthropic first block policy",
		format = "anthropic",
		body = "{\"content\":[{\"type\":\"text\",\"text\":\"first\"},{\"type\":\"text\",\"text\":\"second\"}]}",
		expected = "first",
	},
	{
		name = "gemini first part policy",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"thought\":true,\"text\":\"private\"},{\"text\":\"first\"},{\"text\":\"second\"}]}},{\"content\":{\"parts\":[{\"text\":\"other candidate\"}]}}]}",
		expected = "first",
	},
	{
		name = "openai escaped literal and Unicode",
		format = "openai",
		body = "{\"choices\":[{\"message\":{\"content\":\"é 😀 literal \\\\n and \\\"quoted\\\"\"}}]}",
		expected = "é 😀 literal \\n and \"quoted\"",
	},
	{
		name = "openai error only",
		format = "openai",
		body = "{\"error\":{\"message\":\"failure\"}}",
	},
	{
		name = "gemini thoughts only",
		format = "gemini",
		body = "{\"candidates\":[{\"content\":{\"parts\":[{\"thought\":true,\"text\":\"private\"}]}}]}",
	},
}



-- ==========================
-- ===== Envelope shape =====
-- ==========================

-- Every completion format must keep the full matrix below, so a vector cannot be
-- dropped or swapped for a duplicate without this check naming the lost case.
M.FORMATS = { "openai", "anthropic", "gemini" }
M.CELLS = { "error:object", "error:string", "error:false", "error:null", "healthy", "nested" }
local DECOY = "decoy completion"

--- Whether a decoded table holds an `error` key below its root.
--- @param value any Decoded JSON value.
--- @param depth number Current depth; the root is 0.
--- @return boolean
local function nested_error(value, depth)
	if type(value) ~= "table" then return false end
	for key, child in pairs(value) do
		if key == "error" and depth > 0 then return true end
		if nested_error(child, depth + 1) then return true end
	end
	return false
end

--- Names the cell one vector fills, or nil when it fills none.
--- @param vector table Contract vector.
--- @param Json table The shared JSON codec.
--- @return string|nil cell
local function cell_of(vector, Json)
	if not vector.body:find(DECOY, 1, true) then return nil end
	local root = Json.decode_lossless(vector.body)
	if type(root) ~= "table" then return nil end
	local err = rawget(root, "error")
	if err ~= nil then
		if vector.expected ~= nil then return nil end
		if Json.is_null(err) then return "error:null" end
		if err == false then return "error:false" end
		if type(err) == "string" then return "error:string" end
		if type(err) == "table" then return "error:object" end
		return nil
	end
	if vector.expected ~= DECOY then return nil end
	return nested_error(root, 0) and "nested" or "healthy"
end

--- Lists the format/cell pairs the vectors do not cover.
--- @param vectors table[] Vectors to check, normally M.vectors.
--- @return string[] gaps Sorted "<format> <cell>" names; empty when complete.
function M.shape_gaps(vectors)
	local Json = require("json")
	local seen = {}
	for _, vector in ipairs(vectors) do
		local cell = cell_of(vector, Json)
		if cell then seen[vector.format .. " " .. cell] = true end
	end
	local gaps = {}
	for _, format in ipairs(M.FORMATS) do
		for _, cell in ipairs(M.CELLS) do
			if not seen[format .. " " .. cell] then gaps[#gaps + 1] = format .. " " .. cell end
		end
	end
	return gaps
end

return M
