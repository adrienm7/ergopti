--- modules/diagnostics/hid_diagnostic_mailbox.lua

--- ==============================================================================
--- MODULE: HID Diagnostic Mailbox
--- DESCRIPTION:
--- Owns one repeating off-HID pump for failures discovered inside the keyboard
--- eventtap. Producers publish only bounded, privacy-safe metadata to memory;
--- the pump performs logger I/O later and retries the exact record if the sink
--- raises. This keeps diagnostics visible without creating timers or touching
--- the filesystem on the latency-critical keystroke callback.
---
--- FEATURES & RATIONALE:
--- 1. One lifecycle pump: keymap start/stop owns one exact repeating timer.
--- 2. Bounded mailbox: excess records are coalesced into visible kind counts.
--- 3. Retry ownership: a record is removed only after its logger call returns.
--- 4. Privacy: exception objects and dynamic identifiers never enter the queue.
--- ==============================================================================

local M = {}

local TimerScheduler = require("adapters.timer_scheduler")
local Logger = require("infra.logger")

local LOG = "diagnostics.hid_mailbox"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local KIND_PREVIEW_PROVIDER = "preview_provider"
local KIND_DYNAMIC_RESOLVER = "dynamic_resolver"

-- Diagnostics are exceptional and latched by producer identity. Sixty-four
-- records cover the complete built-in provider/rule set while bounding memory
-- if a future registry installs an unbounded number of failing callbacks.
M.DEFAULT_STATE = {
	capacity = 64,
	pump_interval_sec = 0.25,
}

-- Lua numbers are exact integers through 2^53. Saturating counters keep the
-- mailbox's memory and arithmetic bounded even if the sink remains unavailable.
local MAX_EXACT_COUNTER = 9007199254740991

local _queue = {}
local _head = 1
local _tail = 0
local _overflow_preview = 0
local _overflow_resolver = 0
local _delivery_failures = 0
local _pump_handle = nil
local _pump_generation = 0
local _running = false
local _draining = false


--- Returns the number of concrete records currently retained.
--- @return integer count
local function pending_count()
	if _tail < _head then return 0 end
	return _tail - _head + 1
end


--- Increments a diagnostic counter without leaving the exact-integer range.
--- @param value integer Current counter.
--- @return integer incremented
local function increment_counter(value)
	if value >= MAX_EXACT_COUNTER then return MAX_EXACT_COUNTER end
	return value + 1
end


--- Publishes one bounded metadata record without scheduler or logger calls.
--- @param kind string One of the private diagnostic-kind constants.
--- @param first integer First privacy-safe numeric field.
--- @param second integer|nil Optional second numeric field.
--- @return boolean owned Always true once the event or its overflow count is retained.
local function enqueue(kind, first, second)
	if pending_count() >= M.DEFAULT_STATE.capacity then
		if kind == KIND_PREVIEW_PROVIDER then
			_overflow_preview = increment_counter(_overflow_preview)
		else
			_overflow_resolver = increment_counter(_overflow_resolver)
		end
		return true
	end

	_tail = _tail + 1
	_queue[_tail] = {
		kind = kind,
		first = first,
		second = second,
	}
	return true
end


--- Emits one privacy-safe record through its owning subsystem tag.
--- @param record table Mailbox record containing numeric metadata only.
local function emit_record(record)
	if record.kind == KIND_PREVIEW_PROVIDER then
		Logger.error("keymap.llm_bridge",
			"Preview provider #%d raised; static fallback retained (failure content withheld).",
			record.first)
		return
	end

	Logger.error("dynamic_hotstrings.rules",
		"Dynamic resolver raised; matching continued "
			.. "(%d-byte section identifier, %d-byte suffix; failure content withheld).",
		record.first, record.second)
end


--- Emits the bounded-overflow summary after concrete records are delivered.
local function emit_overflow()
	Logger.error(LOG,
		"HID diagnostic mailbox reached its %d-record bound; "
			.. "%d preview-provider and %d resolver failure(s) were coalesced without content.",
		M.DEFAULT_STATE.capacity, _overflow_preview, _overflow_resolver)
end


--- Emits the retry summary after the blocked record finally reaches the sink.
--- @param attempts integer Failed pump attempt count.
local function emit_recovery(attempts)
	Logger.warn(LOG,
		"HID diagnostic delivery recovered after %d failed off-HID pump attempt(s).",
		attempts)
end


