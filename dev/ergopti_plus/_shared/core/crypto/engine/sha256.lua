--- _shared/core/crypto/engine/sha256.lua

--- ==============================================================================
--- MODULE: SHA-256
--- DESCRIPTION:
--- FIPS 180-4 SHA-256 of a byte string, for the RS256 signature of a token
--- exchange assertion (core/crypto/engine/rsa_pkcs1.lua). Shared by the macOS driver
--- (Lua 5.4, which has no FFI to a native digest) and the Linux driver
--- (LuaJIT), so both sign the same bytes.
---
--- FEATURES & RATIONALE:
--- 1. Lua 5.4 integer operators are compiled with load(), LuaJIT uses its bit
---    library: one source parses under both interpreters.
--- 2. Short inputs only (an assertion is a few hundred bytes); not a hot path.
--- 3. Replayed against the NIST vectors in
---    _shared/tests/corpus/crypto/rs256_vectors.json.
--- ==============================================================================

local M = {}

local MOD32 = 4294967296

--- The 32-bit operations of the running interpreter.
--- @return table ops { band, bor, bxor, bnot, rshift, rrotate }, every result in [0, 2^32).
local function bit_ops()
	if _VERSION ~= "Lua 5.1" then
		local compiled = assert(load([[
			return {
				band = function(a, b) return a & b end,
				bor = function(a, b) return a | b end,
				bxor = function(a, b) return a ~ b end,
				bnot = function(a) return ~a & 0xffffffff end,
				rshift = function(a, n) return a >> n end,
				rrotate = function(a, n) return ((a >> n) | (a << (32 - n))) & 0xffffffff end,
			}
		]], "sha256_bit_ops", "t"))
		return compiled()
	end
	local bit = require("bit")
	local function u(value) return value % MOD32 end
	return {
		band = function(a, b) return u(bit.band(a, b)) end,
		bor = function(a, b) return u(bit.bor(a, b)) end,
		bxor = function(a, b) return u(bit.bxor(a, b)) end,
		bnot = function(a) return u(bit.bnot(a)) end,
		rshift = function(a, n) return u(bit.rshift(a, n)) end,
		rrotate = function(a, n) return u(bit.ror(a, n)) end,
	}
end

local Ops = bit_ops()
local band, bxor, bnot, rshift, rrotate = Ops.band, Ops.bxor, Ops.bnot, Ops.rshift, Ops.rrotate

local K = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local H0 = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }




-- ====================================
-- ====================================
-- ======= 1/ Digest ==================
-- ====================================
-- ====================================

--- Mixes one 64-byte block into the state.
--- @param h table The eight state words.
--- @param block string 64 bytes.
--- @param offset integer Index of the block's first byte.
local function compress(h, block, offset)
	local w = {}
	for i = 0, 15 do
		local b1, b2, b3, b4 = block:byte(offset + i * 4, offset + i * 4 + 3)
		w[i] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
	end
	for i = 16, 63 do
		local x, y = w[i - 15], w[i - 2]
		local s0 = bxor(bxor(rrotate(x, 7), rrotate(x, 18)), rshift(x, 3))
		local s1 = bxor(bxor(rrotate(y, 17), rrotate(y, 19)), rshift(y, 10))
		w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % MOD32
	end
	local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
	for i = 0, 63 do
		local s1 = bxor(bxor(rrotate(e, 6), rrotate(e, 11)), rrotate(e, 25))
		local ch = bxor(band(e, f), band(bnot(e), g))
		local t1 = (hh + s1 + ch + K[i + 1] + w[i]) % MOD32
		local s0 = bxor(bxor(rrotate(a, 2), rrotate(a, 13)), rrotate(a, 22))
		local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
		local t2 = (s0 + maj) % MOD32
		hh, g, f, e, d, c, b, a = g, f, e, (d + t1) % MOD32, c, b, a, (t1 + t2) % MOD32
	end
	h[1], h[2], h[3], h[4] = (h[1] + a) % MOD32, (h[2] + b) % MOD32, (h[3] + c) % MOD32, (h[4] + d) % MOD32
	h[5], h[6], h[7], h[8] = (h[5] + e) % MOD32, (h[6] + f) % MOD32, (h[7] + g) % MOD32, (h[8] + hh) % MOD32
end

--- The SHA-256 digest of a byte string.
--- @param message string
--- @return string digest 32 raw bytes.
function M.digest(message)
	if type(message) ~= "string" then error("sha256.digest requires a string", 2) end
	local length = #message
	-- Padding: 0x80, zeros, then the bit length on eight big-endian bytes
	local bits = length * 8
	local tail = { "\128", string.rep("\0", (55 - length) % 64) }
	for shift = 7, 0, -1 do
		tail[#tail + 1] = string.char(math.floor(bits / 256 ^ shift) % 256)
	end
	local padded = message .. table.concat(tail)
	local h = {}
	for i = 1, 8 do h[i] = H0[i] end
	for offset = 1, #padded, 64 do compress(h, padded, offset) end
	local out = {}
	for i = 1, 8 do
		local word = h[i]
		out[i] = string.char(math.floor(word / 16777216) % 256, math.floor(word / 65536) % 256,
			math.floor(word / 256) % 256, word % 256)
	end
	return table.concat(out)
end

--- The lowercase hexadecimal SHA-256 digest of a byte string.
--- @param message string
--- @return string hex 64 characters.
function M.hex(message)
	return (M.digest(message):gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

return M
