--- tests/support/dialog_host_guard.lua

--- ==============================================================================
--- MODULE: Dialog Host Guard (Linux tests)
--- DESCRIPTION:
--- Every native dialog is Ergopti's own GTK host (core/ui/ui/dialog_host.lua),
--- started as a child that blocks until the user answers. A fixture that forgets
--- to stub it opens a real modal window on any desktop with a display, and the
--- run then waits for a click: one forgotten stub held a unit run for sixteen
--- minutes. Every test process therefore exports the host's guard variable, so a
--- host started from a test records its case and request and exits without a
--- window, and tests/run.lua fails the run and names each case that reached it.
--- The variable is exported through the LuaJIT FFI or, under plain Lua, luv's
--- os_setenv; without either, plain Lua has no luv and cannot start the host.
--- ==============================================================================

local M = {}

local Host = require("core.ui.ui.dialog_host")

-- The setter that exports a variable to every child, once install() found one.
local _setenv = nil

--- The record of the run under the isolated test home.
--- @return string|nil path
function M.record()
	local home = os.getenv("HOME")
	if type(home) ~= "string" or home == "" then return nil end
	return home .. "/.ergopti-dialog-host-guard"
end

--- Finds a way to export a variable to every child process.
--- @return function|nil setenv (name, value) -> boolean
local function find_setenv()
	if type(jit) == "table" then
		local loaded, ffi = pcall(require, "ffi")
		if loaded then
			-- Other test support may already have declared it in this process.
			pcall(ffi.cdef, "int setenv(const char *name, const char *value, int overwrite);")
			return function(name, value) return ffi.C.setenv(name, value, 1) == 0 end
		end
	end
	local loaded, luv = pcall(require, "luv")
	if loaded and type(luv) == "table" and type(luv.os_setenv) == "function" then
		return function(name, value) return luv.os_setenv(name, value) == true end
	end
	return nil
end

--- Exports the guard to every child. Idempotent: a test that reloads
--- tests/helpers in the same process installs it again.
--- @return boolean installed Whether children now start the host guarded.
function M.install()
	local record = M.record()
	if not record then error("the dialog host guard needs the isolated test home", 2) end
	_setenv = _setenv or find_setenv()
	if not _setenv then return false end
	if os.getenv(Host.GUARD_VARIABLE) == record then return true end
	-- The first install of a run starts its record; a child test process
	-- inherits the variable and appends to the same one.
	os.remove(record)
	if not _setenv(Host.GUARD_VARIABLE, record) then error("the dialog host guard could not export its record", 2) end
	return true
end

--- Names the test case about to run, so a dialog that reaches the host names
--- its test. A no-op where install() could not export the guard.
--- @param label string Module and case name.
function M.enter_case(label)
	if not _setenv then return end
	if not _setenv(Host.GUARD_CASE_VARIABLE, label) then error("the dialog host guard could not name the test case", 2) end
end

--- The test cases whose dialogs reached the host, in first-hit order.
--- @param path string|nil The record to read; the run's own by default.
--- @return table offenders { { case = string, count = integer, request = string }, ... }
function M.offenders(path)
	path = path or M.record()
	local offenders, by_case = {}, {}
	local file = path and io.open(path, "rb")
	if not file then return offenders end
	local text = file:read("*a") or ""
	file:close()
	for line in text:gmatch("[^\n]+") do
		local case, request = line:match("^([^\t]*)\t(.*)$")
		case = case or line
		local entry = by_case[case]
		if not entry then
			entry = { case = case, count = 0, request = request or "" }
			by_case[case] = entry
			offenders[#offenders + 1] = entry
		end
		entry.count = entry.count + 1
	end
	return offenders
end

--- Writes the run's verdict: each case whose dialog reached the real host
--- instead of a stubbed os.execute or io.popen.
--- @param write function Receives each line of the report.
--- @param path string|nil The record to read; the run's own by default.
--- @return boolean failed Whether any dialog reached the host.
function M.report(write, path)
	local offenders = M.offenders(path)
	if #offenders == 0 then return false end
	write("dialogs reached the real dialog host instead of a stub (tests/support/dialog_host_guard.lua):\n")
	for _, offender in ipairs(offenders) do
		write(string.format("  - %s (%d dialog(s), first: %s)\n", offender.case, offender.count, offender.request))
	end
	return true
end

return M
