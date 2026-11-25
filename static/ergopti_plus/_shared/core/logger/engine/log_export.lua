--- _shared/core/logger/engine/log_export.lua

--- ==============================================================================
--- MODULE: Log Export Selection and Scrub
--- DESCRIPTION:
--- The pure half of « Export the logs (zip) » on macOS and Linux: which files of
--- the logs folders enter the archive, the name of the archive, and the copy of
--- each entry without the user's typed text. Each driver owns the I/O (listing,
--- reading, writing, revealing); the Windows port in
--- windows/diagnostics/engine/log_export.ahk replays the same shared vectors
--- (_shared/tests/corpus/logger/log_export_vectors.json).
---
--- FEATURES & RATIONALE:
--- 1. One daily log is the only log (maintainer decision, 2026-11-25), so the
---    archive is the daily logs and errors mirrors of the last N days plus the
---    files the logger cannot write itself (log_export.toml); nothing else in
---    the folder, a user file or a retired topical file, is ever selected.
--- 2. The scrub is the runtime port of tools/dev/field-log-scrub.py, with plain
---    markers instead of regular expressions so the three drivers apply the
---    same rules (Lua has no regular expressions). It withholds more, never
---    less: a bundled trigger is withheld too.
--- ==============================================================================

local M = {}

local AppDirs = require("core.fs.engine.app_dirs")
local Data = require("core.logger.engine.log_export_data")

M.DAYS = Data.days
M.WITHHELD = Data.withheld

--- Pre-logger files each platform writes in its DEFAULT logs folder.
local PRE_LOGGER = {
	hs = { AppDirs.files.bootstrap_log, AppDirs.macos.launcher_log, AppDirs.macos.fatal_report,
		AppDirs.macos.reload_breadcrumb },
	linux = { AppDirs.files.bootstrap_log },
	ahk = { AppDirs.files.bootstrap_log },
}

--- The calendar dates of the export window, newest first.
--- @param today string "YYYY-MM-DD".
--- @param days number Whole days, today included.
--- @return table dates
function M.window_dates(today, days)
	local year, month, day = tostring(today):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if not year then error("log_export.window_dates: today must be YYYY-MM-DD", 2) end
	if type(days) ~= "number" or days < 1 or days % 1 ~= 0 then
		error("log_export.window_dates: days must be a positive whole number", 2)
	end
	local dates = {}
	for offset = 0, days - 1 do
		-- Noon anchor: a DST change never moves the date across midnight.
		local stamp = os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day) - offset,
			hour = 12 })
		dates[#dates + 1] = os.date("%Y-%m-%d", stamp)
	end
	return dates
end

--- Indexes a list of names.
local function set_of(names)
	local set = {}
	for _, name in ipairs(names or {}) do set[name] = true end
	return set
end

--- Selects the files of the archive.
--- @param listing table {
---   platform = "hs"|"linux"|"ahk",
---   today = "YYYY-MM-DD", days = number|nil (defaults to M.DAYS),
---   logs = { names of the regular files directly in the logs folder },
---   default = { names of the regular files directly in the default logs folder },
---   crash_reports = { names of the regular files in <logs>/crash_reports } }
--- @return table selected Array of { folder = "logs"|"default"|"crash_reports",
---   name = string, archive = string }, sorted by archive name.
function M.select(listing)
	if type(listing) ~= "table" then error("log_export.select: listing must be a table", 2) end
	local pre_logger = PRE_LOGGER[listing.platform]
	if not pre_logger then error("log_export.select: unknown platform " .. tostring(listing.platform), 2) end
	local logs, default = set_of(listing.logs), set_of(listing.default)
	local selected = {}
	local files = AppDirs.files
	for _, date in ipairs(M.window_dates(listing.today, listing.days or M.DAYS)) do
		for _, prefix in ipairs({ files.unified_prefix, files.errors_prefix }) do
			local name = prefix .. date .. files.extension
			if logs[name] then selected[#selected + 1] = { folder = "logs", name = name, archive = name } end
		end
	end
	for _, name in ipairs(pre_logger) do
		if default[name] then selected[#selected + 1] = { folder = "default", name = name, archive = name } end
	end
	local extension = Data.crash_report_extension
	for _, name in ipairs(listing.crash_reports or {}) do
		if #name > #extension and name:sub(-#extension) == extension and name:sub(1, 1) ~= "."
			and not name:find("[/\\]") then
			selected[#selected + 1] = { folder = "crash_reports", name = name,
				archive = AppDirs.crash_reports_dir .. "/" .. name }
		end
	end
	table.sort(selected, function(a, b) return a.archive < b.archive end)
	return selected
end

--- The archive's file name.
--- @param stamp table Local date table (os.date("*t")).
--- @return string name
function M.archive_name(stamp)
	if type(stamp) ~= "table" or type(stamp.year) ~= "number" then
		error("log_export.archive_name: stamp must be a date table", 2)
	end
	return string.format("%s%04d-%02d-%02d_%02d-%02d-%02d%s", Data.name_prefix, stamp.year, stamp.month,
		stamp.day, stamp.hour, stamp.min, stamp.sec, Data.extension)
end

--- Whether a line starts a record (a timestamp or a "=====" banner).
local function starts_record(line)
	return line:find("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d") ~= nil or line:sub(1, 5) == "====="
end

--- One line without the user's typed text.
--- @param line string
--- @return string kept, boolean withheld
function M.scrub_line(line)
	for _, rule in ipairs(Data.rules) do
		local _, marker_end = line:find(rule.marker, 1, true)
		if marker_end then
			local keep = marker_end
			if rule.cut ~= "" then
				local _, cut_end = line:find(rule.cut, marker_end + 1, true)
				if cut_end then keep = cut_end end
			end
			return line:sub(1, keep) .. Data.withheld, true
		end
	end
	return line, false
end

--- A whole file without the user's typed text: LF line endings, no BOM, and
--- the continuation lines of a withheld record dropped.
--- @param text string File contents.
--- @return string scrubbed
function M.scrub_text(text)
	if type(text) ~= "string" then error("log_export.scrub_text: text must be a string", 2) end
	if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
	local out, dropping = {}, false
	for line in (text:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
		if not (dropping and not starts_record(line)) then
			local kept
			kept, dropping = M.scrub_line(line)
			out[#out + 1] = kept
		end
	end
	-- The split adds one empty line after a final newline; drop only that one.
	if text:sub(-1) == "\n" and out[#out] == "" then out[#out] = nil end
	return #out > 0 and (table.concat(out, "\n") .. "\n") or ""
end

return M
