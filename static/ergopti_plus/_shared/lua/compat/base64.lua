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

return M
