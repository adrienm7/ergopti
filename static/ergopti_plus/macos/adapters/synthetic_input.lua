--- adapters/synthetic_input.lua

--- ==============================================================================
--- MODULE: Synthetic Input Adapter
--- DESCRIPTION:
--- Builds explicitly tagged Quartz keyboard events and normally dispatches them
--- in one eventtap callback-return batch. Terminal compatibility transfers a
--- sealed callback batch to the same process-wide FIFO, then target-posts it with
--- bounded pacing after callback return; timer/menu producers use one tagged
--- otherMouseUp broker trigger.
---
--- FEATURES & RATIONALE:
--- 1. Exact Provenance: Every emitted event carries a unique user-data tag whose
---    bounded record identifies its session, transaction, key ordinal, and phase.
--- 2. Transaction Ordering: Completion waits for seal, retained async work, and
---    timer-zero confirmation that every callback-return batch was handed off.
--- 3. Ambient Migration Layer: Existing nested injectors can emit into the active
---    callback/transaction without threading a batch through every call frame.
--- 4. Visible Async Failures: Pump, timer, and lifecycle callbacks are isolated by
---    xpcall and reported to the file logger instead of disappearing in HS Console.
--- ==============================================================================

local M = {}

local hs            = hs
local Logger        = require("infra.logger")
local LOG           = "adapters.synthetic_input"

local eventtap = assert(hs and hs.eventtap,
	"adapters.synthetic_input: hs.eventtap is unavailable")
local event_api = assert(eventtap.event,
	"adapters.synthetic_input: hs.eventtap.event is unavailable")
local properties = assert(event_api.properties,
	"adapters.synthetic_input: hs.eventtap.event.properties is unavailable")
local event_types = assert(event_api.types,
	"adapters.synthetic_input: hs.eventtap.event.types is unavailable")
local USER_DATA_PROPERTY = assert(properties.eventSourceUserData,
	"adapters.synthetic_input: eventSourceUserData is unavailable")
local SOURCE_PID_PROPERTY = assert(properties.eventSourceUnixProcessID,
	"adapters.synthetic_input: eventSourceUnixProcessID is unavailable")
local OTHER_MOUSE_UP_EVENT_TYPE = assert(event_types.otherMouseUp,
	"adapters.synthetic_input: otherMouseUp is unavailable")
local MOUSE_BUTTON_PROPERTY = assert(properties.mouseEventButtonNumber,
	"adapters.synthetic_input: mouseEventButtonNumber is unavailable")
local new_key_event = assert(event_api.newKeyEvent,
	"adapters.synthetic_input: hs.eventtap.event.newKeyEvent is unavailable")
local new_mouse_event = assert(event_api.newMouseEvent,
	"adapters.synthetic_input: hs.eventtap.event.newMouseEvent is unavailable")
local new_tap = assert(eventtap.new,
	"adapters.synthetic_input: hs.eventtap.new is unavailable")
local timer_api = assert(hs.timer,
	"adapters.synthetic_input: hs.timer is unavailable")
local do_after = assert(timer_api.doAfter,
	"adapters.synthetic_input: hs.timer.doAfter is unavailable")
local do_every = assert(timer_api.doEvery,
	"adapters.synthetic_input: hs.timer.doEvery is unavailable")
local delayed_api = assert(timer_api.delayed,
	"adapters.synthetic_input: hs.timer.delayed is unavailable")
local new_delayed_timer = assert(delayed_api.new,
	"adapters.synthetic_input: hs.timer.delayed.new is unavailable")
local absolute_time = assert(timer_api.absoluteTime,
	"adapters.synthetic_input: hs.timer.absoluteTime is unavailable")
local seconds_since_epoch = assert(timer_api.secondsSinceEpoch,
	"adapters.synthetic_input: hs.timer.secondsSinceEpoch is unavailable")
local CURRENT_PROCESS_ID = assert(hs.processInfo and tonumber(hs.processInfo.processID),
	"adapters.synthetic_input: hs.processInfo.processID is unavailable")
local mouse_position = assert(hs.mouse and hs.mouse.absolutePosition,
	"adapters.synthetic_input: hs.mouse.absolutePosition is unavailable")
local application_api = assert(hs.application,
	"adapters.synthetic_input: hs.application is unavailable")
local application_get = application_api.get

M.MAGIC = "ERGOPTI_SYNTHETIC_V1"
M.RECORD_LIMIT = 4096
M.CONSUMER_LIMIT = 16
-- Keep 64 one-million-tag reservations (more than 67 million events) so a tag
-- evicted from the enrichment ledger during a very large current-session action
-- is not mistaken for pre-reload output. Older dropped ranges fail safe as stale.
M.SESSION_BLOCK_HISTORY_LIMIT = 64
-- A stale tag can be observed by several taps. Bound the central once-only set
-- instead of letting each consumer manufacture its own action boundary.
M.STALE_CONTEXT_DEDUPE_LIMIT = M.RECORD_LIMIT
M.PUMP_DELIVERY_TIMEOUT_SEC = 0.25
M.PUMP_MOUSE_BUTTON = 31
M.PUMP_WATCHDOG_MAX_FAILURES = 5
M.ACTION_LISTENER_RETRY_SEC = 0.05
M.ACTION_LISTENER_RETRY_MAX_SEC = 0.8
M.ACTION_LISTENER_MAX_ATTEMPTS = 5
M.SERIAL_POST_MAX_ATTEMPTS = 5
M.PERIODIC_OWNER_TICK_SEC = 0.005
M.IDLE_WAITER_TICK_SEC = 0.01
-- After the final delete-pair turn, one turn posts the contiguous replacement
-- suffix and the next settles transaction lifecycle callbacks.
M.PACED_TRAILING_TICKS = 2

local EFFECTS = {
	action = true,
	replacement = true,
}

-- Quartz stores eventSourceUserData as int64_t and Hammerspoon reads/writes it
-- with lua_Integer. The high bits are therefore a self-describing namespace:
-- even after its enrichment record is evicted, an Ergopti event still fails
-- closed as synthetic and retains its action/replacement + loopback semantics.
local TAG_NAMESPACE = 0x455047 -- ASCII "EPG", 23 bits; bit 63 remains clear
local TAG_NAMESPACE_BITS = 23
local TAG_NAMESPACE_SHIFT = 40
local TAG_EFFECT_SHIFT = 39
local TAG_LOOPBACK_SHIFT = 38
local TAG_SEQUENCE_BITS = 38
local TAG_SEQUENCE_LIMIT = 1 << TAG_SEQUENCE_BITS
local TAG_SEQUENCE_MASK = TAG_SEQUENCE_LIMIT - 1
local TAG_BLOCK_SIZE = 1 << 20 -- reserve 1,048,576 unique values per write
local TAG_RESERVATION_KEY = "ergopti_plus.synthetic_input.next_tag_sequence_v2"
local session_tick = assert(tonumber(absolute_time()),
	"adapters.synthetic_input: hs.timer.absoluteTime returned no number")
local epoch_microseconds = math.floor(assert(tonumber(seconds_since_epoch()),
	"adapters.synthetic_input: hs.timer.secondsSinceEpoch returned no number") * 1000000)
local settings_api = assert(hs.settings,
	"adapters.synthetic_input: hs.settings is unavailable")
assert(type(settings_api.get) == "function" and type(settings_api.set) == "function",
	"adapters.synthetic_input: hs.settings get/set is unavailable")
local _sequence_next = nil
local _sequence_remaining = 0
local _session_block_starts = {}
local _session_block_count = 0
local _session_block_cursor = 1


--- Remembers one sequence reservation owned by this module instance.
--- The ring is intentionally bounded; ranges older than the history window are
--- treated conservatively as pre-reload if their enrichment is also gone.
--- @param first number First sequence in the reserved block.
local function remember_session_block(first)
	local slot = _session_block_cursor
	_session_block_starts[slot] = first
	_session_block_cursor = (slot % M.SESSION_BLOCK_HISTORY_LIMIT) + 1
	if _session_block_count < M.SESSION_BLOCK_HISTORY_LIMIT then
		_session_block_count = _session_block_count + 1
	end
end


--- Reserves the next globally unique sequence block before any value is used.
--- @return number first_sequence
local function reserve_sequence_block()
	local stored = math.tointeger(settings_api.get(TAG_RESERVATION_KEY))
	-- Wall-clock seeding is used only when no persisted high-water exists.
	-- Thereafter the persisted ring position is authoritative, including zero
	-- after a wrap; max(wall, stored) would eventually brick at the hard ceiling.
	local wall_seed = math.floor(epoch_microseconds % (TAG_SEQUENCE_LIMIT - TAG_BLOCK_SIZE))
	local first = stored == nil and wall_seed or (stored % TAG_SEQUENCE_LIMIT)
	local next_block = (first + TAG_BLOCK_SIZE) % TAG_SEQUENCE_LIMIT
	local ok, err = pcall(settings_api.set, TAG_RESERVATION_KEY, next_block)
	assert(ok, "adapters.synthetic_input: cannot reserve Quartz tag block - " .. tostring(err))
	remember_session_block(first)
	_sequence_next = first
	_sequence_remaining = TAG_BLOCK_SIZE
	return first
end


local first_sequence = reserve_sequence_block()
local SESSION_ID = string.format("%d:%d:%d", CURRENT_PROCESS_ID, first_sequence, session_tick)

local TRANSACTION_MARKER = {}
local RETAIN_MARKER = {}
local BATCH_MARKER = {}
local PACED_OWNER_MARKER = {}
local PHYSICAL_OWNER_MARKER = {}
local RESERVED_OWNER_MARKER = {}
local IDLE_WAITER_MARKER = {}
local ADMISSION_FENCE_MARKER = {}

local _generation = 0
local _active_transactions = {}
local _active_transaction_count = 0
local _idle_callbacks = {}
local _idle_waiter_cleanup = {}
local _admission_fence = nil
-- Native recurring handles remain lifecycle debt until stop() returns a
-- committed truthy result. A false/nil/throw keeps the exact handle strongly
-- owned and therefore keeps pause/reload admission closed while its own next
-- tick retries cleanup autonomously.
local _periodic_cleanup_count = 0
local _records = {}
local _oldest_tag = nil
local _newest_tag = nil
local _record_count = 0

-- Identity, rather than a numeric counter, is the production synchronization
-- primitive. Consumers compare this token allocation-free on every event and
-- reconcile their local cursor/logging state when a successful logical action
-- handoff, or a conservatively observed pre-reload action, replaces it. The
-- count exists for diagnostics and tests only.
local _action_epoch = {}
local _action_handoff_count = 0
local _action_handoff_time_ms = nil
local _stale_context_tags = {}
local _stale_context_ring = {}
local _stale_context_count = 0
local _stale_context_cursor = 1

local _pump_tap = nil
local _pending_by_trigger = {}
local _pending_count = 0
local _pending_loopbacks = {}
local _pending_loopback_count = 0
local _deferred_queue = {}
local _deferred_head = 1
local _deferred_tail = 0
local _broker_scheduled = false
local _broker_timer = nil
local _broker_generation = 0
local _inflight_batch = nil
local _pump_watchdog = nil
local _pump_watchdog_batch = nil
local _pump_watchdog_tag = nil

local _callback_stack = {}
local _transaction_stack = {}
local _action_listeners = {}
local _action_listener_count = 0
local _action_dispatcher = nil
local _action_listener_pending = false
local _action_dispatcher_failure_epoch = nil
local _action_dispatcher_failure_count = 0
local _deferred_diagnostics = {}
local _deferred_diagnostic_timer = nil
local _lifecycle_defer_depth = 0
local _deferred_lifecycle_calls = {}
local _deferred_lifecycle_head = 1
local _deferred_lifecycle_tail = 0
local _deferred_lifecycle_dispatcher = nil
local _deferred_lifecycle_backup_dispatcher = nil
local _deferred_lifecycle_fallback_timer = nil
local _deferred_post_callback_count = 0
local _owned_completion_depth = 0


--- Raises on programmer misuse while keeping the checks out of the event hot path.
--- @param tx table Candidate transaction.
--- @return table tx Valid transaction.
local function require_transaction(tx)
	assert(type(tx) == "table" and tx._marker == TRANSACTION_MARKER,
		"adapters.synthetic_input: invalid transaction")
	return tx
end


--- Validates a batch handle.
--- @param batch table Candidate batch.
--- @return table batch Valid batch.
local function require_batch(batch)
	assert(type(batch) == "table" and batch._marker == BATCH_MARKER,
		"adapters.synthetic_input: invalid batch")
	return batch
end


--- Runs user/async code without letting HS swallow the error invisibly.
--- @param label string Callback description.
--- @param fn function Callback.
--- @param ... any Callback arguments.
--- @return boolean ok
local function run_logged(label, fn, ...)
	local args = table.pack(...)
	local ok, err = xpcall(function()
		return fn(table.unpack(args, 1, args.n))
	end, debug.traceback)
	if not ok then
		pcall(Logger.error, LOG, "%s callback failed - %s.", label, tostring(err))
	end
	return ok
end


--- Queues a logger call outside CGEventTap. Error reporting must not perform the
--- logger's synchronous file open/write/flush on the callback it is protecting.
--- @param level string Logger method name.
--- @param format string Format string.
--- @param ... any Format arguments.
local function defer_diagnostic(level, format, ...)
	_deferred_diagnostics[#_deferred_diagnostics + 1] = {
		level = level, format = format, args = table.pack(...),
	}
	if _deferred_diagnostic_timer then return end
	local callback_ran = false
	local ok, timer_or_err = pcall(do_after, 0, function()
		callback_ran = true
		_deferred_diagnostic_timer = nil
		local pending = _deferred_diagnostics
		_deferred_diagnostics = {}
		for _, diagnostic in ipairs(pending) do
			local sink = Logger[diagnostic.level]
			if type(sink) == "function" then
				pcall(sink, LOG, diagnostic.format,
					table.unpack(diagnostic.args, 1, diagnostic.args.n))
			end
		end
	end)
	if ok and timer_or_err ~= nil and not callback_ran then
		_deferred_diagnostic_timer = timer_or_err
	elseif not ok or timer_or_err == nil then
		-- A diagnostic must never become a reason to block or recurse on the HID path.
		_deferred_diagnostics = {}
	end
end


--- Drains lifecycle callbacks only from a timer callback, never from CGEventTap.
local function drain_deferred_lifecycle()
	_deferred_lifecycle_fallback_timer = nil
	while _deferred_lifecycle_head <= _deferred_lifecycle_tail do
		local call = _deferred_lifecycle_calls[_deferred_lifecycle_head]
		_deferred_lifecycle_calls[_deferred_lifecycle_head] = nil
		_deferred_lifecycle_head = _deferred_lifecycle_head + 1
		if call.post_callback then
			_deferred_post_callback_count = _deferred_post_callback_count - 1
			assert(_deferred_post_callback_count >= 0,
				"adapters.synthetic_input: post-callback count underflow")
		end
		run_logged(call.label, call.callback,
			table.unpack(call.args, 1, call.args.n))
	end
	_deferred_lifecycle_head = 1
	_deferred_lifecycle_tail = 0
end


do
	local function create_lifecycle_dispatcher(role)
		local ok, dispatcher_or_err = pcall(new_delayed_timer, 0, function()
			drain_deferred_lifecycle()
		end)
		assert(ok and dispatcher_or_err ~= nil
			and type(dispatcher_or_err.start) == "function",
			"adapters.synthetic_input: deferred lifecycle " .. role
				.. " dispatcher is unavailable: " .. tostring(dispatcher_or_err))
		return dispatcher_or_err
	end
	-- Two independently created native handles avoid stranding callbacks when a
	-- single delayed-timer start fails transiently inside a physical-input fence.
	_deferred_lifecycle_dispatcher = create_lifecycle_dispatcher("primary")
	_deferred_lifecycle_backup_dispatcher = create_lifecycle_dispatcher("backup")
end


--- Starts the strongly retained post-eventtap dispatcher.
--- @return boolean started
local function start_deferred_lifecycle_dispatcher()
	local ok, result = pcall(_deferred_lifecycle_dispatcher.start,
		_deferred_lifecycle_dispatcher, 0)
	if ok and result ~= nil and result ~= false then return true end
	local backup_ok, backup_result = pcall(_deferred_lifecycle_backup_dispatcher.start,
		_deferred_lifecycle_backup_dispatcher, 0)
	if backup_ok and backup_result ~= nil and backup_result ~= false then return true end

	-- If both retained handles fail, make one independently retained doAfter
	-- attempt without waiting for another keystroke/transaction.
	if _deferred_lifecycle_fallback_timer == nil then
		local callback_ran = false
		local fallback_ok, timer_or_err = pcall(do_after, 0, function()
			callback_ran = true
			drain_deferred_lifecycle()
		end)
		if fallback_ok and timer_or_err ~= nil then
			if not callback_ran then _deferred_lifecycle_fallback_timer = timer_or_err end
			return true
		end
		defer_diagnostic("error", "Cannot start deferred lifecycle dispatcher - %s.",
			tostring(timer_or_err or backup_result or result))
	end
	return false
end


