--- infra/openssl_cipher.lua
--- ==============================================================================
--- MODULE: Native OpenSSL AES-256-CBC Byte Primitive
--- DESCRIPTION:
--- Preserves OpenSSL enc's PKCS#7 payload without subprocess arguments. Every
--- call owns its EVP context; update output is private until final succeeds.
--- Keys and intermediate bytes never become diagnostics or fallback input.
--- ==============================================================================

local M = { available = false }
local Native = require("infra.openssl_library")
local ffi, library = Native.ffi, Native.library
local BLOCK_BYTES, KEY_BYTES, INT_MAX = 16, 32, 2147483647
local cipher

if ffi then
	local declared = pcall(ffi.cdef, [[
		typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
		typedef struct evp_cipher_st EVP_CIPHER;
		EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);
		void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *ctx);
		const EVP_CIPHER *EVP_aes_256_cbc(void);
		int EVP_CipherInit_ex(EVP_CIPHER_CTX *ctx, const EVP_CIPHER *type,
			void *engine, const unsigned char *key, const unsigned char *iv, int enc);
		int EVP_CipherUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl,
			const unsigned char *in, int inl);
		int EVP_CipherFinal_ex(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl);
		int EVP_EncodeBlock(unsigned char *out, const unsigned char *in, int length);
		int EVP_DecodeBlock(unsigned char *out, const unsigned char *in, int length);
		void OPENSSL_cleanse(void *ptr, size_t len);
	]])
	if declared then
		local admitted, value = pcall(function()
			for _, name in ipairs({ "EVP_CIPHER_CTX_new", "EVP_CIPHER_CTX_free", "EVP_CipherInit_ex",
				"EVP_CipherUpdate", "EVP_CipherFinal_ex", "EVP_EncodeBlock", "EVP_DecodeBlock",
				"OPENSSL_cleanse" }) do assert(library[name]) end
			return library.EVP_aes_256_cbc()
		end)
		if admitted and value ~= nil then cipher, M.available = value, true end
	end
end

--- Converts validated hexadecimal key material directly into native bytes.
--- @param value string
--- @param length integer Byte length.
--- @return any|nil buffer
local function unhex(value, length)
	if type(value) ~= "string" or #value ~= length * 2 or value:find("[^%x]") then return nil end
	local buffer = ffi.new("unsigned char[?]", length)
	for index = 0, length - 1 do buffer[index] = tonumber(value:sub(index * 2 + 1, index * 2 + 2), 16) end
	return buffer
end

