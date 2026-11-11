--- infra/field_check_raw_telemetry.lua

--- ==============================================================================
--- MODULE: Field Check, Raw Telemetry Rows
--- DESCRIPTION:
--- The field run's read of the raw telemetry tables the Metrics module fills
--- (TODO, To confirm on the Mac, « Raw telemetry »): how many events_window_topo,
--- events_av and events_network rows of each declared kind the keystats
--- database holds. Read once, it says the tables exist and fill; read before
--- and after a guided gesture (a window moved, Wi-Fi switched off and on), the
--- rise of one kind proves that gesture was recorded.
---
--- FEATURES & RATIONALE:
--- 1. One read-only, lock-free sqlite3 query (the storage check's immutable
---    URI): the ingest writes in rollback-journal mode and a reader's lock once
---    failed its COMMIT.
--- 2. The kinds come from the shared reducers (window_topology,
---    capture_presence, network_transitions), so a kind added there is counted
---    here with no second list; a kind with no row reports 0.
--- 3. Counts only: no application name, window geometry or adapter reaches the
---    report.
--- ==============================================================================

local Report = require("field_check_report")
local Probes = require("infra.field_check_probes")

local M = {}

local PASS, FAIL, INFO, SKIP = Report.STATE_PASS, Report.STATE_FAIL, Report.STATE_INFO, Report.STATE_SKIP

local SQLITE = "/usr/bin/sqlite3"
local SQLITE_TIMEOUT = 20

--- The tables read, each with its report prefix and its shared kind list.
--- @type table { { table, prefix, kinds } } in report order
M.TABLES = {
	{ table = "events_window_topo", prefix = "topo", kinds = require("keystats.window_topology").KINDS },
	{ table = "events_av", prefix = "av", kinds = require("keystats.capture_presence").KINDS },
	{ table = "events_network", prefix = "network", kinds = require("keystats.network_transitions").KINDS },
}

--- The query: one "prefix:kind|count" line per kind present.
--- @return string sql
function M.query()
	local parts = {}
	for _, entry in ipairs(M.TABLES) do
		parts[#parts + 1] = string.format("SELECT '%s:' || kind, COUNT(*) FROM %s GROUP BY kind",
			entry.prefix, entry.table)
	end
	return table.concat(parts, " UNION ALL ") .. ";"
end

--- The declared kinds of one table, sorted, so the report order is stable.
local function sorted_kinds(kinds)
	local names = {}
	for name in pairs(kinds) do names[#names + 1] = name end
	table.sort(names)
	return names
end

--- Reads the sqlite3 answer.
--- @param text any
--- @return table counts "prefix:kind" → count
function M.parse_counts(text)
	local counts = {}
	for line in tostring(text or ""):gmatch("[^\r\n]+") do
		local key, count = line:match("^([%a]+:[%w_]+)|(%d+)$")
		if key then counts[key] = tonumber(count) end
	end
	return counts
end

--- Runs the check.
--- ports.keystats_database(), exec.
--- @param ports table
--- @param report table field_check_report report.
--- @param finish function
function M.raw_telemetry(ports, report, finish)
	local database = ports.keystats_database()
	if database.path == nil or not database.present then
		-- Metrics off, or the keystats start has not resolved its database yet
		report.step("telemetry_db", SKIP, database.path == nil and "metrics_not_started" or "absent")
		return finish()
	end
	ports.exec(SQLITE, { "-readonly", Probes.immutable_uri(database.path), M.query() }, SQLITE_TIMEOUT,
		function(code, output)
			if code ~= 0 then
				report.step("telemetry_db", FAIL, code == nil and "timeout" or ("sqlite_exit_" .. tostring(code)))
				return finish()
			end
			report.step("telemetry_db", PASS, "read")
			local counts = M.parse_counts(output)
			for _, entry in ipairs(M.TABLES) do
				for _, kind in ipairs(sorted_kinds(entry.kinds)) do
					report.step(entry.prefix .. "_" .. kind, INFO, counts[entry.prefix .. ":" .. kind] or 0)
				end
			end
			finish()
		end)
end

return M
