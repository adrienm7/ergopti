--- _shared/lua/healthcheck/snapshot.lua

--- ==============================================================================
--- MODULE: Healthcheck Snapshot Shared Logic
--- DESCRIPTION:
--- Pure functions shared between the macOS (Lua) and Linux (Lua) healthcheck
--- implementations. The Windows (AHK) driver cannot require Lua modules, so
--- its helpers.ahk keeps a hand-maintained copy whose output is pinned by the
--- shared corpus test (see _shared/tests/corpus/healthcheck/).
---
--- FEATURES & RATIONALE:
--- 1. format_uptime: converts raw seconds to "Hh MMm SSs" / "Mm SSs" / "Ss".
---    Previously duplicated in macos/ui/healthcheck/helpers.lua,
---    windows/ui/healthcheck/helpers.ahk, and _shared/ui/healthcheck/script.js.
--- 2. extract_recent_issues: filters a ring-buffer snapshot for [WARNING] /
---    [ERROR] lines and trims to the last N entries. Previously inline in
---    macos/ui/healthcheck/core.lua and as a separate function in
---    windows/ui/healthcheck/helpers.ahk. Now only the fallback of 4.
--- 3. snapshot_schema: returns the canonical field list so both drivers and
---    the corpus test can validate that a snapshot has every expected key.
--- 4. recent_issues: the window's recent warnings and errors come from a
---    bounded tail of today's errors file. The ring holds every level, so at
---    DEBUG a few minutes of routine lines evicted the very problems the
---    window is opened to show; the file keeps WARNING and ERROR only. The
---    ring is used only when today's file does not exist yet. The tail parser
---    is pinned by _shared/tests/corpus/healthcheck/errors_tail_vectors.json.
--- ==============================================================================

local M = {}





-- ==========================================
-- ==========================================
-- ======= 1/ Uptime Formatter ==============
-- ==========================================
-- ==========================================

--- Converts raw seconds to a human-readable uptime string.
--- Format: "Hh MMm SSs" when >= 1h, "Mm SSs" when >= 1m, "Ss" otherwise.
--- Zero-pads minutes and seconds to 2 digits when hours or minutes are present.
--- @param sec number Elapsed seconds (nil-safe — treated as 0).
--- @return string Formatted uptime.
function M.format_uptime(sec)
	sec = math.floor(sec or 0)
	local h = math.floor(sec / 3600)
	local m = math.floor((sec % 3600) / 60)
	local s = sec % 60
	if h > 0 then
		return string.format("%dh %02dm %02ds", h, m, s)
	elseif m > 0 then
		return string.format("%dm %02ds", m, s)
	else
		return string.format("%ds", s)
	end
end




-- ==============================================
-- ==============================================
-- ======= 2/ Recent Issues Extractor ==========
-- ==============================================
-- ==============================================

