--- ui/healthcheck/appleevents.lua

--- ==============================================================================
--- MODULE: Owned AppleEvent Diagnostic Probe
--- DESCRIPTION:
--- Runs one normal external nonce command against this running Hammerspoon.
--- It never changes scripting settings, permissions, process responsibility or
--- native event admission. Business failure and physical retirement are distinct.
--- ==============================================================================

local M = {}
local ShellRunner = require("adapters.shell_runner")
local Scheduler = require("adapters.timer_scheduler")
local Logger = require("infra.logger")
local runtime = hs
local LOG = "healthcheck.appleevents"
local active = {}
local SENDER_CONTEXT = "driver_spawned_osascript"
local QUALIFICATION_SCOPE = "local_runtime_nonce"

local SCRIPT_SUFFIX = [[
set received to execute lua code (item 1 of argv)
end tell
return "OK:" & received
on error ignored number status
return "ERR:" & status
end try
end run]]

local function scripting_source(path)
	-- Compile against the exact bundle dictionary, just like the existing CI
	-- control. A dynamic target would not declare the execute-lua vocabulary.
	local quoted = '"' .. path:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
	return "on run argv\ntry\ntell application " .. quoted .. "\n" .. SCRIPT_SUFFIX
end

local function integer(value)
	return type(value) == "number" and value == value and value > 0
		and value < 2 ^ 53 and value == math.floor(value)
end

local function clock()
	local value = runtime.timer.absoluteTime()
	assert(type(value) == "number" and value == value and value >= 0
		and value < math.huge, "Native diagnostic clock unavailable")
	return value / 1e6
end

local function identity()
	local info = runtime and runtime.processInfo
	if type(info) ~= "table" or not integer(info.processID) then return nil end
	local path, executable, bundle = info.bundlePath, info.executablePath, info.bundleID
	if type(path) ~= "string" or path:sub(1, 1) ~= "/" or path:sub(-4) ~= ".app"
		or path:find("%c") or type(bundle) ~= "string" or bundle == ""
		or executable ~= path .. "/Contents/MacOS/Hammerspoon" then return nil end
	return { pid = info.processID, path = path, executable = executable, bundle = bundle }
end

local function current(expected)
	local actual = identity()
	return actual and actual.pid == expected.pid and actual.path == expected.path
		and actual.executable == expected.executable and actual.bundle == expected.bundle
end

