--- _shared/lua/test/table_util_contract.lua

--- ==============================================================================
--- MODULE: Table Utilities Contract
--- DESCRIPTION:
--- Pins _shared/lua/table_util.lua to the inline copies it replaces, on both
--- Lua runners: the reference functions below are those copies verbatim, and
--- every vector compares the owner against them (shared-lua-helpers).
--- ==============================================================================

local M = {}

-- The inline shapes the drivers defined before the owner existed.
local function inline_shallow(source)
	local result = {}
	for key, value in pairs(source) do result[key] = value end
	return result
end

local function inline_deep(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do copy[key] = inline_deep(child) end
	return copy
end

local function inline_deep_keys(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do copy[inline_deep_keys(key)] = inline_deep_keys(child) end
	return copy
end

local function inline_sorted_keys(map)
	local keys = {}
	for key in pairs(map) do keys[#keys + 1] = key end
	table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
	return keys
end

local function inline_natural_keys(set)
	local result = {}
	for code in pairs(set) do result[#result + 1] = code end
	table.sort(result)
	return result
end

local function inline_count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

--- Builds a value holding every shape the drivers copy.
--- @return table
local function sample()
	return {
		"first", 2, false, { nested = { deeper = { "x" } } },
		name = "value", [10] = "sparse", flag = true, list = { 1, 2, { 3 } },
	}
end

--- Registers the vectors in a driver suite.
--- @param helpers table Driver test API.
function M.register(helpers)
	local TableUtil = require("table_util")

	helpers.describe("table_util: one owner for the generic table helpers (shared-lua-helpers)", function()
		helpers.it("shared-lua-helpers: shallow_copy matches the inline loop and shares nested tables", function()
			local source = setmetatable(sample(), { __index = function() return "meta" end })
			local copy = TableUtil.shallow_copy(source)
			helpers.assert_true(copy ~= source, "a new table")
			helpers.assert_eq(copy, inline_shallow(source))
			helpers.assert_true(copy[4] == source[4], "nested tables are the same objects")
			helpers.assert_nil(getmetatable(copy), "the metatable is not copied")
			helpers.assert_nil(copy.missing, "no inherited lookups")
		end)

		helpers.it("shared-lua-helpers: deep_copy matches the inline recursion and keeps table keys", function()
			local key = { "key" }
			local source = sample()
			source[key] = { "under a table key" }
			local copy = TableUtil.deep_copy(source)
			local reference = inline_deep(source)
			helpers.assert_eq(copy, reference)
			helpers.assert_true(copy[4] ~= source[4] and copy[4].nested ~= source[4].nested, "nested tables copied")
			helpers.assert_true(copy[key] ~= nil and copy[key] ~= source[key], "a table key keeps its identity")
			helpers.assert_eq(copy[key], { "under a table key" })
			for _, scalar in ipairs({ "text", 5, false, true }) do
				helpers.assert_eq(TableUtil.deep_copy(scalar), inline_deep(scalar))
			end
			helpers.assert_nil(TableUtil.deep_copy(nil), "nil passes through like the inline copy")
		end)

		helpers.it("shared-lua-helpers: deep_copy_with_keys copies table keys like the inline recursion", function()
			local key = { "key" }
			local source = { [key] = { 1 }, plain = { 2 } }
			local copy = TableUtil.deep_copy_with_keys(source)
			local copied_key
			for candidate in pairs(copy) do
				if type(candidate) == "table" then copied_key = candidate end
			end
			helpers.assert_true(copied_key ~= nil and copied_key ~= key, "the key table is copied")
			helpers.assert_eq(copied_key, { "key" })
			helpers.assert_eq(copy.plain, inline_deep_keys(source).plain)
			helpers.assert_eq(TableUtil.deep_copy_with_keys(sample()), inline_deep_keys(sample()))
			helpers.assert_nil(TableUtil.deep_copy_with_keys(nil))
		end)

		helpers.it("shared-lua-helpers: a table reached twice is copied twice; a cycle is refused", function()
			local shared = { 1 }
			local copy = TableUtil.deep_copy({ a = shared, b = shared })
			helpers.assert_true(copy.a ~= copy.b, "two copies, as the inline recursion made")
			helpers.assert_eq(copy.a, copy.b)
			local cyclic = {}
			cyclic.self = cyclic
			helpers.assert_throws(function() TableUtil.deep_copy(cyclic) end, "a cycle raises by name")
			helpers.assert_throws(function() TableUtil.deep_copy_with_keys({ [cyclic] = true }) end)
		end)

		helpers.it("shared-lua-helpers: sorted_keys gives table.sort's own order like the inline copies", function()
			local codes = { [10] = true, [9] = true, [100] = true }
			helpers.assert_eq(TableUtil.sorted_keys(codes), inline_natural_keys(codes))
			helpers.assert_eq(TableUtil.sorted_keys(codes), { 9, 10, 100 })
			local names = { zeta = 1, alpha = 1, Beta = 1 }
			helpers.assert_eq(TableUtil.sorted_keys(names), inline_natural_keys(names))
			helpers.assert_eq(TableUtil.sorted_keys({}), {})
			helpers.assert_throws(function() TableUtil.sorted_keys({ [1] = 1, a = 1 }) end,
				"mixed key types raise, as table.sort(keys) did")
			helpers.assert_throws(function() TableUtil.sorted_keys(codes, "numeric") end, "a comparison is a function")
		end)

		helpers.it("shared-lua-helpers: sorted_keys by_text orders by tostring like the inline copies", function()
			local source = { [10] = 1, [2] = 1, [1] = 1, b = 1, a = 1 }
			helpers.assert_eq(TableUtil.sorted_keys(source, TableUtil.by_text), inline_sorted_keys(source))
			helpers.assert_eq(TableUtil.sorted_keys(source, TableUtil.by_text), { 1, 10, 2, "a", "b" })
		end)

		helpers.it("shared-lua-helpers: count counts array, hash and sparse entries", function()
			for _, source in ipairs({ {}, sample(), { nil, nil, 3 }, { [0] = 1, [-1] = 2, x = 3 } }) do
				helpers.assert_eq(TableUtil.count(source), inline_count(source))
			end
			helpers.assert_eq(TableUtil.count(sample()), 8)
		end)

		helpers.it("shared-lua-helpers: a non-table argument raises at the caller", function()
			for _, name in ipairs({ "shallow_copy", "sorted_keys", "count" }) do
				local ok, failure = pcall(TableUtil[name], nil)
				helpers.assert_true(not ok, name .. " refuses nil")
				helpers.assert_contains(tostring(failure), "table_util." .. name .. " expects a table, got nil")
			end
		end)
	end)
end

return M
