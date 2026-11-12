--- tests/support/notify_send_guard.lua

--- ==============================================================================
--- MODULE: notify-send Spawn Guard (Linux tests)
--- DESCRIPTION:
--- The notifier starts notify-send through ShellRunner.run_async (NUI-003), so
--- a fixture that forgets the shell seams (_set_runner, _set_async_runner) would
--- show real desktop notifications from the test run. Every test process puts a
--- sentinel notify-send first on PATH: it records the running test case and its
--- arguments and exits 97, so no test can reach the real program, and
--- tests/run.lua fails the run and names each case whose notice reached it.
--- Only LuaJIT can change the environment children inherit (FFI setenv); plain
--- Lua has no luv either, so run_async refuses there and nothing is spawned.
--- ==============================================================================

local M = {}

-- The FFI module once install() has put the sentinel in place; nil otherwise.
local _ffi = nil

-- The exit status the sentinel answers, so a test that reaches it sees a failure.
M.EXIT_STATUS = 97

-- Lets the guard's own test aim one sentinel run at a file of its choosing.
M.LOG_VARIABLE = "ERGOPTI_NOTIFY_SEND_GUARD_LOG"

-- Names the running test case; a child inherits it, so a hit names its test.
M.CASE_VARIABLE = "ERGOPTI_NOTIFY_SEND_GUARD_CASE"

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
	-- test.runner_home may already have declared setenv in this process. A
	-- child that inherited the sentinel's PATH still names its own cases.
	pcall(ffi.cdef, "int setenv(const char *name, const char *value, int overwrite);")
	_ffi = ffi
	local path = os.getenv("PATH") or ""
	if path:sub(1, #dir + 1) == dir .. ":" then return true end
	if not os.execute("mkdir -p " .. shell_quote(dir)) then error("the notify-send guard could not create " .. dir, 2) end
	local script = assert(io.open(dir .. "/notify-send", "wb"))
	assert(script:write("#!/bin/sh\n",
		"printf '%s\\t%s\\n' \"${", M.CASE_VARIABLE, ":-outside any test case}\" \"$*\" >> \"${", M.LOG_VARIABLE, ":-", dir, "/spawned}\"\n",
		"exit ", tostring(M.EXIT_STATUS), "\n"))
	assert(script:close())
	if not os.execute("chmod +x " .. shell_quote(dir .. "/notify-send")) then
		error("the notify-send guard could not make its sentinel executable", 2)
	end
	if ffi.C.setenv("PATH", dir .. ":" .. path, 1) ~= 0 then error("the notify-send guard could not export PATH", 2) end
	return true
end

--- Names the test case about to run, so a notice that reaches the sentinel
--- names its test. A no-op where install() could not place the sentinel.
--- @param label string Module and case name.
function M.enter_case(label)
	if not _ffi then return end
	if _ffi.C.setenv(M.CASE_VARIABLE, label, 1) ~= 0 then error("the notify-send guard could not name the test case", 2) end
end

--- What the sentinel recorded: one line per real spawn, the test case that
--- started it, a tab, then its arguments.
--- @param path string|nil The record to read; the run's own by default.
--- @return string|nil spawned nil when no test started notify-send.
function M.spawned(path)
	if path == nil then
		local dir = M.dir()
		if not dir then return nil end
		path = dir .. "/spawned"
	end
	local file = io.open(path, "rb")
	if not file then return nil end
	local text = file:read("*a")
	file:close()
	if text == nil or text == "" then return nil end
	return text
end

--- The test cases whose notices reached the sentinel, in first-hit order.
--- @param path string|nil The record to read; the run's own by default.
--- @return table offenders { { case = string, count = integer }, ... }
function M.offenders(path)
	local text = M.spawned(path)
	local offenders, by_case = {}, {}
	if not text then return offenders end
	for line in text:gmatch("[^\n]+") do
		local case = line:match("^([^\t]*)\t") or line
		local entry = by_case[case]
		if not entry then
			entry = { case = case, count = 0 }
			by_case[case] = entry
			offenders[#offenders + 1] = entry
		end
		entry.count = entry.count + 1
	end
	return offenders
end

--- Writes the run's verdict: each case whose notice reached the sentinel
--- instead of a notifier seam (tests/support/notice_recorder.lua).
--- @param write function Receives each line of the report.
--- @param path string|nil The record to read; the run's own by default.
--- @return boolean failed Whether any notice reached the sentinel.
function M.report(write, path)
	local offenders = M.offenders(path)
	if #offenders == 0 then return false end
	write("notices reached the notify-send sentinel instead of a notifier seam (tests/support/notice_recorder.lua):\n")
	for _, offender in ipairs(offenders) do
		write(string.format("  - %s (%d notice(s))\n", offender.case, offender.count))
	end
	return true
end

return M
