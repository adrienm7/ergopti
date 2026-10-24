--- _shared/lua/toml_codec/record_scanner.lua

--- ==============================================================================
--- MODULE: TOML Record Scanner (shared)
--- DESCRIPTION:
--- Tracks the lexical state that makes one TOML assignment span physical lines.
--- It deliberately does not interpret values; it only prevents table-looking
--- data inside arrays, inline tables, and multiline strings from being treated
--- as a new record by lightweight readers and byte-preserving editors.
--- ==============================================================================

local M = {}
local Bom = require("toml_codec.bom")
local KeyPath = require("toml_codec.key_path")
local SourceMemo = require("toml_codec.source_memo")

-- One preferences save scans the same config.toml text 10 times (record list,
-- preferences, inline parents, batch writer, personal metadata). A scan is a
-- pure function of the text and the header grammar, so the newest texts are
-- kept and every caller receives a private copy.
local SCAN_MEMO_ENTRIES = 4
local _scan_memo = SourceMemo.new(SCAN_MEMO_ENTRIES)
-- Defined below scan_records, which is the only public entry point.
local scan_source
local TextUtils = require("text_utils")

--- Finds the end of an already recognized triple-quote closing run.
--- Value decoding owns validation of the maximum run length.
--- @param raw string Source fragment.
--- @param index number Index of the first quote in the closing run.
--- @return number next_index First byte after the complete quote run.
function M.closing_quote_end(raw, index)
	local char = raw:sub(index, index)
	local finish = index + 3
	while raw:sub(finish, finish) == char do finish = finish + 1 end
	return finish
end

--- Advances one physical line of TOML continuation state.
--- @param raw string One physical source line.
--- @param depth number Current array/inline-table nesting depth.
--- @param multiline_quote string|nil Active triple-quote delimiter.
--- @return number depth Updated nesting depth.
--- @return string|nil multiline_quote Updated triple-quote delimiter.
function M.advance(raw, depth, multiline_quote)
	local index = 1
	local length = #raw
	local comment_offset
	while index <= length do
		-- Characters no state reacts to are skipped in one jump.
		local stop
		if multiline_quote then
			stop = raw:find(multiline_quote == '"""' and '[\\"]' or "'", index)
		else
			stop = raw:find("[#\"'%[%]{}]", index)
		end
		if stop == nil then break end
		index = stop
		if multiline_quote then
			if multiline_quote == '"""' and raw:sub(index, index) == "\\" then
				index = index + 2
			elseif raw:sub(index, index + 2) == multiline_quote then
				index = M.closing_quote_end(raw, index)
				multiline_quote = nil
			else
				index = index + 1
			end
		else
			local triple = raw:sub(index, index + 2)
			local char = raw:sub(index, index)
			if char == "#" then
				comment_offset = index
				break
			elseif triple == '"""' or triple == "'''" then
				multiline_quote = triple
				index = index + 3
			elseif char == '"' then
				index = index + 1
				while index <= length do
					local stop = raw:find('[\\"]', index)
					if stop == nil then index = length + 1; break end
					if raw:byte(stop) == 0x5C then
						index = stop + 2
					else
						index = stop + 1
						break
					end
				end
			elseif char == "'" then
				local closing = raw:find("'", index + 1, true)
				index = closing and (closing + 1) or (length + 1)
			elseif char == "[" or char == "{" then
				depth = depth + 1
				index = index + 1
			elseif char == "]" or char == "}" then
				depth = math.max(0, depth - 1)
				index = index + 1
			else
				index = index + 1
			end
		end
	end
	return depth, multiline_quote, comment_offset
end

