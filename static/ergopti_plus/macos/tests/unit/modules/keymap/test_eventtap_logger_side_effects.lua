--- tests/unit/modules/keymap/test_eventtap_logger_side_effects.lua

--- ==============================================================================
--- MODULE: KeyDown logger side-effect boundary
--- DESCRIPTION:
--- Drives the production keyDown callback through a deterministic interceptor
--- failure. The callback must enqueue its ERROR record without touching console,
--- notification, socket, timer, or filesystem. Only a later transport pump and
--- the native worker's exact ACK may deliver the deferred user-visible effects.
---
--- ROOT CAUSE ENCODED:
--- Buffered DEBUG flushing was a structural false-green: Logger.error still
--- printed, opened the unified/error/topical files, flushed them, and notified
--- synchronously. This test observes the complete callback boundary instead of
--- blessing one conditional inside one file-writer helper.
--- ==============================================================================

local helpers = require("tests.helpers")

local RESET_MODULES = {
	"infra.logger", "adapters.log_transport", "adapters.event_provenance",
	"adapters.synthetic_input",
	"infra.paths", "infra.timings",
	"modules.llm", "modules.llm.prediction_engine", "modules.keylogger",
	"ui.tooltip", "modules.hotstrings.hotstrings_config", "adapters.tooltip_renderer",
	"adapters.file_system",
	"modules.keymap", "modules.keymap.init", "modules.keymap.registry",
	"modules.keymap.expander", "modules.keymap.llm_bridge", "modules.keymap.state",
	"modules.keymap.terminator_replay", "modules.keymap.utils",
}

local function reset_modules()
	for _, name in ipairs(RESET_MODULES) do package.loaded[name] = nil end
end

