--- _shared/lua/config_outdated.lua

--- ==============================================================================
--- MODULE: Outdated Configuration Entries (shared rule)
--- DESCRIPTION:
--- The one rule every Lua reader of config.toml applies to an entry this build
--- no longer knows: a retired or unknown key, or a value naming something that
--- no longer exists (a removed hotkey, gesture slot, mode…). Such an entry is
--- never an ERROR, a refusal or a failed boot sync. It is logged once as a
--- WARNING naming it, ignored at runtime, and left unmarked so the existing
--- config cleanup (« Nettoyer config.toml ») lists it for removal.
---
--- FEATURES & RATIONALE:
--- 1. Warned is offered. partition() both reports an outdated entry and
---    declines to mark it, and marks every entry it keeps, so the cleanup
---    candidate list (config_unused_keys) is exactly the set of warned entries.
--- 2. Once per process. A persisted entry is read at boot, on every scope
---    reload and by the cleanup preview; one WARNING per entry is enough to
---    name it, and the log is never flooded.
--- 3. Known entries are untouched. Only an entry the caller's owner rejects is
---    reported; a real I/O or native refusal of a known entry stays the
---    caller's ERROR.
--- 4. Other files follow the same rule. An outdated entry of a file the cleanup
---    never scans (layers.toml, tap_hold.toml, storage.json…) is warned once,
---    ignored and the rest of the file kept; the WARNING names the file and the
---    entry to fix by hand. A file unreadable or malformed as a whole stays
---    its owner's failure.
--- ==============================================================================

local M = {}

-- Resolved at each report, not at load: an entry is reported once per process,
-- and the logger in place when it is reported is the one that must see it.
local function logger() return require("logger.shim") end
local KeyPath = require("toml_codec.key_path")
local LOG    = "config_outdated"
local unpack = table.unpack or unpack

-- Entries (path and reason) already reported in this process, so each is
-- named exactly once.
local _reported = {}

-- Open cleanup scans: each records every path reported while it runs, logged
-- or not, so the cleanup offers what an owner rejects even when another
-- reader (the setup wizard showing the value) also reads it.
local _scans = {}

--- The detail an owner reports for a stored value its own rule refuses (out
--- of range, not a modifier chord…). One spelling, so the boot read and the
--- cleanup name the entry once.
M.REFUSED = "its owner no longer accepts this value"





-- ==================================
-- ==================================
-- ======= 1/ Report And Keep =======
-- ==================================
-- ==================================

--- Joins path segments into the TOML spelling the log and cleanup show. A
--- persisted key can be anything a hand edit wrote, "" included: it is quoted,
--- never refused, because reporting an entry must not fail the reader.
--- @param segments table|string Path segments, or an already dotted path.
--- @return string path
--- @return boolean offerable Whether every segment is a bare key the cleanup can address.
local function dotted(segments)
	if type(segments) == "string" and segments ~= "" then return segments, true end
	if type(segments) ~= "table" or #segments == 0 then
		error("config_outdated: a path needs at least one segment", 3)
	end
	local texts, offerable = {}, true
	for index, segment in ipairs(segments) do
		texts[index] = tostring(segment)
		-- The cleanup only cuts bare-key records (config_unused_keys, feature 4).
		if type(segment) ~= "string" or not segment:match("^[A-Za-z0-9_%-]+$") then offerable = false end
	end
	return KeyPath.render(texts), offerable
end

--- Reports one outdated configuration entry, once per process.
--- @param segments table|string Path of the entry, e.g. { "shortcuts", "keys", "at_hash" }.
--- @param detail string Why this build does not use it.
--- @param sink table|nil The reporting owner's logger; the shared one by default.
--- @return boolean first True when this call logged the WARNING.
function M.report(segments, detail, sink)
	local path, offerable = dotted(segments)
	for _, scan in ipairs(_scans) do scan[path] = true end
	detail = tostring(detail or "this build does not use it")
	-- The same key holding another stale value is another entry to name.
	local identity = path .. "\0" .. detail
	if _reported[identity] then return false end
	_reported[identity] = true
	if offerable then
		(sink or logger()).warn(LOG, "Outdated configuration entry '%s' ignored (%s); it is offered for cleanup.",
			path, detail)
	else
		-- A quoted key or a list member has no line the cleanup can cut;
		-- promising it would be false.
		(sink or logger()).warn(LOG, "Outdated configuration entry '%s' ignored (%s); the config cleanup "
			.. "cannot remove a quoted key or a list member, delete it from config.toml by hand.", path, detail)
	end
	return true
end

--- Reports one outdated entry of a file the config cleanup never scans
--- (layers.toml, tap_hold.toml, storage.json…), once per process. Only
--- config.toml has a cleanup, so the WARNING names the file and the entry to
--- fix by hand instead of promising a cleanup, and no cleanup scan records it.
--- @param file string Path of the file holding the entry.
--- @param segments table|string Path of the entry inside that file.
--- @param detail string Why this build does not use it.
--- @param sink table|nil The reporting owner's logger; the shared one by default.
--- @return boolean first True when this call logged the WARNING.
function M.report_in_file(file, segments, detail, sink)
	if type(file) ~= "string" or file == "" then
		error("config_outdated: an entry outside config.toml needs its file", 2)
	end
	local path = dotted(segments)
	detail = tostring(detail or "this build does not use it")
	local identity = file .. "\0" .. path .. "\0" .. detail
	if _reported[identity] then return false end
	_reported[identity] = true
	(sink or logger()).warn(LOG, "Outdated entry '%s' in '%s' ignored (%s); the config cleanup only covers "
		.. "config.toml, so fix or delete it in that file.", path, file, detail)
	return true
