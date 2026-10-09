--- tests/unit/adapters/test_log_transport.lua

--- ==============================================================================
--- MODULE: LogTransport producer purity Tests
--- DESCRIPTION:
--- Exercises real transport behavior inside an isolated native and module scope.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.log_transport_fixture")
local new_context, configure = Fixture.new_context, Fixture.configure
local TOKEN, SESSION, LOOPBACK = Fixture.TOKEN, Fixture.SESSION, Fixture.LOOPBACK

helpers.describe("LogTransport producer purity", function()
	helpers.it("enqueue mutates memory only and defers every external side effect", function()
		Fixture.with_fixture(function()
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
	end)

	helpers.it("refuses a huge malformed enqueue without scanning or retaining it", function()
		Fixture.with_fixture(function()
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
			string.sub = original_sub
			string.byte = original_byte
			context.hs.json.encode = original_encode

			helpers.assert_true(call_ok, "hostile enqueue must not throw: " .. tostring(retained))
			helpers.assert_nil(retained)
			helpers.assert_contains(enqueue_err, "65536 bytes")
			helpers.assert_eq(enqueue_sub_calls, 0,
				"admission must use string length without allocating fragment substrings")
			helpers.assert_eq(enqueue_byte_calls, 0,
				"enqueue must not validate or sanitize user-derived bytes")
			helpers.assert_eq(enqueue_encode_calls, 0,
				"enqueue must not construct a native payload")
			helpers.assert_eq(enqueue_route_calls, 0,
				"enqueue must not derive topical routes")
			helpers.assert_eq(context.transport.status().queued, 0,
				"an oversized producer line must retain no queue slot or string reference")
		end)
	end)
end)
