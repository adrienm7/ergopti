--- adapters/log_transport.lua

--- ==============================================================================
--- MODULE: Asynchronous Logger Transport
--- DESCRIPTION:
--- Moves every production logging side effect out of Hammerspoon's HID callbacks.
--- A bounded boot-only UDP exchange proves that the native sink is ready before
--- any input tap is armed. Runtime producers then append immutable records to an
--- in-memory deque; a timer-owned pump performs routing, encoding, socket I/O,
--- retries, and delivery callbacks after the HID callback has returned.
---
--- INVARIANTS:
--- 1. enqueue() performs no socket, timer, console, notification, file, or routing call.
--- 2. start() succeeds only after an authenticated native configure ACK.
--- 3. At most one bounded batch is in flight; an ACK can never reorder the retained deque.
--- 4. A missing ACK retries the byte-identical batch and never retires the deque head.
--- 5. Every acquired native capability is either released exactly or retained as debt.
--- 6. No producer line can retain more than one preparation tick's byte budget.
--- ==============================================================================

local M = {}

local hs = hs

local PROTOCOL_VERSION = 1
local LOOPBACK_HOST = "127.0.0.1"
local PUMP_INTERVAL_SEC = 0.01
local ACK_RETRY_SEC = 0.50
local MAX_ACK_ATTEMPTS_BEFORE_FAILURE = 4
local BOOT_CONFIGURE_TIMEOUT_SEC = 0.25
local DEFAULT_DRAIN_TIMEOUT_SEC = 2.0
local MAX_DATAGRAM_BYTES = 60000
local MAX_RECORD_LINE_BYTES = 8000
local MAX_BATCH_RECORDS = 64
local MAX_PREPARE_STEPS_PER_TICK = 64
local MAX_PREPARE_BYTES_PER_TICK = 65536
local MAX_ENQUEUED_LINE_BYTES = MAX_PREPARE_BYTES_PER_TICK
local DEFAULT_ROUTE_OVERLAP_BYTES = 256
local MAX_ROUTE_OVERLAP_BYTES = 4096
local MAX_QUEUED_RECORDS = 8192
-- Keep a hard tail reserve for diagnostics that explain why the ordinary
-- stream stopped progressing. Without a separate admission ceiling, DEBUG or
-- TRACE traffic can consume every slot and the first WARNING/ERROR is then the
-- one record the fail-safe cannot retain.
local MAX_NONCRITICAL_QUEUED_RECORDS = 7168
local MAX_REJECTED_ERROR_RECORDS = 64
local MAX_REJECTED_DELIVERIES_PER_TICK = 8
local MIN_TOKEN_BYTES = 32
local MAX_SESSION_BYTES = 128
local SESSION_SETTING_KEY = "ergopti.logger.transport_session"
local PENDING_SESSION_SETTING_KEY = "ergopti.logger.transport_pending_session"

local ACCEPTED_VARIANTS = {
	debug = true,
	trace = true,
	done = true,
	info = true,
	start = true,
	success = true,
	warn = true,
	error = true,
}

local _active = false
local _accepting = false
local _configured = false
local _socket = nil
local _bootstrap_socket = nil
local _timer_handle = nil
local _scheduler = nil
local _port = nil
local _token = nil
local _session = nil
local _previous_session = nil
local _log_dir = nil
local _retention_days = nil
local _route_line = nil
local _route_overlap_bytes = DEFAULT_ROUTE_OVERLAP_BYTES
local _batch_record_limit = MAX_BATCH_RECORDS
local _on_delivered = nil
local _on_rejected = nil
local _on_ready = nil
local _on_failed = nil
local _clock = nil
local _queue = {}
local _queue_head = 1
local _queue_tail = 0
local _queued_noncritical = 0
local _rejected_errors = {}
local _rejected_error_head = 1
local _rejected_error_tail = 0
local _dropped_total = 0
local _dropped_critical = 0
local _dropped_by_variant = {}
local _rejected_error_overflow = 0
local _next_sequence = 1
local _inflight = nil
local _drain_callback = nil
local _drain_deadline = nil
local _drain_error = nil
local _last_error = nil
local _reported_error = nil

local function queue_count()
	if _queue_tail < _queue_head then return 0 end
	return _queue_tail - _queue_head + 1
end

local function queue_peek()
	if _queue_tail < _queue_head then return nil end
	return _queue[_queue_head]
end

local function queue_push(record)
	_queue_tail = _queue_tail + 1
	_queue[_queue_tail] = record
end

local function queue_pop()
	local record = queue_peek()
	if record == nil then return nil end
	if record.critical ~= true then
		_queued_noncritical = math.max(0, _queued_noncritical - 1)
	end
	_queue[_queue_head] = nil
	_queue_head = _queue_head + 1
	if _queue_head > _queue_tail then
		_queue = {}
		_queue_head = 1
		_queue_tail = 0
	elseif _queue_head > 1024 then
		local compacted = {}
		local tail = 0
		for index = _queue_head, _queue_tail do
			tail = tail + 1
			compacted[tail] = _queue[index]
		end
		_queue = compacted
		_queue_head = 1
		_queue_tail = tail
	end
	return record
end

local function rejected_error_count()
	if _rejected_error_tail < _rejected_error_head then return 0 end
	return _rejected_error_tail - _rejected_error_head + 1
end

local function rejected_error_push(record)
	_rejected_error_tail = _rejected_error_tail + 1
	_rejected_errors[_rejected_error_tail] = record
end

local function rejected_error_pop()
	if _rejected_error_tail < _rejected_error_head then return nil end
	local record = _rejected_errors[_rejected_error_head]
	_rejected_errors[_rejected_error_head] = nil
	_rejected_error_head = _rejected_error_head + 1
	if _rejected_error_head > _rejected_error_tail then
		_rejected_errors = {}
		_rejected_error_head = 1
		_rejected_error_tail = 0
	end
	return record
end

local function dropped_by_variant_snapshot()
	local snapshot = {}
	for variant, count in pairs(_dropped_by_variant) do snapshot[variant] = count end
	return snapshot
