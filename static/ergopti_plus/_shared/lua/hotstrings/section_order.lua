--- hotstrings/section_order.lua

--- ==============================================================================
--- MODULE: Hotstring Section Menu Order
--- DESCRIPTION:
--- Resolves per-category section order without changing the hotstring catalogue.
--- Unknown saved names are ignored, newly shipped sections are appended, and
--- moving a section swaps named positions while retaining visual separators.
--- ==============================================================================

local M = {}
local COMMAND = require("config_keys").COMMAND

--- Accepts only a dense text list, including an empty saved override.
--- @param value any
--- @return boolean
function M.valid(value)
	if type(value) ~= "table" then return false end
	local count = 0
	for key, entry in pairs(value) do
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) or type(entry) ~= "string" then return false end
		count = count + 1
	end
	for index = 1, count do if value[index] == nil then return false end end
	return true
end

--- Orders the discovered names using a saved override, without mutating either.
--- @param source table Discovered names, with optional "-" separators.
--- @param override table|nil Saved names.
--- @return table|nil order
function M.resolve(source, override)
	if not M.valid(source) or override ~= nil and not M.valid(override) then return nil end
	local known, seen, result = {}, {}, {}
	for _, name in ipairs(source) do if name ~= "-" then known[name] = true end end
	local function append(name)
		if name == "-" then
			if #result > 0 and result[#result] ~= "-" then result[#result + 1] = name end
		elseif known[name] and not seen[name] then
			result[#result + 1], seen[name] = name, true
		end
	end
	for _, name in ipairs(override or source) do append(name) end
	if override ~= nil then
		for _, name in ipairs(source) do if name ~= "-" then append(name) end end
	end
	if result[#result] == "-" then table.remove(result) end
	return result
end

--- Moves a named section past its previous/next named neighbour.
--- @param order table Current resolved names.
--- @param name string Selected section.
--- @param delta number Exactly -1 or 1.
--- @param visible table|nil Names drawn as movable sections.
--- @return table|nil candidate A boundary or invalid move is refused.
function M.move(order, name, delta, visible)
	if not M.valid(order) or name == "-" or delta ~= -1 and delta ~= 1 then return nil end
	local result, selected = {}, nil
	for index, entry in ipairs(order) do result[index] = entry; if entry == name then selected = index end end
	if not selected then return nil end
	local neighbour = selected + delta
	while result[neighbour] and (result[neighbour] == "-" or visible and not visible[result[neighbour]]) do neighbour = neighbour + delta end
	if not result[neighbour] then return nil end
	result[selected], result[neighbour] = result[neighbour], result[selected]
	return result
end

--- Builds one declared submenu from the currently rendered section labels.
--- @param template_rows function Native manifest template renderer.
--- @param order table Current resolved names.
--- @param labels table Name to translated label.
--- @param commit function Receives a fresh order, or nil to restore the source.
--- @param ready function Rechecks the native mutation admission at click time.
--- @return table Declared parent rows.
function M.menu(template_rows, order, labels, commit, ready)
	local entries = {}
	for _, name in ipairs(order) do
		if name ~= "-" and labels[name] then
			local function move(delta)
				if ready() ~= true then return false end
				local next_order = M.move(order, name, delta, labels)
				return next_order ~= nil and commit(next_order) == true
			end
			local children = template_rows("hotstring_order_moves", {
				[COMMAND.HOTSTRING_ORDER_UP] = function() return move(-1) end,
				[COMMAND.HOTSTRING_ORDER_DOWN] = function() return move(1) end,
			}, {
				hotstring_order_up_ready = function() return ready() and M.move(order, name, -1, labels) ~= nil end,
				hotstring_order_down_ready = function() return ready() and M.move(order, name, 1, labels) ~= nil end,
			}, {})
			if children then entries[#entries + 1] = { label = labels[name], items = children } end
		end
	end
	if #entries < 2 then return {} end
	local reset = template_rows("hotstring_order_footer", {
		[COMMAND.HOTSTRING_ORDER_RESET] = function() return ready() == true and commit(nil) == true end,
	}, { hotstring_order_ready = ready }, {})
	for _, row in ipairs(reset or {}) do entries[#entries + 1] = row end
	return template_rows("hotstring_order_parent", {}, {}, { hotstring_order_children = entries }) or {}
end

return M
