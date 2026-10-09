--- tests/support/fake_ngram_sqlite.lua

--- ==============================================================================
--- MODULE: Fake N-gram SQLite
--- DESCRIPTION:
--- Evaluates the exact statement shapes `sqlite_reader` issues against the
--- n-gram tables (grouped range reads, today's per-app slice, date bounds and
--- the past-data fingerprint) over in-memory rows, so paced and synchronous
--- projections can be compared without a native SQLite binding. Manifest
--- tables are present and empty.
--- ==============================================================================

local M = {}

--- Parses the WHERE clauses the reader emits.
local function parse_filter(sql)
	local filter = {}
	filter.lo = sql:match("date >= '([%d%-]+)'")
	filter.hi = sql:match("date <= '([%d%-]+)'")
	filter.eq = sql:match("date = '([%d%-]+)'")
	local apps = sql:match("app IN %(([^)]*)%)")
	if apps then
		filter.apps = {}
		for app in apps:gmatch("'([^']*)'") do filter.apps[app] = true end
	end
	return filter
end

local function admitted(row, filter)
	if filter.lo and row.date < filter.lo then return false end
	if filter.hi and row.date > filter.hi then return false end
	if filter.eq and row.date ~= filter.eq then return false end
	if filter.apps and not filter.apps[row.app] then return false end
	return true
end

--- Builds a fake `hs.sqlite3` over `tables` (name → array of rows).
--- @param tables table Rows: { date, app, token|keycode, c, td, e, esrc_json }.
--- @return table sqlite Fake module; `sqlite.statements` counts every query by table.
function M.new(tables)
	local sqlite = { OK = 0, statements = {} }

	local function count(tbl) sqlite.statements[tbl] = (sqlite.statements[tbl] or 0) + 1 end

	local function iterate(rows)
		local index = 0
		return function()
			index = index + 1
			return rows[index]
		end
	end

	local function query(sql)
		local bounded = sql:match("SELECT %(SELECT MIN%(date%) FROM ([%w_]+)%)")
		if bounded then
			local lo, hi = nil, nil
			for _, row in ipairs(tables[bounded] or {}) do
				if not lo or row.date < lo then lo = row.date end
				if not hi or row.date > hi then hi = row.date end
			end
			return { { lo = lo, hi = hi } }
		end
		local tbl = sql:match("FROM ([%w_]+)")
		count(tbl)
		local rows = tables[tbl] or {}
		local filter = parse_filter(sql)
		if sql:find("COUNT(*) AS n", 1, true) then
			local result = { n = 0 }
			local exprs = {}
			for expr, slot in sql:gmatch("TOTAL%((.-)%) AS s(%d+)") do exprs[#exprs + 1] = { expr, "s" .. slot } end
			for _, e in ipairs(exprs) do result[e[2]] = 0.0 end
			for _, row in ipairs(rows) do
				if admitted(row, filter) then
					result.n = result.n + 1
					for _, e in ipairs(exprs) do
						local column = e[1]:match("^length%((.+)%)$")
						local value = column and #tostring(row[column] or "") or (row[e[1]] or 0)
						result[e[2]] = result[e[2]] + value
					end
				end
			end
			return { result }
		end
		local by_app = sql:find("GROUP BY app,", 1, true) ~= nil
		local by_esrc = sql:find("esrc_json", 1, true) ~= nil
		local keyed_by_keycode = sql:find("GROUP BY keycode", 1, true) or sql:find("app, keycode", 1, true)
		local key_column = keyed_by_keycode and "keycode" or "token"
		local groups, order = {}, {}
		for _, row in ipairs(rows) do
			if admitted(row, filter) then
				local parts = { by_app and row.app or "", tostring(row[key_column]), by_esrc and row.esrc_json or "" }
				local key = table.concat(parts, "\1")
				local group = groups[key]
				if not group then
					group = { app = row.app, c = 0, t = 0, e = 0, source_rows = 0, esrc_json = row.esrc_json }
					group[key_column] = row[key_column]
					groups[key] = group
					order[#order + 1] = group
				end
				group.c = group.c + (row.c or 0)
				group.t = group.t + (row.td or 0)
				group.e = group.e + (row.e or 0)
				group.source_rows = group.source_rows + 1
			end
		end
		return order
	end

	function sqlite.open()
		local db = {}
		function db:exec() return 0 end
		function db:close() return 0 end
		function db:nrows(sql) return iterate(query(sql)) end
		return db
	end

	return sqlite
end

return M
