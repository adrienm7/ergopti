--- core/network/engine/openssl_digest.lua
--- ==============================================================================
--- MODULE: Native OpenSSL SHA-256 Binding
--- DESCRIPTION:
--- Hashes explicit byte lengths without passing caller data through exec argv.
--- The module retains the OpenSSL library handle for the lifetime of its calls.
--- ==============================================================================

local M = { available = false }
local DIGEST_BYTES = 32 -- SHA-256's native ABI output size.
local Native = require("core.network.engine.openssl_library")
local ffi = Native.ffi
local library, null_pointer
local streaming = false
if ffi then
	local declared = pcall(ffi.cdef, [[
		unsigned char *SHA256(const unsigned char *data, size_t length, unsigned char *digest);
	]])
	if declared then
		if pcall(function() return Native.library.SHA256 end) then
			library, null_pointer = Native.library, ffi.cast("void *", 0)
			M.available = true
		end
	end
	-- The streaming calls keep their state in a caller-owned SHA256_CTX, the
	-- layout OpenSSL 1.1 and 3 both export (deprecated in 3, still exported).
	streaming = M.available and pcall(ffi.cdef, [[
		typedef struct ergopti_sha256_ctx {
			unsigned int h[8]; unsigned int Nl, Nh; unsigned int data[16]; unsigned int num, md_len;
		} ergopti_sha256_ctx;
		int SHA256_Init(ergopti_sha256_ctx *c);
		int SHA256_Update(ergopti_sha256_ctx *c, const void *data, size_t len);
		int SHA256_Final(unsigned char *md, ergopti_sha256_ctx *c);
	]]) and pcall(function() return library.SHA256_Init, library.SHA256_Update, library.SHA256_Final end)
end

--- Whether streaming digests (M.stream) are available.
M.streaming = streaming

local function hex_of(buffer)
	local hex = {}
	for index = 0, DIGEST_BYTES - 1 do hex[#hex + 1] = string.format("%02x", tonumber(buffer[index])) end
	return table.concat(hex)
end

--- Starts a streaming SHA-256 whose state can be copied, so a reader that has
--- hashed a prefix can extend it without hashing the prefix again.
--- @return table|nil stream { update(bytes):boolean, digest():string|nil, copy():table }
--- @return string|nil reason
function M.stream()
	if not streaming then return nil, "OpenSSL streaming SHA256 binding unavailable" end
	local function wrap(ctx)
		local self = {}
		function self.update(bytes)
			assert(type(bytes) == "string", "a digest update takes bytes")
			if #bytes == 0 then return true end
			return library.SHA256_Update(ctx, bytes, #bytes) == 1
		end
		function self.copy()
			local clone = ffi.new("ergopti_sha256_ctx")
			ffi.copy(clone, ctx, ffi.sizeof("ergopti_sha256_ctx"))
			return wrap(clone)
		end
		--- The digest of every byte so far; the stream itself stays extendable.
		function self.digest()
			local clone = ffi.new("ergopti_sha256_ctx")
			ffi.copy(clone, ctx, ffi.sizeof("ergopti_sha256_ctx"))
			local buffer = ffi.new("unsigned char[?]", DIGEST_BYTES)
			if library.SHA256_Final(buffer, clone) ~= 1 then return nil end
			return hex_of(buffer)
		end
		return self
	end
	local ctx = ffi.new("ergopti_sha256_ctx")
	if library.SHA256_Init(ctx) ~= 1 then return nil, "OpenSSL refused to start a SHA256 stream" end
	return wrap(ctx)
end

--- Computes an independent native digest over every byte of the input.
--- @param data string
--- @return string|nil Lowercase hexadecimal digest.
--- @return string|nil Native failure reason.
function M.sha256(data)
	if type(data) ~= "string" then return nil, "expected a byte string" end
	if not library then return nil, "OpenSSL 3 SHA256 binding unavailable" end
	local ok, result = pcall(function()
		local input = ffi.new("unsigned char[?]", math.max(1, #data))
		ffi.copy(input, data, #data)
		local buffer = ffi.new("unsigned char[?]", DIGEST_BYTES)
		local pointer = library.SHA256(input, #data, buffer)
		if pointer == nil or pointer == null_pointer then
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
