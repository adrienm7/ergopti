--- adapters/crypto.lua

--- ==============================================================================
--- MODULE: Crypto Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the Crypto port contract defined in
--- static/ergopti_plus/_shared/core/ports/Crypto.spec.js. Provides a SHA-256 digest
--- function backed by OpenSSL's native SHA256 byte API. Explicit byte lengths
--- preserve NUL and large strings without the Linux exec argument-size limit.
--- The existing CLI path remains available when the native binding is absent;
--- that capability degradation is logged once. Native refusal is never retried
--- through another primitive. The Crypto port still returns "" on failure.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local OpenSSL = require("infra.openssl_command")
local Shell = require("adapters.shell_runner")
local Base64 = require("compat.base64")
local NativeDigest = require("infra.openssl_digest")

local LOG = "adapters.crypto"
local fallback_reported = false




-- =========================================
-- =========================================
-- ======= 1/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Computes the SHA-256 digest of a UTF-8 string.
--- @param data string The input string to hash.
--- @return string Lowercase hex digest (64 chars), or "" on failure.
function M.sha256(data)
	local ok, result = pcall(function()
		if type(data) ~= "string" then return "" end
		if NativeDigest.available then
			local digest, reason = NativeDigest.sha256(data)
			if not digest then
				Logger.error(LOG, "sha256(): native digest failed: %s", tostring(reason))
				return ""
			end
			return digest
		end
		if not fallback_reported then
			fallback_reported = true
			Logger.warn(LOG, "Native OpenSSL binding unavailable; CLI hashing is subject to exec argument limits")
		end
		local output, native_error
		if data:find("\0", 1, true) then
			-- exec receives a C string: quoting cannot preserve embedded NUL.
			-- The shared codec makes the shell input textual; OpenSSL restores
			-- the original bytes before hashing through the existing primitive.
			output, native_error = OpenSSL.exec(
				"openssl base64 -d -A | openssl dgst -sha256 -hex 2>/dev/null", Base64.encode(data), { pipefail = true })
		else
			output, native_error = OpenSSL.exec(string.format(
				"printf '%%s' %s | openssl dgst -sha256 -hex 2>/dev/null", Shell.quote(data)), nil, { pipefail = true })
		end
		if type(output) ~= "string" then
			Logger.error(LOG, "sha256(): CLI digest failed: %s", native_error or "missing output")
			return ""
		end
		-- openssl output: "SHA2-256(stdin)= <hex>" or "(stdin)= <hex>"
		local hex = output:match("[0-9a-f]+%s*$") or ""
		return (hex:gsub("%s+", ""))
	end)
	if not ok then
		Logger.error(LOG, "sha256(): unexpected error — %s", tostring(result))
		return ""
	end
	return type(result) == "string" and result or ""
end

return M
