--- _shared/lua/menu/click_intent.lua

--- ==============================================================================
--- MODULE: Menu Click Intent
--- DESCRIPTION:
--- Names a tray click by its row path and the state it asks for, so a click
--- that cannot run at once (a reload in flight, a stale menu, a refresh not yet
--- published) runs later against the current tree without toggling a row back.
---
--- FEATURES & RATIONALE:
--- 1. Row path, not position or native ID: a rebuilt or successor menu has new
---    IDs and may insert rows; the titles from the root still name the row.
---    An ambiguous title (two siblings share it) matches nothing.
--- 2. Requested state: a check row's click asks for the opposite of the
---    checkmark the user saw. A late click whose row already shows that state
---    would only toggle it back, so it is skipped (the Windows replay schema v3
---    carries the same field, menu_dispatcher.ahk).
--- 3. Pure Lua with no driver dependency: the macOS and Linux menus share it.
--- ==============================================================================

local M = {}




-- =================================
-- =================================
-- ======= 1/ Public API ===========
-- =================================
-- =================================

--- The comparable text of a row title.
--- @param title any Row title.
--- @return string
function M.title_text(title)
	if type(title) == "string" then return title end
	if title == nil then return "" end
	return tostring(title)
end

--- Extends a parent path with one row title, without sharing the parent table.
--- @param prefix table Parent row titles from the root.
--- @param title any Row title.
--- @return table path
function M.child_path(prefix, title)
	local path = {}
	for index, text in ipairs(prefix) do path[index] = text end
	path[#path + 1] = M.title_text(title)
	return path
end

--- The state a click on a row asks for: the opposite of its checkmark.
--- @param checked any The row's checked field when the click was made.
--- @return boolean|nil desired nil for a row without a checkmark.
function M.desired(checked)
	if type(checked) ~= "boolean" then return nil end
	return not checked
end

--- Whether a late click would only re-apply the state it asked for.
--- @param row table The current row the click resolves to.
--- @param desired boolean|nil The state the click asked for.
--- @return boolean applied
function M.already_applied(row, desired)
	return type(desired) == "boolean" and type(row) == "table" and row.checked == desired
end

--- A printable row path for the log.
--- @param path table Row titles from the root.
--- @return string
function M.describe(path)
	return table.concat(path, " > ")
end

--- Finds the row at a title path in a menu tree.
--- @param items table|nil Menu tree, each row { title, fn, menu, checked }.
--- @param path table Row titles from the root.
--- @return table|nil row nil when absent or ambiguous at any level.
function M.find(items, path)
	if type(path) ~= "table" or #path == 0 then return nil end
	local level = items
	for depth, title in ipairs(path) do
		local found = nil
		for _, row in ipairs(type(level) == "table" and level or {}) do
			if type(row) == "table" and M.title_text(row.title) == title then
				if found then return nil end
				found = row
			end
		end
		if not found then return nil end
		if depth == #path then return found end
		level = found.menu
	end
	return nil
end

--- Validates a decoded path list.
--- @param path any
--- @return boolean valid
function M.valid_path(path)
	if type(path) ~= "table" or #path == 0 then return false end
	for index = 1, #path do
		if type(path[index]) ~= "string" then return false end
	end
	return true
end

return M