local function ack_for(hs_stub, sent, receive_callback, sequence, encode, decode)
	encode = encode or hs_stub.json.encode
	decode = decode or hs_stub.json.decode
	local request = decode(sent[#sent].payload)
	helpers.assert_type(request, "table", "the pump must send a JSON request")
	helpers.assert_eq(request.kind, "batch")
	helpers.assert_type(request.records, "table")
	helpers.assert_true(#request.records > 0)
	helpers.assert_eq(request.records[1].sequence, sequence)
	local final_sequence = request.records[#request.records].sequence
	receive_callback(encode({
		v = 1,
		kind = "ack",
		token = request.token,
		session = request.session,
		ack = final_sequence,
	}), "loopback")
	return request.records
end

helpers.describe("logger: real keyDown callback has no blocking side effect", function()
	helpers.it("enqueues an interceptor-boundary error and defers console/notification until ACK", function()
		reset_modules()
		package.loaded["tests.stubs.hs"] = nil
		local hs_stub = require("tests.stubs.hs")
		hs_stub.__reset()
		_G.hs = hs_stub
		package.loaded["hs"] = hs_stub
		local boundary_calls = {
			json_encode = 0,
			json_decode = 0,
			socket_new = 0,
			socket_listen = 0,
			socket_receive = 0,
			socket_send = 0,
			scheduler_every = 0,
			timer_do_after = 0,
			timer_do_every = 0,
			timer_new = 0,
			timer_delayed_new = 0,
		}
		local raw_json_encode = hs_stub.json.encode
		local raw_json_decode = hs_stub.json.decode
		hs_stub.json.encode = function(...)
			boundary_calls.json_encode = boundary_calls.json_encode + 1
			return raw_json_encode(...)
		end
		hs_stub.json.decode = function(...)
			boundary_calls.json_decode = boundary_calls.json_decode + 1
			return raw_json_decode(...)
		end

		local timer_originals = {}
		local function instrument_timer(owner, name, counter)
			if type(owner) ~= "table" or type(owner[name]) ~= "function" then return end
			timer_originals[#timer_originals + 1] = { owner = owner, name = name, fn = owner[name] }
			local original = owner[name]
			owner[name] = function(...)
				boundary_calls[counter] = boundary_calls[counter] + 1
				return original(...)
			end
		end
		instrument_timer(hs_stub.timer, "doAfter", "timer_do_after")
		instrument_timer(hs_stub.timer, "doEvery", "timer_do_every")
		instrument_timer(hs_stub.timer, "new", "timer_new")
		instrument_timer(hs_stub.timer.delayed, "new", "timer_delayed_new")
		local file_system_write_calls = 0
		package.loaded["adapters.file_system"] = setmetatable({
			write = function()
				file_system_write_calls = file_system_write_calls + 1
				return false, "filesystem publication is forbidden from keyDown"
			end,
		}, { __index = function() return function() return nil end end })
		package.loaded["hs.fs"] = hs_stub.fs
		package.loaded["hs.json"] = hs_stub.json
		package.loaded["hs.sqlite3"] = hs_stub.sqlite3
		package.loaded["hs.timer"] = hs_stub.timer
		package.loaded["infra.timings"] = {
			ms = function() return 100 end,
			sec = function() return 0.1 end,
		}
		package.loaded["infra.paths"] = {
			shared = function(relative) return helpers.shared(relative) end,
			shared_llm_path = function(relative)
				return helpers.shared("modules/llm/" .. tostring(relative or ""))
			end,
		}
		local function noop() end
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = { llm_after_hotstring = false, llm_reset_on_nav = true },
			check_modifiers = function() return false end,
		}
		package.loaded["modules.llm.prediction_engine"] = {
			init = function() return true end,
			set_runtime_guard = noop,
			get_llm_enabled = function() return false end,
			reset = function() return true end,
			handle_chain_signal = function() return false end,
			is_visible = function() return false end,
		}
		package.loaded["modules.keylogger"] = setmetatable({
			notify_synthetic = noop,
			set_buffer = noop,
		}, { __index = function() return noop end })
		package.loaded["ui.tooltip"] = setmetatable({
			tint = function() return {} end,
			is_visible = function() return false end,
			is_hotstring_visible = function() return false end,
			has_visible_hotstring_lease = function() return false end,
		}, { __index = function() return noop end })
		package.loaded["modules.hotstrings.hotstrings_config"] = {
			resolve = function() return nil end,
		}
		package.loaded["adapters.tooltip_renderer"] = { hide = function() return true end }

		local sent = {}
		local bootstrap_requests = {}
		local receive_callback = nil
		hs_stub.socket = {
			udp = {
				parseAddress = function(sockaddr)
					if sockaddr == "loopback" then return { host = "127.0.0.1", port = 49152 } end
					return { host = tostring(sockaddr) }
				end,
				new = function(callback)
					boundary_calls.socket_new = boundary_calls.socket_new + 1
					receive_callback = callback
					return {
						listen = function(_, bind_port)
							boundary_calls.socket_listen = boundary_calls.socket_listen + 1
							helpers.assert_eq(bind_port, 0,
								"runtime ACK receiver must bind one ephemeral local port")
							return true
						end,
						receive = function()
							boundary_calls.socket_receive = boundary_calls.socket_receive + 1
							return true
						end,
						send = function(_, payload, host, port, tag)
							boundary_calls.socket_send = boundary_calls.socket_send + 1
							sent[#sent + 1] = {
								payload = payload, host = host, port = port, tag = tag,
							}
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
				boundary_calls.scheduler_every = boundary_calls.scheduler_every + 1
				pump = callback
				return { callback = callback }, true
			end,
			cancel = function() return true end,
		}

		local Logger = require("infra.logger")
		Logger.set_level("DEBUG")
		local port = 49152
		local token = string.rep("a", 32)
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
		local ready, ready_err = Logger.start_async_sink(setmetatable(scheduler, {
			__index = function() return function() return true end end,
		}), {
			port = port,
			token = token,
			bootstrap_socket_factory = bootstrap_socket_factory,
		})
		helpers.assert_true(ready, "the fake authenticated transport must commit: " .. tostring(ready_err))
		helpers.assert_type(receive_callback, "function")
		helpers.assert_type(pump, "function")
		helpers.assert_eq(#bootstrap_requests, 1,
			"start must prove one authenticated configure ACK before keyDown can exist")
		helpers.assert_eq(#sent, 0,
			"the runtime socket must remain idle until the post-keyDown pump")
		helpers.assert_eq(boundary_calls.socket_new, 1,
			"the socket-construction tripwire must observe the real runtime transport")
		helpers.assert_eq(boundary_calls.socket_listen, 1,
			"the listen tripwire must observe the real ephemeral bind")
		helpers.assert_eq(boundary_calls.socket_receive, 1,
			"the receive tripwire must observe ACK activation")
		helpers.assert_eq(boundary_calls.scheduler_every, 1,
			"the scheduler tripwire must observe the owned logger pump")
		helpers.assert_true(boundary_calls.json_encode > 0 and boundary_calls.json_decode > 0,
			"the codec tripwires must observe the authenticated configure exchange")

		package.loaded["adapters.event_provenance"] = {
			STATUS_UNREADABLE = "unreadable",
			classify_with_fence = function()
				return nil, "physical", { events = {} }
			end,
		}

		local keymap = require("modules.keymap.init")
		helpers.assert_type(keymap, "table")
		local synthetic_input = require("adapters.synthetic_input")
		local original_enter_callback = synthetic_input.enter_callback
		synthetic_input.enter_callback = function()
			error("causal interceptor failure")
		end
		local keydown = nil
		for _, tap in ipairs(hs_stub.eventtap.__taps) do
			if #tap.types == 1 and tap.types[1] == hs_stub.eventtap.event.types.keyDown then
				keydown = tap.fn
				break
			end
		end
		helpers.assert_type(keydown, "function", "the production keyDown callback must be captured")

		local console_calls = 0
		local notification_calls = 0
		local notification_module = nil
		local notification_message = nil
		local file_calls = 0
		local saved_print = _G.print
		local saved_io_open = io.open
		_G.print = function() console_calls = console_calls + 1 end
		io.open = function(...)
			file_calls = file_calls + 1
			return saved_io_open(...)
		end
		Logger.set_error_notification_handler(function(module_name, message)
			notification_calls = notification_calls + 1
			notification_module = module_name
			notification_message = message
			return true
		end)
		local route_patterns = {}
		for _, route in ipairs(require("_generated.logger_sub_files")) do
			for _, pattern in ipairs(route.patterns) do route_patterns[pattern] = true end
		end
		local route_find_calls = 0
		local raw_string_find = string.find
		string.find = function(subject, pattern, ...)
			if route_patterns[pattern] == true then
				route_find_calls = route_find_calls + 1
			end
			return raw_string_find(subject, pattern, ...)
		end

		local hid_boundary_keys = {
			"json_encode", "json_decode",
			"socket_new", "socket_listen", "socket_receive", "socket_send",
			"scheduler_every",
			"timer_do_after", "timer_do_every", "timer_new", "timer_delayed_new",
		}
		local before_keydown = {}
		for _, name in ipairs(hid_boundary_keys) do before_keydown[name] = boundary_calls[name] end
		before_keydown.route_find = route_find_calls

		local target_delivered = false
		local body_ok, body_err = xpcall(function()
			local before = Logger.async_sink_status().queued
			local ok, callback_err = pcall(keydown, {})
			local after = Logger.async_sink_status().queued
			if not ok then
				error("the production callback must contain the injected failure: "
					.. tostring(callback_err), 0)
			end
			helpers.assert_true(after > before, "the callback must enqueue at least one diagnostic record")
			for _, name in ipairs(hid_boundary_keys) do
				helpers.assert_eq(boundary_calls[name], before_keydown[name],
					"keyDown must cross no " .. name .. " boundary before returning")
			end
			helpers.assert_eq(route_find_calls, before_keydown.route_find,
				"keyDown must not derive topical routes before returning")
			helpers.assert_eq(console_calls, 0, "Logger must not print before keyDown returns")
			helpers.assert_eq(file_calls, 0, "Logger must not open a file before keyDown returns")
			helpers.assert_eq(file_system_write_calls, 0,
				"keyDown must not enter FileSystem.write or its blocking native helper")
			helpers.assert_eq(notification_calls, 0, "Logger must not notify before keyDown returns")

			local next_sequence = 1
			while Logger.async_sink_status().queued > 0 do
				local sends_before_pump = boundary_calls.socket_send
				local encodes_before_pump = boundary_calls.json_encode
				local routes_before_pump = route_find_calls
				pump()
				helpers.assert_eq(boundary_calls.socket_send, sends_before_pump + 1,
					"the timer-owned pump must perform the deferred socket send")
				helpers.assert_true(boundary_calls.json_encode > encodes_before_pump,
					"the timer-owned pump must perform deferred JSON encoding")
				helpers.assert_true(route_find_calls > routes_before_pump,
					"the timer-owned pump must derive the deferred topical route")
				local decodes_before_ack = boundary_calls.json_decode
				local records = ack_for(hs_stub, sent, receive_callback, next_sequence,
					raw_json_encode, raw_json_decode)
				helpers.assert_true(boundary_calls.json_decode > decodes_before_ack,
					"the production ACK callback must perform deferred JSON decoding")
				for _, record in ipairs(records) do
					if record.line and record.line:find("causal interceptor failure", 1, true) then
						target_delivered = true
					end
				end
				next_sequence = records[#records].sequence + 1
			end
		end, debug.traceback)

		io.open = saved_io_open
		_G.print = saved_print
		string.find = raw_string_find
		hs_stub.json.encode = raw_json_encode
		hs_stub.json.decode = raw_json_decode
		synthetic_input.enter_callback = original_enter_callback
		for _, original in ipairs(timer_originals) do
			original.owner[original.name] = original.fn
		end
		if not body_ok then error(body_err, 0) end
		helpers.assert_true(target_delivered, "the exact callback diagnostic must cross the pump")
		helpers.assert_true(console_calls > 0, "native ACK must release deferred console delivery")
		helpers.assert_eq(notification_calls, 1,
			"the exact acknowledged ERROR, not a dedup summary, must release one notification")
		helpers.assert_eq(notification_module, "keymap")
		helpers.assert_contains(notification_message, "causal interceptor failure")
		helpers.assert_eq(file_calls, 0,
			"even after ACK, persistence belongs to the native worker rather than Lua io.open")
		helpers.assert_eq(file_system_write_calls, 0,
			"native ACK delivery must not fall back to synchronous FileSystem.write")
	end)
end)
