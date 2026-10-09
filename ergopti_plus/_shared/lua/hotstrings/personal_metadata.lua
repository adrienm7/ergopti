--- _shared/lua/hotstrings/personal_metadata.lua

--- ==============================================================================
--- MODULE: Personal File Metadata Preparation (Shared)
--- DESCRIPTION:
--- Prepares lossless source edits within the established hotstring TOML dialect.
--- Native owners supply admission, leases, runtime journals and publication.
--- ==============================================================================
local M = {}
local Writer = require("toml_codec.writer")
local Reader = require("toml_codec.reader")
local KeyPath = require("toml_codec.key_path")
local Scanner = require("toml_codec.record_scanner")

local function finite(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

--- Checks the four existing controls without granting source authority.
--- @param field string Existing metadata field name.
--- @param value any Candidate value or nil to clear the owned field.
--- @return boolean valid
function M.valid(field, value)
	if field ~= "delay" and field ~= "color" and field ~= "show_tooltip" and field ~= "priority" then return false end
	if value == nil then return true end
	if field == "delay" then return finite(value) and value >= 0 end
	if field == "priority" then return finite(value) and value % 1 == 0 and value >= 0 and value <= 100 end
	if field == "show_tooltip" then return type(value) == "boolean" end
	local hex = type(value) == "string" and value:gsub("^#", "")
	return type(hex) == "string" and #hex >= 3 and #hex <= 8 and hex:match("^[0-9a-fA-F]+$") ~= nil
end

local function same_folded(a, b)
	if #a ~= #b then return false end
	for index, segment in ipairs(a) do if segment:lower() ~= b[index]:lower() then return false end end
	return true
end

--- Refuses case aliases without changing the generic writer's historical dialect.
--- @param content string Exact captured source bytes.
--- @param rows table Narrow source-owned metadata operations.
--- @return boolean available
local function exact_row_owners(content, rows)
	local scanned = Scanner.scan_records(content, { quoted_headers = true })
	if not scanned then return false end
	for _, row in ipairs(rows) do
		local target = assert(KeyPath.parse(row.section, true))
		for _, header in ipairs(scanned.headers) do
			if header.segments and same_folded(header.segments, target)
				and KeyPath.render(header.segments) ~= KeyPath.render(target) then return false end
		end
		for _, record in ipairs(scanned.records) do
			local section, key = record.section, record.key
			if record.quoted then section, key = record.quoted.section, record.quoted.key end
			local owner = section and KeyPath.parse(section, true)
			if owner and (record.quoted or record.addressable and #record.key_segments == 1)
				and same_folded(owner, target) and key:lower() == row.key:lower()
				and (KeyPath.render(owner) ~= KeyPath.render(target) or key ~= row.key) then return false end
		end
	end
	return true
end

--- Checks bounded native-owned rows against exact semantic source identities.
--- This preflight grants no source or preferences publication capability.
--- @param content string Exact captured source bytes.
--- @param rows table Native-owned set/delete rows.
--- @return boolean available
function M.exact_rows_available(content, rows)
	return type(content) == "string" and type(rows) == "table" and exact_row_owners(content, rows)
end

--- Projects metadata control availability without changing source discovery.
--- @param content string Exact captured source bytes.
--- @param section string|nil Exact declared literal section.
--- @param legacy table|nil Recognized source-owned legacy fields.
--- @return table unavailable Boolean flags for the four existing controls.
function M.readonly_fields(content, section, legacy)
	local parsed, committed = Reader.parse_text(content)
	legacy = type(legacy) == "table" and legacy or {}
	local unavailable = {}
	for _, field in ipairs({ "delay", "color", "show_tooltip", "priority" }) do
		local rows = { { section = KeyPath.render(section and { "_meta", "sections", section } or { "_meta" }), key = field } }
		if section and legacy[field] ~= nil then rows[#rows + 1] = { section = "_meta", key = field } end
		if section and field == "delay" and committed == true and (parsed.meta.section_delays or {})[section] ~= nil then
			rows[#rows + 1] = { section = "_meta.section_delays", key = section }
		end
		local meta = committed == true and (section and (parsed.meta.sections or {})[section] or parsed.meta) or nil
		local value = type(meta) == "table" and meta[field] or nil
		local stored = section and (legacy.sections or {})[section] or legacy
		if type(stored) == "table" and stored[field] ~= nil then value = stored[field] end
		unavailable[field] = committed ~= true or not M.exact_rows_available(content, rows)
			or not M.valid(field, value) or (section and legacy[field] ~= nil and not M.valid(field, legacy[field])) or false
	end
	return unavailable
end

--- A section edit removes a masking legacy file leaf only after transferring
--- that inherited value into the file metadata; siblings keep their settings.
--- Unknown override fields and unrelated recognized leaves remain untouched.
--- @param content string Exact source bytes.
--- @param section string|nil Literal declared section, or nil for file metadata.
--- @param field string Existing metadata field.
--- @param value any Validated candidate or nil to clear.
--- @param legacy table|nil Recognized uniquely owned legacy override values.
--- @return table|nil plan { content, remove_file, remove_section }
function M.prepare(content, section, field, value, legacy)
	if type(content) ~= "string" or not M.valid(field, value)
		or (section ~= nil and (type(section) ~= "string" or section == "")) then return nil end
	local parsed, committed = Reader.parse_text(content)
	if committed ~= true or type(parsed) ~= "table" then return nil end
	if section and type((parsed.sections or {})[section]) ~= "table" then return nil end
	legacy = type(legacy) == "table" and legacy or {}
	local rows, remove_file = {}, false
	if section and value ~= nil and legacy[field] ~= nil then
		if not M.valid(field, legacy[field]) then return nil end
		rows[#rows + 1] = { section = "_meta", key = field, value = legacy[field] }
		remove_file = true
	elseif not section then
		remove_file = legacy[field] ~= nil
	end
	rows[#rows + 1] = { section = KeyPath.render(section and { "_meta", "sections", section } or { "_meta" }),
		key = field, value = value, delete = value == nil and true or nil }
	-- The old delay spelling is a recognized alias. Remove only this section's
	-- leaf so a cleared or edited canonical delay cannot be masked on reload.
	if section and field == "delay" and type((parsed.meta or {}).section_delays) == "table"
		and parsed.meta.section_delays[section] ~= nil then
		rows[#rows + 1] = { section = "_meta.section_delays", key = section, delete = true, literal_key = true }
	end
	if not exact_row_owners(content, rows) then return nil, "ambiguous-metadata-owner" end
	local ok, detail, candidate = Writer.prepare_batch("personal-metadata.toml", rows,
		{ read_with_status = function() return content, "ok" end }, { status = "ok", content = content })
	if ok ~= true then return nil, detail end
	local checked, valid = Reader.parse_text(candidate)
	if valid ~= true or type(checked) ~= "table" then return nil end
	local leaf = section and (legacy.sections or {})[section]
	return { content = candidate, remove_file = remove_file,
		remove_section = type(leaf) == "table" and leaf[field] ~= nil }
end

return M
