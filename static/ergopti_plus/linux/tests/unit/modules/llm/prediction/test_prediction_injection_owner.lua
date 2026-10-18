--- tests/unit/modules/llm/prediction/test_prediction_injection_owner.lua

--- ==============================================================================
--- MODULE: Prediction Injection Destination Ownership
--- DESCRIPTION:
--- Executes the real Engine acceptance, Main callback, focus guard, detector,
--- injector and clipboard with controlled native/I/O ports. Native qualification
--- belongs to the separate GTK proof; these cases claim no kernel input coverage.
--- ==============================================================================
local helpers = require("tests.helpers")

--- Runs a complete offer/accept workflow and restores every imported module.
--- @param action string Transition to deliver, or stable.
--- @param phase string External boundary at which to deliver it.
--- @param body function Receives the public outcome and observed effects.
local function scenario(action, phase, body)
	local saved = {}; for name, value in pairs(package.loaded) do saved[name] = value end
	local engine, guard, injector
	local ok, detail = pcall(function()
		for name in pairs(package.loaded) do
			if name:match("^modules%.llm%.") then package.loaded[name] = nil end
		end
		for _, name in ipairs({ "modules.keylogger.focus_guard", "modules.keylogger.keylogger", "adapters.secure_field_detector",
			"adapters.clipboard", "adapters.keyboard_layout", "modules.hotstrings.injector" }) do package.loaded[name] = nil end
		local state = { bus = ":1.23", path = "/field/original", role = 61, now = 1000,
			rows = {}, held = {}, writes = {}, requests = {}, errors = {}, stopped = 0, resets = 0, output = 0, paused = false }
		local logger = assert(dofile(require("infra.paths").shared("lua/logger/init.lua")))
		logger.set_sink(function() end)
		logger.set_error_observer(function(_, template) state.errors[#state.errors + 1] = template end)
		package.loaded["logger.shim"] = logger
		local policy = require("modules.keylogger.keylogger")
		local configuration = assert(policy.configuration_snapshot()); configuration.private_filter_enabled = false
		assert(policy.apply_configuration(configuration))
		package.loaded["infra.llm_preferences"] = require("tests.support.llm_preferences_fixture").new({ initial = {
			["llm.models.selected"] = "api", ["llm.profiles.auto_profile_for_model"] = false,
			["llm.trigger.secure_filter_enabled"] = true,
		} })
		package.loaded["modules.llm.profiles"] = { init = function() end, is_enabled = function() return true end }
		package.loaded["modules.llm.api_entries"] = { active = function()
			return { id = "owned", provider = "openai_compat", model = "fixture-model" }
		end }
		package.loaded["modules.llm.api_remote"] = {
			provider = function() return { default_model = "fixture-model" } end, serves = function() return true end,
			chat = function(_, _, _, _, _, done) state.requests[#state.requests + 1] = done; return true end,
			cancel = function() return true end,
		}
		engine = require("modules.llm.prediction_engine")
		local listener, receipt
		local watch = {
			on_change = function(fn) listener = fn end,
			pump = function() end,
			barrier = function()
				receipt = { bus = state.bus, path = state.path, role = state.role }
				listener(receipt)
				return receipt
			end,
			snapshot = function() return receipt end,
			invalidate = function() receipt = nil; listener(nil) end,
		}
		guard = require("modules.keylogger.focus_guard").new({ watch = watch,
			detector = require("adapters.secure_field_detector"), keylogger = policy, prediction = engine,
			now_ms = function() return state.now end,
			capture_context = function() return { app_id = "owned-editor", title = "owned-field", native_identity = "owned-window" } end,
			publish_context = function(context) return true, policy.is_context_protected(context.app_id, context.title) end,
		})
		local function transition(point)
			if not state.armed or state.triggered or phase ~= point then return end
			state.triggered = true
			if action == "field" or action == "password" then
				state.path = "/field/successor"
				if action == "password" then state.role = 40 end
			elseif action == "cancel" then engine.cancel()
			elseif action == "pause" then state.paused = true
			elseif action == "shutdown" then engine.shutdown_runtime()
			elseif action == "successor" then
				engine.cancel()
				state.offer()
				state.successor = engine.get_suggestions()[1]
				state.successor_resets = state.resets
			end
		end
		local commands = {}
		package.loaded["adapters.shell_runner"] = {
			has_command = function() return true end,
			exec_checked = function() transition("read"); return true, "SAVED" end,
			with_exact_stdin = function(_, text)
				local command = "controlled-prediction-clipboard-" .. (#commands + 1)
				commands[#commands + 1] = { command = command, text = text }; return command
			end,
			run = function(command)
				for _, item in ipairs(commands) do
					if item.command == command then
						state.writes[#state.writes + 1] = item.text
						if item.text ~= "SAVED" then transition("write") end
						return true
					end
				end
				return false
			end,
		}
		package.loaded["infra.display_server"] = {
			is_x11 = function() return true end, is_wayland = function() return false end, kind = function() return "x11" end,
		}
		package.loaded["adapters.keyboard_hook"] = {
			held_text_modifier_codes = function() return {} end, held_shortcut_modifier_codes = function() return {} end,
			held_forwarded_keys = function() return {} end, emergency_stop = function() state.stopped = state.stopped + 1 end,
		}
		local layout = require("adapters.keyboard_layout")
		layout._set_table_for_test({ o = { keycode = 24, mods = {} }, k = { keycode = 37, mods = {} }, [" "] = { keycode = 57, mods = {} } })
		local shortcut = layout.shortcut_keycode
		layout.shortcut_keycode = function(...) transition("lookup"); return shortcut(...) end
		injector = require("modules.hotstrings.injector")
		injector._set_uinput({ is_open = function() return true end, emit = function(code, value)
			state.rows[#state.rows + 1] = code .. ":" .. value; state.held[code] = value == 1 or nil; return true
		end })
		injector._set_nanosleep_for_test(function(seconds) if seconds == .03 then transition("settle") end end)
		local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local source = file:read("*a"); assert(file:close())
		local first = assert(source:find("\t\t\tapply_prediction = function(", 1, true))
		local last = assert(source:find("\n\t\t\tend,", first, true))
		local expression = source:sub(first + #"\t\t\tapply_prediction = ", last + #"\n\t\t\tend" - 1)
		local compile = loadstring or load
		local apply = assert(compile("return function(injector, secure_focus_guard) return " .. expression .. " end"))()(injector, guard)
		local scheduler = require("tests.fakes").timer_scheduler()
		engine.init({ scheduler = scheduler, clock_ms = function() return scheduler.now * 1000 end,
			engine = { current_buffer = function() return "btw" end, reset = function() state.resets = state.resets + 1 end },
			is_paused = function() return state.paused end,
			focus_id = function() local target = guard.focused_text_identity(); transition("focus"); return target end,
			privacy_guard = function() local blocked = guard.blocks_text(); transition("privacy"); return blocked end,
			privacy_context = guard.current_context,
			apply_prediction = apply,
			on_output = function()
				state.output = state.output + 1
				state.output_resets, state.output_candidate = state.resets, engine.get_suggestions()[1]
				transition("output-observer")
			end,
		})
		assert(guard.prime())
		state.text = phase == "native" and " ok ok ok ok ok ok" or " ok ok ok ok ok ☃"
		function state.offer()
			local before = #state.requests
			engine.predict("btw", nil, { num_predictions = 1, profile = { id = "raw", system_single = "{context}" } })
			-- A successor observes the real canonical provider pacing; advance only
			-- this controlled scheduler, never a native/privacy deadline.
			scheduler.test.advance(require("modules.llm.inference").min_interval_ms("api") / 1000)
			assert(#state.requests == before + 1, "the real Engine dispatches one controlled provider request")
			state.requests[#state.requests](state.text, nil)
			assert(engine.has_suggestions(), "the real parser admits the six-word response")
		end
		state.offer(); state.armed = true
		local accepted = engine.accept(1, function(committed) state.completed = committed end)
		helpers.assert_eq(state.held, {}, "the exact original native key cleanup is balanced")
		body(accepted, state, engine, guard)
	end)
	if injector then injector._set_uinput(nil); injector._set_nanosleep_for_test(nil) end
	if guard then guard.stop() end
	if engine then engine.shutdown_runtime() end
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not ok then error(detail, 0) end
end

helpers.describe("AI continuation retains its injection authority", function()
	for _, route in ipairs({ "native", "clipboard" }) do
		helpers.it("commits the original current " .. route .. " prediction", function()
			scenario("stable", route, function(accepted, state)
				helpers.assert_true(accepted and state.completed)
				helpers.assert_eq(state.output, 1)
				helpers.assert_eq(state.stopped, 0)
				helpers.assert_eq(state.errors, {})
				if route == "clipboard" then
					helpers.assert_eq(table.concat(state.rows, " "), "29:1 47:1 47:0 29:0")
					helpers.assert_eq(state.writes, { " ok ok ok ok ok ☃", "SAVED" })
				else
					local expected = {}; for _ = 1, 6 do expected[#expected + 1] = "57:1 57:0 24:1 24:0 37:1 37:0" end
					helpers.assert_eq(table.concat(state.rows, " "), table.concat(expected, " "))
					helpers.assert_eq(state.writes, {})
				end
			end)
		end)
	end
	for _, action in ipairs({ "field", "password" }) do
		helpers.it("refuses a " .. action .. " changed during clipboard settle", function()
			scenario(action, "settle", function(accepted, state)
				helpers.assert_true(state.triggered)
				helpers.assert_eq(accepted, false); helpers.assert_eq(state.completed, false)
				helpers.assert_eq(state.rows, {})
				helpers.assert_eq(state.writes, { " ok ok ok ok ok ☃", "SAVED" })
				helpers.assert_eq(state.output, 0); helpers.assert_eq(state.stopped, 0)
			end)
		end)
	end
	helpers.it("acknowledges committed output without dismissing or resetting its observer's successor", function()
		scenario("successor", "output-observer", function(accepted, state, engine)
			helpers.assert_true(state.triggered)
			helpers.assert_true(accepted and state.completed, "the original physical edit remains acknowledged")
			helpers.assert_eq(table.concat(state.rows, " "), "29:1 47:1 47:0 29:0")
			helpers.assert_eq(state.writes, { " ok ok ok ok ok ☃", "SAVED" })
			helpers.assert_eq(state.output, 1)
			helpers.assert_eq(state.stopped, 0)
			helpers.assert_true(state.successor ~= nil)
			helpers.assert_true(rawequal(engine.get_suggestions()[1], state.successor), "the committed predecessor cannot dismiss the observer's new offer")
			helpers.assert_eq(state.resets, state.successor_resets, "no reset follows publication of the successor")
		end)
	end)
	helpers.it("acknowledges output but preserves the offer when its observer pauses without advancing the request", function()
		scenario("pause", "output-observer", function(accepted, state, engine)
			helpers.assert_true(state.triggered and state.paused)
			helpers.assert_true(accepted and state.completed, "the completed physical edit remains acknowledged")
			helpers.assert_eq(table.concat(state.rows, " "), "29:1 47:1 47:0 29:0")
			helpers.assert_eq(state.writes, { " ok ok ok ok ok ☃", "SAVED" })
			helpers.assert_eq(state.output, 1)
			helpers.assert_eq(state.stopped, 0)
			helpers.assert_true(engine.has_suggestions(), "paused continuation authority cannot retire the existing offer")
			helpers.assert_true(rawequal(engine.get_suggestions()[1], state.output_candidate), "the original offer identity remains current")
			helpers.assert_eq(state.resets, state.output_resets, "no buffer reset follows the observer's pause")
		end)
	end)
	for _, phase in ipairs({ "privacy", "focus", "read", "write", "settle", "lookup" }) do
		for _, action in ipairs({ "cancel", "pause", "shutdown", "successor" }) do
			helpers.it("retires " .. action .. " at " .. phase .. " without output or successor cleanup", function()
				scenario(action, phase, function(accepted, state, engine)
					helpers.assert_true(state.triggered)
					helpers.assert_eq(accepted, false); helpers.assert_eq(state.completed, false)
					helpers.assert_eq(state.rows, {})
					helpers.assert_eq(state.output, 0); helpers.assert_eq(state.stopped, 0)
					if action == "successor" then
						helpers.assert_true(state.successor ~= nil)
						helpers.assert_true(rawequal(engine.get_suggestions()[1], state.successor), "the old acceptance cannot dismiss the new offer")
					end
				end)
			end)
		end
	end
end)
