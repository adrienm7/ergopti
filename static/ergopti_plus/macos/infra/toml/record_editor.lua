--- infra/toml/record_editor.lua

--- ==============================================================================
--- MODULE: TOML Record Editor
--- DESCRIPTION:
--- Preserves complete TOML assignments while replacing one field in a table.
--- A physical line that resembles a table header is data when an array, inline
--- table, or multiline string is still open, so every caller shares this one
--- continuation-aware scanner instead of growing another line-based patcher.
--- ==============================================================================

local Scanner = require("toml_codec.record_scanner")

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

local function split_lines(source)
	local lines = {}
	for raw in (source .. "\n"):gmatch("([^\n]*)\n") do
		lines[#lines + 1] = raw:gsub("\r$", "")
	end
	while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
	return lines
end

local function starts_target_header(trimmed, target_header)
	if trimmed:sub(1, #target_header) ~= target_header then return false end
	local suffix = trimmed:sub(#target_header + 1)
	return suffix == "" or suffix:match("^%s+#") ~= nil
end

local function escape_pattern(value)
	return (value:gsub("([^%w])", "%%%1"))
end

--- Finds complete records for one field inside an exact TOML table.
--- @param lines string[] Physical source lines.
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
	local field_pattern = "^" .. escape_pattern(field) .. "%s*="

	for index, raw in ipairs(lines) do
		if depth > 0 or multiline_quote ~= nil then
			depth, multiline_quote = M.advance_continuation(raw, depth, multiline_quote)
			if open_field_range then open_field_range.last = index end
		else
			local trimmed = raw:match("^%s*(.-)%s*$") or ""
			if trimmed:sub(1, 1) == "[" then
				if starts_target_header(trimmed, target_header) and scan.header_line == nil then
					scan.header_line = index
					in_target = true
				else
					in_target = false
				end
			else
				if in_target and trimmed:match(field_pattern) then
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

local function section_has_value(lines, header_line)
	local depth = 0
	local multiline_quote = nil
	for index = header_line + 1, #lines do
		local raw = lines[index] or ""
		if depth > 0 or multiline_quote ~= nil then
			return true
		end
		local trimmed = raw:match("^%s*(.-)%s*$") or ""
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

	local lines = split_lines(source)
	local scan, scan_err = scan_table(lines, target_header, field)
	if not scan then return nil, scan_err end
	local ranges = scan.field_ranges
	local new_line = encoded_value and (field .. " = " .. encoded_value) or nil

	if #ranges > 0 then
		for index = #ranges, 2, -1 do remove_range(lines, ranges[index]) end
		local first = ranges[1]
		if new_line then
			for index = first.last, first.first + 1, -1 do table.remove(lines, index) end
			lines[first.first] = new_line
		else
			remove_range(lines, first)
		end
	elseif new_line and scan.header_line then
		table.insert(lines, scan.header_line + 1, new_line)
	elseif new_line then
		if #lines > 0 then lines[#lines + 1] = "" end
		lines[#lines + 1] = target_header
		lines[#lines + 1] = new_line
	end

	if not new_line and scan.header_line
		and options and options.remove_empty_section == true
		and not section_has_value(lines, scan.header_line) then
		table.remove(lines, scan.header_line)
	end

	return table.concat(lines, "\n") .. "\n"
end

return M
