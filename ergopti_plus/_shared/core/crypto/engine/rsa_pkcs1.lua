--- _shared/core/crypto/engine/rsa_pkcs1.lua

--- ==============================================================================
--- MODULE: RSA PKCS#1 v1.5 Signer
--- DESCRIPTION:
--- Signs bytes with RSASSA-PKCS1-v1_5 and SHA-256 (JWT RS256, RFC 7518 3.3)
--- under an unencrypted PEM private key: PKCS#8 (BEGIN PRIVATE KEY, the
--- private_key of a Google service-account key file) or PKCS#1 (BEGIN RSA
--- PRIVATE KEY). The token exchange signs its service-account assertion with
--- it (ai/engine/api/token_exchange.lua) on macOS and Linux.
---
--- FEATURES & RATIONALE:
--- 1. Pure Lua under Lua 5.4 and LuaJIT: Hammerspoon has no FFI to a native
---    signer, and handing the private key to an openssl process would put it
---    on a command line, a pipe or a temporary file. Limbs of 24 bits keep
---    every product below 2^53, exact on both interpreters.
--- 2. Montgomery multiplication, the Chinese remainder theorem and a 4-bit
---    window keep a 2048-bit signature to a fraction of a second.
--- 3. Every signature is verified with the public exponent before it is
---    returned: a key whose CRT values disagree fails here, never at the
---    token service.
--- 4. No key material reaches an error: reasons name the defect only.
--- ==============================================================================

local M = {}

local Base64 = require("core.lifecycle.engine.compat.base64")
local Sha256 = require("core.crypto.engine.sha256")

local BASE = 16777216
local LIMB_BITS = 24

-- Modulus sizes taken, in bits: below is unsafe, above is no key Google issues
M.MIN_MODULUS_BITS = 2048
M.MAX_MODULUS_BITS = 4096

-- Limb products per slice of a paused signature: 32 products of a 2048-bit
-- key's 1024-bit primes, about 3 ms under Lua 5.4
M.SLICE_LIMB_PRODUCTS = 32 * 43 * 43

-- DER of the SHA-256 DigestInfo prefix (RFC 8017 9.2, note 1)
local SHA256_DIGEST_INFO = "\48\49\48\13\6\9\96\134\72\1\101\3\4\2\1\5\0\4\32"
-- DER of the rsaEncryption object identifier, 1.2.840.113549.1.1.1
local RSA_ENCRYPTION_OID = "\42\134\72\134\247\13\1\1\1"




-- ====================================
-- ====================================
-- ======= 1/ Big Integers ============
-- ====================================
-- ====================================

-- A big integer is an array of limbs, least significant first, with n = the
-- limb count; zero has n = 0. Every limb lies in [0, BASE).

--- Drops the leading zero limbs.
--- @param a table
--- @return table a
local function trim(a)
	local n = a.n
	while n > 0 and a[n] == 0 do a[n] = nil; n = n - 1 end
	a.n = n
	return a
end

--- A big integer from big-endian bytes.
--- @param bytes string
--- @return table
local function from_bytes(bytes)
	local a, n = {}, 0
	local position = #bytes
	while position >= 1 do
		local limb, scale = 0, 1
		for _ = 1, 3 do
			if position < 1 then break end
			limb = limb + bytes:byte(position) * scale
			scale, position = scale * 256, position - 1
		end
		n = n + 1
		a[n] = limb
	end
	a.n = n
	return trim(a)
end