--- Enqueues one callback on the retained post-eventtap FIFO.
--- @param label string Diagnostic label.
--- @param callback function Callback.
--- @param args table Packed arguments.
--- @param post_callback boolean Whether this is accepted feature work counted
---        against the lifecycle admission boundary.
--- @param discard_on_refusal boolean|nil Remove this exact FIFO entry if no
---        dispatcher could be armed. Callers returning false must never leave a
---        callback that a later unrelated enqueue can revive.
--- @return boolean scheduled
local function enqueue_deferred_call(label, callback, args, post_callback, discard_on_refusal)
	_deferred_lifecycle_tail = _deferred_lifecycle_tail + 1
	local index = _deferred_lifecycle_tail
	_deferred_lifecycle_calls[index] = {
		label = label,
		callback = callback,
		args = args,
		post_callback = post_callback == true,
	}
	if post_callback then
		_deferred_post_callback_count = _deferred_post_callback_count + 1
	end
	if start_deferred_lifecycle_dispatcher() then return true end
	if post_callback or discard_on_refusal == true then
		-- A caller that receives false will pass the original key through. Remove
		-- this exact action atomically so a later enqueue cannot execute a callback
		-- whose ownership was explicitly refused.
		_deferred_lifecycle_calls[index] = nil
		_deferred_lifecycle_tail = index - 1
	end
	if post_callback then
		_deferred_post_callback_count = _deferred_post_callback_count - 1
	end
	return false
end


--- Schedules isolated work on the HS run loop.
--- @param delay number Delay in seconds.
--- @param label string Callback description.
--- @param fn function Callback.
--- @return table|userdata|nil timer Retained HS timer handle, or nil on failure.
local function schedule_after(delay, label, fn)
	local ok, timer_or_err = pcall(do_after, delay, function()
		run_logged(label, fn)
	end)
	if not ok or timer_or_err == nil then
		local detail = tostring(timer_or_err or "hs.timer.doAfter returned nil")
		-- This helper is used by collectors while a CGEventTap callback is still
		-- active. Always defer the diagnostic: synchronous logger sinks open and
		-- flush files, turning an already-failing timer allocation into a tap timeout.
		defer_diagnostic("error", "Cannot schedule %s callback - %s.", label, detail)
		return nil
	end
	return timer_or_err
end


--- Schedules work after the current eventtap callback has returned.
--- @param label string Callback description.
--- @param fn function Callback.
--- @return table|userdata|nil timer
local function schedule_zero(label, fn)
	return schedule_after(0, label, fn)
end


--- Runs one action after the current eventtap callback has returned and retains
--- its native timer until delivery. Callers may safely consume the physical
--- event only when this function returns true.
--- @param label string Diagnostic label.
--- @param fn function Callback.
--- @param ... any Callback arguments.
--- @return boolean scheduled
function M.defer_after_callback(label, fn, ...)
	assert(type(label) == "string" and label ~= "",
		"adapters.synthetic_input.defer_after_callback: label must be non-empty")
	assert(type(fn) == "function",
		"adapters.synthetic_input.defer_after_callback: fn must be a function")
	return enqueue_deferred_call(label, fn, table.pack(...), true)
end


--- Allocates one globally unique, self-describing Quartz user-data tag.
--- @param effect string action|replacement.
--- @param loopback boolean Whether keymap must deliberately process this signal.
--- @param physical_replay boolean|nil Whether this is a delayed physical event.
--- @return integer tag
local function next_tag(effect, loopback, physical_replay)
	if _sequence_remaining == 0 then reserve_sequence_block() end
	local sequence = _sequence_next
	_sequence_next = (_sequence_next + 1) % TAG_SEQUENCE_LIMIT
	_sequence_remaining = _sequence_remaining - 1
	local flags = effect == "action" and (1 << TAG_EFFECT_SHIFT) or 0
	-- replacement+loopback is intentionally reserved for a delayed physical
	-- replay. It remains self-describing after bounded-ledger eviction, yet can
	-- never acquire the action-loopback authority used by F16.
	if loopback or physical_replay then flags = flags | (1 << TAG_LOOPBACK_SHIFT) end
	return (TAG_NAMESPACE << TAG_NAMESPACE_SHIFT) | flags | sequence
end


--- Returns whether a decoded sequence belongs to a block reserved by this
--- module instance. A block may wrap the 38-bit ring, so membership uses modular
--- distance rather than a naive first/last comparison.
--- @param sequence number Decoded tag sequence.
--- @return boolean current_session
local function sequence_is_current_session(sequence)
	for index = 1, _session_block_count do
		local first = _session_block_starts[index]
		if ((sequence - first) % TAG_SEQUENCE_LIMIT) < TAG_BLOCK_SIZE then
			return true
		end
	end
	return false
end


local discard_record


--- Adds one immutable provenance record to the bounded ledger.
--- @param fields table Record fields.
--- @return number tag
local function register_record(fields)
	while _record_count >= M.RECORD_LIMIT do
		local candidate = assert(_oldest_tag,
			"adapters.synthetic_input: record ledger count/list mismatch")
		while candidate and _records[candidate]._loopback_pinned do
			candidate = _records[candidate]._next
		end
		assert(candidate ~= nil,
			"adapters.synthetic_input: record ledger exhausted by live loopback events")
		discard_record(candidate)
	end
	local tag = next_tag(fields.effect, fields.loopback == true,
		fields.physical_replay == true)
	fields.tag = tag
	fields.magic = M.MAGIC
	fields.session = SESSION_ID
	fields.source_pid = CURRENT_PROCESS_ID
	fields.seen_by = {}
	fields.seen_count = 0
	fields._loopback_pinned = fields.loopback == true
		and fields.physical_replay ~= true
	fields._previous = _newest_tag
	fields._next = nil
	_records[tag] = fields
	if _newest_tag then _records[_newest_tag]._next = tag else _oldest_tag = tag end
	_newest_tag = tag
	_record_count = _record_count + 1
	return tag
end


--- Deletes a record that was built but will never be dispatched.
--- @param tag number Record tag.
discard_record = function(tag)
	local record = _records[tag]
	if record == nil then return end
	if record._previous then
		_records[record._previous]._next = record._next
	else
		_oldest_tag = record._next
	end
	if record._next then
		_records[record._next]._previous = record._previous
	else
		_newest_tag = record._previous
	end
	_records[tag] = nil
	_record_count = _record_count - 1
end


--- Invokes a transaction lifecycle callback with logging isolation.
--- @param label string Callback description.
--- @param callback function Callback.
--- @param ... any Callback arguments.
local function invoke_lifecycle(label, callback, ...)
	if _owned_completion_depth > 0 then
		return run_logged(label, callback, ...)
	end
	-- Lifecycle APIs are intentionally always asynchronous. A terminal
	-- transaction or an idle adapter can be observed from a raw eventtap that did
	-- not enter an ambient collector (reload/quit is the important case). Running
	-- the callback inline there could reload Hammerspoon before Quartz receives the
	-- callback's return table.
	return enqueue_deferred_call(label, callback, table.pack(...), false)
end


--- Returns whether every accepted user producer and native cleanup owner is idle.
--- Post-eventtap work is counted from acceptance, before it has a chance to open
--- its transaction, closing the final idle-to-PAUSED admission race.
--- @return boolean idle
local function lifecycle_is_idle()
	return _active_transaction_count == 0
		and _deferred_post_callback_count == 0
		and _periodic_cleanup_count == 0
end


--- Adds an exact native periodic handle to process-wide cleanup debt once.
--- @param owner table Periodic/idle owner.
local function retain_periodic_cleanup(owner)
	if owner.cleanup_counted == true then return end
	owner.cleanup_counted = true
	_periodic_cleanup_count = _periodic_cleanup_count + 1
end


--- Removes an exact native periodic cleanup debt once.
--- @param owner table Periodic/idle owner.
local function release_periodic_cleanup(owner)
	if owner.cleanup_counted ~= true then return end
	owner.cleanup_counted = false
	_periodic_cleanup_count = _periodic_cleanup_count - 1
	assert(_periodic_cleanup_count >= 0,
		"adapters.synthetic_input: periodic cleanup count underflow")
end


--- Reads one candidate's stop capability without indexing false/native garbage.
--- @param candidate any Native recurring handle candidate.
--- @return function|nil stop_fn
local function periodic_stop_function(candidate)
	if type(candidate) ~= "table" and type(candidate) ~= "userdata" then return nil end
	local ok, stop_fn = pcall(function() return candidate.stop end)
	if not ok or type(stop_fn) ~= "function" then return nil end
	return stop_fn
end


--- Stops one exact recurring handle; refusal remains autonomously retryable.
--- @param owner table Periodic/idle owner.
--- @param label string Diagnostic label.
--- @return boolean settled
local function stop_periodic_handle(owner, label)
	local timer = owner.timer
	if timer == nil then
		release_periodic_cleanup(owner)
		return true
	end
	local stop_fn = periodic_stop_function(timer)
	if stop_fn == nil then
		retain_periodic_cleanup(owner)
		if owner.stop_error_reported ~= true then
			owner.stop_error_reported = true
			defer_diagnostic("error", "%s cleanup has no native stop capability.", label)
		end
		return false
	end
	local ok, result = pcall(stop_fn, timer)
	if ok and result ~= nil and result ~= false then
		owner.timer = nil
		owner.stop_error_reported = false
		release_periodic_cleanup(owner)
		return true
	end
	retain_periodic_cleanup(owner)
	if owner.stop_error_reported ~= true then
		owner.stop_error_reported = true
		defer_diagnostic("error", "%s cleanup remains pending - %s.",
			label, tostring(result))
	end
	return false
end


--- Retries release of an inert idle-waiter timer without re-running user work.
--- @param owner table Idle waiter owner.
--- @return boolean settled
local function stop_idle_waiter(owner)
	if type(owner) ~= "table" or owner._marker ~= IDLE_WAITER_MARKER then return true end
	local settled = stop_periodic_handle(owner, "Idle waiter timer")
	if settled then
		_idle_waiter_cleanup[owner] = nil
		return true
	end
	_idle_waiter_cleanup[owner] = true
	return false
end


--- Publishes one already-stopped idle waiter exactly once.
--- @param owner table Idle waiter owner.
local function finish_idle_waiter(owner)
	if owner.callback_delivered == true then return end
	owner.callback_delivered = true
	owner.settling = false
	run_logged("when_idle", owner.callback)
end


--- Completes one accepted active-state waiter exactly once.
--- @param owner table Idle waiter owner.
local function settle_idle_waiter(owner)
	if owner.active ~= true or not lifecycle_is_idle() then return end
	owner.active = false
	owner.settling = true
	if stop_idle_waiter(owner) then finish_idle_waiter(owner) end
end


--- Attempts the low-latency lifecycle wake for an already-owned idle waiter.
--- The periodic owner is acquired before this entry exists, so a dispatcher
--- refusal can discard the exact entry without losing an accepted callback.
--- @param owner table Idle waiter owner.
--- @return boolean scheduled
local function invoke_when_idle(owner)
	return enqueue_deferred_call("when_idle", function()
		settle_idle_waiter(owner)
	end, table.pack(), false, true)
end


--- Acquires an autonomous periodic wake before accepting an active-state waiter.
--- @param callback function Idle callback.
--- @return table|nil owner
local function acquire_idle_waiter(callback)
	local owner = {
		_marker = IDLE_WAITER_MARKER,
		callback = callback,
		active = false,
		settling = false,
		callback_delivered = false,
		timer = nil,
	}
	local installing = true
	local callback_ran = false
	local ok, timer_or_error = pcall(do_every, M.IDLE_WAITER_TICK_SEC, function()
		callback_ran = true
		if installing then return end
		if owner.settling == true then
			if stop_idle_waiter(owner) then finish_idle_waiter(owner) end
			return
		end
		if owner.active ~= true then
			stop_idle_waiter(owner)
			return
		end
		settle_idle_waiter(owner)
	end)
	installing = false
	local stop_fn = periodic_stop_function(timer_or_error)
	if not ok or stop_fn == nil or callback_ran then
		if stop_fn then
			owner.timer = timer_or_error
			stop_periodic_handle(owner, "Refused idle waiter timer")
		end
		defer_diagnostic("error", "Cannot acquire autonomous idle waiter - %s.",
			callback_ran and "timer ran inline" or tostring(timer_or_error))
		return nil
	end
	owner.timer = timer_or_error
	owner.active = true
	return owner
end


local try_complete
local schedule_broker
local fail_queued_batch
local start_paced_batch
local pump_physical_batch
local pump_reserved_batch
local start_reserved_batch
local start_unowned_fifo_head
local invalidate_paced_owner
local invalidate_periodic_owner
local run_pending_action_listeners
local start_action_dispatcher
local post_deferred_trigger


--- Stops the reusable pump watchdog only when it belongs to this batch.
--- @param batch table Deferred batch.
local function clear_pump_watchdog(batch)
	if _pump_watchdog_batch ~= batch then
		batch.watchdog = nil
		return
	end
	if _pump_watchdog and type(_pump_watchdog.stop) == "function" then
		pcall(_pump_watchdog.stop, _pump_watchdog)
	end
	_pump_watchdog_batch = nil
	_pump_watchdog_tag = nil
	batch.watchdog = nil
end


--- Tracks a globally posted loopback until it is posted or cancelled. Unlike a
--- broker batch it cannot be returned through the originating keymap tap, so a
--- physical event fence cancels it rather than allowing it to overtake input.
--- @param batch table Queued loopback batch.
local function track_pending_loopback(batch)
	assert(batch.mode == "loopback" and batch.status == "queued",
		"adapters.synthetic_input: only a queued loopback can become pending")
	assert(not batch.loopback_pending,
		"adapters.synthetic_input: loopback batch counted twice")
	_pending_loopbacks[batch] = true
	_pending_loopback_count = _pending_loopback_count + 1
	batch.loopback_pending = true
end


--- Removes a loopback from the physical-ordering fence exactly once.
--- @param batch table Loopback batch.
local function untrack_pending_loopback(batch)
	if not batch.loopback_pending then return end
	_pending_loopbacks[batch] = nil
	_pending_loopback_count = _pending_loopback_count - 1
	assert(_pending_loopback_count >= 0,
		"adapters.synthetic_input: pending loopback count underflow")
	batch.loopback_pending = false
end


--- Marks one batch terminal and publishes dispatch callbacks.
--- @param batch table Batch.
--- @param status string dispatched|failed|cancelled.
local function finish_batch(batch, status)
	if batch.status == "dispatched" or batch.status == "failed"
		or batch.status == "cancelled" then return end
	untrack_pending_loopback(batch)
	batch.status = status
	local tx = batch.tx
	if status == "failed" then
		tx.failed = true
		tx.failure = tx.failure or "synthetic batch dispatch failed"
	end
	tx.pending_batches = tx.pending_batches - 1
	assert(tx.pending_batches >= 0,
		"adapters.synthetic_input: transaction batch count underflow")
	for _, callback in ipairs(tx.dispatched_callbacks) do
		invoke_lifecycle("on_dispatched", callback, tx, batch, status)
	end
	try_complete(tx)
	if batch.mode == "deferred" and schedule_broker then schedule_broker() end
end


--- Completes a transaction exactly once when every ordering gate is clear.
--- @param tx table Transaction.
try_complete = function(tx)
	if tx.completed or not tx.sealed then return end
	if tx.retain_count ~= 0 or tx.pending_batches ~= 0 then return end
	tx.completed = true
	if _active_transactions[tx] then
		_active_transactions[tx] = nil
		_active_transaction_count = _active_transaction_count - 1
		assert(_active_transaction_count >= 0,
			"adapters.synthetic_input: active transaction count underflow")
	end
	local status = tx.cancelled and "cancelled" or (tx.failed and "failed" or "complete")
	tx.completion_status = status
	for _, callback in ipairs(tx.complete_callbacks) do
		invoke_lifecycle("on_complete", callback, tx, status)
	end
	if _active_transaction_count == 0 and #_idle_callbacks > 0 then
		local waiters = _idle_callbacks
		_idle_callbacks = {}
		for _, owner in ipairs(waiters) do
			if owner.active == true then
				-- The periodic timer remains the authoritative fallback if every
				-- one-shot dispatcher refuses this fast completion path.
				invoke_when_idle(owner)
			end
		end
	end
end


--- Schedules the terminal transition after Hammerspoon has consumed a return table.
--- @param batch table Handed-off batch.
local function confirm_dispatched_after_return(batch)
	local timer_handle
	local scheduled_ok, scheduled_result = pcall(schedule_zero,
		"synthetic dispatch", function()
			batch.confirm_timer = nil
			-- If listener timer allocation failed at handoff, this independent
			-- post-return timer is already outside every eventtap callback and is a
			-- safe no-next-key retry path for tooltip/keylogger reconciliation.
			if _action_listener_pending and start_action_dispatcher then
				start_action_dispatcher(0)
			end
			local finished_ok, finish_err = pcall(finish_batch, batch, "dispatched")
			if not finished_ok then
				defer_diagnostic("error", "Synthetic dispatch confirmation failed - %s.",
					tostring(finish_err))
			end
		end)
	if scheduled_ok then timer_handle = scheduled_result end
	batch.confirm_timer = timer_handle
	if not timer_handle then
		batch.tx.failed = true
		batch.tx.failure = "dispatch confirmation timer could not be scheduled"
		-- A failed timer cannot establish post-return ordering. Terminate the
		-- transaction as failed instead of hanging forever; completion clients
		-- must only continue their output chain for status == "complete".
		local finished_ok, finish_err = pcall(finish_batch, batch, "failed")
		if not finished_ok then
			defer_diagnostic("error", "Cannot terminate unconfirmed synthetic batch - %s.",
				tostring(finish_err))
		end
	end
