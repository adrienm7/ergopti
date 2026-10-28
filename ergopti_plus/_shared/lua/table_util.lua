--- _shared/lua/table_util.lua

--- ==============================================================================
--- MODULE: Table Utilities
--- DESCRIPTION:
--- The one owner of the generic table helpers the Lua drivers used to define
--- inline: shallow and deep copies, sorted key lists and entry counts.
---
--- FEATURES & RATIONALE:
--- 1. Same results as the inline copies they replace: a copy walks pairs(),
---    drops the metatable and keeps every key as it was unless the caller asks
---    for the keys to be copied too.
--- 2. Fail fast: a helper given something other than a table raises at the
---    caller, as the inline loops did when pairs() met a nil. A cyclic table
---    is refused by name instead of overflowing the stack.
--- 3. Pure: no driver, file system or host dependency, so every boot stage
---    can load it once the shared Lua root is on package.path.
--- 4. tools/test/test-shared-lua-helpers-single-use.cjs fails when a driver
---    or shared module defines one of these helpers inline again.
--- ==============================================================================

local M = {}

--- Raises at the caller of a helper when its argument is not a table.
--- @param value any Candidate argument.
--- @param helper string Helper name, for the message.
local function require_table(value, helper)
	if type(value) ~= "table" then
		error(string.format("table_util.%s expects a table, got %s", helper, type(value)), 3)
	end
end

--- Copies one level: the copy holds the same keys and values.
--- @param source table Table to copy.
--- @return table copy New table without the source's metatable.
function M.shallow_copy(source)
	require_table(source, "shallow_copy")
	local copy = {}
	for key, value in pairs(source) do copy[key] = value end
	return copy
end

--- Copies a value recursively.
--- @param value any Value to copy.
--- @param copy_keys boolean Whether table keys are copied as well as values.
--- @param visiting table Tables on the current path, to refuse a cycle.
--- @return any copy
local function deep_copy(value, copy_keys, visiting)
	if type(value) ~= "table" then return value end
	if visiting[value] then error("table_util: deep copy of a cyclic table", 0) end
	visiting[value] = true
	local copy = {}
	for key, child in pairs(value) do
		if copy_keys then key = deep_copy(key, copy_keys, visiting) end
		copy[key] = deep_copy(child, copy_keys, visiting)
	end
	visiting[value] = nil
	return copy
end

--- Copies every nested table value; keys stay the same objects, so a table
--- used as a key keeps its identity. A table reached twice without a cycle
--- is copied twice. Any other value is returned unchanged.
--- @param value any Value to copy.
--- @return any copy
function M.deep_copy(value)
	if type(value) ~= "table" then return value end
	return deep_copy(value, false, {})
end

--- Copies every nested table, keys included. Any other value is returned
--- unchanged.
--- @param value any Value to copy.
--- @return any copy
function M.deep_copy_with_keys(value)
	if type(value) ~= "table" then return value end
	return deep_copy(value, true, {})
end

--- Orders two keys by their tostring() text, so a table mixing number and
--- string keys sorts without raising. Pass it to sorted_keys.
--- @param left any
--- @param right any
--- @return boolean
function M.by_text(left, right) return tostring(left) < tostring(right) end

--- Lists a table's keys in order: Lua's own < order, as table.sort(keys)
--- gives (numbers numerically, strings bytewise, mixed types raise), unless
--- the caller passes a comparison such as M.by_text.
--- @param source table Table whose keys are listed.
--- @param compare function|nil table.sort comparison of two keys.
--- @return table keys Array of the keys, sorted.
function M.sorted_keys(source, compare)
	require_table(source, "sorted_keys")
	if compare ~= nil and type(compare) ~= "function" then
		error("table_util.sorted_keys expects a comparison function, got " .. type(compare), 2)
	end
	local keys = {}
	for key in pairs(source) do keys[#keys + 1] = key end
	table.sort(keys, compare)
	return keys
end

--- Counts every entry, array and hash parts alike.
--- @param source table Table to count.
--- @return integer count
function M.count(source)
	require_table(source, "count")
	local count = 0
	for _ in pairs(source) do count = count + 1 end
	return count
end

return M
