--- tests/support/notify_send_guard.lua

--- ==============================================================================
--- MODULE: notify-send Spawn Guard (Linux tests)
--- DESCRIPTION:
--- The notifier starts notify-send through ShellRunner.run_async (NUI-003), so
--- a fixture that forgets the shell seams (_set_runner, _set_async_runner) would
--- show real desktop notifications from the test run. Every test process puts a
--- sentinel notify-send first on PATH: it records its arguments and exits 97,
--- so no test can reach the real program, and tests/run.lua reports how many
--- notices reached the sentinel.
--- Only LuaJIT can change the environment children inherit (FFI setenv); plain
--- Lua has no luv either, so run_async refuses there and nothing is spawned.
--- ==============================================================================

local M = {}

-- The exit status the sentinel answers, so a test that reaches it sees a failure.
M.EXIT_STATUS = 97

-- Lets the guard's own test aim one sentinel run at a file of its choosing.
M.LOG_VARIABLE = "ERGOPTI_NOTIFY_SEND_GUARD_LOG"

--- The sentinel's directory under the isolated test home.
--- @return string|nil dir
function M.dir()
	local home = os.getenv("HOME")
	if type(home) ~= "string" or home == "" then return nil end
	return home .. "/.ergopti-notify-send-guard"
end

local function shell_quote(text) return "'" .. text:gsub("'", "'\\''") .. "'" end

--- Installs the sentinel first on PATH. Idempotent while it is in place: a test
--- that reloads tests/helpers in the same process installs it again.
--- @return boolean installed Whether children now resolve notify-send to it.
function M.install()
	if type(jit) ~= "table" then return false end
	local loaded, ffi = pcall(require, "ffi")
	if not loaded then return false end
	local dir = M.dir()
	if not dir then error("the notify-send guard needs the isolated test home", 2) end
	local path = os.getenv("PATH") or ""
	if path:sub(1, #dir + 1) == dir .. ":" then return true end
	if not os.execute("mkdir -p " .. shell_quote(dir)) then error("the notify-send guard could not create " .. dir, 2) end
	local script = assert(io.open(dir .. "/notify-send", "wb"))
	assert(script:write("#!/bin/sh\n",
		"printf '%s\\n' \"$*\" >> \"${", M.LOG_VARIABLE, ":-", dir, "/spawned}\"\n",
		"exit ", tostring(M.EXIT_STATUS), "\n"))
	assert(script:close())
	if not os.execute("chmod +x " .. shell_quote(dir .. "/notify-send")) then
		error("the notify-send guard could not make its sentinel executable", 2)
	end
	-- test.runner_home may already have declared setenv in this process.
	pcall(ffi.cdef, "int setenv(const char *name, const char *value, int overwrite);")
	if ffi.C.setenv("PATH", dir .. ":" .. path, 1) ~= 0 then error("the notify-send guard could not export PATH", 2) end
	return true
end

--- What the sentinel recorded: one line of arguments per real spawn.
--- @return string|nil spawned nil when no test started notify-send.
function M.spawned()
	local dir = M.dir()
	if not dir then return nil end
	local file = io.open(dir .. "/spawned", "rb")
	if not file then return nil end
	local text = file:read("*a")
	file:close()
	if text == nil or text == "" then return nil end
	return text
end

return M