end

local function now()
	local clock = _clock
	if type(clock) ~= "function" then return os.time() end
	local ok, value = pcall(clock)
	if ok and type(value) == "number" then return value end
	-- A wall clock can jump, but it still advances while the process is idle. On
	-- monotonic-clock failure an early retry/timeout is safer than an unbounded
	-- drain that leaves a torn-down Hammerspoon process alive indefinitely.
	return os.time()
end

local function invoke_failure_callback()
	if _last_error == nil or _last_error == _reported_error or type(_on_failed) ~= "function" then
		return
	end
	_reported_error = _last_error
	local ok, callback_err = xpcall(_on_failed, debug.traceback, _last_error)
	if not ok then _last_error = "failure callback failed: " .. tostring(callback_err) end
end

local function set_error(message, report_from_async_boundary)
	_last_error = tostring(message or "unknown transport error")
	-- A drain is a durability verdict, not merely an empty-deque observation.
	-- Retain the first failure that happened while that verdict was pending so a
	-- later ACK cannot turn the same transaction into a false clean shutdown.
	if _drain_callback ~= nil and _drain_error == nil then _drain_error = _last_error end
	if report_from_async_boundary == true then invoke_failure_callback() end
end

local function parsed_peer(sockaddr)
	local udp = hs and hs.socket and hs.socket.udp
	if type(udp) ~= "table" or type(udp.parseAddress) ~= "function" then return nil end
	local ok, parsed = pcall(udp.parseAddress, sockaddr)
	if not ok or type(parsed) ~= "table" then return nil end
	local host = tostring(parsed.host or "")
	local port = tonumber(parsed.port)
	if host ~= "127.0.0.1" and host ~= "::1" and host ~= "::ffff:127.0.0.1" then
		return nil
	end
	if port ~= _port then return nil end
	return parsed
end

local function decode_response(data, token, session)
	if type(data) ~= "string" or data == "" then return nil end
	local json = hs and hs.json
	if type(json) ~= "table" or type(json.decode) ~= "function" then return nil end
	local ok, decoded = pcall(json.decode, data)
	if not ok or type(decoded) ~= "table" then return nil end
	if decoded.v ~= PROTOCOL_VERSION or decoded.token ~= token or decoded.session ~= session then
		return nil
	end
	if decoded.kind == "nack" then
		return {
			kind = "nack",
			reason = tostring(decoded.reason or "native logger rejected the datagram"),
			expected = tonumber(decoded.expected),
		}
	end
	if decoded.kind ~= "ack" then return nil end
	local sequence = tonumber(decoded.ack)
	if sequence == nil or sequence < 0 or sequence ~= math.floor(sequence) then return nil end
	return { kind = "ack", sequence = sequence }
end

local function finish_drain_if_ready()
	if type(_drain_callback) ~= "function" then return end
	if queue_count() > 0 or rejected_error_count() > 0 or _inflight ~= nil then
		if type(_drain_deadline) == "number" and now() >= _drain_deadline then
			local callback = _drain_callback
			_drain_callback = nil
			_drain_deadline = nil
			_drain_error = nil
			_accepting = true
			set_error("native logger drain timed out with retained records")
			local ok, callback_err = xpcall(callback, debug.traceback, false, _last_error)
			if not ok then set_error("drain callback failed: " .. tostring(callback_err)) end
		end
		return
	end
	local callback = _drain_callback
	local drain_error = _drain_error
	_drain_callback = nil
	_drain_deadline = nil
	_drain_error = nil
	-- Lua callbacks cannot interleave. Fencing producers at the exact empty-queue
	-- pump boundary still lets a reload request be upgraded to quit (and enqueue
	-- its quit-only teardown diagnostics) while the earlier drain is pending.
	local settled = drain_error == nil
	_accepting = not settled
	local ok, callback_err = xpcall(callback, debug.traceback, settled, drain_error)
	if not ok then set_error("drain callback failed: " .. tostring(callback_err)) end
end

local function deliver_rejected_errors()
	for _ = 1, MAX_REJECTED_DELIVERIES_PER_TICK do
		local record = rejected_error_pop()
		if record == nil then return end
		if type(_on_rejected) == "function" then
			local ok, delivered_or_err, delivery_detail = xpcall(
				_on_rejected,
				debug.traceback,
				record
			)
			if not ok or delivered_or_err ~= true then
				local detail = ok and (delivery_detail or delivered_or_err) or delivered_or_err
				set_error("rejected-record callback failed: " .. tostring(detail))
			end
		end
	end
end

local function handle_response(data, sockaddr)
	if not _active or parsed_peer(sockaddr) == nil then return end
	local response = decode_response(data, _token, _session)
	if response == nil then return end
	if response.kind == "nack" then
		set_error(string.format(
			"native logger NACK: %s%s",
			response.reason,
			response.expected and (" (expected sequence " .. tostring(response.expected) .. ")") or ""
		))
		if type(_inflight) == "table" then _inflight.sent_at = now() end
		return
	end
	local sequence = response.sequence
	if type(_inflight) ~= "table" or sequence ~= _inflight.sequence then return end
	for offset, completed in ipairs(_inflight.completed_items or {}) do
		if _queue[_queue_head + offset - 1] ~= completed then
			set_error("ACK matched the in-flight batch but not its retained producer prefix")
			return
		end
	end
	local batch = _inflight
	for _ = 1, #(batch.completed_items or {}) do queue_pop() end
	_inflight = nil
	if type(_on_delivered) == "function" then
		for _, delivery_record in ipairs(batch.deliveries or {}) do
			local ok, delivered_or_err, delivery_detail = xpcall(
				_on_delivered,
				debug.traceback,
				delivery_record
			)
			if not ok or delivered_or_err ~= true then
				local detail = ok and (delivery_detail or delivered_or_err) or delivered_or_err
				set_error("delivery callback failed: " .. tostring(detail))
			end
		end
	end
	-- Drain ownership belongs to the pump timer, never this socket callback. In
	-- particular, a failing delivery hook must reach invoke_failure_callback() on
	-- the next tick before a final empty-queue ACK can finalize the logger.
