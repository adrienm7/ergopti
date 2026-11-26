--- core/text/engine/toml/record_editor.lua

--- ==============================================================================
--- MODULE: TOML Record Editor
--- DESCRIPTION:
--- Preserves complete TOML assignments while replacing one field in a table.
--- A physical line that resembles a table header is data when an array, inline
--- table, or multiline string is still open, so every caller shares this one
--- continuation-aware scanner instead of growing another line-based patcher.
--- ==============================================================================

local Scanner = require("core.text.engine.toml_codec.record_scanner")
local KeyPath = require("core.text.engine.toml_codec.key_path")
local TextUtils = require("core.text.engine.utils_core")

local M = {}

--- Advances the lexical state needed to identify a complete TOML assignment.
--- This is intentionally smaller than a parser: callers already obtained a
--- committed source snapshot and only need record boundaries for byte-preserving
--- edits. Strings and comments are skipped so brackets inside them are data.
--- @param raw string One physical source line.
--- @param depth number Current array/inline-table nesting depth.
--- @param multiline_quote string|nil Active triple-quote delimiter.
--- @return number depth Updated nesting depth.
--- @return string|nil multiline_quote Updated triple-quote delimiter.
function M.advance_continuation(raw, depth, multiline_quote)
	return Scanner.advance(raw, depth, multiline_quote)
end

