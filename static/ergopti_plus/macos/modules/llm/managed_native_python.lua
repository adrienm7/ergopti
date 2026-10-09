--- modules/llm/managed_native_python.lua

--- ==============================================================================
--- MODULE: Managed Native Python Resolver
--- DESCRIPTION:
--- Keeps native system Python first, then probes the exact generated private uv
--- namespace asynchronously before any private interpreter may be executed.
--- ==============================================================================

local M = {}
local Interpreter = require("adapters.python_interpreter")
local Locator = require("core.llm.managed_python_locator")
local Probe = require("adapters.native_python_probe")
local TimerScheduler = require("adapters.timer_scheduler")
local Budget = require("modules.llm.bootstrap_retry_generated")
local hs = hs

local function now()
	local ok, value = pcall(TimerScheduler.now_ns)
	return ok and type(value) == "number" and value == value and value >= 0
		and value < math.huge and value / 1e9 or nil
end

local function finite(value)
	return type(value) == "number" and value == value and value > 0 and value < math.huge
end

local function locator_shape()
	if type(Locator) ~= "table" then return false end
	local count = 0
	for architecture, relative in pairs(Locator) do
		if architecture ~= "arm64" and architecture ~= "x86_64" then return false end
		local family = architecture == "arm64" and "aarch64" or "x86_64"
		if type(relative) ~= "string" or not relative:match("^cpython%-%d+%.%d+%.%d+%-macos%-"
			.. family .. "%-none/bin/python%d+%.%d+$") then return false end
		count = count + 1
	end
	return count == 2
end

--- Resolve native system Python or one physically retired private header probe.
--- @param remaining_seconds number|nil Remaining original caller admission budget.
--- @return string|nil executable Existing actually native interpreter.
--- @return string|nil state `pending` while exact probe cleanup remains owned.
function M.resolve(remaining_seconds)
	local entry_clock = now()
	local duration = finite(Budget.admission_seconds) and
		(remaining_seconds == nil or finite(remaining_seconds)) and
		math.min(Budget.admission_seconds, remaining_seconds or Budget.admission_seconds) or nil
	local deadline = entry_clock and duration and entry_clock + duration or nil
	local system = Interpreter.resolve()
	if system then
		if Probe.cancel() ~= true then return nil, "pending" end
		local clock = now()
		return deadline and clock and clock < deadline and system or nil
	end
	if not deadline then return nil, Probe.cancel() ~= true and "pending" or nil end
	local home = os.getenv("HOME")
	local arch = hs and hs.processInfo and hs.processInfo.arch
	if type(home) ~= "string" or home:sub(1, 1) ~= "/" or home:find("\0", 1, true)
		or (arch ~= "arm64" and arch ~= "x86_64") or not locator_shape() then
		return nil, Probe.cancel() ~= true and "pending" or nil
	end
	local relative = Locator[arch]
	local root = home:gsub("/+$", "") .. "/Library/Application Support/Ergopti/native-bootstrap/python/"
	local installation = relative:match("^([^/]+)/bin/python%d+%.%d+$")
	return Probe.get(root .. relative, root .. installation .. "/", arch, remaining_seconds, deadline)
end

--- Retry physical retirement of the exact pending private interpreter probe.
--- @return boolean settled The original probe and timer are physically retired.
function M.cancel()
	return Probe.cancel()
end

--- Observe original probe settlement without authorizing a successor launch.
--- @param callback function Receives exact retirement, including refusal.
--- @return boolean accepted Observer is owned by the current probe or called now.
function M.onSettled(callback)
	return Probe.onSettled(callback)
end

return M
