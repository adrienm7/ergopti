--- infra/asset_signature.lua

--- ==============================================================================
--- MODULE: Update Asset Signature Verification (Linux)
--- DESCRIPTION:
--- Verifies the detached signature of the Linux update bundle against the key in
--- _shared/modules/updater/asset_signing.json, with OpenSSL's ECDSA P-256
--- verification. The signed record binds the asset name, its size and its SHA-256
--- (the digest the updater already computes over the exact bytes it installs), so
--- this module never re-reads the archive. tools/build/update-asset-signature.cjs
--- signs; the shared vectors (tests/corpus/updater/asset_signature_vectors.json)
--- are replayed by every verifier.
---
--- FEATURES & RATIONALE:
--- 1. Fail closed. Anything that is not a valid signature of exactly this record
---    (a malformed signature, an unreadable key, a missing OpenSSL binding) is a
---    refusal with a closed reason, never a pass.
--- 2. Enforcement is the policy's, stated, not silent: `evaluate` returns
---    "not_enforced" when the policy is off and the caller logs it on every
---    update; "required" turns every refusal into a stop.
--- 3. Pure parts (record, DER wrapping, policy admission) are separate from the
---    one FFI call, so the suite replays them without OpenSSL.
--- ==============================================================================

local M = {}

local Base64 = require("compat.base64")

--- Closed reasons a verification can be refused for.
M.REFUSALS = {
	no_signature = "no_signature",
	malformed_signature = "malformed_signature",
	bad_key = "bad_key",
	no_native = "no_native",
	mismatch = "mismatch",
}

--- Signature length in bytes, from the policy (P-256: r and s are 32 bytes each).
local COMPONENT_BYTES = 32

--- The canonical record a signature covers.
--- @param header string Policy record_header.
--- @param name string Asset file name.
--- @param size number Size in bytes.
--- @param sha256 string Lowercase hexadecimal digest.
--- @return string|nil record
--- @return string|nil reason
function M.record(header, name, size, sha256)
	if type(header) ~= "string" or header == "" then return nil, "bad_policy" end
	if type(name) ~= "string" or not name:match("^[%w._-]+$") or #name > 128 then return nil, "bad_name" end
	if type(size) ~= "number" or size < 0 or size % 1 ~= 0 then return nil, "bad_size" end
	if type(sha256) ~= "string" or not sha256:match("^%x+$") or #sha256 ~= 64 or sha256:find("%u") then
		return nil, "bad_digest"
	end
	return string.format("%s\n%s\n%d\n%s\n", header, name, size, sha256)
end

