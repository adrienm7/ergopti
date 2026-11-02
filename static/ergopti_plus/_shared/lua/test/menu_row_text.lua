--- _shared/lua/test/menu_row_text.lua

--- ==============================================================================
--- MODULE: Shared Menu Row Text Check
--- DESCRIPTION:
--- Walks a rendered Lua tray and reports each row whose visible text is an id,
--- a config path, a raw key, snake_case or an unfilled placeholder. The Windows
--- walk applies the same rule from tools/test/lib/menu-row-text.cjs; both read
--- _shared/tests/corpus/menu_row_text_allowlist.json.
---
--- USAGE (one call per driver suite and locale):
---   local check = require("test.menu_row_text")
---   local catalogue = check.catalogue(shared_root, "fr", json_decode)
---   local defects, rows = check.defects(tray, shared_root, json_decode)
--- ==============================================================================

local M = {}

local SEPARATOR = "-"





-- ====================================
-- ====================================
-- ======= 1/ Reference Data ==========
-- ====================================
-- ====================================

--- Reads and decodes one shared JSON file.
--- @param shared_root string Path of _shared.
--- @param relative string Path below it.
--- @param json_decode function JSON decoder.
--- @return table
local function read_json(shared_root, relative, json_decode)
	local handle = assert(io.open(shared_root .. "/" .. relative, "rb"))
	local text = handle:read("*a")
	handle:close()
	return json_decode(text)
end

--- Loads one real locale catalogue.
--- @param shared_root string Path of _shared.
--- @param locale string Locale code.
--- @param json_decode function JSON decoder.
--- @return table Key to text.
function M.catalogue(shared_root, locale, json_decode)
	return read_json(shared_root, "data/locales/" .. locale .. ".json", json_decode)
end

--- Records every id of a manifest tree.
--- @param node any Current node.
--- @param out table Set of ids.
local function collect_ids(node, out)
	if type(node) ~= "table" then return end
	if type(node.id) == "string" and node.id ~= "---" then out[node.id] = true end
	if type(node.path) == "string" then out[node.path] = true end
	for _, value in pairs(node) do collect_ids(value, out) end
end

--- The ids and config paths no row may show.
--- @param shared_root string Path of _shared.
--- @param json_decode function JSON decoder.
--- @return table Set of texts.
local function identifiers(shared_root, json_decode)
	local out = {}
	collect_ids(read_json(shared_root, "modules/menu/menu_manifest.json", json_decode), out)
	local handle = assert(io.open(shared_root .. "/lua/features/manifest_data.lua", "rb"))
	local source = handle:read("*a")
	handle:close()
	for path in source:gmatch('path = "([^"]+)"') do
		out[path] = true
		out[path:match("([^.]+)$")] = true
	end
	return out
end





-- ====================================
-- ====================================
-- ======= 2/ The Rule ================
-- ====================================
-- ====================================

--- Names what is wrong with one row's text.
--- @param text string Visible row text.
--- @param known table Set of ids and paths.
--- @param allowlist table Allowlist entries.
--- @return string|nil The defect, nil for a text that reads as text.
function M.defect(text, known, allowlist)
	for _, entry in ipairs(allowlist) do
		if text:find(entry.lua_pattern) then return nil end
	end
	-- A hotstring row ends with its entry count, which is no part of the label.
	local label = text:gsub("%s*%(%d+%)$", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if known[label] then return "equals an id or a config path" end
	for word in label:gmatch("%S+") do
		-- Segments start with a letter: « v2.2.1 » is a version, not a key.
		if word:match("^%l[%w_]*%.%a[%w_.]*$") then return "reads as a dotted key" end
	end
	for word in label:gmatch("[%w_\128-\255]+") do
		if word:match("^[%l%d]+_[%l%d_]+$") then return "reads as snake_case" end
	end
	if label:find("{%d*}") or label:find("%%[sd]") then return "holds an unfilled placeholder" end
	return nil
end

--- Walks a rendered tray.
--- @param rows table Rendered rows.
--- @param trail string Parent titles.
--- @param visit function Called with (text, trail).
local function walk(rows, trail, visit)
	for _, row in ipairs(rows) do
		if type(row) == "table" and type(row.title) == "string" and row.title ~= SEPARATOR then
			visit(row.title, trail)
			if type(row.menu) == "table" then walk(row.menu, trail .. " > " .. row.title, visit) end
		end
	end
end

--- Judges every row of a rendered tray.
--- @param tray table Rendered rows, `title` and `menu`.
--- @param shared_root string Path of _shared.
--- @param json_decode function JSON decoder.
--- @return table defects, number rows
function M.defects(tray, shared_root, json_decode)
	local allowlist = read_json(shared_root, "tests/corpus/menu_row_text_allowlist.json", json_decode).entries
	local known = identifiers(shared_root, json_decode)
	local defects, rows = {}, 0
	walk(tray, "tray", function(text, trail)
		rows = rows + 1
		local defect = M.defect(text, known, allowlist)
		if defect then defects[#defects + 1] = trail .. " > \"" .. text .. "\" " .. defect end
	end)
	return defects, rows
end

return M
