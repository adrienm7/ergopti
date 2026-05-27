--- adapters/crypto.lua

--- ==============================================================================
--- MODULE: Crypto Adapter (Hammerspoon)
--- DESCRIPTION:
--- Hammerspoon implementation of the Crypto port contract defined in
--- static/ergopti_plus/shared/ports/Crypto.spec.js. Provides a SHA-256 digest
--- function without coupling domain modules to any specific crypto library.
---
--- FEATURES & RATIONALE:
--- 1. Fail-safe return: sha256() returns "" on any failure rather than
---    propagating an exception, matching the port contract error_behavior.
--- 2. OpenSSL delegation: macOS ships with openssl in /usr/bin so we shell out
---    rather than bundling a pure-Lua implementation.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

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
	local ok, result = pcall(function()
		if type(data) ~= "string" then return "" end
		-- Shell out to openssl — available on every macOS installation
		local cmd = string.format("printf '%%s' %q | openssl dgst -sha256 -hex 2>/dev/null", data)
		local output = hs.execute(cmd)
		if type(output) ~= "string" then return "" end
		-- openssl output format: "SHA2-256(stdin)= <hex>" or "(stdin)= <hex>"
		local hex = output:match("[0-9a-f]+%s*$") or ""
		return hex:gsub("%s+", "")
	end)
	if not ok then
		Logger.error(LOG, "sha256(): unexpected error — %s", tostring(result))
		return ""
	end
	return type(result) == "string" and result or ""
end

return M
