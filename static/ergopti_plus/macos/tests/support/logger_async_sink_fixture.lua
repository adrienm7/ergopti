--- tests/support/logger_async_sink_fixture.lua

--- ==============================================================================
--- MODULE: Logger Asynchronous Sink Fixture
--- DESCRIPTION:
--- Constructs real logger and transport dependencies for lifecycle regressions.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}
local OWNERS = {
	"infra.logger", "adapters.log_transport", "tests.stubs.hs", "hs", "logger",
	"infra.launcher_environment", "_generated.logger_sub_files", "socket",
}

local function load_policy_logger()
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	return require("infra.logger")
end

local function load_fixture()
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	local sent = {}
	local bootstrap_requests = {}
	local receive_callback = nil
	hs_stub.socket = {
		udp = {
			parseAddress = function(sockaddr)
				if sockaddr == "loopback" then return { host = "127.0.0.1", port = 49153 } end
				return { host = tostring(sockaddr) }
			end,
			new = function(callback)
				receive_callback = callback
				return {
					listen = function(_, bind_port)
						helpers.assert_eq(bind_port, 0,
							"runtime ACK receiver must bind one ephemeral local port")
						return true
					end,
					receive = function() return true end,
					send = function(_, payload)
						sent[#sent + 1] = payload
						return true
					end,
					close = function() return true end,
				}
			end,
		},
	}

	local pump = nil
	local scheduler = {
		every = function(_interval, callback)
			pump = callback
			return { callback = callback }, true
		end,
		cancel = function() return true end,
		now_ns = function() return 100000000000 end,
	}
	local Logger = require("infra.logger")
	Logger.set_level("DEBUG")
	Logger.reset_dedup()
	Logger.init_log_path("/tmp/ergopti_async_logger_handoff/", 14)

	local port = 49153
	local token = string.rep("b", 32)
	local function bootstrap_socket_factory()
		local request_payload = nil
		return {
			settimeout = function(_, timeout)
				helpers.assert_true(timeout > 0 and timeout <= 0.25,
					"bootstrap receive must remain positively bounded")
				return true
			end,
			sendto = function(_, payload, host, destination_port)
				helpers.assert_eq(host, "127.0.0.1")
				helpers.assert_eq(destination_port, port)
				request_payload = payload
				bootstrap_requests[#bootstrap_requests + 1] = hs_stub.json.decode(payload)
				return #payload
			end,
			receivefrom = function()
				local configure = hs_stub.json.decode(request_payload)
				return hs_stub.json.encode({
					v = 1,
					kind = "ack",
					token = configure.token,
					session = configure.session,
					ack = 0,
				}), "127.0.0.1", port
			end,
			close = function() return true end,
		}
	end
	local ready, ready_err = Logger.start_async_sink(scheduler, {
		port = port,
		token = token,
		max_batch_records = 1,
		bootstrap_socket_factory = bootstrap_socket_factory,
	})
	helpers.assert_true(ready, "the fake transport must commit: " .. tostring(ready_err))
	helpers.assert_eq(#bootstrap_requests, 1,
		"start must synchronously prove one authenticated native configure ACK")
	helpers.assert_eq(bootstrap_requests[1].kind, "configure")
	helpers.assert_eq(#sent, 0, "the runtime socket must not repeat the bootstrap handshake")

	local function deliver_next()
		local sends_before = #sent
		for _ = 1, 16 do
			pump()
			if #sent > sends_before then break end
		end
		helpers.assert_true(#sent > sends_before,
			"timer-owned preparation must eventually publish one bounded batch")
		local request = hs_stub.json.decode(sent[#sent])
		local records = request.records or {}
		local final_record = records[#records]
		helpers.assert_eq(request.kind, "batch")
		helpers.assert_not_nil(final_record, "runtime logger batches must not be empty")
		receive_callback(hs_stub.json.encode({
			v = 1,
			kind = "ack",
			token = request.token,
			session = request.session,
			ack = final_record.sequence,
		}), "loopback")
		return final_record
	end

	return {
		hs = hs_stub,
		Logger = Logger,
		deliver_next = deliver_next,
		bootstrap_requests = bootstrap_requests,
		pump = function() return pump() end,
		receive = function(payload) return receive_callback(payload, "loopback") end,
		sent = sent,
	}
end


--- Runs custom asynchronous logger construction and callback work.
--- @param callback function Fixture work.
--- @return ... Callback results.
function M.with_scope(callback)
	return helpers.with_stub_scope(OWNERS, callback)
end

--- Runs the real asynchronous logger fixture and all its callback assertions.
--- @param callback function Receives the ready fixture.
--- @return ... Callback results.
function M.with_fixture(callback)
	return M.with_scope(function() return callback(load_fixture()) end)
end

--- Runs a fresh real logger for boot-policy assertions.
--- @param callback function Receives the policy logger.
--- @return ... Callback results.
function M.with_policy_logger(callback)
	return M.with_scope(function() return callback(load_policy_logger()) end)
end

return M