end


--- Creates a transaction-owned batch.
--- @param tx table Transaction.
--- @param mode string callback|deferred (callback can commit to paced).
--- @param token table|nil Active retain token when opening after seal.
--- @return table batch
local function create_batch(tx, mode, token)
	require_transaction(tx)
	assert(not tx.cancelled and not tx.completed,
		"adapters.synthetic_input: transaction is no longer active")
	if tx.sealed then
		assert(type(token) == "table" and token._marker == RETAIN_MARKER
			and token.tx == tx and token.active,
			"adapters.synthetic_input: a sealed transaction needs its active retain token")
	end
	tx.next_batch_id = tx.next_batch_id + 1
	local batch = {
		_marker = BATCH_MARKER,
		tx = tx,
		id = tx.next_batch_id,
		mode = mode,
		status = "building",
		events = {},
		tags = {},
	}
	tx.pending_batches = tx.pending_batches + 1
	tx.batches[#tx.batches + 1] = batch
	return batch
end


--- Rolls back events created for a batch that will not be dispatched.
--- @param batch table Batch.
local function discard_batch_records(batch)
	if batch.collector and #batch.events > 0 then
		local discarded = {}
		for _, event in ipairs(batch.events) do discarded[event] = true end
		local kept = {}
		for _, event in ipairs(batch.collector.events) do
			if not discarded[event] then kept[#kept + 1] = event end
		end
		batch.collector.events = kept
	end
	for _, tag in ipairs(batch.tags) do discard_record(tag) end
	batch.tags = {}
	batch.events = {}
end


--- Starts the pre-created, strongly retained delayed listener dispatcher.
--- @param delay number Delay before retry.
--- @return boolean started
start_action_dispatcher = function(delay)
	if _action_dispatcher == nil then return false end
	local ok, result = pcall(_action_dispatcher.start, _action_dispatcher, delay)
	if not ok or result == nil or result == false then
		defer_diagnostic("error", "Cannot start synthetic action dispatcher - %s.",
			tostring(result))
		return false
	end
	return true
end


--- Runs the latest action epoch outside an eventtap callback.
--- Each listener acknowledges that exact token only after returning normally;
--- a transient failure is retried without blocking successful siblings.
run_pending_action_listeners = function()
	if not _action_listener_pending then return end
	local token = _action_epoch
	local handoff_time_ms = _action_handoff_time_ms
	local next_retry_sec = nil
	local listeners = {}
	for listener_id, listener in pairs(_action_listeners) do
		listeners[#listeners + 1] = {
			id = listener_id,
			callback = listener.callback,
			record = listener,
		}
	end
	table.sort(listeners, function(a, b) return a.id < b.id end)
	for _, listener in ipairs(listeners) do
		if listener.record.acknowledged_epoch ~= token then
			local record = listener.record
			if record.retry_epoch ~= token then
				record.retry_epoch = token
				record.failure_count = 0
				record.quarantined_epoch = nil
			end
			if record.quarantined_epoch ~= token then
				local ok = run_logged("action listener " .. listener.id,
					listener.callback, token, handoff_time_ms)
				if ok and _action_listeners[listener.id] == record then
					record.acknowledged_epoch = token
					record.failure_count = 0
				else
					record.failure_count = record.failure_count + 1
					if record.failure_count >= M.ACTION_LISTENER_MAX_ATTEMPTS then
						record.quarantined_epoch = token
						pcall(Logger.error, LOG,
							"Action listener '%s' failed %d times; quarantining this epoch until new input or a later action.",
							listener.id, record.failure_count)
					else
						local delay = math.min(M.ACTION_LISTENER_RETRY_SEC
							* (2 ^ (record.failure_count - 1)),
							M.ACTION_LISTENER_RETRY_MAX_SEC)
						next_retry_sec = next_retry_sec and math.min(next_retry_sec, delay) or delay
					end
				end
			end
		end
	end
	_action_listener_pending = false
	local latest_epoch = _action_epoch
	for _, listener in pairs(_action_listeners) do
		if listener.acknowledged_epoch ~= latest_epoch
			and listener.quarantined_epoch ~= latest_epoch then
			_action_listener_pending = true
			break
		end
	end
	if _action_listener_pending then
		-- A newer handoff that arrived while callbacks ran must reconcile
		-- immediately. Retries for the same epoch back off exponentially.
		start_action_dispatcher(latest_epoch ~= token and 0
			or (next_retry_sec or M.ACTION_LISTENER_RETRY_SEC))
	end
end


--- Advances the process-wide action epoch at a real or conservative handoff.
--- @return table token Newly published epoch token.
local function advance_action_epoch()
	_action_epoch = {}
	local time_ok, handoff_ticks = pcall(absolute_time)
	if time_ok and type(handoff_ticks) == "number" then
		_action_handoff_time_ms = handoff_ticks / 1000000
	else
		-- Diagnostic timing must never veto already-authorized user output.
		_action_handoff_time_ms = nil
	end
	_action_handoff_count = _action_handoff_count + 1
	if _action_listener_count > 0 then
		_action_listener_pending = true
		start_action_dispatcher(0)
	end
	return _action_epoch
end


--- Advances once for a pre-reload non-loopback tag, independently of how many
--- taps classify that same Quartz event. Both old actions and replacements can
--- move the cursor/text without updating this module instance's logical buffer.
--- The fixed-size ring bounds memory; if a tag reappears after eviction, another
--- conservative reset is safer than retaining stale state.
--- @param tag number Decoded full event tag.
--- @return boolean advanced
local function publish_stale_context_epoch(tag)
	if _stale_context_tags[tag] then return false end
	local limit = M.STALE_CONTEXT_DEDUPE_LIMIT
	assert(math.tointeger(limit) ~= nil and limit > 0,
		"adapters.synthetic_input: stale context dedupe limit must be positive")
	if _stale_context_count >= limit then
		local oldest = _stale_context_ring[_stale_context_cursor]
		if oldest ~= nil then _stale_context_tags[oldest] = nil end
	else
		_stale_context_count = _stale_context_count + 1
	end
	_stale_context_ring[_stale_context_cursor] = tag
	_stale_context_tags[tag] = true
	_stale_context_cursor = (_stale_context_cursor % limit) + 1
	advance_action_epoch()
	return true
end


--- Advances the process-wide action epoch once at irrevocable output handoff.
--- Multiple batches may belong to one retained transaction, but consumers only
--- need one invalidation for the whole logical action. Building, queueing,
--- cancellation and failed pump startup remain reversible and never advance it.
--- @param batch table Batch being handed to Quartz.
local function publish_action_epoch(batch)
	local tx = batch.tx
	if not batch.has_observable_action or tx.action_epoch_published then return end
	advance_action_epoch()
	tx.action_epoch_published = true
end


--- Creates and tags one key-down/key-up pair atomically.
--- @param batch table Destination batch.
--- @param modifiers table Modifier names.
--- @param key string|number Key name/code or one UTF-8 character.
--- @param unicode boolean Whether key is Unicode text.
--- @param loopback boolean Whether keymap must process this synthetic signal.
--- @return table down_event
--- @return table up_event
--- @return number down_tag
--- @return number up_tag
local function build_key_pair(batch, modifiers, key, unicode, loopback)
	local tx = batch.tx
	local ordinal = tx.next_ordinal + 1
	local down = assert(new_key_event(modifiers, unicode and 0 or key, true),
		"adapters.synthetic_input: newKeyEvent returned nil for keyDown")
	local up = assert(new_key_event(modifiers, unicode and 0 or key, false),
		"adapters.synthetic_input: newKeyEvent returned nil for keyUp")
	if unicode then
		assert(type(down.setUnicodeString) == "function" and type(up.setUnicodeString) == "function",
			"adapters.synthetic_input: setUnicodeString is unavailable")
		down:setUnicodeString(key)
		up:setUnicodeString(key)
	end
	assert(type(down.setProperty) == "function" and type(up.setProperty) == "function",
		"adapters.synthetic_input: event.setProperty is unavailable")
	local common = {
		generation = tx.generation,
		owner = tx.owner,
		effect = tx.effect,
		batch = batch.id,
		ordinal = ordinal,
		control = false,
		loopback = loopback == true,
	}
	local down_tag, up_tag
	local allocated, allocation_err = xpcall(function()
		down_tag = register_record({
			generation = common.generation, owner = common.owner, effect = common.effect,
			batch = common.batch, ordinal = common.ordinal, phase = "down", control = false,
			loopback = common.loopback,
		})
		up_tag = register_record({
			generation = common.generation, owner = common.owner, effect = common.effect,
			batch = common.batch, ordinal = common.ordinal, phase = "up", control = false,
			loopback = common.loopback,
		})
	end, debug.traceback)
	if not allocated then
		if down_tag then discard_record(down_tag) end
		if up_tag then discard_record(up_tag) end
		error("adapters.synthetic_input: cannot allocate key-pair tags - "
			.. tostring(allocation_err), 0)
	end
	local ok, err = pcall(function()
		down:setProperty(USER_DATA_PROPERTY, down_tag)
		up:setProperty(USER_DATA_PROPERTY, up_tag)
	end)
	if not ok then
		discard_record(down_tag)
		discard_record(up_tag)
		error("adapters.synthetic_input: cannot tag key pair - " .. tostring(err), 0)
	end
	tx.next_ordinal = ordinal
	if tx.effect == "action" and not loopback then
		batch.has_observable_action = true
		batch.first_observable_ordinal = batch.first_observable_ordinal or ordinal
	end
	return down, up, down_tag, up_tag
end


--- Appends a pair and mirrors it into an ambient collector when present.
--- @param batch table Destination batch.
--- @param modifiers table Modifiers.
--- @param key string|number Key.
--- @param unicode boolean Unicode mode.
--- @param collector table|nil Ambient callback collector.
--- @param loopback boolean|nil Whether keymap must process this signal.
local function append_pair(batch, modifiers, key, unicode, collector, loopback)
	local down, up, down_tag, up_tag = build_key_pair(batch, modifiers, key, unicode, loopback)
	batch.events[#batch.events + 1] = down
	batch.events[#batch.events + 1] = up
	batch.tags[#batch.tags + 1] = down_tag
	batch.tags[#batch.tags + 1] = up_tag
	if collector then
		collector.events[#collector.events + 1] = down
		collector.events[#collector.events + 1] = up
	end
end


--- Starts the tagged otherMouseUp pump only when deferred output is first requested.
--- @return boolean started
local function ensure_pump_started()
	if _pump_tap ~= nil then
		local enabled_ok, enabled = false, false
		if type(_pump_tap.isEnabled) == "function" then
			enabled_ok, enabled = pcall(_pump_tap.isEnabled, _pump_tap)
		end
		if enabled_ok and enabled == true then return true end
		Logger.warn(LOG, "Synthetic batch pump was disabled; recreating it before dispatch.")
		pcall(_pump_tap.stop, _pump_tap)
		_pump_tap = nil
	end
	local callback
	callback = function(event)
		local consume = false
		local events = nil
		local matched_batch = nil
		local ok, err = xpcall(function()
			if event == nil or type(event.getProperty) ~= "function" then return end
			local read_ok, tag = pcall(event.getProperty, event, USER_DATA_PROPERTY)
			if not read_ok or type(tag) ~= "number" then return end
			-- A delayed trigger may arrive after cancellation/watchdog cleanup removed
			-- its pending mapping and bounded enrichment record. Namespace + reserved
			-- event type still prove it is our broker control event, so consume it rather
			-- than leaking a phantom mouse-up into the frontmost application.
			if M.decode_tag(tag) == nil then return end
			consume = true
			-- The trigger tag mapping is stricter than re-reading the mouse button:
			-- each tag is unique and reserved by this adapter. A second native getter
			-- can fail after ownership was already proven; making it authoritative
			-- leaked the internal otherMouseUp and stranded the queued batch.
			local batch = _pending_by_trigger[tag]
			if batch == nil then return end
			matched_batch = batch
			_pending_by_trigger[tag] = nil
			batch.trigger_tag = nil
			_pending_count = _pending_count - 1
			assert(_pending_count >= 0,
				"adapters.synthetic_input: pending pump count underflow")
			batch.pending_counted = false
			clear_pump_watchdog(batch)
			if _inflight_batch == batch then _inflight_batch = nil end
			discard_record(tag) -- control tags are never payload provenance
			if batch.status ~= "queued" then
				consume = true
				return
			end
			publish_action_epoch(batch)
			batch.status = "handed_off"
			events = batch.events
			confirm_dispatched_after_return(batch)
		end, debug.traceback)
		if not ok then
			-- If callback processing failed, recover ownership cheaply enough to suppress
			-- a reserved trigger. An unreadable tag remains indeterminate and passes.
			if not consume and event and type(event.getProperty) == "function" then
				local tag_ok, tag = pcall(event.getProperty, event, USER_DATA_PROPERTY)
				consume = tag_ok and M.decode_tag(tag) ~= nil
				if consume then matched_batch = _pending_by_trigger[tag] end
			end
			defer_diagnostic("error", "Synthetic pump callback failed - %s.", tostring(err))
			if matched_batch and matched_batch.status == "queued" then
				fail_queued_batch(matched_batch,
					"pump callback failed - " .. tostring(err), true, true)
				return true
			end
			return consume, events
		end
		return consume, events
	end
	local ok, tap_or_err = pcall(new_tap, { OTHER_MOUSE_UP_EVENT_TYPE }, callback)
	if not ok or tap_or_err == nil or type(tap_or_err.start) ~= "function" then
		Logger.error(LOG, "Cannot create synthetic batch pump - %s.",
			tostring(tap_or_err or "eventtap.new returned no usable tap"))
		return false
	end
	local start_ok, start_err = pcall(tap_or_err.start, tap_or_err)
	if not start_ok then
		Logger.error(LOG, "Cannot start synthetic batch pump - %s.", tostring(start_err))
		return false
	end
	if type(tap_or_err.isEnabled) ~= "function" then
		Logger.error(LOG, "Cannot verify synthetic batch pump - isEnabled is unavailable.")
		pcall(tap_or_err.stop, tap_or_err)
		return false
	end
	local enabled_ok, enabled = pcall(tap_or_err.isEnabled, tap_or_err)
	if not enabled_ok or enabled ~= true then
		Logger.error(LOG, "Synthetic batch pump did not enable - %s.",
			tostring(enabled_ok and "CGEventTapCreate failed" or enabled))
		pcall(tap_or_err.stop, tap_or_err)
		return false
	end
	_pump_tap = tap_or_err
	Logger.success(LOG, "Synthetic batch pump started lazily.")
	return true
end


--- Removes the current broker-trigger claim while leaving its namespace as a
--- tombstone that the always-enabled pump will still consume if delivered late.
--- @param batch table Deferred batch.
local function discard_active_trigger(batch)
	local tag = batch.trigger_tag
	if tag == nil then return end
	_pending_by_trigger[tag] = nil
	batch.trigger_tag = nil
	discard_record(tag)
end


--- Terminates one queued deferred batch and optionally recreates its pump later.
--- @param batch table Queued batch.
--- @param reason string Logged failure reason.
--- @param reset_pump boolean Stop/drop the current pump before the next dispatch.
fail_queued_batch = function(batch, reason, reset_pump, quiet)
	if batch.status ~= "queued" then return end
	if batch.mode == "paced" and invalidate_paced_owner then
		invalidate_paced_owner(batch.paced_owner, "failed")
	elseif batch.mode == "physical" and batch.physical_owner then
		invalidate_periodic_owner(batch.physical_owner, "failed")
	elseif batch.mode == "reserved" and batch.reserved_owner then
		invalidate_periodic_owner(batch.reserved_owner, "failed")
	end
	clear_pump_watchdog(batch)
	if _inflight_batch == batch then _inflight_batch = nil end
	discard_active_trigger(batch)
	if batch.pending_counted then
		_pending_count = _pending_count - 1
		assert(_pending_count >= 0,
			"adapters.synthetic_input: pending pump count underflow")
		batch.pending_counted = false
	end
	if reset_pump and _pump_tap then
		pcall(_pump_tap.stop, _pump_tap)
		_pump_tap = nil
	end
	discard_batch_records(batch)
	batch.tx.failure = reason
	if quiet then
		defer_diagnostic("error", "Synthetic batch dispatch failed - %s.", reason)
	else
		Logger.error(LOG, "Synthetic batch dispatch failed - %s.", reason)
	end
	finish_batch(batch, "failed")
end


--- Registers/replaces a non-vetoing async listener for action reconciliation.
--- @param listener_id string Stable consumer ID.
--- @param callback function function(epoch_token, handoff_time_ms).
--- @param acknowledged_epoch table|nil Last token already reconciled by caller.
function M.register_action_listener(listener_id, callback, acknowledged_epoch)
	assert(type(listener_id) == "string" and listener_id ~= "",
		"adapters.synthetic_input.register_action_listener: listener_id must be non-empty")
	assert(type(callback) == "function",
		"adapters.synthetic_input.register_action_listener: callback must be a function")
	local previous = _action_listeners[listener_id]
	local is_new = previous == nil
	if is_new then
		assert(_action_listener_count < M.CONSUMER_LIMIT,
			"adapters.synthetic_input: action listener limit exhausted")
	end
	if _action_dispatcher == nil then
		local created_ok, dispatcher_or_err = pcall(new_delayed_timer, 0, function()
			local token = _action_epoch
			local ran_ok, ran_err = xpcall(run_pending_action_listeners, debug.traceback)
			if ran_ok then
				_action_dispatcher_failure_epoch = nil
				_action_dispatcher_failure_count = 0
			else
				if _action_dispatcher_failure_epoch ~= token then
					_action_dispatcher_failure_epoch = token
					_action_dispatcher_failure_count = 0
				end
				_action_dispatcher_failure_count = _action_dispatcher_failure_count + 1
				_action_listener_pending = true
				pcall(Logger.error, LOG, "Synthetic action dispatcher failed - %s.",
					tostring(ran_err))
				if _action_dispatcher_failure_count >= M.ACTION_LISTENER_MAX_ATTEMPTS then
					for _, record in pairs(_action_listeners) do
						if record.acknowledged_epoch ~= token then
							record.retry_epoch = token
							record.quarantined_epoch = token
						end
					end
					_action_listener_pending = false
					pcall(Logger.error, LOG,
						"Synthetic action dispatcher failed %d times; quarantining this epoch until a later action.",
						_action_dispatcher_failure_count)
				else
					local delay = math.min(M.ACTION_LISTENER_RETRY_SEC
						* (2 ^ (_action_dispatcher_failure_count - 1)),
						M.ACTION_LISTENER_RETRY_MAX_SEC)
					start_action_dispatcher(delay)
				end
			end
		end)
		assert(created_ok and dispatcher_or_err ~= nil
			and type(dispatcher_or_err.start) == "function"
			and type(dispatcher_or_err.stop) == "function",
			"adapters.synthetic_input: cannot create retained action dispatcher - "
				.. tostring(dispatcher_or_err))
		_action_dispatcher = dispatcher_or_err
	end
	_action_listeners[listener_id] = {
		callback = callback,
		-- Most new consumers start against current state. A stopped/restarted
		-- consumer may supply its last safe token so an action that happened while
		-- it was absent is scheduled instead of falsely acknowledged.
		acknowledged_epoch = acknowledged_epoch == nil and _action_epoch
			or acknowledged_epoch,
		retry_epoch = nil,
		failure_count = 0,
		quarantined_epoch = nil,
	}
	if is_new then _action_listener_count = _action_listener_count + 1 end
	if _action_listeners[listener_id].acknowledged_epoch ~= _action_epoch then
		_action_listener_pending = true
		if not start_action_dispatcher(0) then
			-- Registration is a commitment boundary for consumers such as keymap.
			-- A listener that needs immediate catch-up but owns no scheduled native
			-- dispatcher is not registered: restore the exact previous record/count
			-- so callers can fail closed and retry without exhausting the fixed slot
			-- budget one failed start at a time.
			_action_listeners[listener_id] = previous
			if is_new then _action_listener_count = _action_listener_count - 1 end
			_action_listener_pending = false
			for _, record in pairs(_action_listeners) do
				if record.acknowledged_epoch ~= _action_epoch
					and record.quarantined_epoch ~= _action_epoch then
					_action_listener_pending = true
					break
				end
			end
			if _action_listener_count == 0 then
				pcall(_action_dispatcher.stop, _action_dispatcher)
			end
			return false
		end
	end
	return true
end


--- Removes an async action listener; repeated removal is idempotent.
--- @param listener_id string Stable consumer ID.
--- @return boolean removed
function M.unregister_action_listener(listener_id)
	assert(type(listener_id) == "string" and listener_id ~= "",
		"adapters.synthetic_input.unregister_action_listener: listener_id must be non-empty")
	if _action_listeners[listener_id] == nil then return false end
	_action_listeners[listener_id] = nil
	_action_listener_count = _action_listener_count - 1
	if _action_listener_count == 0 then
		_action_listener_pending = false
		pcall(_action_dispatcher.stop, _action_dispatcher)
	end
	return true
end


--- Returns the opaque epoch token for successful logical action handoffs.
--- The same table is returned allocation-free until the next handoff.
--- @return table token
--- @return number|nil handoff_time_ms Monotonic timestamp of this epoch.
function M.current_action_epoch()
	return _action_epoch, _action_handoff_time_ms
end


--- Closes new synthetic admission only after every active transaction settled.
--- @param owner string Lifecycle owner label.
--- @return table|nil token Exact fence token, or nil when not idle/already fenced.
function M.acquire_admission_fence(owner)
	assert(type(owner) == "string" and owner ~= "",
		"adapters.synthetic_input.acquire_admission_fence: owner must be non-empty")
	if not lifecycle_is_idle() or _admission_fence ~= nil then return nil end
	local token = { _marker = ADMISSION_FENCE_MARKER, owner = owner, active = true }
	_admission_fence = token
	return token
end


--- Reopens synthetic admission for the exact lifecycle fence owner.
--- @param token table Token returned by acquire_admission_fence().
--- @return boolean released
function M.release_admission_fence(token)
	if type(token) ~= "table" or token._marker ~= ADMISSION_FENCE_MARKER
		or token.active ~= true or _admission_fence ~= token then return false end
	token.active = false
	_admission_fence = nil
	return true
end


--- Reports whether a user producer may open a new synthetic transaction.
--- @return boolean open
function M.admission_open()
	return _admission_fence == nil
end


--- Opens one synthetic transaction.
--- @param owner string Stable producer name.
--- @param effect string replacement|action.
--- @return table tx Opaque transaction.
function M.begin(owner, effect)
	assert(type(owner) == "string" and owner ~= "",
		"adapters.synthetic_input.begin: owner must be a non-empty string")
	assert(EFFECTS[effect] == true,
		"adapters.synthetic_input.begin: effect must be 'replacement' or 'action'")
	assert(_admission_fence == nil,
		"adapters.synthetic_input.begin: lifecycle admission is fenced")
	_generation = _generation + 1
	local tx = {
		_marker = TRANSACTION_MARKER,
		owner = owner,
		effect = effect,
		generation = _generation,
		sealed = false,
		cancelled = false,
		completed = false,
		failed = false,
		retain_count = 0,
		retains = {},
		pending_batches = 0,
		next_batch_id = 0,
		next_ordinal = 0,
		batches = {},
		dispatched_callbacks = {},
		complete_callbacks = {},
	}
	_active_transactions[tx] = true
	_active_transaction_count = _active_transaction_count + 1
	return tx
end


--- Retains a transaction across one deferred producer.
--- @param tx table Transaction.
--- @return table token Opaque retain token.
function M.retain(tx)
	tx = require_transaction(tx)
	assert(not tx.cancelled and not tx.completed and not tx.sealed,
		"adapters.synthetic_input.retain: transaction is not retainable")
	local token = { _marker = RETAIN_MARKER, tx = tx, active = true }
	tx.retains[token] = true
	tx.retain_count = tx.retain_count + 1
	return token
end


--- Releases one retain token; repeated release is an idempotent no-op.
--- @param tx table Transaction.
--- @param token table Retain token returned by retain().
--- @return boolean released True only on the first release.
function M.release(tx, token)
	tx = require_transaction(tx)
	assert(type(token) == "table" and token._marker == RETAIN_MARKER and token.tx == tx,
		"adapters.synthetic_input.release: token does not belong to transaction")
	if not token.active then return false end
	token.active = false
	tx.retains[token] = nil
	tx.retain_count = tx.retain_count - 1
	assert(tx.retain_count >= 0,
		"adapters.synthetic_input: transaction retain count underflow")
	try_complete(tx)
	return true
end


--- Registers a callback invoked after each batch is handed off or fails.
--- @param tx table Transaction.
--- @param callback function function(tx, batch, status).
function M.on_dispatched(tx, callback)
	tx = require_transaction(tx)
	assert(type(callback) == "function",
		"adapters.synthetic_input.on_dispatched: callback must be a function")
	assert(not tx.completed,
		"adapters.synthetic_input.on_dispatched: transaction already completed")
	tx.dispatched_callbacks[#tx.dispatched_callbacks + 1] = callback
end


--- Registers a once-only completion callback.
--- Registration after completion invokes it immediately with the final status.
--- @param tx table Transaction.
--- @param callback function function(tx, status).
function M.on_complete(tx, callback)
	tx = require_transaction(tx)
	assert(type(callback) == "function",
		"adapters.synthetic_input.on_complete: callback must be a function")
	if tx.completed then
		invoke_lifecycle("on_complete", callback, tx, tx.completion_status)
		return
	end
	tx.complete_callbacks[#tx.complete_callbacks + 1] = callback
end


--- Invokes callback when every adapter-created transaction is terminal.
--- Active callbacks are retained strongly until the final transaction closes.
--- @param callback function function().
function M.when_idle(callback)
	assert(type(callback) == "function",
		"adapters.synthetic_input.when_idle: callback must be a function")
	local owner = acquire_idle_waiter(callback)
	if owner == nil then return false end
	if lifecycle_is_idle() then
		-- The retained periodic owner is the acceptance authority. This one-shot is
		-- only a latency optimization and is removed exactly if dispatch refuses.
		invoke_when_idle(owner)
	else
		_idle_callbacks[#_idle_callbacks + 1] = owner
	end
	return true
end


--- Declares that no unretained producers will be added.
--- @param tx table Transaction.
--- @return boolean changed False when already sealed.
function M.seal(tx)
	tx = require_transaction(tx)
	if tx.sealed then return false end
	tx.sealed = true
	try_complete(tx)
	return true
end


--- Cancels undispatched work. Already-handed-off batches still reach terminal state.
--- @param tx table Transaction.
--- @return boolean changed False when already cancelled/completed.
function M.cancel(tx)
	tx = require_transaction(tx)
	if tx.cancelled or tx.completed then return false end
	-- Once a paced callback batch owns the consumed physical action, cancellation
	-- cannot retract its output. Refuse the whole cancellation before mutating the
	-- transaction; the serializer or the next physical fence must finish its exact
	-- suffix so pause/reload cannot strand a partial replacement on screen.
	for _, batch in ipairs(tx.batches) do
		local owner = batch.paced_owner
		if owner and owner.committed == true and batch.status == "queued" then
			defer_diagnostic("warn",
				"Cancellation deferred behind committed paced output for '%s'.",
				tostring(tx.owner))
			return false
		end
	end
	tx.cancelled = true
	tx.sealed = true
	for token in pairs(tx.retains) do token.active = false end
	tx.retains = {}
	tx.retain_count = 0
	for _, batch in ipairs(tx.batches) do
		if batch.status == "building" or batch.status == "queued" then
			if batch.paced_owner and invalidate_paced_owner then
				invalidate_paced_owner(batch.paced_owner, "cancelled")
			end
			if batch.physical_owner then
				invalidate_periodic_owner(batch.physical_owner, "cancelled")
			end
			if batch.reserved_owner then
				invalidate_periodic_owner(batch.reserved_owner, "cancelled")
			end
			if batch.loopback_timer and type(batch.loopback_timer.stop) == "function" then
				pcall(batch.loopback_timer.stop, batch.loopback_timer)
			end
			batch.loopback_timer = nil
			clear_pump_watchdog(batch)
			if _inflight_batch == batch then _inflight_batch = nil end
			discard_active_trigger(batch)
			if batch.pending_counted then
				_pending_count = _pending_count - 1
				assert(_pending_count >= 0,
					"adapters.synthetic_input: pending pump count underflow")
				batch.pending_counted = false
			end
			discard_batch_records(batch)
			finish_batch(batch, "cancelled")
		end
	end
	try_complete(tx)
	return true
end


--- Marks an active transaction failed without inventing successful completion.
--- Existing handed-off batches retain their exact settlement ownership; later
--- producers must stop their continuation before calling this boundary.
--- @param tx table Transaction.
--- @param detail any Root-cause diagnostic retained on the transaction.
--- @return boolean changed False when already terminal/cancelled/failed.
function M.fail(tx, detail)
	tx = require_transaction(tx)
	if tx.completed or tx.cancelled or tx.failed then return false end
	tx.failed = true
	tx.failure = tostring(detail or "synthetic producer failed")
	try_complete(tx)
	return true
end


--- Cancels the entire transaction after a high-level emitter fails. High-level
--- calls are atomic transaction operations: an explicit sibling must not survive
--- merely because the failure occurred in a later emitter.
--- @param tx table Transaction to cancel.
--- @param label string Diagnostic emitter label.
local function cancel_failed_emission(tx, label)
	local ok, err = pcall(M.cancel, tx)
	if not ok then
		defer_diagnostic("error", "Cannot cancel failed %s transaction - %s.",
			label, tostring(err))
	end
end


--- Opens a batch that will be returned by the originating eventtap callback.
--- @param tx table Transaction.
--- @param token table|nil Active retain token when tx is already sealed.
--- @return table batch
function M.begin_callback(tx, token)
	return create_batch(tx, "callback", token)
end


--- Opens a batch for timer/menu output through the lazy pump.
--- @param tx table Transaction.
--- @param token table|nil Active retain token when tx is already sealed.
--- @return table batch
function M.begin_batch(tx, token)
	return create_batch(tx, "deferred", token)
end


--- Appends one key-down/key-up pair.
--- @param batch table Batch.
--- @param modifiers table Modifier names.
--- @param key string|number Key name/code.
--- @return boolean success
function M.keyStroke(batch, modifiers, key)
	batch = require_batch(batch)
	assert(batch.status == "building",
		"adapters.synthetic_input.keyStroke: batch is not writable")
	assert(type(modifiers) == "table",
		"adapters.synthetic_input.keyStroke: modifiers must be a table")
	assert(type(key) == "string" or type(key) == "number",
		"adapters.synthetic_input.keyStroke: key must be a string or number")
	append_pair(batch, modifiers, key, false, batch.collector)
	return true
end


--- Appends a tagged loopback pair that keymap must deliberately process.
--- @param batch table Action batch.
--- @param modifiers table Modifier names.
--- @param key string|number Key name/code.
--- @return boolean success
function M.loopbackKeyStroke(batch, modifiers, key)
	batch = require_batch(batch)
	assert(batch.status == "building",
		"adapters.synthetic_input.loopbackKeyStroke: batch is not writable")
	assert(batch.tx.effect == "action",
		"adapters.synthetic_input.loopbackKeyStroke: loopback requires an action transaction")
	assert(type(modifiers) == "table",
		"adapters.synthetic_input.loopbackKeyStroke: modifiers must be a table")
	assert(type(key) == "string" or type(key) == "number",
		"adapters.synthetic_input.loopbackKeyStroke: key must be a string or number")
	append_pair(batch, modifiers, key, false, batch.collector, true)
	return true
end


--- Appends UTF-8 text as tagged key pairs, atomically for the whole string.
--- @param batch table Batch.
--- @param value string UTF-8 text.
--- @return boolean success
function M.keyStrokes(batch, value)
	batch = require_batch(batch)
	assert(batch.status == "building",
		"adapters.synthetic_input.keyStrokes: batch is not writable")
	assert(type(value) == "string",
		"adapters.synthetic_input.keyStrokes: value must be a string")
	local event_start = #batch.events
	local tag_start = #batch.tags
	local ordinal_start = batch.tx.next_ordinal
	local collector_start = batch.collector and #batch.collector.events or 0
	local observable_start = batch.has_observable_action
	local first_observable_start = batch.first_observable_ordinal
	local ok, err = xpcall(function()
		for _, codepoint in utf8.codes(value) do
			append_pair(batch, {}, utf8.char(codepoint), true, batch.collector)
		end
	end, debug.traceback)
	if ok then return true end
	for index = tag_start + 1, #batch.tags do discard_record(batch.tags[index]) end
	for index = #batch.tags, tag_start + 1, -1 do batch.tags[index] = nil end
	for index = #batch.events, event_start + 1, -1 do batch.events[index] = nil end
	if batch.collector then
		for index = #batch.collector.events, collector_start + 1, -1 do
			batch.collector.events[index] = nil
		end
	end
	batch.tx.next_ordinal = ordinal_start
	batch.has_observable_action = observable_start
	batch.first_observable_ordinal = first_observable_start
	defer_diagnostic("error", "Cannot build synthetic UTF-8 text - %s.", tostring(err))
	return false, err
end


--- Hands a direct batch to the originating callback and schedules completion.
--- @param batch table Callback batch.
--- @param consume boolean|nil Whether to suppress the original event.
--- @return boolean consume
--- @return table events
function M.finish_callback(batch, consume)
	batch = require_batch(batch)
	assert(batch.mode == "callback" and batch.collector == nil,
		"adapters.synthetic_input.finish_callback: batch is not standalone callback output")
	assert(batch.status == "building",
		"adapters.synthetic_input.finish_callback: batch already finished")
	if consume == nil then consume = #batch.events > 0 end
	assert(type(consume) == "boolean",
		"adapters.synthetic_input.finish_callback: consume must be boolean")
	-- All fallible caller-contract validation is complete before this handoff.
	publish_action_epoch(batch)
	batch.status = "handed_off"
	confirm_dispatched_after_return(batch)
	return consume, (#batch.events > 0 and batch.events or nil)
end


--- Resolves the oldest dispatchable batch without crossing a reserved successor.
--- A reservation is a barrier for every later transaction, including physical
--- input, but its own predecessor may still create deferred batches after the
--- ordinal was reserved. Those exact sibling batches are the sole legal
--- overtakers; otherwise the predecessor could never complete and open the
--- reservation.
--- @return table|nil batch
--- @return integer|nil index
local function next_dispatchable_batch()
	while _deferred_head <= _deferred_tail do
		local batch = _deferred_queue[_deferred_head]
		if not batch or batch.status ~= "queued" then
			_deferred_queue[_deferred_head] = nil
			_deferred_head = _deferred_head + 1
		elseif batch.mode == "reserved"
			and batch.reserved_owner.ready ~= true then
			local predecessor = batch.reserved_owner.predecessor
			for index = _deferred_head + 1, _deferred_tail do
				local candidate = _deferred_queue[index]
				if candidate and candidate.status == "queued"
					and candidate.mode == "deferred"
					and candidate.tx == predecessor then
					return candidate, index
				end
			end
			return nil, nil
		else
			return batch, _deferred_head
		end
	end
	_deferred_queue = {}
	_deferred_head = 1
	_deferred_tail = 0
	return nil, nil
end


--- Pops the batch selected by next_dispatchable_batch().
--- @return table|nil batch
local function pop_deferred_batch()
	local batch, index = next_dispatchable_batch()
	if batch == nil then return nil end
	_deferred_queue[index] = nil
	if index == _deferred_head then _deferred_head = _deferred_head + 1 end
	return batch
end


--- Lazily creates the single strongly retained watchdog used by the FIFO head.
--- @return boolean ready
local function ensure_pump_watchdog()
	if _pump_watchdog ~= nil then return true end
	local ok, handle_or_err = pcall(new_delayed_timer, M.PUMP_DELIVERY_TIMEOUT_SEC, function()
		local batch = _pump_watchdog_batch
		local trigger_tag = _pump_watchdog_tag
		local failure_counted = false
		_pump_watchdog_batch = nil
		_pump_watchdog_tag = nil
		if batch then batch.watchdog = nil end
		local ran_ok, ran_err = xpcall(function()
			if batch == nil or batch.status ~= "queued"
				or batch.trigger_tag ~= trigger_tag then return end
			discard_active_trigger(batch)
			batch.watchdog_failure_count = (batch.watchdog_failure_count or 0) + 1
			failure_counted = true
			if batch.watchdog_failure_count >= M.PUMP_WATCHDOG_MAX_FAILURES then
				fail_queued_batch(batch,
					"synthetic pump trigger repeatedly timed out", true)
				-- A fresh tap remains the tombstone sink for any retired button-31
				-- trigger that Quartz delivers after this payload became terminal.
				ensure_pump_started()
				return
			end
			pcall(Logger.warn, LOG,
				"Synthetic pump trigger was not observed within %.3f s; retrying without dropping output.",
				M.PUMP_DELIVERY_TIMEOUT_SEC)
			if not ensure_pump_started() then
				fail_queued_batch(batch, "synthetic pump could not restart", true)
				return
			end
			post_deferred_trigger(batch)
		end, debug.traceback)
		if not ran_ok then
			pcall(Logger.error, LOG, "Synthetic pump watchdog failed - %s.",
				tostring(ran_err))
			if batch and batch.status == "queued" then
				if not failure_counted then
					batch.watchdog_failure_count = (batch.watchdog_failure_count or 0) + 1
				end
				local recovered_ok, recovered_err = xpcall(function()
					discard_active_trigger(batch)
					if batch.watchdog_failure_count >= M.PUMP_WATCHDOG_MAX_FAILURES then
						fail_queued_batch(batch,
							"synthetic pump watchdog repeatedly failed", true)
						return
					end
					if not ensure_pump_started() then
						fail_queued_batch(batch, "synthetic pump could not recover", true)
						return
					end
					post_deferred_trigger(batch)
				end, debug.traceback)
				if not recovered_ok and batch.status == "queued" then
					pcall(Logger.error, LOG,
						"Synthetic pump watchdog recovery failed - %s.", tostring(recovered_err))
					pcall(fail_queued_batch, batch,
						"synthetic pump watchdog recovery failed", true)
				end
			end
		end
	end)
	if not ok or handle_or_err == nil
		or type(handle_or_err.start) ~= "function"
		or type(handle_or_err.stop) ~= "function" then
		Logger.error(LOG, "Cannot create retained synthetic pump watchdog - %s.",
			tostring(handle_or_err))
		return false
	end
	_pump_watchdog = handle_or_err
	return true
end


--- Arms the reusable watchdog before a trigger can become irrevocable.
--- @param batch table Deferred batch.
--- @param trigger_tag integer Trigger tag.
--- @return boolean armed
local function arm_pump_watchdog(batch, trigger_tag)
	if not ensure_pump_watchdog() then return false end
	assert(_pump_watchdog_batch == nil,
		"adapters.synthetic_input: pump watchdog is already armed")
	_pump_watchdog_batch = batch
	_pump_watchdog_tag = trigger_tag
	batch.watchdog = _pump_watchdog
	local ok, result = pcall(_pump_watchdog.start, _pump_watchdog,
		M.PUMP_DELIVERY_TIMEOUT_SEC)
	if ok and result ~= nil and result ~= false then return true end
	clear_pump_watchdog(batch)
	_pump_watchdog = nil
	Logger.error(LOG, "Cannot arm retained synthetic pump watchdog - %s.",
		tostring(result))
	return false
end


--- Posts one retryable documented Quartz broker trigger for the FIFO head.
--- A watchdog timeout means run-loop reordering, not lost user intent: retire
--- only that trigger claim and post a fresh one. Any late retired trigger is
--- consumed by the namespace/button tombstone path in the pump callback.
--- @param batch table Deferred batch.
post_deferred_trigger = function(batch)
	if batch.status ~= "queued" then return end
	local trigger_tag = nil
	local post_attempted = false
	local ok, err = xpcall(function()
		local position = assert(mouse_position(),
			"hs.mouse.absolutePosition returned nil")
		local trigger = assert(new_mouse_event(OTHER_MOUSE_UP_EVENT_TYPE, position, {}),
			"newMouseEvent returned nil for pump trigger")
		assert(type(trigger.setProperty) == "function" and type(trigger.post) == "function",
			"pump trigger event contract is incomplete")
		trigger_tag = register_record({
			generation = batch.tx.generation,
			owner = batch.tx.owner,
			effect = batch.tx.effect,
			batch = batch.id,
			ordinal = 0,
			phase = "trigger",
			control = true,
			loopback = false,
		})
		batch.trigger_tag = trigger_tag
		trigger:setProperty(MOUSE_BUTTON_PROPERTY, M.PUMP_MOUSE_BUTTON)
		trigger:setProperty(USER_DATA_PROPERTY, trigger_tag)
		_pending_by_trigger[trigger_tag] = batch
		assert(arm_pump_watchdog(batch, trigger_tag),
			"pump watchdog could not be armed before trigger post")
		post_attempted = true
		trigger:post() -- sole 1 ms post is broker-side, never in an input callback
	end, debug.traceback)
	if not ok then
		-- Once post() was attempted, its side effect is uncertain on a native
		-- exception. Keep the pump as a tombstone sink even while failing payload.
		fail_queued_batch(batch, tostring(err), not post_attempted)
	end
end


--- Starts one deferred FIFO batch after the broker timer fires.
--- @param batch table Deferred batch.
local function start_deferred_batch(batch)
	_inflight_batch = batch
	if batch.mode == "paced" then
		start_paced_batch(batch)
		return
	end
	if batch.mode == "physical" then
		pump_physical_batch(batch)
		return
	end
	if batch.mode == "reserved" then
		start_reserved_batch(batch)
		return
	end
	if not ensure_pump_started() then
		fail_queued_batch(batch, "synthetic pump could not start", true)
		return
	end
	post_deferred_trigger(batch)
end


--- Schedules at most one FIFO broker timer and never starts a tap synchronously.
--- @return boolean scheduled
schedule_broker = function()
	if _broker_scheduled or _inflight_batch ~= nil then return true end
	if next_dispatchable_batch() == nil then return true end
	_broker_scheduled = true
	_broker_generation = _broker_generation + 1
	local generation = _broker_generation
	_broker_timer = schedule_zero("synthetic FIFO broker", function()
		if generation ~= _broker_generation then return end
		_broker_timer = nil
		_broker_scheduled = false
		-- The generic zero-delay broker owns only ordinary deferred batches.
		-- Paced/physical/reserved heads already own their exact periodic wake;
		-- starting one here can place a zero turn immediately beside an overdue
		-- cadence tick and post two render turns back to back.
		start_unowned_fifo_head()
	end)
	if _broker_timer then return true end
	-- With no run-loop timer there is no safe fallback from an input callback.
	-- Fail only an ordinary head terminally so completion cannot hang. An owned
	-- head retains its periodic authority, so this generic timer refusal does not
	-- reject a later ordinary batch waiting behind it.
	_broker_scheduled = false
	_broker_generation = _broker_generation + 1
	local head = next_dispatchable_batch()
	if head and head.mode ~= "deferred" then return true end
	local batch = head and pop_deferred_batch() or nil
	if batch then fail_queued_batch(batch, "FIFO broker timer could not be scheduled", false) end
	-- finish_batch normally schedules the next sibling after the flag was cleared.
	-- Keep an explicit backstop for a future finish path that does not recurse.
	if _inflight_batch == nil then schedule_broker() end
	return false
end


--- Enqueues a deferred batch in the single FIFO broker.
--- Payload events are callback-returned and never individually posted.
--- @param batch table Deferred batch.
--- @return boolean scheduled
function M.dispatch(batch)
	batch = require_batch(batch)
	assert(batch.mode == "deferred",
		"adapters.synthetic_input.dispatch: callback batch cannot use the pump")
	assert(batch.status == "building",
		"adapters.synthetic_input.dispatch: batch already dispatched")
	if #batch.events == 0 then
		batch.status = "handed_off"
		confirm_dispatched_after_return(batch)
		return true
	end
	batch.status = "queued"
	_pending_count = _pending_count + 1
	batch.pending_counted = true
	_deferred_tail = _deferred_tail + 1
	_deferred_queue[_deferred_tail] = batch
	return schedule_broker()
end


--- Begins an ambient eventtap collector before a transaction necessarily exists.
--- @return table collector Opaque collector (diagnostic/test use only).
function M.enter_callback()
	local collector = {
		events = {},
		batches = {},
		batch_by_tx = {},
		implicit_transactions = {},
		delivery_mode = "callback",
	}
	_callback_stack[#_callback_stack + 1] = collector
	return collector
end


--- Returns whether one ambient collector is active on this Lua stack.
--- @return boolean active
function M.is_collecting_callback()
	return _callback_stack[#_callback_stack] ~= nil
end


--- Opens a private collector for an action invoked after its eventtap returned.
--- It exists only to let terminal output acquire one paced batch atomically; its
--- payload is globally posted by that owner and is never returned to Quartz.
--- @return table collector
function M.enter_paced_collection()
	assert(_callback_stack[#_callback_stack] == nil,
		"adapters.synthetic_input.enter_paced_collection: nested collector is forbidden")
	local collector = M.enter_callback()
	collector.delivery_mode = "paced"
	return collector
end


--- Closes a private paced collector after every non-cancelled batch committed.
--- No native call, callback, timer start, logger, or allocation occurs here.
--- @return boolean closed
function M.leave_paced_collection()
	local collector = _callback_stack[#_callback_stack]
	assert(collector ~= nil and collector.delivery_mode == "paced",
		"adapters.synthetic_input.leave_paced_collection: no private paced collector")
	for _, batch in ipairs(collector.batches) do
		local settled = batch.status == "cancelled" or batch.status == "failed"
		local owned = batch.mode == "paced" and batch.status == "queued"
			and batch.paced_owner and batch.paced_owner.committed == true
		assert(settled or owned,
			"adapters.synthetic_input.leave_paced_collection: output lacks paced ownership")
	end
	assert(#collector.events == 0,
		"adapters.synthetic_input.leave_paced_collection: unowned events remain")
	assert(next(collector.implicit_transactions) == nil,
		"adapters.synthetic_input.leave_paced_collection: implicit transactions are forbidden")
	_callback_stack[#_callback_stack] = nil
	return true
end


--- Returns the ambient transaction bound by with_transaction(), if any.
--- @return table|nil tx
function M.current_transaction()
	return _transaction_stack[#_transaction_stack]
end


--- Runs a nested emitter under one transaction and always restores prior scope.
--- @param tx table Transaction.
--- @param fn function Function to run.
--- @param ... any Arguments.
--- @return ... any Function results.
function M.with_transaction(tx, fn, ...)
	tx = require_transaction(tx)
	assert(type(fn) == "function",
		"adapters.synthetic_input.with_transaction: fn must be a function")
	assert(not tx.cancelled and not tx.completed,
		"adapters.synthetic_input.with_transaction: transaction is inactive")
	assert(not tx.sealed or tx.retain_count > 0,
		"adapters.synthetic_input.with_transaction: sealed transaction is not retained")
	local args = table.pack(...)
	_transaction_stack[#_transaction_stack + 1] = tx
	local results = table.pack(xpcall(function()
		return fn(table.unpack(args, 1, args.n))
	end, debug.traceback))
	_transaction_stack[#_transaction_stack] = nil
	if not results[1] then error(results[2], 0) end
	return table.unpack(results, 2, results.n)
end


--- Gets or creates the ambient callback batch for a transaction.
--- @param collector table Active collector.
--- @param tx table Transaction.
--- @return table batch
local function collector_batch(collector, tx)
	local batch = collector.batch_by_tx[tx]
	if batch then return batch end
	local token = nil
	if tx.sealed then
		for candidate in pairs(tx.retains) do token = candidate break end
	end
	batch = create_batch(tx, "callback", token)
	batch.collector = collector
	collector.batch_by_tx[tx] = batch
	collector.batches[#collector.batches + 1] = batch
	return batch
end


--- Resolves an explicit/ambient/implicit transaction for an emitter.
--- @param explicit_tx table|nil Optional explicit transaction.
--- @param deferred boolean True outside an eventtap callback.
--- @return table tx
--- @return boolean implicit
local function resolve_emission_transaction(explicit_tx, deferred)
	local tx = explicit_tx or M.current_transaction()
	if tx ~= nil then return require_transaction(tx), false end
	local owner = deferred and "ambient.deferred" or "ambient.callback"
	return M.begin(owner, "action"), true
end


--- Emits one key pair into the ambient collector or through the deferred pump.
--- Delays below one microsecond match Hammerspoon's native useconds_t truncation
--- and are therefore normalized to zero; >=1 us would alter ordering and is rejected.
--- @param modifiers table Modifiers.
--- @param key string|number Key.
--- @param delay number|nil Legacy Hammerspoon delay in microseconds.
--- @param explicit_tx table|nil Transaction override.
--- @return boolean success
function M.emit_key_stroke(modifiers, key, delay, explicit_tx)
	local collector = _callback_stack[#_callback_stack]
	local tx, implicit = resolve_emission_transaction(explicit_tx, collector == nil)
	local arguments_ok, arguments_err = xpcall(function()
		delay = delay or 0
		assert(type(delay) == "number" and delay >= 0 and delay < 1,
			"adapters.synthetic_input.emit_key_stroke: delay must be in [0, 1) microseconds")
	end, debug.traceback)
	if not arguments_ok then
		cancel_failed_emission(tx, "key-stroke")
		error(arguments_err, 0)
	end
	if collector then
		local ok, err = xpcall(function()
			local batch = collector_batch(collector, tx)
			M.keyStroke(batch, modifiers, key)
		end, debug.traceback)
		if not ok then
			cancel_failed_emission(tx, "key-stroke")
			error(err, 0)
		end
		if implicit and not tx.cancelled then collector.implicit_transactions[tx] = true end
		return true
	end
	local token = nil
	if tx.sealed then
		for candidate in pairs(tx.retains) do token = candidate break end
	end
	local batch
	local ok, err = xpcall(function()
		batch = M.begin_batch(tx, token)
		M.keyStroke(batch, modifiers, key)
	end, debug.traceback)
	if not ok then
		cancel_failed_emission(tx, "key-stroke")
		error(err, 0)
	end
	local dispatched_ok, scheduled = xpcall(function()
		return M.dispatch(batch)
	end, debug.traceback)
	if not dispatched_ok then
		cancel_failed_emission(tx, "key-stroke")
		error(scheduled, 0)
	end
	if not scheduled then cancel_failed_emission(tx, "key-stroke") end
	if implicit and not tx.cancelled then M.seal(tx) end
	return scheduled
end


--- Emits one action signal that is intentionally routed back through keymap.
--- @param modifiers table Modifiers.
--- @param key string|number Key.
--- @param delay number|nil Legacy delay; only values truncated to zero are valid.
--- @param explicit_tx table|nil Action transaction override.
--- @return boolean success
function M.emit_loopback_key_stroke(modifiers, key, delay, explicit_tx)
	local tx, implicit = resolve_emission_transaction(explicit_tx, true)
	local arguments_ok, arguments_err = xpcall(function()
		delay = delay or 0
		assert(type(delay) == "number" and delay >= 0 and delay < 1,
			"adapters.synthetic_input.emit_loopback_key_stroke: delay must be in [0, 1) microseconds")
		assert(tx.effect == "action",
			"adapters.synthetic_input.emit_loopback_key_stroke: transaction effect must be action")
	end, debug.traceback)
	if not arguments_ok then
		cancel_failed_emission(tx, "loopback key-stroke")
		error(arguments_err, 0)
	end
	local token = nil
	if tx.sealed then
		for candidate in pairs(tx.retains) do token = candidate break end
	end
	local batch
	local built_ok, build_err = xpcall(function()
		batch = create_batch(tx, "loopback", token)
		M.loopbackKeyStroke(batch, modifiers, key)
		batch.status = "queued"
		track_pending_loopback(batch)
	end, debug.traceback)
	if not built_ok then
		cancel_failed_emission(tx, "loopback key-stroke")
		error(build_err, 0)
	end
	local timer_handle
	timer_handle = schedule_zero("synthetic loopback dispatch", function()
		batch.loopback_timer = nil
		if batch.status ~= "queued" then return end
		local posted_count = 0
		local ok, err = xpcall(function()
			for index, event in ipairs(batch.events) do
				assert(type(event.post) == "function",
					"loopback event.post is unavailable")
				event:post()
				posted_count = index
			end
		end, debug.traceback)
		if not ok then
			-- Keep enrichment only for phases whose post returned successfully;
			-- never-emitted ghosts must not evict delayed live provenance later.
			for index = posted_count + 1, #batch.tags do discard_record(batch.tags[index]) end
			for index = #batch.tags, posted_count + 1, -1 do batch.tags[index] = nil end
			batch.tx.failure = tostring(err)
			Logger.error(LOG, "Cannot post synthetic loopback pair - %s.", tostring(err))
			finish_batch(batch, "failed")
			return
		end
		finish_batch(batch, "dispatched")
	end)
	batch.loopback_timer = timer_handle
	if not timer_handle then
		batch.tx.failure = "loopback dispatch timer could not be scheduled"
		discard_batch_records(batch)
		finish_batch(batch, "failed")
		cancel_failed_emission(tx, "loopback key-stroke")
	end
	if implicit and not tx.cancelled then M.seal(tx) end
	return timer_handle ~= nil
end


--- Emits UTF-8 text into the ambient collector or through the deferred pump.
--- @param value string UTF-8 text.
--- @param explicit_tx table|nil Transaction override.
--- @return boolean success
function M.emit_key_strokes(value, explicit_tx)
	if value == "" then return true end
	local collector = _callback_stack[#_callback_stack]
	local tx, implicit = resolve_emission_transaction(explicit_tx, collector == nil)
	local arguments_ok, arguments_err = xpcall(function()
		assert(type(value) == "string",
			"adapters.synthetic_input.emit_key_strokes: value must be a string")
	end, debug.traceback)
	if not arguments_ok then
		cancel_failed_emission(tx, "key-strokes")
		error(arguments_err, 0)
	end
	if collector then
		local built_ok, emitted = xpcall(function()
			local batch = collector_batch(collector, tx)
			return M.keyStrokes(batch, value)
		end, debug.traceback)
		if not built_ok then
			cancel_failed_emission(tx, "key-strokes")
			error(emitted, 0)
		end
		if not emitted then cancel_failed_emission(tx, "key-strokes") end
		if implicit and not tx.cancelled then collector.implicit_transactions[tx] = true end
		return emitted
	end
	local token = nil
	if tx.sealed then
		for candidate in pairs(tx.retains) do token = candidate break end
	end
	local batch
	local built_ok, emitted = xpcall(function()
		batch = M.begin_batch(tx, token)
		return M.keyStrokes(batch, value)
	end, debug.traceback)
	if not built_ok then
		cancel_failed_emission(tx, "key-strokes")
		error(emitted, 0)
	end
	if not emitted then
		cancel_failed_emission(tx, "key-strokes")
		return false
	end
	local dispatched_ok, scheduled = xpcall(function()
		return M.dispatch(batch)
	end, debug.traceback)
	if not dispatched_ok then
		cancel_failed_emission(tx, "key-strokes")
		error(scheduled, 0)
	end
	if not scheduled then cancel_failed_emission(tx, "key-strokes") end
	if implicit and not tx.cancelled then M.seal(tx) end
	return scheduled
end


local pump_paced_batch


--- Reads a stable process identity without making an optional PID accessor fail.
--- @param app userdata|table Application object.
--- @return integer|nil pid
local function application_pid(app)
	if app == nil or type(app.pid) ~= "function" then return nil end
	local ok, pid = pcall(app.pid, app)
	if not ok or type(pid) ~= "number" then return nil end
	return math.tointeger(pid)
end


--- Proves that an application-targeted serializer still owns its original PID.
--- A nil/global target needs no application liveness proof.
--- @param app userdata|table|nil Target application.
--- @param pid integer|nil Captured PID.
--- @return boolean live
local function target_is_live(app, pid)
	if app == nil then return true end
	if pid ~= nil and type(application_get) == "function" then
		local ok, current = pcall(application_get, pid)
		if not ok or current == nil then return false end
		local current_pid = application_pid(current)
		-- Once a concrete PID was captured, an unreadable replacement object is
		-- not proof that the same process still owns the target.
		return current_pid == pid
	end
	if type(app.isRunning) == "function" then
		local ok, running = pcall(app.isRunning, app)
		return ok and running == true
	end
	return true
end


--- Stops one pre-acquired periodic owner and fences any late callback.
--- @param owner table Paced/physical owner.
--- @param status string Terminal owner status.
invalidate_periodic_owner = function(owner, status)
	if type(owner) ~= "table" then return end
	if owner.cleanup_requested ~= true then
		owner.cleanup_requested = true
		owner.generation = owner.generation + 1
		owner.status = status
		owner.committed = false
	end
	return stop_periodic_handle(owner, "Periodic synthetic owner")
end


--- Discards provenance only for events that never reached Quartz.
--- @param batch table Serialized batch.
--- @param ordinal integer First unposted event.
local function discard_unposted_suffix(batch, ordinal)
	for index = ordinal, #batch.tags do discard_record(batch.tags[index]) end
	for index = #batch.tags, ordinal, -1 do batch.tags[index] = nil end
end


--- Returns the owner-specific invalidator for a serialized batch.
--- @param owner table Periodic owner.
--- @param status string Terminal status.
local function invalidate_serial_owner(owner, status)
	if owner._marker == PACED_OWNER_MARKER then
		invalidate_paced_owner(owner, status)
	else
		invalidate_periodic_owner(owner, status)
	end
end


--- Finishes a serialized batch exactly once and advances the global FIFO.
--- @param batch table Serialized batch.
--- @param owner table Periodic owner.
--- @param status string dispatched|failed.
--- @param detail string|nil Failure detail.
local function finish_serial_batch(batch, owner, status, detail)
	if batch.status ~= "queued" then return end
	if detail then batch.tx.failure = detail end
	if _inflight_batch == batch then _inflight_batch = nil end
	if batch.pending_counted then
		_pending_count = _pending_count - 1
		assert(_pending_count >= 0,
			"adapters.synthetic_input: pending serialized count underflow")
		batch.pending_counted = false
	end
	-- Establish any native stop debt before finish_batch can make the transaction
	-- appear idle and synchronously run lifecycle callbacks.
	invalidate_serial_owner(owner, status)
	_owned_completion_depth = _owned_completion_depth + 1
	local ok, err = xpcall(function() finish_batch(batch, status) end, debug.traceback)
	_owned_completion_depth = _owned_completion_depth - 1
	if not ok then
		defer_diagnostic("error", "Serialized batch settlement failed - %s.", tostring(err))
	end
	start_unowned_fifo_head()
end


--- Applies one bounded retry budget to an exact native post ordinal.
--- @param batch table Serialized batch.
--- @param owner table Periodic owner.
--- @param label string Diagnostic label.
--- @param detail any Native failure detail.
--- @return boolean retry True while the exact ordinal remains retryable.
local function retain_or_fail_post(batch, owner, label, detail)
	owner.post_failures = (owner.post_failures or 0) + 1
	owner.status = "queued"
	if owner.post_failures == 1 then
		pcall(Logger.warn, LOG, "%s refused at ordinal %d; exact suffix retained: %s.",
			label, owner.ordinal, tostring(detail))
	end
	if owner.post_failures < M.SERIAL_POST_MAX_ATTEMPTS then return true end
	local failure = string.format("%s permanently refused at ordinal %d after %d attempts: %s",
		label, owner.ordinal, owner.post_failures, tostring(detail))
	pcall(Logger.error, LOG, "%s.", failure)
	discard_unposted_suffix(batch, owner.ordinal)
	finish_serial_batch(batch, owner, "failed", failure)
	return false
end


--- Releases and invalidates one paced owner so an already-queued callback/timer
--- cannot replay its suffix after cancellation, adoption, failure, or completion.
--- @param owner table|nil Paced owner.
--- @param status string Terminal owner status.
invalidate_paced_owner = function(owner, status)
	if type(owner) ~= "table" or owner._marker ~= PACED_OWNER_MARKER then return end
	invalidate_periodic_owner(owner, status)
	local token = owner.token
	owner.token = nil
	if token and token.active then
		local released_ok, release_err = pcall(M.release, owner.tx, token)
		if not released_ok then
			defer_diagnostic("error", "Cannot release paced terminal owner - %s.",
				tostring(release_err))
		end
	end
end


--- Lets a pre-acquired periodic owner recover the global FIFO without allocating
--- anything after commit. Timer-zero normally starts the head immediately; if
--- that timer was accepted but never delivered, the first periodic tick fences
--- its generation and takes over. A late broker callback then becomes inert.
--- @param owner table Paced/physical owner.
local function wake_owned_fifo(owner)
	if owner.committed ~= true or owner.batch.status ~= "queued" then return end
	local batch = owner.batch
	if _inflight_batch == batch then
		if batch.mode == "paced" then pump_paced_batch(batch)
		elseif batch.mode == "reserved" then pump_reserved_batch(batch)
		else pump_physical_batch(batch) end
		return
	end
	if _inflight_batch ~= nil then return end
	local head = next_dispatchable_batch()
	-- A 5 ms physical/reserved owner may only wake its own ordinal. Borrowing its
	-- callback to pump a preceding 20 ms paced head shortens the Terminal render
	-- interval and makes cadence depend on unrelated FIFO siblings.
	if head ~= batch then return end
	if _broker_scheduled then
		_broker_generation = _broker_generation + 1
		_broker_scheduled = false
		if _broker_timer and type(_broker_timer.stop) == "function" then
			pcall(_broker_timer.stop, _broker_timer)
		end
		_broker_timer = nil
	end
	local next_batch = pop_deferred_batch()
	if next_batch then
		assert(next_batch == batch,
			"adapters.synthetic_input: periodic owner popped a foreign FIFO head")
		start_deferred_batch(next_batch)
	end
end


--- Acquires and starts the retry/cadence owner before any irreversible commit.
--- Its callback is the only post-commit scheduling authority: pump code merely
--- posts one render turn and returns, so timer allocation can never collapse the
--- Terminal pacing workaround into an immediate burst.
--- @param owner table Prepared owner.
--- @param interval number Seconds between ticks.
--- @return boolean acquired
local function acquire_periodic_owner(owner, interval)
	local callback_ran = false
	local generation = owner.generation
	local ok, timer_or_error = pcall(do_every, interval, function()
		callback_ran = true
		if owner.generation ~= generation or owner.cleanup_requested == true then
			stop_periodic_handle(owner, "Periodic synthetic owner")
			return
		end
		local ran, run_error = xpcall(function() wake_owned_fifo(owner) end, debug.traceback)
		if not ran then
			defer_diagnostic("error", "Periodic synthetic owner failed - %s.",
				tostring(run_error))
		end
	end)
	local stop_fn = periodic_stop_function(timer_or_error)
	if not ok or stop_fn == nil or callback_ran then
		if stop_fn then
			owner.timer = timer_or_error
			owner.cleanup_requested = true
			owner.generation = owner.generation + 1
			stop_periodic_handle(owner, "Refused periodic synthetic owner")
		end
		defer_diagnostic("error", "Cannot acquire periodic synthetic owner - %s.",
			callback_ran and "timer ran inline" or tostring(timer_or_error))
		return false
	end
	owner.timer = timer_or_error
	return true
end


--- Starts an ordinary deferred FIFO head from the already-owned run-loop turn.
--- Paced/physical siblings retain their own periodic wake and must not borrow an
--- immediate turn that would alter their cadence.
start_unowned_fifo_head = function()
	if _inflight_batch ~= nil then return end
	local candidate = next_dispatchable_batch()
	if candidate == nil or candidate.mode ~= "deferred" then return end
	local next_batch = pop_deferred_batch()
	if next_batch then start_deferred_batch(next_batch) end
end


--- Finishes one fully target-posted paced batch and advances the global FIFO.
--- @param batch table Paced batch.
local function finish_paced_batch(batch)
	local owner = batch.paced_owner
	finish_serial_batch(batch, owner, "dispatched")
end


--- Posts one complete delete pair per periodic render turn, then the replacement
--- suffix contiguously. A refusal advances no ordinal and returns to the already
--- running periodic owner; it never allocates or immediately retries post-commit.
--- @param batch table Paced batch.
pump_paced_batch = function(batch)
	if batch.status ~= "queued" then return end
	local owner = batch.paced_owner
	assert(type(owner) == "table" and owner._marker == PACED_OWNER_MARKER
		and owner.committed == true,
		"adapters.synthetic_input: queued paced batch has no committed owner")
	if owner.awaiting_settlement == true then
		finish_paced_batch(batch)
		return
	end
	if not target_is_live(owner.app, owner.target_pid) then
		local failure = string.format("Paced terminal target PID %s is no longer live",
			tostring(owner.target_pid or "unknown"))
		pcall(Logger.error, LOG, "%s; undispatched suffix dropped without rerouting.", failure)
		discard_unposted_suffix(batch, owner.ordinal)
		finish_serial_batch(batch, owner, "failed", failure)
		return
	end
	owner.status = "running"
	if not owner.handoff_published then
		publish_action_epoch(batch)
		owner.handoff_published = true
	end

	local stop_index = #owner.events
	if owner.ordinal <= owner.delete_event_count then
		-- If keyDown succeeded and keyUp refused, retry only that up event on the
		-- next tick; never open a second delete pair in the same render turn.
		stop_index = owner.ordinal + (owner.ordinal % 2 == 1 and 1 or 0)
		stop_index = math.min(stop_index, owner.delete_event_count)
	end
	for index = owner.ordinal, stop_index do
		local event = owner.events[index]
		local posted, post_error = xpcall(function()
			event:post(owner.app)
		end, debug.traceback)
		if not posted then
			retain_or_fail_post(batch, owner, "Paced terminal post", post_error)
			return
		end
		owner.post_failures = 0
		owner.irreversible = true
		owner.ordinal = index + 1
	end
	if owner.ordinal > #owner.events then
		-- Keep lifecycle effects one render turn behind the final native post. The
		-- already-running owner is the non-fallible completion capability.
		owner.awaiting_settlement = true
		owner.status = "queued"
	end
end


--- Starts the process-wide FIFO head after the originating callback returned.
--- @param batch table Paced batch.
start_paced_batch = function(batch)
	if batch.status ~= "queued" then
		if _inflight_batch == batch then _inflight_batch = nil end
		schedule_broker()
		return
	end
	pump_paced_batch(batch)
end


--- Posts a pre-built terminator only when its domain owner opens the gate.
--- The reserved FIFO position itself blocks later physical replays meanwhile.
--- @param batch table Reserved successor batch.
pump_reserved_batch = function(batch)
	if batch.status ~= "queued" then return end
	local owner = batch.reserved_owner
	assert(type(owner) == "table" and owner._marker == RESERVED_OWNER_MARKER
		and owner.committed == true,
		"adapters.synthetic_input: queued reserved successor has no committed owner")
	if owner.awaiting_settlement == true then
		finish_serial_batch(batch, owner, "dispatched")
		return
	end
	if owner.ready ~= true then return end
	if not target_is_live(owner.target_app, owner.target_pid) then
		local failure = string.format("Reserved target PID %s is no longer live",
			tostring(owner.target_pid or "unknown"))
		pcall(Logger.error, LOG, "%s; terminator was not rerouted.", failure)
		discard_unposted_suffix(batch, owner.ordinal)
		finish_serial_batch(batch, owner, "failed", failure)
		return
	end
	owner.status = "running"
	for index = owner.ordinal, #owner.events do
		local event = owner.events[index]
		local posted, post_error = xpcall(function()
			if owner.target_app then event:post(owner.target_app) else event:post() end
		end, debug.traceback)
		if not posted then
			retain_or_fail_post(batch, owner, "Reserved terminator post", post_error)
			return
		end
		owner.post_failures = 0
		owner.ordinal = index + 1
	end
	owner.awaiting_settlement = true
	owner.status = "queued"
end


--- Starts one reserved successor from its already-owned periodic wake.
--- @param batch table Reserved successor batch.
start_reserved_batch = function(batch)
	if batch.status ~= "queued" then
		if _inflight_batch == batch then _inflight_batch = nil end
		schedule_broker()
		return
	end
	pump_reserved_batch(batch)
end


--- Posts one owned physical replay only after every older FIFO batch settled.
--- Failure leaves the exact event and target under the pre-acquired periodic
--- owner; the next tick retries without allocating or waiting for new input.
--- @param batch table Physical replay batch.
pump_physical_batch = function(batch)
	if batch.status ~= "queued" then return end
	local owner = batch.physical_owner
	assert(type(owner) == "table" and owner._marker == PHYSICAL_OWNER_MARKER
		and owner.committed == true,
		"adapters.synthetic_input: queued physical replay has no committed owner")
	if owner.awaiting_settlement == true then
		finish_serial_batch(batch, owner, "dispatched")
		return
	end
	owner.status = "running"
	local posted, post_error = xpcall(function()
		owner.event:post()
	end, debug.traceback)
	if not posted then
		retain_or_fail_post(batch, owner, "Physical replay post", post_error)
		return
	end
	owner.post_failures = 0
	owner.ordinal = 2
	owner.awaiting_settlement = true
	owner.status = "queued"
end


--- Prepares reversible ownership of a callback transaction for terminal pacing.
--- This function allocates, validates, and arms every fallible native artifact
--- but neither detaches nor posts an event. The caller must seal, authorize, and
--- commit its local state before passing the owner to commit_collected_paced().
--- @param tx table Active transaction represented in the ambient collector.
--- @param delete_pairs number Number of leading Backspace pairs to pace.
--- @param delay_us number Inter-pair delay in microseconds.
--- @param app userdata|table Target hs.application.
--- @return table|nil owner Prepared owner, or nil outside a callback batch.
function M.prepare_collected_paced(tx, delete_pairs, delay_us, app)
	tx = require_transaction(tx)
	assert(type(delete_pairs) == "number" and delete_pairs >= 1
		and delete_pairs == math.floor(delete_pairs),
		"adapters.synthetic_input.prepare_collected_paced: delete_pairs must be a positive integer")
	assert(type(delay_us) == "number" and delay_us >= 1000,
		"adapters.synthetic_input.prepare_collected_paced: delay must be at least 1000 us")
	assert(app ~= nil,
		"adapters.synthetic_input.prepare_collected_paced: target application is required")

	local collector = _callback_stack[#_callback_stack]
	if collector == nil then return nil end
	local batch = collector.batch_by_tx[tx]
	if batch == nil or batch.status ~= "building" then return nil end
	assert(batch.mode == "callback" and batch.paced_owner == nil,
		"adapters.synthetic_input.prepare_collected_paced: callback batch already has an owner")
	local delete_event_count = delete_pairs * 2
	assert(#batch.events >= delete_event_count,
		"adapters.synthetic_input.prepare_collected_paced: collected batch is shorter than its deletion prefix")

	local selected = {}
	local events = {}
	for index, event in ipairs(batch.events) do
		assert((type(event) == "table" or type(event) == "userdata")
			and type(event.post) == "function",
			"adapters.synthetic_input.prepare_collected_paced: event cannot be posted")
		assert(not selected[event],
			"adapters.synthetic_input.prepare_collected_paced: duplicate event identity")
		selected[event] = true
		events[index] = event
	end
	local collector_snapshot = {}
	local remaining = {}
	local found = 0
	for index, event in ipairs(collector.events) do
		collector_snapshot[index] = event
		if selected[event] then
			found = found + 1
		else
			remaining[#remaining + 1] = event
		end
	end
	assert(found == #events,
		"adapters.synthetic_input.prepare_collected_paced: batch is not fully owned by its collector")

	local owner = {
		_marker = PACED_OWNER_MARKER,
		tx = tx,
		batch = batch,
		collector = collector,
		events = events,
		collector_snapshot = collector_snapshot,
		remaining = remaining,
		ordinal = 1,
		delete_event_count = delete_event_count,
		delay_sec = delay_us / 1000000,
		-- Worst-case owned cadence when the timer-zero wake is unavailable: one
		-- tick per delete pair, one for the contiguous suffix, and one settlement
		-- tick before transaction lifecycle callbacks may run.
		settlement_budget_sec = (delete_pairs + M.PACED_TRAILING_TICKS)
			* (delay_us / 1000000),
		app = app,
		target_pid = application_pid(app),
		generation = 0,
		status = "prepared",
		committed = false,
	}
	owner.token = M.retain(tx)
	batch.paced_owner = owner
	if not acquire_periodic_owner(owner, owner.delay_sec) then
		batch.paced_owner = nil
		invalidate_paced_owner(owner, "refused")
		return nil
	end
	-- The recurring owner is deliberately the sole paced wake. A second
	-- zero-delay callback could run immediately before or after an overdue timer
	-- tick and post two delete pairs without the required render interval.
	return owner
end


--- Returns the conservative post-callback settlement budget captured by a
--- prepared paced plan. Consumers use this immutable value to place their own
--- safety timers after, never inside, the serializer's native delivery window.
--- @param owner table Owner returned by prepare_collected_paced().
--- @return number seconds
function M.paced_settlement_budget(owner)
	assert(type(owner) == "table" and owner._marker == PACED_OWNER_MARKER,
		"adapters.synthetic_input.paced_settlement_budget: invalid owner")
	assert(type(owner.settlement_budget_sec) == "number"
		and owner.settlement_budget_sec > 0,
		"adapters.synthetic_input.paced_settlement_budget: owner has no valid budget")
	return owner.settlement_budget_sec
end


--- Authorizes a sealed prepared owner before any engine-side state mutation.
--- Every assertion and mutable-snapshot check belongs here so the later commit
--- is a guaranteed in-memory ownership transfer.
--- @param owner table Owner returned by prepare_collected_paced().
--- @return boolean authorized
function M.authorize_collected_paced(owner)
	assert(type(owner) == "table" and owner._marker == PACED_OWNER_MARKER,
		"adapters.synthetic_input.authorize_collected_paced: invalid owner")
	assert(owner.status == "prepared" and owner.committed == false,
		"adapters.synthetic_input.authorize_collected_paced: owner is not prepared")
	local tx = require_transaction(owner.tx)
	local batch = require_batch(owner.batch)
	local collector = _callback_stack[#_callback_stack]
	assert(tx.sealed == true and not tx.cancelled and not tx.completed,
		"adapters.synthetic_input.authorize_collected_paced: transaction is not sealed and active")
	assert(owner.token and owner.token.active,
		"adapters.synthetic_input.authorize_collected_paced: retain token is inactive")
	assert(owner.timer ~= nil,
		"adapters.synthetic_input.authorize_collected_paced: periodic owner is not live")
	assert(collector == owner.collector and batch.collector == collector
		and batch.status == "building" and batch.mode == "callback",
		"adapters.synthetic_input.authorize_collected_paced: callback ownership changed")
	assert(#batch.events == #owner.events
		and #collector.events == #owner.collector_snapshot,
		"adapters.synthetic_input.authorize_collected_paced: prepared output changed")
	for index, event in ipairs(owner.events) do
		assert(batch.events[index] == event,
			"adapters.synthetic_input.authorize_collected_paced: batch order changed")
	end
	for index, event in ipairs(owner.collector_snapshot) do
		assert(collector.events[index] == event,
			"adapters.synthetic_input.authorize_collected_paced: collector order changed")
	end
	owner.status = "authorized"
	return true
end


--- Commits an authorized owner to the process-wide FIFO after engine state.
--- All validation and native scheduling already committed in authorize; this
--- path invokes no callback, logger, timer, assertion, or application API.
--- @param owner table Owner authorized by authorize_collected_paced().
--- @return boolean committed Always true for an authorized owner.
function M.commit_collected_paced(owner)
	local batch = owner.batch
	local collector = owner.collector
	owner.committed = true
	owner.status = "queued"
	batch.mode = "paced"
	batch.status = "queued"
	_pending_count = _pending_count + 1
	batch.pending_counted = true
	_deferred_tail = _deferred_tail + 1
	_deferred_queue[_deferred_tail] = batch
	collector.events = owner.remaining
	owner.remaining = nil
	return true
end


--- Pre-builds a synthetic successor under an isolated collector and acquires its
--- autonomous FIFO owner before the originating physical key can be consumed.
--- @param predecessor table Replacement transaction that must complete first.
--- @param build function Constructs the exact terminator events.
--- @param target_app userdata|table|nil Terminal target; nil keeps global routing.
--- @return table|nil owner Prepared successor owner.
function M.prepare_reserved_successor(predecessor, build, target_app)
	predecessor = require_transaction(predecessor)
	assert(type(build) == "function",
		"adapters.synthetic_input.prepare_reserved_successor: build must be a function")
	local owner = {
		_marker = RESERVED_OWNER_MARKER,
		predecessor = predecessor,
		target_app = target_app,
		target_pid = application_pid(target_app),
		generation = 0,
		status = "preparing",
		committed = false,
		ready = false,
		ordinal = 1,
	}
	if not acquire_periodic_owner(owner, M.PERIODIC_OWNER_TICK_SEC) then return nil end

	local collector = M.enter_callback()
	local tx = nil
	local ok, build_error = xpcall(function()
		tx = M.begin("terminator_replay", "replacement")
		M.with_transaction(tx, function()
			assert(build() ~= false, "reserved successor construction refused")
		end)
		assert(#collector.batches == 1 and collector.batch_by_tx[tx] ~= nil,
			"reserved successor must build exactly one batch")
		local batch = collector.batch_by_tx[tx]
		assert(#batch.events > 0,
			"reserved successor constructed no events")
		assert(M.seal(tx) == true,
			"reserved successor transaction could not be sealed")
		owner.tx = tx
		owner.batch = batch
		owner.events = batch.events
		batch.reserved_owner = owner
	end, debug.traceback)
	assert(_callback_stack[#_callback_stack] == collector,
		"adapters.synthetic_input: reserved collector ownership changed")
	_callback_stack[#_callback_stack] = nil
	if not ok then
		if tx then pcall(M.cancel, tx) end
		invalidate_periodic_owner(owner, "refused")
		defer_diagnostic("error", "Cannot prepare reserved synthetic successor - %s.",
			tostring(build_error))
		return nil
	end
	owner.status = "prepared"
	return owner
end


--- Validates every reserved successor invariant before engine-state commit.
--- @param owner table Owner returned by prepare_reserved_successor().
--- @return boolean authorized
function M.authorize_reserved_successor(owner)
	assert(type(owner) == "table" and owner._marker == RESERVED_OWNER_MARKER,
		"adapters.synthetic_input.authorize_reserved_successor: invalid owner")
	assert(owner.status == "prepared" and owner.committed == false,
		"adapters.synthetic_input.authorize_reserved_successor: owner is not prepared")
	local predecessor = require_transaction(owner.predecessor)
	local tx = require_transaction(owner.tx)
	local batch = require_batch(owner.batch)
	-- Authorization is deliberately memory-only and may happen while the caller
	-- is still building the predecessor transaction.  FIFO readiness remains
	-- gated by predecessor completion, so publishing the ordinal here cannot
	-- overtake any of its later batches.
	assert(not predecessor.cancelled,
		"adapters.synthetic_input.authorize_reserved_successor: predecessor was cancelled")
	assert(tx.sealed == true and not tx.cancelled and not tx.completed,
		"adapters.synthetic_input.authorize_reserved_successor: transaction is inactive")
	assert(owner.timer ~= nil and batch.status == "building"
		and batch.mode == "callback" and #batch.events == #owner.events,
		"adapters.synthetic_input.authorize_reserved_successor: ownership changed")
	owner.status = "authorized"
	return true
end


--- Commits the already-authorized FIFO ordinal using memory-only mutations.
--- @param owner table Authorized reserved successor.
--- @return boolean committed
function M.commit_reserved_successor(owner)
	local batch = owner.batch
	owner.committed = true
	owner.status = "queued"
	batch.collector = nil
	batch.mode = "reserved"
	batch.status = "queued"
	_pending_count = _pending_count + 1
	batch.pending_counted = true
	_deferred_tail = _deferred_tail + 1
	_deferred_queue[_deferred_tail] = batch
	return true
end


--- Opens the reserved replay gate without posting on the caller's stack.
--- @param owner table Committed reserved successor.
--- @return boolean activated
function M.activate_reserved_successor(owner)
	if type(owner) ~= "table" or owner._marker ~= RESERVED_OWNER_MARKER
		or owner.committed ~= true or owner.batch.status ~= "queued" then return false end
	owner.ready = true
	return true
end


--- Registers a terminal observer for the reserved successor transaction.
--- @param owner table Prepared reserved successor.
--- @param callback function function(transaction, status).
--- @return boolean registered
function M.on_reserved_complete(owner, callback)
	assert(type(owner) == "table" and owner._marker == RESERVED_OWNER_MARKER,
		"adapters.synthetic_input.on_reserved_complete: invalid owner")
	return M.on_complete(owner.tx, callback)
end


--- Cancels a reversible reserved successor and leaves later callbacks inert.
--- @param owner table Prepared/queued reserved successor.
--- @return boolean cancelled
function M.cancel_reserved_successor(owner)
	if type(owner) ~= "table" or owner._marker ~= RESERVED_OWNER_MARKER then return false end
	if owner.ordinal > 1 then return false end
	local batch = owner.batch
	if owner.committed == true and batch.status == "queued" then
		if _inflight_batch == batch then _inflight_batch = nil end
		if batch.pending_counted then
			_pending_count = _pending_count - 1
			batch.pending_counted = false
		end
		discard_unposted_suffix(batch, 1)
		invalidate_periodic_owner(owner, "cancelled")
		_owned_completion_depth = _owned_completion_depth + 1
		pcall(finish_batch, batch, "cancelled")
		_owned_completion_depth = _owned_completion_depth - 1
		start_unowned_fifo_head()
		return true
	end
	invalidate_periodic_owner(owner, "cancelled")
	local ok, cancelled = pcall(M.cancel, owner.tx)
	return ok and cancelled == true
end


--- Prepares one exact global physical replay without mutating the live FIFO.
--- Every native failure rolls back its private transaction and provenance.
--- @param event userdata|table Physical event being intercepted.
--- @return table|nil owner Prepared replay owner.
local function prepare_physical_replay(event)
	assert(event ~= nil and type(event.copy) == "function",
		"adapters.synthetic_input: physical event.copy is unavailable")
	local owner = {
		_marker = PHYSICAL_OWNER_MARKER,
		generation = 0,
		status = "preparing",
		committed = false,
		ordinal = 1,
	}
	if not acquire_periodic_owner(owner, M.PERIODIC_OWNER_TICK_SEC) then return nil end
	local tx = nil
	local batch = nil
	local ok, replay_or_error = xpcall(function()
		local replay = assert(event:copy(),
			"adapters.synthetic_input: physical event.copy returned nil")
		assert(type(replay.setProperty) == "function" and type(replay.post) == "function",
			"adapters.synthetic_input: copied physical event contract is incomplete")
		tx = M.begin("physical_input_fence", "replacement")
		batch = create_batch(tx, "physical")
		owner.tx = tx
		owner.batch = batch
		owner.event = replay
		batch.physical_owner = owner
		local tag = register_record({
			generation = tx.generation,
			owner = tx.owner,
			effect = "replacement",
			batch = batch.id,
			ordinal = 1,
			phase = "physical",
			control = false,
			loopback = false,
			physical_replay = true,
		})
		batch.events[1] = replay
		batch.tags[1] = tag
		replay:setProperty(USER_DATA_PROPERTY, tag)
		assert(M.seal(tx) == true,
			"adapters.synthetic_input: physical replay transaction could not be sealed")
	end, debug.traceback)
	if not ok then
		invalidate_periodic_owner(owner, "refused")
		if tx then pcall(M.cancel, tx) end
		defer_diagnostic("error", "Cannot own physical-input replay - %s.",
			tostring(replay_or_error))
		return nil
	end
	owner.status = "prepared"
	return owner
end


--- Commits a prepared physical replay behind the already-preserved FIFO suffix.
--- @param owner table Owner returned by prepare_physical_replay().
local function commit_physical_replay(owner)
	local batch = owner.batch
	batch.status = "queued"
	_pending_count = _pending_count + 1
	batch.pending_counted = true
	_deferred_tail = _deferred_tail + 1
	_deferred_queue[_deferred_tail] = batch
	owner.committed = true
	owner.status = "queued"
end


--- Builds an immutable adoption plan before touching the live FIFO. Allocation
--- and validation happen here so a later commit cannot destroy the only copy of
--- queued user output and then fail while assembling its return table.
--- @param excluded_collector table|nil Current collector whose paced batch must
---        remain queued until this callback returns.
--- @return table adoption { batches, events, event_groups, remaining_batches }.
local function prepare_pending_adoption(excluded_collector)
	local all_batches = {}
	local seen = {}
	if _inflight_batch and _inflight_batch.status == "queued" then
		all_batches[#all_batches + 1] = _inflight_batch
		seen[_inflight_batch] = true
	end
	for index = _deferred_head, _deferred_tail do
		local batch = _deferred_queue[index]
		if batch and batch.status == "queued" and not seen[batch] then
			all_batches[#all_batches + 1] = batch
			seen[batch] = true
		end
	end
	if #all_batches == 0 then
		return { batches = {}, events = nil, event_groups = {}, remaining_batches = {} }
	end
	assert(#all_batches == _pending_count,
		"adapters.synthetic_input: pending FIFO count cannot be adopted atomically")
	for _, batch in ipairs(all_batches) do
		assert(batch.status == "queued" and batch.pending_counted == true
			and type(batch.events) == "table" and #batch.events > 0,
			"adapters.synthetic_input: queued batch is not adoption-ready")
	end

	local batches = {}
	local remaining_batches = {}
	local excluded = false
	local reserved_predecessor = nil
	for _, batch in ipairs(all_batches) do
		-- An unopened reservation is a barrier for unrelated/physical input, but
		-- not for deferred batches that still belong to its own predecessor. Those
		-- batches were intentionally allowed to be created after the ordinal was
		-- reserved and must be able to complete the transaction that opens it.
		if reserved_predecessor ~= nil then
			if batch.mode == "deferred" and batch.tx == reserved_predecessor then
				batches[#batches + 1] = batch
			else
				remaining_batches[#remaining_batches + 1] = batch
			end
		elseif excluded then
			remaining_batches[#remaining_batches + 1] = batch
		else
			local owner = batch.paced_owner
			if excluded_collector ~= nil and batch.mode == "paced"
				and owner and owner.collector == excluded_collector then
				excluded = true
			end
			if not excluded and (batch.mode == "paced" or batch.mode == "physical"
				or batch.mode == "reserved") then
				-- Paced output may never be flattened into a callback-return table:
				-- doing so removes its inter-pair render turns. Physical replay must
				-- remain globally posted so every tap observes it.
				excluded = true
				if batch.mode == "reserved"
					and batch.reserved_owner.ready ~= true then
					reserved_predecessor = batch.reserved_owner.predecessor
				end
			end
			if excluded then
				remaining_batches[#remaining_batches + 1] = batch
			else
				batches[#batches + 1] = batch
			end
		end
	end

	local event_groups = {}
	local event_count = 0
	for index, batch in ipairs(batches) do
		local group = batch.events
		if batch.mode == "paced" then
			local owner = batch.paced_owner
			assert(owner and owner._marker == PACED_OWNER_MARKER
				and owner.committed == true and owner.ordinal <= #owner.events,
				"adapters.synthetic_input: paced batch has no adoptable suffix")
			if owner.ordinal > 1 then
				group = {}
				for event_index = owner.ordinal, #owner.events do
					group[#group + 1] = owner.events[event_index]
				end
			end
		end
		event_groups[index] = group
		event_count = event_count + #group
	end

	local events = nil
	if #batches == 1 then
		events = event_groups[1]
	elseif #batches > 1 then
		events = {}
		for _, group in ipairs(event_groups) do
			for _, event in ipairs(group) do events[#events + 1] = event end
		end
		assert(#events == event_count,
			"adapters.synthetic_input: adoption event count changed during preparation")
	end
	return {
		batches = batches,
		events = events,
		event_groups = event_groups,
		remaining_batches = remaining_batches,
	}
end


--- Commits a fully prepared FIFO adoption without allocating or invoking user code.
--- A trigger already posted for the in-flight head becomes a namespace tombstone
--- consumed by the still-enabled pump, so the payload cannot replay twice.
--- @param adoption table Result of prepare_pending_adoption().
local function commit_pending_adoption(adoption)
	if #adoption.batches == 0 then return end

	local has_remaining = #adoption.remaining_batches > 0
	if not has_remaining then
		if _broker_timer and type(_broker_timer.stop) == "function" then
			pcall(_broker_timer.stop, _broker_timer)
		end
		_broker_timer = nil
		_broker_scheduled = false
	end
	local selected = {}
	for _, batch in ipairs(adoption.batches) do selected[batch] = true end
	if _inflight_batch and selected[_inflight_batch] then _inflight_batch = nil end
	_deferred_queue = {}
	_deferred_head = 1
	_deferred_tail = 0
	for _, batch in ipairs(adoption.remaining_batches) do
		if batch ~= _inflight_batch then
			_deferred_tail = _deferred_tail + 1
			_deferred_queue[_deferred_tail] = batch
		end
	end

	for index, batch in ipairs(adoption.batches) do
		if batch.mode == "paced" then
			batch.events = adoption.event_groups[index]
			invalidate_paced_owner(batch.paced_owner, "adopted")
			batch.paced_owner = nil
		end
		clear_pump_watchdog(batch)
		discard_active_trigger(batch)
		if batch.pending_counted then
			_pending_count = _pending_count - 1
			assert(_pending_count >= 0,
				"adapters.synthetic_input: pending adoption count underflow")
			batch.pending_counted = false
		end
	end
end


--- Detaches every older deferred payload so a later callback cannot overtake it.
--- @param excluded_collector table|nil Current callback's paced owner.
--- @return table adoption Prepared and committed FIFO payload.
local function adopt_pending_deferred_batches(excluded_collector)
	local adoption = prepare_pending_adoption(excluded_collector)
	commit_pending_adoption(adoption)
	return adoption
end


--- Finalizes a batch whose event table is about to be returned to Quartz.
--- Internal diagnostics must not veto already-authorized output.
--- @param batch table Callback or adopted deferred batch.
local function handoff_returned_batch(batch)
	local ok, err = xpcall(function()
		publish_action_epoch(batch)
		batch.status = "handed_off"
		confirm_dispatched_after_return(batch)
	end, debug.traceback)
	if ok then return end
	if _lifecycle_defer_depth > 0 then
		defer_diagnostic("error", "Synthetic callback handoff bookkeeping failed - %s.",
			tostring(err))
	else
		pcall(Logger.error, LOG, "Synthetic callback handoff bookkeeping failed - %s.",
			tostring(err))
	end
	batch.status = "handed_off"
	batch.tx.failed = true
	batch.tx.failure = batch.tx.failure or tostring(err)
	pcall(finish_batch, batch, "failed")
end


--- Claims every eligible older deferred payload at the first physical-input tap.
--- Paced output keeps its cadence and exact target. When such output remains,
--- the original event is copied into the global FIFO and the caller consumes the
--- original; the tagged replay later re-enters every tap as physical input.
--- The empty fast path is one integer comparison on every ordinary input event.
--- @param event userdata|table Physical event to fence.
--- @return table|nil fence { events, batches, consume_original }, or nil.
function M.claim_physical_fence(event)
	if _pending_count == 0 and _pending_loopback_count == 0 then return nil end
	_lifecycle_defer_depth = _lifecycle_defer_depth + 1
	local ok, adoption_or_err = xpcall(function()
		local adoption
		if _pending_count > 0 then
			adoption = prepare_pending_adoption()
		else
			adoption = { batches = {}, events = nil, remaining_batches = {} }
		end
		local physical_owner = nil
		if #adoption.remaining_batches > 0 then
			physical_owner = prepare_physical_replay(event)
			if physical_owner == nil then return nil end
		end

		-- No FIFO node, trigger claim, or transaction acknowledgement mutates until
		-- the exact physical copy, tag, and autonomous owner all exist.
		commit_pending_adoption(adoption)
		if physical_owner then
			commit_physical_replay(physical_owner)
			adoption.consume_original = true
		end

		-- A loopback must re-enter the keymap tap globally; returning it from that
		-- same tap would bypass the consumer. Once real input has overtaken the
		-- timer, the only safe outcome is cancellation. Collect transactions first
		-- because M.cancel() removes every sibling loopback from this set.
		local loopback_transactions = {}
		local cancelled_loopbacks = _pending_loopback_count
		for batch in pairs(_pending_loopbacks) do
			if batch.status == "queued" then loopback_transactions[batch.tx] = true end
		end
		for tx in pairs(loopback_transactions) do M.cancel(tx) end
		assert(_pending_loopback_count == 0,
			"adapters.synthetic_input: physical fence left a loopback pending")
		adoption.cancelled_loopbacks = cancelled_loopbacks
		for _, batch in ipairs(adoption.batches) do handoff_returned_batch(batch) end
		if #adoption.batches == 0 and cancelled_loopbacks == 0
			and adoption.consume_original ~= true then return nil end
		return adoption
	end, debug.traceback)
	_lifecycle_defer_depth = _lifecycle_defer_depth - 1
	if not ok then
		defer_diagnostic("error", "Cannot claim synthetic physical-input fence - %s.",
			tostring(adoption_or_err))
		return nil
	end
	return adoption_or_err
end


--- Leaves the current ambient callback and returns its ordered event table.
--- Dispatch/completion callbacks are deferred to timer zero for correct ordering.
--- @param consume boolean|nil Whether to suppress the original event.
--- @return boolean consume
--- @return table events
function M.leave_callback(consume)
	local collector = _callback_stack[#_callback_stack]
	assert(collector ~= nil,
		"adapters.synthetic_input.leave_callback: no active callback collector")
	if consume == nil then consume = #collector.events > 0 end
	assert(type(consume) == "boolean",
		"adapters.synthetic_input.leave_callback: consume must be boolean")
	-- Validate the entire collector before popping it or handing off any prefix.
	-- If validation fails, the wrapper can still call abort_callback() and roll
	-- every batch back atomically.
	for _, batch in ipairs(collector.batches) do
		local retained_paced = batch.mode == "paced" and batch.status == "queued"
			and batch.paced_owner and batch.paced_owner.collector == collector
		if batch.status ~= "building" and batch.status ~= "cancelled"
			and batch.status ~= "failed" and not retained_paced then
			error("adapters.synthetic_input.leave_callback: collector batch already handed off", 0)
		end
	end
	-- Eligible older FIFO work is returned before this callback's own events. A
	-- target-mismatched paced batch, the freshly committed paced batch, and every
	-- later sibling remain queued behind their retained post-return wake
	local adoption = adopt_pending_deferred_batches(collector)
	local adopted = adoption.batches
	if #adopted > 0 then
		if #collector.events == 0 then
			-- Common physical-event fence: transfer the existing array in O(1)
			-- rather than copying a potentially large selection batch in the tap.
			collector.events = adoption.events
		else
			local ordered_events = {}
			for _, event in ipairs(adoption.events) do
				ordered_events[#ordered_events + 1] = event
			end
			for _, event in ipairs(collector.events) do
				ordered_events[#ordered_events + 1] = event
			end
			collector.events = ordered_events
		end
	end
	_callback_stack[#_callback_stack] = nil
	for _, batch in ipairs(adopted) do handoff_returned_batch(batch) end
	for _, batch in ipairs(collector.batches) do
		if batch.status == "building" then
			handoff_returned_batch(batch)
		end
	end
	for tx in pairs(collector.implicit_transactions) do
		local sealed_ok, seal_err = pcall(M.seal, tx)
		if not sealed_ok then
			defer_diagnostic("error", "Cannot seal handed-off implicit transaction - %s.",
				tostring(seal_err))
		end
	end
	return consume, (#collector.events > 0 and collector.events or nil)
end


--- Cancels and removes the current collector after an enclosing callback failure.
--- A committed paced owner cannot be revoked, so the caller must still consume
--- the physical event whose output that owner represents.
--- @return boolean removed False when no collector is active.
--- @return boolean consume_original True when committed output retains ownership.
function M.abort_callback()
	local collector = _callback_stack[#_callback_stack]
	if collector == nil then return false, false end
	_callback_stack[#_callback_stack] = nil
	local consume_original = false
	for _, batch in ipairs(collector.batches) do
		local owner = batch.paced_owner
		if owner and owner.committed == true and batch.status == "queued" then
			consume_original = true
		elseif not batch.tx.cancelled then
			local cancelled_ok, cancelled_or_error = pcall(M.cancel, batch.tx)
			if not cancelled_ok then
				defer_diagnostic("error", "Cannot cancel aborted callback transaction - %s.",
					tostring(cancelled_or_error))
			end
		end
	end
	return true, consume_original
end


--- Decodes ownership fields that survive bounded-ledger eviction and reload.
--- @param tag number Quartz user-data value.
--- @return table|nil metadata Fresh caller-owned table.
function M.decode_tag(tag)
	local integer_tag = math.tointeger(tag)
	if integer_tag == nil or integer_tag < 0 then return nil end
	local namespace = (integer_tag >> TAG_NAMESPACE_SHIFT) & ((1 << TAG_NAMESPACE_BITS) - 1)
	if namespace ~= TAG_NAMESPACE then return nil end
	local effect = ((integer_tag >> TAG_EFFECT_SHIFT) & 1) == 1
		and "action" or "replacement"
	local encoded_loopback = ((integer_tag >> TAG_LOOPBACK_SHIFT) & 1) == 1
	local physical_replay = effect == "replacement" and encoded_loopback
	return {
		owned = true,
		magic = M.MAGIC,
		tag = integer_tag,
		effect = effect,
		loopback = effect == "action" and encoded_loopback,
		physical_replay = physical_replay,
		sequence = integer_tag & TAG_SEQUENCE_MASK,
		enriched = false,
		stale = true,
		control = false,
	}
end


--- Copies a live ledger record without exposing dedupe/linkage tables.
--- @param record table Internal record.
--- @return table metadata Fresh caller-owned table.
local function copy_record(record)
	return {
		owned = true,
		magic = record.magic,
		tag = record.tag,
		session = record.session,
		generation = record.generation,
		owner = record.owner,
		effect = record.effect,
		batch = record.batch,
		ordinal = record.ordinal,
		phase = record.phase,
		control = record.control == true,
		loopback = record.loopback == true,
		physical_replay = record.physical_replay == true,
		source_pid = record.source_pid,
		sequence = record.tag & TAG_SEQUENCE_MASK,
		enriched = true,
		stale = false,
	}
end


--- Looks up enrichment when present, otherwise returns decoded fail-closed data.
--- @param tag number Quartz user-data value.
--- @return table|nil metadata Fresh caller-owned table.
function M.lookup_tag(tag)
	local decoded = M.decode_tag(tag)
	if decoded == nil then return nil end
	local record = _records[decoded.tag]
	if record == nil or record.magic ~= M.MAGIC then
		if decoded.loopback then
			decoded.encoded_loopback = true
			decoded.loopback = false
			decoded.stale_loopback = true
		end
		return decoded
	end
	return copy_record(record)
end


--- Claims one tag independently per event consumer.
--- Transaction-wide action state uses current_action_epoch(); this per-event
--- claim remains only to suppress duplicate live loopback control delivery.
--- @param tag number Quartz user-data value.
--- @param consumer_id string|nil Stable consumer name; nil performs no mutation.
--- @return table|nil metadata Fresh caller-owned table.
--- @return boolean duplicate Same event was already seen by this consumer.
function M.claim_tag(tag, consumer_id)
	if consumer_id ~= nil then
		assert(type(consumer_id) == "string" and consumer_id ~= "",
			"adapters.synthetic_input.claim_tag: consumer_id must be a non-empty string")
	end
	local decoded = M.decode_tag(tag)
	if decoded == nil then return nil, false end
	local record = _records[decoded.tag]
	if record == nil then
		-- A valid old/evicted tag must never become physical input. Without live
		-- enrichment there is no exact tx key, so action consumers invalidate
		-- conservatively; replacement consumers only suppress the echo.
		local encoded_loopback = decoded.loopback == true
		if consumer_id ~= nil and not encoded_loopback
			and not sequence_is_current_session(decoded.sequence) then
			publish_stale_context_epoch(decoded.tag)
		end
		if encoded_loopback then
			decoded.encoded_loopback = true
			decoded.loopback = false
			decoded.stale_loopback = true
		end
		-- The bounded full-tag ring above is the once-only invalidation key shared by
		-- every consumer. Current-session evictions are excluded through their
		-- reservation block, avoiding reset storms in one large live action.
		return decoded, false
	end
	local metadata = copy_record(record)
	if consumer_id == nil then return metadata, false end
	local duplicate = record.seen_by[consumer_id] == true
	if not duplicate then
		assert(record.seen_count < M.CONSUMER_LIMIT,
			"adapters.synthetic_input: per-record consumer limit exhausted")
		record.seen_by[consumer_id] = true
		record.seen_count = record.seen_count + 1
		if record._loopback_pinned
			and ((record.phase == "down" and consumer_id == "keymap")
				or (record.phase == "up" and consumer_id == "keymap.loopback_keyup")) then
			record._loopback_pinned = false
		end
	end
	return metadata, duplicate
end


--- Returns bounded-state diagnostics without exposing mutable ledgers.
--- @return table stats
function M.stats()
	return {
		session = SESSION_ID,
		generation = _generation,
		action_handoffs = _action_handoff_count,
		active_transactions = _active_transaction_count,
		records = _record_count,
		record_limit = M.RECORD_LIMIT,
		pending = _pending_count + _pending_loopback_count,
		pending_deferred = _pending_count,
		pending_loopbacks = _pending_loopback_count,
		pending_lifecycle_callbacks = math.max(0,
			_deferred_lifecycle_tail - _deferred_lifecycle_head + 1),
		pending_post_callback_actions = _deferred_post_callback_count,
		pending_periodic_cleanup = _periodic_cleanup_count,
		pump_started = _pump_tap ~= nil,
		stale_context_tags = _stale_context_count,
	}
end


return M
