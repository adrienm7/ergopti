--- tests/unit/ui/test_text_prompt_exit_status.lua

--- ==============================================================================
--- MODULE: Native Text Prompt Exit Status
--- DESCRIPTION:
--- A private executable exercises the real prompt and checked shell owner in a
--- separate interpreter. Its exit status remains authoritative when LuaJIT
--- acknowledges closing a cancelled child's pipe as true.
--- ==============================================================================

local h = require("tests.helpers")
local Shell = h.load_module("adapters.shell_runner")

--- Writes one exclusively owned fixture file.
--- @param path string Absolute private path.
--- @param content string File contents.
local function write(path, content)
	local file = assert(io.open(path, "wb"))
	assert(file:write(content))
	assert(file:close())
end

--- Runs the public prompt with a real child executable and real exit status.
--- @param status number Native exit status.
--- @param output string Native stdout.
--- @return string Independent child receipt.
local function probe(status, output)
	local created, directory = Shell.exec_checked("mktemp -d")
	assert(created)
	directory = directory:gsub("[\r\n]+$", "")
	local executable = directory .. "/zenity"
	local worker = directory .. "/worker.lua"
	local ok, receipt = xpcall(function()
		write(executable, "#!/bin/sh\nprintf '%s' " .. Shell.quote(output) .. "\nexit " .. status .. "\n")
		assert(Shell.run("chmod u+x " .. Shell.quote(executable)))
		write(worker, "package.path = " .. string.format("%q", package.path) .. "\n"
			.. "package.loaded['logger.shim'] = { error = function() end, warn = function() end, debug = function() end }\n"
			.. "local modal_calls = 0\n"
			.. "package.loaded['ui.modal'] = { run = function(fn) modal_calls = modal_calls + 1; return fn() end }\n"
			.. "local value = require('ui.text_prompt').ask('Caption', 'Question', 'Initial')\n"
			.. "io.write(value == nil and 'cancelled' or 'accepted|' .. value)\n"
			.. "io.write('|modal:' .. modal_calls)\n")
		-- The executable is resolved only in this child. The parent interpreter's
		-- PATH, pipe methods and production shell owner remain untouched.
		local command = "env PATH=" .. Shell.quote(directory .. ":" .. (os.getenv("PATH") or ""))
			.. " " .. Shell.quote(arg[-1] or "luajit") .. " " .. Shell.quote(worker)
		local executed, result, reason = Shell.exec_checked(command)
		assert(executed, tostring(reason))
		return result
	end, debug.traceback)
	os.remove(executable)
	os.remove(worker)
	local removed = Shell.run("rmdir " .. Shell.quote(directory))
	assert(removed, "private prompt fixture must retire")
	assert(ok, receipt)
	return receipt
end

h.describe("native text prompt status", function()
	h.it("linux-prompt-cancel: real exit one returns cancellation", function()
		h.assert_eq(probe(1, ""), "cancelled|modal:1")
	end)
	h.it("linux-prompt-cancel: successful empty answer remains accepted", function()
		h.assert_eq(probe(0, ""), "accepted||modal:1")
	end)
	h.it("linux-prompt-cancel: successful text preserves spaces and trims line endings", function()
		h.assert_eq(probe(0, "  exact café  \r\n"), "accepted|  exact café  |modal:1")
	end)
	h.it("linux-prompt-cancel: other native failure never becomes an accepted value", function()
		h.assert_eq(probe(7, "untrusted output"), "cancelled|modal:1")
	end)
end)
