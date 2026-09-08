--- tests/unit/adapters/log_transport/test_startup.lua

--- ==============================================================================
--- MODULE: LogTransport startup transaction Tests
--- DESCRIPTION:
--- Exercises real transport behavior inside an isolated native and module scope.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.log_transport_fixture")
local new_context, configure = Fixture.new_context, Fixture.configure
local TOKEN, SESSION, LOOPBACK = Fixture.TOKEN, Fixture.SESSION, Fixture.LOOPBACK

helpers.describe("LogTransport startup transaction", function()
	helpers.it("refuses missing environment, socket, and scheduler capabilities", function()
		Fixture.with_fixture(function()
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
	end)

	helpers.it("refuses missing protocol codec and source-auth capabilities", function()
		Fixture.with_fixture(function()
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
	end)

	helpers.it("rolls back every bootstrap failure after native acquisition", function()
		Fixture.with_fixture(function()
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
	end)

	helpers.it("does not publish runtime ownership when bootstrap construction fails", function()
		Fixture.with_fixture(function()
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
	end)

	helpers.it("retains a bootstrap socket whose rollback close refuses", function()
		Fixture.with_fixture(function()
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
	end)

	helpers.it("retains an acquired bootstrap handle with no close capability", function()
		Fixture.with_fixture(function()
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
	end)

	helpers.it("closes the exact socket when receive activation cannot commit", function()
		Fixture.with_fixture(function()
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
	end)

	helpers.it("closes the exact socket when ephemeral ACK binding cannot commit", function()
		Fixture.with_fixture(function()
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
	end)

	helpers.it("retains a socket whose receive rollback close refuses", function()
		Fixture.with_fixture(function()
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
	end)

	helpers.it("refuses session persistence before acquiring either socket", function()
		Fixture.with_fixture(function()
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
	end)

	helpers.it("closes the socket when pump timer acquisition cannot commit", function()
		Fixture.with_fixture(function()
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
	end)

	helpers.it("retains a socket whose startup rollback close refuses", function()
		Fixture.with_fixture(function()
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
	end)

	helpers.it("retains an uncommitted pump timer whose cancellation refuses", function()
		Fixture.with_fixture(function()
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
	end)

	helpers.it("reuses one pending session after an ambiguous preflight timeout", function()
		Fixture.with_fixture(function()
			local previous = "previous-native-session"
			local generated = "generated-native-session"
			local uuid_calls = 0
			local context = new_context({
				no_explicit_session = true,
				previous_session = previous,
			})
			helpers.assert_nil(context.options.session, "the fixture must exercise automatic session allocation")
			context.hs.host.uuid = function()
				uuid_calls = uuid_calls + 1
				return generated
			end
			context.state.preflight_mode = "timeout"
			local started = context:start()
			helpers.assert_eq(started, false)
			local first_request = context.hs.json.decode(context.state.preflight_payloads[1])
			helpers.assert_type(first_request.session, "string")
			helpers.assert_eq(first_request.session, generated)
			helpers.assert_eq(uuid_calls, 1)
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
			helpers.assert_eq(uuid_calls, 1, "retry must reuse the persisted session, not allocate another UUID")
			helpers.assert_eq(context.hs.settings.get("ergopti.logger.transport_session"), generated)
			helpers.assert_nil(context.hs.settings.get("ergopti.logger.transport_pending_session"))
		end)
	end)

	helpers.it("restarts record sequencing at one for each committed native session", function()
		Fixture.with_fixture(function()
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
end)
