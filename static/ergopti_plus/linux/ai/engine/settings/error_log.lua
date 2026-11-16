--- ai/engine/settings/error_log.lua

--- ==============================================================================
--- MODULE: Safe LLM Error Diagnostics (Linux)
--- DESCRIPTION:
--- Keeps free-form backend error text out of logs: a provider may echo a user's
--- request or credentials. Public callback errors remain unchanged.
--- ==============================================================================

local M = {}

-- Only these fixed local outcomes may be printed without a native status.
local SAFE = {
	["cancelled"] = true,
	["empty reply"] = true,
	["HTTP transport unavailable"] = true,
	["request could not be encoded"] = true,
}

--- Describes an inference failure without publishing its untrusted text.
--- @param reason any Backend or local failure.
--- @return string diagnostic A closed local outcome, HTTP status, or generic text.
function M.describe(reason)
	if type(reason) ~= "string" then return "details withheld" end
	local status = reason:match("^HTTP (%d%d%d):") or reason:match("^HTTP (%d%d%d)$")
	if status then return "HTTP " .. status end
	if SAFE[reason] then return reason end
	return "details withheld"
end

return M
