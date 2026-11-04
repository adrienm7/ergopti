--- adapters/crypto.lua

--- ==============================================================================
--- MODULE: Crypto Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the Crypto port contract defined in
--- static/ergopti_plus/_shared/core/ports/Crypto.spec.js. Provides a SHA-256 digest
--- function without coupling domain modules to any specific crypto library.
---
--- FEATURES & RATIONALE:
--- 1. Fail-safe return: sha256() returns "" on any failure rather than
---    propagating an exception, matching the port contract error_behavior.
--- 2. One native digest: sha256() and sha256_bytes() both hash the exact Lua
---    string through hs.hash. The text digest used to interpolate its input
---    into a /bin/sh command for openssl; popen(3) stops at the first NUL, so a
---    NUL-bearing input returned "" here while Windows and Linux hashed it.
--- 3. Private failures: a native refusal is logged by fixed category, because
---    the hashed text (an SSID, a row seed) can appear in the native error.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")

local LOG = "adapters.crypto"




-- =========================================
-- =========================================
-- ======= 1/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Computes the SHA-256 digest of a UTF-8 string.
--- @param data string The input string to hash.
--- @return string Lowercase hex digest (64 chars), or "" on failure.
function M.sha256(data)
	if type(data) ~= "string" then return "" end
	return M.sha256_bytes(data, function(category)
		Logger.error(LOG, "sha256(): native digest refused (%s).", category)
	end)
end

--- Computes the SHA-256 digest of an arbitrary binary string.
--- @param data string The exact byte string to hash.
--- @param on_error function|nil Scoped callback receiving a fixed failure category.
--- @return string Lowercase hex digest (64 chars), or "" on failure.
function M.sha256_bytes(data, on_error)
	local ok, result = pcall(function()
		if type(data) ~= "string" then return "" end
		if type(hs.hash) ~= "table" or type(hs.hash.new) ~= "function" then return "" end
		local context = hs.hash.new("SHA256")
		if not context then return "" end
		local appended = context:append(data)
		if not appended then return "" end
		local finished = appended:finish()
		if not finished then return "" end
		local digest = finished:value()
		if type(digest) ~= "string" then return "" end
		digest = digest:lower()
		if #digest ~= 64 or not digest:match("^[0-9a-f]+$") then return "" end
		return digest
	end)
	if not ok then
		if type(on_error) == "function" then
			-- Private source bytes can appear in a native error. Never pass that
			-- value to the scoped reporter or fall back after reporter refusal.
			pcall(on_error, "native-hash-error")
		else
			Logger.error(LOG, "sha256_bytes(): unexpected error — %s", tostring(result))
		end
		return ""
	end
	return type(result) == "string" and result or ""
end

return M
