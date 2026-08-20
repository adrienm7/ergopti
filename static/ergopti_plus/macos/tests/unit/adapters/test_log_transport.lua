--- tests/unit/adapters/test_log_transport.lua

--- ==============================================================================
--- MODULE: Asynchronous Log Transport Behavioral Tests
--- DESCRIPTION:
--- Drives the authenticated UDP mailbox as a state machine. These tests assert
--- observable queue, retry, ACK, and ownership behavior; they deliberately avoid
--- source scans so a refactor cannot keep the test green while restoring HID-path
--- I/O or allowing an unrelated datagram to retire a queued record.
--- ==============================================================================

local helpers = require("tests.helpers")

local TOKEN = string.rep("transport-secret-", 3)
local SESSION = "lua-runtime-session-17"
local LOOPBACK = { host = "127.0.0.1", port = 49321 }





-- ==================================================
-- ==================================================
-- ======= 1/ Authenticated Transport Harness =======
-- ==================================================
-- ==================================================

--- Creates a fresh transport with controllable native socket and scheduler ports.
--- @param config table|nil Fault-injection options.
--- @return table context Transport plus observable test-double state.
local function new_context(config)
	config = config or {}
	package.loaded["adapters.log_transport"] = nil
	package.loaded["tests.stubs.hs"] = nil
	package.loaded["hs"] = nil

	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()

	local state = {
		clock = 100,
		bootstrap_new_calls = 0,
		bootstrap_close_calls = 0,
		new_calls = 0,
		preflight_payloads = {},
		preflight_timeouts = {},
		listen_calls = 0,
		receive_calls = 0,
		close_calls = 0,
		cancel_calls = 0,
		cancel_handles = {},
		every_calls = 0,
		after_calls = 0,
		sends = {},
		delivered = {},
		failures = {},
		route_calls = 0,
		activation_order = {},
	}

	local socket = {}
	function socket:setBufferSize(size)
		state.buffer_size = size
		return self
	end
	if config.no_listen ~= true then
		function socket:listen(port)
			state.listen_calls = state.listen_calls + 1
			state.listen_port = port
			state.activation_order[#state.activation_order + 1] = "listen"
			if config.listen_mode == "throw" then error("synthetic listen failure") end
			if config.listen_mode == "false" then return false end
			if config.listen_mode == "nil" then return nil end
			return self
		end
	end
	if config.no_receive ~= true then
		function socket:receive()
			state.receive_calls = state.receive_calls + 1
			state.activation_order[#state.activation_order + 1] = "receive"
			if config.receive_mode == "throw" then error("synthetic receive failure") end
			if config.receive_mode == "false" then return false end
			if config.receive_mode == "nil" then return nil end
			return self
		end
	end
	function socket:send(data, host, port, tag)
		state.sends[#state.sends + 1] = {
			data = data,
			host = host,
			port = port,
			tag = tag,
		}
		if state.send_mode == "throw" then error("synthetic send failure") end
		if state.send_mode == "false" then return false end
		if state.send_mode == "nil" then return nil end
		return self
	end
	function socket:close()
		state.close_calls = state.close_calls + 1
		if state.close_mode == "throw" then error("synthetic close failure") end
		if state.close_mode == "false" then return false end
		return self
	end

	local udp = {}
	function udp.new(callback)
		state.new_calls = state.new_calls + 1
		if config.construct_mode == "throw" then error("synthetic construction failure") end
		if config.construct_mode == "false" then return false end
		if config.construct_mode == "nil" then return nil end
		state.receive_callback = callback
		return socket
	end
	if not config.no_parse_address then
		function udp.parseAddress(address)
			if config.parse_address_mode == "throw" then error("synthetic address parse failure") end
			if config.parse_address_mode == "nil" then return nil end
			if type(address) == "table" then return address end
			return { host = tostring(address) }
		end
	end

	if config.no_udp then
		hs_stub.socket = {}
	else
		hs_stub.socket = { udp = udp }
	end
	if config.no_settings then hs_stub.settings = nil end
	if config.no_json then hs_stub.json = nil end
	if config.previous_session and hs_stub.settings then
		hs_stub.settings.set("ergopti.logger.transport_session", config.previous_session)
	end
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	local scheduler = {}
	function scheduler.every(interval, callback)
		state.every_calls = state.every_calls + 1
		state.activation_order[#state.activation_order + 1] = "timer"
		state.every_interval = interval
		state.pump = callback
		if config.every_mode == "throw" then error("synthetic timer acquisition failure") end
		if config.every_mode == "nil" then return nil, nil end
		local handle = { identity = "pump-handle-" .. tostring(state.every_calls) }
		state.timer_handle = handle
		if config.every_mode == "refuse" then return handle, false end
		return handle, true
	end
	function scheduler.cancel(handle)
		state.cancel_calls = state.cancel_calls + 1
		state.cancel_handles[#state.cancel_handles + 1] = handle
		if state.cancel_mode == "throw" then error("synthetic cancellation failure") end
		if state.cancel_mode == "false" then return false end
		return true
	end
	function scheduler.after(delay, callback)
		state.after_calls = state.after_calls + 1
		state.shutdown_timeout = delay
		state.shutdown_deadline = callback
		local handle = { identity = "shutdown-deadline-" .. tostring(state.after_calls) }
		state.shutdown_handle = handle
		if state.after_mode == "throw" then error("synthetic deadline acquisition failure") end
		if state.after_mode == "refuse" then return handle, false end
		return handle, true
	end
	function scheduler.now_ns()
		return state.clock * 1000000000
	end

	local transport = require("adapters.log_transport")
	local bootstrap = {}
	function bootstrap:settimeout(timeout_sec)
		state.preflight_timeouts[#state.preflight_timeouts + 1] = timeout_sec
		if state.bootstrap_timeout_mode == "throw" then error("synthetic timeout configuration failure") end
		if state.bootstrap_timeout_mode == "false" then return false end
		return self
	end
	function bootstrap:sendto(payload, host, port)
		state.preflight_payloads[#state.preflight_payloads + 1] = payload
		state.sends[#state.sends + 1] = {
			data = payload,
			host = host,
			port = port,
			tag = 0,
			bootstrap = true,
		}
		state.preflight_request = hs_stub.json and hs_stub.json.decode(payload) or nil
		if state.bootstrap_send_mode == "throw" then error("synthetic bootstrap send failure") end
		if state.bootstrap_send_mode == "short" then return math.max(0, #payload - 1) end
		if state.bootstrap_send_mode == "false" then return false end
		return #payload
	end
	function bootstrap:receivefrom()
		local request = state.preflight_request
		if state.preflight_mode == "timeout" then return nil, "synthetic ACK timeout" end
		if state.preflight_mode == "throw" then error("synthetic receive failure") end
		local response = {
			v = 1,
			kind = "ack",
			token = TOKEN,
			session = request and request.session or SESSION,
			ack = 0,
		}
		if state.preflight_mode == "wrong-token" then response.token = string.rep("x", 32) end
		if state.preflight_mode == "wrong-session" then response.session = "wrong-session" end
		if state.preflight_mode == "wrong-sequence" then response.ack = 1 end
		if state.preflight_mode == "nack" then
			response.kind = "nack"
			response.ack = nil
			response.reason = "configure_failed"
		end
		local address = state.preflight_address or LOOPBACK
		return hs_stub.json.encode(response), address.host, address.port
	end
	function bootstrap:close()
		state.bootstrap_close_calls = state.bootstrap_close_calls + 1
		if state.bootstrap_close_mode == "throw" then error("synthetic bootstrap close failure") end
		if state.bootstrap_close_mode == "false" then return false end
		return self
	end
	if config.no_bootstrap_timeout then bootstrap.settimeout = nil end
	if config.no_bootstrap_send then bootstrap.sendto = nil end
	if config.no_bootstrap_receive then bootstrap.receivefrom = nil end
	if config.no_bootstrap_close then bootstrap.close = nil end

	local options = {
		port = 49321,
		token = TOKEN,
		session = config.no_explicit_session and nil or SESSION,
		log_dir = "/tmp/ergopti/logs",
		retention_days = 21,
		max_batch_records = config.batch_records or 1,
		route_overlap_bytes = config.route_overlap_bytes or 16,
		scheduler = scheduler,
		clock = function() return state.clock end,
		bootstrap_socket_factory = function()
			state.bootstrap_new_calls = state.bootstrap_new_calls + 1
			if state.bootstrap_construct_mode == "throw" then
				error("synthetic bootstrap construction failure")
			end
			if state.bootstrap_construct_mode == "nil" then return nil end
			return bootstrap
		end,
		route_line = function(line)
			state.route_calls = state.route_calls + 1
			if state.route_mode == "throw" then error("synthetic routing failure") end
			if state.route_mode == "invalid" then return false end
			return line:find("LLM", 1, true) and { "ErgoptiPlus_llm.log" } or {}
		end,
		on_delivered = function(record)
			state.delivered[#state.delivered + 1] = record
			if state.delivered_mode == "throw" then error("synthetic delivery failure") end
			if state.delivered_mode == "false" then
				return false, "synthetic delivery refusal"
			end
			return true
		end,
		on_failed = function(message)
			state.failures[#state.failures + 1] = message
			if state.failure_mode == "throw" then error("synthetic failure callback failure") end
		end,
	}

	local context = {
		hs = hs_stub,
		options = options,
		scheduler = scheduler,
		socket = socket,
		state = state,
		transport = transport,
	}
	function context:start()
		return transport.start(options)
	end
	function context:payload(index)
		local sent = state.sends[index or #state.sends]
		local decoded = sent and hs_stub.json.decode(sent.data) or nil
		if type(decoded) == "table" and decoded.kind == "batch"
			and type(decoded.records) == "table" and #decoded.records == 1 then
			local record = decoded.records[1]
			record.v = decoded.v
			record.token = decoded.token
			record.session = decoded.session
			record.kind = "record"
			return record
		end
		return decoded
	end
	function context:batch(index)
		local sent = state.sends[index or #state.sends]
		return sent and hs_stub.json.decode(sent.data) or nil
	end
	function context:ack(sequence, overrides, address)
		local body = {
			v = 1,
			kind = "ack",
			token = TOKEN,
			session = SESSION,
			ack = sequence,
		}
		for key, value in pairs(overrides or {}) do body[key] = value end
		state.receive_callback(hs_stub.json.encode(body), address or LOOPBACK)
	end
	function context:raw_ack(data, address)
		state.receive_callback(data, address or LOOPBACK)
	end
	return context
end

--- Completes the configure handshake sent synchronously by start().
--- @param context table Harness returned by new_context().
local function configure(context)
	local started, start_err = context:start()
	helpers.assert_eq(started, true, "transport fixture must start: " .. tostring(start_err))
	helpers.assert_eq(#context.state.sends, 1, "start must send one configure datagram")
	helpers.assert_eq(context.transport.status().configured, true)
end





-- ===============================================
-- ===============================================
-- ======= 2/ Producer Purity And Ordering =======
-- ===============================================
-- ===============================================

helpers.describe("LogTransport producer purity", function()
	helpers.it("enqueue mutates memory only and defers every external side effect", function()
		local context = new_context()
		configure(context)
		local sends_before = #context.state.sends
		local delivered_before = #context.state.delivered
		local print_calls = 0
		local open_calls = 0
		local execute_calls = 0
		local task_calls = 0
		local setting_calls = 0
		local notify_calls = 0
		local every_before = context.state.every_calls
		local after_before = context.state.after_calls
		local original_print = _G.print
		local original_open = io.open
		local original_execute = os.execute
		local original_hs_execute = context.hs.execute
		local original_task_new = context.hs.task and context.hs.task.new
		local original_settings_set = context.hs.settings.set
		local original_settings_clear = context.hs.settings.clear
		_G.print = function() print_calls = print_calls + 1 end
		io.open = function() open_calls = open_calls + 1; return nil end
		os.execute = function() execute_calls = execute_calls + 1; return false end
		context.hs.execute = function() execute_calls = execute_calls + 1; return "", false end
		context.hs.task = context.hs.task or {}
		context.hs.task.new = function() task_calls = task_calls + 1; return nil end
		context.hs.settings.set = function(...)
			setting_calls = setting_calls + 1
			return original_settings_set(...)
		end
		context.hs.settings.clear = function(...)
			setting_calls = setting_calls + 1
			return original_settings_clear(...)
		end
		context.hs.notify = {
			new = function() notify_calls = notify_calls + 1; return {} end,
		}

		local call_ok, record, enqueue_err = pcall(
			context.transport.enqueue,
			"2026-08-14 12:00:00 | DEBUG | keymap | LLM candidate",
			"DEBUG"
		)
		_G.print = original_print
		io.open = original_open
		os.execute = original_execute
		context.hs.execute = original_hs_execute
		context.hs.task.new = original_task_new
		context.hs.settings.set = original_settings_set
		context.hs.settings.clear = original_settings_clear

		helpers.assert_true(call_ok, "enqueue must not throw: " .. tostring(record))
		helpers.assert_not_nil(record, tostring(enqueue_err))
		helpers.assert_eq(#context.state.sends, sends_before,
			"enqueue must not call the UDP socket from an HID producer")
		helpers.assert_eq(context.state.route_calls, 0,
			"topical routing must execute in the timer pump, not enqueue")
		helpers.assert_eq(#context.state.delivered, delivered_before,
			"delivery hooks, including notifications, require a durable ACK")
		helpers.assert_eq(print_calls, 0, "enqueue must not write to the HS console")
		helpers.assert_eq(open_calls, 0, "enqueue must not touch the filesystem")
		helpers.assert_eq(execute_calls, 0, "enqueue must not run a blocking shell command")
		helpers.assert_eq(task_calls, 0, "enqueue must not launch a process")
		helpers.assert_eq(setting_calls, 0, "enqueue must not persist session state")
		helpers.assert_eq(context.state.every_calls, every_before,
			"enqueue must not acquire another periodic timer")
		helpers.assert_eq(context.state.after_calls, after_before,
			"enqueue must not defer work by acquiring a one-shot timer itself")
		helpers.assert_eq(notify_calls, 0, "enqueue must not create a notification")
		helpers.assert_eq(context.transport.status().queued, 1)
	end)

	helpers.it("does zero fragmentation, sanitation, routing, or JSON work for a huge malformed enqueue", function()
		local context = new_context()
		configure(context)
		local hostile = string.rep(string.char(128), 16 * 8000)
		local original_sub = string.sub
		local original_byte = string.byte
		local original_encode = context.hs.json.encode
		local sub_calls = 0
		local byte_calls = 0
		local encode_calls = 0
		string.sub = function(...)
			sub_calls = sub_calls + 1
			return original_sub(...)
		end
		string.byte = function(...)
			byte_calls = byte_calls + 1
			return original_byte(...)
		end
		context.hs.json.encode = function(...)
			encode_calls = encode_calls + 1
			return original_encode(...)
		end

		local call_ok, retained, enqueue_err = pcall(context.transport.enqueue, hostile, "error")
		local enqueue_sub_calls = sub_calls
		local enqueue_byte_calls = byte_calls
		local enqueue_encode_calls = encode_calls
		local enqueue_route_calls = context.state.route_calls
		local pump_ok, pump_err = pcall(function()
			context.state.pump()
			context.state.pump()
		end)
		string.sub = original_sub
		string.byte = original_byte
		context.hs.json.encode = original_encode

		helpers.assert_true(call_ok, "hostile enqueue must not throw: " .. tostring(retained))
		helpers.assert_not_nil(retained, tostring(enqueue_err))
		helpers.assert_eq(enqueue_sub_calls, 0,
			"enqueue must retain the original string reference without fragment substrings")
		helpers.assert_eq(enqueue_byte_calls, 0,
			"enqueue must not validate or sanitize user-derived bytes")
		helpers.assert_eq(enqueue_encode_calls, 0,
			"enqueue must not construct a native payload")
		helpers.assert_eq(enqueue_route_calls, 0,
			"enqueue must not derive topical routes")
		helpers.assert_eq(context.transport.status().queued, 1,
			"a huge producer consumes one capacity slot, not one slot per fragment")
		helpers.assert_true(pump_ok, "timer-owned preparation must contain hostile bytes: "
			.. tostring(pump_err))
		helpers.assert_true(sub_calls > 0 and byte_calls > 0 and encode_calls > 0,
			"fragmentation, sanitation, and JSON must move to the timer pump")
		helpers.assert_true(context.state.route_calls > 0,
			"topical routing must move to the timer pump")
	end)
end)

helpers.describe("LogTransport configure and one-in-flight protocol", function()
	helpers.it("returns startup success only after a bounded exact configure ACK", function()
		local context = new_context()
		local started, start_err = context:start()
		helpers.assert_eq(started, true, tostring(start_err))
		helpers.assert_eq(context.state.bootstrap_new_calls, 1)
		helpers.assert_eq(context.state.bootstrap_close_calls, 1,
			"the boot-only blocking socket must be closed before runtime activation")
		helpers.assert_true(
			type(context.state.preflight_timeouts[1]) == "number"
				and context.state.preflight_timeouts[1] > 0
				and context.state.preflight_timeouts[1] <= 0.25,
			"boot preflight must have a short positive deadline"
		)
		helpers.assert_eq(context.state.listen_calls, 1)
		helpers.assert_eq(context.state.listen_port, 0,
			"the runtime socket needs a concrete ephemeral ACK endpoint")
		helpers.assert_eq(table.concat(context.state.activation_order, ","), "listen,receive,timer",
			"bind and receive must commit before the pump can send sequence one")
		helpers.assert_eq(context.transport.status().configured, true)
	end)

	helpers.it("rejects caller attempts to widen or disable the boot deadline", function()
		for _, timeout in ipairs({ -1, 0, 0.251, 5 }) do
			local context = new_context()
			context.options.bootstrap_timeout_sec = timeout
			local started = context:start()
			helpers.assert_eq(started, false, "timeout=" .. tostring(timeout))
			helpers.assert_eq(#context.state.preflight_payloads, 0,
				"an invalid deadline must fail before a blocking receive becomes possible")
			helpers.assert_eq(context.state.bootstrap_close_calls, 1,
				"the exact bootstrap handle must still be released")
			helpers.assert_eq(context.state.new_calls, 0)
		end
	end)

	helpers.it("refuses timeout, NACK, wrong identity, and wrong source before input", function()
		local cases = {
			{ name = "timeout", mode = "timeout" },
			{ name = "native NACK", mode = "nack" },
			{ name = "wrong token", mode = "wrong-token" },
			{ name = "wrong session", mode = "wrong-session" },
			{ name = "wrong sequence", mode = "wrong-sequence" },
			{ name = "wrong source host", address = { host = "192.0.2.9", port = 49321 } },
			{ name = "wrong source port", address = { host = "127.0.0.1", port = 49322 } },
		}
		for _, case in ipairs(cases) do
			local context = new_context()
			context.state.preflight_mode = case.mode
			context.state.preflight_address = case.address
			local started = context:start()
			helpers.assert_eq(started, false,
				case.name .. " is not evidence that the native sink committed")
			helpers.assert_eq(context.transport.status().configured, false)
			helpers.assert_eq(context.transport.status().active, false)
			helpers.assert_eq(context.state.every_calls, 0,
				case.name .. " must not arm the runtime pump before preflight succeeds")
		end
	end)

	helpers.it("sends configure sequence zero before any queued record", function()
		local context = new_context()
		local started, start_err = context:start()
		helpers.assert_eq(started, true, tostring(start_err))
		local configure_payload = context:payload(1)
		helpers.assert_eq(configure_payload.v, 1)
		helpers.assert_eq(configure_payload.kind, "configure")
		helpers.assert_eq(configure_payload.sequence, 0)
		helpers.assert_eq(configure_payload.token, TOKEN)
		helpers.assert_eq(configure_payload.session, SESSION)
		helpers.assert_eq(configure_payload.log_dir, "/tmp/ergopti/logs")
		helpers.assert_eq(configure_payload.retention_days, 21)

		-- Deliberately differs from the wall date. A record retained across midnight
		-- belongs to the date already frozen into its canonical timestamp, not the
		-- later retry/pump date.
		local first_line = "2001-02-03 12:00:00:001 | INFO | test | LLM first"
		context.transport.enqueue(first_line, "info")
		context.state.pump()
		helpers.assert_eq(#context.state.sends, 2,
			"record sequence one may follow only after preflight ACKed sequence zero")
		local record_payload = context:payload(2)
		helpers.assert_eq(record_payload.kind, "record")
		helpers.assert_eq(record_payload.sequence, 1)
		helpers.assert_eq(record_payload.line, first_line)
		helpers.assert_eq(record_payload.calendar_date, "2001-02-03",
			"worker date rotation must derive from the canonical record timestamp")
		helpers.assert_eq(record_payload.topics[1], "ErgoptiPlus_llm.log",
			"topical routes must use the native worker's validated filename contract")
	end)

	helpers.it("keeps exactly one record in flight and delivers in queue order", function()
		local context = new_context()
		configure(context)
		context.transport.enqueue("one", "info")
		context.transport.enqueue("two", "warn")
		context.state.pump()
		helpers.assert_eq(#context.state.sends, 2)
		local first_payload = context:payload()
		helpers.assert_eq(first_payload.sequence, 1)
		helpers.assert_nil(first_payload.topics,
			"an empty Lua table encodes ambiguously; the wire contract omits empty topics")

		context.state.pump()
		helpers.assert_eq(#context.state.sends, 2,
			"a second queue entry must not overtake an unacknowledged head")
		context:ack(1)
		helpers.assert_eq(#context.state.delivered, 1)
		helpers.assert_eq(context.state.delivered[1].line, "one")
		context.state.pump()
		helpers.assert_eq(context:payload().sequence, 2)
		context:ack(2)

		helpers.assert_eq(#context.state.delivered, 2)
		helpers.assert_eq(context.state.delivered[2].line, "two")
		helpers.assert_eq(context.transport.status().queued, 0)
	end)

	helpers.it("encodes one complete short-record batch once instead of serializing every prefix", function()
		local context = new_context({ batch_records = 64 })
		configure(context)
		local original_encode = context.hs.json.encode
		local batch_encode_calls = 0
		context.hs.json.encode = function(value)
			if type(value) == "table" and value.kind == "batch" then
				batch_encode_calls = batch_encode_calls + 1
			end
			return original_encode(value)
		end
		for index = 1, 64 do
			local retained, enqueue_err = context.transport.enqueue(
				"codec-linear-" .. tostring(index),
				"info"
			)
			helpers.assert_not_nil(retained, tostring(enqueue_err))
		end
		context.state.pump()
		context.hs.json.encode = original_encode
		local batch = context:batch()
		helpers.assert_eq(#batch.records, 64)
		helpers.assert_eq(batch_encode_calls, 1,
			"the timer hot path must encode the complete fitting batch only once")
		context:ack(64)
		helpers.assert_eq(context.transport.status().queued, 0)
	end)

	helpers.it("shrinks oversized JSON batches logarithmically without loss or reordering", function()
		local context = new_context({ batch_records = 64 })
		configure(context)
		local expected = {}
		for index = 1, 16 do
			local line = string.rep("\\", 7000) .. tostring(index)
			expected[index] = line
			local retained, enqueue_err = context.transport.enqueue(line, "info")
			helpers.assert_not_nil(retained, tostring(enqueue_err))
		end
		local original_encode = context.hs.json.encode
		local batch_encode_calls = 0
		context.hs.json.encode = function(value)
			if type(value) == "table" and value.kind == "batch" then
				batch_encode_calls = batch_encode_calls + 1
			end
			return original_encode(value)
		end
		local completion = nil
		helpers.assert_true(context.transport.drain(function(settled, detail)
			completion = { settled = settled, detail = detail }
		end, 2.0))

		local expected_sequence = 1
		local batch_count = 0
		local body_ok, body_err = xpcall(function()
			while context.transport.status().queued > 0 do
				batch_count = batch_count + 1
				context.state.pump()
				local sent = context.state.sends[#context.state.sends]
				local batch = context:batch()
				helpers.assert_eq(batch.kind, "batch")
				helpers.assert_true(#batch.records > 0 and #batch.records < 16,
					"the oversized full candidate must reduce to a non-empty fitting prefix")
				helpers.assert_true(#sent.data < 60000)
				for _, record in ipairs(batch.records) do
					helpers.assert_eq(record.sequence, expected_sequence)
					helpers.assert_eq(record.line, expected[expected_sequence])
					expected_sequence = expected_sequence + 1
				end
				context:ack(batch.records[#batch.records].sequence)
			end
		end, debug.traceback)
		context.hs.json.encode = original_encode
		helpers.assert_true(body_ok, tostring(body_err))
		helpers.assert_eq(expected_sequence, 17)
		helpers.assert_true(batch_encode_calls > batch_count,
			"the fixture must exercise the too-large reduction branch")
		helpers.assert_true(batch_encode_calls <= batch_count * 7,
			"64 candidates need at most one full encode plus six binary-search probes")
		helpers.assert_eq(#context.state.delivered, 16)
		for index, delivered in ipairs(context.state.delivered) do
			helpers.assert_eq(delivered.sequence, index)
			helpers.assert_eq(delivered.line, expected[index])
		end
		helpers.assert_nil(completion,
			"the final socket ACK must leave terminal continuation to the pump")
		context.state.pump()
		helpers.assert_eq(completion.settled, true, tostring(completion.detail))
	end)

	helpers.it("preserves FIFO order across the deque compaction boundary", function()
		local context = new_context()
		configure(context)
		local count = 1030
		for index = 1, count do
			local record, enqueue_err = context.transport.enqueue(
				"ordered-record-" .. tostring(index),
				"info"
			)
			helpers.assert_not_nil(record, tostring(enqueue_err))
		end

		for index = 1, count do
			context.state.pump()
			local payload = context:payload()
			helpers.assert_eq(payload.sequence, index)
			helpers.assert_eq(payload.line, "ordered-record-" .. tostring(index),
				"deque compaction must not skip, duplicate, or reorder a retained record")
			context:ack(index)
		end
		helpers.assert_eq(context.transport.status().queued, 0)
		helpers.assert_eq(#context.state.delivered, count)
		helpers.assert_eq(context.state.delivered[count].line, "ordered-record-" .. tostring(count))
	end)

	helpers.it("bounds ordinary traffic while reserving exact warning/error ownership", function()
		local context = new_context()
		configure(context)
		for index = 1, 7168 do
			local record = context.transport.enqueue("capacity-" .. tostring(index), "trace")
			helpers.assert_not_nil(record, "the ordinary queue capacity must remain usable")
		end
		local refused, refusal = context.transport.enqueue("capacity-overflow", "trace")
		helpers.assert_nil(refused)
		helpers.assert_contains(refusal, "capacity",
			"overflow must fail visibly instead of silently evicting an earlier record")

		local diagnostic, diagnostic_err = context.transport.enqueue(
			"diagnostic after ordinary saturation",
			"error"
		)
		helpers.assert_not_nil(diagnostic,
			"ordinary saturation must not consume the ERROR ownership reserve: "
				.. tostring(diagnostic_err))
		for index = 2, 1024 do
			local retained = context.transport.enqueue("reserved-warning-" .. tostring(index), "warn")
			helpers.assert_not_nil(retained, "the complete diagnostic reserve must be usable")
		end
		local full_refusal, full_detail = context.transport.enqueue("absolute-overflow", "error")
		helpers.assert_nil(full_refusal)
		helpers.assert_contains(full_detail, "capacity")
		helpers.assert_eq(context.transport.status().queued, 8192)
		helpers.assert_eq(#context.state.failures, 0,
			"producer-side capacity refusal must not call the fail-safe on the HID stack")

		context.state.pump()
		helpers.assert_eq(#context.state.failures, 1,
			"the next timer-owned pump must surface producer-side capacity refusal")
		helpers.assert_contains(context.state.failures[1], "capacity")
	end)

	helpers.it("drains the maximum admitted backlog in FIFO batches before the two-second deadline", function()
		local context = new_context({ batch_records = 64 })
		configure(context)
		local expected = {}
		for index = 1, 7168 do
			local line = "backlog-normal-" .. tostring(index)
			expected[#expected + 1] = line
			local retained, enqueue_err = context.transport.enqueue(line, "trace")
			helpers.assert_not_nil(retained, tostring(enqueue_err))
		end
		for index = 7169, 8191 do
			local line = "backlog-critical-" .. tostring(index)
			expected[#expected + 1] = line
			local retained, enqueue_err = context.transport.enqueue(line, "warn")
			helpers.assert_not_nil(retained, tostring(enqueue_err))
		end
		local final_line = "backlog-critical-8192"
		expected[#expected + 1] = final_line
		local final_record, enqueue_err = context.transport.enqueue(final_line, "error")
		helpers.assert_not_nil(final_record, tostring(enqueue_err))
		final_record.notification = {
			module_name = "logger",
			message = "maximum backlog drained",
		}
		helpers.assert_eq(context.transport.status().queued, 8192,
			"the test must exercise the exact admitted producer ceiling")

		local completion = nil
		local drained, drain_err = context.transport.drain(function(settled, detail)
			completion = { settled = settled, detail = detail, clock = context.state.clock }
		end, 2.0)
		helpers.assert_true(drained, tostring(drain_err))

		local expected_sequence = 1
		local batch_count = 0
		local saw_full_batch = false
		while expected_sequence <= 8192 do
			batch_count = batch_count + 1
			helpers.assert_true(batch_count <= 200,
				"the admitted queue must not exceed its drain-timer pump budget")
			context.state.clock = context.state.clock + 0.01
			context.state.pump()
			local sent = context.state.sends[#context.state.sends]
			local batch = context:batch()
			helpers.assert_eq(batch.kind, "batch")
			helpers.assert_true(#batch.records >= 1 and #batch.records <= 64,
				"every datagram must carry one bounded non-empty record batch")
			if #batch.records == 64 then saw_full_batch = true end
			helpers.assert_true(#sent.data < 60000,
				"dynamic batching must stay below the authenticated datagram ceiling")
			for _, record in ipairs(batch.records) do
				helpers.assert_eq(record.sequence, expected_sequence)
				helpers.assert_eq(record.line, expected[expected_sequence],
					"batching must preserve exact producer FIFO order")
				expected_sequence = expected_sequence + 1
			end
			context:ack(batch.records[#batch.records].sequence)
			if expected_sequence <= 8192 then
				helpers.assert_nil(completion,
					"a partial backlog ACK cannot certify a completed drain")
			end
		end
		helpers.assert_true(saw_full_batch,
			"ordinary short records must exercise the complete 64-record batch capacity")
		helpers.assert_eq(expected_sequence, 8193)
		helpers.assert_eq(context.transport.status().queued, 0)
		helpers.assert_nil(completion,
			"the UDP callback must not run the timer-owned terminal continuation")
		context.state.clock = context.state.clock + 0.01
		context.state.pump()
		helpers.assert_not_nil(completion)
		helpers.assert_eq(completion.settled, true, tostring(completion.detail))
		helpers.assert_true(completion.clock < 102,
			"the maximum admitted queue must settle inside the two-second drain window")
		helpers.assert_eq(#context.state.delivered, 8192,
			"every ACKed batch record must reach the post-durability callback")
		local delivered_final = context.state.delivered[#context.state.delivered]
		helpers.assert_eq(delivered_final.line, final_line)
		helpers.assert_eq(delivered_final.notification.message, "maximum backlog drained",
			"a tail critical notification must not be starved behind ordinary traffic")
	end)

	helpers.it("fragments oversized UTF-8 records without losing ordered ownership", function()
		local context = new_context()
		configure(context)
		local line = "2026-08-14 12:00:00:001 | INFO | test | LLM "
			.. string.rep("x", 7952) .. "é" .. string.rep("y", 8050)
		local retained, enqueue_err = context.transport.enqueue(line, "info")
		helpers.assert_not_nil(retained, tostring(enqueue_err))
		local fragment_count = 3
		helpers.assert_eq(context.transport.status().queued, 1,
			"one producer must consume one queue slot before timer-owned fragmentation")

		for sequence = 1, fragment_count do
			context.state.pump()
			local payload = context:payload()
			helpers.assert_eq(payload.sequence, sequence)
			helpers.assert_eq(payload.calendar_date, "2026-08-14")
			helpers.assert_contains(payload.line,
				"[fragment " .. tostring(sequence) .. "/" .. tostring(fragment_count) .. "]")
			local utf8_ok, utf8_length = pcall(utf8.len, payload.line)
			helpers.assert_true(utf8_ok and utf8_length ~= nil,
				"a byte boundary must never publish malformed UTF-8")
			helpers.assert_eq(payload.topics[1], "ErgoptiPlus_llm.log",
				"each fragment must route from the immutable original record")
			context:ack(sequence)
		end
		helpers.assert_eq(context.transport.status().queued, 0)
	end)

	helpers.it("routes a literal that crosses a timer-owned fragment boundary", function()
		local context = new_context({ route_overlap_bytes = 2 })
		configure(context)
		local line = string.rep("x", 7999) .. "LLM" .. string.rep("y", 100)
		local retained, enqueue_err = context.transport.enqueue(line, "info")
		helpers.assert_not_nil(retained, tostring(enqueue_err))
		for sequence = 1, 2 do
			context.state.pump()
			local payload = context:payload()
			helpers.assert_eq(payload.sequence, sequence)
			helpers.assert_eq(payload.topics[1], "ErgoptiPlus_llm.log",
				"bounded routing windows must preserve a cross-boundary literal")
			context:ack(sequence)
		end
		helpers.assert_eq(context.transport.status().queued, 0)
	end)

	helpers.it("sanitizes malformed UTF-8 only off-HID and reuses the exact safe delivery", function()
		local context = new_context()
		configure(context)
		local raw_encode = context.hs.json.encode
		local record_encode_calls = 0
		context.hs.json.encode = function(value)
			if type(value) == "table" and value.kind == "batch" then
				record_encode_calls = record_encode_calls + 1
				for _, record in ipairs(value.records or {}) do
					local valid, length = pcall(utf8.len, record.line)
					if not valid or length == nil then error("synthetic JSON UTF-8 refusal") end
				end
			end
			return raw_encode(value)
		end

		local raw_line = "2026-08-14 | INFO | test | été bad" .. string.char(255) .. "tail"
		local retained, enqueue_err = context.transport.enqueue(raw_line, "info")
		helpers.assert_not_nil(retained, tostring(enqueue_err))
		retained.notification = {
			module_name = "module" .. string.char(254),
			message = "détail" .. string.char(128),
		}
		helpers.assert_eq(record_encode_calls, 0,
			"enqueue/eventtap must not scan or encode malformed UTF-8")
		helpers.assert_eq(retained.line, raw_line,
			"the immutable producer record must retain its byte-exact source")

		context.state.pump()
		helpers.assert_eq(record_encode_calls, 1)
		local payload = context:payload()
		local safe_line = "2026-08-14 | INFO | test | été bad\\xFFtail"
		helpers.assert_eq(payload.line, safe_line,
			"the native sink must receive an ASCII escape for each invalid byte")
		local valid, length = pcall(utf8.len, payload.line)
		helpers.assert_true(valid and length ~= nil, "the persisted line must be valid UTF-8")

		context:ack(1)
		helpers.assert_eq(#context.state.delivered, 1)
		helpers.assert_eq(context.state.delivered[1].line, safe_line,
			"post-ACK console output must reuse the native worker's exact safe line")
		helpers.assert_eq(context.state.delivered[1].notification.module_name, "module\\xFE")
		helpers.assert_eq(context.state.delivered[1].notification.message, "détail\\x80")
		helpers.assert_eq(#context.state.failures, 0,
			"one malformed user-derived diagnostic must not fail the transport")
	end)

	helpers.it("bounds long invalid-continuation runs before escaped UDP encoding", function()
		local context = new_context()
		configure(context)
		local line = string.rep("x", 8000) .. string.rep(string.char(128), 16000)
		local retained, enqueue_err = context.transport.enqueue(line, "warn")
		helpers.assert_not_nil(retained, tostring(enqueue_err))
		local fragment_count = 3
		helpers.assert_eq(context.transport.status().queued, 1,
			"an invalid continuation run remains one producer before the pump fragments it")

		for sequence = 1, fragment_count do
			context.state.pump()
			local sent = context.state.sends[#context.state.sends]
			helpers.assert_true(#sent.data < 60000,
				"escaped fragment must remain inside the authenticated UDP envelope")
			local payload = context:payload()
			local valid, length = pcall(utf8.len, payload.line)
			helpers.assert_true(valid and length ~= nil)
			context:ack(sequence)
		end
		helpers.assert_eq(context.transport.status().queued, 0)
		helpers.assert_eq(#context.state.failures, 0)
	end)
end)





-- ===============================================
-- ===============================================
-- ======= 3/ ACK Authentication And Retry =======
-- ===============================================
-- ===============================================

helpers.describe("LogTransport authenticated ACK handling", function()
	helpers.it("uses elapsed scheduler time when the process CPU clock is frozen", function()
		local context = new_context()
		context.options.clock = nil
		local original_clock = os.clock
		os.clock = function() return 7 end
		local call_ok, call_err = xpcall(function()
			configure(context)
			context.transport.enqueue("retry-on-monotonic-time", "error")
			context.state.pump()
			local sends_before_retry = #context.state.sends
			context.state.clock = context.state.clock + 0.51
			context.state.pump()
			helpers.assert_eq(#context.state.sends, sends_before_retry + 1,
				"ACK retry must advance from scheduler elapsed time, not CPU consumption")

			local completions = {}
			helpers.assert_eq(context.transport.drain(function(settled)
				completions[#completions + 1] = settled
			end, 0.25), true)
			context.state.clock = context.state.clock + 0.26
			context.state.pump()
			helpers.assert_eq(completions[1], false,
				"a retained record must hit its real elapsed-time drain deadline")
		end, debug.traceback)
		os.clock = original_clock
		if not call_ok then error(call_err, 0) end
	end)

	helpers.it("contains timer-owned routing failures and reports them off the HID path", function()
		local context = new_context()
		configure(context)
		context.transport.enqueue("route-me", "info")
		context.state.route_mode = "throw"
		local pump_ok, pump_err = pcall(context.state.pump)
		helpers.assert_true(pump_ok, "timer callback must contain routing exceptions: " .. tostring(pump_err))
		helpers.assert_eq(#context.state.sends, 1,
			"a record with no valid route payload cannot cross the socket boundary")
		helpers.assert_eq(context.transport.status().queued, 1)
		helpers.assert_eq(#context.state.failures, 1,
			"the async failure must reach the injected off-hotpath reporter")
		helpers.assert_contains(context.state.failures[1], "routing failure")

		context.state.route_mode = nil
		context.state.clock = context.state.clock + 0.51
		context.state.pump()
		helpers.assert_eq(context:payload().sequence, 1)
		context:ack(1)
		helpers.assert_eq(context.transport.status().queued, 0)
	end)

	helpers.it("contains delivery-hook exceptions after exact dequeue", function()
		local context = new_context()
		configure(context)
		context.state.delivered_mode = "throw"
		context.transport.enqueue("deliver-once", "done")
		context.state.pump()
		local callback_ok, callback_err = pcall(context.ack, context, 1)
		helpers.assert_true(callback_ok,
			"the native socket callback must contain delivery-hook exceptions: " .. tostring(callback_err))
		helpers.assert_eq(context.transport.status().queued, 0,
			"an exact durable ACK owns dequeue even when a secondary hook fails")
		helpers.assert_eq(#context.state.delivered, 1)
		helpers.assert_contains(context.transport.status().last_error, "delivery callback failed")
		helpers.assert_eq(#context.state.failures, 0,
			"receive callback containment must not invoke secondary user code re-entrantly")
		context.state.pump()
		helpers.assert_eq(#context.state.failures, 1)
		helpers.assert_contains(context.state.failures[1], "delivery callback failed")
	end)

	helpers.it("rejects malformed, stale, unauthenticated, and non-loopback ACKs", function()
		local context = new_context()
		configure(context)
		context.transport.enqueue("one", "INFO")
		context.transport.enqueue("two", "INFO")
		context.state.pump()

		local invalid = {
			function() context:raw_ack("{") end,
			function() context:raw_ack(context.hs.json.encode({
				kind = "ack", token = TOKEN, session = SESSION, ack = 1,
			})) end,
			function() context:raw_ack(context.hs.json.encode({
				v = 1, token = TOKEN, session = SESSION, ack = 1,
			})) end,
			function() context:raw_ack(context.hs.json.encode({
				v = 1, kind = "ack", session = SESSION, ack = 1,
			})) end,
			function() context:raw_ack(context.hs.json.encode({
				v = 1, kind = "ack", token = TOKEN, ack = 1,
			})) end,
			function() context:ack(1, nil, { host = "192.0.2.9" }) end,
			function() context:ack(1, nil, { host = "127.0.0.1", port = 49322 }) end,
			function() context:ack(1, { v = 2 }) end,
			function() context:ack(1, { kind = "nack" }) end,
			function() context:ack(1, { token = string.rep("wrong-token-", 4) }) end,
			function() context:ack(1, { session = "previous-runtime" }) end,
			function() context:ack(0) end,
			function() context:ack(1.5) end,
			function() context:raw_ack("[]") end,
		}
		for index, deliver in ipairs(invalid) do
			deliver()
			local status = context.transport.status()
			helpers.assert_eq(status.queued, 2,
				"invalid ACK case " .. tostring(index) .. " must retain the queue head")
			helpers.assert_eq(status.inflight_sequence, 1,
				"invalid ACK case " .. tostring(index) .. " must retain exact ownership")
			helpers.assert_eq(#context.state.delivered, 0)
		end

		context:ack(1)
		helpers.assert_eq(context.transport.status().queued, 1)
		helpers.assert_eq(#context.state.delivered, 1)
		context.state.pump()
		helpers.assert_eq(context.transport.status().inflight_sequence, 2)

		context:ack(1)
		helpers.assert_eq(context.transport.status().queued, 1,
			"a duplicate old ACK must not dequeue the new in-flight head")
		helpers.assert_eq(#context.state.delivered, 1)
		context:ack(2)
		helpers.assert_eq(context.transport.status().queued, 0)
		helpers.assert_eq(#context.state.delivered, 2)
	end)

	helpers.it("treats a native NACK as a visible refusal, never as delivery", function()
		local context = new_context()
		local started, start_err = context:start()
		helpers.assert_eq(started, true, tostring(start_err))
		context.transport.enqueue("must-stay-queued", "error")
		context.state.pump()
		context:raw_ack(context.hs.json.encode({
			v = 1,
			kind = "nack",
			token = TOKEN,
			session = SESSION,
			reason = "configure_failed",
		}))

		local status = context.transport.status()
		helpers.assert_eq(status.configured, true)
		helpers.assert_eq(status.inflight_sequence, 1,
			"a native refusal must retain the exact record in-flight owner")
		helpers.assert_eq(status.queued, 1,
			"a native refusal is not evidence that a queued record was delivered")
		helpers.assert_contains(status.last_error, "configure_failed",
			"the boot readiness gate needs the native refusal reason")
		helpers.assert_eq(#context.state.delivered, 0)
	end)

	helpers.it("retains and retries the identical queue head after ACK timeout", function()
		local context = new_context()
		configure(context)
		context.transport.enqueue("retry-me", "ERROR")
		context.state.pump()
		local first_send = context.state.sends[#context.state.sends]
		helpers.assert_eq(first_send.tag, 1)

		context.state.clock = context.state.clock + 0.49
		context.state.pump()
		helpers.assert_eq(#context.state.sends, 2,
			"the pump must not duplicate a record before its retry deadline")
		context.state.clock = context.state.clock + 0.02
		context.state.pump()
		helpers.assert_eq(#context.state.sends, 3)
		local retry_send = context.state.sends[#context.state.sends]
		helpers.assert_eq(retry_send.tag, 1)
		helpers.assert_eq(retry_send.data, first_send.data,
			"retry must reuse byte-identical authenticated payload for worker deduplication")
		helpers.assert_eq(context.transport.status().queued, 1,
			"timeout is not evidence of delivery and must not dequeue the head")

		context:ack(1)
		helpers.assert_eq(context.transport.status().queued, 0)
		helpers.assert_eq(#context.state.delivered, 1)
	end)

	helpers.it("replays a complete multi-record batch byte-identically until its final ACK", function()
		local context = new_context({ batch_records = 4 })
		configure(context)
		for index = 1, 4 do
			context.transport.enqueue("batch-retry-" .. tostring(index), "info")
		end
		context.state.pump()
		local first_send = context.state.sends[#context.state.sends]
		local first_batch = context:batch()
		helpers.assert_eq(first_batch.kind, "batch")
		helpers.assert_eq(#first_batch.records, 4)
		helpers.assert_eq(first_send.tag, 4,
			"the UDP tag and ACK authority belong to the final batch sequence")

		context:ack(1)
		helpers.assert_eq(context.transport.status().queued, 4,
			"an inner record ACK cannot retire any producer in the batch")
		helpers.assert_eq(#context.state.delivered, 0)
		context.state.clock = context.state.clock + 0.51
		context.state.pump()
		local retry_send = context.state.sends[#context.state.sends]
		helpers.assert_eq(retry_send.tag, 4)
		helpers.assert_eq(retry_send.data, first_send.data,
			"a lost final ACK must replay the byte-identical whole batch")
		context:ack(4)
		helpers.assert_eq(context.transport.status().queued, 0)
		helpers.assert_eq(#context.state.delivered, 4)
		for index, delivered in ipairs(context.state.delivered) do
			helpers.assert_eq(delivered.sequence, index)
			helpers.assert_eq(delivered.line, "batch-retry-" .. tostring(index))
		end
	end)

	helpers.it("backs off a refused send without dropping the queue head", function()
		local context = new_context()
		configure(context)
		context.transport.enqueue("send-refusal", "error")
		context.state.send_mode = "false"
		context.state.pump()
		helpers.assert_eq(#context.state.sends, 2)
		context.state.pump()
		helpers.assert_eq(#context.state.sends, 2,
			"one native send refusal must not create a 100 Hz retry spin")
		helpers.assert_eq(context.transport.status().queued, 1)

		context.state.clock = context.state.clock + 0.51
		context.state.pump()
		helpers.assert_eq(#context.state.sends, 3,
			"the exact retained payload must retry after bounded backoff")
		helpers.assert_eq(context.transport.status().inflight_sequence, 1)
	end)
end)





-- ================================================
-- ================================================
-- ======= 4/ Acquisition And Teardown Debt =======
-- ================================================
-- ================================================

helpers.describe("LogTransport startup transaction", function()
	helpers.it("refuses missing environment, socket, and scheduler capabilities", function()
		local missing_env = new_context()
		missing_env.options.port = nil
		missing_env.options.token = nil
		missing_env.options.getenv = function() return nil end
		local started = missing_env:start()
		helpers.assert_eq(started, false)
		helpers.assert_eq(missing_env.state.new_calls, 0,
			"invalid credentials must fail before acquiring a socket")
		helpers.assert_eq(missing_env.transport.status().active, false)

		local missing_socket = new_context({ no_udp = true })
		started = missing_socket:start()
		helpers.assert_eq(started, false)
		helpers.assert_eq(missing_socket.state.every_calls, 0,
			"a missing socket must fail before acquiring a timer")
		helpers.assert_eq(missing_socket.transport.status().active, false)

		local missing_scheduler = new_context()
		missing_scheduler.options.scheduler = { every = function() end }
		started = missing_scheduler:start()
		helpers.assert_eq(started, false)
		helpers.assert_eq(missing_scheduler.state.new_calls, 0,
			"an incomplete scheduler must fail before acquiring a socket")
		helpers.assert_eq(missing_scheduler.transport.status().active, false)
	end)

	helpers.it("refuses missing protocol codec and source-auth capabilities", function()
		for _, case in ipairs({
			{ name = "JSON codec", config = { no_json = true } },
			{ name = "address parser", config = { no_parse_address = true } },
		}) do
			local context = new_context(case.config)
			local started = context:start()
			helpers.assert_eq(started, false, case.name)
			helpers.assert_eq(context.state.new_calls, 0,
				case.name .. " refusal must happen before acquiring a socket")
			helpers.assert_eq(context.transport.status().active, false)
		end
	end)

	helpers.it("rolls back every bootstrap failure after native acquisition", function()
		local cases = {
			{ name = "missing timeout", config = { no_bootstrap_timeout = true } },
			{ name = "missing send", config = { no_bootstrap_send = true } },
			{ name = "missing receive", config = { no_bootstrap_receive = true } },
			{ name = "timeout refusal", state = { bootstrap_timeout_mode = "false" } },
			{ name = "timeout exception", state = { bootstrap_timeout_mode = "throw" } },
			{ name = "short send", state = { bootstrap_send_mode = "short" } },
			{ name = "send refusal", state = { bootstrap_send_mode = "false" } },
			{ name = "send exception", state = { bootstrap_send_mode = "throw" } },
			{ name = "receive exception", state = { preflight_mode = "throw" } },
		}
		for _, case in ipairs(cases) do
			local context = new_context(case.config)
			for key, value in pairs(case.state or {}) do context.state[key] = value end
			local started = context:start()
			helpers.assert_eq(started, false, case.name)
			helpers.assert_eq(context.state.bootstrap_new_calls, 1, case.name)
			helpers.assert_eq(context.state.bootstrap_close_calls, 1,
				case.name .. " must close the exact acquired bootstrap socket")
			helpers.assert_eq(context.state.new_calls, 0,
				case.name .. " must not construct the runtime sibling")
			helpers.assert_eq(context.state.every_calls, 0,
				case.name .. " must not arm the runtime pump")
		end
	end)

	helpers.it("does not publish runtime ownership when bootstrap construction fails", function()
		for _, mode in ipairs({ "nil", "throw" }) do
			local context = new_context()
			context.state.bootstrap_construct_mode = mode
			local started = context:start()
			helpers.assert_eq(started, false, mode)
			helpers.assert_eq(context.state.bootstrap_new_calls, 1)
			helpers.assert_eq(context.state.bootstrap_close_calls, 0,
				"a factory that returned no handle created no closeable ownership")
			helpers.assert_eq(context.state.new_calls, 0)
			helpers.assert_eq(context.state.every_calls, 0)
		end
	end)

	helpers.it("retains a bootstrap socket whose rollback close refuses", function()
		local context = new_context()
		context.state.preflight_mode = "timeout"
		context.state.bootstrap_close_mode = "false"
		local started = context:start()
		helpers.assert_eq(started, false)
		helpers.assert_eq(context.state.bootstrap_new_calls, 1)
		helpers.assert_eq(context.state.bootstrap_close_calls, 1)

		started = context:start()
		helpers.assert_eq(started, false)
		helpers.assert_eq(context.state.bootstrap_new_calls, 1,
			"cleanup debt must block construction of a sibling bootstrap socket")
		helpers.assert_eq(context.state.bootstrap_close_calls, 2,
			"the successor must retry only the retained bootstrap handle")

		context.state.bootstrap_close_mode = "success"
		helpers.assert_eq(context.transport.stop(), true)
		helpers.assert_eq(context.state.bootstrap_close_calls, 3)
	end)

	helpers.it("retains an acquired bootstrap handle with no close capability", function()
		local context = new_context({ no_bootstrap_close = true })
		local started = context:start()
		helpers.assert_eq(started, false)
		helpers.assert_eq(context.state.bootstrap_new_calls, 1)
		helpers.assert_eq(context.transport.status().active, false)

		started = context:start()
		helpers.assert_eq(started, false)
		helpers.assert_eq(context.state.bootstrap_new_calls, 1,
			"an uncloseable acquired handle must never be discarded for a sibling")
		helpers.assert_eq(context.transport.stop(), false,
			"the adapter must keep reporting exact cleanup debt rather than claim release")
	end)

	helpers.it("closes the exact socket when receive activation cannot commit", function()
		for _, mode in ipairs({ "missing", "nil", "false", "throw" }) do
			local context = new_context({
				no_receive = mode == "missing",
				receive_mode = mode ~= "missing" and mode or nil,
			})
			local started = context:start()
			helpers.assert_eq(started, false, mode)
			helpers.assert_eq(context.state.close_calls, 1,
				mode .. " receive refusal must close the acquired socket")
			helpers.assert_eq(context.state.every_calls, 0,
				mode .. " receive refusal must not acquire the pump timer")
			helpers.assert_eq(context.transport.status().active, false)
			helpers.assert_eq(context.transport.status().configured, false,
				mode .. " failed start must not advertise a committed runtime channel")
		end
	end)

	helpers.it("closes the exact socket when ephemeral ACK binding cannot commit", function()
		for _, mode in ipairs({ "missing", "nil", "false", "throw" }) do
			local context = new_context({
				no_listen = mode == "missing",
				listen_mode = mode ~= "missing" and mode or nil,
			})
			local started = context:start()
			helpers.assert_eq(started, false, mode)
			helpers.assert_eq(context.state.receive_calls, 0,
				mode .. " listen refusal must not activate receive")
			helpers.assert_eq(context.state.close_calls, 1,
				mode .. " listen refusal must close the acquired socket")
			helpers.assert_eq(context.state.every_calls, 0,
				mode .. " listen refusal must not acquire the pump timer")
			helpers.assert_eq(context.transport.status().active, false)
			helpers.assert_eq(context.transport.status().configured, false,
				mode .. " failed bind must not advertise a committed runtime channel")
		end
	end)

	helpers.it("retains a socket whose receive rollback close refuses", function()
		local context = new_context({ receive_mode = "false" })
		context.state.close_mode = "false"
		local started = context:start()
		helpers.assert_eq(started, false)
		helpers.assert_eq(context.state.close_calls, 1)
		started = context:start()
		helpers.assert_eq(started, false)
		helpers.assert_eq(context.state.new_calls, 1,
			"cleanup refusal must block construction of a sibling UDP socket")
		helpers.assert_eq(context.state.close_calls, 2,
			"a blocked successor must retry only the retained socket")

		context.state.close_mode = "success"
		local settled = context.transport.stop()
		helpers.assert_eq(settled, true)
		helpers.assert_eq(context.state.close_calls, 3,
			"receive rollback refusal must retain the exact socket for retry")
	end)

	helpers.it("refuses session persistence before acquiring either socket", function()
		local context = new_context({ no_settings = true })
		local started = context:start()
		helpers.assert_eq(started, false)
		helpers.assert_eq(context.state.bootstrap_new_calls, 0,
			"session refusal must precede the blocking bootstrap capability")
		helpers.assert_eq(context.state.new_calls, 0,
			"session refusal must precede the asynchronous runtime socket")
		helpers.assert_eq(context.state.close_calls, 0)
		helpers.assert_eq(context.transport.status().active, false)
	end)

	helpers.it("closes the socket when pump timer acquisition cannot commit", function()
		for _, mode in ipairs({ "nil", "refuse", "throw" }) do
			local context = new_context({ every_mode = mode })
			local started = context:start()
			helpers.assert_eq(started, false, mode)
			helpers.assert_eq(context.state.receive_calls, 1)
			helpers.assert_eq(context.state.close_calls, 1,
				mode .. " timer refusal must roll back the socket")
			helpers.assert_eq(context.transport.status().active, false)
			helpers.assert_eq(context.transport.status().configured, false,
				mode .. " failed timer commit must leave transport unconfigured")
		end
	end)

	helpers.it("retains a socket whose startup rollback close refuses", function()
		local context = new_context({ every_mode = "refuse" })
		context.state.close_mode = "false"
		local started = context:start()
		helpers.assert_eq(started, false)
		helpers.assert_eq(context.state.close_calls, 1,
			"timer refusal must attempt immediate rollback of its exact socket")

		context.state.close_mode = "success"
		local settled = context.transport.stop()
		helpers.assert_eq(settled, true)
		helpers.assert_eq(context.state.close_calls, 2,
			"a refused startup rollback must remain owned for an exact close retry")
	end)

	helpers.it("retains an uncommitted pump timer whose cancellation refuses", function()
		local context = new_context({ every_mode = "refuse" })
		context.state.cancel_mode = "false"
		local started = context:start()
		helpers.assert_eq(started, false)
		helpers.assert_eq(context.state.cancel_calls, 1,
			"an uncommitted scheduler handle must receive immediate rollback")
		helpers.assert_eq(context.state.cancel_handles[1], context.state.timer_handle)

		context.state.cancel_mode = "success"
		local settled = context.transport.stop()
		helpers.assert_eq(settled, true)
		helpers.assert_eq(context.state.cancel_calls, 2,
			"a refused timer rollback must remain owned for an exact retry")
		helpers.assert_eq(context.state.cancel_handles[2], context.state.timer_handle)
	end)

	helpers.it("reuses one pending session after an ambiguous preflight timeout", function()
		local previous = "previous-native-session"
		local context = new_context({
			no_explicit_session = true,
			previous_session = previous,
		})
		context.state.preflight_mode = "timeout"
		local started = context:start()
		helpers.assert_eq(started, false)
		local first_request = context.hs.json.decode(context.state.preflight_payloads[1])
		helpers.assert_type(first_request.session, "string")
		helpers.assert_eq(first_request.previous_session, previous)
		helpers.assert_eq(context.transport.status().active, false)

		context.state.preflight_mode = nil
		started = context:start()
		helpers.assert_eq(started, true,
			"a lost ACK must be recoverable whether the worker accepted the first configure or not")
		local second_request = context.hs.json.decode(context.state.preflight_payloads[2])
		helpers.assert_eq(second_request.session, first_request.session,
			"an ambiguous timeout must retry the same transition identity, never invent a sibling")
		helpers.assert_eq(second_request.previous_session, previous,
			"the accepted predecessor remains stable until exact configure ACK")
		helpers.assert_eq(context.transport.status().configured, true)
	end)

	helpers.it("restarts record sequencing at one for each committed native session", function()
		local context = new_context()
		configure(context)
		context.transport.enqueue("first-session-record", "info")
		context.state.pump()
		helpers.assert_eq(context:payload().sequence, 1)
		context:ack(1)
		helpers.assert_eq(context.transport.stop(), true)

		local successor = "lua-runtime-session-18"
		context.options.session = successor
		local restarted, restart_err = context:start()
		helpers.assert_eq(restarted, true, tostring(restart_err))
		local configure_request = context.hs.json.decode(context.state.preflight_payloads[2])
		helpers.assert_eq(configure_request.session, successor)
		helpers.assert_eq(configure_request.previous_session, SESSION)

		context.transport.enqueue("successor-session-record", "info")
		context.state.pump()
		local successor_record = context:payload()
		helpers.assert_eq(successor_record.session, successor)
		helpers.assert_eq(successor_record.sequence, 1,
			"the native worker resets lastSequence to zero for every new session")
	end)
end)

helpers.describe("LogTransport teardown ownership", function()
	helpers.it("contains a throwing drain callback and keeps cleanup retryable", function()
		local context = new_context()
		configure(context)
		helpers.assert_eq(context.transport.drain(function()
			error("synthetic drain owner failure")
		end, 0.25), true)
		local pump_ok, pump_err = pcall(context.state.pump)
		helpers.assert_true(pump_ok,
			"timer boundary must contain a drain-owner exception: " .. tostring(pump_err))
		helpers.assert_contains(context.transport.status().last_error, "drain callback failed")
		helpers.assert_eq(context.transport.status().accepting, false)
		helpers.assert_eq(context.transport.stop(), true,
			"contained callback failure must not orphan timer/socket ownership")
	end)

	helpers.it("drains queued records before releasing timer and socket ownership", function()
		local context = new_context()
		configure(context)
		context.transport.enqueue("shutdown-tail", "info")
		local completions = {}

		local committed = context.transport.drain(function(settled, detail)
			completions[#completions + 1] = { settled = settled, detail = detail }
		end, 0.25)
		helpers.assert_eq(committed, true,
			"controlled teardown must acquire an exact drain deadline")
		helpers.assert_eq(#completions, 0, "an unacknowledged tail cannot complete shutdown")
		helpers.assert_eq(context.state.cancel_calls, 0,
			"the pump must remain owned while queued shutdown diagnostics drain")
		helpers.assert_eq(context.state.close_calls, 0)
		helpers.assert_eq(context.transport.status().active, true)
		helpers.assert_eq(context.transport.status().queued, 1)
		local late_record = context.transport.enqueue("reload-upgraded-to-quit", "info")
		helpers.assert_not_nil(late_record,
			"a pending reload drain must still accept a quit-upgrade diagnostic")

		context.state.pump()
		helpers.assert_eq(context.transport.status().inflight_sequence, 1)
		context:ack(1)
		helpers.assert_eq(#completions, 0,
			"the drain cannot settle while the quit-upgrade tail remains queued")
		context.state.pump()
		helpers.assert_eq(context.transport.status().inflight_sequence, 2)
		context:ack(2)
		helpers.assert_eq(#completions, 0,
			"socket ACK handling must not run the timer-owned drain continuation")
		context.state.pump()
		helpers.assert_eq(#completions, 1)
		helpers.assert_eq(completions[1].settled, true)
		helpers.assert_eq(context.transport.status().queued, 0)
		helpers.assert_nil(context.transport.enqueue("after-drain-boundary", "info"),
			"the pump must fence producers atomically at the observed empty boundary")
		helpers.assert_eq(context.transport.status().active, true,
			"the drain callback hands terminal ownership to its shutdown coordinator")
		helpers.assert_eq(context.transport.stop(), true)
		helpers.assert_eq(context.transport.status().active, false)
		helpers.assert_eq(context.state.cancel_calls, 1)
		helpers.assert_eq(context.state.close_calls, 1)
		context:ack(1)
		helpers.assert_eq(#completions, 1,
			"a duplicate late ACK must not deliver shutdown completion twice")
	end)

	helpers.it("reports a final ACK delivery failure before the drain continuation", function()
		local context = new_context()
		configure(context)
		context.state.delivered_mode = "false"
		context.transport.enqueue("final-delivery-hook", "info")
		local failure_count_at_completion = nil
		local completion = nil
		helpers.assert_eq(context.transport.drain(function(settled, detail)
			failure_count_at_completion = #context.state.failures
			completion = { settled = settled, detail = detail }
		end, 0.25), true)

		context.state.pump()
		context:ack(1)
		helpers.assert_eq(#context.state.failures, 0,
			"the socket callback must not invoke secondary fail-safe code re-entrantly")
		helpers.assert_nil(failure_count_at_completion,
			"the final ACK alone must not bypass deferred failure delivery")
		context.state.pump()
		helpers.assert_eq(#context.state.failures, 1)
		helpers.assert_contains(context.state.failures[1], "delivery callback failed")
		helpers.assert_eq(failure_count_at_completion, 1,
			"the fail-safe must observe the post-ACK failure before finalization")
		helpers.assert_eq(completion.settled, false,
			"a failed final delivery hook cannot certify a clean native drain")
		helpers.assert_contains(completion.detail, "synthetic delivery refusal")
		helpers.assert_eq(context.transport.status().accepting, true,
			"a failed drain must resume producers instead of publishing a terminal fence")
	end)

	helpers.it("reports a drain deadline without discarding recoverable ownership", function()
		local context = new_context()
		configure(context)
		context.transport.enqueue("still-pending", "error")
		local completions = {}
		local committed = context.transport.drain(function(settled, detail)
			completions[#completions + 1] = { settled = settled, detail = detail }
		end, 0.25)
		helpers.assert_eq(committed, true)
		context.state.clock = context.state.clock + 0.26
		context.state.pump()

		helpers.assert_eq(#completions, 1)
		helpers.assert_eq(completions[1].settled, false)
		helpers.assert_type(completions[1].detail, "string")
		helpers.assert_eq(context.transport.status().active, true,
			"deadline expiry is not proof that the UDP socket stopped")
		helpers.assert_eq(context.transport.status().queued, 1,
			"deadline expiry is not proof that the queued record was durable")
		helpers.assert_eq(context.state.close_calls, 0)
		helpers.assert_not_nil(context.transport.enqueue("accepted-after-timeout", "info"),
			"a failed drain must resume producers so normal runtime can recover")
	end)

	helpers.it("refuses stop while records remain without releasing their pump", function()
		local context = new_context()
		configure(context)
		context.transport.enqueue("owned-tail", "warn")
		helpers.assert_eq(context.transport.stop(), false)
		helpers.assert_eq(context.state.cancel_calls, 0)
		helpers.assert_eq(context.state.close_calls, 0)
		helpers.assert_eq(context.transport.status().active, true)
		helpers.assert_eq(context.transport.status().queued, 1)
		context.state.pump()
		context:ack(1)
		helpers.assert_eq(context.transport.stop(), true)
	end)

	helpers.it("fences producers when socket close fails after pump cancellation", function()
		local context = new_context()
		configure(context)
		context.state.close_mode = "false"

		local stopped = context.transport.stop()
		helpers.assert_eq(stopped, false)
		helpers.assert_eq(context.state.cancel_calls, 1)
		helpers.assert_eq(context.state.close_calls, 1)
		helpers.assert_eq(context.transport.status().accepting, false,
			"once the only pump is gone, accepting a record would strand it forever")
		helpers.assert_nil(context.transport.enqueue("cannot-be-pumped", "error"),
			"cleanup debt must be callback-inert and producer-fenced")

		context.state.close_mode = "success"
		stopped = context.transport.stop()
		helpers.assert_eq(stopped, true)
		helpers.assert_eq(context.state.cancel_calls, 1,
			"the already released timer must not be cancelled twice")
		helpers.assert_eq(context.state.close_calls, 2,
			"retry must close the exact retained socket")
		helpers.assert_eq(context.transport.status().active, false)
	end)

	helpers.it("retains the exact timer and socket when cancellation refuses", function()
		local context = new_context()
		configure(context)
		context.state.cancel_mode = "false"

		local stopped = context.transport.stop()
		helpers.assert_eq(stopped, false)
		helpers.assert_eq(context.state.cancel_calls, 1)
		helpers.assert_eq(context.state.cancel_handles[1], context.state.timer_handle)
		helpers.assert_eq(context.state.close_calls, 0,
			"socket ownership must remain while the pump may still fire")
		helpers.assert_eq(context.transport.status().active, true)
		helpers.assert_eq(context.transport.status().queued, 0)

		context.state.cancel_mode = "success"
		stopped = context.transport.stop()
		helpers.assert_eq(stopped, true)
		helpers.assert_eq(context.state.cancel_calls, 2)
		helpers.assert_eq(context.state.cancel_handles[2], context.state.timer_handle,
			"retry must target the same retained timer handle")
		helpers.assert_eq(context.state.close_calls, 1)
		helpers.assert_eq(context.transport.status().active, false)
		helpers.assert_eq(context.transport.status().queued, 0)
	end)
end)