--- Splits source bytes into physical lines, each keeping its exact terminator.
--- @param source string Complete file content.
--- @return table lines Array of `{ text, eol }`.
local function split_lines(source)
	local lines = {}
	local cursor = 1
	while cursor <= #source do
		local cr_at = source:find("\r", cursor, true)
		local lf_at = source:find("\n", cursor, true)
		local eol_at = (cr_at and lf_at) and math.min(cr_at, lf_at) or cr_at or lf_at
		if not eol_at then
			lines[#lines + 1] = { text = source:sub(cursor), eol = "" }
			break
		end
		local eol = source:sub(eol_at, eol_at)
		local eol_last = eol_at
		if eol == "\r" and source:sub(eol_at + 1, eol_at + 1) == "\n" then
			eol = "\r\n"
			eol_last = eol_at + 1
		end
		lines[#lines + 1] = { text = source:sub(cursor, eol_at - 1), eol = eol }
		cursor = eol_last + 1
	end
	return lines
end

local trim = TextUtils.trim

--- Splits an assignment at the first equals sign outside quoted key segments.
--- The strict codec still owns key and value validation; this shared lexical
--- boundary only gives the decoder and physical editor the same source span.
--- @param line string One physical assignment line.
--- @return string|nil key Trimmed key spelling.
--- @return string|nil value Trimmed value spelling.
--- @return string|nil original_rhs Untrimmed bytes after the separator.
function M.split_assignment(line)
	local in_dbl, in_sgl = false, false
	local i, length = 1, #line
	while i <= length do
		-- Only a quote, a backslash or an equals sign changes the state.
		i = line:find("[\\\"'=]", i)
		if i == nil then break end
		local c = line:sub(i, i)
		if c == "\\" and in_dbl then
			i = i + 1 -- the escaped character is skipped whole
		elseif c == '"' and not in_sgl then
			in_dbl = not in_dbl
		elseif c == "'" and not in_dbl then
			in_sgl = not in_sgl
		elseif not in_dbl and not in_sgl and c == "=" then
			return trim(line:sub(1, i - 1)), trim(line:sub(i + 1)), line:sub(i + 1)
		end
		i = i + 1
	end
	return nil, nil
end

--- Splits a dotted bare-key path. Returns nil for anything that is not a plain
--- run of bare segments (quotes, empty segments), which is never offered.
--- @param text string Key or header body.
--- @return table|nil segments
local function bare_segments(text)
	if text:find("[\"']") then return nil end
	local segments = {}
	for part in (text .. "."):gmatch("([^%.]*)%.") do
		local segment = trim(part)
		if not segment:match("^[%w_%-]+$") then return nil end
		segments[#segments + 1] = segment
	end
	return #segments > 0 and segments or nil
end

--- Parses a table header line.
--- @param trimmed string The trimmed physical line, starting with "[".
--- @return table header `{ array, segments|nil }`; segments is nil when unaddressable.
local function parse_header(trimmed)
	local array = trimmed:sub(1, 2) == "[["
	local body, rest
	if array then
		body, rest = trimmed:match("^%[%[([^%]]*)%]%](.*)$")
	else
		body, rest = trimmed:match("^%[([^%]]*)%](.*)$")
	end
	local header = { array = array, segments = nil }
	if body and (trim(rest) == "" or trim(rest):sub(1, 1) == "#") then
		header.segments = bare_segments(body)
	end
	return header
end

--- Whether prefix is a leading run of segments.
--- @param segments table
--- @param prefix table
--- @return boolean
local function starts_with(segments, prefix)
	if #prefix > #segments then return false end
	for index = 1, #prefix do
		if segments[index] ~= prefix[index] then return false end
	end
	return true
end

--- Finds every assignment record of a TOML document with its exact line span.
---
--- Continuation lines of arrays, inline tables and multiline strings belong to
--- the record that opened them (the shared record scanner decides), so a line
--- that merely looks like a header inside a value is data.
--- @param source string Complete file content.
--- @param options table|nil Explicit quoted_headers capability for the batch writer.
--- @return table|nil scan `{ lines, headers, records }`, nil when a value never closes.
--- @return string|nil error_detail
function M.scan_records(source, options)
	local quoted = (options and options.quoted_headers) and true or false
	if type(source) ~= "string" then return scan_source(source, quoted) end
	return _scan_memo.fetch(source, quoted, function() return scan_source(source, quoted) end)
end

--- Scans one source without the memo; see scan_records.
--- @param source string Complete file content.
--- @param quoted boolean Whether headers use the quoted key-path grammar.
--- @return table|nil scan
--- @return string|nil error_detail
scan_source = function(source, quoted)
	local options = quoted and { quoted_headers = true } or nil
	local lines = split_lines(source)
	local headers, records = {}, {}
	local current = nil
	local open = nil
	local depth, multiline_quote = 0, nil
	for index, line in ipairs(lines) do
		local raw = index == 1 and Bom.strip_prefix(line.text) or line.text
		if depth > 0 or multiline_quote ~= nil then
			depth, multiline_quote = M.advance(raw, depth, multiline_quote)
			open.last = index
			open.value_parts[#open.value_parts + 1] = trim(raw)
		else
			local trimmed = trim(raw)
			if trimmed == "" or trimmed:sub(1, 1) == "#" then
				open = nil
			elseif trimmed:sub(1, 1) == "[" then
				current = options and options.quoted_headers and KeyPath.header(trimmed) or parse_header(trimmed)
				current.index = index
				current.section = current.segments and (options and options.quoted_headers
					and KeyPath.render(current.segments) or table.concat(current.segments, ".")) or nil
				headers[#headers + 1] = current
				open = nil
			else
				local key_text, value_text = M.split_assignment(trimmed)
				open = {
					first = index,
					last = index,
					header = current,
					key_text = key_text,
					key_segments = key_text and bare_segments(key_text) or nil,
					value_parts = { value_text or "" },
				}
				records[#records + 1] = open
				depth, multiline_quote = M.advance(raw, 0, nil)
			end
		end
	end
	if depth > 0 or multiline_quote ~= nil then
		return nil, "unterminated TOML assignment"
	end

	-- Anything under an array of tables attaches to its latest element; the
	-- text alone cannot name that element, so none of it is addressable.
	local array_prefixes = {}
	for _, header in ipairs(headers) do
		if header.array and header.segments then array_prefixes[#array_prefixes + 1] = header.segments end
	end
	for _, record in ipairs(records) do
		local header = record.header
		local table_owned = header ~= nil and header.segments ~= nil and not header.array
		if table_owned then
			for _, prefix in ipairs(array_prefixes) do
				if starts_with(header.segments, prefix) then
					table_owned = false
					break
				end
			end
		end
		local addressable = table_owned and record.key_segments ~= nil
		record.addressable = addressable
		-- One quoted key, such as an extension pack's `"ext:pack:stem"` or a hand
		-- edit's `"enabled"`, is exposed apart from `addressable` so only the batch
		-- writer, which renders it back in its canonical spelling, can edit its
		-- line; cleanup and path readers stay unchanged. The batch writer alone
		-- can address a quoted literal dot through semantic key path segments.
		if table_owned and not addressable and record.key_text then
			local key = KeyPath.parse(record.key_text)
			if key and #key == 1 and key[1] ~= ""
				and (not key[1]:find(".", 1, true) or (options and options.quoted_headers)) then
				record.quoted = { section = header.section, key = key[1] }
			end
		end
		if addressable then
			record.section = header.section
			record.key = table.concat(record.key_segments, ".")
			record.path = {}
			for _, segment in ipairs(header.segments) do record.path[#record.path + 1] = segment end
			for _, segment in ipairs(record.key_segments) do record.path[#record.path + 1] = segment end
			record.value = table.concat(record.value_parts, " ")
		end
	end
	return { lines = lines, headers = headers, records = records }
end

return M