local function native_result(code, stdout, stderr, expected)
	if code ~= 0 then return "error", "native_exit", nil end
	if type(stdout) ~= "string" or stderr ~= "" then return "error", "native_output_refused", nil end
	local maximum = math.max(#("OK:" .. expected .. "\n"), #("ERR:" .. tostring(-2147483648) .. "\n"))
	if #stdout > maximum then return "error", "native_output_refused", nil end
	local frame = stdout:gsub("\n$", "")
	if frame == "OK:" .. expected then return "ok", "nonce_acknowledged", 0 end
	local text = frame:match("^ERR:(%-?%d+)$")
	local status = text and tonumber(text)
	if not status or status ~= math.floor(status) or status < -2147483648 or status > 2147483647
		or tostring(status) ~= text or status == 0 then return "error", "native_output_refused", nil end
	if status == -1743 then return "error", "permission_refused", status end
	if status == -1744 then return "error", "consent_required", status end
	if status == -1712 then return "timeout", "native_timeout", status end
	return "error", "native_refused", status
end

--- Builds one affine body for the existing healthcheck probe registry.
--- Caller owns the schema timing and the run/epoch; this body cannot restart it.
--- @param config table Declared probe { timeout_ms = positive integer }.
--- @return function body(done, register_cancel, started_ms) Returns an exact local actor.
function M.body(config)
	assert(type(config) == "table" and integer(config.timeout_ms), "Invalid diagnostic timing")
	local budget, claimed = config.timeout_ms, false
	return function(done, register_cancel, started_ms)
		assert(type(done) == "function" and type(register_cancel) == "function", "Invalid diagnostic owner")
		assert(type(started_ms) == "number" and started_ms == started_ms and started_ms >= 0
			and started_ms < math.huge, "Original diagnostic clock unavailable")
		assert(not claimed, "Diagnostic body already claimed")
		claimed = true
		if next(active) ~= nil then
			done({ state = "not_run", detail = "probe_busy", cleanup = "settled",
				sender_context = SENDER_CONTEXT, qualification_scope = QUALIFICATION_SCOPE })
			return nil
		end
		local owner = { preparing = true, process_creating = false, result = nil, delivered = false }
		active[owner] = true
		local retry
		local function notify()
			if owner.preparing or owner.delivered or not owner.result then return end
			owner.delivered = true
			local okay = pcall(done, owner.result)
			if not okay then Logger.error(LOG, "Diagnostic result callback refused.") end
		end
		local function choose(state, detail, status)
			if owner.result then return end
			owner.result = { state = state, detail = detail, cleanup = "pending",
				runtime_pid = owner.identity and owner.identity.pid or nil,
				native_status = status, sender_context = SENDER_CONTEXT,
				qualification_scope = QUALIFICATION_SCOPE }
			owner.native_status = status
		end
		function owner.snapshot()
			return { state = owner.result and owner.result.state or "pending",
				detail = owner.result and owner.result.detail or nil,
				cleanup = owner.result and owner.result.cleanup or "pending",
				native_status = owner.native_status,
				runtime_pid = owner.identity and owner.identity.pid or nil,
				sender_context = SENDER_CONTEXT, qualification_scope = QUALIFICATION_SCOPE }
		end
		retry = function()
			if owner.closed or owner.retiring or owner.preparing or not owner.result then return end
			owner.retiring = true
			if owner.timer then
				local okay, acknowledged = pcall(Scheduler.cancel, owner.timer)
				if okay and acknowledged == true then owner.timer = nil end
			end
			if owner.process then
				local okay, settled = pcall(owner.process.isSettled)
				if not okay or settled ~= true then pcall(owner.process.terminate) end
				okay, settled = pcall(owner.process.isSettled)
				if okay and settled == true then owner.process = nil end
			end
			local closed = not owner.timer and not owner.process and not owner.process_creating
			owner.result.cleanup = closed and "settled" or "pending"
			if owner.result.state == "ok" then
				local okay, now = pcall(clock)
				if not closed then owner.result.state, owner.result.detail = "error", "cleanup_debt"
				elseif not okay then owner.result.state, owner.result.detail = "error", "clock_refused"
				elseif now >= owner.deadline then owner.result.state, owner.result.detail = "timeout", "deadline_expired" end
			end
			owner.retiring = false
			if closed then
				owner.closed = true
				active[owner] = nil
				Logger.done(LOG, "Diagnostic native resources retired.")
			end
			notify()
		end
		function owner.cancel()
			choose("cancelled", "cancelled")
			retry()
			return owner.snapshot().cleanup
		end
		Logger.trace(LOG, "Diagnostic probe started.")
		local okay = pcall(function()
			owner.started = started_ms
			owner.deadline = owner.started + budget
			assert(clock() >= owner.started, "Original diagnostic clock is not current")
			register_cancel(owner.cancel)
			if owner.result then return end
			owner.identity = identity()
			if not owner.identity then choose("not_run", "runtime_identity_unavailable") return end
			local allowed = runtime.allowAppleScript()
			if allowed ~= true then
				choose("not_run", allowed == false and "scripting_disabled" or "scripting_state_unavailable")
				return
			end
			local uuid = runtime.host.uuid()
			assert(type(uuid) == "string", "Native nonce unavailable")
			local nonce = uuid:gsub("%-", ""):lower()
			assert(#nonce == 32 and nonce:match("^[0-9a-f]+$"), "Native nonce invalid")
			owner.expected = tostring(owner.identity.pid) .. ":" .. nonce
			local remaining = owner.deadline - clock()
			if remaining <= 0 then choose("timeout", "deadline_expired") return end
			local handle, committed = Scheduler.after(remaining / 1000, function()
				choose("timeout", "deadline_expired")
				retry()
			end)
			owner.timer = handle
			if handle and Scheduler.onSettled(handle, retry) ~= true then
				choose("error", "timer_observer_refused")
				return
			end
			if committed ~= true then choose("error", "timer_start_refused") return end
			if owner.result then return end
			if clock() >= owner.deadline then choose("timeout", "deadline_expired") return end
			assert(current(owner.identity), "Runtime identity changed")
			local source = "return tostring(hs.processInfo.processID) .. ':" .. nonce .. "'"
			owner.process_creating = true
			owner.process = ShellRunner.spawn("/usr/bin/osascript", { "-e", scripting_source(owner.identity.path), source },
				function(code, stdout, stderr)
					owner.completion = { code, stdout, stderr }
					if not owner.preparing then owner.consume() end
				end, nil, nil, true)
			owner.process_creating = false
			if owner.process.onSettled(retry) ~= true then choose("error", "native_observer_refused") return end
			function owner.consume()
				if owner.result then retry() return end
				local sampled, now = pcall(clock)
				if not sampled then choose("error", "clock_refused")
				elseif now >= owner.deadline then choose("timeout", "deadline_expired")
				else
					local checked, same = pcall(current, owner.identity)
					if not checked or not same then choose("error", "runtime_identity_changed")
					else choose(native_result(owner.completion[1], owner.completion[2], owner.completion[3], owner.expected)) end
				end
				retry()
			end
			if owner.process.start() ~= true then choose("error", "native_start_refused") end
		end)
		if not okay then choose("error", "native_operation_refused") end
		owner.preparing = false
		if owner.completion and not owner.result then owner.consume() end
		retry()
		return owner
	end
end

--- Counts only physically unretired local owners, not inferred running PIDs.
--- @return integer retained count.
function M.active_count()
	local count = 0
	for _ in pairs(active) do count = count + 1 end
	return count
end

return M
