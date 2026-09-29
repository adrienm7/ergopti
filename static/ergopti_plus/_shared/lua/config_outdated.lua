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
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local LOG    = "config_outdated"
local unpack = table.unpack or unpack

-- Paths already reported in this process, so each is named exactly once.
local _reported = {}





-- ==================================
-- ==================================
-- ======= 1/ Report And Keep =======
-- ==================================
-- ==================================

--- Joins path segments into the dotted spelling the log and cleanup show.
--- @param segments table|string Path segments, or an already dotted path.
--- @return string path
local function dotted(segments)
	if type(segments) == "string" then return segments end
	if type(segments) ~= "table" or #segments == 0 then
		error("config_outdated: a path needs at least one segment", 3)
	end
	for _, segment in ipairs(segments) do
		if type(segment) ~= "string" or segment == "" then
			error("config_outdated: path segments must be non-empty strings", 3)
		end
	end
	return table.concat(segments, ".")
end

--- Reports one outdated configuration entry, once per process.
--- @param segments table|string Path of the entry, e.g. { "shortcuts", "keys", "at_hash" }.
--- @param detail string Why this build does not use it.
--- @return boolean first True when this call logged the WARNING.
function M.report(segments, detail)
	local path = dotted(segments)
	if _reported[path] then return false end
	_reported[path] = true
	Logger.warn(LOG, "Outdated configuration entry '%s' ignored (%s); it is offered for cleanup.",
		path, tostring(detail or "this build does not use it"))
	return true
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
	for id, value in pairs(map) do
		local known, detail = false, "not a text key"
		if type(id) == "string" and id ~= "" then known, detail = is_known(id, value) end
		local segments = {}
		for index, segment in ipairs(prefix) do segments[index] = segment end
		segments[#segments + 1] = tostring(id)
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

--- Checks a persisted value against its manifest entry: the entry must exist
--- for this driver and the value must still be one it accepts.
--- @param entry table|nil Manifest feature entry.
--- @param value any Persisted value.
--- @param platform string|nil Manifest platform tag of the reading driver.
--- @return boolean known
--- @return string|nil detail Why the value is outdated.
function M.manifest_value_fits(entry, value, platform)
	if type(entry) ~= "table" then return false, "no setting of this build declares it" end
	if platform and type(entry.platforms) == "table" then
		local listed = false
		for _, tag in ipairs(entry.platforms) do
			if tag == platform then listed = true; break end
		end
		if not listed then return false, "this driver has no such setting" end
	end
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
