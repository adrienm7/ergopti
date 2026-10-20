-- _shared/lua/layout/layout_rows_policy.lua
-- ============================================================================
-- MODULE: Layout Rows Policy
-- DESCRIPTION:
-- The four physical rows a layout emulation types, each behind its own [layout]
-- switch (emulate_<row>, declared in the features manifest): which keys each
-- row holds, read from the shared physical-key registry, and whether a row is
-- emulated. Twin of _shared/modules/features/layout_rows_policy.ahk; both replay
-- tests/corpus/layouts/layout_rows.json. Only Windows emulates a layout today,
-- so macOS and Linux use it to state the rows their menus grey.
-- ============================================================================

local M = {}

--- The rows in registry order: ISO geometry rows 1 (the number row) to 4.
M.IDS = { "number_row", "top_row", "home_row", "bottom_row" }

--- The character keys of each emulated row, from the physical-key registry:
--- the alphanumeric keys that type a character (no layout-independent Send
--- name) on ISO rows 1 to 4, left to right.
--- @param registry table Decoded _shared/data/keycodes/physical_keys.json.
--- @param is_null function|nil Tells a decoded JSON null apart (the decoder's own sentinel).
--- @return table Row id -> array of KeyboardEvent.code, left to right.
function M.keys(registry, is_null)
	if type(registry) ~= "table" or type(registry.keys) ~= "table" then
		error("The layout rows need the physical-key registry.")
	end
	local columns = {}
	for _, row in ipairs(M.IDS) do columns[row] = {} end
	for code, key in pairs(registry.keys) do
		local send = type(key) == "table" and key.ahk_send or nil
		local character = send == nil or (type(is_null) == "function" and is_null(send)) or send == ""
		local iso = type(key) == "table" and type(key.geometry) == "table" and key.geometry.iso or nil
		if character and key.kind == "key" and key.group == "alphanumeric" and type(iso) == "table"
			and type(iso.row) == "number" and iso.row >= 1 and iso.row <= #M.IDS then
			local entries = columns[M.IDS[iso.row]]
			entries[#entries + 1] = { col = iso.col, code = code }
		end
	end
	local rows = {}
	for row, entries in pairs(columns) do
		table.sort(entries, function(a, b) return a.col < b.col end)
		local codes = {}
		for index, entry in ipairs(entries) do codes[index] = entry.code end
		rows[row] = codes
	end
	return rows
end

--- Whether row `row` is emulated under the stored [layout] switches.
--- @param layout table The [layout] settings, holding the emulate_<row> booleans.
--- @param row string One of M.IDS.
--- @return boolean
function M.emulates(layout, row)
	local known = false
	for _, id in ipairs(M.IDS) do known = known or id == row end
	if not known then error("Unknown layout row: " .. tostring(row)) end
	local value = nil
	if type(layout) == "table" then value = layout["emulate_" .. row] end
	if type(value) ~= "boolean" then
		error("The layout row switch emulate_" .. row .. " is not a boolean.")
	end
	return value
end

--- Which row the number-row ordering reads: the emulated one while an emulation
--- is active and types the number row, else the OS layout's.
--- @param emulation_active boolean
--- @param layout table The [layout] settings.
--- @return string "emulated" or "native"
function M.number_row_source(emulation_active, layout)
	if emulation_active == true and M.emulates(layout, "number_row") then return "emulated" end
	return "native"
end

return M