--- Runs one checked EVP operation, retaining every resource through cleanup.
--- @param key_hex string AES-256 key.
--- @param iv_hex string One AES block.
--- @param input string Exact input bytes.
--- @param encrypt boolean
--- @return string|nil output
--- @return string|nil reason Generic and independent of private data.
local function crypt(key_hex, iv_hex, input, encrypt)
	if not M.available then return nil, "native AES-256-CBC unavailable" end
	if type(input) ~= "string" or #input > INT_MAX - BLOCK_BYTES then return nil, "invalid AES input length" end
	if not encrypt and (#input == 0 or #input % BLOCK_BYTES ~= 0) then return nil, "invalid AES ciphertext length" end
	local key, iv, output, context
	local capacity = #input + BLOCK_BYTES
	local ok, result = pcall(function()
		key = unhex(key_hex, KEY_BYTES)
		iv = unhex(iv_hex, BLOCK_BYTES)
		assert(key and iv)
		context = library.EVP_CIPHER_CTX_new()
		assert(context ~= nil)
		output = ffi.new("unsigned char[?]", capacity)
		local length = ffi.new("int[1]")
		assert(library.EVP_CipherInit_ex(context, cipher, nil, key, iv, encrypt and 1 or 0) == 1)
		assert(library.EVP_CipherUpdate(context, output, length, input, #input) == 1)
		local written = tonumber(length[0])
		assert(written >= 0 and written <= capacity - BLOCK_BYTES)
		length[0] = 0
		assert(library.EVP_CipherFinal_ex(context, output + written, length) == 1)
		local final = tonumber(length[0])
		assert(final >= 0 and final <= BLOCK_BYTES and written + final <= capacity)
		return ffi.string(output, written + final)
	end)
	local cleaned = true
	local function release(callback, ...)
		local released = pcall(callback, ...)
		cleaned = cleaned and released
	end
	if context ~= nil then release(library.EVP_CIPHER_CTX_free, context) end
	if key ~= nil then release(library.OPENSSL_cleanse, key, KEY_BYTES) end
	if iv ~= nil then release(library.OPENSSL_cleanse, iv, BLOCK_BYTES) end
	if output ~= nil then release(library.OPENSSL_cleanse, output, capacity) end
	if not ok or not cleaned then return nil, "native AES operation refused" end
	return result
end

--- Encrypts exact bytes with AES-256-CBC and OpenSSL's default PKCS#7 padding.
--- @param key_hex string
--- @param iv_hex string
--- @param plaintext string
--- @return string|nil ciphertext
--- @return string|nil reason
function M.encrypt(key_hex, iv_hex, plaintext)
	return crypt(key_hex, iv_hex, plaintext, true)
end

--- Decrypts only after the complete ciphertext and padding are acknowledged.
--- @param key_hex string
--- @param iv_hex string
--- @param ciphertext string
--- @return string|nil plaintext
--- @return string|nil reason
function M.decrypt(key_hex, iv_hex, ciphertext)
	return crypt(key_hex, iv_hex, ciphertext, false)
end

--- Runs canonical RFC 4648 framing without per-byte Lua tables on large rows.
--- @param value string Exact input bytes.
--- @param decode boolean
--- @return string|nil output
--- @return string|nil reason
local function base64(value, decode)
	if not M.available then return nil, "native Base64 unavailable" end
	if type(value) ~= "string" or #value > INT_MAX then return nil, "invalid Base64 input length" end
	if decode and #value % 4 ~= 0 then return nil, "invalid Base64 input" end
	local needed = decode and (#value / 4 * 3) or (4 * math.ceil(#value / 3))
	-- EVP_EncodeBlock writes a trailing NUL in addition to its reported bytes.
	if needed >= INT_MAX then return nil, "invalid Base64 output length" end
	local output, canonical
	local ok, result = pcall(function()
		output = ffi.new("unsigned char[?]", needed + 1)
		if not decode then
			assert(library.EVP_EncodeBlock(output, value, #value) == needed)
			return ffi.string(output, needed)
		end
		assert(library.EVP_DecodeBlock(output, value, #value) == needed)
		local padding = value:sub(-2) == "==" and 2 or (value:sub(-1) == "=" and 1 or 0)
		local length = needed - padding
		assert(length >= 0)
		canonical = ffi.new("unsigned char[?]", #value + 1)
		assert(library.EVP_EncodeBlock(canonical, output, length) == #value)
		-- Exact canonical bytes also refuse whitespace, bad alphabet and unused bits.
		assert(ffi.string(canonical, #value) == value, "noncanonical Base64")
		return ffi.string(output, length)
	end)
	local cleaned = true
	if output ~= nil then cleaned = pcall(library.OPENSSL_cleanse, output, needed + 1) end
	if canonical ~= nil then
		local released = pcall(library.OPENSSL_cleanse, canonical, #value + 1)
		cleaned = cleaned and released
	end
	if not ok or not cleaned then return nil, "native Base64 operation refused" end
	return result
end

--- Encodes bytes using canonical padded RFC 4648 without line wrapping.
--- @param value string
--- @return string|nil encoded
--- @return string|nil reason
function M.encode_base64(value)
	return base64(value, false)
end

--- Decodes only canonical padded RFC 4648, including its unused-bit rules.
--- @param value string
--- @return string|nil decoded
--- @return string|nil reason
function M.decode_base64(value)
	return base64(value, true)
end

return M
