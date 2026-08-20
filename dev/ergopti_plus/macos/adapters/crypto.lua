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
--- 2. OpenSSL delegation: macOS ships with openssl in /usr/bin so we shell out
---    rather than bundling a pure-Lua implementation.
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
	local ok, result = pcall(function()
		if type(data) ~= "string" then return "" end
		-- POSIX single-quoting: replace every ' in data with '\'' so the shell
		-- never interprets $, backticks, backslash-newline or other expansions.
		-- %q (Lua double-quoting) is NOT shell-safe and would mangle newlines and
		-- dollar signs, producing wrong digests or allowing shell injection.
		local q = "'" .. data:gsub("'", "'\\''") .. "'"
		local cmd = "printf '%s' " .. q .. " | openssl dgst -sha256 -hex 2>/dev/null"
		local output = hs.execute(cmd)
		if type(output) ~= "string" then return "" end
		-- openssl output format: "SHA2-256(stdin)= <hex>" or "(stdin)= <hex>"
		-- Anchoring on "=" prevents spurious matches on words like "here" whose
		-- last character happens to be a valid hex digit (e.g. "e").
		local digest = output:match("%=%s*([0-9a-f]+)%s*$")
		if not digest then return "" end
		return (digest:gsub("%s+", ""))
	end)
	if not ok then
		Logger.error(LOG, "sha256(): unexpected error — %s", tostring(result))
		return ""
	end
	return type(result) == "string" and result or ""
end

return M
