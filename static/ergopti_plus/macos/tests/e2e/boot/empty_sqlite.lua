--- tests/e2e/boot/empty_sqlite.lua

--- Empty SQLite model for headless boot. It exposes the native backup and
--- revision protocol; raw data/transaction correctness is covered separately
--- by the real SQLite rebuild tests.
local M = {}

function M.install(hs, shared)
	local sqlite = hs.sqlite3
	local definitions = {}
	for _, name in ipairs({ "schema.sql", "media_schema.sql" }) do
		local file = assert(io.open(shared .. "/metrics/data/db/" .. name, "rb"))
		local source = assert(file:read("*a")); assert(file:close())
		for table_name, columns in source:gmatch("CREATE TABLE IF NOT EXISTS%s+([%w_]+)%s*(%b())%s*;") do
			definitions[table_name] = "CREATE TABLE " .. table_name .. " " .. columns
		end
	end
	local original_open = sqlite.open
	sqlite.open = function(path, flags)
		local db, err = original_open(path, flags)
		if not db then return nil, err end
		local original_exec, original_rows = db.exec, db.nrows
		local changes, revision, live = 0, "0", true
		function db:exec(sql)
			assert(live, "closed boot SQLite handle")
			local rc = original_exec(self, sql)
			if rc == sqlite.OK then
				local upper = sql:upper()
				if upper:find("INSERT", 1, true) or upper:find("UPDATE", 1, true) or upper:find("DELETE", 1, true) then
					changes = changes + 1
				end
				local value = sql:match("UPDATE meta SET value='([^']*)' WHERE key='aggregate_cache_revision'")
				if value then revision = value end
			end
			return rc
		end
		function db:nrows(sql)
			assert(live, "closed boot SQLite handle")
			local row
			if sql:match("^PRAGMA data_version") then row = { data_version = 1 }
			elseif sql:match("^PRAGMA foreign_keys") then row = { foreign_keys = 0 }
			elseif sql:find("SELECT total_changes() AS n", 1, true) then row = { n = changes }
			elseif sql:find("main.sqlite_master", 1, true) then
				local name = sql:match("name='([%w_]+)'")
				if definitions[name] then row = { sql = definitions[name] } end
			elseif sql:find("SELECT value FROM meta WHERE key='aggregate_cache_revision'", 1, true) then
				row = { value = revision }
			else return original_rows(self, sql) end
			return function() local current = row; row = nil; return current end
		end
		local original_close = db.close
		function db:close() live = false; return original_close(self) end
		db._boot_alive = function() return live end
		return db, err
	end
	sqlite.backup_init = function(target, _, source, _)
		assert(target ~= source and target._boot_alive() and source._boot_alive(), "invalid boot backup owners")
		local live = true
		return {
			step = function() assert(live, "closed boot backup"); return sqlite.DONE end,
			finish = function() assert(live, "closed boot backup"); live = false; return sqlite.OK end,
		}
	end
end

return M
