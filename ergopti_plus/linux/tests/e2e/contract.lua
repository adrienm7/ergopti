--- tests/e2e/contract.lua

--- ==============================================================================
--- MODULE: Linux Hotstring E2E Corpus Contract
--- DESCRIPTION:
--- Loads the mandatory shared corpus, validates its minimum/schema, and exposes
--- exact field observations so no platform expectation can be weakened into an
--- alternative that accepts a semantically different result.
--- ==============================================================================

local M = {}

M.MIN_VECTOR_COUNT = 34
M.MIN_HARDCODED_ASSERTIONS = 19
M.MIN_CORPUS_ASSERTIONS = 78

local function validate_vector(vector, index, ids)
	if type(vector) ~= "table" then return false, string.format("vector %d is not a table", index) end
	if type(vector.id) ~= "string" or vector.id == "" then
		return false, string.format("vector %d has no id", index)
	end
	if ids[vector.id] then return false, "duplicate vector id: " .. vector.id end
	ids[vector.id] = true
	for _, field in ipairs({ "trigger", "replacement", "buffer" }) do
		if type(vector[field]) ~= "string" then
			return false, string.format("vector %s has no string %s", vector.id, field)
		end
	end
	if type(vector.expected) ~= "table" or type(vector.expected.matched) ~= "boolean" then
		return false, string.format("vector %s has no boolean expected.matched", vector.id)
	end
	if vector.expected.matched then
		if type(vector.expected.replacement) ~= "string" then
			return false, string.format("vector %s has no expected.replacement", vector.id)
		end
		if type(vector.expected.backspace_count) ~= "number"
				or vector.expected.backspace_count < 0
				or vector.expected.backspace_count % 1 ~= 0 then
			return false, string.format("vector %s has invalid expected.backspace_count", vector.id)
		end
	end
	return true
end

--- Validates corpus size, identifiers and every expectation field the runner uses.
--- @param vectors table
--- @return boolean ok
--- @return string|nil error_message
function M.validate_vectors(vectors)
	if type(vectors) ~= "table" then return false, "corpus vectors are not a table" end
	if #vectors < M.MIN_VECTOR_COUNT then
		return false, string.format("corpus has %d vectors; minimum is %d",
			#vectors, M.MIN_VECTOR_COUNT)
	end
	local ids = {}
	for index, vector in ipairs(vectors) do
		local ok, vector_error = validate_vector(vector, index, ids)
		if not ok then return false, vector_error end
	end
	return true
end

--- Reads and validates the mandatory corpus.
--- @param path string
--- @param decode function|nil JSON decoder test seam.
--- @return table|nil vectors
--- @return string|nil error_message
function M.load_corpus(path, decode)
	local file, open_error = io.open(path, "r")
	if not file then return nil, string.format("cannot open corpus %s: %s", path, tostring(open_error)) end
	local raw = file:read("*a")
	file:close()

	local decoder = decode
	if not decoder then
		local ok_json, json_or_error = pcall(require, "json")
		if not ok_json then return nil, "cannot load shared JSON decoder: " .. tostring(json_or_error) end
		decoder = json_or_error.decode
	end
	if type(decoder) ~= "function" then return nil, "JSON decoder is not callable" end
	local ok_decode, decoded = pcall(decoder, raw)
	if not ok_decode then return nil, "corpus JSON decode failed: " .. tostring(decoded) end
	if type(decoded) ~= "table" or type(decoded.vectors) ~= "table" then
		return nil, "corpus JSON has no vectors array"
	end
	local valid, validation_error = M.validate_vectors(decoded.vectors)
	if not valid then return nil, validation_error end
	return decoded.vectors, nil
end

--- Returns one exact observation per expected semantic field.
--- @param expected table
--- @param result table|nil
--- @return table Array of { field, expected, actual }.
function M.observations(expected, result)
	local matched = type(result) == "table"
	local observations = {
		{ field = "matched", expected = expected.matched, actual = matched },
	}
	if expected.matched then
		observations[#observations + 1] = {
			field = "replacement",
			expected = expected.replacement,
			actual = matched and result.replacement or nil,
		}
		observations[#observations + 1] = {
			field = "backspace_count",
			expected = expected.backspace_count,
			actual = matched and result.backspace_count or nil,
		}
	end
	return observations
end

return M
