--- adapters/atspi_context_worker.lua

--- Captures one native field/frame/application observation in an owned child.
--- The parent owns the only deadline and process group; no nested timeout exists.
local M = {}

--- Runs one private native observation only in the directly owned CLI child.
--- @param bus string Native field bus.
--- @param path string Native field path.
--- @param role string Native field role.
--- @param shared string Canonical shared Lua source directory.
--- @param parent_pid string Exact native daemon process.
--- @return boolean completed
function M.run(bus, path, role, shared, parent_pid)
	local source = debug.getinfo(1, "S").source:gsub("^@", "")
	local root = assert(source:match("^(.*)/adapters/atspi_context_worker%.lua$"), "context worker source unavailable")
	assert(type(shared) == "string" and shared:sub(1, 1) == "/", "context worker shared source unavailable")
	package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. shared .. "/?.lua;" .. shared .. "/?/init.lua;" .. package.path
	require("logger.shim").set_level("error")
	local ffi = require("ffi")
	ffi.cdef([[int getppid(void); int prctl(int option, ...);]])
	parent_pid = tonumber(parent_pid)
	local PR_SET_PDEATHSIG, SIGKILL = 1, 9
	-- Bind before native RPCs, then close the race where the original parent died.
	assert(parent_pid and parent_pid > 0 and parent_pid % 1 == 0, "context worker parent unavailable")
	assert(ffi.C.prctl(PR_SET_PDEATHSIG, ffi.cast("unsigned long", SIGKILL), 0, 0, 0) == 0, "parent lifetime binding failed")
	assert(tonumber(ffi.C.getppid()) == parent_pid, "context worker parent already exited")
	local Json = require("json")
	local field = { bus = bus, path = path, role = tonumber(role) }
	local ok, context = pcall(function()
		local snapshot, conclusive = require("adapters.atspi_focus")._get_native_context_snapshot()
		if conclusive ~= true then return nil end
		return require("adapters.window_info")._privacy_context_from_snapshot(field, snapshot)
	end)
	if not ok or not context then os.exit(2) end
	io.write("CONTEXT:" .. Json.encode({ field = field, context = context }))
	return true
end

-- Requiring the adapter must not run a CLI job or change native ownership.
local invoked_source = debug.getinfo(1, "S").source:gsub("^@", "")
if type(arg) == "table" and arg[0] == invoked_source then M.run(arg[1], arg[2], arg[3], arg[4], arg[5]) end

return M
