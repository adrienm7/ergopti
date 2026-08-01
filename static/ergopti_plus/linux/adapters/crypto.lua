--- adapters/crypto.lua

--- ==============================================================================
--- MODULE: Crypto Adapter (Linux)
--- DESCRIPTION:
--- Linux implementation of the Crypto port contract defined in
--- static/ergopti_plus/_shared/core/ports/Crypto.spec.js. Provides a SHA-256 digest
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
--- 4. shell_runner quoting: the input is arbitrary caller data, so it is passed
---    through the adapter's quote() rather than interpolated. The previous
---    string.format("%q") form emitted a DOUBLE-quoted word, where $, ` and
---    $( ) stay live — sha256("$HOME") hashed the expansion instead of the
---    literal, and any input could run a command.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Shell  = require("adapters.shell_runner")

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
		local output = Shell.exec(string.format(
			"printf '%%s' %s | openssl dgst -sha256 -hex 2>/dev/null", Shell.quote(data)))
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
