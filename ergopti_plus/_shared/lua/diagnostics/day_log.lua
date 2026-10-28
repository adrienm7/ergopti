--- _shared/lua/diagnostics/day_log.lua

--- ==============================================================================
--- MODULE: Day Log Attachment (Shared Lua)
--- DESCRIPTION:
--- Turns today's complete log file into the opt-in attachment of a bug report:
--- every line redacted by diagnostics.redact, the size checked against a cap,
--- and a short preview (first and last lines) for the page to show before the
--- user decides. Pure: the driver reads the file and hands over its text; the
--- AHK port (windows/infra/day_log.ahk) replays the same vectors
--- (_shared/tests/corpus/diagnostics/day_log_vectors.json).
---
--- FEATURES & RATIONALE:
--- 1. A day, not a tail: the whole file is redacted, line by line, so the
---    per-line logger records stay intact and one slow line cannot hide in a
---    blob.
--- 2. A refusal is a result, never a silent truncation: over the cap the
---    caller gets the reason and both sizes, and nothing is attached.
--- 3. The preview is the redacted text itself (head and tail), so what the
---    user sees is what would be attached.
--- ==============================================================================

local Redact = require("diagnostics.redact")

local M = {}

-- What a log line starts with: its local date and time
local TIME_PREFIX = "^(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d)"

-- The ellipsis that marks a cut preview line
local ELLIPSIS = "\226\128\166"

--- Validates the decoded day_log.json.
--- @param limits table
--- @return table The same table.
function M.check_limits(limits)
	if type(limits) ~= "table" then error("day_log: the limits must be the decoded day_log.json", 2) end
	for _, key in ipairs({ "max_bytes", "preview_head_lines", "preview_tail_lines", "preview_line_max_chars" }) do
		local value = limits[key]
		if type(value) ~= "number" or value < 1 or value ~= math.floor(value) then
			error("day_log: " .. key .. " must be a positive integer", 2)
		end
	end
	return limits
end

--- Cuts a line to `max` code points, marking the cut.
--- @param line string
--- @param max number
--- @return string
local function cut(line, max)
	local count = 0
	for i = 1, #line do
		local b = line:byte(i)
		if b < 0x80 or b > 0xBF then
			count = count + 1
			if count > max then return line:sub(1, i - 1) .. ELLIPSIS end
		end
	end
	return line
end

--- Redacts and measures today's log.
--- @param raw string|nil The file's text; nil only when file_size is over the cap.
--- @param file_size number The file's size in bytes.
--- @param rules table Decoded redaction.json.
--- @param context table Redaction context ({ home, user, config_dir, case_insensitive }).
--- @param limits table Decoded day_log.json.
--- @return table { ok = false, reason = "empty"|"too_large", bytes, cap_bytes } or
---   { ok = true, text, bytes, lines, first_time, last_time, head, tail, cap_bytes }
function M.collect(raw, file_size, rules, context, limits)
	M.check_limits(limits)
	local cap = limits.max_bytes
	if type(file_size) ~= "number" or file_size < 0 then error("day_log: the file size is unknown", 2) end
	if file_size > cap then return { ok = false, reason = "too_large", bytes = file_size, cap_bytes = cap } end
	if type(raw) ~= "string" then error("day_log: the log text is missing", 2) end
	raw = raw:gsub("^\239\187\191", ""):gsub("\r\n", "\n")
	if raw == "" then return { ok = false, reason = "empty", bytes = 0, cap_bytes = cap } end
	if raw:sub(-1) ~= "\n" then raw = raw .. "\n" end
	local lines, first_time, last_time = {}, "", ""
	for line in raw:gmatch("([^\n]*)\n") do
		local clean = Redact.apply(line, rules, context)
		lines[#lines + 1] = clean
		local stamp = clean:match(TIME_PREFIX)
		if stamp then
			if first_time == "" then first_time = stamp end
			last_time = stamp
		end
	end
	local text = table.concat(lines, "\n") .. "\n"
	if #text > cap then return { ok = false, reason = "too_large", bytes = #text, cap_bytes = cap } end
	local head_count, tail_count = limits.preview_head_lines, limits.preview_tail_lines
	local head, tail = {}, {}
	if #lines <= head_count + tail_count then
		head_count, tail_count = #lines, 0
	end
	for i = 1, head_count do head[i] = cut(lines[i], limits.preview_line_max_chars) end
	for i = #lines - tail_count + 1, #lines do tail[#tail + 1] = cut(lines[i], limits.preview_line_max_chars) end
	return {
		ok = true, text = text, bytes = #text, lines = #lines, first_time = first_time, last_time = last_time,
		head = head, tail = tail, cap_bytes = cap,
	}
end

return M
