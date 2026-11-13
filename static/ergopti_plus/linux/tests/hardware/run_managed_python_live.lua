--- tests/hardware/run_managed_python_live.lua

--- ==============================================================================
--- MODULE: Ergopti's Own Python, Downloaded For Real
--- DESCRIPTION:
--- Drives the production managed Python of the layout registry (the managed
--- HTTP download, the file digest, GNU or BusyBox tar, the publication by
--- rename) against the real python-build-standalone release, in a private
--- XDG data folder, with the consent answered yes. The published interpreter
--- must then run and report the pinned version; a second request must answer
--- from the installed folder without downloading again.
---
--- Needs the network. Exit 0 = installed, ran and reused. 1 = a step failed.
--- ==============================================================================

local uv = require("luv")

local data_home = assert(os.getenv("XDG_DATA_HOME"), "run with a private XDG_DATA_HOME")
assert(data_home:match("^/tmp/") or data_home:match("^/var/tmp/"), "XDG_DATA_HOME must be a scratch folder")
local Registry = require("layouts.engine.registry.registry")
local Pins = require("_generated.native_runtime").managed_python

--- Runs the loop until the request settles or its deadline passes.
--- @param start function start(callback)
--- @return boolean ok, string value, string|nil detail
local function settle(start)
	local outcome
	start(function(ok, value, detail) outcome = { ok, value, detail } end)
	local deadline = uv.hrtime() + 900 * 1e9
	while not outcome and uv.hrtime() < deadline do uv.run("once") end
	assert(outcome, "the managed Python request never settled")
	return outcome[1], outcome[2], outcome[3]
end

local asked = 0
local python = Registry._managed_python_for_probe(function(bytes)
	asked = asked + 1
	print(string.format("consent asked for %d bytes", bytes))
	return true
end)

local ok, interpreter, detail = settle(python)
assert(ok, "managed Python refused: " .. tostring(interpreter) .. " " .. tostring(detail))
print("installed: " .. interpreter)
assert(interpreter:sub(1, #data_home + 1) == data_home .. "/", "the interpreter lives in the private data folder")
local probe = io.popen("'" .. interpreter .. "' -c 'import sys; print(\"%d.%d.%d\" % sys.version_info[:3])'")
local version = probe:read("*l")
probe:close()
assert(version == Pins.version, "the published interpreter reports " .. tostring(version))
print("runs: Python " .. version)
assert(asked == 1, "one consent for one download")

local again_ok, again = settle(python)
assert(again_ok and again == interpreter, "the second request must reuse the installed interpreter")
assert(asked == 1, "an installed interpreter asks nothing")
print("MANAGED_PYTHON_LIVE_OK")
