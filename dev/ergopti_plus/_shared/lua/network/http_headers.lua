--- _shared/lua/network/http_headers.lua

--- ==============================================================================
--- MODULE: Shared Immutable HTTP Header Preparation
--- DESCRIPTION:
--- Converts caller metadata once in its original sorted order. Native consumers
--- retain the ordered rows; the detached string view supports redirect filtering.
--- No URL, proxy, timeout or native ownership state is cached with headers.
--- ==============================================================================

local M = {}

--- Captures immutable header strings using the original wire conversion order.
--- @param headers table
--- @param validate function Canonical forbidden-byte policy.
--- @return table rows Ordered detached string pairs.
--- @return table view Last value for each normalized field name.
function M.capture(headers, validate)
	if type(headers) ~= "table" or type(validate) ~= "function" then error("HTTP headers are invalid") end
	local names, rows, view = {}, {}, {}
	for name in pairs(headers) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		local header_name, header_value = tostring(name), tostring(headers[name])
		local allowed, err = validate(header_name, header_value)
		if not allowed then error(err) end
		rows[#rows + 1] = { name = header_name, value = header_value }
		view[header_name] = header_value
	end
	return rows, view
end

--- Copies only immutable strings; the caller cannot mutate the retained view.
--- @param view table
--- @return table
function M.copy(view)
	local detached = {}
	for name, value in next, view do detached[name] = value end
	return detached
end

--- Compares only detached plain string fields; this never evaluates metadata.
--- @param headers table
--- @param view table
--- @return boolean
function M.matches(headers, view)
	if type(headers) ~= "table" or getmetatable(headers) ~= nil then return false end
	local count, expected = 0, 0
	for name, value in next, view do
		expected = expected + 1
		if rawget(headers, name) ~= value then return false end
	end
	for name, value in next, headers do
		count = count + 1
		if type(name) ~= "string" or type(value) ~= "string" or rawget(view, name) ~= value then return false end
	end
	return count == expected
end

--- Selects only unchanged fields from a previously admitted ordered snapshot.
--- @param rows table
--- @param view table
--- @param subset table
--- @return table|nil rows
--- @return table|nil view
function M.subset(rows, view, subset)
	if type(subset) ~= "table" or getmetatable(subset) ~= nil then return nil end
	local selected, copy = {}, {}
	for name, value in next, subset do
		if type(name) ~= "string" or type(value) ~= "string" or rawget(view, name) ~= value then return nil end
		copy[name] = value
	end
	-- Preserve every original duplicate wire field and its exact order; a
	-- redirect may remove a field, but cannot rewrite its admitted values.
	for _, row in ipairs(rows) do
		if rawget(copy, row.name) ~= nil then
			selected[#selected + 1] = { name = row.name, value = row.value }
		end
	end
	return selected, copy
end

return M
