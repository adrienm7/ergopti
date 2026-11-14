--- tests/support/notice_recorder.lua

--- ==============================================================================
--- MODULE: Recording Notifier (Linux tests)
--- DESCRIPTION:
--- Every test case resolves require("adapters.notifier") to a recording
--- notifier: the real adapter, loaded once against a shell double that records
--- the notify-send argv instead of spawning it. Production code reaches the
--- notifier through a call-time require, so a fixture that never stubs it still
--- goes through this seam rather than the notify-send sentinel
--- (tests/support/notify_send_guard.lua), whose hits fail the run.
---
--- FEATURES & RATIONALE:
--- 1. The real adapter, not a hand-written double: titles, levels, the "--"
---    boundary and owned admission behave exactly as in production, so a test
---    that asserts on a recorded notice asserts on what would be shown.
--- 2. Built once, before any fixture can replace infra.timings or the logger,
---    and without leaving its Lua dependencies in package.loaded, so the cache a
---    test module sees is the one it saw before the recorder existed.
--- 3. Installed per case and put back after it only while it is still in
---    place: a fixture that installs its own notifier keeps ownership of it,
---    across cases too, and may restore the recorder it found.
--- ==============================================================================

local M = {}

local NOTIFIER = "adapters.notifier"
local SHELL = "core.process.adapters.shell_runner"

-- The recording notifier, built by install().
local _notifier = nil

-- What the current case sent, in order.
local _notices = {}

-- What package.loaded holds for the notifier outside the cases: the last value
-- a case found that was neither the recorder nor a fixture's double.
local _baseline = nil

--- The shell double the recording notifier is bound to: notify-send is always
--- present, and each run is recorded and reported as a success.
--- @return table shell
local function recording_shell()
	return {
		has_command = function(name) return name == "notify-send" end,
		run = function() error("the notifier must not run notify-send through a shell line", 2) end,
		run_async = function(executable, args, options, callback)
			_notices[#_notices + 1] = {
				executable = executable, args = args, options = options,
				urgency = type(args) == "table" and type(args[2]) == "string" and args[2]:match("^%-%-urgency=(.*)$") or nil,
				title = type(args) == "table" and args[5] or nil,
				message = type(args) == "table" and args[6] or nil,
			}
			if type(callback) == "function" then callback({ ok = true, code = 0 }) end
			return { cancel = function() return false end, on_settled = function() return false end }
		end,
	}
end

--- Builds the recording notifier. Idempotent: the first call builds it, before
--- any fixture replaces a dependency; later calls keep that instance.
--- @return table notifier
function M.install()
	if _notifier then return _notifier end
	local before = {}
	for name, value in pairs(package.loaded) do before[name] = value end
	package.loaded[SHELL] = recording_shell()
	package.loaded[NOTIFIER] = nil
	local ok, result = pcall(require, NOTIFIER)
	-- Only Lua sources are forgotten: a native module such as luv owns process
	-- state (its event loop), and opening it a second time crashes the process.
	for name in pairs(package.loaded) do
		if before[name] == nil and package.searchpath(name, package.path) then package.loaded[name] = nil end
	end
	package.loaded[SHELL], package.loaded[NOTIFIER] = before[SHELL], before[NOTIFIER]
	if not ok then error("the recording notifier could not load: " .. tostring(result), 0) end
	_notifier = result
	return _notifier
end

--- A chunk for `luajit -e` that makes a child driver process resolve its
--- notifier to the recording one, for fixtures that launch the daemon itself.
--- The child loads it on its first require("adapters.notifier"), once its own
--- package.path is in place, and keeps the dependencies it loaded.
--- @param driver_root string Absolute path of the Linux driver.
--- @return string chunk
function M.child_prelude(driver_root)
	assert(type(driver_root) == "string" and driver_root ~= "", "the driver root is required")
	return string.format([[
package.path = %q .. "/?.lua;" .. package.path
package.preload[%q] = function()
	package.preload[%q] = nil
	return require("tests.support.notice_recorder").bind_child()
end]], driver_root, NOTIFIER, NOTIFIER)
end

--- Builds the recording notifier inside a child launched with child_prelude.
--- @return table notifier
function M.bind_child()
	assert(_notifier == nil, "the recording notifier is already bound")
	local shell = package.loaded[SHELL]
	package.loaded[SHELL] = recording_shell()
	local ok, result = pcall(require, NOTIFIER)
	package.loaded[SHELL] = shell
	if not ok then error("the recording notifier could not load: " .. tostring(result), 0) end
	_notifier = result
	return _notifier
end

--- Puts the recording notifier in place for one test case and forgets what
--- the previous case sent. A double a fixture installed in an earlier case
--- and still owns stays in place: it already keeps the case's notices.
--- @param is_fixture_double function Whether a package.loaded value is a test double.
function M.begin_case(is_fixture_double)
	assert(_notifier, "the recording notifier is not installed")
	_notices = {}
	local current = package.loaded[NOTIFIER]
	if current ~= nil and current ~= _notifier and is_fixture_double(current) then return end
	if current ~= _notifier then _baseline = current end
	package.loaded[NOTIFIER] = _notifier
end

--- Puts back the notifier found outside the cases, unless the case left its own.
function M.end_case()
	if package.loaded[NOTIFIER] == _notifier then package.loaded[NOTIFIER] = _baseline end
end

--- The recording notifier, so a fixture can bind a module to it explicitly.
--- @return table notifier
function M.notifier()
	return assert(_notifier, "the recording notifier is not installed")
end

--- What the current case sent through the recording notifier.
--- @return table notices { { title, message, urgency, args, ... }, ... }
function M.notices()
	local copy = {}
	for index, notice in ipairs(_notices) do copy[index] = notice end
	return copy
end

return M
