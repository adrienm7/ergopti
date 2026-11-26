--- tests/meta/harness/test_dialog_host_guard.lua

--- ==============================================================================
--- MODULE: Dialog Host Guard
--- DESCRIPTION:
--- Proves that no test can open a real dialog: the runner exports the dialog
--- host's guard to every child, the real host started under it records the
--- request with its test case and exits before any window, and the runner's
--- report names each case whose dialog reached it. It fails when the guard is
--- not exported, when the host would bind GTK under it, or when a hit would not
--- be reported.
--- ==============================================================================

local helpers = require("tests.helpers")
local Guard = require("tests.support.dialog_host_guard")
local Host = require("core.ui.ui.dialog_host")
local NativeDialog = require("core.ui.ui.native_dialog")
local quote = require("core.text.engine.utils_core").shell_quote

--- Reads a whole file, nil when it is absent.
--- @param path string
--- @return string|nil
local function read(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local text = file:read("*a")
	file:close()
	return text
end

--- Starts the real host as production does, with the guard aimed at `record`.
--- @param record string The record the child writes.
--- @param arguments string The host's arguments, already quoted.
--- @return number|nil code The host's exit code.
local function run_host(record, arguments)
	local command = Host.GUARD_VARIABLE .. "=" .. quote(record) .. " " .. Host.GUARD_CASE_VARIABLE .. "="
		.. quote("guard probe case") .. " " .. NativeDialog.command() .. " " .. arguments .. " 2>/dev/null"
	return NativeDialog.exit_code(os.execute(command))
end

helpers.describe("dialog host guard (test-dialog-host-guard)", function()
	helpers.it("exports the guard to every child of the run", function()
		helpers.assert_true(Guard.install(), "this interpreter can export the guard (LuaJIT FFI or luv)")
		local record = assert(Guard.record())
		helpers.assert_eq(os.getenv(Host.GUARD_VARIABLE), record)
		local pipe = assert(io.popen("printf '%s' \"$" .. Host.GUARD_VARIABLE .. "\""))
		local seen = pipe:read("*a")
		pipe:close()
		helpers.assert_eq(seen, record, "a child process inherits the guard")
	end)

	helpers.it("makes the real host record a dialog and exit before any window", function()
		local record = os.tmpname()
		os.remove(record)
		local code = run_host(record, "--error --title=" .. quote("Guard probe") .. " --text=" .. quote("body"))
		local recorded = read(record)
		os.remove(record)
		helpers.assert_eq(code, Host.EXIT_UNAVAILABLE, "the guarded host answers as a host with no display")
		helpers.assert_eq(recorded, "guard probe case\t--error Guard probe\n", "the request is recorded with its case")
		helpers.assert_eq(#Guard.offenders(), 0, "the probe wrote to its own record, not the run's")
	end)

	helpers.it("keeps refusing malformed arguments as the unguarded host does", function()
		local record = os.tmpname()
		os.remove(record)
		local code = run_host(record, "--bogus")
		local recorded = read(record)
		os.remove(record)
		helpers.assert_eq(code, Host.EXIT_USAGE)
		helpers.assert_nil(recorded, "a refused command line shows nothing, so nothing is recorded")
	end)

	helpers.it("reports each case whose dialog reached the host, and nothing for a clean run", function()
		local record = os.tmpname()
		local file = assert(io.open(record, "wb"))
		assert(file:write("mod :: first\t--error A\nmod :: first\t--info B\nmod :: second\t--question C\n"))
		assert(file:close())
		local lines = {}
		helpers.assert_true(Guard.report(function(line) lines[#lines + 1] = line end, record))
		os.remove(record)
		helpers.assert_eq(#lines, 3)
		helpers.assert_contains(lines[2], "mod :: first (2 dialog(s), first: --error A)")
		helpers.assert_contains(lines[3], "mod :: second (1 dialog(s), first: --question C)")
		helpers.assert_eq(Guard.report(function() error("a clean run reports nothing", 0) end, record), false)
	end)
end)

return true
