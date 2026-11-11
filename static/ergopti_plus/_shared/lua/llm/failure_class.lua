--- _shared/lua/llm/failure_class.lua

--- ==============================================================================
--- MODULE: LLM Failure Classification — Shared Lua Implementation
--- DESCRIPTION:
--- Tells whether a failed prediction call failed because the credential was
--- refused. The prediction retry policy (extra tokens, higher temperature) only
--- helps a call that was too short or unlucky; the same refused key is refused
--- again, so it is never retried (maintainer decision of 6 November 2026).
---
--- FEATURES & RATIONALE:
--- 1. One verdict for every driver: macOS and Linux call this module, Windows
---    mirrors it in windows/modules/llm/api_common.ahk. Both replay
---    _shared/tests/corpus/llm/auth_failure_vectors.json.
--- 2. A failure is a string ("HTTP 401: ..." or a plain message) or a table
---    { status?, reason?, message? }. HTTP 401 and 403 are authentication or
---    authorization failures whatever the provider says.
--- 3. Providers that report a bad key with another status (Gemini answers 400
---    "API key not valid") are recognised by their message, matched
---    case-insensitively against a closed list of phrases.
--- 4. A token exchange answering HTTP 400 (OAuth invalid_grant, an unknown
---    IAM key) is a refused credential: the same key is refused again, so it
---    fails at once with the service's message (maintainer decision AID-2 of
---    11 November 2026). The phrase is api_token_exchange.read's refusal.
--- ==============================================================================

local M = {}

-- HTTP statuses that always mean the credential was refused.
local AUTH_STATUSES = { [401] = true, [403] = true }

-- Local reasons the drivers raise when no usable credential exists.
local AUTH_REASONS = { no_credential = true, missing_credential = true, invalid_credential = true }

-- Lowercase phrases providers use for an invalid or missing key.
local AUTH_PHRASES = {
	"invalid api key", "invalid_api_key", "incorrect api key", "api key not valid",
	"api key is invalid", "api key is missing", "invalid x-api-key", "invalid authentication",
	"authentication_error", "authentication failed", "unauthorized", "missing api key",
	"no api key", "api key is missing or invalid", "invalid token", "permission_denied",
	"the token exchange answered http 400",
}

local function has_auth_phrase(text)
	if type(text) ~= "string" or text == "" then return false end
	local lowered = text:lower()
	for _, phrase in ipairs(AUTH_PHRASES) do
		if lowered:find(phrase, 1, true) then return true end
	end
	return false
end

--- Whether a failure is an authentication or authorization refusal.
--- @param failure any A failure string, or a table { status?, reason?, message? }.
--- @return boolean refused True when retrying the same credential cannot help.
function M.is_authentication_failure(failure)
	if type(failure) == "string" then
		local status = tonumber(failure:match("^HTTP (%d%d%d)"))
		if status and AUTH_STATUSES[status] then return true end
		return has_auth_phrase(failure)
	end
	if type(failure) ~= "table" then return false end
	local status = tonumber(failure.status)
	if status and AUTH_STATUSES[status] then return true end
	if type(failure.reason) == "string" then
		if AUTH_REASONS[failure.reason] then return true end
		local reason_status = tonumber(failure.reason:match("^http_(%d%d%d)$"))
		if reason_status and AUTH_STATUSES[reason_status] then return true end
	end
	return has_auth_phrase(failure.message)
end

return M
