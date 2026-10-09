--- _shared/lua/wrap_pair/init.lua

--- ==============================================================================
--- MODULE: Wrap Pair Parameter
--- DESCRIPTION:
--- Resolves the wrap_pair parameter of the wrap_selection action to the left and
--- right symbols it names, for the macOS and Linux drivers. The value is either
--- a symbol of the built-in catalogue (_shared/modules/wrap_symbols/wrap_symbols.json,
--- opening or closing) or a custom pair written left|right.
---
--- FEATURES & RATIONALE:
--- 1. Pure: the caller passes the catalogue pairs it already loaded, so the
---    module needs neither a JSON decoder nor a path resolver.
--- 2. One rule, pinned by _shared/tests/corpus/action_parameters/wrap_pair_vectors.json,
---    which the Windows suite replays against its own parser too.
--- ==============================================================================

local M = {}

--- The separator of a custom pair.
M.SEPARATOR = "|"

--- @param text string
--- @return string text without its leading and trailing whitespace.
local function trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Resolves a stored parameter value.
--- @param value any The stored value.
--- @param pairs_list table Ordered catalogue pairs, each { left = ..., right = ... }.
--- @return string|nil left
--- @return string|nil right Both nil when the value names no pair.
function M.parse(value, pairs_list)
	if type(value) ~= "string" or type(pairs_list) ~= "table" then return nil, nil end
	local wanted = trim(value)
	if wanted == "" or wanted:find("[\r\n]") then return nil, nil end
	for _, field in ipairs({ "left", "right" }) do
		for _, pair in ipairs(pairs_list) do
			if type(pair) == "table" and type(pair[field]) == "string"
				and trim(pair[field]) == wanted then
				return pair.left, pair.right
			end
		end
	end
	local at = wanted:find(M.SEPARATOR, 1, true)
	if not at or wanted:find(M.SEPARATOR, at + 1, true) then return nil, nil end
	local left, right = wanted:sub(1, at - 1), wanted:sub(at + 1)
	if trim(left) == "" or trim(right) == "" then return nil, nil end
	return left, right
end

--- The catalogue as one line of "left…right" samples, for the prompt that asks
--- for the value.
--- @param pairs_list table Ordered catalogue pairs.
--- @return string
function M.describe(pairs_list)
	local samples = {}
	for _, pair in ipairs(pairs_list or {}) do
		if type(pair) == "table" and type(pair.left) == "string" and type(pair.right) == "string" then
			samples[#samples + 1] = trim(pair.left) .. "…" .. trim(pair.right)
		end
	end
	return table.concat(samples, "   ")
end

return M
