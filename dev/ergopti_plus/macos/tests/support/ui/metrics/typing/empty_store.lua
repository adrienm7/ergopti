--- tests/support/ui/metrics/typing/empty_store.lua

--- ==============================================================================
--- MODULE: Typing Metrics Empty Store
--- DESCRIPTION:
--- Gives a typing dashboard scenario a present db.sqlite that holds no rows,
--- read completely. A missing store is an incomplete read (MET-11), so a
--- scenario that needs a complete publication without SQLite rows installs
--- this one instead of answering no path.
--- ==============================================================================

local M = {}

M.PATH = "/fixture/empty-db.sqlite"

--- Installs the store into the current stub scope (hs.fs, the log manager and
--- the reader are restored by the scope that owns them).
--- @param on_path function|nil Called each time the dashboard asks for the path.
function M.install(on_path)
	package.loaded["modules.keystats.log_manager"].get_sqlite_path = function()
		if on_path then on_path() end
		return M.PATH
	end
	local fs = package.loaded["hs.fs"]
	local attributes = fs.attributes
	fs.attributes = function(path, ...)
		if path == M.PATH then return { mode = "file" } end
		if attributes then return attributes(path, ...) end
		return nil
	end
	package.loaded["modules.keystats.sqlite_reader"] = {
		split_bounds = function(_, _, today) return { historical_end = today } end,
		read_manifest = function() return {}, true end,
		read_ngrams = function() return {}, true end,
		read_today_split = function() return {}, true end,
		merge_ngrams = function(into) return into end,
		next_day = function(day) return day end,
	}
end

return M