--- Drains all currently reachable records, retaining the first failed item.
--- @return boolean delivered True only when records, overflow, and recovery settled.
local function drain_pending()
	if _draining then return false end
	_draining = true

	local delivered = true
	while _head <= _tail do
		local record = _queue[_head]
		local emitted = pcall(emit_record, record)
		if not emitted then
			delivered = false
			break
		end
		_queue[_head] = nil
		_head = _head + 1
	end

	if _head > _tail then
		_queue = {}
		_head = 1
		_tail = 0
	end

	if delivered and (_overflow_preview > 0 or _overflow_resolver > 0) then
		local emitted = pcall(emit_overflow)
		if emitted then
			_overflow_preview = 0
			_overflow_resolver = 0
		else
			delivered = false
		end
	end

	if delivered and _delivery_failures > 0 then
		local recovered_after = _delivery_failures
		local emitted = pcall(emit_recovery, recovered_after)
		if emitted then
			_delivery_failures = 0
		else
			delivered = false
		end
	end

	if not delivered then
		_delivery_failures = increment_counter(_delivery_failures)
	end
	_draining = false
	return delivered
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Publishes a preview-provider failure without retaining its error object.
--- Extra arguments are deliberately ignored so exception content cannot cross
--- the eventtap-to-pump boundary.
--- @param provider_index number Stable provider ordinal.
--- @return boolean owned
function M.report_preview_provider_failure(provider_index)
	local index = type(provider_index) == "number" and math.floor(provider_index) or 0
	return enqueue(KIND_PREVIEW_PROVIDER, index)
end


--- Publishes a resolver failure using lengths only, never dynamic content.
--- Extra arguments are deliberately ignored so exception content cannot cross
--- the eventtap-to-pump boundary.
--- @param rule table|nil Shared rule descriptor.
--- @return boolean owned
function M.report_resolver_failure(rule)
	local section_length = type(rule) == "table" and type(rule.section) == "string"
		and #rule.section or 0
	local suffix_length = type(rule) == "table" and type(rule.suffix) == "string"
		and #rule.suffix or 0
	return enqueue(KIND_DYNAMIC_RESOLVER, section_length, suffix_length)
end


--- Starts the sole repeating diagnostic pump.
--- This must run before eventtaps are armed; scheduler failures are therefore
--- logged synchronously only from lifecycle code, never from a key callback.
--- @return boolean committed True only when the native repeating timer is owned.
function M.start()
	if _running then
		Logger.warn(LOG, "start() called while the HID diagnostic pump is already running — retaining it.")
		return true
	end

	Logger.start(LOG, "Starting HID diagnostic pump…")
	_pump_generation = _pump_generation + 1
	local generation = _pump_generation
	local candidate
	local schedule_ok, handle, committed = pcall(TimerScheduler.every,
		M.DEFAULT_STATE.pump_interval_sec, function()
			if not _running or generation ~= _pump_generation
				or _pump_handle ~= candidate then
				return
			end
			drain_pending()
		end)
	candidate = handle

	if not schedule_ok or committed ~= true or type(handle) ~= "table" then
		_pump_generation = _pump_generation + 1
		if schedule_ok and type(handle) == "table" then
			pcall(TimerScheduler.cancel, handle)
		end
		Logger.error(LOG,
			"HID diagnostic pump could not be armed; key capture must remain stopped.")
		return false
	end

	_pump_handle = handle
	_running = true
	Logger.success(LOG, "HID diagnostic pump started.")
	return true
end


--- Drains and stops the exact repeating pump.
--- A failed drain or cancel retains ownership so a later teardown retry can
--- settle the same record and native handle.
--- @return boolean settled
function M.stop()
	Logger.start(LOG, "Stopping HID diagnostic pump…")
	if not drain_pending() then
		Logger.error(LOG,
			"HID diagnostic pump stop retained pending records after a sink failure.")
		return false
	end

	if _running then
		local cancel_ok, settled = pcall(TimerScheduler.cancel, _pump_handle)
		if not cancel_ok or settled ~= true then
			Logger.error(LOG,
				"HID diagnostic pump cancellation did not commit; handle retained for retry.")
			return false
		end
	end

	_pump_generation = _pump_generation + 1
	_pump_handle = nil
	_running = false
	Logger.success(LOG, "HID diagnostic pump stopped.")
	return true
end


--- Reports whether the exact repeating pump is currently owned.
--- @return boolean running
function M.is_running()
	return _running
end


--- Returns content-free mailbox counters for health checks and tests.
--- @return table status
function M.status()
	return {
		running = _running,
		pending = pending_count(),
		overflow_preview = _overflow_preview,
		overflow_resolver = _overflow_resolver,
		delivery_failures = _delivery_failures,
	}
end

return M
