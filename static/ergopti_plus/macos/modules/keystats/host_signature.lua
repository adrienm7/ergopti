--- modules/keystats/host_signature.lua

--- ==============================================================================
--- MODULE: Keystats Host Signature Prefetch
--- DESCRIPTION:
--- Reads this Mac's hardware UUID (KEYSTATS_SPEC §16.1) in an asynchronous
--- ioreg child before the deferred keystats start needs it. The log manager
--- resolved it with a synchronous `ioreg -d2` pipeline inside M.init(), which
--- held the main run loop 151 ms at boot+1 s on the Mac (field report
--- 2026-11-03) while the event taps were already live.
---
--- FEATURES & RATIONALE:
--- 1. One owner: this module holds the only probe in flight, its waiters and
---    its bound. A second prefetch while one is pending joins it.
--- 2. Same value as the synchronous pipeline: parse() mirrors
---    `grep IOPlatformUUID | awk -F\" '{print $4}'` followed by the log
---    manager's whitespace strip. A different value would mint a second device
---    identity for the same Mac.
--- 3. Fail toward the old path, never toward a fallback identity: a probe that
---    cannot start, exits non-zero, prints no UUID or outlives its bound leaves
---    the value unpublished, so the log manager runs its synchronous probe (and
---    only then its documented `fallback:<host>` value).
--- ==============================================================================

local M = {}

local Logger       = require("infra.logger")
local ShellRunner  = require("adapters.shell_runner")
local DeferredWork = require("infra.deferred_work")

local LOG = "keystats.host_signature"

M.IOREG_PATH = "/usr/sbin/ioreg"
M.IOREG_ARGS = { "-d2", "-c", "IOPlatformExpertDevice" }

-- A UUID shorter than this is not one; the synchronous resolver uses the same bound.
M.MIN_LENGTH = 8

-- ioreg answers in about 150 ms; past this bound the start stops waiting for it.
M.TIMEOUT_SEC = 3.0

-- idle | pending | resolved | failed
local _status = "idle"
local _value = nil
local _waiters = {}
-- Bumped by every probe and by cancel(), so a late completion or bound from an
-- abandoned probe cannot settle the current one.
local _generation = 0





-- ==========================
-- ==========================
-- ======= 1/ Parsing =======
-- ==========================
-- ==========================

--- Extracts the hardware UUID from raw `ioreg -d2 -c IOPlatformExpertDevice`
--- output exactly as the synchronous pipeline does.
--- @param output string|nil Raw ioreg standard output.
--- @return string|nil uuid The stripped UUID, or nil when none is usable.
function M.parse(output)
	if type(output) ~= "string" then return nil end
	local printed = {}
	for line in (output .. "\n"):gmatch("([^\n]*)\n") do
		if line:find("IOPlatformUUID", 1, true) then
			-- awk -F'"' '{print $4}': the fourth double-quote-separated field,
			-- empty when the line has fewer fields.
			local fields = {}
			for field in (line .. '"'):gmatch('([^"]*)"') do fields[#fields + 1] = field end
			printed[#printed + 1] = fields[4] or ""
		end
	end
	local uuid = table.concat(printed, "\n"):gsub("[%s\n\r]+", "")
	if #uuid >= M.MIN_LENGTH then return uuid end
	return nil
end





-- ============================
-- ============================
-- ======= 2/ Lifecycle =======
-- ============================
-- ============================

--- Settles the current probe and hands its outcome to every waiter.
--- @param generation number Probe generation the outcome belongs to.
--- @param uuid string|nil Parsed UUID, or nil on failure.
--- @param reason string|nil Failure description for the log.
local function settle(generation, uuid, reason)
	if generation ~= _generation or _status ~= "pending" then return end
	if uuid then
		_status, _value = "resolved", uuid
		Logger.success(LOG, "Hardware UUID read off the main thread.")
	else
		_status, _value = "failed", nil
		Logger.warn(LOG, "Hardware UUID prefetch failed (%s); keystats start reads it synchronously.",
			tostring(reason))
	end
	local waiters = _waiters
	_waiters = {}
	for _, waiter in ipairs(waiters) do
		local ok, err = xpcall(waiter, debug.traceback)
		if not ok then
			Logger.error(LOG, "Host signature waiter raised: %s.", tostring(err))
		end
	end
end

--- Starts the probe unless it already ran, and calls on_settled once it has.
--- @param on_settled function|nil Zero-argument callback run after the probe
---   settles; it is not called when the probe has already settled.
--- @return boolean settled True when the outcome is already known, so the caller
---   proceeds now and on_settled is not retained.
function M.prefetch(on_settled)
	if on_settled ~= nil and type(on_settled) ~= "function" then
		error("host signature prefetch callback must be a function", 2)
	end
	if _status == "resolved" or _status == "failed" then return true end
	if _status == "pending" then
		if on_settled then _waiters[#_waiters + 1] = on_settled end
		return false
	end

	_generation = _generation + 1
	local generation = _generation
	_status = "pending"
	Logger.start(LOG, "Reading the hardware UUID off the main thread…")
	local bounded = DeferredWork.after(M.TIMEOUT_SEC, function()
		settle(generation, nil, "no answer within the bound")
	end, "keystats.host_signature.timeout")
	if not bounded then
		settle(generation, nil, "the bound could not be armed")
		return true
	end
	-- ShellRunner.run pins the task and calls back on every outcome, a launch
	-- failure included, synchronously. The caller's callback is retained only
	-- after the launch, so a synchronous settle answers true without running it.
	ShellRunner.run(M.IOREG_PATH, M.IOREG_ARGS, function(ok, stdout)
		if not ok then
			settle(generation, nil, "ioreg failed")
			return
		end
		local uuid = M.parse(stdout)
		settle(generation, uuid, uuid == nil and "no IOPlatformUUID in the output" or nil)
	end)
	if _status ~= "pending" then return true end
	if on_settled then _waiters[#_waiters + 1] = on_settled end
	return false
end

--- Returns the prefetched UUID once one was read.
--- @return string|nil uuid
function M.value()
	if _status == "resolved" then return _value end
	return nil
end

--- Returns the probe state: idle, pending, resolved or failed.
--- @return string status
function M.status()
	return _status
end

--- Abandons a pending probe and its waiters; a settled value is kept, since
--- the hardware UUID does not change while the process runs.
function M.cancel()
	if _status ~= "pending" then return end
	_generation = _generation + 1
	_status = "idle"
	_waiters = {}
	Logger.info(LOG, "Hardware UUID prefetch abandoned.")
end

--- Restores the pristine state (test seam).
function M._reset_for_tests()
	_generation = _generation + 1
	_status, _value, _waiters = "idle", nil, {}
end

return M
