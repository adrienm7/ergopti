--- _shared/lua/healthcheck/day_log.lua

--- ==============================================================================
--- MODULE: Diagnostics Day Log Host (Shared Lua)
--- DESCRIPTION:
--- What the macOS and Linux diagnostics hosts do with the opt-in day log: read
--- today's log file, collect it (diagnostics.day_log), keep the redacted text
--- for the snapshot it was prepared for, and hand the report actions the file to
--- save next to the report. The Windows host has the same part in
--- windows/ui/healthcheck/day_log.ahk.
---
--- FEATURES & RATIONALE:
--- 1. The text never travels in the snapshot the page receives: the snapshot
---    carries only the closed record (included, bytes, lines).
--- 2. One slot per snapshot, weakly held: a refreshed or closed window drops the
---    text with its snapshot, and a collection prepared for another snapshot is
---    never saved.
--- 3. An unreadable file is an error; only a file that does not exist yet is
---    the answer "missing".
--- ==============================================================================

local DayLog = require("diagnostics.day_log")

local M = {}

-- errno of a file that does not exist
local ENOENT = 2

-- The redacted text kept for each snapshot
local retained = setmetatable({}, { __mode = "k" })

--- Reads today's log, or only measures it when it is over the cap.
--- @param path string
--- @param cap number The most bytes worth reading.
--- @param open_fn function|nil io.open replacement for tests.
--- @return table { found = boolean, size = number, text = string }
function M.read_file(path, cap, open_fn)
	local file, detail, code = (open_fn or io.open)(path, "rb")
	if not file then
		if code == ENOENT then return { found = false, size = 0, text = "" } end
		error("today's log cannot be read: " .. tostring(detail), 2)
	end
	local ok, result = pcall(function()
		local size = file:seek("end")
		if type(size) ~= "number" or size < 0 then error("the log's end cannot be found") end
		if size > cap then return { found = true, size = size, text = "" } end
		if file:seek("set", 0) ~= 0 then error("the log's start cannot be found") end
		local text = file:read("*a")
		if type(text) ~= "string" or #text ~= size then error("the log was not read completely") end
		return { found = true, size = size, text = text }
	end)
	local closed = file:close()
	if not ok then error("today's log cannot be read: " .. tostring(result), 2) end
	if closed ~= true then error("today's log could not be closed", 2) end
	return result
end

--- The page's answer for a collection result.
--- @param result table From diagnostics.day_log.collect, or { ok = false, reason = "missing" }.
--- @return table
function M.reply(result)
	local reply = { type = "action", action = "day_log", ok = true }
	if not result.ok then
		reply.state, reply.bytes, reply.cap_bytes = result.reason, result.bytes or 0, result.cap_bytes or 0
		return reply
	end
	reply.state = "ready"
	for _, key in ipairs({ "bytes", "lines", "cap_bytes", "first_time", "last_time", "head", "tail" }) do
		reply[key] = result[key]
	end
	return reply
end

--- Drops the collection of a snapshot and its record.
--- @param snapshot table
function M.discard(snapshot)
	retained[snapshot] = nil
	snapshot.day_log_attachment = nil
end

--- Collects today's log for a snapshot and retains it.
--- @param snapshot table The window's snapshot; receives the closed record.
--- @param documents table The host documents (redaction, day_log).
--- @param context table The redaction context.
--- @param read_today function(cap) → { found, size, text }.
--- @return table The page's answer.
function M.prepare(snapshot, documents, context, read_today)
	M.discard(snapshot)
	local file = read_today(documents.day_log.max_bytes)
	if not file.found then return M.reply({ ok = false, reason = "missing" }) end
	local result = DayLog.collect(file.text, file.size, documents.redaction, context, documents.day_log)
	if not result.ok then return M.reply(result) end
	retained[snapshot] = result
	snapshot.day_log_attachment = { included = true, bytes = result.bytes, lines = result.lines }
	return M.reply(result)
end

--- The file a save or report action writes next to the report.
--- @param snapshot table
--- @param documents table
--- @param safe table The shareable snapshot (driver, generated_at).
--- @return table { name, text }
function M.file(snapshot, documents, safe)
	local result = retained[snapshot]
	if not result or snapshot.day_log_attachment == nil then
		error("the day log was not prepared for this report", 2)
	end
	local limits = documents.day_log
	local stamp = (tostring(safe.generated_at or "unknown"):gsub("[^%w._%-]", "_"))
	return { name = limits.name_prefix .. safe.driver .. "-" .. stamp .. limits.name_suffix, text = result.text }
end

return M
