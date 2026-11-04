--- tests/support/posix_printf_model.lua

--- ==============================================================================
--- MODULE: POSIX printf %b Pipeline Model
--- DESCRIPTION:
--- Decodes the standard input that /bin/sh delivers for a command shaped
--- `set -o pipefail; printf '%b' <word> | <consumer>`, the macOS exact-stdin
--- transport. Quotes are parsed as the shell parses them and the operand is
--- expanded as bash's printf %b expands it, so a transport that drops, adds or
--- reinterprets a byte is observable in tests.
--- ==============================================================================

local M = {}

local SIMPLE_ESCAPES = {
	a = "\a", b = "\b", e = "\27", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v",
	["\\"] = "\\",
}

--- Parses one shell word starting at `index`, stopping at unquoted whitespace.
--- @param text string
--- @param index integer
--- @return string|nil value, integer next_index
local function shell_word(text, index)
	local value = {}
	while index <= #text do
		local char = text:sub(index, index)
		if char == "'" then
			local closing = text:find("'", index + 1, true)
			if not closing then return nil, index end
			value[#value + 1] = text:sub(index + 1, closing - 1)
			index = closing + 1
		elseif char == "\\" then
			value[#value + 1] = text:sub(index + 1, index + 1)
			index = index + 2
		elseif char:match("%s") then
			break
		else
			value[#value + 1] = char
			index = index + 1
		end
	end
	return table.concat(value), index
end

--- Expands one printf %b operand.
--- @param operand string
--- @return string
function M.expand_b(operand)
	local out, index = {}, 1
	while index <= #operand do
		local char = operand:sub(index, index)
		local escape = operand:sub(index + 1, index + 1)
		if char ~= "\\" or escape == "" then
			out[#out + 1] = char
			index = index + 1
		elseif escape == "0" then
			local digits = operand:sub(index + 2):match("^[0-7]?[0-7]?[0-7]?")
			out[#out + 1] = string.char(tonumber(digits ~= "" and digits or "0", 8) % 256)
			index = index + 2 + #digits
		elseif escape == "c" then
			break
		elseif SIMPLE_ESCAPES[escape] then
			out[#out + 1] = SIMPLE_ESCAPES[escape]
			index = index + 2
		else
			out[#out + 1] = char .. escape
			index = index + 2
		end
	end
	return table.concat(out)
end

--- Returns the delivered stdin and the consumer of a printf %b pipeline.
--- @param command string C-string command as /bin/sh receives it.
--- @return string|nil stdin, string|nil consumer
function M.parse_pipeline(command)
	local prefix = "set -o pipefail; printf '%b' "
	if command:sub(1, #prefix) ~= prefix then return nil, nil end
	local operand, next_index = shell_word(command, #prefix + 1)
	if not operand then return nil, nil end
	local consumer = command:sub(next_index):match("^ | (.+)$")
	if not consumer then return nil, nil end
	return M.expand_b(operand), consumer
end

return M
