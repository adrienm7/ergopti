--- tests/support/keystats/rebuild_sqlite_bridge.lua

--- ==============================================================================
--- MODULE: Rebuild SQLite Bridge
--- DESCRIPTION:
--- Maps the subset of Hammerspoon SQLite used by the rebuild to a Python
--- SQLite connection owner. Backup page stepping is a controlled model; SQL,
--- transactions and schema images are executed by real SQLite in the parent.
--- ==============================================================================

local M = {}

--- @param request function JSON request/response boundary.
--- @return table sqlite Simulated lsqlite3 capability over real SQLite.
function M.new(request)
	local sqlite = { OK = 0, ERROR = 1, BUSY = 5, LOCKED = 6, DONE = 101 }
	local function call(operation, fields)
		fields = fields or {}
		fields.op = operation
		local result = request(fields)
		return result.ok and result.value or nil, result.error
	end
	function sqlite.open(path)
		local id = call("open", { path = path })
		if id == nil then return nil end
		local db, detail, closed = { _bridge_id = id }, "", false
		local function check() if closed then error("attempt to use closed sqlite database") end end
		function db:exec(sql)
			check()
			local value, err = call("exec", { connection = id, sql = sql })
			detail = err or ""
			return value or sqlite.ERROR
		end
		function db:errmsg() return detail end
		function db:nrows(sql)
			check()
			local rows, err = call("rows", { connection = id, sql = sql })
			if not rows then error(err or "query failed") end
			local index = 0
			return function() index = index + 1; return rows[index] end
		end
		function db:close()
			check()
			closed = true
			local value, err = call("close", { connection = id })
			detail = err or ""
			return value or sqlite.ERROR
		end
		return db
	end
	function sqlite.backup_init(target, target_name, source, source_name)
		local id = call("backup_init", { target = target._bridge_id, target_name = target_name,
			source = source._bridge_id, source_name = source_name })
		if id == nil then return nil end
		local backup = { _bridge_id = id }
		local closed = false
		function backup:step(pages)
			if closed then error("attempt to use closed sqlite database backup") end
			local value = call("backup_step", { backup = id, pages = pages })
			return value or sqlite.ERROR
		end
		function backup:finish()
			if closed then error("attempt to use closed sqlite database backup") end
			closed = true
			local value = call("backup_finish", { backup = id })
			return value or sqlite.ERROR
		end
		return backup
	end
	return sqlite
end

return M
