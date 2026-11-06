--- adapters/sqlite_process_worker.lua
-- The application-owned child is invoked directly, without a global Lua init.
local literal_driver = os.getenv("ERGOPTI_LITERAL_DRIVER_ROOT")
if literal_driver and literal_driver ~= "" then
	local literal_shared = assert(os.getenv("ERGOPTI_LITERAL_SHARED_ROOT"), "literal shared root unavailable")
	assert(loadfile(literal_driver .. "/infra/literal_module_loader.lua"))().install(literal_driver, literal_shared, os.getenv("ERGOPTI_RUNTIME_PREFIX"), os.getenv("ERGOPTI_LITERAL_DIRECT") == "1" and "child-direct" or (os.getenv("ERGOPTI_LITERAL_DAEMON") == "1" and "daemon" or nil))
end

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
		unsigned int umask(unsigned int mask);
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
	local source = debug.getinfo(1, "S").source:gsub("^@", "")
	local root = assert(source:match("^(.*)/adapters/sqlite_process_worker%.lua$"), "SQLite worker source unavailable")
	if literal_driver then
		assert(package.loaded["infra.literal_module_loader"]).prepend({ { root, ".lua" } })
	else
		package.path = root .. "/?.lua;" .. package.path
	end
	local private = require("infra.private_sqlite_file")
	assert(private.admit(database), "SQLite private file admission refused")
	-- SQLite creates rollback journals and WAL/SHM after replacing this process.
	ffi.C.umask(private.creation_mask)
	-- The private runtime's sqlite3 by absolute path; execvp searches PATH only
	-- for a source run, which has no prefix (infra/owned_programs.lua).
	local values = { require("infra.owned_programs").resolve("sqlite3"), "-init", "/dev/null", "-bail", "-noheader", database }
	local argv = ffi.new("char *[?]", #values + 1)
	for index, value in ipairs(values) do argv[index - 1] = ffi.cast("char *", value) end
	ffi.C.execvp(values[1], argv)
	error("SQLite process replacement refused")
end

-- Importing the launcher never binds or replaces its caller.
local invoked_source = debug.getinfo(1, "S").source:gsub("^@", "")
if type(arg) == "table" and arg[0] == invoked_source then M.run(arg[1], arg[2]) end

return M
