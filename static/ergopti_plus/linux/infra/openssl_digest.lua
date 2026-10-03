--- infra/openssl_digest.lua
--- ==============================================================================
--- MODULE: Native OpenSSL SHA-256 Binding
--- DESCRIPTION:
--- Hashes explicit byte lengths without passing caller data through exec argv.
--- The module retains the OpenSSL library handle for the lifetime of its calls.
--- ==============================================================================

local M = { available = false }
local DIGEST_BYTES = 32 -- SHA-256's native ABI output size.
local ffi_ok, ffi = pcall(require, "ffi")
local library
if ffi_ok then
	local declared = pcall(ffi.cdef, [[
		unsigned char *SHA256(const unsigned char *data, size_t length, unsigned char *digest);
	]])
	if declared then
		local loaded, candidate = pcall(ffi.load, "libcrypto.so.3")
		if loaded and pcall(function() return candidate.SHA256 end) then
			library = candidate
			M.available = true
		end
	end
end

--- Computes an independent native digest over every byte of the input.
--- @param data string
--- @return string|nil Lowercase hexadecimal digest.
--- @return string|nil Native failure reason.
function M.sha256(data)
	if type(data) ~= "string" then return nil, "expected a byte string" end
	if not library then return nil, "OpenSSL 3 SHA256 binding unavailable" end
	local ok, result = pcall(function()
		local buffer = ffi.new("unsigned char[?]", DIGEST_BYTES)
		if library.SHA256(data, #data, buffer) == nil then
			error("OpenSSL SHA256 refused the input")
		end
		local hex = {}
		for index = 0, DIGEST_BYTES - 1 do
			hex[#hex + 1] = string.format("%02x", tonumber(buffer[index]))
		end
		return table.concat(hex)
	end)
	if not ok then return nil, tostring(result) end
	return result, nil
end

return M