end

--- Reads a persisted table of id = value settings. Another shape where this
--- build keeps such a table (a scalar, or an older build's list) is outdated
--- as a whole: reported once and read as absent, never asserted on.
--- @param value any Persisted value.
--- @param segments table|string Path of the table.
--- @param sink table|nil The reporting owner's logger.
--- @return table|nil settings The table, or nil when absent or outdated.
function M.settings_table(value, segments, sink)
	if value == nil then return nil end
	if type(value) ~= "table" then
		M.report(segments, "a table of settings is expected here", sink)
		return nil
	end
	-- A TOML array decodes as a sequence.
	if #value > 0 then
		M.report(segments, "a list is not a table of settings", sink)
		return nil
	end
	return value
end

--- Splits a persisted id → value table into the entries a live owner knows and
--- the outdated ones. Every kept entry is marked for the cleanup; every other
--- one is reported and left unmarked, so the cleanup offers it.
--- @param prefix table Path segments of the table, e.g. { "shortcuts", "keys" }.
--- @param map table Persisted entries.
--- @param is_known function `is_known(id, value) -> boolean, detail?`.
--- @param mark function|nil Cleanup mark(...segments), when collecting.
--- @return table kept Entries the owner knows.
--- @return table outdated Sorted ids of the reported entries.
function M.partition(prefix, map, is_known, mark)
	if type(prefix) ~= "table" or #prefix == 0 then
		error("config_outdated.partition needs the table path as segments", 2)
	end
	if type(map) ~= "table" then error("config_outdated.partition needs a table", 2) end
	if type(is_known) ~= "function" then error("config_outdated.partition needs an is_known owner", 2) end
	local kept, outdated = {}, {}
	if M.settings_table(map, prefix) == nil then return kept, outdated end
	for id, value in pairs(map) do
		local known, detail = false, "not a text key"
		if type(id) == "string" and id ~= "" then known, detail = is_known(id, value) end
		local segments = {}
		for index, segment in ipairs(prefix) do segments[index] = segment end
		segments[#segments + 1] = id
		if known == true then
			kept[id] = value
			if mark then mark(unpack(segments)) end
		else
			outdated[#outdated + 1] = tostring(id)
			M.report(segments, detail)
		end
	end
	table.sort(outdated)
	return kept, outdated
end

--- Runs a cleanup collection and returns every path an owner reported as
--- outdated during it.
--- @param collect function The driver's readers, run once.
--- @return table outdated Set of dotted paths.
function M.collect_reports(collect)
	if type(collect) ~= "function" then error("config_outdated.collect_reports needs a function", 2) end
	local scan = {}
	_scans[#_scans + 1] = scan
	local ok, err = xpcall(collect, debug.traceback)
	for index = #_scans, 1, -1 do
		if _scans[index] == scan then table.remove(_scans, index) end
	end
	if not ok then error(err, 0) end
	return scan
end

--- Checks a persisted value against its manifest entry: the entry must exist
--- for this driver and the value must still be one it accepts.
--- @param entry table|nil Manifest feature entry.
--- @param value any Persisted value.
--- @param platform string|nil Manifest platform tag of the reading driver.
--- @param accepts function|nil The owning module's own value rule,
---   `accepts(value) -> boolean, detail?`, used instead of the manifest type
---   when the owner applies more (a coerced number) or knows more (whether an
---   action still exists) than the declared Lua type says.
--- @return boolean known
--- @return string|nil detail Why the value is outdated.
function M.manifest_value_fits(entry, value, platform, accepts)
	if type(entry) ~= "table" then return false, "no setting of this build declares it" end
	if platform and type(entry.platforms) == "table" then
		local listed = false
		for _, tag in ipairs(entry.platforms) do
			if tag == platform then listed = true; break end
		end
		if not listed then return false, "this driver has no such setting" end
	end
	if accepts ~= nil then return accepts(value) end
	if entry.type == "boolean" and type(value) ~= "boolean" then
		return false, "the value is not a boolean"
	end
	if entry.type == "number" and type(value) ~= "number" then
		return false, "the value is not a number"
	end
	if entry.type == "enum" and type(entry.enum_values) == "table" then
		for _, allowed in ipairs(entry.enum_values) do
			if allowed == value then return true end
		end
		return false, "'" .. tostring(value) .. "' is no longer one of its values"
	end
	return true
end





-- ============================
-- ============================
-- ======= 2/ Test Seam =======
-- ============================
-- ============================

--- Forgets which entries were reported, so a test observes a fresh process.
function M.reset_for_tests()
	_reported = {}
end

return M
