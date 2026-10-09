--- _shared/lua/healthcheck/snapshot.lua

--- ==============================================================================
--- MODULE: Diagnostics Snapshot Shared Logic
--- DESCRIPTION:
--- Pure functions shared between the macOS (Lua) and Linux (Lua) diagnostics
--- hosts. The Windows (AHK) driver cannot require Lua modules, so its
--- ui/healthcheck/ keeps copies whose output is pinned by the shared corpora
--- (_shared/tests/corpus/healthcheck/).
---
--- FEATURES & RATIONALE:
--- 1. extract_recent_issues: the ring fallback of the recent warnings and
---    errors, used only before today's errors file exists.
--- 2. recent_issues: the window's recent warnings and errors come from a
---    bounded tail of today's errors file. The ring holds every level, so at
---    DEBUG a few minutes of routine lines evicted the very problems the
---    window is opened to show; the file keeps WARNING and ERROR only. The
---    tail parser is pinned by _shared/tests/corpus/healthcheck/errors_tail_vectors.json.
--- 3. The version 2 snapshot: the schema loader, the platform rules, the
---    pending probes and check_fields, which names the fields a driver
---    produced that the schema does not declare (drift the page would never
---    show) and the declared ones it left out. The shared page formats every
---    value, so no formatter lives here any more.
--- ==============================================================================

local M = {}





-- ==========================================
-- ==========================================
-- ======= 1/ Recent Issues Extractor =======
-- ==========================================
-- ==========================================

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





-- =========================================================
-- =========================================================
-- ======= 2/ Recent Issues From Today's Errors File =======
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





-- =========================================
-- =========================================
-- ======= 3/ The Version 2 Snapshot =======
-- =========================================
-- =========================================

--- Decodes a JSON document from the shared tree.
--- @param path string Absolute path.
--- @return table
local function read_json(path)
	local fh, err = io.open(path, "rb")
	if not fh then error("diagnostics: " .. path .. " is unreadable: " .. tostring(err), 3) end
	local raw = fh:read("*a")
	fh:close()
	local data = require("json").decode(raw)
	if type(data) ~= "table" then error("diagnostics: " .. path .. " is not a JSON object", 3) end
	return data
end

--- Loads the diagnostics schema (_shared/modules/diagnostics/schema.json).
--- @param path string Absolute path of schema.json.
--- @return table
function M.load_schema(path)
	local schema = read_json(path)
	if schema.schema_version ~= 2 or type(schema.sections) ~= "table" or type(schema.probes) ~= "table" then
		error("diagnostics: " .. path .. " is not a version 2 schema", 2)
	end
	return schema
end

--- Loads the three documents a diagnostics host works from.
--- @param shared function(rel) → absolute path under _shared/.
--- @return table { schema, templates, redaction, repository }
function M.load_config(shared)
	local defaults = read_json(shared("modules/updater/defaults.json"))
	return {
		schema     = M.load_schema(shared("modules/diagnostics/schema.json")),
		templates  = read_json(shared("modules/diagnostics/issue_templates.json")),
		redaction  = read_json(shared("modules/diagnostics/redaction.json")),
		repository = defaults.github,
	}
end

--- True when a schema entry (a section, a field or a probe) applies to a driver.
--- @param entry table
--- @param driver string
--- @return boolean
function M.applies(entry, driver)
	if type(entry.platforms) ~= "table" then return true end
	for _, platform in ipairs(entry.platforms) do
		if platform == driver then return true end
	end
	return false
end

--- The probe that fills a field on a driver, or nil.
--- @param field table
--- @param driver string
--- @return string|nil
function M.probe_for(field, driver)
	if type(field.probe) == "string" then return field.probe end
	if type(field.probe) == "table" then return field.probe[driver] end
	return nil
end

--- The pending state of every probe that applies to a driver.
--- @param schema table
--- @param driver string
--- @return table { <probe id> = { state = "pending" } }
function M.pending_probes(schema, driver, selected)
	local probes = {}
	for id, probe in pairs(schema.probes) do
		if M.applies(probe, driver) then
			probes[id] = selected == false and { state = "not_run", reason = "opt_in_required" } or { state = "pending" }
		end
	end
	return probes
end

--- The current UTC time as ISO 8601, the snapshot's generated_at.
--- @param now number|nil Epoch seconds (tests); os.time() otherwise.
--- @return string
function M.utc_now(now)
	return os.date("!%Y-%m-%dT%H:%M:%SZ", now or os.time())
end

--- Compares a snapshot with the schema: the fields a driver produced that the
--- schema does not declare for it (drift: the page would never show them),
--- and the declared synchronous fields it did not produce (shown as unknown).
--- @param snapshot table
--- @param schema table
--- @return table undeclared "section.field" names.
--- @return table missing "section.field" names.
function M.check_fields(snapshot, schema)
	local driver = snapshot.driver
	local undeclared, missing = {}, {}
	local declared = {}
	for _, section in ipairs(schema.sections) do
		if M.applies(section, driver) then declared[section.id] = section end
	end
	for id, data in pairs(snapshot.sections or {}) do
		local section = declared[id]
		if not section then
			undeclared[#undeclared + 1] = id
		elseif section.kind ~= "items" and type(data) == "table" then
			local fields = {}
			for _, field in ipairs(section.fields or {}) do
				if M.applies(field, driver) then fields[field.id] = field end
			end
			for field_id in pairs(data) do
				if not fields[field_id] then undeclared[#undeclared + 1] = id .. "." .. tostring(field_id) end
			end
			for field_id, field in pairs(fields) do
				local optional = field.opt_in or M.probe_for(field, driver)
				if data[field_id] == nil and not optional then missing[#missing + 1] = id .. "." .. field_id end
			end
		end
	end
	for id, section in pairs(declared) do
		if section.kind ~= "summary" and snapshot.sections[id] == nil then missing[#missing + 1] = id end
	end
	table.sort(undeclared)
	table.sort(missing)
	return undeclared, missing
end

return M
