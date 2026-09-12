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
	while index <= length do
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
				break
			elseif triple == '"""' or triple == "'''" then
				multiline_quote = triple
				index = index + 3
			elseif char == '"' then
				index = index + 1
				while index <= length do
					local quoted_char = raw:sub(index, index)
					if quoted_char == "\\" then
						index = index + 2
					elseif quoted_char == '"' then
						index = index + 1
						break
					else
						index = index + 1
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
	return depth, multiline_quote
end

return M