end

local function socket_callback(data, sockaddr)
	local ok, callback_err = xpcall(handle_response, debug.traceback, data, sockaddr)
	if not ok then set_error("UDP receive callback failed: " .. tostring(callback_err)) end
end

local function encode_json(payload)
	local json = hs and hs.json
	if type(json) ~= "table" or type(json.encode) ~= "function" then
		return nil, "hs.json.encode is unavailable"
	end
	local ok, encoded = pcall(json.encode, payload)
	if not ok or type(encoded) ~= "string" then
		return nil, "log datagram JSON encoding failed: " .. tostring(encoded)
	end
	if #encoded > MAX_DATAGRAM_BYTES then
		return nil, string.format(
			"log datagram is %d bytes; authenticated UDP limit is %d bytes",
			#encoded,
			MAX_DATAGRAM_BYTES
		), "too_large"
	end
	return encoded
end

--- Returns the byte width of one valid UTF-8 sequence, or nil for an invalid
--- leading byte/continuation tuple. This deliberately avoids utf8.offset/len:
--- malformed user-derived diagnostics are the input being contained here.
--- @param value string Raw byte string.
--- @param index integer One-based byte offset.
--- @return integer|nil width
local function valid_utf8_width(value, index)
	local first = string.byte(value, index)
	if first == nil then return nil end
	if first <= 0x7F then return 1 end
	local second = string.byte(value, index + 1)
	if first >= 0xC2 and first <= 0xDF then
		if second and second >= 0x80 and second <= 0xBF then return 2 end
		return nil
	end
	local third = string.byte(value, index + 2)
	if first == 0xE0 then
		if second and second >= 0xA0 and second <= 0xBF
			and third and third >= 0x80 and third <= 0xBF then return 3 end
		return nil
	end
	if (first >= 0xE1 and first <= 0xEC) or (first >= 0xEE and first <= 0xEF) then
		if second and second >= 0x80 and second <= 0xBF
			and third and third >= 0x80 and third <= 0xBF then return 3 end
		return nil
	end
	if first == 0xED then
		if second and second >= 0x80 and second <= 0x9F
			and third and third >= 0x80 and third <= 0xBF then return 3 end
		return nil
	end
	local fourth = string.byte(value, index + 3)
	if first == 0xF0 then
		if second and second >= 0x90 and second <= 0xBF
			and third and third >= 0x80 and third <= 0xBF
			and fourth and fourth >= 0x80 and fourth <= 0xBF then return 4 end
		return nil
	end
	if first >= 0xF1 and first <= 0xF3 then
		if second and second >= 0x80 and second <= 0xBF
			and third and third >= 0x80 and third <= 0xBF
			and fourth and fourth >= 0x80 and fourth <= 0xBF then return 4 end
		return nil
	end
	if first == 0xF4 then
		if second and second >= 0x80 and second <= 0x8F
			and third and third >= 0x80 and third <= 0xBF
			and fourth and fourth >= 0x80 and fourth <= 0xBF then return 4 end
	end
	return nil
end

