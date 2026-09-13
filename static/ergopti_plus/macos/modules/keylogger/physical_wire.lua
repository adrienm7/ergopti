--- modules/keylogger/physical_wire.lua

--- Validates exact physical stream representations without numeric coercion.
local M = {}
local UINT64_MAX = "18446744073709551615"

--- Validates a canonical unsigned decimal string.
---@param value string Wire value.
---@param positive boolean Require a nonzero value.
---@return string
function M.decimal(value, positive)
	assert(type(value) == "string" and value:match("^%d+$")
		and (value == "0" or value:sub(1, 1) ~= "0")
		and (#value < #UINT64_MAX or (#value == #UINT64_MAX and value <= UINT64_MAX))
		and (not positive or value ~= "0"), "Invalid physical decimal identifier")
	return value
end

--- Compares already validated decimal strings without losing uint64 precision.
---@param left string Canonical decimal.
---@param right string Canonical decimal.
---@return boolean
function M.less(left, right) return #left < #right or (#left == #right and left < right) end

--- Increments a canonical decimal sequence without converting it to a number.
---@param value string Canonical sequence.
---@return string
function M.successor(value)
	assert(value ~= UINT64_MAX, "Physical sequence exhausted")
	local prefix, suffix = value:match("^(.-)(9*)$")
	if prefix == "" then return "1" .. string.rep("0", #suffix) end
	return prefix:sub(1, -2) .. tostring(tonumber(prefix:sub(-1)) + 1) .. string.rep("0", #suffix)
end

--- Validates a bounded integer represented as a JSON number.
---@param value number Wire value.
---@param minimum number Inclusive minimum.
---@param maximum number Inclusive maximum.
---@return number
function M.integer(value, minimum, maximum)
	assert(type(value) == "number" and value % 1 == 0 and value >= minimum and value <= maximum,
		"Invalid physical integer")
	return value
end

--- Rejects missing or additional fields in an object.
---@param value table Decoded object.
---@param names table Expected field names.
function M.fields(value, names)
	assert(type(value) == "table", "Invalid physical object")
	local expected = {}
	for _, name in ipairs(names) do
		assert(value[name] ~= nil, "Missing physical field: " .. name)
		expected[name] = true
	end
	for name in pairs(value) do assert(expected[name], "Unexpected physical field") end
end

--- Validates a bounded dense array and returns its length.
---@param value table Decoded array.
---@param minimum number Inclusive minimum length.
---@param maximum number Inclusive maximum length.
---@return number
function M.array(value, minimum, maximum)
	assert(type(value) == "table", "Invalid physical array")
	local length = M.integer(#value, minimum, maximum)
	for key in pairs(value) do M.integer(key, 1, length) end
	for index = 1, length do assert(value[index] ~= nil, "Sparse physical array") end
	return length
end

return M