--- The big-endian bytes of a big integer, left-padded to a length.
--- @param a table
--- @param length integer
--- @return string|nil bytes Nil when the value does not fit.
local function to_bytes(a, length)
	local out = {}
	for i = 1, a.n do
		local limb = a[i]
		for _ = 1, 3 do
			out[#out + 1] = limb % 256
			limb = math.floor(limb / 256)
		end
	end
	while #out > 0 and out[#out] == 0 do out[#out] = nil end
	if #out > length then return nil end
	local chars = {}
	for i = length, 1, -1 do chars[#chars + 1] = string.char(out[i] or 0) end
	return table.concat(chars)
end

--- Compares two big integers.
--- @return integer sign -1, 0 or 1.
local function compare(a, b)
	if a.n ~= b.n then return a.n < b.n and -1 or 1 end
	for i = a.n, 1, -1 do
		if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end
	end
	return 0
end

--- a - b, for a >= b.
local function sub(a, b)
	local out, borrow = { n = a.n }, 0
	for i = 1, a.n do
		local value = a[i] - (b[i] or 0) - borrow
		if value < 0 then value, borrow = value + BASE, 1 else borrow = 0 end
		out[i] = value
	end
	return trim(out)
end

--- a + b.
local function add(a, b)
	local n = math.max(a.n, b.n)
	local out, carry = { n = n + 1 }, 0
	for i = 1, n do
		local value = (a[i] or 0) + (b[i] or 0) + carry
		if value >= BASE then value, carry = value - BASE, 1 else carry = 0 end
		out[i] = value
	end
	out[n + 1] = carry
	return trim(out)
end

--- a * b, schoolbook.
local function mul(a, b)
	local out = { n = a.n + b.n }
	for i = 1, out.n do out[i] = 0 end
	for i = 1, a.n do
		local carry, ai = 0, a[i]
		for j = 1, b.n do
			local value = out[i + j - 1] + ai * b[j] + carry
			carry = math.floor(value / BASE)
			out[i + j - 1] = value - carry * BASE
		end
		local k = i + b.n
		while carry > 0 do
			local value = out[k] + carry
			carry = math.floor(value / BASE)
			out[k] = value - carry * BASE
			k = k + 1
		end
	end
	return trim(out)
end

--- The bit length of a big integer.
local function bit_length(a)
	if a.n == 0 then return 0 end
	local top, bits = a[a.n], 0
	while top > 0 do top, bits = math.floor(top / 2), bits + 1 end
	return (a.n - 1) * LIMB_BITS + bits
end

--- Whether bit i (0 = least significant) is set.
local function bit_at(a, i)
	local limb = a[math.floor(i / LIMB_BITS) + 1] or 0
	return math.floor(limb / 2 ^ (i % LIMB_BITS)) % 2
end




-- ====================================
-- ====================================
-- ======= 2/ Montgomery Arithmetic ===
-- ====================================
-- ====================================

--- The Montgomery context of an odd modulus.
--- @param m table The modulus.
--- @param tick function|nil tick(k) after each k doublings, about one product's work.
--- @return table ctx { m, k, inv, r2 }
local function montgomery(m, tick)
	local k = m.n
	-- inv = -m^-1 mod BASE, by Newton iteration on the lowest limb
	local m0, x = m[1], 1
	for _ = 1, 5 do
		local t = (m0 * x) % BASE
		x = (x * ((2 - t) % BASE)) % BASE
	end
	local inv = (BASE - x) % BASE
	-- r2 = R^2 mod m, R = BASE^k, by doubling 1 until it reaches R^2
	local r2 = { 1, n = 1 }
	for step = 1, 2 * k * LIMB_BITS do
		r2 = add(r2, r2)
		if compare(r2, m) >= 0 then r2 = sub(r2, m) end
		if tick and step % k == 0 then tick(k) end
	end
	return { m = m, k = k, inv = inv, r2 = r2 }
end

-- The Montgomery product, the hot loop of a signature, is written once and
-- compiled per interpreter: Lua 5.4 splits a limb product with integer
-- shifts and masks, LuaJIT (no integer operators) with an exact float floor.
-- HI(x) is x's carry above the low limb, LO(x) its low limb.
local MONT_MUL_SOURCE = [[
local trim, compare, sub = ...
return function(ctx, a, b)
	local m, k, inv = ctx.m, ctx.k, ctx.inv
	local t = {}
	for i = 1, k + 2 do t[i] = 0 end
	for i = 1, k do
		local bi = b[i] or 0
		local carry, value = 0, 0
		if bi ~= 0 then
			for j = 1, k do
				value = t[j] + (a[j] or 0) * bi + carry
				carry = HI(value)
				t[j] = LO(value)
			end
			value = t[k + 1] + carry
			carry = HI(value)
			t[k + 1] = LO(value)
			t[k + 2] = t[k + 2] + carry
		end
		local q = LO(t[1] * inv)
		value = t[1] + q * m[1]
		carry = HI(value)
		for j = 2, k do
			value = t[j] + q * m[j] + carry
			carry = HI(value)
			t[j - 1] = LO(value)
		end
		value = t[k + 1] + carry
		carry = HI(value)
		t[k] = LO(value)
		t[k + 1] = t[k + 2] + carry
		t[k + 2] = 0
	end
	t[k + 2] = nil
	t.n = k + 1
	trim(t)
	if compare(t, m) >= 0 then t = sub(t, m) end
	return t
end
]]

--- a * b * R^-1 mod m (CIOS), for a, b < m; a may also be any value below R.
--- @param ctx table montgomery() output.
--- @return table
local mont_mul
do
	local native = _VERSION ~= "Lua 5.1"
	local source = MONT_MUL_SOURCE:gsub("HI(%b())", function(arg)
		return native and ("(" .. arg .. " >> 24)") or ("math.floor(" .. arg .. " / 16777216)")
	end):gsub("LO(%b())", function(arg)
		return native and ("(" .. arg .. " & 16777215)") or ("(" .. arg .. " % 16777216)")
	end)
	mont_mul = assert(load(source, "rsa_pkcs1_mont_mul", "t"))(trim, compare, sub)
end

--- x mod m, for any x below m * R.
local function reduce(ctx, x)
	-- REDC(x) = x R^-1; a second product by R^2 brings back x mod m
	local low = mont_mul(ctx, x, { 1, n = 1 })
	return mont_mul(ctx, low, ctx.r2)
end

--- x mod m for any x: REDC reads only k limbs, so x is folded k limbs at a
--- time from the top, x = (...(c_top * R + c) * R ...) + c_0.
local function mod(ctx, x)
	local k = ctx.k
	if x.n <= k and compare(x, ctx.m) < 0 then return x end
	local result = { n = 0 }
	local top = math.ceil(x.n / k) - 1
	for chunk = top, 0, -1 do
		local part = { n = k }
		for i = 1, k do part[i] = x[chunk * k + i] or 0 end
		trim(part)
		-- result * R mod m = mont_mul(result, R^2)
		if result.n > 0 then result = mont_mul(ctx, result, ctx.r2) end
		result = add(result, reduce(ctx, part))
		if compare(result, ctx.m) >= 0 then result = sub(result, ctx.m) end
	end
	return result
end

--- base^exponent mod m, for base < m, with a fixed 4-bit window.
--- @param tick function|nil tick(k) after each product of k limbs (slicing).
local function mod_pow(ctx, base, exponent, tick)
	local k = ctx.k
	local function product(a, b)
		local out = mont_mul(ctx, a, b)
		if tick then tick(k) end
		return out
	end
	local one_mont = mont_mul(ctx, mod(ctx, { 1, n = 1 }), ctx.r2)
	local table_m = { [0] = one_mont, product(base, ctx.r2) }
	for i = 2, 15 do table_m[i] = product(table_m[i - 1], table_m[1]) end
	local windows = math.ceil(bit_length(exponent) / 4)
	local acc = one_mont
	for w = windows - 1, 0, -1 do
		for _ = 1, 4 do acc = product(acc, acc) end
		local digit = 0
		for b = 3, 0, -1 do digit = digit * 2 + bit_at(exponent, w * 4 + b) end
		if digit ~= 0 then acc = product(acc, table_m[digit]) end
	end
	return mont_mul(ctx, acc, { 1, n = 1 })
end




-- ====================================
-- ====================================
-- ======= 3/ Key Reading =============
-- ====================================
-- ====================================

--- Reads one DER element.
--- @param der string
--- @param position integer Index of the tag byte.
--- @return integer|nil tag, string|nil content, integer|nil next Index after the element.
local function der_element(der, position)
	local tag, first = der:byte(position, position + 1)
	if not tag or not first then return nil end
	local length, start = first, position + 2
	if first >= 128 then
		local count = first - 128
		if count < 1 or count > 3 then return nil end
		length = 0
		for i = 0, count - 1 do
			local byte = der:byte(start + i)
			if not byte then return nil end
			length = length * 256 + byte
		end
		start = start + count
	end
	if start + length - 1 > #der then return nil end
	return tag, der:sub(start, start + length - 1), start + length
end

--- The elements of a DER SEQUENCE's content.
--- @param content string
--- @return table|nil elements Array of { tag, content }.
local function der_children(content)
	local out, position = {}, 1
	while position <= #content do
		local tag, value, next_position = der_element(content, position)
		if not tag then return nil end
		out[#out + 1] = { tag = tag, content = value }
		position = next_position
	end
	return out
end

--- Reads a PKCS#1 RSAPrivateKey.
--- @param der string
--- @return table|nil key, string|nil reason
local function read_rsa_private_key(der)
	local tag, content, after = der_element(der, 1)
	if tag ~= 0x30 or after ~= #der + 1 then return nil, "the private key is no DER sequence" end
	local items = der_children(content)
	if not items or #items ~= 9 then return nil, "the private key is no two-prime RSA key" end
	for _, item in ipairs(items) do
		if item.tag ~= 0x02 then return nil, "the private key holds a field that is no integer" end
	end
	if items[1].content ~= "\0" then return nil, "the private key has an unknown version" end
	local names = { "n", "e", "d", "p", "q", "dp", "dq", "qinv" }
	local key = {}
	for index, name in ipairs(names) do
		local raw = items[index + 1].content
		if raw:byte(1) and raw:byte(1) >= 128 then return nil, "the private key holds a negative integer" end
		key[name] = from_bytes(raw)
	end
	local bits = bit_length(key.n)
	if bits < M.MIN_MODULUS_BITS or bits > M.MAX_MODULUS_BITS then
		return nil, "the private key modulus is not between 2048 and 4096 bits"
	end
	if key.p.n == 0 or key.q.n == 0 or key.p[1] % 2 == 0 or key.q[1] % 2 == 0 or key.n[1] % 2 == 0 then
		return nil, "the private key primes are invalid"
	end
	if compare(mul(key.p, key.q), key.n) ~= 0 then return nil, "the private key primes do not multiply to its modulus" end
	key.bits = bits
	return key, nil
end

--- Reads an unencrypted PEM RSA private key.
--- @param pem string PKCS#8 (BEGIN PRIVATE KEY) or PKCS#1 (BEGIN RSA PRIVATE KEY).
--- @return table|nil key An opaque key for sign(), never logged.
--- @return string|nil reason Why the key is refused (never the key).
function M.read_private_key(pem)
	if type(pem) ~= "string" or pem == "" then return nil, "the private key is empty" end
	local label, body = pem:match("^%s*%-%-%-%-%-BEGIN ([%u ]+)%-%-%-%-%-(.-)%-%-%-%-%-END ([%u ]+)%-%-%-%-%-%s*$")
	if not label then return nil, "the private key is no PEM block" end
	if label ~= "PRIVATE KEY" and label ~= "RSA PRIVATE KEY" then
		return nil, "the private key is a " .. label .. ", not an unencrypted RSA key"
	end
	if pem:match("END ([%u ]+)%-%-%-%-%-%s*$") ~= label then return nil, "the private key PEM labels differ" end
	local der = Base64.decode((body:gsub("%s", "")))
	if not der then return nil, "the private key is no Base64" end
	if label == "RSA PRIVATE KEY" then return read_rsa_private_key(der) end
	-- PrivateKeyInfo: version, AlgorithmIdentifier, OCTET STRING privateKey
	local tag, content, after = der_element(der, 1)
	if tag ~= 0x30 or after ~= #der + 1 then return nil, "the private key is no DER sequence" end
	local items = der_children(content)
	if not items or #items < 3 or items[1].tag ~= 0x02 or items[1].content ~= "\0" then
		return nil, "the private key is no PKCS#8 key"
	end
	local algorithm = items[2].tag == 0x30 and der_children(items[2].content) or nil
	if not algorithm or not algorithm[1] or algorithm[1].tag ~= 0x06 or algorithm[1].content ~= RSA_ENCRYPTION_OID then
		return nil, "the private key is no RSA key"
	end
	if items[3].tag ~= 0x04 then return nil, "the private key is no PKCS#8 key" end
	return read_rsa_private_key(items[3].content)
end




-- ====================================
-- ====================================
-- ======= 4/ Signature ===============
-- ====================================
-- ====================================

--- The RSASSA-PKCS1-v1_5 SHA-256 signature of a message.
--- @param key table read_private_key() output.
--- @param message string
--- @param pause function|nil Called once per slice of M.SLICE_LIMB_PRODUCTS limb
---   products (coroutine.yield, to spread a signature over timer ticks).
--- @return string|nil signature Raw bytes, as long as the modulus.
--- @return string|nil reason Why it could not be made.
function M.sign_sha256(key, message, pause)
	if type(key) ~= "table" or type(key.n) ~= "table" then error("rsa_pkcs1.sign_sha256 requires a read key", 2) end
	if type(message) ~= "string" then error("rsa_pkcs1.sign_sha256 requires a message", 2) end
	if pause ~= nil and type(pause) ~= "function" then error("rsa_pkcs1.sign_sha256 pause must be a function", 2) end
	local tick
	if pause then
		local work = 0
		tick = function(k)
			work = work + k * k
			if work >= M.SLICE_LIMB_PRODUCTS then work = 0; pause() end
		end
	end
	local length = math.ceil(key.bits / 8)
	local info = SHA256_DIGEST_INFO .. Sha256.digest(message)
	local encoded = "\0\1" .. string.rep("\255", length - #info - 3) .. "\0" .. info
	local m = from_bytes(encoded)
	key.ctx_p = key.ctx_p or montgomery(key.p, tick)
	key.ctx_q = key.ctx_q or montgomery(key.q, tick)
	key.ctx_n = key.ctx_n or montgomery(key.n, tick)
	-- s = m^d mod n through the primes: s1 = m^dp mod p, s2 = m^dq mod q
	local s1 = mod_pow(key.ctx_p, mod(key.ctx_p, m), key.dp, tick)
	local s2 = mod_pow(key.ctx_q, mod(key.ctx_q, m), key.dq, tick)
	local s2p = mod(key.ctx_p, s2)
	local diff = compare(s1, s2p) >= 0 and sub(s1, s2p) or sub(add(s1, key.p), s2p)
	local h = mod(key.ctx_p, mul(diff, mod(key.ctx_p, key.qinv)))
	local s = add(s2, mul(h, key.q))
	-- The signature must open back to the encoded message
	if compare(mod_pow(key.ctx_n, s, key.e, tick), m) ~= 0 then
		return nil, "the private key values disagree: the signature does not verify"
	end
	return to_bytes(s, length), nil
end

return M
