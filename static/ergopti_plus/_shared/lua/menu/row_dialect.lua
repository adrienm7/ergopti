--- _shared/lua/menu/row_dialect.lua

--- ==============================================================================
--- MODULE: External Menu Row Dialect
--- DESCRIPTION:
--- Detaches collected user rows into provider data without running their callbacks.
--- Native and provider aliases retain the same literal presentation and payload;
--- ambiguous or malformed semantic trees are refused before menu publication.
--- ==============================================================================

local M = {}
local MAX_DEPTH = 8
local NATIVE_FIELDS = { title = true, fn = true, menu = true, submenu = true }

--- Converts a whole collected external subtree by raw inspection only.
--- Non-presentation payload is retained but never interpreted as menu policy.
--- @param rows table Dense native or provider rows collected by the actual owner.
--- @return table|nil Detached provider rows, nil for an unadmitted whole tree.
function M.rows(rows)
	local active = {}
	local function convert(list, depth)
		if type(list) ~= "table" or getmetatable(list) ~= nil or active[list] or depth > MAX_DEPTH then return nil end
		local count, maximum = 0, 0
		for index in next, list do
			if type(index) ~= "number" or index % 1 ~= 0 or index < 1 then return nil end
			count, maximum = count + 1, math.max(maximum, index)
		end
		if count ~= maximum then return nil end
		active[list] = true
		local out = {}
		for index = 1, count do
			local row = rawget(list, index)
			if type(row) ~= "table" or getmetatable(row) ~= nil then return nil end
			local title, label = rawget(row, "title"), rawget(row, "label")
			local fn, action = rawget(row, "fn"), rawget(row, "action")
			local menu, items = rawget(row, "menu"), rawget(row, "items")
			local submenu = rawget(row, "submenu")
			if title ~= nil and type(title) ~= "string" or label ~= nil and type(label) ~= "string"
				or fn ~= nil and type(fn) ~= "function" or action ~= nil and type(action) ~= "function"
				or menu ~= nil and type(menu) ~= "table" or items ~= nil and type(items) ~= "table"
				or submenu ~= nil and type(submenu) ~= "table" then return nil end
			if title ~= nil and label ~= nil and title ~= label
				or fn ~= nil and action ~= nil and not rawequal(fn, action)
				or menu ~= nil and items ~= nil and not rawequal(menu, items)
				or submenu ~= nil and items ~= nil and not rawequal(submenu, items)
				or submenu ~= nil and menu ~= nil and not rawequal(submenu, menu) then return nil end
			if label == nil then label = title end
			if action == nil then action = fn end
			if items == nil then items = menu or submenu end
			local separator, checked = rawget(row, "separator"), rawget(row, "checked")
			local disabled, image = rawget(row, "disabled"), rawget(row, "image")
			local reason = rawget(row, "disabled_reason_key")
			if separator ~= nil and type(separator) ~= "boolean"
				or reason ~= nil and type(reason) ~= "string"
				or checked ~= nil and type(checked) ~= "boolean"
				or disabled ~= nil and type(disabled) ~= "boolean"
				or action ~= nil and type(action) ~= "function"
				or image ~= nil and type(image) ~= "string" and type(image) ~= "userdata"
				or items ~= nil and type(items) ~= "table"
				or action ~= nil and items ~= nil then return nil end
			local converted = {}
			for field, value in next, row do
				if type(field) ~= "string" then return nil end
				if not NATIVE_FIELDS[field] then converted[field] = value end
			end
			if separator == true or title == "-" then
				if label ~= nil and label ~= "-" or action ~= nil or items ~= nil
					or checked ~= nil or disabled ~= nil or image ~= nil then return nil end
				converted.label, converted.action, converted.items = nil, nil, nil
				converted.separator = true
			else
				if type(label) ~= "string" or label == "" then return nil end
				converted.label, converted.action = label, action
				if items ~= nil then
					converted.items = convert(items, depth + 1)
					if converted.items == nil then return nil end
				end
			end
			out[index] = converted
		end
		active[list] = nil
		return out
	end
	return convert(rows, 1)
end

--- Converts one existing external row through the same complete-tree boundary.
--- @param row table Native or provider row from the actual collected input.
--- @return table|nil Detached provider row, nil when the row is unadmitted.
function M.row(row)
	local rows = M.rows({ row })
	return rows and rows[1] or nil
end

return M
