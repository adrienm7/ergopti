--- _shared/lua/toml_codec/basic_string.lua

--- ==============================================================================
--- MODULE: TOML Basic String Codec (shared)
--- DESCRIPTION:
--- Encodes and decodes the body of TOML basic strings. The implementation is
--- byte-oriented for escaping so UTF-8 payload bytes remain untouched, and uses
--- one decoding pass so escaped control values cannot collide with sentinels.
--- ==============================================================================

local utf8_lib = (type(utf8) == "table" and utf8.char) and utf8 or require("compat.utf8")

local M = {}

local SHORT_ESCAPES = {
	[0x08] = "\\b",
	[0x09] = "\\t",
	[0x0A] = "\\n",
	[0x0C] = "\\f",
	[0x0D] = "\\r",
}

local SHORT_VALUES = {
	b = string.char(0x08),
	t = "\t",
	n = "\n",
	f = string.char(0x0C),
	r = "\r",
}

local function is_unicode_scalar(codepoint)
	return type(codepoint) == "number"
		and codepoint >= 0
		and codepoint <= 0x10FFFF
		and not (codepoint >= 0xD800 and codepoint <= 0xDFFF)
end

local function is_forbidden_raw_control(byte, allow_newlines)
	if byte == 0x09 then return false end
	if allow_newlines and byte == 0x0A then return false end
	return byte <= 0x1F or byte == 0x7F
end

--- Escapes one TOML basic-string body without adding surrounding quotes.
--- @param value string Raw Lua string bytes.
--- @return string|nil escaped Escaped TOML body, or nil for invalid input.
function M.escape_body(value)
	if type(value) ~= "string" then return nil end
	local out = {}
	for index = 1, #value do
		local byte = value:byte(index)
		if byte == 0x22 then
			out[#out + 1] = '\\"'
		elseif byte == 0x5C then
			out[#out + 1] = "\\\\"
		elseif SHORT_ESCAPES[byte] then
			out[#out + 1] = SHORT_ESCAPES[byte]
		elseif byte <= 0x1F or byte == 0x7F then
			out[#out + 1] = string.format("\\u%04X", byte)
		else
			out[#out + 1] = string.char(byte)
		end
	end
	return table.concat(out)
end

--- Validates and decodes one TOML basic-string body.
--- @param value string Escaped body without surrounding quotes.
--- @param allow_newlines boolean|nil Whether raw LF is valid for a multiline body.
--- @return string|nil decoded Decoded bytes, or nil for malformed TOML.
function M.unescape_body(value, allow_newlines)
	if type(value) ~= "string" then return nil end
	local out = {}
	local index = 1
	while index <= #value do
		local byte = value:byte(index)
		if byte == 0x5C then
			local escape = value:sub(index + 1, index + 1)
			if escape == "" then return nil end
			if escape == '"' then
				out[#out + 1] = '"'
				index = index + 2
			elseif escape == "\\" then
				out[#out + 1] = "\\"
				index = index + 2
			elseif SHORT_VALUES[escape] then
				out[#out + 1] = SHORT_VALUES[escape]
				index = index + 2
			elseif escape == "u" or escape == "U" then
				local width = escape == "u" and 4 or 8
				local hex = value:sub(index + 2, index + 1 + width)
				if #hex ~= width or not hex:match("^" .. string.rep("%x", width) .. "$") then
					return nil
				end
				local codepoint = tonumber(hex, 16)
				if not is_unicode_scalar(codepoint) then return nil end
				local ok_char, decoded = pcall(utf8_lib.char, codepoint)
				if not ok_char or type(decoded) ~= "string" then return nil end
				out[#out + 1] = decoded
				index = index + width + 2
			else
				return nil
			end
		elseif is_forbidden_raw_control(byte, allow_newlines == true) then
			return nil
		else
			out[#out + 1] = string.char(byte)
			index = index + 1
		end
	end
	return table.concat(out)
end

return M
