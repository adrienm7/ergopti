--- _shared/lua/updater/list_cache.lua

--- ==============================================================================
--- MODULE: Stored Release List Copy (Shared Lua)
--- DESCRIPTION:
--- Decides whether a release-list copy read back from the Storage port is safe to
--- send as a conditional request again. The update check answers a 304 from the
--- copy it holds, so a copy that outlives a restart saves the full request that
--- the GitHub anonymous quota (60 per hour per IP address) cannot afford.
---
--- FEATURES & RATIONALE:
--- 1. One validation for macOS and Linux (vectors in
---    _shared/tests/corpus/updater/list_cache_vectors.json). A copy is a table of
---    the final URL it answered, the ETag validating it, and the list text. Any
---    other shape is dropped, never repaired: a 304 on a half-copy would be
---    turned into a wrong answer.
--- 2. The copy is bounded: a stored value larger than one release response can
---    be is not a copy this module ever wrote.
--- 3. PURE Lua (LuaJIT and 5.4): no driver imports, no io.
--- ==============================================================================

local M = {}

-- One response is capped at 2 MiB by the Linux transport; a larger body was not stored by it.
M.MAX_BODY_BYTES = 2 * 1024 * 1024





-- ==========================================
-- ==========================================
-- ======= 1/ Validation ====================
-- ==========================================
-- ==========================================

--- Why a value is not a usable copy, or nil when it is one.
--- @param stored any The value read from the Storage port.
--- @param expected_url string|nil The URL the copy must have answered, when the caller knows it.
--- @return string|nil reason
local function refusal(stored, expected_url)
	if type(stored) ~= "table" then return "the stored copy is not a table" end
	if type(stored.url) ~= "string" or stored.url == "" then return "the stored copy has no URL" end
	if expected_url ~= nil and stored.url ~= expected_url then return "the stored copy answers another URL" end
	if type(stored.etag) ~= "string" or stored.etag == "" then return "the stored copy has no ETag" end
	if type(stored.body) ~= "string" or not stored.body:match("^%s*%[") then
		return "the stored copy is not a release array"
	end
	if #stored.body > M.MAX_BODY_BYTES then return "the stored copy exceeds the response bound" end
	return nil
end

--- Admits a stored copy.
--- @param stored any The value read from the Storage port.
--- @param expected_url string|nil The URL the copy must have answered.
--- @return table|nil copy { url, etag, body }, a fresh table holding only those fields.
--- @return string|nil reason Why the value was refused.
function M.validate(stored, expected_url)
	local reason = refusal(stored, expected_url)
	if reason then return nil, reason end
	return { url = stored.url, etag = stored.etag, body = stored.body }
end

--- Builds the copy to store after a list was accepted.
--- @param url string The final URL that answered.
--- @param etag string The validator the response carried.
--- @param body string The release array text.
--- @return table|nil copy { url, etag, body }
--- @return string|nil reason Why nothing may be stored.
function M.entry(url, etag, body)
	return M.validate({ url = url, etag = etag, body = body })
end

return M