local function split_records(source)
	local records = {}
	local cursor = 1
	while cursor <= #source do
		local cr_at = source:find("\r", cursor, true)
		local lf_at = source:find("\n", cursor, true)
		local eol_at
		if cr_at and lf_at then
			eol_at = math.min(cr_at, lf_at)
		else
			eol_at = cr_at or lf_at
		end

		if not eol_at then
			records[#records + 1] = { text = source:sub(cursor), eol = "" }
			break
		end

		local eol = source:sub(eol_at, eol_at)
		local eol_last = eol_at
		if eol == "\r" and source:sub(eol_at + 1, eol_at + 1) == "\n" then
			eol = "\r\n"
			eol_last = eol_at + 1
		end
		records[#records + 1] = {
			text = source:sub(cursor, eol_at - 1),
			eol = eol,
		}
		cursor = eol_last + 1
	end
	return records
end

local function serialize_records(records)
	local chunks = {}
	for _, record in ipairs(records) do
		chunks[#chunks + 1] = record.text
		chunks[#chunks + 1] = record.eol
	end
	return table.concat(chunks)
end

local function local_eol(records, pivot)
	for index = pivot, 1, -1 do
		if records[index].eol ~= "" then return records[index].eol end
	end
	for index = pivot + 1, #records do
		if records[index].eol ~= "" then return records[index].eol end
	end
	return "\n"
end

local function starts_target_header(trimmed, target_header)
	local actual, target = KeyPath.header(trimmed), KeyPath.header(target_header)
	if actual.array or target.array or type(actual.segments) ~= "table"
		or type(target.segments) ~= "table" or #actual.segments ~= #target.segments then return false end
	for index, segment in ipairs(target.segments) do
		if actual.segments[index] ~= segment then return false end
	end
	return true
end

--- Finds complete records for one field inside an exact TOML table.
--- @param lines table[] Physical source records with exact line terminators.
--- @param target_header string Canonical table header, including brackets.
--- @param field string Bare field name.
--- @return table|nil scan Scan result, or nil for an unterminated record.
--- @return string|nil error_detail Failure detail.
local function scan_table(lines, target_header, field)
	local scan = { header_line = nil, field_ranges = {} }
	local in_target = false
	local depth = 0
	local multiline_quote = nil
	local open_field_range = nil

	for index, record in ipairs(lines) do
		local raw = record.text
		if depth > 0 or multiline_quote ~= nil then
			depth, multiline_quote = M.advance_continuation(raw, depth, multiline_quote)
			if open_field_range then open_field_range.last = index end
		else
			local trimmed = TextUtils.trim(raw)
			if trimmed:sub(1, 1) == "[" then
				if starts_target_header(trimmed, target_header) and scan.header_line == nil then
					scan.header_line = index
					in_target = true
				else
					in_target = false
				end
			else
				local key_text = in_target and Scanner.split_assignment(trimmed) or nil
				local key = key_text and KeyPath.parse(key_text) or nil
				if key and #key == 1 and key[1] == field then
					open_field_range = { first = index, last = index }
					scan.field_ranges[#scan.field_ranges + 1] = open_field_range
				else
					open_field_range = nil
				end
				depth, multiline_quote = M.advance_continuation(raw, 0, nil)
			end
		end

		if depth == 0 and multiline_quote == nil then open_field_range = nil end
	end

	if depth > 0 or multiline_quote ~= nil then
		return nil, "unterminated TOML assignment"
	end
	return scan
end

local function remove_range(lines, range)
	for index = range.last, range.first, -1 do table.remove(lines, index) end
end

--- Preserves a trailing comment outside strings when replacing an assignment.
local function trailing_comment(lines, range)
	local depth, quote, comment = 0, nil, nil
	for index = range.first, range.last do
		local raw = lines[index].text
		local offset
		depth, quote, offset = Scanner.advance(raw, depth, quote)
		if index == range.last and offset then
			local before = raw:sub(1, offset - 1)
			comment = (before:match("[ \t]*$") or "") .. raw:sub(offset)
		end
	end
	return comment or ""
end

local function section_has_value(lines, header_line)
	local depth = 0
	local multiline_quote = nil
	for index = header_line + 1, #lines do
		local raw = lines[index].text
		if depth > 0 or multiline_quote ~= nil then
			return true
		end
		local trimmed = TextUtils.trim(raw)
		if trimmed:sub(1, 1) == "[" then return false end
		if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then return true end
		depth, multiline_quote = M.advance_continuation(raw, 0, nil)
	end
	return false
end

--- Replaces, inserts, or removes one complete field record in a TOML table.
--- @param source string Complete committed TOML bytes.
--- @param target_header string Canonical table header, including brackets.
--- @param field string Bare field name.
--- @param encoded_value string|nil TOML value bytes, or nil to remove the field.
--- @param options table|nil Supports remove_empty_section=true.
--- @return string|nil content Patched candidate bytes.
--- @return string|nil error_detail Failure detail.
function M.patch_table_field(source, target_header, field, encoded_value, options)
	if type(source) ~= "string" or type(target_header) ~= "string"
		or type(field) ~= "string" or field == ""
		or (encoded_value ~= nil and type(encoded_value) ~= "string") then
		return nil, "invalid TOML patch arguments"
	end

	local lines = split_records(source)
	local scan, scan_err = scan_table(lines, target_header, field)
	if not scan then return nil, scan_err end
	local ranges = scan.field_ranges
	local new_line = encoded_value and (field .. " = " .. encoded_value) or nil

	if #ranges > 0 then
		for index = #ranges, 2, -1 do remove_range(lines, ranges[index]) end
		local first = ranges[1]
		if new_line then
			local replacement_eol = lines[first.last].eol
			new_line = new_line .. trailing_comment(lines, first)
			for index = first.last, first.first + 1, -1 do table.remove(lines, index) end
			lines[first.first] = { text = new_line, eol = replacement_eol }
		else
			remove_range(lines, first)
		end
	elseif new_line and scan.header_line then
		local header = lines[scan.header_line]
		local eol = local_eol(lines, scan.header_line)
		local inserted_eol = eol
		if header.eol == "" then
			header.eol = eol
			inserted_eol = ""
		end
		table.insert(lines, scan.header_line + 1, {
			text = new_line,
			eol = inserted_eol,
		})
	elseif new_line then
		local eol = local_eol(lines, #lines)
		local keep_final_eol = #lines > 0 and lines[#lines].eol ~= ""
		if #lines > 0 then
			if lines[#lines].eol == "" then lines[#lines].eol = eol end
			if lines[#lines].text ~= "" then
				lines[#lines + 1] = { text = "", eol = eol }
			end
		end
		lines[#lines + 1] = { text = target_header, eol = eol }
		lines[#lines + 1] = {
			text = new_line,
			eol = keep_final_eol and eol or "",
		}
	end

	if not new_line and #ranges > 0 and scan.header_line
		and options and options.remove_empty_section == true
		and not section_has_value(lines, scan.header_line)
		-- A header can carry user-authored context. Retaining a harmless empty
		-- table preserves that text, including quoted keys containing '#'.
		and not lines[scan.header_line].text:find("#", 1, true) then
		table.remove(lines, scan.header_line)
	end

	return serialize_records(lines)
end

return M