--- Wraps one unsigned big-endian integer as a DER INTEGER.
--- @param bytes string
--- @return string
local function der_integer(bytes)
	bytes = bytes:gsub("^%z+", "")
	if bytes == "" then bytes = "\0" end
	if bytes:byte(1) >= 0x80 then bytes = "\0" .. bytes end
	return string.char(0x02, #bytes) .. bytes
end

--- Converts the raw r||s signature to the DER SEQUENCE OpenSSL verifies.
--- @param raw string 64 bytes.
--- @return string|nil der
function M.raw_to_der(raw)
	if type(raw) ~= "string" or #raw ~= 2 * COMPONENT_BYTES then return nil end
	local body = der_integer(raw:sub(1, COMPONENT_BYTES)) .. der_integer(raw:sub(COMPONENT_BYTES + 1))
	return string.char(0x30, #body) .. body
end

--- Admits the shared policy.
--- @param policy any Decoded asset_signing.json.
--- @return table|nil policy
--- @return string|nil reason
function M.admit_policy(policy)
	if type(policy) ~= "table" or policy.schema_version ~= 1 or policy.algorithm ~= "ecdsa-p256-sha256"
		or policy.signature_bytes ~= 2 * COMPONENT_BYTES or type(policy.record_header) ~= "string"
		or type(policy.signature_suffix) ~= "string" or type(policy.public_key_spki_base64) ~= "string"
		or (policy.enforcement ~= "off" and policy.enforcement ~= "required") then
		return nil, "bad_policy"
	end
	if policy.enforcement == "required" and policy.public_key_spki_base64 == "" then
		return nil, "required_without_key"
	end
	return policy
end

--- The OpenSSL binding, or nil with a reason.
--- @return table|nil binding
local function native()
	local Native = require("infra.openssl_library")
	local ffi, library = Native.ffi, Native.library
	if not ffi then return nil end
	if not M._declared then
		M._declared = pcall(ffi.cdef, [[
			typedef struct evp_pkey_st EVP_PKEY;
			typedef struct evp_md_ctx_st EVP_MD_CTX;
			typedef struct evp_md_st EVP_MD;
			EVP_PKEY *d2i_PUBKEY(EVP_PKEY **a, const unsigned char **pp, long length);
			void EVP_PKEY_free(EVP_PKEY *pkey);
			EVP_MD_CTX *EVP_MD_CTX_new(void);
			void EVP_MD_CTX_free(EVP_MD_CTX *ctx);
			const EVP_MD *EVP_sha256(void);
			int EVP_DigestVerifyInit(EVP_MD_CTX *ctx, void **pctx, const EVP_MD *type, void *e, EVP_PKEY *pkey);
			int EVP_DigestVerify(EVP_MD_CTX *ctx, const unsigned char *sig, size_t siglen,
				const unsigned char *tbs, size_t tbslen);
		]])
	end
	if not M._declared or not library then return nil end
	return { ffi = ffi, library = library }
end

--- Verifies a signature of a record.
--- @param spki_base64 string The policy's verification key.
--- @param record string The canonical record.
--- @param signature_base64 string|nil The published signature.
--- @return boolean ok
--- @return string|nil reason A key of M.REFUSALS.
function M.verify(spki_base64, record, signature_base64)
	if type(signature_base64) ~= "string" or signature_base64 == "" then return false, M.REFUSALS.no_signature end
	local raw = signature_base64:match("^[A-Za-z0-9+/]+=*$") and Base64.decode(signature_base64) or nil
	local der = raw and M.raw_to_der(raw)
	if not der or Base64.encode(raw) ~= signature_base64 then return false, M.REFUSALS.malformed_signature end
	local key = type(spki_base64) == "string" and spki_base64 ~= "" and Base64.decode(spki_base64) or nil
	if not key or key == "" then return false, M.REFUSALS.bad_key end
	local binding = native()
	if not binding then return false, M.REFUSALS.no_native end
	local ffi, crypto = binding.ffi, binding.library
	local pointer = ffi.new("const unsigned char *[1]")
	local key_buffer = ffi.new("unsigned char[?]", #key)
	ffi.copy(key_buffer, key, #key)
	pointer[0] = key_buffer
	local pkey = crypto.d2i_PUBKEY(nil, pointer, #key)
	if pkey == nil then return false, M.REFUSALS.bad_key end
	local context = crypto.EVP_MD_CTX_new()
	local verdict
	if context ~= nil and crypto.EVP_DigestVerifyInit(context, nil, crypto.EVP_sha256(), nil, pkey) == 1 then
		local signature = ffi.new("unsigned char[?]", #der)
		ffi.copy(signature, der, #der)
		local message = ffi.new("unsigned char[?]", math.max(1, #record))
		ffi.copy(message, record, #record)
		verdict = crypto.EVP_DigestVerify(context, signature, #der, message, #record)
	end
	if context ~= nil then crypto.EVP_MD_CTX_free(context) end
	crypto.EVP_PKEY_free(pkey)
	if verdict == 1 then return true end
	return false, M.REFUSALS.mismatch
end

--- Decides what an update does with an asset's signature.
--- @param policy table An admitted policy.
--- @param asset table { name, size, sha256 }
--- @param signature_base64 string|nil The published signature, nil when none was published.
--- @return string verdict "verified", "not_enforced" or "refused"
--- @return string|nil reason Closed reason for "not_enforced" and "refused".
function M.evaluate(policy, asset, signature_base64)
	local record, why = M.record(policy.record_header, asset.name, asset.size, asset.sha256)
	if not record then return policy.enforcement == "required" and "refused" or "not_enforced", why end
	if policy.enforcement == "off" then
		if policy.public_key_spki_base64 == "" then return "not_enforced", "policy_off" end
		if signature_base64 == nil then return "not_enforced", M.REFUSALS.no_signature end
		-- A published signature is still checked when a key exists, and a failure
		-- is reported although it does not stop the update while the policy is off.
		local ok, reason = M.verify(policy.public_key_spki_base64, record, signature_base64)
		if ok then return "verified" end
		return "not_enforced", reason
	end
	local ok, reason = M.verify(policy.public_key_spki_base64, record, signature_base64)
	if ok then return "verified" end
	return "refused", reason
end

return M
