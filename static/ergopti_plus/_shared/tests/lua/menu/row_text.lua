--- _shared/tests/lua/menu/row_text.lua

--- ==============================================================================
--- MODULE: Shared Menu Row Text Check
--- DESCRIPTION:
--- Walks a rendered Lua tray and reports each row whose visible text is an id,
--- a config path, a raw key, snake_case, an unfilled placeholder or a key id
--- or abbreviation the shared key name table names (`lalt`, `LCtrl`), and each
--- French row gluing `:`, `?`, `!` or `;` to its word. The Windows
--- walk applies the same rule from tools/test/lib/menu-row-text.cjs; both read
--- _shared/tests/corpus/menu_row_text_allowlist.json.
---
--- USAGE (one call per driver suite and locale):
---   local check = require("tests.lua.menu.row_text")
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
	return read_json(shared_root, "core/i18n/data/locales/" .. locale .. ".json", json_decode)
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

-- Spellings of the key name table that are also plain words of a sentence
-- (`alt` is « all » in Danish, « old » in German): a row may hold them.
-- tools/test/lib/menu-row-text.cjs keeps the same list.
local PROSE_SPELLINGS = {
	alt = true, tab = true, space = true, enter = true, delete = true, option = true, ["return"] = true,
	command = true, control = true, super = true, caps = true, escape = true, shift = true, meta = true,
	insert = true, home = true, ["end"] = true,
}

--- Every key spelling a row must never show: the ids and aliases of
--- layouts/data/keycodes/key_names.json that read as no word, and the side
--- abbreviations the Tap-Hold rows used to print (LCtrl, RShift, LAlt…).
--- @param shared_root string Path of _shared.
--- @param json_decode function JSON decoder.
--- @return table Set of spellings, matched case-exactly.
function M.raw_key_spellings(shared_root, json_decode)
	local table_ = read_json(shared_root, "layouts/data/keycodes/key_names.json", json_decode)
	local out = {}
	for _, field in ipairs({ "keys", "aliases" }) do
		for spelling in pairs(table_[field]) do
			if not PROSE_SPELLINGS[spelling] then out[spelling] = true end
		end
	end
	for _, side in ipairs({ "L", "R" }) do
		for _, name in ipairs({ "Ctrl", "Shift", "Alt", "Win", "Cmd", "Option" }) do out[side .. name] = true end
	end
	return out
end

--- The ids and config paths no row may show.
--- @param shared_root string Path of _shared.
--- @param json_decode function JSON decoder.
--- @return table Set of texts.
local function identifiers(shared_root, json_decode)
	local out = {}
	collect_ids(read_json(shared_root, "menu/data/menu_manifest.json", json_decode), out)
	local handle = assert(io.open(shared_root .. "/settings/engine/features/manifest_data.lua", "rb"))
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
--- @param raw_keys table|nil Set from M.raw_key_spellings.
--- @return string|nil The defect, nil for a text that reads as text.
function M.defect(text, known, allowlist, raw_keys)
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
	-- Case-exact: « Ctrl » and « Alt » are the names, `ctrl`, `lalt`, `LCtrl` the ids.
	for word in label:gmatch("[%w_\128-\255]+") do
		if raw_keys and raw_keys[word] then return "shows the raw key \"" .. word .. "\"" end
	end
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

--- Names the glued word and mark of a French row, nil when it reads right. The
--- bytes before a mark also start with a high byte in « é », so a no-break space
--- is told apart by its full spelling.
--- @param text string French row text.
--- @return string|nil
function M.french_punctuation_defect(text)
	local probe = text .. " "
	local start = 1
	while true do
		local at = probe:find("[:?!;]%s", start)
		if at == nil then return nil end
		local before = probe:sub(1, at - 1)
		local spaced = before:find("%s$") or before:find("\194\160$") or before:find("\226\128\175$")
		local glued = not spaced and before:find("[%w\128-\255%)%]}]$")
		if glued then
			local word = before:match("[^%s]*$")
			local scheme = probe:sub(at, at) == ":" and (word:match("https?$") or word:match("msteams$"))
			if not scheme then return word .. probe:sub(at, at) end
		end
		start = at + 1
	end
end

--- Judges every row of a rendered tray.
--- @param tray table Rendered rows, `title` and `menu`.
--- @param shared_root string Path of _shared.
--- @param json_decode function JSON decoder.
--- @param locale string|nil Locale of the texts; "fr" adds the punctuation rule.
--- @return table defects, number rows
function M.defects(tray, shared_root, json_decode, locale)
	local allowlist = read_json(shared_root, "tests/corpus/menu_row_text_allowlist.json", json_decode).entries
	local known = identifiers(shared_root, json_decode)
	local raw_keys = M.raw_key_spellings(shared_root, json_decode)
	local defects, rows = {}, 0
	walk(tray, "tray", function(text, trail)
		rows = rows + 1
		local defect = M.defect(text, known, allowlist, raw_keys)
		if defect then defects[#defects + 1] = trail .. " > \"" .. text .. "\" " .. defect end
		local glued = locale == "fr" and M.french_punctuation_defect(text) or nil
		if glued then defects[#defects + 1] = trail .. " > \"" .. text .. "\" glues \"" .. glued .. "\"" end
	end)
	return defects, rows
end

--- Proves the French walk reaches each submenu row that joins a label to its
--- value: a walk that stops short would judge none of them.
--- @param tray table Rendered rows.
--- @param shared_root string Path of _shared.
--- @param json_decode function JSON decoder.
--- @param catalogue table The French catalogue.
--- @param platform string Manifest platform name.
--- @return table The labels no rendered row spells with « label : ».
function M.missing_label_value_rows(tray, shared_root, json_decode, catalogue, platform)
	local titles = {}
	walk(tray, "tray", function(text) titles[#titles + 1] = text end)
	local missing, seen = {}, {}
	local function shown_here(platforms)
		if platforms == nil then return true end
		for _, name in ipairs(platforms) do
			if name == platform then return true end
		end
		return false
	end
	local function visit(node)
		if type(node) ~= "table" then return end
		if node.current_choice_label_value == true and shown_here(node.platforms) and not seen[node.i18n] then
			seen[node.i18n] = true
			local spelled = catalogue[node.i18n] .. " : "
			local found = false
			for _, title in ipairs(titles) do
				found = found or title:find(spelled, 1, true) ~= nil
			end
			if not found then missing[#missing + 1] = spelled end
		end
		for _, value in pairs(node) do visit(value) end
	end
	visit(read_json(shared_root, "menu/data/menu_manifest.json", json_decode))
	table.sort(missing)
	return missing
end

return M
