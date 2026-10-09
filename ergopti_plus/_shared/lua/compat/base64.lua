--- _shared/lua/compat/base64.lua

--- ==============================================================================
--- MODULE: Base64 Compatibility Codec
--- DESCRIPTION:
--- Encodes arbitrary bytes as RFC 4648 Base64 without a native extension.
--- Linux uses this for WebKit response envelopes and CSP nonces under both
--- LuaJIT 5.1 and Lua 5.4.
--- ==============================================================================

local M = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

--- Encodes a byte string using the padded RFC 4648 alphabet.
--- @param value string
--- @return string|nil
function M.encode(value)
	if type(value) ~= "string" then return nil end
	local encoded = {}
	for offset = 1, #value, 3 do
		local first = value:byte(offset)
		local second = value:byte(offset + 1)
		local third = value:byte(offset + 2)
		local combined = first * 65536 + (second or 0) * 256 + (third or 0)
		local i1 = math.floor(combined / 262144) % 64
		local i2 = math.floor(combined / 4096) % 64
		local i3 = math.floor(combined / 64) % 64
		local i4 = combined % 64
		encoded[#encoded + 1] = ALPHABET:sub(i1 + 1, i1 + 1)
		encoded[#encoded + 1] = ALPHABET:sub(i2 + 1, i2 + 1)
		encoded[#encoded + 1] = second and ALPHABET:sub(i3 + 1, i3 + 1) or "="
		encoded[#encoded + 1] = third and ALPHABET:sub(i4 + 1, i4 + 1) or "="
	end
	return table.concat(encoded)
end

--- Decodes canonical padded RFC 4648 bytes, refusing malformed or ambiguous input.
--- @param value string Encoded bytes.
--- @return string|nil decoded
function M.decode(value)
	if type(value) ~= "string" or #value % 4 ~= 0 then return nil end
	local output = {}
	for offset = 1, #value, 4 do
		local combined, padding = 0, 0
		for index = 0, 3 do
			local character = value:sub(offset + index, offset + index)
			local digit = ALPHABET:find(character, 1, true)
			if character == "=" then
				if offset + 3 ~= #value or index < 2 then return nil end
				padding = padding + 1
			elseif not digit or padding > 0 then
				return nil
			end
			combined = combined * 64 + (digit and digit - 1 or 0)
		end
		output[#output + 1] = string.char(math.floor(combined / 65536) % 256)
		if padding < 2 then output[#output + 1] = string.char(math.floor(combined / 256) % 256) end
		if padding == 0 then output[#output + 1] = string.char(combined % 256) end
	end
	local decoded = table.concat(output)
	if M.encode(decoded) ~= value then return nil end
	return decoded
end

return M
