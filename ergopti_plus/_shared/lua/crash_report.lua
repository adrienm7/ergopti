--- _shared/lua/crash_report.lua

--- ==============================================================================
--- MODULE: Crash Report Format And Retention
--- DESCRIPTION:
--- The one crash-report document and the one retention policy of the macOS and
--- Linux drivers (parity audit D6 and R31). The drivers gather their own facts
--- and own every native effect; this module owns what a report contains, how
--- it is serialised, what its file is called and how many are kept.
---
--- FEATURES & RATIONALE:
--- 1. One Record: the macOS report is the reference content. Every field has a
---    string value and a default, so a driver that cannot know a field (the
---    Linux daemon has no screen resolution) still writes the same keys, in the
---    same order, and a reader never branches on the driver. The `module` field
---    is the only addition: it names the protected module that raised, which the
---    Linux crash notice shows and macOS leaves empty.
--- 2. Deterministic JSON: keys are written in the documented order, two spaces
---    deep, with the shared JSON string quoting. The serialiser used to be the
---    host's (hs.json on macOS), so the byte layout depended on the driver.
--- 3. One Name: `<timestamp>.json`, colons replaced by hyphens, a numeric suffix
---    from `-2` for a second report within the same second. The timestamp is UTC,
---    so names sort chronologically on every machine.
--- 4. One Cap: MAX_REPORTS, oldest first. Only files that carry the report name
---    are ever selected, so a stray file the user put in the folder is never
---    deleted, and the cap counts reports rather than directory entries.
--- 5. Fail Fast: an unknown field is a programming error and raises; a
---    non-string value is converted, never dropped.
---
--- WINDOWS: the AutoHotkey reporter (crash_report_worker.ahk) has no cap and its
--- own text layout. It must adopt FIELDS (as a JSON object, same order), the file
--- name scheme and MAX_REPORTS, with the same vectors
--- (_shared/tests/corpus/diagnostics/crash_report_vectors.json).
--- ==============================================================================

local M = {}

local Json = require("json")





-- =============================
-- =============================
-- ======= 1/ The Record =======
-- =============================
-- =============================

--- The number of reports kept in the crash folder, newest first.
M.MAX_REPORTS = 20

--- The fields of a report, in the order they are written, with their defaults.
--- A default is what a driver that cannot know the field records.
M.FIELDS = {
	{ "version", "unknown" },
	{ "driver", "unknown" },
	{ "timestamp", "" },
	{ "module", "" },
	{ "error_msg", "" },
	{ "stack_trace", "" },
	{ "os_version", "unknown" },
	{ "hs_version", "unknown" },
	{ "screen_res", "unknown" },
	{ "locale", "unknown" },
	{ "config_dir", "" },
	{ "script_dir", "" },
	{ "git_hash", "unknown" },
	{ "commit_source", "unknown" },
	{ "active_app", "" },
	{ "active_title", "" },
	{ "uptime_sec", "0" },
	{ "adapters_ok", "" },
	{ "adapters_failed", "" },
	{ "session_warnings", "0" },
	{ "session_errors", "0" },
	{ "log_tail", "" },
}

local DEFAULT_BY_FIELD = {}
for _, field in ipairs(M.FIELDS) do DEFAULT_BY_FIELD[field[1]] = field[2] end

--- Completes a record: every documented field, strings only.
--- @param fields table Facts the driver gathered, keyed by field name.
--- @return table record A fresh table with every field of FIELDS.
function M.build(fields)
	assert(type(fields) == "table", "a crash report needs its facts")
	for key in pairs(fields) do
		assert(DEFAULT_BY_FIELD[key] ~= nil, "unknown crash report field: " .. tostring(key))
	end
	local record = {}
	for _, field in ipairs(M.FIELDS) do
		local value = fields[field[1]]
		if value == nil then value = field[2] end
		record[field[1]] = tostring(value)
	end
	return record
end

--- Serialises a built record as the report document.
--- @param record table From M.build.
--- @return string json Pretty JSON object, no trailing newline.
function M.encode(record)
	assert(type(record) == "table", "a crash report needs its record")
	local lines = {}
	for _, field in ipairs(M.FIELDS) do
		local value = record[field[1]]
		assert(type(value) == "string", "crash report field is not built: " .. field[1])
		lines[#lines + 1] = "  " .. Json.quote(field[1]) .. ": " .. Json.quote(value)
	end
	return "{\n" .. table.concat(lines, ",\n") .. "\n}"
end





-- ===========================================
-- ===========================================
-- ======= 2/ File Names And Retention =======
-- ===========================================
-- ===========================================

--- The file stem of a report: its UTC timestamp with colons made portable.
--- @param timestamp string "YYYY-MM-DDTHH:MM:SSZ".
--- @return string stem "YYYY-MM-DDTHH-MM-SSZ".
function M.stem(timestamp)
	assert(type(timestamp) == "string" and timestamp:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"),
		"a crash report timestamp is YYYY-MM-DDTHH:MM:SSZ")
	return (timestamp:gsub(":", "-"))
end

--- The file name of a report.
--- @param stem string From M.stem.
--- @param attempt integer|nil 1 (default) for the plain name, n >= 2 for a collision.
--- @return string name
function M.file_name(stem, attempt)
	attempt = attempt or 1
	assert(type(attempt) == "number" and attempt >= 1 and attempt % 1 == 0,
		"a crash report attempt is a positive integer")
	return stem .. (attempt == 1 and "" or ("-" .. attempt)) .. ".json"
end

--- Splits a file name into its stem and attempt.
--- @param name string File name without directory.
--- @return string|nil stem Nil when the name is not a report name.
--- @return integer|nil attempt
function M.parse_name(name)
	if type(name) ~= "string" then return nil end
	local stem, suffix = name:match("^(%d%d%d%d%-%d%d%-%d%dT%d%d%-%d%d%-%d%dZ)(%-?%d*)%.json$")
	if not stem then return nil end
	if suffix == "" then return stem, 1 end
	local attempt = tonumber(suffix:sub(2))
	if not attempt or attempt < 2 then return nil end
	return stem, attempt
end

--- The reports to delete so that at most `limit` remain, oldest first.
--- Names that are not report names are ignored: they are never selected.
--- @param names table File names found in the crash folder.
--- @param limit integer|nil Reports to keep (default MAX_REPORTS).
--- @return table expired Names to delete, oldest first.
function M.expired(names, limit)
	limit = limit or M.MAX_REPORTS
	assert(type(names) == "table", "the crash folder listing is a list of names")
	assert(type(limit) == "number" and limit >= 1 and limit % 1 == 0, "the report limit is a positive integer")
	local reports = {}
	for _, name in ipairs(names) do
		local stem, attempt = M.parse_name(name)
		if stem then reports[#reports + 1] = { name = name, stem = stem, attempt = attempt } end
	end
	table.sort(reports, function(a, b)
		if a.stem ~= b.stem then return a.stem < b.stem end
		return a.attempt < b.attempt
	end)
	local expired = {}
	for index = 1, #reports - limit do expired[#expired + 1] = reports[index].name end
	return expired
end

return M
