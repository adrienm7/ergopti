--- tests/unit/modules/gestures/engine/test_gesture_click_retirement.lua

--- Real manager/lifecycle with explicit native process admission and settlement.
local Errors = require("adapter_errors")
local helpers = require("tests.helpers")
local function with_manager(body)
	local saved = {}; for name, value in pairs(package.loaded) do saved[name] = value end
	local Process, Clock = require("adapters.owned_process"), require("infra.monotonic")
	local start, now, execute = Process.start, Clock.now_ms, os.execute
	local state = { paused = false, time = 1000, operations = {}, commands = {} }
	local function record(command)
		state.commands[#state.commands + 1] = command
		if state.emit then return state.emit(command) end
		return true
	end
	local ok, err = pcall(function()
		local logger = dofile(helpers.driver_root() .. "/../_shared/lua/logger/init.lua")
		package.loaded["logger.shim"] = logger
		state.logger, state.diagnostics, state.errors = logger, {}, 0
		logger.clock_fn = function() return state.time / 1000 end
		logger.set_sink(function(line, variant)
			if not line:find("modules.gestures.click_hold", 1, true) then return end
			state.diagnostics[#state.diagnostics + 1] = { line = line, variant = variant }
			if state.observe_log then state.observe_log(line, variant) end
		end)
		logger.set_error_observer(function() state.errors = state.errors + 1 end)
		-- os.execute observes the OLD background path too, for causal baseline RED.
		os.execute = record
		Clock.now_ms = function() return state.time end
		Process.start = function(executable, args, options)
			if state.start_throws then error("PRIVATE_CONSTRUCTOR_BODY") end
			helpers.assert_eq(executable, "xdotool")
			helpers.assert_eq(options.timeout_ms, require("infra.timings").ms("gestures", "aux_shell_timeout_ms"))
			helpers.assert_eq(options.capture_output, false)
			local op = { started = true, settled = false, options = options, action = args[1], button = args[2] }
			function op:is_settled() return self.settled end
			function op:cancel() self.cancelled = true; return state.cancel_ack == true or self.settled end
			state.operations[#state.operations + 1] = op
			if state.start_refused then
				op.started, op.settled, op.result = false, true, { ok = false }
				op.not_found = state.not_found
				return op
			end
			local called, ack = pcall(record, "xdotool " .. args[1] .. " " .. args[2])
			if not state.hold then
				op.result, op.settled = { ok = called and ack == true,
					error = (not called or ack ~= true) and Errors.PROCESS_EXITED_UNSUCCESSFULLY or nil,
					exit_code = (called and ack == true) and 0 or 1,
					stdout = "PRIVATE_PROCESS_OUTPUT", stderr = "PRIVATE_PROCESS_ERROR" }, true
			end
			return op
		end
		package.loaded["modules.gestures.click_hold"] = nil
		local manager = helpers.load_module("modules.gestures.manager")
		manager.init({ enabled = false, persist = false, is_paused = function()
			if state.observe_active then state.observe_active() end
			return state.paused
		end })
		function state.harvest() manager.pump(); manager.pump() end
		function state.advance()
			state.time = state.time + require("infra.timings").ms("gestures", "aux_shell_cleanup_retry_ms")
			state.harvest()
		end
		body(manager, state)
	end)
	Process.start, Clock.now_ms, os.execute = start, now, execute
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not ok then error(err, 0) end
end
local function edges(state)
	local out = {}; for _, command in ipairs(state.commands) do
		local edge, button = command:match("xdotool (mouse%a+) ([13])")
		if edge then out[#out + 1] = edge .. ":" .. button end
	end
	return out
end
local function holds(manager, state)
	manager.execute_action("left_click_toggle", "left")
	manager.execute_action("right_click_toggle", "right")
	state.harvest()
	helpers.assert_eq(edges(state), { "mousedown:1", "mousedown:3" })
end
helpers.describe("gesture click retirement", function()
	-- click.ahk: an InputHook started with the hold releases it at the next
	-- key-down (GestureOnKeyDown). Linux kept the button down until the next
	-- toggle, a pause or a disable (GSL-002, click-hold-key-release).
	helpers.it("releases both held buttons at the next key press (click-hold-key-release)", function()
		with_manager(function(manager, state)
			helpers.assert_true(manager.release_clicks_on_activity(), "nothing held: nothing to do")
			helpers.assert_eq(edges(state), {}, "and no native helper runs for it")
			holds(manager, state)
			manager.release_clicks_on_activity()
			state.harvest()
			helpers.assert_eq(edges(state), { "mousedown:1", "mousedown:3", "mouseup:1", "mouseup:3" })
			manager.execute_action("left_click_toggle", "left")
			state.harvest()
			helpers.assert_eq(edges(state)[5], "mousedown:1", "a released hold can be taken again")
		end)
	end)

	-- The daemon's physical key observer is the caller, ahead of the privacy
	-- gate: a key typed in a secure field ends the hold too.
	helpers.it("wires every physical key press to the click release (click-hold-key-release)", function()
		local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
		local source = file:read("*a")
		file:close()
		local start = assert(source:find("local function handle_physical(", 1, true), "the physical key observer")
		local gate = assert(source:find("secure_focus_guard.blocks_text()", start, true), "its privacy gate")
		local call = source:find("gestures.release_clicks_on_activity()", start, true)
		helpers.assert_true(call ~= nil and call < gate, "the release runs before the privacy gate")
	end)

	helpers.it("releases a toggled button when its gesture binding is removed", function()
		with_manager(function(manager, state)
			helpers.assert_true(manager.set_action("swipe_3_left", "left_click_toggle"))
			manager._test_begin_reading({ feed = function() end })
			package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad",
				drain = function() return 0, "would_block" end, close = function() return true end }
			helpers.assert_true(manager.enable())
			helpers.assert_true(manager.dispatch_gesture({ fingers = 3, direction = "left" }))
			state.harvest()
			helpers.assert_eq(edges(state), { "mousedown:1" })
			helpers.assert_true(manager.set_action("swipe_3_left", "none"))
			state.harvest()
			helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1" }, "the removed binding cannot leave a held button")
		end)
	end)


	helpers.it("waits for a removed binding's DOWN child before releasing", function()
		with_manager(function(manager, state)
			helpers.assert_true(manager.set_action("swipe_3_left", "left_click_toggle"))
			state.hold = true
			manager.execute_action("left_click_toggle", "swipe_3_left")
			local down = state.operations[1]
			helpers.assert_true(manager.set_action("swipe_3_left", "none"))
			helpers.assert_true(down.cancelled)
			state.harvest()
			helpers.assert_eq(edges(state), { "mousedown:1" }, "cancellation intent does not prove child exit")
			down.result, down.settled = { ok = false, error = "cancelled" }, true
			state.harvest()
			helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1" })
			local up = state.operations[2]; up.result, up.settled = { ok = true }, true
			state.harvest()
		end)
	end)

	helpers.it("preserves a different binding's held button when a gesture is changed", function()
		with_manager(function(manager, state)
			helpers.assert_true(manager.set_action("swipe_3_left", "left_click_toggle"))
			manager.execute_action("left_click_toggle", "tap_key__other"); state.harvest()
			helpers.assert_true(manager.set_action("swipe_3_left", "none")); state.harvest()
			helpers.assert_eq(edges(state), { "mousedown:1" })
			manager.execute_action("left_click_toggle", "tap_key__other"); state.harvest()
			helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1" })
		end)
	end)

	helpers.it("keeps the other button held when one gesture is reassigned", function()
		with_manager(function(manager, state)
			helpers.assert_true(manager.set_action("swipe_3_left", "left_click_toggle"))
			helpers.assert_true(manager.set_action("swipe_3_right", "right_click_toggle"))
			manager.execute_action("left_click_toggle", "swipe_3_left")
			manager.execute_action("right_click_toggle", "swipe_3_right"); state.harvest()
			helpers.assert_true(manager.set_action("swipe_3_left", "none")); state.harvest()
			helpers.assert_eq(edges(state), { "mousedown:1", "mousedown:3", "mouseup:1" })
			manager.execute_action("right_click_toggle", "swipe_3_right"); state.harvest()
			helpers.assert_eq(edges(state), { "mousedown:1", "mousedown:3", "mouseup:1", "mouseup:3" })
		end)
	end)

	helpers.it("keeps unchanged and refused gesture assignments from releasing a button", function()
		with_manager(function(manager, state)
			helpers.assert_true(manager.set_action("swipe_3_left", "left_click_toggle"))
			manager.execute_action("left_click_toggle", "swipe_3_left"); state.harvest()
			helpers.assert_true(manager.set_action("swipe_3_left", "left_click_toggle")); state.harvest()
			local persist = manager._persist_updates
			manager._persist_updates = function() return false end
			helpers.assert_eq(manager.set_action("swipe_3_left", "none"), false)
			manager._persist_updates = persist
			state.harvest(); helpers.assert_eq(edges(state), { "mousedown:1" })
			manager.execute_action("left_click_toggle", "swipe_3_left"); state.harvest()
			helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1" })
		end)
	end)

	for _, route in ipairs({ "reset", "clear" }) do
		helpers.it("retires an owned click during " .. route .. " gesture reassignment", function()
			with_manager(function(manager, state)
				helpers.assert_true(manager.set_action("swipe_3_left", "left_click_toggle"))
				manager.execute_action("left_click_toggle", "swipe_3_left"); state.harvest()
				if route == "reset" then helpers.assert_true(manager.reset_defaults())
				else helpers.assert_true(manager.disable_all_actions()) end
				state.harvest()
				helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1" })
			end)
		end)
	end


	helpers.it("does not retire a replacement click when finalizing a captured receipt", function()
		with_manager(function(manager, state)
			helpers.assert_true(manager.set_action("swipe_3_left", "left_click_toggle"))
			manager.execute_action("left_click_toggle", "swipe_3_left"); state.harvest()
			local owner = {}
			helpers.assert_true(manager.acquire_parameter_configuration(owner))
			local receipt = manager.capture_click_configuration(owner, "swipe_3_left")
			local actions = manager.parameter_configuration_actions_snapshot(owner)
			actions.swipe_3_left = "open_url"
			helpers.assert_true(manager.apply_parameter_configuration_actions(owner, actions))
			helpers.assert_true(manager.seal_click_configuration(owner, receipt))
			helpers.assert_true(manager.release_parameter_configuration(owner))
			manager.execute_action("left_click_toggle", "swipe_3_left"); state.harvest()
			manager.execute_action("left_click_toggle", "swipe_3_left"); state.harvest()
			helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1", "mousedown:1" })
			manager.commit_click_configuration(owner, receipt); state.harvest()
			helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1", "mousedown:1" })
		end)
	end)

	helpers.it("does not start a removed gesture click during parameter publication", function()
		with_manager(function(manager, state)
			manager._test_begin_reading({ feed = function() end })
			package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad", close = function() return true end, drain = function() return 0, "would_block" end }
			helpers.assert_true(manager.enable())
			helpers.assert_true(manager.set_action("swipe_3_left", "left_click_toggle"))
			local path = os.tmpname(); local backup = path .. ".backup"
			local file = assert(io.open(path, "w")); file:write('[gestures]\nswipe_3_left = "left_click_toggle"\n'); file:close()
			local stop = manager.stop_programs
			local ran = false
			manager.stop_programs = function()
				ran = true
				helpers.assert_eq(manager.dispatch_gesture({ fingers = 3, direction = "left" }), false)
				helpers.assert_eq(manager.execute_action("left_click_toggle", "swipe_3_left"), false)
				state.harvest()
				return stop()
			end
			local owner = require("infra.program_binding_transaction").new({ binding = "swipe_3_left", action = "open_url",
				scalar = "https://example.test", path = path, backup_path = backup,
				is_paused = function() return false end, parameters = manager })
			local ok, detail = xpcall(function()
				helpers.assert_true(owner.apply()); helpers.assert_true(ran); state.harvest()
				helpers.assert_eq(edges(state), {}, "the old binding cannot acquire a new click after capture")
			end, debug.traceback)
			manager.stop_programs = stop
			os.remove(path); os.remove(path .. ".tmp"); os.remove(backup); os.remove(backup .. ".tmp")
			if not ok then error(detail, 0) end
		end)
	end)
	for _, accepted in ipairs({ false, true }) do
		helpers.it("preserves the click until gesture disable is " .. (accepted and "committed" or "refused"), function()
			with_manager(function(manager, state)
				manager._test_begin_reading({ feed = function() end })
				package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad",
					close = function() return true end, drain = function() return 0, "would_block" end }
				helpers.assert_true(manager.enable())
				manager.execute_action("left_click_toggle", "swipe_3_left"); state.harvest()
				local persist = manager._persist_updates
				manager._persist_updates = function()
					manager.pump()
					helpers.assert_eq(edges(state), { "mousedown:1" }, "UP must await durable publication")
					return accepted
				end
				if not accepted then
					package.loaded["modules.gestures.touchpad_finder"] = { read_resolution = function() return nil end, read_axes = function() return nil end, find = function() return { path = "/dev/input/test", max_fingers = 5 } end }
					local reader = package.loaded["adapters.evdev_reader"]
					reader.open = function() return true end
				end
				local result = manager.set_enabled(false)
				manager._persist_updates = persist
				helpers.assert_eq(result, accepted)
				if not accepted then helpers.assert_true(manager.is_enabled()); helpers.assert_true(manager.is_reading()) end
				state.harvest()
				helpers.assert_eq(edges(state), accepted and { "mousedown:1", "mouseup:1" } or { "mousedown:1" })
			end)
		end)
	end

	for _, accepted in ipairs({ false, true }) do
		helpers.it("fences gesture clicks until activation is " .. (accepted and "committed" or "refused"), function()
			with_manager(function(manager, state)
				helpers.assert_true(manager.set_action("swipe_3_left", "left_click_toggle"))
				package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad", open = function() return true end,
					close = function() return true end, drain = function() return 0, "would_block" end }
				package.loaded["modules.gestures.touchpad_finder"] = { read_resolution = function() return nil end, read_axes = function() return nil end, find = function() return { path = "/dev/input/test", max_fingers = 5 } end }
				local persist, observed = manager._persist_updates, nil
				manager._persist_updates = function()
					observed = manager.dispatch_gesture({ fingers = 3, direction = "left" })
					helpers.assert_eq(manager.execute_action("left_click_toggle", "swipe_3_left"), false)
					state.harvest()
					return accepted
				end
				local result = manager.set_enabled(true)
				manager._persist_updates = persist
				helpers.assert_eq(result, accepted)
				helpers.assert_eq(observed, false, "a provisional activation cannot admit a click")
				helpers.assert_eq(edges(state), {}, "a refused activation must not leave a held button")
				if accepted then
					helpers.assert_true(manager.dispatch_gesture({ fingers = 3, direction = "left" }))
					state.harvest(); helpers.assert_eq(edges(state), { "mousedown:1" })
				end
			end)
		end)
	end

	helpers.it("keeps a held click when the provisional touchpad close is refused", function()
		with_manager(function(manager, state)
			manager._test_begin_reading({ feed = function() end })
			package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad", close = function() return false, "refused" end,
				drain = function() return 0, "would_block" end }
			helpers.assert_true(manager.enable())
			manager.execute_action("left_click_toggle", "swipe_3_left"); state.harvest()
			helpers.assert_eq(manager.set_enabled(false), false)
			state.harvest()
			helpers.assert_eq(edges(state), { "mousedown:1" })
		end)
	end)

	helpers.it("retains and retries the disable owner when applying raises", function()
		with_manager(function(manager, state)
			manager._test_begin_reading({ feed = function() end })
			package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad", close = function() return true end,
				drain = function() return 0, "would_block" end }
			helpers.assert_true(manager.enable())
			manager.execute_action("left_click_toggle", "swipe_3_left"); state.harvest()
			local apply = manager.apply_scope_state
			local calls = 0
			manager.apply_scope_state = function(...)
				calls = calls + 1
				if calls == 1 then error("controlled apply exception") end
				return apply(...)
			end
			helpers.assert_eq(manager.set_enabled(false), false)
			manager.apply_scope_state = apply
			helpers.assert_true(calls >= 2)
			helpers.assert_true(manager.is_enabled())
			helpers.assert_eq(edges(state), { "mousedown:1" })
			helpers.assert_true(manager.set_action("swipe_3_left", "none"))
		end)
	end)

	for _, publish in ipairs({ false, true }) do
		helpers.it("reconciles disable when the writer throws " .. (publish and "after" or "before") .. " publication", function()
			with_manager(function(manager, state)
				local path = os.tmpname()
				local file = assert(io.open(path, "w")); file:write('[gestures]\nenabled = true\n'); file:close()
				manager.init({ enabled = false, persist = true, config_path = path, is_paused = function() return false end })
				manager._test_begin_reading({ feed = function() end })
				package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad", close = function() return true end,
					open = function() return true end, drain = function() return 0, "would_block" end }
				package.loaded["modules.gestures.touchpad_finder"] = { read_resolution = function() return nil end, read_axes = function() return nil end, find = function() return { path = "/dev/input/test", max_fingers = 5 } end }
				helpers.assert_true(manager.enable())
				manager.execute_action("left_click_toggle", "swipe_3_left"); state.harvest()
				local writer, write = require("toml_codec.writer"), require("toml_codec.writer").batch_write
				writer.batch_write = function(...)
					if publish then helpers.assert_true(write(...)) end
					error("controlled writer exception")
				end
				local ok, detail = xpcall(function()
					helpers.assert_eq(manager.set_enabled(false), publish)
					state.harvest()
					helpers.assert_eq(manager.is_enabled(), not publish)
					helpers.assert_eq(edges(state), publish and { "mousedown:1", "mouseup:1" } or { "mousedown:1" })
					writer.batch_write = write
					helpers.assert_true(manager.set_action("swipe_3_left", "none"), "settled ownership must permit later edits")
				end, debug.traceback)
				writer.batch_write = write
				os.remove(path); os.remove(path .. ".tmp")
				if not ok then error(detail, 0) end
			end)
		end)
	end

	for _, mode in ipairs({ "foreign", "reader" }) do
		helpers.it("retains uncertain disable on " .. mode .. " source", function()
			with_manager(function(manager, state)
				local path = os.tmpname(); local original = '[gestures]\nenabled = true\n'
				local f = assert(io.open(path, "wb")); assert(f:write(original)); assert(f:close())
				manager.init({ enabled = false, persist = true, config_path = path, is_paused = function() return false end })
				manager._test_begin_reading({ feed = function() end })
				package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad", close = function() return true end,
					open = function() return true end, drain = function() return 0, "would_block" end }
				package.loaded["modules.gestures.touchpad_finder"] = { read_resolution = function() return nil end, read_axes = function() return nil end, find = function() return { path = "/dev/input/test", max_fingers = 5 } end }
				helpers.assert_true(manager.enable())
				manager.execute_action("left_click_toggle", "swipe_3_left"); state.harvest()
				local writer = require("toml_codec.writer"); local write, read = writer.batch_write, writer.read_classified
				writer.batch_write = function()
					if mode == "foreign" then local x = assert(io.open(path, "wb")); assert(x:write('[gestures]\nenabled = true\n# foreign\n')); assert(x:close())
					else writer.read_classified = function() return nil, "error" end end
					error("uncertain publication")
				end
				local ok, err = xpcall(function()
					helpers.assert_eq(manager.set_enabled(false), false)
					state.harvest(); helpers.assert_eq(edges(state), { "mousedown:1" })
					helpers.assert_true(require("infra.scope_registry").pending())
					helpers.assert_eq(manager.set_enabled(true), false)
					local x = assert(io.open(path, "rb")); local bytes = x:read("*a"); assert(x:close())
					helpers.assert_eq(bytes, mode == "foreign" and '[gestures]\nenabled = true\n# foreign\n' or original)
				end, debug.traceback)
				writer.batch_write, writer.read_classified = write, read; os.remove(path)
				if not ok then error(err, 0) end
			end)
		end)
	end

	helpers.it("rejects a nested state change while the reader is closing", function()
		with_manager(function(manager, state)
			manager._test_begin_reading({ feed = function() end })
			local nested
			package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad", drain = function() return 0, "would_block" end,
				close = function() nested = manager.set_enabled(true); return true end }
			helpers.assert_true(manager.enable())
			manager.execute_action("left_click_toggle", "swipe_3_left"); state.harvest()
			helpers.assert_true(manager.set_enabled(false))
			helpers.assert_eq(nested, false)
			state.harvest(); helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1" })
			helpers.assert_eq(manager.is_enabled(), false)
		end)
	end)

	helpers.it("does not acquire a gesture click during provisional disable", function()
		with_manager(function(manager, state)
			manager._test_begin_reading({ feed = function() end })
			local called = false
			package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad", drain = function() return 0, "would_block" end,
				close = function()
					called = true
					manager.dispatch_gesture({ fingers = 3, direction = "left" })
					return true
				end }
			helpers.assert_true(manager.enable())
			helpers.assert_true(manager.set_action("swipe_3_left", "left_click_toggle"))
			helpers.assert_true(manager.set_enabled(false)); helpers.assert_true(called); state.harvest()
			helpers.assert_eq(edges(state), {}, "provisional close cannot acquire a click after its receipt")
		end)
	end)


	helpers.it("finalizes click retirement after a standalone gesture scope", function()
		with_manager(function(manager, state)
			local dir = os.tmpname(); os.remove(dir); assert(require("lfs").mkdir(dir))
			local path = dir .. "/config.toml"
			local file = assert(io.open(path, "w")); file:write('[gestures]\nenabled = true\nswipe_3_left = "left_click_toggle"\n'); file:close()
			manager.init({ enabled = false, persist = true, config_path = path, is_paused = function() return false end })
			manager._test_begin_reading({ feed = function() end })
			package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad", close = function() return true end, drain = function() return 0, "would_block" end }
			helpers.assert_true(manager.enable())
			manager.execute_action("left_click_toggle", "swipe_3_left"); state.harvest()
			local writer, publish = require("toml_codec.writer"), require("toml_codec.writer").publish_if_unchanged
			local reentered = false
			writer.publish_if_unchanged = function(...)
				if not reentered then
					reentered = true
					helpers.assert_eq(manager.apply_scope("clear"), false)
				end
				return publish(...)
			end
			local ok, detail = xpcall(function()
				helpers.assert_true(manager.apply_scope("clear")); helpers.assert_true(reentered)
				state.harvest(); helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1" })
			end, debug.traceback)
			writer.publish_if_unchanged = publish
			for name in require("lfs").dir(dir) do if name ~= "." and name ~= ".." then os.remove(dir .. "/" .. name) end end
			assert(require("lfs").rmdir(dir))
			if not ok then error(detail, 0) end
		end)
	end)

	helpers.it("retains finalization after a later participant refuses release", function()
		with_manager(function(manager, state)
			local path = os.tmpname(); local backup = path .. ".backup"
			local file = assert(io.open(path, "w")); file:write('[gestures]\nenabled = true\nswipe_3_left = "left_click_toggle"\n'); file:close()
			manager._test_begin_reading({ feed = function() end })
			package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad", close = function() return true end,
				open = function() return true end, drain = function() return 0, "would_block" end }
			package.loaded["modules.gestures.touchpad_finder"] = { read_resolution = function() return nil end, read_axes = function() return nil end, find = function() return { path = "/dev/input/test", max_fingers = 5 } end }
			helpers.assert_true(manager.enable()); helpers.assert_true(manager.set_action("swipe_3_left", "left_click_toggle"))
			manager.execute_action("left_click_toggle", "swipe_3_left"); state.harvest()
			local scope = require("infra.gesture_scope").new({ path = path, backup_path = backup, gestures = manager })
			local participant = require("config_scope_participant").synchronous({ apply = function(mode) return scope.apply(mode) end, owner = function() return scope end })
			local releases, reversions = 0, 0
			local other = { pending = function() return false end, apply = function(_, done) done(true) end,
				revert = function(done) reversions = reversions + 1; done(true) end,
				release = function() releases = releases + 1; return releases > 1 end,
				retry_restore = function(done) done(true) end }
			local logger = { start = function() end, success = function() end, info = function() end, warn = function() end, error = function() end }
			local composed = require("config_scope_composition").new({ scope = "all", logger = logger,
				manifest = { scopes = function() return { all = { includes = { "gestures", "other" } }, gestures = {}, other = {} } end },
				participants = function() return { gestures = participant, other = other } end })
			local ok, detail = xpcall(function()
				local result, report; composed.apply("clear", function(value, r) result, report = value, r end)
				helpers.assert_eq(result, false); helpers.assert_eq(report.committed, true)
				helpers.assert_eq(report.finalization_pending, true); helpers.assert_true(composed.pending())
				state.harvest(); helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1" })
				local retry; composed.retry_restore(function(value) retry = value end)
				helpers.assert_eq(retry, true); helpers.assert_eq(reversions, 0); helpers.assert_eq(releases, 2)
				state.harvest(); helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1" })
			end, debug.traceback)
			os.remove(path); os.remove(path .. ".tmp"); os.remove(backup); os.remove(backup .. ".tmp")
			if not ok then error(detail, 0) end
		end)
	end)

	for _, succeeds in ipairs({ false, true }) do
		helpers.it("preserves exact click through composed scope " .. (succeeds and "finalization" or "rollback"), function()
			with_manager(function(manager, state)
				local path = os.tmpname(); local backup = path .. ".backup"
				local file = assert(io.open(path, "w")); file:write('[gestures]\nenabled = true\nswipe_3_left = "left_click_toggle"\n'); file:close()
				manager._test_begin_reading({ feed = function() end })
				package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad", close = function() return true end,
					open = function() return true end, drain = function() return 0, "would_block" end }
				package.loaded["modules.gestures.touchpad_finder"] = { read_resolution = function() return nil end, read_axes = function() return nil end, find = function() return { path = "/dev/input/test", max_fingers = 5 } end }
				helpers.assert_true(manager.enable())
				helpers.assert_true(manager.set_action("swipe_3_left", "left_click_toggle"))
				manager.execute_action("left_click_toggle", "swipe_3_left"); state.harvest()
				local scope = require("infra.gesture_scope").new({ path = path, backup_path = backup, gestures = manager })
				local participant = require("config_scope_participant").synchronous({ apply = function(mode) return scope.apply(mode) end, owner = function() return scope end })
				local reached = false
				local other = { pending = function() return false end, apply = function(_, done)
						reached = true
						helpers.assert_eq(manager.execute_action("left_click_toggle", "swipe_3_left"), false)
						manager.pump(); helpers.assert_eq(edges(state), { "mousedown:1" }); done(succeeds)
					end,
					revert = function(done) done(true) end, release = function() end, retry_restore = function(done) done(true) end }
				local logger = { start = function() end, success = function() end, info = function() end, warn = function() end, error = function() end }
				local composed = require("config_scope_composition").new({ scope = "all", logger = logger,
					manifest = { scopes = function() return { all = { includes = { "gestures", "other" } }, gestures = {}, other = {} } end },
					participants = function() return { gestures = participant, other = other } end })
				local ok, detail = xpcall(function()
					local result; composed.apply("clear", function(value) result = value end)
					helpers.assert_true(reached, "the following scope must run")
					helpers.assert_eq(result, succeeds)
					state.harvest()
					helpers.assert_eq(edges(state), succeeds and { "mousedown:1", "mouseup:1" } or { "mousedown:1" })
				end, debug.traceback)
				os.remove(path); os.remove(path .. ".tmp"); os.remove(backup); os.remove(backup .. ".tmp")
				if not ok then error(detail, 0) end
			end)
		end)
	end

	for _, mode in ipairs({ "publication refused", "release refused", "committed" }) do
		helpers.it("retains click ownership through " .. mode .. " parameter publication", function()
			local refused = mode ~= "committed"
			with_manager(function(manager, state)
				helpers.assert_true(manager.set_action("swipe_3_left", "left_click_toggle"))
				manager.execute_action("left_click_toggle", "swipe_3_left"); state.harvest()
				local path = os.tmpname(); local backup = path .. ".backup"
				local file = assert(io.open(path, "w")); file:write('[gestures]\nswipe_3_left = "left_click_toggle"\n'); file:close()
				local Writer = require("toml_codec.writer")
				local files = {
					read_with_status = function(target) return Writer.read_classified(target) end,
					write = function() error("unconditional publication is forbidden") end,
					write_if_unchanged = function(target, content, expected)
						if target == path then
							manager.pump()
							helpers.assert_eq(edges(state), { "mousedown:1" }, "publication cannot release a click")
							if mode == "publication refused" then return false, "controlled publication refusal" end
						end
						return Writer.publish_if_unchanged(target, content, nil, expected)
					end,
				}
				local release = manager.release_parameter_configuration
				if mode == "release refused" then
					local first = true
					manager.release_parameter_configuration = function(token)
						if first then first = false; return false end
						return release(token)
					end
				end
				local owner = require("infra.program_binding_transaction").new({ binding = "swipe_3_left",
					action = "open_url", scalar = "https://example.test", path = path, backup_path = backup,
					is_paused = function() return false end, parameters = manager, files = files })
				local ok, detail = xpcall(function()
					helpers.assert_eq(owner.apply(), not refused)
					state.harvest()
					if refused then
						helpers.assert_eq(manager.get_action("swipe_3_left"), "left_click_toggle")
						helpers.assert_eq(edges(state), { "mousedown:1" }, "compensation cannot invent a reversible UP")
					else
						helpers.assert_eq(manager.get_action("swipe_3_left"), "open_url")
						helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1" })
					end
				end, debug.traceback)
				manager.release_parameter_configuration = release
				os.remove(path); os.remove(path .. ".tmp"); os.remove(backup); os.remove(backup .. ".tmp")
				if not ok then error(detail, 0) end
			end)
		end)
	end

	for _, transition in ipairs({ "disable", "stop", "pause" }) do
		helpers.it("releases both buttons on " .. transition .. " without a touchpad reader", function()
			with_manager(function(manager, state)
				holds(manager, state)
				local initial
				if transition == "pause" then state.paused = true; manager.pump()
				elseif transition == "disable" then initial = manager.disable()
				else initial = manager.stop_reading() end
				helpers.assert_eq(edges(state), { "mousedown:1", "mousedown:3", "mouseup:1", "mouseup:3" },
					"retirement must emit real owned releases before claiming success")
				if transition ~= "pause" then helpers.assert_eq(initial, false, "native UP is not yet harvested") end
				state.harvest()
				helpers.assert_eq(manager.stop_reading(), true)
				helpers.assert_eq(edges(state), { "mousedown:1", "mousedown:3", "mouseup:1", "mouseup:3" })
				helpers.assert_eq(manager.stop_reading(), true)
				helpers.assert_eq(#state.commands, 4)
			end)
		end)
	end
	for _, failure in ipairs({ "false", "throw" }) do
		helpers.it("retains " .. failure .. " UP debt and retries only the exact refused button", function()
			with_manager(function(manager, state)
				holds(manager, state)
				state.emit = function(command)
					if command:find("mouseup 1", 1, true) then
						if failure == "throw" then error("native helper failed") end
						return false
					end
					return true
				end
				helpers.assert_eq(manager.disable(), false)
				state.harvest()
				helpers.assert_eq(manager.stop_reading(), false)
				helpers.assert_eq(#state.commands, 4, "no fork storm before canonical retry interval")
				state.emit = nil; state.advance()
				helpers.assert_eq(manager.stop_reading(), true)
				helpers.assert_eq(edges(state), { "mousedown:1", "mousedown:3", "mouseup:1", "mouseup:3", "mouseup:1" })
			end)
		end)
	end
	helpers.it("waits for physical DOWN-child settlement before dispatching any compensating UP", function()
		with_manager(function(manager, state)
			state.hold, state.cancel_ack = true, true
			manager.execute_action("left_click_toggle", "left")
			local down = state.operations[1]
			helpers.assert_eq(manager.disable(), false)
			helpers.assert_eq(down.cancelled, true)
			state.harvest()
			helpers.assert_eq(edges(state), { "mousedown:1" }, "cancel receipt is not physical settlement")
			down.result, down.settled = { ok = false, error = "cancelled" }, true
			state.harvest()
			helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1" })
			helpers.assert_eq(manager.stop_reading(), false, "UP child itself still owns resources")
			local up = state.operations[2]; up.result, up.settled = { ok = true }, true
			state.harvest(); helpers.assert_eq(manager.stop_reading(), true)
		end)
	end)
	for _, transition in ipairs({ "pause", "disable" }) do
		helpers.it("does not admit another DOWN after reentrant " .. transition .. " during acquisition", function()
			with_manager(function(manager, state)
				local interrupted, once
				state.emit = function(command)
					if not once and command:find("mousedown", 1, true) then
						once = true
						if transition == "pause" then state.paused = true
						else interrupted = manager.disable() end
						manager.execute_action("right_click_toggle", "nested")
					end
					return true
				end
				manager.execute_action("left_click_toggle", "left")
				state.harvest()
				if transition == "disable" then helpers.assert_eq(interrupted, false) end
				helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1" })
				helpers.assert_eq(manager.stop_reading(), true)
			end)
		end)
	end
	helpers.it("never emits an UP without acquisition and toggles both buttons independently", function()
		with_manager(function(manager, state)
			helpers.assert_eq(manager.stop_reading(), true); helpers.assert_eq(#state.commands, 0)
			holds(manager, state)
			manager.execute_action("left_click_toggle", "left"); state.harvest()
			helpers.assert_eq(edges(state), { "mousedown:1", "mousedown:3", "mouseup:1" })
			manager.execute_action("right_click_toggle", "right"); state.harvest()
			helpers.assert_eq(manager.stop_reading(), true)
			helpers.assert_eq(edges(state), { "mousedown:1", "mousedown:3", "mouseup:1", "mouseup:3" })
		end)
	end)
	helpers.it("keeps the actual Main shutdown barrier pending through DOWN retirement and UP ACK", function()
		with_manager(function(manager, state)
			state.hold = true
			manager.execute_action("left_click_toggle", "left")
			local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
			local source = file:read("*a"); file:close()
			local entry = assert(source:match('(%{\n%s*name = "gesture reader",.-\n%s*%}),'))
			local env = { gestures = manager, type = type }
			local chunk
			if setfenv then chunk = assert(loadstring("return " .. entry)); setfenv(chunk, env)
			else chunk = assert(load("return " .. entry, "gesture-shutdown", "t", env)) end
			local stops = 0
			local coordinator = require("infra.shutdown_coordinator").new({ pre_wait = { chunk() },
				keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
				event_loop = { stop = function() stops = stops + 1 end } })
			helpers.assert_eq(coordinator.request("owned-button"), true)
			helpers.assert_eq(coordinator.is_pending(), true); helpers.assert_eq(stops, 0)
			local down = state.operations[1]; down.result, down.settled = { ok = false, error = "cancelled" }, true
			helpers.assert_eq(coordinator.poll(), false)
			local up = state.operations[2]; up.result, up.settled = { ok = true }, true
			helpers.assert_eq(coordinator.poll(), true); helpers.assert_eq(stops, 1)
			helpers.assert_eq(coordinator.poll(), true); helpers.assert_eq(stops, 1)
			helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1" })
		end)
	end)
	for _, failure in ipairs({ "false", "throw" }) do
		helpers.it("compensates a settled " .. failure .. " DOWN with one owned UP", function()
			with_manager(function(manager, state)
				state.emit = function(command)
					if command:find("mousedown", 1, true) then
						if failure == "throw" then error("failed DOWN") end
						return false
					end
					return true
				end
				manager.execute_action("left_click_toggle", "left"); state.harvest()
				helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1" })
				helpers.assert_eq(manager.stop_reading(), true)
			end)
		end)
	end
	helpers.it("does not invent an UP when native dispatch conclusively acquired no child", function()
		with_manager(function(manager, state)
			state.start_refused = true
			manager.execute_action("left_click_toggle", "left"); state.harvest()
			helpers.assert_eq(#state.commands, 0)
			helpers.assert_eq(manager.stop_reading(), true)
		end)
	end)
	helpers.it("retains unknown constructor ownership without dispatching an UP before a physical receipt", function()
		with_manager(function(manager, state)
			state.start_throws = true
			manager.execute_action("left_click_toggle", "left")
			state.harvest(); helpers.assert_eq(manager.stop_reading(), false)
			helpers.assert_eq(#state.commands, 0)
		end)
	end)
	helpers.it("refuses acquisition if disable reenters the active-policy check before any DOWN", function()
		with_manager(function(manager, state)
			local once
			state.observe_active = function()
				if once then return end
				once = true; manager.disable()
			end
			manager.execute_action("left_click_toggle", "left")
			helpers.assert_eq(#state.commands, 0)
			helpers.assert_eq(manager.stop_reading(), true)
		end)
	end)

	helpers.it("blocks new button acquisition between global retirement request and final UP settlement", function()
		with_manager(function(manager, state)
			manager.execute_action("left_click_toggle", "left"); state.harvest()
			state.hold = true
			state.emit = function(command)
				if command:find("mouseup", 1, true) then manager.execute_action("right_click_toggle", "inside-UP") end
				return true
			end
			helpers.assert_eq(manager.disable(), false)
			manager.execute_action("right_click_toggle", "between-ACKs")
			helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1" })
			local up = state.operations[2]; up.result, up.settled = { ok = true }, true
			state.harvest(); helpers.assert_eq(manager.stop_reading(), true)
			state.hold, state.emit = false, nil
			manager.execute_action("right_click_toggle", "fresh-after-settlement"); state.harvest()
			helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1", "mousedown:3" })
			manager.stop_reading(); state.harvest(); helpers.assert_eq(manager.stop_reading(), true)
		end)
	end)
	helpers.it("keeps global retirement latched after one healthy UP while another button retains refusal debt", function()
		with_manager(function(manager, state)
			holds(manager, state); state.hold = true
			helpers.assert_eq(manager.stop_reading(), false)
			local left, right = state.operations[3], state.operations[4]
			right.result, right.settled = { ok = true }, true
			state.harvest(); manager.execute_action("right_click_toggle", "after-other-UP")
			helpers.assert_eq(#state.commands, 4)
			left.result, left.settled = { ok = false }, true
			state.harvest(); manager.execute_action("right_click_toggle", "after-refusal")
			helpers.assert_eq(#state.commands, 4)
			state.hold = false; state.advance()
			helpers.assert_eq(manager.stop_reading(), true)
			manager.execute_action("right_click_toggle", "fresh"); state.harvest()
			helpers.assert_eq(edges(state), { "mousedown:1", "mousedown:3", "mouseup:1", "mouseup:3", "mouseup:1", "mousedown:3" })
			manager.stop_reading(); state.harvest(); helpers.assert_eq(manager.stop_reading(), true)
		end)
	end)

	for _, category in ipairs({ "unavailable", "exit_failed", "deadline", "constructor_unknown" }) do
		helpers.it("diagnoses " .. category .. " through the real logger without private process text or ERROR", function()
			with_manager(function(manager, state)
				if category == "unavailable" then state.start_refused, state.not_found = true, true
				elseif category == "constructor_unknown" then state.start_throws = true
				elseif category == "deadline" then state.hold = true
				else state.emit = function(command) return not command:find("mousedown", 1, true) end end
				manager.execute_action("left_click_toggle", "left")
				if category == "deadline" then
					local op = state.operations[1]
					op.result, op.settled = { ok = false, error = Errors.PROCESS_DEADLINE_EXCEEDED, stderr = "PRIVATE_PROCESS_ERROR" }, true
				end
				state.harvest()
				helpers.assert_eq(#state.diagnostics, 1, "native failure must not disappear silently")
				helpers.assert_eq(state.diagnostics[1].variant, "warn")
				helpers.assert_contains(state.diagnostics[1].line, "button 1 DOWN")
				helpers.assert_contains(state.diagnostics[1].line, category)
				helpers.assert_eq(state.diagnostics[1].line:find("PRIVATE", 1, true), nil)
				helpers.assert_eq(state.errors, 0)
			end)
		end)
	end
	helpers.it("reports an UP failure once per debt despite retries beyond logger dedup windows", function()
		with_manager(function(manager, state)
			manager.execute_action("left_click_toggle", "left"); state.harvest()
			state.emit = function() return false end
			manager.stop_reading(); state.harvest()
			helpers.assert_eq(#state.diagnostics, 1)
			helpers.assert_contains(state.diagnostics[1].line, "button 1 UP")
			for _ = 1, 3 do state.time = state.time + 60000; state.harvest() end
			helpers.assert_eq(#state.diagnostics, 1, "one retained debt is not a fresh failure on every retry")
			helpers.assert_eq(state.errors, 0)
			state.emit = nil; state.advance(); helpers.assert_eq(manager.stop_reading(), true)
		end)
	end)
	helpers.it("keeps normal pause and deliberate pending-DOWN cancellation free of failure notifications", function()
		with_manager(function(manager, state)
			holds(manager, state); state.paused = true; state.harvest()
			helpers.assert_eq(#state.diagnostics, 0); helpers.assert_eq(state.errors, 0)
			state.paused, state.hold = false, true
			manager.execute_action("left_click_toggle", "left")
			local op = state.operations[#state.operations]
			manager.stop_reading()
			op.result, op.settled = { ok = false, error = "cancelled" }, true
			state.hold = false; state.harvest()
			helpers.assert_eq(manager.stop_reading(), true)
			helpers.assert_eq(#state.diagnostics, 0); helpers.assert_eq(state.errors, 0)
		end)
	end)
	for _, behavior in ipairs({ "retire", "throw" }) do
		helpers.it("preserves the original cleanup issuer through a reentrant logger that will " .. behavior, function()
			with_manager(function(manager, state)
				local foreign = 0
				state.emit = function(command) return not command:find("mousedown", 1, true) end
				state.observe_log = function()
					if behavior == "throw" then error("sink output unavailable") end
					manager.disable()
					manager.execute_action("right_click_toggle", "from-diagnostic")
					require("adapters.owned_process").start = function() foreign = foreign + 1; error("foreign issuer") end
				end
				manager.execute_action("left_click_toggle", "left"); state.harvest()
				helpers.assert_eq(#state.diagnostics, 1)
				helpers.assert_eq(foreign, 0)
				helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1" })
				helpers.assert_eq(manager.stop_reading(), true)
				helpers.assert_eq(state.errors, 0)
			end)
		end)
	end

	helpers.it("does not hide an already failed native DOWN when pause requests cancellation afterward", function()
		with_manager(function(manager, state)
			state.hold = true; manager.execute_action("left_click_toggle", "left")
			local op = state.operations[1]
			op.result, op.settled = { ok = false, exit_code = 5, error = Errors.PROCESS_EXITED_UNSUCCESSFULLY }, true
			state.paused, state.hold = true, false
			state.harvest()
			helpers.assert_eq(#state.diagnostics, 1)
			helpers.assert_contains(state.diagnostics[1].line, "exit_failed")
			helpers.assert_eq(manager.stop_reading(), true)
			helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1" })
		end)
	end)

	helpers.it("diagnoses a terminal deadline while physical cleanup remains pending without minting an UP receipt", function()
		with_manager(function(manager, state)
			state.hold = true; manager.execute_action("left_click_toggle", "left")
			local op = state.operations[1]
			op.result = { ok = false, error = Errors.PROCESS_DEADLINE_EXCEEDED }
			state.harvest()
			helpers.assert_eq(#state.diagnostics, 1, "terminal failure must be visible even when group retirement is not")
			helpers.assert_contains(state.diagnostics[1].line, "deadline")
			helpers.assert_eq(manager.stop_reading(), false)
			helpers.assert_eq(edges(state), { "mousedown:1" }, "failure report is not physical settlement")
			op.settled, state.hold = true, false
			state.harvest(); helpers.assert_eq(manager.stop_reading(), true)
			helpers.assert_eq(edges(state), { "mousedown:1", "mouseup:1" })
			helpers.assert_eq(#state.diagnostics, 1)
		end)
	end)

end)
