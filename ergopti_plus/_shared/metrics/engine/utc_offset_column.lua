--- _shared/metrics/engine/utc_offset_column.lua

--- ==============================================================================
--- MODULE: Raw Rows' UTC Offset Column — Store Migration
--- DESCRIPTION:
--- Every raw events_* table carries utc_offset_min, the local UTC offset in
--- force when its row was recorded (maintainer decision KMD-1 of 11 November
--- 2026, _shared/metrics/data/db/schema.sql). A fresh store gets it from schema.sql; a
--- store created before has the tables without it, which CREATE TABLE IF NOT
--- EXISTS leaves alone, so each driver adds it on open with these statements.
--- The column comes last in both shapes, so a migrated table and a fresh one
--- list the same columns in the same order.
--- ==============================================================================

local M = {}

M.COLUMN = "utc_offset_min"

-- The column's definition, as schema.sql spells it, bounded by the widest
-- offset the host clock can report (local_time.MAX_OFFSET_MIN)
local MAX_OFFSET_MIN = require("metrics.engine.local_time").MAX_OFFSET_MIN
M.DEFINITION = "INTEGER CHECK (utc_offset_min IS NULL OR (typeof(utc_offset_min) = 'integer'"
	.. " AND utc_offset_min BETWEEN -" .. MAX_OFFSET_MIN .. " AND " .. MAX_OFFSET_MIN .. "))"

-- Every raw table of schema.sql, in its order
M.TABLES = {
	"events_typing", "events_app_switch", "events_window_switch", "events_shortcut", "events_system",
	"events_hotstring", "events_llm", "events_session", "events_mouse", "events_ergo", "events_window_topo",
	"events_av", "events_network", "events_clipboard", "events_roi",
}

--- The query that names the raw tables still without the column, one per line.
--- @return string sql
function M.missing_query()
	local quoted = {}
	for index, name in ipairs(M.TABLES) do quoted[index] = "'" .. name .. "'" end
	return "SELECT m.name FROM sqlite_master m WHERE m.type = 'table' AND m.name IN ("
		.. table.concat(quoted, ",") .. ") AND NOT EXISTS (SELECT 1 FROM pragma_table_info(m.name) p WHERE p.name = '"
		.. M.COLUMN .. "') ORDER BY m.name;"
end

--- The purge triggers of _shared/metrics/data/db/purge_schema.sql, which read the column:
--- a store created before keeps its older triggers (CREATE TRIGGER IF NOT
--- EXISTS), so the migration drops them and purge_schema.sql, run after it on
--- the same open, creates the current ones.
--- @return table names
function M.purge_triggers()
	local names = { "metrics_purge_apply" }
	for _, table_name in ipairs(M.TABLES) do
		names[#names + 1] = "metrics_purge_guard_" .. table_name:gsub("^events_", "")
	end
	return names
end

--- The statements that add the column to the named tables, then retire the
--- purge triggers written before it; none when no table lacks it.
--- @param missing table Table names from missing_query().
--- @return table statements In order; run before purge_schema.sql.
function M.statements(missing)
	assert(type(missing) == "table", "the tables without the offset column are a list")
	local known = {}
	for _, name in ipairs(M.TABLES) do known[name] = true end
	local statements = {}
	for _, name in ipairs(missing) do
		assert(known[name], "not a raw metrics table: " .. tostring(name))
		statements[#statements + 1] = "ALTER TABLE " .. name .. " ADD COLUMN " .. M.COLUMN .. " " .. M.DEFINITION .. ";"
	end
	if #statements == 0 then return statements end
	for _, trigger in ipairs(M.purge_triggers()) do
		statements[#statements + 1] = "DROP TRIGGER IF EXISTS " .. trigger .. ";"
	end
	return statements
end

return M
