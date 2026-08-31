--- tests/unit/lib/test_logger_async_sink.lua

--- ==============================================================================
--- MODULE: Logger asynchronous sink lifecycle
--- DESCRIPTION:
--- Proves the ownership handoff from the Lua boot sink to the authenticated
--- native worker. It covers exact purge-timer cancellation and the subtle dedup
--- ordering where a previous streak summary is delivered before the next error.
--- ==============================================================================

local helpers = require("tests.helpers")

local function load_policy_logger()
	package.loaded["infra.logger"] = nil
	package.loaded["adapters.log_transport"] = nil
	package.loaded["tests.stubs.hs"] = nil
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	return require("infra.logger")
end

local function load_fixture()
	package.loaded["infra.logger"] = nil
	package.loaded["adapters.log_transport"] = nil
	package.loaded["tests.stubs.hs"] = nil
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

helpers.describe("logger: native asynchronous sink ownership", function()
	helpers.it("classifies complete managed authority, complete absence, and every partial set", function()
		local Logger = load_policy_logger()
		local keys = {
			"ERGOPTI_LAUNCHER_PID",
			"ERGOPTI_LAUNCHER_BUNDLE_ID",
			"ERGOPTI_LOG_PORT",
			"ERGOPTI_LOG_TOKEN",
		}
		for mask = 0, 15 do
			local environment = {}
			for index, name in ipairs(keys) do
				if math.floor(mask / (2 ^ (index - 1))) % 2 == 1 then
					environment[name] = name .. "_value"
				end
			end
			local mode, detail = Logger.classify_async_sink_boot_environment(function(name)
				return environment[name]
			end)
			if mask == 0 then
				helpers.assert_eq(mode, "standalone",
					"complete absence must remain distinguishable for root fail-closed diagnosis")
				helpers.assert_nil(detail)
			elseif mask == 15 then
				helpers.assert_eq(mode, "managed",
					"all identity and credential fields must select the native worker")
				helpers.assert_nil(detail)
			else
				helpers.assert_eq(mode, "invalid",
					string.format("partial managed environment mask %d must fail closed", mask))
				helpers.assert_contains(detail, "partial")
				for _, name in ipairs(keys) do
					if environment[name] == nil then helpers.assert_contains(detail, name) end
				end
			end
		end

		local mode, detail = Logger.classify_async_sink_boot_environment(function()
			error("environment denied")
		end)
		helpers.assert_eq(mode, "invalid")
		helpers.assert_contains(detail, "environment read failed")
	end)

	helpers.it("stops the exact pending Lua purge timer before native retention owns the directory", function()
		local fixture = load_fixture()
		local purge_timer = fixture.hs.timer.__timers[1]
		helpers.assert_not_nil(purge_timer, "init_log_path must have committed its deferred boot purge")
		helpers.assert_eq(purge_timer.running, false,
			"the exact pre-existing Lua purge timer must be stopped during native handoff")
		helpers.assert_true(fixture.Logger.async_sink_status().active)
	end)

	helpers.it("refuses native handoff when the unified boot handle returns nil from close", function()
		local saved_logger = package.loaded["infra.logger"]
		local saved_transport = package.loaded["adapters.log_transport"]
		local saved_hs_stub = package.loaded["tests.stubs.hs"]
		local saved_hs_module = package.loaded["hs"]
		local saved_global_hs = rawget(_G, "hs")
		local saved_io_open = io.open
		local transport_starts = 0
		local close_calls = 0

		local ok, err = xpcall(function()
			package.loaded["infra.logger"] = nil
			package.loaded["adapters.log_transport"] = {
				start = function()
					transport_starts = transport_starts + 1
					return true
				end,
			}
			package.loaded["tests.stubs.hs"] = nil
			local hs_stub = require("tests.stubs.hs")
			hs_stub.__reset()
			_G.hs = hs_stub
			package.loaded["hs"] = hs_stub

			local Logger = require("infra.logger")
			Logger.set_level("DEBUG")
			Logger.init_log_path("/tmp/ergopti_async_logger_close_refusal/", 14)
			io.open = function()
				return {
					write = function() return true end,
					flush = function() return true end,
					close = function()
						close_calls = close_calls + 1
						return nil, "injected close refusal"
					end,
				}
			end
			Logger.info("close_probe", "alpha")
			io.open = saved_io_open

			local ready, detail = Logger.start_async_sink({})
			helpers.assert_eq(ready, false,
				"nil plus an error is Lua's ordinary file-close refusal, never a committed handoff")
			helpers.assert_contains(detail, "unified boot log handle refused close")
			helpers.assert_contains(detail, "injected close refusal",
				"the exact io.close diagnostic must survive the handoff boundary")
			helpers.assert_eq(close_calls, 1,
				"the exact refusing boot handle must remain published for a later retry")
			helpers.assert_eq(transport_starts, 0,
				"native persistence must not start while buffered boot bytes remain unclosed")
		end, debug.traceback)

		io.open = saved_io_open
		package.loaded["infra.logger"] = saved_logger
		package.loaded["adapters.log_transport"] = saved_transport
		package.loaded["tests.stubs.hs"] = saved_hs_stub
		package.loaded["hs"] = saved_hs_module
		_G.hs = saved_global_hs
		if type(saved_logger) == "table" and type(saved_logger.claim_core_hooks) == "function" then
			saved_logger.claim_core_hooks()
		end
		if not ok then error(err, 0) end
	end)

	helpers.it("associates notifications with their exact error across a dedup summary", function()
		local fixture = load_fixture()
		local notifications = {}
		fixture.Logger.set_error_notification_handler(function(module_name, message)
			notifications[#notifications + 1] = module_name .. ":" .. message
			return true
		end)

		fixture.Logger.error("first", "same failure")
		fixture.Logger.error("first", "same failure")
		fixture.Logger.error("second", "next failure")
		helpers.assert_eq(fixture.Logger.async_sink_status().queued, 3,
			"first error, its dedup summary, and second error must retain FIFO ownership")
		helpers.assert_eq(#notifications, 0, "no notification may fire before native ACK")

		local first = fixture.deliver_next()
		local summary = fixture.deliver_next()
		local second = fixture.deliver_next()
		helpers.assert_contains(first.line, "[first] same failure")
		helpers.assert_contains(summary.line, "identical line suppressed")
		helpers.assert_contains(second.line, "[second] next failure")
		helpers.assert_eq(#notifications, 2,
			"the dedup summary must not steal or create an error notification")
		helpers.assert_eq(notifications[1], "first:same failure")
		helpers.assert_eq(notifications[2], "second:next failure")
	end)

	helpers.it("attaches a huge error notification without suffix-copying the rendered line on HID", function()
		local fixture = load_fixture()
		local notifications = {}
		fixture.Logger.set_error_notification_handler(function(module_name, message)
			notifications[#notifications + 1] = module_name .. ":" .. message
			return true
		end)
		local huge_message = string.rep("suffix-probe-", 4000)
		local original_sub = string.sub
		local large_sub_calls = 0
		string.sub = function(value, ...)
			if type(value) == "string" and #value >= #huge_message then
				large_sub_calls = large_sub_calls + 1
			end
			return original_sub(value, ...)
		end
		local call_ok, call_err = pcall(fixture.Logger.error, "huge_error", huge_message)
		string.sub = original_sub

		helpers.assert_true(call_ok, "huge error logging must not throw: " .. tostring(call_err))
		helpers.assert_eq(large_sub_calls, 0,
			"the HID producer must not suffix-scan or duplicate the rendered error line")
		helpers.assert_eq(fixture.Logger.async_sink_status().queued, 1,
			"one huge logical error must retain one producer record")
		local original_print = _G.print
		_G.print = function() end
		local delivery_ok, delivery_err = xpcall(function()
			while fixture.Logger.async_sink_status().queued > 0 do fixture.deliver_next() end
		end, debug.traceback)
		_G.print = original_print
		helpers.assert_true(delivery_ok, tostring(delivery_err))
		helpers.assert_eq(#notifications, 1)
		helpers.assert_eq(notifications[1], "huge_error:" .. huge_message,
			"the final ACKed fragment must still own the exact notification")
	end)

	helpers.it("retains a refused ERROR notification in the bounded timer-owned fallback", function()
		local fixture = load_fixture()
		local transport = require("adapters.log_transport")
		local notifications = {}
		local failures = {}
		fixture.Logger.set_error_notification_handler(function(module_name, message)
			notifications[#notifications + 1] = module_name .. ":" .. message
			return true
		end)
		local installed, install_err = fixture.Logger.set_async_sink_failure_handler(
			function(detail) failures[#failures + 1] = detail end
		)
		helpers.assert_true(installed, tostring(install_err))

		for index = 1, 7168 do
			local retained, enqueue_err = transport.enqueue("ordinary-" .. tostring(index), "trace")
			helpers.assert_not_nil(retained, tostring(enqueue_err))
		end
		for index = 1, 1024 do
			local retained, enqueue_err = transport.enqueue("critical-" .. tostring(index), "warn")
			helpers.assert_not_nil(retained, tostring(enqueue_err))
		end
		helpers.assert_eq(fixture.Logger.async_sink_status().queued, 8192,
			"the fixture must saturate the real producer queue before logging the ERROR")

		fixture.Logger.error("capacity", "visible refusal")
		local refused = fixture.Logger.async_sink_status()
		helpers.assert_eq(refused.dropped_total, 1)
		helpers.assert_eq(refused.dropped_by_variant.error, 1)
		helpers.assert_eq(refused.rejected_error_fallback_queued, 1)
		helpers.assert_eq(#notifications, 0,
			"the producer callback must not notify synchronously when the queue is full")
		helpers.assert_eq(#failures, 0,
			"the producer callback must leave failure reporting to the timer-owned pump")

		fixture.pump()
		helpers.assert_eq(#failures, 1)
		helpers.assert_contains(failures[1], "capacity")
		helpers.assert_eq(#notifications, 1,
			"a refused ERROR must still release its exact user notification off HID")
		helpers.assert_eq(notifications[1], "capacity:visible refusal")
		helpers.assert_eq(fixture.Logger.async_sink_status().rejected_error_fallback_queued, 0)
	end)

	helpers.it("keeps the native transport live until every queued record has an exact ACK", function()
		local fixture = load_fixture()
		fixture.Logger.info("teardown", "final diagnostic")
		helpers.assert_eq(fixture.Logger.async_sink_status().queued, 1)
		local drained = nil
		local detail = nil
		local committed, begin_err = fixture.Logger.begin_async_sink_shutdown(function(ok, why)
			drained = ok
			detail = why
		end)
		helpers.assert_true(committed, "asynchronous drain callback ownership must commit: "
			.. tostring(begin_err))
		helpers.assert_nil(drained,
			"drain completion must wait for the queued record's exact native ACK")
		helpers.assert_true(fixture.Logger.async_sink_status().active,
			"a pending drain must retain the pump and native socket")

		local request = fixture.deliver_next()
		helpers.assert_contains(request.line, "[teardown] final diagnostic")
		helpers.assert_eq(fixture.Logger.async_sink_status().queued, 0)
		helpers.assert_nil(drained,
			"the socket callback must leave terminal continuation to the owned pump")
		fixture.pump()
		helpers.assert_eq(drained, true, "the exact final ACK must settle drain completion")
		helpers.assert_true(detail == nil or type(detail) == "string")
		helpers.assert_true(fixture.Logger.stop_async_sink(),
			"resource stop must settle after the drain callback proves an empty queue")
	end)

	helpers.it("retains an exact native failure until a late fail-safe handler is registered", function()
		local fixture = load_fixture()
		fixture.Logger.info("transport", "record awaiting native decision")
		fixture.pump()
		local request = fixture.hs.json.decode(fixture.sent[#fixture.sent])
		local final_record = request.records[#request.records]
		fixture.receive(fixture.hs.json.encode({
			v = 1,
			kind = "nack",
			token = request.token,
			session = request.session,
			reason = "synthetic native refusal",
			expected = final_record.sequence,
		}))
		helpers.assert_nil(fixture.Logger.async_sink_status().pending_failure,
			"the UDP callback may retain adapter state but must not enter the root fail-safe")
		fixture.pump()

		local before_registration = fixture.Logger.async_sink_status()
		helpers.assert_contains(before_registration.pending_failure, "synthetic native refusal",
			"the adapter callback must retain the exact failure before root wiring exists")

		local failures = {}
		local installed, install_err = fixture.Logger.set_async_sink_failure_handler(function(detail)
			failures[#failures + 1] = detail
		end)
		helpers.assert_true(installed, "late failure handler must accept retained delivery: "
			.. tostring(install_err))
		helpers.assert_eq(#failures, 1)
		helpers.assert_contains(failures[1], "synthetic native refusal")
		helpers.assert_nil(fixture.Logger.async_sink_status().pending_failure,
			"successful exact delivery must clear retained failure ownership")
	end)

	helpers.it("routes refused and throwing notification delivery to the runtime fail-safe", function()
		for _, case in ipairs({
			{
				name = "false",
				handler = function() return false, "synthetic notification refusal" end,
				expected = "synthetic notification refusal",
			},
			{
				name = "throw",
				handler = function() error("synthetic notification throw") end,
				expected = "synthetic notification throw",
			},
		}) do
			local fixture = load_fixture()
			local failures = {}
			local installed, install_err = fixture.Logger.set_async_sink_failure_handler(
				function(detail)
					failures[#failures + 1] = detail
				end
			)
			helpers.assert_true(installed, tostring(install_err))
			fixture.Logger.set_error_notification_handler(case.handler)

			fixture.Logger.error("notification", "delivery " .. case.name)
			fixture.deliver_next()
			helpers.assert_eq(#failures, 0,
				"the socket callback must leave the runtime fail-safe to the owned pump")
			fixture.pump()

			helpers.assert_eq(#failures, 1,
				"an ACKed log must not hide a " .. case.name .. " notification failure")
			helpers.assert_contains(failures[1], case.expected)
			helpers.assert_nil(fixture.Logger.async_sink_status().pending_failure,
				"the installed runtime fail-safe must own the exact failure")
			helpers.assert_true(fixture.Logger.stop_async_sink())
		end
	end)

	helpers.it("routes a throwing terminal drain continuation to the runtime fail-safe", function()
		local fixture = load_fixture()
		local failures = {}
		local installed, install_err = fixture.Logger.set_async_sink_failure_handler(
			function(detail)
				failures[#failures + 1] = detail
			end
		)
		helpers.assert_true(installed, tostring(install_err))
		local committed, drain_err = fixture.Logger.begin_async_sink_shutdown(function()
			error("synthetic terminal continuation throw")
		end)
		helpers.assert_true(committed, tostring(drain_err))

		fixture.pump()

		helpers.assert_eq(#failures, 1,
			"a swallowed drain continuation would leave termination pending forever")
		helpers.assert_contains(failures[1], "synthetic terminal continuation throw")
		helpers.assert_nil(fixture.Logger.async_sink_status().pending_failure)
		helpers.assert_true(fixture.Logger.stop_async_sink())
	end)
end)
