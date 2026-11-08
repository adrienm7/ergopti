--- _shared/lua/keystats/metrics_maintenance.lua

--- ==============================================================================
--- MODULE: Dashboard Export and Purge (shared)
--- DESCRIPTION:
--- The values the metrics dashboard's Export and Purge share on macOS and
--- Linux: the tombstone row a Purge appends to the owning writer's ledger, the
--- name of an Export copy, and the folder it lands in. Windows renders the same
--- values in modules/keystats/keystats_maintenance.ahk; both are checked against
--- _shared/tests/corpus/keystats/metrics_maintenance_vectors.json.
---
--- FEATURES & RATIONALE:
--- 1. A Purge is one events_system row (action 'metrics_purge'): every importer
---    already admits that table, and _shared/data/db/purge_schema.sql applies it
---    in SQLite while any ledger replays, so a sibling device never brings a
---    purged row back (maintainer decision 2026-11-06).
--- 2. The tombstone's ts is local time with milliseconds, as macOS and Windows
---    stamp their rows; Linux stamps its rows in UTC, so the tombstone carries
---    its UTC instant too and the triggers compare a Linux row with that one.
--- 3. An Export is a VACUUM INTO copy (query export.vacuum_into) taken by the
---    owning writer once its flush settles, into the user's Downloads folder.
--- ==============================================================================

local M = {}





-- ============================
-- ============================
-- ======= 1/ Constants =======
-- ============================
-- ============================

--- The events_system action of a purge tombstone (purge_schema.sql).
M.TOMBSTONE_ACTION = "metrics_purge"

--- The two dashboard operations a writer accepts.
M.KINDS = { export = true, purge = true }

--- Prefix and extension of an Export copy.
M.EXPORT_PREFIX = "ergopti-metrics-"
M.EXPORT_EXTENSION = ".sqlite"





-- ===========================
-- ===========================
-- ======= 2/ Helpers ========
-- ===========================
-- ===========================

--- Builds the tombstone row of a purge taken at one wall-clock instant.
--- @param epoch number Seconds since the Unix epoch, fraction included.
--- @return table { ts, date, action, metadata = { utc } } for events_system.
function M.tombstone(epoch)
	assert(type(epoch) == "number" and epoch >= 0, "a purge tombstone needs a wall-clock instant")
	local seconds = math.floor(epoch)
	local millis = math.floor((epoch - seconds) * 1000)
	return {
		ts = os.date("%Y-%m-%d %H:%M:%S", seconds) .. string.format(".%03d", millis),
		date = os.date("%Y-%m-%d", seconds),
		action = M.TOMBSTONE_ACTION,
		metadata = { utc = os.date("!%Y-%m-%d %H:%M:%S", seconds) },
	}
end

--- Names the Export copy taken at one instant, in local time.
--- @param epoch number Seconds since the Unix epoch.
--- @return string file name
function M.export_file_name(epoch)
	assert(type(epoch) == "number" and epoch >= 0, "an export name needs a wall-clock instant")
	return M.EXPORT_PREFIX .. os.date("%Y-%m-%d_%H-%M-%S", math.floor(epoch)) .. M.EXPORT_EXTENSION
end

--- Resolves the folder an Export lands in: XDG_DOWNLOAD_DIR when the session
--- declares it, else the Downloads folder of the home directory.
--- @param getenv function Environment reader (os.getenv).
--- @return string|nil folder, string|nil reason
function M.downloads_dir(getenv)
	assert(type(getenv) == "function", "the Downloads folder needs an environment reader")
	local declared = getenv("XDG_DOWNLOAD_DIR")
	if type(declared) == "string" and declared ~= "" then return declared end
	local home = getenv("HOME")
	if type(home) ~= "string" or home == "" then return nil, "HOME is not set" end
	return home .. "/Downloads"
end

return M
