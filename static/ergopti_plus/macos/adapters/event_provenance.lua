--- adapters/event_provenance.lua

--- ==============================================================================
--- MODULE: Quartz Event Provenance Adapter
--- DESCRIPTION:
--- Classifies events only when their eventSourceUserData carries the reserved
--- SyntheticInput namespace. Live ledger records add exact transaction data;
--- old/evicted tags remain fail-closed without regaining loopback authority.
--- Source PID is secondary diagnostics only because unrelated injectors can
--- share Hammerspoon's PID.
---
--- FEATURES & RATIONALE:
--- 1. Explicit Ownership: Untagged/unknown events remain foreign even when their
---    Quartz source PID is the current Hammerspoon process.
--- 2. Independent Consumers: Each live tag is deduplicated separately for
---    keymap, keylogger, and any future loopback consumer.
--- 3. Fail-safe Reads: A malformed user-data accessor is logged once and fails
---    closed; a missing PID only removes diagnostics from an otherwise known tag.
--- ==============================================================================

local M = {}

M.STATUS_OWNED     = "owned"
M.STATUS_FOREIGN   = "foreign"
M.STATUS_UNREADABLE = "unreadable"

local hs             = hs
local Logger         = require("infra.logger")
local SyntheticInput = require("adapters.synthetic_input")
local LOG             = "adapters.event_provenance"

local event_api = assert(hs and hs.eventtap and hs.eventtap.event,
	"adapters.event_provenance: hs.eventtap.event is unavailable")
local properties = assert(event_api.properties,
	"adapters.event_provenance: hs.eventtap.event.properties is unavailable")
local USER_DATA_PROPERTY = assert(properties.eventSourceUserData,
	"adapters.event_provenance: eventSourceUserData is unavailable")
local SOURCE_PID_PROPERTY = assert(properties.eventSourceUnixProcessID,
	"adapters.event_provenance: eventSourceUnixProcessID is unavailable")
local CURRENT_PROCESS_ID = assert(hs.processInfo and tonumber(hs.processInfo.processID),
	"adapters.event_provenance: hs.processInfo.processID is unavailable")
local do_after = assert(hs.timer and hs.timer.doAfter,
	"adapters.event_provenance: hs.timer.doAfter is unavailable")

local _tag_read_failure_logged = false
local _pid_read_failure_logged = false
local _internal_failure_logged = false
local _read_failure_timer = nil
local _pending_read_failures = {}


--- Reads or updates the one-shot diagnostic latch for one failure class.
--- @param field string user-data|PID|adapter.
--- @param value boolean|nil New value, or nil to read.
--- @return boolean latched
local function failure_latch(field, value)
	local current
	if field == "user-data" then
		current = _tag_read_failure_logged
		if value ~= nil then _tag_read_failure_logged = value end
	elseif field == "PID" then
		current = _pid_read_failure_logged
		if value ~= nil then _pid_read_failure_logged = value end
	else
		current = _internal_failure_logged
		if value ~= nil then _internal_failure_logged = value end
	end
	return current
end