--- Preserves every valid UTF-8 sequence byte-for-byte and renders each invalid
--- byte as an ASCII `\xNN` escape. Called only by the timer-owned encoder, never
--- by enqueue()/eventtap, so arbitrary input cannot make hs.json.encode throw or
--- add a full-line validation scan to the HID callback.
--- @param value string Raw byte string.
--- @return string safe_utf8
local function sanitize_utf8(value)
	local pieces = {}
	local literal_start = 1
	local index = 1
	while index <= #value do
		local width = valid_utf8_width(value, index)
		if width ~= nil then
			index = index + width
		else
			if literal_start < index then
				pieces[#pieces + 1] = value:sub(literal_start, index - 1)
			end
			pieces[#pieces + 1] = string.format("\\x%02X", string.byte(value, index))
			index = index + 1
			literal_start = index
		end
	end
	if literal_start <= #value then pieces[#pieces + 1] = value:sub(literal_start) end
	if #pieces == 0 then return value end
	return table.concat(pieces)
end

--- Chooses a bounded raw-byte fragment without splitting a valid UTF-8 scalar.
--- Invalid continuation runs deliberately stay bounded at MAX_RECORD_LINE_BYTES;
--- sanitize_utf8() will escape them later instead of extending the datagram.
--- @param value string Raw producer text.
--- @param cursor integer One-based start byte.
--- @return integer finish Inclusive end byte.
local function next_fragment_finish(value, cursor)
	local finish = math.min(#value, cursor + MAX_RECORD_LINE_BYTES - 1)
	if finish >= #value then return finish end
	local sequence_start = finish
	local walked = 0
	while sequence_start > cursor and walked < 3 do
		local byte = string.byte(value, sequence_start)
		if byte == nil or byte < 0x80 or byte > 0xBF then break end
		sequence_start = sequence_start - 1
		walked = walked + 1
	end
	local width = valid_utf8_width(value, sequence_start)
	if width ~= nil and sequence_start + width - 1 > finish then
		finish = sequence_start - 1
	end
	return finish
end

local function add_topics(item, routed)
	item.topic_seen = item.topic_seen or {}
	item.topics = item.topics or {}
	for _, topic in ipairs(routed) do
		if type(topic) == "string" and item.topic_seen[topic] ~= true then
			item.topic_seen[topic] = true
			item.topics[#item.topics + 1] = topic
		end
	end
end

local function begin_notification_preparation(item)
	local notification = item.notification
	if type(notification) ~= "table" then
		item.prepared = true
		return true
	end
	local module_ok, module_name = pcall(tostring, notification.module_name)
	local message_ok, message = pcall(tostring, notification.message)
	if not module_ok or not message_ok then
		set_error("notification text conversion failed", true)
		return false
	end
	item.notification_fields = {
		{ name = "module_name", raw = module_name, cursor = 1, pieces = {} },
		{ name = "message", raw = message, cursor = 1, pieces = {} },
	}
	item.notification_field_index = 1
	item.safe_notification = {}
	item.preparation_stage = "notification"
	return true
end

--- Performs at most one bounded fragment of preparation for one producer.
--- All scans, routing, substring allocation and UTF-8 sanitation live here on
--- the timer boundary; enqueue() publishes the original string reference and
--- its O(1) admission-time calendar fallback.
--- @param item table Retained producer record.
--- @return boolean progressed_or_ready False only on a contained routing error.
local function prepare_item_step(item)
	if item.prepared == true then return true, 0 end
	if item.preparation_stage == nil then
		item.preparation_stage = "line"
		item.prepare_cursor = 1
		item.fragment_count = 0
		item.calendar_date = item.line:match("^(%d%d%d%d%-%d%d%-%d%d) ")
			or item.enqueue_calendar_date
		item.topics = {}
		item.topic_seen = {}
		item.route_tail = ""
	end

	if item.preparation_stage == "line" then
		local cursor = item.prepare_cursor
		local finish = next_fragment_finish(item.line, cursor)
		local chunk = item.line:sub(cursor, finish)
		if type(_route_line) == "function" then
			local route_source = item.route_tail .. chunk
			local route_ok, routed_or_err = xpcall(_route_line, debug.traceback, route_source)
			if not route_ok or type(routed_or_err) ~= "table" then
				set_error("topical route derivation failed: " .. tostring(routed_or_err), true)
				return false, 0
			end
			add_topics(item, routed_or_err)
			if _route_overlap_bytes > 0 then
				local tail_start = math.max(1, #route_source - _route_overlap_bytes + 1)
				item.route_tail = route_source:sub(tail_start)
			end
		end
		item.fragment_count = item.fragment_count + 1
		item.prepare_cursor = finish + 1
		if item.prepare_cursor > #item.line then
			item.emit_cursor = 1
			item.fragment_index = 1
			if not begin_notification_preparation(item) then return false, 0 end
		end
		return true, finish - cursor + 1
	end

	local field = item.notification_fields[item.notification_field_index]
	if field == nil then
		item.notification_fields = nil
		item.notification_field_index = nil
		item.prepared = true
		return true, 0
	end
	if field.raw == "" then
		item.safe_notification[field.name] = ""
		item.notification_field_index = item.notification_field_index + 1
		return true, 0
	end
	local cursor = field.cursor
	local finish = next_fragment_finish(field.raw, cursor)
	field.pieces[#field.pieces + 1] = sanitize_utf8(field.raw:sub(cursor, finish))
	field.cursor = finish + 1
	if field.cursor > #field.raw then
		item.safe_notification[field.name] = table.concat(field.pieces)
		item.notification_field_index = item.notification_field_index + 1
	end
	return true, finish - cursor + 1
end

--- Prepares a FIFO prefix with a strict per-tick scan budget. The largest
--- admitted producer line can consume one complete tick but never more, while
--- ordinary records fill one native batch per tick.
--- @return boolean ready Whether the retained head is ready for encoding.
local function prepare_ready_prefix()
	local step_budget = MAX_PREPARE_STEPS_PER_TICK
	local byte_budget = MAX_PREPARE_BYTES_PER_TICK
	local ready_fragments = 0
	local queue_index = _queue_head
	while step_budget > 0 and byte_budget > 0 and queue_index <= _queue_tail
		and ready_fragments < _batch_record_limit do
		local item = _queue[queue_index]
		if item.prepared ~= true then
			local progressed, consumed = prepare_item_step(item)
			if not progressed then return false end
			step_budget = step_budget - 1
			byte_budget = byte_budget - (consumed or 0)
		end
		if item.prepared == true then
			ready_fragments = ready_fragments
				+ (item.fragment_count - item.fragment_index + 1)
			queue_index = queue_index + 1
		end
	end
	local head = queue_peek()
	return type(head) == "table" and head.prepared == true
end

local function configure_payload(token, session, previous_session, log_dir, retention_days)
	return encode_json({
		v = PROTOCOL_VERSION,
		token = token,
		session = session,
		previous_session = previous_session,
		kind = "configure",
		sequence = 0,
		log_dir = log_dir,
		retention_days = retention_days,
	})
end

local function build_next_batch()
	local wire_records = {}
	local deliveries = {}
	local progress = {}
	local local_states = {}
	local queue_index = _queue_head
	local safe_line_bytes = 0

	while #wire_records < _batch_record_limit and queue_index <= _queue_tail do
		local item = _queue[queue_index]
		if type(item) ~= "table" or item.prepared ~= true then break end
		local state = local_states[item]
		if state == nil then
			state = { cursor = item.emit_cursor, index = item.fragment_index }
			local_states[item] = state
		end
		local finish = next_fragment_finish(item.line, state.cursor)
		local raw_fragment = item.line:sub(state.cursor, finish)
		local rendered = raw_fragment
		if item.fragment_count > 1 then
			rendered = string.format(
				"%s 00:00:00:000 | INFO | log_transport | [fragment %d/%d] %s",
				item.calendar_date,
				state.index,
				item.fragment_count,
				raw_fragment
			)
		end
		local safe_line = sanitize_utf8(rendered)
		-- Collection is bounded by both record count and the actual sanitized
		-- text budget. Thus 64 short records cost one encode, while 8 KiB
		-- fragments cannot make this timer callback prepare half a megabyte only
		-- to discover that UDP can carry a small prefix.
		if #wire_records > 0 and safe_line_bytes + #safe_line > MAX_DATAGRAM_BYTES then break end
		local completes_item = finish >= #item.line
		local sequence = _next_sequence + #wire_records
		local delivery = {
			sequence = sequence,
			line = safe_line,
			calendar_date = item.calendar_date,
			variant = item.variant,
			critical = item.critical,
		}
		if completes_item and type(item.safe_notification) == "table" then
			delivery.notification = item.safe_notification
		end
		local wire_record = {
			sequence = sequence,
			calendar_date = item.calendar_date,
			line = safe_line,
			variant = item.variant,
		}
		if #item.topics > 0 then wire_record.topics = item.topics end
		wire_records[#wire_records + 1] = wire_record
		deliveries[#deliveries + 1] = delivery
		safe_line_bytes = safe_line_bytes + #safe_line
		state.cursor = finish + 1
		state.index = state.index + 1
		progress[#progress + 1] = {
			item = item,
			cursor = state.cursor,
			index = state.index,
			completed = completes_item,
		}
		if completes_item then
			queue_index = queue_index + 1
		end
	end

	if #wire_records == 0 then return nil end
	local function encode_prefix(count)
		local prefix = {}
		for index = 1, count do prefix[index] = wire_records[index] end
		return encode_json({
			v = PROTOCOL_VERSION,
			token = _token,
			session = _session,
			kind = "batch",
			records = prefix,
		})
	end

	local chosen_count = #wire_records
	local payload, encode_err, encode_kind = encode_prefix(chosen_count)
	if payload == nil and encode_kind ~= "too_large" then
		set_error(encode_err, true)
		return nil
	end
	if payload == nil then
		local low = 1
		local high = chosen_count - 1
		local best_count = 0
		local best_payload = nil
		while low <= high do
			local middle = math.floor((low + high) / 2)
			local candidate, candidate_err, candidate_kind = encode_prefix(middle)
			if candidate ~= nil then
				best_count = middle
				best_payload = candidate
				low = middle + 1
			elseif candidate_kind == "too_large" then
				high = middle - 1
			else
				set_error(candidate_err, true)
				return nil
			end
		end
		if best_payload == nil then
			set_error(encode_err, true)
			return nil
		end
		chosen_count = best_count
		payload = best_payload
	end

	local accepted_updates = {}
	local accepted_completed = {}
	local accepted_deliveries = {}
	for index = 1, chosen_count do
		local step = progress[index]
		accepted_updates[step.item] = { cursor = step.cursor, index = step.index }
		if step.completed then accepted_completed[#accepted_completed + 1] = step.item end
		accepted_deliveries[index] = deliveries[index]
	end
	for item, update in pairs(accepted_updates) do
		item.emit_cursor = update.cursor
		item.fragment_index = update.index
	end
	_next_sequence = _next_sequence + chosen_count
	return {
		sequence = _next_sequence - 1,
		payload = payload,
		deliveries = accepted_deliveries,
		completed_items = accepted_completed,
		attempts = 0,
	}
end

local function pump()
	if not _active or _socket == nil then return end
	invoke_failure_callback()
	deliver_rejected_errors()
	finish_drain_if_ready()
	if not _active or type(_drain_callback) ~= "function"
		and queue_count() == 0 and rejected_error_count() == 0 then return end

	if _inflight ~= nil then
		if _inflight.sent_at ~= nil and (now() - _inflight.sent_at) < ACK_RETRY_SEC then return end
	else
		if queue_peek() == nil then
			finish_drain_if_ready()
			return
		end
		if not prepare_ready_prefix() then return end
		_inflight = build_next_batch()
		if _inflight == nil then return end
	end

	local ok, sent_or_err = pcall(
		_socket.send,
		_socket,
		_inflight.payload,
		LOOPBACK_HOST,
		_port,
		_inflight.sequence
	)
	_inflight.sent_at = now()
	if not ok or sent_or_err == nil or sent_or_err == false then
		set_error("UDP send was refused: " .. tostring(sent_or_err), true)
		return
	end
	_inflight.attempts = (_inflight.attempts or 0) + 1
	if _inflight.attempts >= MAX_ACK_ATTEMPTS_BEFORE_FAILURE
		and _inflight.failure_reported ~= true then
		_inflight.failure_reported = true
		set_error(string.format(
			"native logger did not ACK retained sequence %d after %d sends",
			_inflight.sequence,
			_inflight.attempts
		), true)
	end
end

local function pump_boundary()
	local ok, pump_err = xpcall(pump, debug.traceback)
	if not ok then set_error("logger pump callback failed: " .. tostring(pump_err), true) end
end

local function valid_session(value)
	return type(value) == "string"
		and value ~= ""
		and #value <= MAX_SESSION_BYTES
		and value:match("^[%w_-]+$") ~= nil
end

local function settings_value(settings, key)
	local ok, value = pcall(settings.get, key)
	if not ok then return nil, false end
	return value, true
end

local function clear_setting_exact(settings, key)
	if type(settings.clear) ~= "function" then return false end
	local ok, result = pcall(settings.clear, key)
	local value, readable = settings_value(settings, key)
	return ok and result ~= false and readable and value == nil
end

local function set_setting_exact(settings, key, value)
	local ok, result = pcall(settings.set, key, value)
	local stored, readable = settings_value(settings, key)
	if not ok or result == false or not readable then return false end
	if type(value) ~= "table" then return stored == value end
	return type(stored) == "table"
		and stored.current == value.current
		and stored.previous == value.previous
end

local function prepare_session(options, settings)
	local committed, committed_readable = settings_value(settings, SESSION_SETTING_KEY)
	if not committed_readable then return nil, nil, "logger committed session is unreadable" end
	if committed ~= nil and not valid_session(committed) then
		return nil, nil, "logger committed session is malformed"
	end
	local pending, pending_readable = settings_value(settings, PENDING_SESSION_SETTING_KEY)
	if not pending_readable then return nil, nil, "logger pending session is unreadable" end
	if pending ~= nil then
		if type(pending) ~= "table" or not valid_session(pending.current)
			or type(pending.previous) ~= "string" then
			return nil, nil, "logger pending session is malformed"
		end
		local previous = pending.previous ~= "" and pending.previous or nil
		if pending.current == committed then
			if not clear_setting_exact(settings, PENDING_SESSION_SETTING_KEY) then
				return nil, nil, "committed logger session residue could not be cleared"
			end
			pending = nil
		elseif previous == committed then
			return pending.current, committed
		else
			return nil, nil, "logger pending session transition has an invalid predecessor"
		end
	end

	local generated = nil
	if valid_session(options.session) then
		generated = options.session
	elseif hs and type(hs.host) == "table" and type(hs.host.uuid) == "function" then
		local ok, uuid = pcall(hs.host.uuid)
		if ok and type(uuid) == "string" then generated = uuid:gsub("[^%w_-]", "") end
	end
	if not valid_session(generated) or generated == committed then
		return nil, nil, "cannot allocate a unique logger transport session"
	end
	local transition = {
		current = generated,
		previous = committed or "",
	}
	if not set_setting_exact(settings, PENDING_SESSION_SETTING_KEY, transition) then
		return nil, nil, "logger pending session could not be persisted exactly"
	end
	return generated, committed
end

local function commit_session(settings, session)
	if not set_setting_exact(settings, SESSION_SETTING_KEY, session) then
		return false, "logger committed session could not be persisted exactly"
	end
	if not clear_setting_exact(settings, PENDING_SESSION_SETTING_KEY) then
		return false, "logger pending session could not be cleared after native ACK"
	end
	return true
end

local function close_bootstrap_socket()
	if _bootstrap_socket == nil then return true end
	if type(_bootstrap_socket.close) ~= "function" then
		set_error("bootstrap UDP socket has no close method")
		return false
	end
	local ok, result = pcall(_bootstrap_socket.close, _bootstrap_socket)
	if not ok or result == false or result == nil then
		set_error("bootstrap UDP socket refused close: " .. tostring(result))
		return false
	end
	_bootstrap_socket = nil
	return true
end

local function bootstrap_configure(options, payload, token, session, port)
	local function refuse(detail)
		local original = tostring(detail)
		if not close_bootstrap_socket() then
			return false, original .. "; cleanup debt: " .. tostring(_last_error)
		end
		return false, original
	end
	local factory = options.bootstrap_socket_factory
	if type(factory) ~= "function" then
		local loaded, socket_lib = pcall(require, "socket")
		if not loaded or type(socket_lib) ~= "table" or type(socket_lib.udp) ~= "function" then
			return false, "LuaSocket UDP bootstrap capability is unavailable"
		end
		factory = socket_lib.udp
	end
	local acquired, candidate = pcall(factory)
	if not acquired or candidate == nil or candidate == false then
		return false, "bootstrap UDP construction failed: " .. tostring(candidate)
	end
	_bootstrap_socket = candidate
	if type(candidate.settimeout) ~= "function" or type(candidate.sendto) ~= "function"
		or type(candidate.receivefrom) ~= "function" or type(candidate.close) ~= "function" then
		return refuse("bootstrap UDP socket contract is incomplete")
	end
	local timeout = tonumber(options.bootstrap_timeout_sec) or BOOT_CONFIGURE_TIMEOUT_SEC
	if timeout <= 0 or timeout > BOOT_CONFIGURE_TIMEOUT_SEC then
		return refuse("bootstrap timeout must be positive and bounded")
	end
	local timeout_ok, timeout_result = pcall(candidate.settimeout, candidate, timeout)
	if not timeout_ok or timeout_result == false or timeout_result == nil then
		return refuse("bootstrap UDP timeout configuration failed: " .. tostring(timeout_result))
	end
	local sent_ok, sent_or_err = pcall(candidate.sendto, candidate, payload, LOOPBACK_HOST, port)
	if not sent_ok or tonumber(sent_or_err) ~= #payload then
		return refuse("bootstrap configure send failed: " .. tostring(sent_or_err))
	end
	local receive_ok, data, source_host, source_port = pcall(candidate.receivefrom, candidate, 8192)
	if not receive_ok or type(data) ~= "string" then
		return refuse("bootstrap configure ACK timed out or failed: " .. tostring(data))
	end
	if source_host ~= LOOPBACK_HOST or tonumber(source_port) ~= port then
		return refuse("bootstrap configure ACK came from an unexpected peer")
	end
	local response = decode_response(data, token, session)
	if response == nil or response.kind ~= "ack" or response.sequence ~= 0 then
		local detail = response and response.reason or "invalid authenticated ACK"
		return refuse("bootstrap configure was refused: " .. tostring(detail))
	end
	if not close_bootstrap_socket() then return false, _last_error end
	return true
end

local function close_runtime_socket()
	if _socket == nil then return true end
	if type(_socket.close) ~= "function" then
		set_error("logger UDP socket has no close method")
		return false
	end
	local ok, result = pcall(_socket.close, _socket)
	if not ok or result == false or result == nil then
		set_error("logger UDP socket refused close: " .. tostring(result))
		return false
	end
	_socket = nil
	return true
end

local function rollback_runtime_candidate(candidate)
	_socket = candidate
	if close_runtime_socket() then return true end
	return false
end

--- Starts the authenticated channel and proves native readiness before returning.
--- The only blocking operation is the boot-only configure receive, bounded to
--- 250 ms and executed before any eventtap exists. Runtime records are async.
--- @param options table Runtime dependencies and resolved log policy.
--- @return boolean committed True only after native ACK plus resource ownership.
--- @return string|nil error_message
function M.start(options)
	if _active then
		if _accepting then return true end
		return false, "logger transport is already draining"
	end
	if _bootstrap_socket ~= nil or _socket ~= nil or _timer_handle ~= nil then
		if not M.stop() then return false, "retained logger cleanup debt refused release" end
	end
	if type(options) ~= "table" then return false, "options must be a table" end

	local getenv = type(options.getenv) == "function" and options.getenv or os.getenv
	local port = tonumber(options.port or getenv("ERGOPTI_LOG_PORT"))
	local token = options.token or getenv("ERGOPTI_LOG_TOKEN")
	if port == nil or port < 1 or port > 65535 or port ~= math.floor(port) then
		return false, "ERGOPTI_LOG_PORT is missing or invalid"
	end
	if type(token) ~= "string" or #token < MIN_TOKEN_BYTES then
		return false, "ERGOPTI_LOG_TOKEN is missing or too short"
	end
	if type(options.log_dir) ~= "string" or options.log_dir == "" then
		return false, "log_dir must be a non-empty string"
	end
	if type(options.scheduler) ~= "table" or type(options.scheduler.every) ~= "function"
		or type(options.scheduler.cancel) ~= "function" then
		return false, "TimerScheduler every/cancel capability is unavailable"
	end
	local batch_record_limit = tonumber(options.max_batch_records) or MAX_BATCH_RECORDS
	if batch_record_limit < 1 or batch_record_limit > MAX_BATCH_RECORDS
		or batch_record_limit ~= math.floor(batch_record_limit) then
		return false, "max_batch_records must be an integer between 1 and 64"
	end
	local route_overlap_bytes = tonumber(options.route_overlap_bytes)
		or DEFAULT_ROUTE_OVERLAP_BYTES
	if route_overlap_bytes < 0 or route_overlap_bytes > MAX_ROUTE_OVERLAP_BYTES
		or route_overlap_bytes ~= math.floor(route_overlap_bytes) then
		return false, "route_overlap_bytes must be an integer between 0 and 4096"
	end
	if type(options.clock) ~= "function"
		and type(options.scheduler.now_ns) ~= "function"
		and type(options.scheduler.now) ~= "function" then
		return false, "TimerScheduler monotonic clock capability is unavailable"
	end
	local json = hs and hs.json
	if type(json) ~= "table" or type(json.encode) ~= "function" or type(json.decode) ~= "function" then
		return false, "hs.json encode/decode capability is unavailable"
	end
	local udp = hs and hs.socket and hs.socket.udp
	if type(udp) ~= "table" or type(udp.new) ~= "function"
		or type(udp.parseAddress) ~= "function" then
		return false, "hs.socket.udp is unavailable"
	end
	local settings = hs and hs.settings
	if type(settings) ~= "table" or type(settings.get) ~= "function"
		or type(settings.set) ~= "function" or type(settings.clear) ~= "function" then
		return false, "hs.settings cannot persist logger transport session"
	end

	local session, previous_session, session_err = prepare_session(options, settings)
	if session == nil then return false, session_err end
	local retention_days = tonumber(options.retention_days) or 14
	local payload, payload_err = configure_payload(
		token,
		session,
		previous_session,
		options.log_dir,
		retention_days
	)
	if payload == nil then return false, payload_err end
	local boot_ok, boot_err = bootstrap_configure(options, payload, token, session, port)
	if not boot_ok then return false, boot_err end
	local committed, commit_err = commit_session(settings, session)
	if not committed then return false, commit_err end

	_port = port
	_token = token
	_session = session
	_previous_session = previous_session
	_log_dir = options.log_dir
	_retention_days = retention_days
	_route_line = options.route_line
	_route_overlap_bytes = route_overlap_bytes
	_batch_record_limit = batch_record_limit
	_on_delivered = options.on_delivered
	_on_rejected = options.on_rejected
	_on_ready = options.on_ready
	_on_failed = options.on_failed
	if type(options.clock) == "function" then
		_clock = options.clock
	elseif type(options.scheduler.now_ns) == "function" then
		-- ACK retry and shutdown deadlines are elapsed-time contracts. `os.clock()`
		-- measures process CPU consumption, so an idle Hammerspoon process can leave
		-- a nominal two-second drain pending indefinitely in real time. Reuse the
		-- scheduler's monotonic Mach clock instead; this function is called only by
		-- the timer-owned pump/drain boundary, never by enqueue() on HID.
		_clock = function() return options.scheduler.now_ns() / 1000000000 end
	elseif type(options.scheduler.now) == "function" then
		_clock = options.scheduler.now
	end
	-- Native configuration has committed, but the public readiness bit belongs to
	-- the whole Lua transaction (bound receive socket + committed pump timer).
	_configured = false
	_inflight = nil
	_drain_error = nil
	_last_error = nil
	_reported_error = nil

	local socket_ok, socket_or_err = pcall(udp.new, socket_callback)
	if not socket_ok or socket_or_err == nil or socket_or_err == false then
		return false, "UDP socket construction failed: " .. tostring(socket_or_err)
	end
	local candidate = socket_or_err
	_socket = candidate
	if type(candidate.setBufferSize) == "function" then pcall(candidate.setBufferSize, candidate, 65535) end
	-- An unconnected client is not guaranteed to own a local UDP port until its
	-- first send. Bind port zero explicitly so the native ACK always has a live
	-- receive endpoint before the runtime pump can transmit sequence one.
	if type(candidate.listen) ~= "function" or type(candidate.receive) ~= "function" then
		rollback_runtime_candidate(candidate)
		return false, "UDP socket has no listen/receive method"
	end
	local listen_ok, listening_or_err = pcall(candidate.listen, candidate, 0)
	if not listen_ok or listening_or_err == nil or listening_or_err == false then
		rollback_runtime_candidate(candidate)
		return false, "UDP ephemeral bind failed: " .. tostring(listening_or_err)
	end
	local receive_ok, receiving_or_err = pcall(candidate.receive, candidate)
	if not receive_ok or receiving_or_err == nil or receiving_or_err == false then
		rollback_runtime_candidate(candidate)
		return false, "UDP receive activation failed: " .. tostring(receiving_or_err)
	end

	_scheduler = options.scheduler
	local timer_ok, handle_or_err, timer_committed = pcall(
		_scheduler.every,
		PUMP_INTERVAL_SEC,
		pump_boundary
	)
	if not timer_ok or timer_committed ~= true or type(handle_or_err) ~= "table" then
		if type(handle_or_err) == "table" then
			_timer_handle = handle_or_err
			local cancel_ok, cancelled = pcall(_scheduler.cancel, handle_or_err)
			if cancel_ok and cancelled == true then _timer_handle = nil end
		end
		if _timer_handle == nil then close_runtime_socket() end
		return false, "logger pump timer failed to commit: " .. tostring(handle_or_err)
	end
	_timer_handle = handle_or_err
	-- Native configure resets its per-session sequence authority to zero. A new
	-- committed Lua session is reachable only after stop proved the old deque and
	-- in-flight owner empty, so sequence one is both necessary and safe here.
	_next_sequence = 1
	_queued_noncritical = 0
	_rejected_errors = {}
	_rejected_error_head = 1
	_rejected_error_tail = 0
	_dropped_total = 0
	_dropped_critical = 0
	_dropped_by_variant = {}
	_rejected_error_overflow = 0
	_active = true
	_accepting = true
	_configured = true
	if type(_on_ready) == "function" then
		local callback = _on_ready
		_on_ready = nil
		local ready_ok, ready_err = xpcall(callback, debug.traceback)
		if not ready_ok then set_error("ready callback failed: " .. tostring(ready_err), true) end
	end
	return true
end

--- Enqueues one immutable producer record without crossing an async boundary.
--- @param line string Fully formatted canonical line.
--- @param variant string Shared-core variant name.
--- @return table|nil record Retained producer, used for post-delivery metadata.
--- @return string|nil error_message
--- @return table|nil rejected_record Bounded ERROR fallback retained for timer delivery.
function M.enqueue(line, variant)
	if not _active or not _accepting then return nil, "asynchronous logger transport is not accepting" end
	if type(line) ~= "string" or line == "" then return nil, "line must be a non-empty string" end
	if type(variant) ~= "string" or variant == "" then return nil, "variant must be a non-empty string" end
	variant = variant:lower()
	if ACCEPTED_VARIANTS[variant] ~= true then return nil, "variant is not canonical" end
	local critical = variant == "warn" or variant == "error"
	if #line > MAX_ENQUEUED_LINE_BYTES then
		_dropped_total = _dropped_total + 1
		if critical then _dropped_critical = _dropped_critical + 1 end
		_dropped_by_variant[variant] = (_dropped_by_variant[variant] or 0) + 1
		set_error(string.format(
			"asynchronous logger record exceeds the %d bytes admission ceiling",
			MAX_ENQUEUED_LINE_BYTES))
		-- In particular, do not retain an oversized ERROR in the fallback deque:
		-- that would recreate the same unbounded residency outside the main queue.
		return nil, _last_error
	end
	if queue_count() + 1 > MAX_QUEUED_RECORDS
		or (not critical and _queued_noncritical + 1 > MAX_NONCRITICAL_QUEUED_RECORDS) then
		_dropped_total = _dropped_total + 1
		if critical then _dropped_critical = _dropped_critical + 1 end
		_dropped_by_variant[variant] = (_dropped_by_variant[variant] or 0) + 1
		local rejected_record = nil
		if variant == "error" then
			rejected_record = {
				line = line,
				variant = variant,
				critical = true,
				rejected = true,
			}
			if rejected_error_count() < MAX_REJECTED_ERROR_RECORDS then
				rejected_error_push(rejected_record)
			else
				_rejected_error_overflow = _rejected_error_overflow + 1
				rejected_record = nil
			end
		end
		set_error("asynchronous logger queue capacity was exhausted")
		return nil, _last_error, rejected_record
	end
	local record = {
		line = line,
		variant = variant,
		critical = critical,
		enqueue_calendar_date = os.date("%Y-%m-%d"),
	}
	queue_push(record)
	if not critical then _queued_noncritical = _queued_noncritical + 1 end
	return record
end

--- Requests an asynchronous drain. The callback always runs from the pump timer,
--- never from the initiating eventtap. Producers remain accepted while records
--- are in flight so a reload-to-quit upgrade can append its quit-only diagnostics;
--- the pump fences them atomically at the first observed empty-queue boundary.
--- @param callback function Receives `(settled, detail)`.
--- @param timeout_sec number|nil Positive timeout, capped at two seconds.
--- @return boolean accepted
--- @return string|nil error_message
function M.drain(callback, timeout_sec)
	if not _active then return false, "asynchronous logger transport is inactive" end
	if type(callback) ~= "function" then return false, "drain callback must be a function" end
	if _drain_callback ~= nil then return false, "logger drain is already pending" end
	local timeout = tonumber(timeout_sec) or DEFAULT_DRAIN_TIMEOUT_SEC
	if timeout <= 0 or timeout > DEFAULT_DRAIN_TIMEOUT_SEC then
		return false, "logger drain timeout must be positive and bounded"
	end
	_drain_callback = callback
	_drain_deadline = now() + timeout
	_drain_error = nil
	return true
end

--- Stops owned native resources only after the retained queue is empty.
--- @return boolean settled
function M.stop()
	if queue_count() > 0 or rejected_error_count() > 0
		or _inflight ~= nil or _drain_callback ~= nil then
		set_error("logger stop refused while retained records or a drain remain")
		return false
	end
	-- Fence producers before releasing the only pump. If a later socket close
	-- refuses, the exact socket stays retryable but no undrainable record can be
	-- appended beside a transport that no longer owns a timer.
	_accepting = false
	if _timer_handle ~= nil then
		if _scheduler == nil or type(_scheduler.cancel) ~= "function" then
			set_error("logger pump timer has no cancellation owner")
			return false
		end
		local ok, settled = pcall(_scheduler.cancel, _timer_handle)
		if not ok or settled ~= true then
			set_error("logger pump timer refused cancellation")
			return false
		end
		_timer_handle = nil
	end
	if not close_runtime_socket() then return false end
	if not close_bootstrap_socket() then return false end
	_active = false
	_accepting = false
	_configured = false
	_socket = nil
	_timer_handle = nil
	_scheduler = nil
	_inflight = nil
	_drain_error = nil
	return true
end

--- Returns a read-only status snapshot for health checks and causal tests.
function M.status()
	return {
		active = _active,
		accepting = _accepting,
		configured = _configured,
		queued = queue_count(),
		max_record_bytes = MAX_ENQUEUED_LINE_BYTES,
		dropped_total = _dropped_total,
		dropped_noncritical = _dropped_total - _dropped_critical,
		dropped_critical = _dropped_critical,
		dropped_by_variant = dropped_by_variant_snapshot(),
		rejected_error_fallback_queued = rejected_error_count(),
		rejected_error_fallback_overflow = _rejected_error_overflow,
		inflight_sequence = _inflight and _inflight.sequence or nil,
		draining = _drain_callback ~= nil,
		last_error = _last_error,
	}
end

return M
