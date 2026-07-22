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
---    windows/ui/healthcheck/helpers.ahk.
--- 3. snapshot_schema: returns the canonical field list so both drivers and
---    the corpus test can validate that a snapshot has every expected key.
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


--- Counts warnings and errors in a ring-buffer snapshot.
--- @param lines table Array of log lines.
--- @return integer warn_count, integer err_count
function M.count_issues(lines)
	if type(lines) ~= "table" then return 0, 0 end
	local warn_count, err_count = 0, 0
	for _, line in ipairs(lines) do
		if type(line) == "string" then
			if line:find("%[WARNING%]") then warn_count = warn_count + 1 end
			if line:find("%[ERROR%]")   then err_count  = err_count  + 1 end
		end
	end
	return warn_count, err_count
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

return M
