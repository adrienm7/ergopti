--- _shared/lua/llm/request_settings.lua

--- ==============================================================================
--- MODULE: Request Settings — Shared Lua Implementation
--- DESCRIPTION:
--- The settings an AI request is sent with, and the test that one of them
--- changed while it was in flight. A change of the backend, the API entry, its
--- provider, model, endpoint or key retires the request, as Windows does
--- (maintainer decision AID-3 of 11 November 2026): its answer is dropped, its
--- transport cancelled, and the next request is sent with the new settings.
---
--- FEATURES & RATIONALE:
--- 1. One field list for macOS (modules/llm/prediction_engine.lua) and Linux
---    (modules/llm/prediction_engine.lua); each driver reads its own sources.
--- 2. Values are compared, never logged: the key is held only as long as the
---    request.
--- ==============================================================================

local M = {}

-- The settings a change of which retires the request in flight, in the order
-- a change is reported
M.FIELDS = { "backend", "entry", "provider", "model", "endpoint", "key" }

local KNOWN = {}
for _, field in ipairs(M.FIELDS) do KNOWN[field] = true end

--- A snapshot of the settings a request is sent with.
--- @param values table Any of FIELDS; an absent one is nil.
--- @return table snapshot
function M.snapshot(values)
	if type(values) ~= "table" then error("request_settings.snapshot requires a table", 2) end
	local snapshot = {}
	for field, value in pairs(values) do
		if not KNOWN[field] then error("request_settings.snapshot: unknown field " .. tostring(field), 2) end
		snapshot[field] = value
	end
	return snapshot
end

--- The first field that differs between two snapshots, or nil when none does.
--- @param before table The request's snapshot.
--- @param now table The settings now.
--- @return string|nil field
function M.change(before, now)
	if type(before) ~= "table" or type(now) ~= "table" then
		error("request_settings.change requires two snapshots", 2)
	end
	for _, field in ipairs(M.FIELDS) do
		if before[field] ~= now[field] then return field end
	end
	return nil
end

return M
