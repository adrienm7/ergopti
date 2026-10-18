--- tests/unit/modules/gestures/engine/test_gesture_click_retirement.lua

--- Real manager/lifecycle with explicit native process admission and settlement.
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
					error = (not called or ack ~= true) and "process exited unsuccessfully" or nil,
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
					op.result, op.settled = { ok = false, error = "process deadline exceeded", stderr = "PRIVATE_PROCESS_ERROR" }, true
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
			op.result, op.settled = { ok = false, exit_code = 5, error = "process exited unsuccessfully" }, true
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
			op.result = { ok = false, error = "process deadline exceeded" }
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
