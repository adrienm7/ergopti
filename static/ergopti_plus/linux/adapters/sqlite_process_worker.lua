--- adapters/sqlite_process_worker.lua
--- ==============================================================================
--- MODULE: Parent-bound SQLite Launcher
--- DESCRIPTION:
--- Binds the directly owned child to the daemon before replacing itself with
--- SQLite. Exec preserves PID, process group and the private stdin pipe.
--- ==============================================================================

local M = {}

--- Replaces this directly owned LuaJIT child with the native SQLite CLI.
--- @param parent_pid string Exact daemon PID captured before dispatch.
--- @param database string Literal database path.
function M.run(parent_pid, database)
	local ffi = require("ffi")
	ffi.cdef([[
		int getppid(void);
		int prctl(int option, ...);
		int execvp(const char *file, char *const argv[]);
	]])
	local PR_SET_PDEATHSIG, SIGKILL = 1, 9
	local parent = tonumber(parent_pid)
	assert(parent and parent > 0 and parent % 1 == 0, "SQLite parent identity unavailable")
	assert(type(database) == "string" and database ~= "" and not database:find("\0", 1, true))
	assert(ffi.C.prctl(PR_SET_PDEATHSIG, ffi.cast("unsigned long", SIGKILL), 0, 0, 0) == 0,
		"SQLite parent lifetime binding failed")
	assert(tonumber(ffi.C.getppid()) == parent, "SQLite parent already exited")
	local values = { "sqlite3", "-init", "/dev/null", "-bail", "-noheader", database }
	local argv = ffi.new("char *[?]", #values + 1)
	for index, value in ipairs(values) do argv[index - 1] = ffi.cast("char *", value) end
	ffi.C.execvp(values[1], argv)
	error("SQLite process replacement refused")
end

-- Importing the launcher never binds or replaces its caller.
local invoked_source = debug.getinfo(1, "S").source:gsub("^@", "")
if type(arg) == "table" and arg[0] == invoked_source then M.run(arg[1], arg[2]) end

return M
