--- _shared/lua/menu/frames/parent_source.lua

--- ==============================================================================
--- MODULE: Menu Parent Source Admission
--- DESCRIPTION:
--- Admits the actual declared structure of one top-level menu parent (Debug,
--- Configuration, Metrics, About) before a native builder renders its children,
--- and later proves that the direct parent row is still the one it admitted.
---
--- FEATURES & RATIONALE:
--- 1. Raw reads only: `rawget`, `next` and `rawequal` keep source metamethods
---    from running while the structure is admitted or rechecked.
--- 2. One body for every section. A section differs only by its parent id (the
---    section name), the root key of its children and three explicit options,
---    declared once in SECTIONS: `children_required` (About needs a child),
---    `plain_label` (About has no label prefix) and `protect_root` (Metrics
---    reads the root under pcall). Both drivers delegate here, so one text and
---    one contract replace the eight copies the drivers carried.
--- 3. Pure Lua with no driver dependency: the renderer is injected.
--- ==============================================================================

local M = {}

--- The sections this module admits, by parent id.
local SECTIONS = {
	debug = { children = "debug_menu" },
	configuration = { children = "configuration_menu" },
	metrics = { children = "metrics_menu", protect_root = true },
	about = { children = "about_menu", children_required = true, plain_label = true },
}





-- =============================
-- =============================
-- ======= 1/ Admission ========
-- =============================
-- =============================

--- Checks raw dense arrays without triggering source metamethods.
--- @param value table Source array.
--- @param records boolean Whether its values must be plain records.
--- @return boolean
local function dense(value, records)
	if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
	local count, maximum = 0, 0
	for index, row in next, value do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 then return false end
		if records and (type(row) ~= "table" or getmetatable(row) ~= nil) then return false end
		count, maximum = count + 1, math.max(maximum, index)
	end
	return count == maximum
end

--- Admits the actual source structure of a section without interpreting its row grammar.
--- @param renderer table|nil Actual manifest renderer.
--- @param platform string Native platform token.
--- @param section string Parent id: a key of SECTIONS.
--- @return table|nil root, table|nil top, table|nil children, table|nil parent, table|nil fields
local function read_source(renderer, platform, section)
	local spec = SECTIONS[section]
	if spec == nil then error("menu parent source: unknown section " .. tostring(section), 3) end
	if type(renderer) ~= "table" or type(rawget(renderer, "get_root")) ~= "function"
		or type(rawget(renderer, "build")) ~= "function" or type(rawget(renderer, "group_row")) ~= "function" then return nil end

	local root
	if spec.protect_root then
		local ok
		ok, root = pcall(renderer.get_root)
		if not ok then return nil end
	else
		root = renderer.get_root()
	end
	if type(root) ~= "table" or getmetatable(root) ~= nil then return nil end
	local top, children = rawget(root, "top_level"), rawget(root, spec.children)
	if not dense(top, true) or not dense(children, true) then return nil end
	if spec.children_required and #children == 0 then return nil end
	local parent
	for _, row in next, top do
		if rawget(row, "id") == section then
			if parent then return nil end
			parent = row
		end
	end
	if parent == nil or rawget(parent, "type") ~= "group" or type(rawget(parent, "i18n")) ~= "string"
		or rawget(parent, "i18n") == "" or not dense(rawget(parent, "rows"), true) then return nil end
	if spec.plain_label and rawget(parent, "label_prefix") ~= nil then return nil end
	local platforms = rawget(parent, "platforms")
	if platforms ~= nil then
		if not dense(platforms, false) then return nil end
		local visible = false
		for _, token in next, platforms do
			if type(token) ~= "string" then return nil end
			if token == platform then visible = true end
		end
		if not visible then return nil end
	end
	local fields = {}
	for key, value in next, parent do fields[key] = value end
	return root, top, children, parent, fields
end

--- Rechecks the captured direct parent fields without source metamethods.
--- @param parent table Actual direct source row.
--- @param fields table Captured raw field references and scalar values.
--- @return boolean
local function parent_unchanged(parent, fields)
	for key, value in next, parent do
		if not rawequal(value, rawget(fields, key)) then return false end
	end
	for key, value in next, fields do
		if not rawequal(value, rawget(parent, key)) then return false end
	end
	return true
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Checks raw dense arrays without triggering source metamethods.
--- @param value table Source array.
--- @param records boolean Whether its values must be plain records.
--- @return boolean
function M.dense(value, records)
	return dense(value, records)
end

--- Admits the actual source structure of a section.
--- @param renderer table|nil Actual manifest renderer.
--- @param platform string Native platform token.
--- @param section string "debug", "configuration", "metrics" or "about".
--- @return table|nil root, table|nil top, table|nil children, table|nil parent, table|nil fields
function M.read(renderer, platform, section)
	return read_source(renderer, platform, section)
end

--- Rechecks the captured direct parent fields without source metamethods.
--- @param parent table Actual direct source row.
--- @param fields table Captured raw field references and scalar values.
--- @return boolean
function M.unchanged(parent, fields)
	return parent_unchanged(parent, fields)
end

return M