--- Filters a ring-buffer snapshot (array of strings) for [WARNING] and [ERROR]
--- lines, then trims to the last ``max_lines`` entries.
--- @param lines table Array of log lines (from Logger.ring_buffer_snapshot()).
--- @param max_lines integer Maximum entries to return (default 100).
--- @return table Array of matching lines, oldest-first, trimmed to max_lines.
function M.extract_recent_issues(lines, max_lines)
	max_lines = max_lines or 100
	if type(lines) ~= "table" then return {} end

	local issues = {}
	for _, line in ipairs(lines) do
		if type(line) == "string" then
			if line:find("%[WARNING%]") or line:find("%[ERROR%]") then
				issues[#issues + 1] = line
			end
		end
	end

	if #issues <= max_lines then
		return issues
	end

	-- Keep only the last max_lines entries
	local trimmed = {}
	for i = #issues - max_lines + 1, #issues do
		trimmed[#trimmed + 1] = issues[i]
	end
	return trimmed
end






-- ================================================
-- ================================================
-- ======= 3/ Snapshot Schema =====================
-- ================================================
-- ================================================

--- Returns the canonical list of top-level snapshot field names.
--- Both drivers (macOS Lua, AHK) must produce a snapshot containing every
--- key in this list. The corpus test validates this.
--- @return table Array of field name strings.
function M.snapshot_fields()
	return {
		"version",
		"loaded_adapters",
		"ports_validated",
		"failed_adapters",
		"last_error",
		"uptime_sec",
		"warn_count",
		"err_count",
		"recent_issues",
		"sys",
		"pause_state",
		"keylogger",
		"llm",
		"layout",
		"hotstrings",
		"logs",
		"config",
	}
end

--- Validates that a snapshot table contains every canonical field.
--- @param snapshot table The snapshot to validate.
--- @return boolean ok, table missing Array of missing field names (empty if ok).
function M.validate_snapshot(snapshot)
	if type(snapshot) ~= "table" then return false, { "(not a table)" } end
	local missing = {}
	for _, field in ipairs(M.snapshot_fields()) do
		if snapshot[field] == nil then
			missing[#missing + 1] = field
		end
	end
	return #missing == 0, missing
end





-- =========================================================
-- =========================================================
-- ======= 4/ Recent Issues From Today's Errors File =======
-- =========================================================
-- =========================================================

-- The UTF-8 byte order mark some writers open the errors file with (the
-- Windows logger does)
local UTF8_BOM = "\239\187\191"

-- The levels the errors file carries, as rendered labels
local ISSUE_LABELS = { WARNING = true, ERROR = true }

-- errno for "no such file": the one open failure that means "no errors file
-- yet" rather than "a file that exists but cannot be read"
local ENOENT = 2

--- Returns the level label when the line opens a log entry (spec § 3
--- timestamp, then the bracketed label), nil for a continuation line.
--- @param line string
--- @return string|nil
local function entry_label(line)
	return line:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d:%d%d%d %[(%u+)%] ")
end

--- Turns the tail of an errors file into its WARNING and ERROR entries.
---
--- A read that did not start at byte 0 began inside a line (or inside a UTF-8
--- sequence), so its first line is dropped: it cannot be told from a partial
--- one. Continuation lines (a traceback) join the entry above them; lines of
--- any other level, and continuations with no entry above them, are dropped.
--- @param chunk string Bytes read from the end of the file.
--- @param at_file_start boolean True when the read began at byte 0.
--- @param max_entries number How many of the newest entries to keep.
--- @return table Entries, oldest first.
function M.parse_errors_tail(chunk, at_file_start, max_entries)
	if type(chunk) ~= "string" then error("parse_errors_tail: chunk must be a string", 2) end
	if type(max_entries) ~= "number" or max_entries < 1 then
		error("parse_errors_tail: max_entries must be a positive number", 2)
	end
	local text = chunk
	if at_file_start and text:sub(1, #UTF8_BOM) == UTF8_BOM then text = text:sub(#UTF8_BOM + 1) end
	text = text:gsub("\r\n", "\n"):gsub("\r", "\n")

	local entries = {}
	-- Index of the entry continuation lines join; false inside an entry of
	-- another level, nil before the first entry
	local current = nil
	local index = 0
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		index = index + 1
		if (index > 1 or at_file_start) and line ~= "" then
			local label = entry_label(line)
			if label then
				if ISSUE_LABELS[label] then
					entries[#entries + 1] = line
					current = #entries
				else
					current = false
				end
			elseif current then
				entries[current] = entries[current] .. "\n" .. line
			end
		end
	end

	if #entries <= max_entries then return entries end
	local newest = {}
	for i = #entries - max_entries + 1, #entries do newest[#newest + 1] = entries[i] end
	return newest
end

--- Reads at most max_bytes from the end of a file.
--- @param path string
--- @param max_bytes number
--- @param open_fn function|nil io.open replacement for tests.
--- @return string|nil chunk nil when the file cannot be opened.
--- @return boolean|string at_file_start, or the open error.
--- @return number|nil errno of the open failure.
function M.read_tail(path, max_bytes, open_fn)
	local fh, err, code = (open_fn or io.open)(path, "rb")
	if not fh then return nil, tostring(err), code end
	local size = fh:seek("end")
	local start = math.max(0, size - max_bytes)
	fh:seek("set", start)
	local chunk = fh:read(size - start) or ""
	fh:close()
	return chunk, start == 0
end

--- Loads the recent-issue bounds from _shared/modules/diagnostics/recent_issues.json.
--- @param path string Absolute path of that file.
--- @return table { tail_max_bytes = number, max_entries = number }
function M.load_recent_issue_limits(path)
	local fh, err = io.open(path, "rb")
	if not fh then error("recent issue limits are unreadable: " .. tostring(err), 2) end
	local raw = fh:read("*a")
	fh:close()
	local data = require("json").decode(raw)
	local limits = type(data) == "table" and {
		tail_max_bytes = data.errors_tail_max_bytes,
		max_entries = data.max_entries,
	} or {}
	for _, name in ipairs({ "tail_max_bytes", "max_entries" }) do
		local value = limits[name]
		if type(value) ~= "number" or value < 1 or value ~= math.floor(value) then
			error("recent issue limits: " .. name .. " must be a positive integer in " .. path, 2)
		end
	end
	return limits
end

--- The window's recent warnings and errors: the tail of today's errors file,
--- or the ring when that file does not exist yet. A file that exists but does
--- not open raises an error, never a reason to answer from the ring: the page
--- would then say the file does not exist, and the AHK port fails the same way.
--- @param errors_path string Today's errors file.
--- @param ring_lines table The logger's ring buffer snapshot.
--- @param limits table From load_recent_issue_limits().
--- @param open_fn function|nil io.open replacement for tests.
--- @return table entries Oldest first.
--- @return string source "errors_file" or "ring".
function M.collect_recent_issues(errors_path, ring_lines, limits, open_fn)
	local chunk, at_start, code = M.read_tail(errors_path, limits.tail_max_bytes, open_fn)
	if chunk then
		return M.parse_errors_tail(chunk, at_start, limits.max_entries), "errors_file"
	end
	if code ~= ENOENT then
		error("today's errors file cannot be read: " .. tostring(at_start), 2)
	end
	return M.extract_recent_issues(ring_lines, limits.max_entries), "ring"
end

return M
