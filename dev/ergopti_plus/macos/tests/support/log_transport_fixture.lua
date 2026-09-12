--- tests/support/log_transport_fixture.lua

--- ==============================================================================
--- MODULE: Log Transport Fixture
--- DESCRIPTION:
--- Provides one controllable authenticated transport with observable native state.
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
		rejected = {},
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

	local session = SESSION
	if config.no_explicit_session then session = nil end
	local options = {
		port = 49321,
		token = TOKEN,
		session = session,
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
		on_rejected = function(record)
			state.rejected[#state.rejected + 1] = record
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


--- Runs a complete test case, retaining all contexts until its assertions finish.
--- @param callback function Test assertions.
local function with_fixture(callback)
	return helpers.with_stub_scope({
		"adapters.log_transport", "tests.stubs.hs", "hs",
		"adapters.timer_scheduler", "infra.logger",
	}, callback)
end

return {
	TOKEN = TOKEN, SESSION = SESSION, LOOPBACK = LOOPBACK,
	new_context = new_context, configure = configure, with_fixture = with_fixture,
}
