--- _shared/lua/updater/rate_limit.lua

--- ==============================================================================
--- MODULE: GitHub API Rate Limit Detail (Shared Lua)
--- DESCRIPTION:
--- Names an exhausted GitHub API rate limit for the update check on macOS and
--- Linux. Unauthenticated requests get 60 calls an hour per IP address, and the
--- update check, the changelog window and the health check all spend them, so
--- a 403 or 429 is usually that limit and not a network failure (#95).
---
--- FEATURES & RATIONALE:
--- 1. One sentence for both Lua drivers, built from the final response's
---    X-RateLimit-Remaining and X-RateLimit-Reset values as the driver read them.
--- 2. PURE Lua (LuaJIT and 5.4): no driver imports and no io; os.date only
---    formats the reset epoch in UTC.
--- ==============================================================================

local M = {}

--- Describes an exhausted GitHub API rate limit.
--- @param status integer HTTP status of the final response.
--- @param remaining string|integer|nil Its X-RateLimit-Remaining value.
--- @param reset string|integer|nil Its X-RateLimit-Reset value, in epoch seconds.
--- @return string|nil detail The log and window detail, or nil when the response
--- is not an exhausted rate limit.
function M.exhausted_detail(status, remaining, reset)
	if status ~= 403 and status ~= 429 then return nil end
	if remaining ~= 0 and remaining ~= "0" then return nil end
	local epoch = tonumber(reset)
	local when = ""
	if epoch and epoch >= 0 and epoch % 1 == 0 then
		when = ", it resets at " .. os.date("!%Y-%m-%d %H:%M:%S UTC", epoch)
	end
	return string.format("HTTP %d: the GitHub API rate limit is exhausted%s", status, when)
end

return M
