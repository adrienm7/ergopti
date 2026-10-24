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
			if state.selection then
				local first, last = state.selection[1], state.selection[2]
				state.text = state.text:sub(1, first) .. text .. state.text:sub(last + 1)
				state.caret, state.selection = first + #text, nil
				return
			end
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
		if options.shortcut_resets_word ~= nil then settings.shortcut_resets_word = options.shortcut_resets_word end
		assert(WordReset.restore_configuration(settings)); WordReset.forget_last_key()
		local gate = require("infra.input_capture_gate").new()
		local keyboard_identity = require("modules.shortcuts.keyboard_shortcuts").collision_identity
		local environment = setmetatable({ engine = matcher, engine_mod = require("modules.hotstrings.engine"),
			prediction_engine = prediction, injector = injector, secure_focus_guard = guard,
			shortcuts = options.restart_prediction and { is_enabled = function() return true end,
				is_caps_word_active = function() return false end } or nil,
			script_actions = require("modules.shortcuts.script_actions").new({ reset = function() end,
				reload = function() end, quit = function() end }),
			keystats = policy, WordReset = WordReset, InputEvent = require("infra.input_event"),
			Monotonic = { now_ms = function() return 1000 + scheduler.now * 1000 end }, _cached_app_id = "owned-editor",
			terminators_mod = { is_terminator = function() return false end },
			RepeatKey = { is_enabled = function() return false end }, opts = { dry_run = false }, Logger = logger,
			input_capture_gate = gate, MagicKeySource = { on_key = function() return false end },
			script_chords = { on_key = function() return false end }, tap_keys = { on_key = function() return false end },
			wrap_on_type = { on_key = function() return false end }, consume_bound_chord = function() return false end,
			keyboard_shortcuts = { collision_identity = keyboard_identity, chord_name = function() return nil end,
				dispatch = function()
					if options.restart_prediction then return prediction.trigger_now() end
					return false
				end },
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
		function state.shortcut(vector)
			local original_hook = package.loaded["adapters.keyboard_hook"]
			local hook = helpers.load_module("adapters.keyboard_hook")
			local events, modifiers, raw_held = {}, {}, {}
			for _, pair in ipairs({ { "ctrl", 29 }, { "shift", 42 }, { "alt", 56 }, { "meta", 125 }, { "altgr", 100 } }) do
				if vector.mods[pair[1]] then modifiers[#modifiers + 1] = pair[2] end
			end
			local function event(code, value) events[#events + 1] = { type = 1, code = code, value = value } end
			for _, code in ipairs(modifiers) do event(code, 1) end
			event(vector.code, 1); event(vector.code, 0)
			for index = #modifiers, 1, -1 do event(modifiers[index], 0) end
			local forwarded, semantic, chars = false, nil, 0
			local driven, problem = pcall(hook._test_drive, events, {
				onPhysical = callbacks.physical, onConsume = callbacks.consume,
				captureEvent = function(code, value)
					if code ~= vector.code or value == 0 then return nil, nil, nil end
					local identity = vector.mods.shift and vector.key:upper() or vector.key
					return identity, identity, nil
				end,
				onChar = function() chars = chars + 1 end,
				onEmitRaw = function(code, value)
					raw_held[code] = value == 1 or nil
					if code == vector.code and value == 1 then
						forwarded = true
						if vector.effect == "paste" then edit(0, "PASTED")
						elseif vector.effect == "cut" then state.selection = { 3, 5 }; edit(0, "")
						elseif vector.effect == "undo" then state.text, state.caret = "hell", 4
						elseif vector.effect == "redo" then state.text, state.caret = "hello!", 6
						elseif vector.effect == "select" then state.selection = { 0, #state.text }; state.caret = #state.text end
					end
					return true
				end,
				onKey = function(name, detail)
					helpers.assert_true(forwarded, "the receiver edits before the actual semantic callback")
					semantic = { name = name, detail = detail }
					state.controls = state.controls + 1
					callbacks.control(name, detail)
				end,
			}, true)
			package.loaded["adapters.keyboard_hook"] = original_hook
			if not driven then error(problem, 0) end
			helpers.assert_true(forwarded, "the actual Hook must forward the unbound editing chord")
			helpers.assert_eq(raw_held, {}, "all physical forwarded modifiers and keys must be released")
			helpers.assert_eq(chars, 0, "pasted or undone text must not become invented on_char input")
			helpers.assert_true(semantic ~= nil)
			helpers.assert_eq(semantic.name, "shortcut")
			helpers.assert_eq(semantic.detail.key, vector.mods.shift and vector.key:upper() or vector.key)
			helpers.assert_eq(semantic.detail.mods, vector.mods, "Main receives the actual named modifier map")
			return { state.text, state.caret, state.selection }
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

helpers.describe("Main retires AI at forwarded standard editing chords", function()
	local vectors = {
		{ label = "Ctrl+V", key = "v", code = 47, mods = { ctrl = true }, effect = "paste" },
		{ label = "Ctrl+Shift+V", key = "v", code = 47, mods = { ctrl = true, shift = true }, effect = "paste" },
		{ label = "Ctrl+X", key = "x", code = 45, mods = { ctrl = true }, effect = "cut" },
		{ label = "Ctrl+Z", key = "z", code = 44, mods = { ctrl = true }, effect = "undo" },
		{ label = "Ctrl+Shift+Z", key = "z", code = 44, mods = { ctrl = true, shift = true }, effect = "redo" },
		{ label = "Ctrl+Y", key = "y", code = 21, mods = { ctrl = true }, effect = "redo" },
		{ label = "Ctrl+A", key = "a", code = 30, mods = { ctrl = true }, effect = "select" },
	}
	for _, vector in ipairs(vectors) do
		for _, phase in ipairs({ "debounce", "late", "visible" }) do
			helpers.it("editing-chord-owner retires " .. phase .. " through " .. vector.label, function()
				scenario({}, function(s)
					s.type("hello")
					if phase ~= "debounce" then s.scheduler.test.advance(.5); helpers.assert_eq(#s.requests, 1) end
					if phase == "visible" then
						s.respond(1, RESPONSE)
						helpers.assert_true(s.prediction.has_suggestions() and s.overlay_showing)
					end
					local received = s.shortcut(vector)
					local expected = vector.effect == "paste" and { "helloPASTED", 11 }
						or vector.effect == "cut" and { "hel", 3 }
						or vector.effect == "undo" and { "hell", 4 }
						or vector.effect == "redo" and { "hello!", 6 } or { "hello", 5, { 0, 5 } }
					helpers.assert_eq(received, expected, "the forwarded chord must actually edit the independent receiver")
					if phase == "debounce" then s.scheduler.test.advance(.5) end
					if phase ~= "visible" and #s.requests > 0 then s.respond(1, RESPONSE) end
					local offered, visible = s.prediction.has_suggestions(), s.overlay_showing
					local accepted = s.prediction.accept(1)
					if phase == "debounce" then helpers.assert_eq(#s.requests, 0, "editing must retire the original pending prompt") end
					helpers.assert_eq(offered, false, "a standard edit cannot retain its old AI offer; accepted=" .. tostring(accepted))
					helpers.assert_eq(visible, false); helpers.assert_eq(accepted, false)
					helpers.assert_eq({ s.text, s.caret, s.selection }, received, "obsolete acceptance must not mutate the independently edited document")
					helpers.assert_eq(s.outputs, 0)
				end)
			end)
		end
	end

	helpers.it("editing-chord-owner retires paste even when shortcut word reset is off", function()
		scenario({ shortcut_resets_word = false }, function(s)
			s.type("hello"); s.scheduler.test.advance(.5)
			local received = s.shortcut(vectors[1])
			helpers.assert_eq(s.matcher:current_buffer(), "hello", "the matcher preference remains independent of AI caret retirement")
			s.respond(1, RESPONSE)
			helpers.assert_eq(s.prediction.has_suggestions(), false)
			helpers.assert_eq(s.prediction.accept(1), false)
			helpers.assert_eq({ s.text, s.caret, s.selection }, received)
		end)
	end)

	for _, vector in ipairs({
		{ label = "Ctrl+C", key = "c", code = 46, mods = { ctrl = true } },
		{ label = "Ctrl+S", key = "s", code = 31, mods = { ctrl = true } },
		{ label = "Ctrl+Alt+V", key = "v", code = 47, mods = { ctrl = true, alt = true } },
		{ label = "Ctrl+Meta+V", key = "v", code = 47, mods = { ctrl = true, meta = true } },
		{ label = "Ctrl+AltGr+V", key = "v", code = 47, mods = { ctrl = true, altgr = true } },
	}) do
		helpers.it("editing-chord-owner preserves unclassified " .. vector.label, function()
			scenario({}, function(s)
				s.type("hello"); s.scheduler.test.advance(.5)
				s.shortcut(vector); s.respond(1, RESPONSE)
				helpers.assert_true(s.prediction.has_suggestions())
				helpers.assert_true(s.prediction.accept(1)); helpers.assert_eq(s.text, "hello" .. RESPONSE)
			end)
		end)
	end

	helpers.it("editing-chord-owner retires before the dispatch port starts a successor request", function()
		scenario({ restart_prediction = true }, function(s)
			s.type("hello"); s.scheduler.test.advance(.5)
			s.shortcut(vectors[1])
			s.respond(1, RESPONSE); helpers.assert_eq(s.prediction.has_suggestions(), false)
			-- The actual rate limiter delays a same-tick successor; it must survive
			-- the remaining control callback before its transport is dispatched.
			s.scheduler.test.advance(1)
			helpers.assert_eq(#s.requests, 2, "the bound action must actually start its new request")
			s.respond(2, RESPONSE); helpers.assert_true(s.prediction.has_suggestions(), "the later action's own request must survive")
		end)
	end)
end)


-- Whole-Main regression fixture: configuration/desktop/input/transport ports are
-- controlled. Main is loaded intact and initializes the actual AI/focus owners.
do
	local shared_engine = require("hotstring_engine")
	local shared_new = shared_engine.new

	local function whole_main(options, body)
		local journal, path_before = {}, package.path
		for name, value in pairs(package.loaded) do journal[name] = value end
		local marker = assert(os.tmpname())
		local owned_paths = { [marker] = true }
		local fixture_state, fixture_prediction
		local ok, failure = xpcall(function()
			for name in pairs(package.loaded) do
				if name:match("^modules%.llm%.") or name:match("^modules%.keystats%.")
					or name:match("^modules%.hotstrings%.") or name:match("^modules%.shortcuts%.") then package.loaded[name] = nil end
			end
			for _, name in ipairs({ "adapters.keyboard_hook", "adapters.evdev_reader", "adapters.modifier_broker",
				"adapters.keyboard_layout", "adapters.secure_field_detector", "adapters.clipboard", "adapters.timer_scheduler",
				"infra.hotstring_preferences", "infra.llm_preferences", "infra.metrics_preferences", "infra.monotonic",
				"infra.config_paths", "config_migrate", "toml_codec.writer" }) do package.loaded[name] = nil end
			local root, key, phase, modifier = helpers.driver_root(), options.key or "u", options.phase or "late", options.modifier or "ctrl"
			local app = options.app or "gnome-terminal"
			local action_mode = options.mode or "none"
			local terminal = app == "gnome-terminal"
			local role = terminal and 60 or 61
			package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. root .. "/../_shared/lua/?.lua;" .. root .. "/../_shared/lua/?/init.lua;" .. package.path
			require("compat.utf8").install()
			local Json = require("json")
			local state = { requests = {}, cancellations = 0, text = "", caret = 0, output = 0, overlays = {}, chars = 0, controls = 0, forwarded = 0, read_frame = 1 }
			fixture_state = state
			local function noop() end
			local function yes() return true end
			local function no() return false end
			local function put(name, module) package.loaded[name] = module; return module end
			put("infra.config_paths", { config = function(name)
			  local file = marker .. "." .. name; owned_paths[file] = true; return file
			end, get_config_dir = function() return marker .. ".config-dir" end })
			put("adapters.storage", require("tests.fakes").storage())
			local scheduler = require("tests.fakes").timer_scheduler()
			put("adapters.timer_scheduler", scheduler)
			put("infra.monotonic", { now_ms = function() return 1000 + scheduler.now * 1000 end, resolution_ms = function() return .001 end })
			local logger = assert(dofile(root .. "/../_shared/lua/logger/init.lua")); logger.set_sink(function(line) state.last_log = tostring(line) end)
			put("logger.shim", logger)
			put("infra.logger_sink", { install = yes })
			put("infra.session_lock", { protect = yes, acquire = yes })
			put("infra.script_settings", { apply = yes, current = function() return "ERROR" end })
			put("infra.boot_profiler", { begin = noop, stage = noop, stage_done = noop, complete = function() return 0 end })
			put("infra.diagnostic_snapshot", { pid = function() return "controlled" end, prepare = function() return noop end })
			put("modules.diagnostics.crash_reporter", { protect = function(_, body)
			  local ok, result = xpcall(body, debug.traceback)
			  if not ok then io.stderr:write("MAIN_SETUP_FAILURE " .. tostring(result) .. "\n") end
			  return ok, result
			end })
			put("infra.input_access", { is_denied = no, report = function() error("unexpected input access") end })
			put("infra.signal_handlers", { start = yes, stop = yes, is_settled = yes })
			put("infra.restart_pause", { restore = yes })
			put("infra.legacy_hotstring_storage", { import = yes })
			local config = { init = noop, set_magic_key = yes, load_all = function() return 0, true, nil, { complete = true } end,
			  parse_error_count = function() return 0 end, get_categories = function() return {} end }
			put("modules.hotstrings.hotstrings_config", config)
			put("platform.remap.tap_hold_manager", { init = noop, user_path = function() return marker .. ".tap_hold.toml" end,
			  reload = yes, is_tap_action = no, canonical_hold = function() return "none" end, is_active = no, keys = function() return {} end, set_paused = yes })
			put("platform.remap.tap_hold_writer", { FILE_NAME = "tap_hold.toml", init = noop })
			-- Gesture/action sources have no configured bindings in this scope.
			put("modules.hotstrings.magic_key_source", { init = noop, on_key = no, cancel_capture = yes })
			put("modules.hotstrings.repeat_key", { is_enabled = no })
			put("modules.shortcuts.wrap_on_type", { new = function() return { on_key = no, end_selection_window = yes, on_pointer_down = noop } end })
			put("adapters.selection_transaction", { new = function() return { cancel = yes, stop = yes } end })
			put("adapters.clipboard", { read_primary = function() error("no selection read is permitted") end })
			put("infra.display_server", { is_x11 = yes, is_wayland = no, kind = function() return "x11" end })
			local layout = put("adapters.keyboard_layout", require("tests.support.layout_cohort_fixture").layout(function() return 30 end))
			layout.refresh, layout.is_ready, layout.publish_current_capture = yes, yes, yes
			local injector = put("modules.hotstrings.injector", {
			  _is_injecting = no, _queue_char = function() error("unexpected queued text") end,
			  open_fast_channel = yes, close_fast_channel = yes, output_broker = function() return {} end, emit_key = yes, set_output_observer = yes,
			  inject = function(deletes, text, _, _, publication)
			    assert(publication.current() and publication.cached(), "real Main must admit original field")
			    state.output = state.output + 1
			    local start = math.max(0, state.caret - deletes)
			    state.text = state.text:sub(1, start) .. text .. state.text:sub(state.caret + 1); state.caret = start + #text
			    return { ok = true }
			  end,
			})
			local preferences = require("tests.support.llm_preferences_fixture").new({ initial = {
			  ["llm.models.selected"] = "api", ["llm.profiles.auto_profile_for_model"] = false, ["llm.profiles.active"] = "basic",
			  ["llm.profiles.num_predictions"] = 1, ["llm.trigger.secure_filter_enabled"] = true,
			  ["llm.trigger.debounce_ms"] = 500, ["llm.trigger.instant_on_word_end"] = false,
			  ["llm.trigger.after_hotstring"] = false, ["llm.display.streaming"] = true, ["llm.display.streaming_multi"] = true,
			} })
			put("infra.llm_preferences", preferences)
			put("modules.llm.profiles", { init = yes, is_enabled = yes })
			put("modules.llm.api_entries", { active = function() return { id = "owned", provider = "openai_compat", model = "fixture-model" } end })
			put("modules.llm.api_remote", { serves = yes, provider = function() return { default_model = "fixture-model" } end,
			  chat = function(_, _, messages, _, stream, done) state.requests[#state.requests + 1] = { messages = messages, stream = stream, done = done }; return true end,
			  cancel = function() state.cancellations = state.cancellations + 1; return true end })
			local overlay = { show = function(rows, meta) state.overlays = rows; state.visible = #rows > 0; state.loading = meta and meta.loading; return true end,
			  hide = function() state.overlays = {}; state.visible = false; return true end, is_showing = function() return state.visible == true end,
			  move = yes, active_index = function() return 1 end }
			local policy = require("modules.keystats.keystats")
			-- Metrics persistence is outside this semantic audit; privacy policy methods remain real.
			for _, name in ipairs({ "init", "record_physical_key", "record_synthetic_output", "record_suggestion", "record_shortcut", "on_keydown", "on_hotstring", "record_correction", "cancel_hold_intervals" }) do policy[name] = noop end
			local watch = require("tests.support.focus_watch_fixture").new()
			local original_barrier, original_snapshot = watch.barrier, watch.snapshot
			watch.barrier = function() local receipt = original_barrier(); receipt.role = role; return receipt end
			watch.snapshot = function() local receipt = original_snapshot(); receipt.role = role; return receipt end
			put("adapters.atspi_focus_watch", { new = function() return watch end })
			local window = { getFocused = function() return { appId = app, windowTitle = "owned ordinary field" } end,
			  start_privacy_context = function(field, opts, callback)
			    assert(field.role == role and opts.authorized())
			    callback({ app_id = app, title = "owned ordinary field", native_identity = "owned-audit-frame" })
			    return { cancel = yes, is_settled = yes }
			  end }
			local focus_module = require("modules.keystats.focus_guard")
			local original_focus_new = focus_module.new
			focus_module.new = function(options) state.guard = original_focus_new(options); return state.guard end
			local engine_module = require("modules.hotstrings.engine")
			local original_engine_new = engine_module.new
			local main_engine = {}
			for name, value in pairs(engine_module) do main_engine[name] = value end
			main_engine.new = function(...) state.matcher = original_engine_new(...); return state.matcher end
			put("modules.hotstrings.engine", main_engine)
			local prediction = require("modules.llm.prediction_engine"); fixture_prediction = prediction
			local hook = require("adapters.keyboard_hook")
			hook.start = function(options) state.callbacks = options; coroutine.yield("actual Hook.start callback capture"); return true end
			hook.isRunning, hook.get_mode = yes, function() return "intercept" end
			local optional = { ["modules.llm.prediction_engine"] = prediction, ["ui.tooltip.llm"] = overlay,
			  ["adapters.window_info"] = window, ["adapters.secure_field_detector"] = require("adapters.secure_field_detector") }
			put("infra.runtime_guard", { optional_require = function(name) return optional[name] end,
			  call = function(_, callback) return true, callback() end })
			put("adapters.event_loop", { run = function() error("probe must remain before actual event-loop launch") end, stop = yes, defer = function(fn) state.deferred = state.deferred or {}; state.deferred[#state.deferred + 1] = fn; return true end })
			-- Selected keyboard bindings are absent; the classifier itself is the production module.
			local keyboard_shortcuts = require("modules.shortcuts.keyboard_shortcuts")
			local function start_successor(port)
			  state.action_entry = { port = port, old_offer = prediction.has_suggestions(), cancellations = state.cancellations,
			    predecessor_retired = phase == "visible" and not prediction.has_suggestions() or phase == "late" and state.cancellations > 0 }
			  state.action_started = prediction.trigger_now({ app_id = app })
			end
			keyboard_shortcuts.consume = function(detail, options)
			  if action_mode == "consumed" and detail.key == "u" then
			    state.bound_consumed = true; options.defer(function() start_successor("consumed deferred action") end); return true
			  end
			  return false
			end
			keyboard_shortcuts.dispatch = function(detail)
			  if action_mode == "dispatch" and detail.key == key then start_successor("forwarded Main dispatch"); return true end
			  return false
			end
			keyboard_shortcuts.init = noop
			local launch_args = { "--device", marker .. ".event-placeholder", "--config", marker .. ".config.toml" }
			local main = assert(loadfile(root .. "/ergopti_hotstrings.lua"))
			-- Migration/persistence is an explicit inert Main boundary; canonical writer imports stay real.
			local migration = require("config_migrate")
			local startup_migration = { REGISTRY_PATH = migration.REGISTRY_PATH, boot = function() return {} end,
			  read_only_notice_key = function() return nil end }
			local environment = setmetatable({ arg = launch_args, require = function(name)
			  if name == "config_migrate" then return startup_migration end
			  return require(name)
			end, os = setmetatable({ exit = function(code) error("controlled Main exit " .. tostring(code)) end }, { __index = os }) }, { __index = _G })
			if setfenv then setfenv(main, environment) else main = assert(loadfile(root .. "/ergopti_hotstrings.lua", "t", environment)) end
			state.thread = coroutine.create(main)
			local resumed, detail = coroutine.resume(state.thread)
			assert(resumed, tostring(detail))
			assert(state.callbacks and coroutine.status(state.thread) == "suspended", tostring(detail) .. " last log=" .. tostring(state.last_log))
			local guard = assert(state.guard)
			guard.refresh(true); guard.refresh(true)
			assert(guard.blocks_text() == false and guard.focused_text_identity(), "actual Main focus guard must admit this ordinary field")
			local original_focus = guard.focused_text_identity()
			assert(policy.is_context_protected(app, "owned ordinary field") == false)
			local WordReset = require("modules.hotstrings.word_reset")
			assert(WordReset.is_terminal_app(app) == terminal, "production classifier owns terminal scope")
			local settings = WordReset.snapshot(); settings.idle_seconds = 0; settings.shortcut_resets_word = options.reset == true
			assert(WordReset.restore_configuration(settings)); WordReset.forget_last_key()
			local callbacks = state.callbacks
			state.prediction, state.scheduler, state.guard = prediction, scheduler, guard
			state.original_focus, state.response = original_focus, " ok ok ok ok ok ok"
			function state.type(text)
				for char in text:gmatch(".") do
					callbacks.onPhysical(30, "a", char, 1)
					state.text = state.text:sub(1, state.caret) .. char .. state.text:sub(state.caret + 1)
					state.caret = state.caret + #char
					callbacks.onChar(char, 30)
				end
			end
			function state.prepare()
				if terminal and key == "n" then
					state.text = "owned latest history "; state.caret = #state.text
					state.history_saved_draft, state.history_selected = "hello world", true
					state.type("typed")
				else
					local before_suffix = terminal and (key == "k" or key == "e" or key == "f" or key == "d")
					if before_suffix then state.text = " world" end
					state.type(before_suffix and "hello" or "hello world")
				end
				if phase ~= "debounce" then scheduler.test.advance(.5); helpers.assert_eq(#state.requests, 1) end
				if phase == "visible" then state.requests[1].done(state.response, nil); helpers.assert_true(prediction.has_suggestions()) end
			end
			function state.control()
				local codes = { u = 22, h = 35, k = 37, w = 17, c = 46, s = 31, v = 47,
					b = 48, f = 33, e = 18, d = 32, t = 20, p = 25, n = 49, j = 36, m = 50 }
				local control_text = { p = string.char(16), n = string.char(14), j = "\n", m = "\r" }
				local code, modifiers = assert(codes[key]), { 29 }
				if modifier == "ctrl-alt" then modifiers[#modifiers + 1] = 56
				elseif modifier == "ctrl-meta" then modifiers[#modifiers + 1] = 125
				elseif modifier == "ctrl-altgr" then modifiers[#modifiers + 1] = 100
				elseif modifier == "ctrl-shift" then modifiers[#modifiers + 1] = 42 end
				local events, held = {}, {}
				local function event(c, value) events[#events + 1] = { type = 1, code = c, value = value } end
				for _, c in ipairs(modifiers) do event(c, 1) end
				event(code, 1); event(code, 0)
				for i = #modifiers, 1, -1 do event(modifiers[i], 0) end
				state.before_control = { text = state.text, caret = state.caret }
				hook._test_drive(events, {
					onPhysical = callbacks.onPhysical, onConsume = callbacks.onConsume,
					captureEvent = function(c, value) if c == code and value == 1 then return control_text[key] or key, key, nil end end,
					onChar = function() state.chars = state.chars + 1 end,
					onKey = function(name, detail)
						state.controls = state.controls + 1; state.semantic = { name = name, key = detail.key, mods = detail.mods }
						callbacks.onKey(name, detail)
					end,
					onEmitRaw = function(c, value)
						held[c] = value == 1 or nil
						if c == code and value == 1 then
							state.forwarded = state.forwarded + 1
							if modifier == "ctrl" then
								if terminal and key == "u" then state.text, state.caret = state.text:sub(state.caret + 1), 0
								elseif terminal and key == "h" then state.text = state.text:sub(1, state.caret - 1) .. state.text:sub(state.caret + 1); state.caret = state.caret - 1
								elseif terminal and key == "k" then state.text = state.text:sub(1, state.caret)
								elseif terminal and key == "w" then
									local start = state.text:sub(1, state.caret):match("^.*()%s%S*$") or 0
									state.text = state.text:sub(1, start) .. state.text:sub(state.caret + 1); state.caret = start
								elseif terminal and key == "b" then state.caret = state.caret - 1
								elseif terminal and key == "f" then state.caret = state.caret + 1
								elseif terminal and key == "e" then state.caret = #state.text
								elseif terminal and key == "d" then state.text = state.text:sub(1, state.caret) .. state.text:sub(state.caret + 2)
								elseif terminal and key == "t" then
									assert(state.caret == #state.text and state.caret >= 2, "the measured transpose case starts at the line end")
									state.text = state.text:sub(1, state.caret - 2) .. state.text:sub(state.caret, state.caret)
										.. state.text:sub(state.caret - 1, state.caret - 1) .. state.text:sub(state.caret + 1)
								elseif terminal and key == "p" then
									state.text = "owned latest history"; state.caret = #state.text; state.history_selected = true
								elseif terminal and key == "n" then
									assert(state.history_selected and state.history_saved_draft == "hello world")
									state.text = state.history_saved_draft; state.caret = #state.text; state.history_selected = false
								elseif terminal and (key == "j" or key == "m") then
									assert(state.read_frame == 1)
									state.submitted_line = state.text; state.text = ""; state.caret = 0; state.read_frame = 2
								elseif not terminal and key == "v" then state.text = state.text:sub(1, state.caret) .. "PASTED" .. state.text:sub(state.caret + 1); state.caret = state.caret + 6
								elseif not terminal and key == "c" then state.copy_observed = true
								elseif not terminal and key == "s" then state.saved_text = state.text end
							end
						end
						return true
					end,
				}, true)
				helpers.assert_eq(held, {}, "all controlled forwarded DOWNs have UPs")
				helpers.assert_eq(state.chars, 0, "Ctrl-letter edits are not invented character input")
				helpers.assert_eq(guard.focused_text_identity(), original_focus)
				helpers.assert_eq(guard.blocks_text(), false)
				state.after_control = { text = state.text, caret = state.caret }
			end
			body(state)
			helpers.assert_eq(guard.focused_text_identity(), original_focus, "no focus change may vacuously retire this case")
		end, debug.traceback)
		if fixture_prediction then pcall(fixture_prediction.cancel) end
		if fixture_state and fixture_state.guard then pcall(fixture_state.guard.stop) end
		for name in pairs(package.loaded) do if journal[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(journal) do package.loaded[name] = value end
		package.path = path_before
		local cleaned = true
		for file in pairs(owned_paths) do
			os.remove(file)
			local remaining = io.open(file, "rb")
			if remaining then remaining:close(); cleaned = false end
		end
		helpers.assert_true(shared_engine.new == shared_new, "a preloaded shared matcher constructor must remain unchanged")
		helpers.assert_true(cleaned, "every temporary file owned by this fixture must be removed")
		if not ok then error(failure, 0) end
	end

	local function finish_old(s, phase)
		if phase == "debounce" then s.scheduler.test.advance(.5) end
		if phase ~= "visible" and #s.requests > 0 then s.requests[1].done(s.response, nil) end
	end

	helpers.describe("whole Main retires Readline editing controls", function()
		local receiver = { u = { text = "", caret = 0 }, h = { text = "hello worl", caret = 10 },
			k = { text = "hello", caret = 5 }, w = { text = "hello ", caret = 6 } }
		for _, key in ipairs({ "u", "h", "k", "w" }) do
			for _, phase in ipairs({ "debounce", "late", "visible" }) do
				for _, reset in ipairs({ false, true }) do
					helpers.it("readline-control-retirement " .. key .. " " .. phase .. " reset=" .. tostring(reset), function()
						whole_main({ key = key, phase = phase, reset = reset }, function(s)
							s.prepare(); s.control()
							helpers.assert_eq(s.after_control, receiver[key], "independent receiver must match native Readline receipt")
							finish_old(s, phase)
							if phase == "debounce" then helpers.assert_eq(#s.requests, 0, "the pending old prompt must not dispatch") end
							helpers.assert_eq(s.prediction.has_suggestions(), false, "the edited document cannot retain its old offer")
							helpers.assert_eq(s.visible, false)
							helpers.assert_eq(s.prediction.accept(1), false)
							helpers.assert_eq({ text = s.text, caret = s.caret }, s.after_control)
							helpers.assert_eq(s.output, 0)
						end)
					end)
				end
			end
		end

		for _, specimen in ipairs({ { "c", "ctrl", "owned-gui-editor" }, { "s", "ctrl", "owned-gui-editor" },
			{ "u", "ctrl", "owned-gui-editor" }, { "u", "ctrl-alt", "gnome-terminal" },
			{ "u", "ctrl-meta", "gnome-terminal" }, { "u", "ctrl-altgr", "gnome-terminal" }, { "u", "ctrl-shift", "gnome-terminal" } }) do
			helpers.it("readline-control-scope " .. table.concat(specimen, " "), function()
				whole_main({ key = specimen[1], modifier = specimen[2], app = specimen[3] }, function(s)
					s.prepare(); s.control(); finish_old(s, "late")
					helpers.assert_eq(s.after_control, s.before_control)
					if specimen[1] == "c" then helpers.assert_true(s.copy_observed) end
					if specimen[1] == "s" then helpers.assert_eq(s.saved_text, s.before_control.text) end
					helpers.assert_true(s.prediction.has_suggestions())
					helpers.assert_true(s.prediction.accept(1))
				end)
			end)
		end

		helpers.it("readline-control whole-Main GUI paste still retires", function()
			whole_main({ key = "v", app = "owned-gui-editor" }, function(s)
				s.prepare(); s.control(); helpers.assert_eq(s.text, "hello worldPASTED")
				finish_old(s, "late"); helpers.assert_eq(s.prediction.has_suggestions(), false)
				helpers.assert_eq(s.prediction.accept(1), false); helpers.assert_eq(s.output, 0)
			end)
		end)

		for _, mode in ipairs({ "dispatch", "consumed" }) do
			for _, phase in ipairs({ "late", "visible" }) do
				for _, reset in ipairs({ false, true }) do
					helpers.it("readline-control-successor " .. mode .. " " .. phase .. " reset=" .. tostring(reset), function()
						whole_main({ key = "u", mode = mode, phase = phase, reset = reset }, function(s)
							s.prepare(); s.control()
							if mode == "consumed" then
								helpers.assert_eq(s.forwarded, 0); helpers.assert_eq(s.controls, 0)
								helpers.assert_eq(s.after_control, s.before_control)
								for _, fn in ipairs(s.deferred or {}) do fn() end
							else
								helpers.assert_eq(s.forwarded, 1); helpers.assert_eq(s.controls, 1)
								helpers.assert_true(s.action_entry.predecessor_retired, "retire before dispatch, never erase its successor afterwards")
							end
							helpers.assert_true(s.action_started)
							s.requests[1].done(s.response, nil); helpers.assert_eq(s.prediction.has_suggestions(), false)
							s.scheduler.test.advance(2); helpers.assert_eq(#s.requests, 2)
							s.requests[2].done(s.response, nil); helpers.assert_true(s.prediction.has_suggestions())
						end)
					end)
				end
			end
		end
	end)

	helpers.describe("whole Main retires Readline caret and text edits", function()
		-- The native marker receipt establishes these caret positions; X is not
		-- typed through Main or included in the independent receiving document.
		local receiver = { b = { text = "hello world", caret = 10 }, f = { text = "hello world", caret = 6 },
			e = { text = "hello world", caret = 11 }, d = { text = "helloworld", caret = 5 },
			t = { text = "hello wordl", caret = 11 } }
		for _, key in ipairs({ "b", "f", "e", "d", "t" }) do
			for _, phase in ipairs({ "debounce", "late", "visible" }) do
				for _, reset in ipairs({ false, true }) do
					helpers.it("readline-terminal-retirement " .. key .. " " .. phase .. " reset=" .. tostring(reset), function()
						whole_main({ key = key, phase = phase, reset = reset }, function(s)
							s.prepare(); s.control()
							helpers.assert_eq(s.forwarded, 1); helpers.assert_eq(s.controls, 1)
							helpers.assert_eq(s.after_control, receiver[key], "independent receiver must match native Readline movement/edit")
							finish_old(s, phase)
							if phase == "debounce" then helpers.assert_eq(#s.requests, 0, "the pending pre-edit prompt must not dispatch") end
							helpers.assert_eq(s.prediction.has_suggestions(), false, "caret or text edits must retire the original offer")
							helpers.assert_eq(s.visible, false)
							helpers.assert_eq(s.prediction.accept(1), false)
							helpers.assert_eq({ text = s.text, caret = s.caret }, s.after_control)
							helpers.assert_eq(s.output, 0)
						end)
					end)
				end
			end
		end

		-- These receiving ports model no edit outside plain terminal Ctrl. They
		-- check classification only, not native GUI or modified C0 semantics.
		for _, specimen in ipairs({ { "b", "ctrl", "owned-gui-editor" }, { "b", "ctrl-alt", "gnome-terminal" },
			{ "b", "ctrl-meta", "gnome-terminal" }, { "b", "ctrl-altgr", "gnome-terminal" }, { "b", "ctrl-shift", "gnome-terminal" } }) do
			helpers.it("readline-terminal-scope " .. table.concat(specimen, " "), function()
				whole_main({ key = specimen[1], modifier = specimen[2], app = specimen[3] }, function(s)
					s.prepare(); s.control(); finish_old(s, "late")
					helpers.assert_eq(s.after_control, s.before_control)
					helpers.assert_eq(s.forwarded, 1); helpers.assert_eq(s.controls, 1)
					helpers.assert_true(s.prediction.has_suggestions())
					helpers.assert_true(s.prediction.accept(1)); helpers.assert_eq(s.output, 1)
				end)
			end)
		end

		for _, phase in ipairs({ "late", "visible" }) do
			helpers.it("readline-terminal-successor dispatch " .. phase, function()
				whole_main({ key = "b", mode = "dispatch", phase = phase, reset = false }, function(s)
					s.prepare(); s.control()
					helpers.assert_eq(s.after_control, receiver.b)
					helpers.assert_eq(s.forwarded, 1); helpers.assert_eq(s.controls, 1)
					helpers.assert_true(s.action_entry.predecessor_retired, "retire before the configured action starts its successor")
					helpers.assert_true(s.action_started)
					s.requests[1].done(s.response, nil); helpers.assert_eq(s.prediction.has_suggestions(), false)
					s.scheduler.test.advance(2); helpers.assert_eq(#s.requests, 2)
					s.requests[2].done(s.response, nil); helpers.assert_true(s.prediction.has_suggestions())
					helpers.assert_eq(s.output, 0, "an offered successor is not an accepted insertion")
				end)
			end)
		end
	end)

	helpers.describe("whole Main retires Readline history and submitted lines", function()
		local receiver = { p = { text = "owned latest history", caret = 20 }, n = { text = "hello world", caret = 11 },
			j = { text = "", caret = 0 }, m = { text = "", caret = 0 } }
		for _, key in ipairs({ "p", "n", "j", "m" }) do
			for _, phase in ipairs({ "debounce", "late", "visible" }) do
				for _, reset in ipairs({ false, true }) do
					helpers.it("readline-history-retirement " .. key .. " " .. phase .. " reset=" .. tostring(reset), function()
						whole_main({ key = key, phase = phase, reset = reset }, function(s)
							s.prepare(); s.control()
							helpers.assert_eq(s.forwarded, 1); helpers.assert_eq(s.controls, 1)
							helpers.assert_eq(s.after_control, receiver[key], "receiver must match the separately measured history/read transition")
							if key == "n" then helpers.assert_eq(s.before_control.text, "owned latest history typed") end
							if key == "j" or key == "m" then
								helpers.assert_eq(s.submitted_line, "hello world"); helpers.assert_eq(s.read_frame, 2)
							end
							finish_old(s, phase)
							if phase == "debounce" then helpers.assert_eq(#s.requests, 0, "a pre-transition pending prompt must not dispatch") end
							helpers.assert_eq(s.prediction.has_suggestions(), false)
							helpers.assert_eq(s.visible, false); helpers.assert_eq(s.prediction.accept(1), false)
							helpers.assert_eq({ text = s.text, caret = s.caret }, s.after_control)
							helpers.assert_eq(s.output, 0)
						end)
					end)
				end
			end
		end

		-- GUI printing and modified chords are controlled scope ports only;
		-- no native GUI or modified C0 meaning is inferred from these checks.
		for _, specimen in ipairs({ { "p", "ctrl", "owned-gui-editor" }, { "p", "ctrl-alt", "gnome-terminal" },
			{ "p", "ctrl-meta", "gnome-terminal" }, { "p", "ctrl-altgr", "gnome-terminal" }, { "p", "ctrl-shift", "gnome-terminal" } }) do
			helpers.it("readline-history-scope " .. table.concat(specimen, " "), function()
				whole_main({ key = specimen[1], modifier = specimen[2], app = specimen[3] }, function(s)
					s.prepare(); s.control(); finish_old(s, "late")
					helpers.assert_eq(s.after_control, s.before_control)
					helpers.assert_true(s.prediction.has_suggestions())
					helpers.assert_true(s.prediction.accept(1)); helpers.assert_eq(s.output, 1)
				end)
			end)
		end

		for _, phase in ipairs({ "late", "visible" }) do
			helpers.it("readline-history-successor dispatch " .. phase, function()
				whole_main({ key = "p", mode = "dispatch", phase = phase, reset = false }, function(s)
					s.prepare(); s.control(); helpers.assert_eq(s.after_control, receiver.p)
					helpers.assert_eq(s.forwarded, 1); helpers.assert_eq(s.controls, 1)
					helpers.assert_true(s.action_entry.predecessor_retired, "retire the old history context before configured dispatch")
					helpers.assert_true(s.action_started)
					s.requests[1].done(s.response, nil); helpers.assert_eq(s.prediction.has_suggestions(), false)
					s.scheduler.test.advance(2); helpers.assert_eq(#s.requests, 2)
					s.requests[2].done(s.response, nil); helpers.assert_true(s.prediction.has_suggestions())
					helpers.assert_eq(s.output, 0)
				end)
			end)
		end
	end)
end