--- Reports one native-property failure without flooding the keyboard hot path.
--- @param field string user-data|PID.
--- @param detail string Failure detail.
local function report_read_failure(field, detail)
	if failure_latch(field) then return end
	failure_latch(field, true)
	_pending_read_failures[#_pending_read_failures + 1] = { field = field, detail = detail }
	if _read_failure_timer then return end
	-- Logger.error writes and flushes two files. A property accessor usually fails
	-- from inside CGEventTap, where that synchronous I/O could disable the very tap
	-- this diagnostic is meant to protect. Queue the one-shot report off the HID
	-- callback and retain its native timer until it fires.
	local callback_ran = false
	local ok, timer_or_err = pcall(do_after, 0, function()
		callback_ran = true
		_read_failure_timer = nil
		local pending = _pending_read_failures
		_pending_read_failures = {}
		for _, failure in ipairs(pending) do
			local logged = pcall(Logger.error, LOG,
				"Cannot read Quartz event %s - %s.", failure.field, failure.detail)
			if not logged then failure_latch(failure.field, false) end
		end
	end)
	if ok and timer_or_err ~= nil and not callback_ran then
		_read_failure_timer = timer_or_err
	else
		-- Never replace a failed diagnostic deferral with blocking file I/O on the
		-- eventtap. Roll the latches back so a recovered timer can report the next
		-- occurrence instead of creating a permanent diagnostics black hole.
		for _, failure in ipairs(_pending_read_failures) do
			failure_latch(failure.field, false)
		end
		_pending_read_failures = {}
	end
end


--- Reads a property without allowing a malformed event to abort its eventtap.
--- @param event userdata|table hs.eventtap event.
--- @param property number Quartz property constant.
--- @param field string Diagnostic label.
--- @return any value
--- @return boolean readable
local function read_property(event, property, field)
	if event == nil or type(event.getProperty) ~= "function" then
		report_read_failure(field, "event.getProperty is unavailable")
		return nil, false
	end
	local ok, value = pcall(event.getProperty, event, property)
	if not ok then
		report_read_failure(field, tostring(value))
		return nil, false
	end
	return value, true
end


--- Classifies a tagged SyntheticInput event and claims it for one consumer.
--- Tag membership is authoritative. PID mismatch/missing state is diagnostic
--- metadata only and cannot turn an explicit owned event into physical input.
--- @param event userdata|table hs.eventtap event.
--- @param consumer_id string|nil Stable consumer name for independent dedupe.
--- @return table|nil metadata Nil for untagged/unknown/unreadable events.
--- @return string status One of STATUS_OWNED/STATUS_FOREIGN/STATUS_UNREADABLE.
function M.classify(event, consumer_id)
	if consumer_id ~= nil then
		assert(type(consumer_id) == "string" and consumer_id ~= "",
			"adapters.event_provenance.classify: consumer_id must be a non-empty string")
	end
	local tag, readable = read_property(event, USER_DATA_PROPERTY, "user-data")
	if not readable then return nil, M.STATUS_UNREADABLE end
	if type(tag) ~= "number" then return nil, M.STATUS_FOREIGN end
	local claimed, duplicate = SyntheticInput.claim_tag(tag, consumer_id)
	if claimed == nil then return nil, M.STATUS_FOREIGN end
	local source_pid, pid_readable = read_property(event, SOURCE_PID_PROPERTY, "PID")
	if not pid_readable or type(source_pid) ~= "number" then source_pid = nil end
	local pid_matches = nil
	if source_pid ~= nil then pid_matches = source_pid == CURRENT_PROCESS_ID end
	claimed.duplicate = duplicate
	claimed.source_pid = source_pid
	claimed.pid_matches = pid_matches
	return claimed, M.STATUS_OWNED
end


--- Returns explicit tag ownership without consuming any consumer dedupe slot.
--- @param event userdata|table hs.eventtap event.
--- @return boolean owned
--- @return string status Classification status.
function M.is_owned(event)
	local _, status = M.classify(event, nil)
	return status == M.STATUS_OWNED, status
end


--- Classifies one input event and atomically claims every older deferred payload
--- before a non-owned event can mutate user-visible state. Unreadable events also
--- take the ordering fence, but remain distinct so consumers can pass them through
--- without treating an unknown synthetic echo as human input.
--- @param event userdata|table hs.eventtap event.
--- @param consumer_id string Stable consumer name.
--- @return table|nil metadata Owned-event metadata.
--- @return string status Classification status.
--- @return table|nil fence Physical-ordering adoption/cancellation record.
function M.classify_with_fence(event, consumer_id)
	assert(type(consumer_id) == "string" and consumer_id ~= "",
		"adapters.event_provenance.classify_with_fence: consumer_id must be a non-empty string")
	local ok, metadata, status = xpcall(function()
		return M.classify(event, consumer_id)
	end, debug.traceback)
	if not ok then
		report_read_failure("adapter", tostring(metadata))
		metadata, status = nil, M.STATUS_UNREADABLE
	end
	if status == M.STATUS_OWNED then return metadata, status, nil end
	local fence_ok, fence_or_err = xpcall(SyntheticInput.claim_physical_fence, debug.traceback)
	if not fence_ok then
		report_read_failure("adapter", tostring(fence_or_err))
		-- A foreign event is only authoritative after every older payload was
		-- claimed. If that ordering operation fails, downgrade the event so no
		-- consumer accepts, reloads, wraps, or otherwise mutates stale state.
		return nil, M.STATUS_UNREADABLE, nil
	end
	return nil, status, fence_or_err
end

return M
