--- tests/unit/modules/llm/prediction/test_prediction_control_retirement.lua

--- ==============================================================================
--- MODULE: Prediction Retirement On Forwarded Document Controls
--- DESCRIPTION:
--- Executes Main's real input, consumption and acceptance callbacks with the
--- shared matcher, AI engine and focus guard. The receiving document/caret is
--- independent of the matcher's buffer; only desktop, scheduler and transport
--- ports are controlled. No native keyboard or window is claimed here.
--- ==============================================================================
local helpers = require("tests.helpers")

--- Compiles actual Main callbacks, including its control-policy declarations.
--- @param environment table Existing callback dependencies.
--- @return table callbacks
local function main_callbacks(environment)
	local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
	local source = assert(file:read("*a")); assert(file:close())
	local function section(first_marker, last_marker)
		local first = assert(source:find(first_marker, 1, true))
		local last = assert(source:find(last_marker, first, true))
		return source:sub(first, last - 1)
	end
	local text = "local _undoable; local _last_offered; local physical_privacy_admission; local capture_owned_scancodes={}; local on_char;\n"
		.. section("\tlocal function handle_char(", "\n\ton_char = input_capture_gate.guard(handle_char)")
		.. section("\tlocal function handle_physical(", "\n\tlocal on_physical = input_capture_gate.guard(handle_physical,")
		.. section("\t-- 8.7) Define the control-key callback.", "\n\tlocal on_control = input_capture_gate.guard(handle_control)")
		.. section("\tlocal on_consume = input_capture_gate.guard(function(detail)", "\n\t-- Bind the same privacy owner")
		.. "\non_char=handle_char;return {char=handle_char,physical=handle_physical,control=handle_control,consume=on_consume}"
	local first = assert(source:find("\t\t\tapply_prediction = function(", 1, true))
	local last = assert(source:find("\n\t\t\tend,", first, true))
	local apply = source:sub(first + #"\t\t\tapply_prediction = ", last + #"\n\t\t\tend" - 1)
	local function compile(body)
		if loadstring then local chunk = assert(loadstring(body)); setfenv(chunk, environment); return chunk end
		return assert(load(body, "actual Main document-control callbacks", "t", environment))
	end
	local callbacks = compile(text)()
	callbacks.apply = compile("return " .. apply)()
	return callbacks
end

--- Gives each case a real stable native field and an independent document.
--- @param options table Optional count and hotstring word-reset policy.
--- @param body function Receives real engines, callbacks and observed wire state.
local function scenario(options, body)
	local journal = {}; for name, value in pairs(package.loaded) do journal[name] = value end
	local prediction, guard, injector
	local ok, failure = xpcall(function()
		for name in pairs(package.loaded) do
			if name:match("^modules%.llm%.") then package.loaded[name] = nil end
		end
		for _, name in ipairs({ "modules.keystats.focus_guard", "modules.keystats.keystats", "adapters.secure_field_detector",
			"modules.hotstrings.word_reset", "infra.hotstring_preferences", "adapters.keyboard_layout",
			"modules.hotstrings.injector", "adapters.clipboard" }) do package.loaded[name] = nil end
		local state = { text = "", caret = 0, wire = {}, held = {}, requests = {}, submissions = {},
			cancelled = 0, offers = {}, overlay_showing = false, controls = 0, moves = 0, outputs = 0 }
		local logger = assert(dofile(require("infra.paths").shared("lua/logger/init.lua")))
		logger.set_sink(function() end); package.loaded["logger.shim"] = logger
		local preferences = require("tests.support.llm_preferences_fixture").new({ initial = {
			["llm.models.selected"] = "api", ["llm.profiles.auto_profile_for_model"] = false,
			["llm.profiles.active"] = "basic", ["llm.profiles.num_predictions"] = options.count or 1,
			["llm.trigger.secure_filter_enabled"] = true, ["llm.trigger.debounce_ms"] = 500,
			["llm.trigger.instant_on_word_end"] = false, ["llm.trigger.after_hotstring"] = false,
			["llm.display.streaming"] = true, ["llm.display.streaming_multi"] = true,
		} })
		package.loaded["infra.llm_preferences"] = preferences
		package.loaded["modules.llm.profiles"] = { init = function() return true end, is_enabled = function() return true end }
		package.loaded["modules.llm.api_entries"] = { active = function()
			return { id = "owned", provider = "openai_compat", model = "fixture-model" }
		end }
		package.loaded["modules.llm.api_remote"] = {
			provider = function() return { default_model = "fixture-model" } end, serves = function() return true end,
			chat = function(_, _, messages, _, stream, done)
				state.submissions[#state.submissions + 1] = messages
				state.requests[#state.requests + 1] = { stream = stream, done = done }; return true
			end,
			cancel = function() state.cancelled = state.cancelled + 1; return true end,
		}
		prediction = require("modules.llm.prediction_engine")
		local policy = require("modules.keystats.keystats")
		local configuration = assert(policy.configuration_snapshot()); configuration.private_filter_enabled = false
		assert(policy.apply_configuration(configuration))
		local listener, snapshot
		local watch = { on_change = function(fn) listener = fn end, pump = function() end,
			barrier = function()
				snapshot = { bus = ":1.23", path = "/field/original", role = 61 }; listener(snapshot); return snapshot
			end, snapshot = function() return snapshot end,
			invalidate = function() snapshot = nil; listener(nil) end }
		local scheduler = require("tests.fakes").timer_scheduler()
		guard = require("modules.keystats.focus_guard").new({ watch = watch,
			detector = require("adapters.secure_field_detector"), keystats = policy, prediction = prediction,
			now_ms = function() return 1000 + scheduler.now * 1000 end,
			capture_context = function() return { app_id = "owned-editor", title = "owned-field", native_identity = "owned-window" } end,
			publish_context = function(context) return true, policy.is_context_protected(context.app_id, context.title) end,
		})
		package.loaded["infra.display_server"] = { is_x11 = function() return true end,
			is_wayland = function() return false end, kind = function() return "x11" end }
		package.loaded["adapters.keyboard_hook"] = { held_text_modifier_codes = function() return {} end,
			held_shortcut_modifier_codes = function() return {} end, held_forwarded_keys = function() return {} end,
			emergency_stop = function() state.stopped = true end }
		local layout = require("adapters.keyboard_layout")
		layout._set_table_for_test({ o = { keycode = 24, mods = {} }, k = { keycode = 37, mods = {} },
			a = { keycode = 30, mods = {} }, b = { keycode = 48, mods = {} }, [" "] = { keycode = 57, mods = {} } })
		local characters = { [24] = "o", [37] = "k", [30] = "a", [48] = "b", [57] = " " }
		local function edit(deletes, text)
			local start = math.max(0, state.caret - deletes)
			state.text = state.text:sub(1, start) .. text .. state.text:sub(state.caret + 1)
			state.caret = start + #text
		end
		injector = require("modules.hotstrings.injector")
		injector._set_uinput({ is_open = function() return true end, emit = function(code, value)
			state.wire[#state.wire + 1] = { code = code, value = value, caret = state.caret }
			state.held[code] = value == 1 or nil
			if value == 1 then
				if code == 14 then edit(1, "") elseif characters[code] then edit(0, characters[code]) end
			end
			return true
		end })
		injector._set_nanosleep_for_test(function() end)
		local matcher = require("modules.hotstrings.engine").new()
		local WordReset = require("modules.hotstrings.word_reset")
		local settings = WordReset.snapshot(); settings.idle_seconds = 0
		settings.arrow_resets_word = options.arrow_resets_word ~= false
		assert(WordReset.restore_configuration(settings)); WordReset.forget_last_key()
		local gate = require("infra.input_capture_gate").new()
		local environment = setmetatable({ engine = matcher, engine_mod = require("modules.hotstrings.engine"),
			prediction_engine = prediction, injector = injector, secure_focus_guard = guard,
			script_actions = require("modules.shortcuts.script_actions").new({ reset = function() end,
				reload = function() end, quit = function() end }),
			keystats = policy, WordReset = WordReset, InputEvent = require("infra.input_event"),
			Monotonic = { now_ms = function() return 1000 + scheduler.now * 1000 end }, _cached_app_id = "owned-editor",
			terminators_mod = { is_terminator = function() return false end },
			-- Main sizes the expansion delay from the physically held modifiers.
			keyboard_hook = { held_modifiers = function() return {} end },
			RepeatKey = { is_enabled = function() return false end }, opts = { dry_run = false }, Logger = logger,
			input_capture_gate = gate, MagicKeySource = { on_key = function() return false end },
			script_chords = { on_key = function() return false end }, tap_keys = { on_key = function() return false end },
			wrap_on_type = { on_key = function() return false end }, consume_bound_chord = function() return false end,
			keyboard_shortcuts = { chord_name = function() return nil end, dispatch = function() return false end },
		}, { __index = _G })
		local callbacks = main_callbacks(environment)
		local overlay = { show = function(rows)
			state.offers = rows; state.overlay_showing = #rows > 0; return true
		end, hide = function() state.offers = {}; state.overlay_showing = false end,
			is_showing = function() return state.overlay_showing end,
			move = function(delta) state.moves = state.moves + delta; return true end,
			active_index = function() return 1 end }
		prediction.init({ engine = matcher, scheduler = scheduler, clock_ms = function() return scheduler.now * 1000 end,
			is_paused = environment.script_actions.is_paused, focus_id = guard.focused_text_identity,
			privacy_guard = guard.blocks_text, privacy_context = guard.current_context,
			overlay = overlay, apply_prediction = callbacks.apply, on_output = function() state.outputs = state.outputs + 1 end })
		assert(guard.prime())
		local target = assert(guard.focused_text_identity())
		function state.type(text)
			for char in text:gmatch(".") do
				callbacks.physical(30, "a", char, 1); edit(0, char); callbacks.char(char, 30)
			end
		end
		function state.control(name, code, mods)
			callbacks.physical(code, name, nil, 1)
			if callbacks.consume({ code = code, key = name, mods = mods or {} }) == true then return true end
			if name == "home" or name == "pageup" or name == "up" then state.caret = 0
			elseif name == "end" or name == "pagedown" or name == "down" then state.caret = #state.text
			elseif name == "left" then state.caret = math.max(0, state.caret - 1)
			elseif name == "right" then state.caret = math.min(#state.text, state.caret + 1)
			elseif name == "backspace" then edit(1, "")
			elseif name == "delete" then state.text = state.text:sub(1, state.caret) .. state.text:sub(state.caret + 2) end
			state.controls = state.controls + 1; callbacks.control(name, { mods = mods or {} })
			return false
		end
		function state.respond(index, text)
			local request = assert(state.requests[index], "the real prediction engine must dispatch before completion")
			if request.stream then request.stream(text) end
			request.done(text, nil)
		end
		state.matcher, state.prediction, state.scheduler, state.callbacks = matcher, prediction, scheduler, callbacks
		body(state)
		helpers.assert_eq(guard.focused_text_identity(), target, "the same original field identity survives every caret edit")
		helpers.assert_eq(state.held, {}, "all controlled native key DOWNs receive cleanup UPs")
		helpers.assert_eq(state.stopped, nil, "context retirement does not stop a healthy input channel")
	end, debug.traceback)
	if injector then injector._set_uinput(nil); injector._set_nanosleep_for_test(nil) end
	if guard then guard.stop() end
	if prediction then prediction.shutdown_runtime() end
	for name in pairs(package.loaded) do if journal[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(journal) do package.loaded[name] = value end
	if not ok then error(failure, 0) end
end

local RESPONSE = " ok ok ok ok ok ok"

helpers.describe("Main retires AI at forwarded document controls", function()
	helpers.it("does not submit the pre-Home context after debounce", function()
		scenario({}, function(s)
			s.type("hello"); helpers.assert_eq(s.matcher:current_buffer(), "hello")
			helpers.assert_eq(s.control("home", 102), false)
			helpers.assert_eq(s.matcher:current_buffer(), "")
			s.scheduler.test.advance(.5)
			if #s.requests > 0 then s.respond(1, RESPONSE) end
			local accepted = s.prediction.accept(1)
			helpers.assert_eq(#s.requests, 0, "obsolete debounce submitted; accepted=" .. tostring(accepted) .. ", document=" .. s.text)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(s.text, "hello"); helpers.assert_eq(s.caret, 0)
		end)
	end)

	for _, control in ipairs({ { "home", 102 }, { "end", 107 }, { "pageup", 104 }, { "pagedown", 109 },
		{ "left", 105 }, { "right", 106 }, { "up", 103 }, { "down", 108 }, { "delete", 111 },
		{ "insert", 110 }, { "enter", 28, { ctrl = true } }, { "escape", 1 }, { "backspace", 14 } }) do
		helpers.it("rejects late streaming, completion and acceptance after " .. control[1], function()
			scenario({}, function(s)
				s.type("hello"); s.scheduler.test.advance(.5)
				helpers.assert_eq(#s.requests, 1)
				helpers.assert_eq(s.control(control[1], control[2], control[3]), false)
				local document, caret = s.text, s.caret
				s.respond(1, RESPONSE)
				local offered, visible = s.prediction.has_suggestions(), s.overlay_showing
				local accepted = s.prediction.accept(1)
				helpers.assert_eq(offered, false, "late offer remained; accepted=" .. tostring(accepted) .. ", document=" .. s.text)
				helpers.assert_eq(visible, false); helpers.assert_eq(accepted, false)
				helpers.assert_eq({ s.text, s.caret }, { document, caret }); helpers.assert_eq(s.outputs, 0)
			end)
		end)
	end

	helpers.it("withdraws an already visible prediction before Home can relocate acceptance", function()
		scenario({}, function(s)
			s.type("hello"); s.scheduler.test.advance(.5); s.respond(1, RESPONSE)
			helpers.assert_true(s.prediction.has_suggestions() and s.overlay_showing)
			s.control("home", 102)
			local offered = s.prediction.has_suggestions(); local accepted = s.prediction.accept(1)
			helpers.assert_eq(offered, false, "Home kept an obsolete visible offer; accepted=" .. tostring(accepted))
			helpers.assert_eq(accepted, false); helpers.assert_eq(s.text, "hello"); helpers.assert_eq(s.caret, 0)
		end)
	end)

	helpers.it("retires a forwarded arrow even when hotstring word reset is off", function()
		scenario({ arrow_resets_word = false }, function(s)
			s.type("hello"); s.scheduler.test.advance(.5); s.control("left", 105)
			helpers.assert_eq(s.matcher:current_buffer(), "hello", "the hotstring preference keeps its original meaning")
			s.respond(1, RESPONSE)
			helpers.assert_eq(s.prediction.has_suggestions(), false)
			helpers.assert_eq(s.prediction.accept(1), false); helpers.assert_eq({ s.text, s.caret }, { "hello", 4 })
		end)
	end)

	for _, control in ipairs({ { "f1", 59 }, { "f12", 88 }, { "shortcut", 31, { ctrl = true } } }) do
		helpers.it("preserves an unchanged document's offer through " .. control[1], function()
			scenario({}, function(s)
				s.type("hello"); s.scheduler.test.advance(.5); s.control(control[1], control[2], control[3])
				s.respond(1, RESPONSE)
				helpers.assert_true(s.prediction.has_suggestions())
				helpers.assert_true(s.prediction.accept(1)); helpers.assert_eq(s.text, "hello" .. RESPONSE)
			end)
		end)
	end

	helpers.it("does not retire an offer for physical modifiers or locks", function()
		scenario({}, function(s)
			s.type("hello"); s.scheduler.test.advance(.5)
			-- The actual hook returns before semantic control dispatch for these keys.
			for _, code in ipairs({ 42, 29, 58 }) do s.callbacks.physical(code, "modifier", nil, 1) end
			s.respond(1, RESPONSE)
			helpers.assert_true(s.prediction.has_suggestions()); helpers.assert_true(s.prediction.accept(1))
			helpers.assert_eq(s.text, "hello" .. RESPONSE)
		end)
	end)

	helpers.it("keeps a genuinely consumed tooltip arrow out of the document-control handler", function()
		scenario({ count = 2 }, function(s)
			s.type("hello"); s.scheduler.test.advance(.5); s.respond(1, RESPONSE)
			s.scheduler.test.advance(1); s.respond(2, " ko ko ko ko ko ko")
			helpers.assert_eq(#s.prediction.get_suggestions(), 2)
			helpers.assert_true(s.control("left", 105))
			helpers.assert_eq({ s.controls, s.moves, s.caret, s.text }, { 0, -1, 5, "hello" })
			helpers.assert_eq(#s.prediction.get_suggestions(), 2)
		end)
	end)

	helpers.it("lets the actual consumed validation chord commit the current offer", function()
		scenario({}, function(s)
			s.type("hello"); s.scheduler.test.advance(.5); s.respond(1, RESPONSE)
			helpers.assert_true(s.control("1", 2))
			helpers.assert_eq(s.controls, 0); helpers.assert_eq(s.text, "hello" .. RESPONSE)
			helpers.assert_eq(s.outputs, 1); helpers.assert_eq(s.prediction.has_suggestions(), false)
		end)
	end)

	helpers.it("retires replacement-context work before the hotstring Undo early return", function()
		scenario({}, function(s)
			helpers.assert_true(s.matcher:load_mappings({ { trigger = "ab", replacement = "ok", auto_expand = true } }))
			s.type("ab"); helpers.assert_eq(s.text, "ok")
			s.scheduler.test.advance(.5); helpers.assert_eq(#s.requests, 1)
			s.control("backspace", 14); helpers.assert_eq(s.text, "ab")
			s.respond(1, RESPONSE)
			helpers.assert_eq(s.prediction.has_suggestions(), false)
			helpers.assert_eq(s.prediction.accept(1), false); helpers.assert_eq(s.text, "ab")
		end)
	end)
end)
