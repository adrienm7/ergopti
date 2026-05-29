--- linux/adapters/crypto.lua

--- ==============================================================================
--- MODULE: Crypto Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the Crypto port contract defined in
--- static/ergopti_plus/shared/ports/Crypto.spec.js. Provides a SHA-256 digest
--- function backed by the openssl CLI (available on all mainstream Linux
--- distributions) without coupling domain modules to any specific crypto library.
---
--- FEATURES & RATIONALE:
--- 1. Fail-safe return: sha256() returns "" on any failure, matching the port
---    contract error_behavior so callers never receive nil.
--- 2. openssl delegation: openssl dgst is present on Debian, Fedora, Arch, etc.;
---    no bundled Lua implementation is needed.
--- 3. printf instead of echo: avoids trailing-newline contamination that would
---    silently produce a different hash than the expected value.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

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
		local cmd = string.format(
			"printf '%%s' %q | openssl dgst -sha256 -hex 2>/dev/null", data)
		local fh = io.popen(cmd, "r")
		if not fh then return "" end
		local output = fh:read("*a")
		fh:close()
		if type(output) ~= "string" then return "" end
		-- openssl output: "SHA2-256(stdin)= <hex>" or "(stdin)= <hex>"
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
