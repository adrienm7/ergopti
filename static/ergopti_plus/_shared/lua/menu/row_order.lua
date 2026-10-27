--- _shared/lua/menu/row_order.lua

--- ==============================================================================
--- MODULE: Menu Row Order
--- DESCRIPTION:
--- The display-order rules of the menus, read from the generated projection of
--- _shared/modules/menu/row_order.json. No driver spells an order of its own.
---
--- FEATURES & RATIONALE:
--- 1. An unknown rule is an error: a typo must not silently sort nothing.
--- 2. Callers get detached copies, so one menu cannot reorder another's rule.
--- 3. A name outside a rule ranks after every listed name, so a new entry shows
---    up last instead of vanishing.
--- ==============================================================================

local Data = require("menu.row_order_data")

local M = {}

local function rule(name)
	local order = Data[name]
	if type(name) ~= "string" or order == nil then
		error("unknown menu row order rule: " .. tostring(name), 3)
	end
	return order
end

--- The ordered names of one rule.
--- @param name string Rule name from row_order.json.
--- @return string[] order A fresh array.
function M.list(name)
	local order = rule(name)
	local copy = {}
	for index, item in ipairs(order) do copy[index] = item end
	return copy
end

--- The position of every name of one rule.
--- @param name string Rule name from row_order.json.
--- @return table rank name -> 1-based position.
function M.rank(name)
	local rank = {}
	for index, item in ipairs(rule(name)) do rank[item] = index end
	return rank
end

--- Whether `left` is listed before `right`; unlisted names follow the listed ones
--- and compare by text among themselves.
--- @param name string Rule name from row_order.json.
--- @param rank table|nil The result of M.rank(name), to avoid rebuilding it per comparison.
--- @return function before function(left, right) -> boolean, usable with table.sort.
function M.comparator(name, rank)
	rank = rank or M.rank(name)
	local unlisted = #rule(name) + 1
	return function(left, right)
		local left_rank, right_rank = rank[left] or unlisted, rank[right] or unlisted
		if left_rank == right_rank then return left < right end
		return left_rank < right_rank
	end
end

return M
