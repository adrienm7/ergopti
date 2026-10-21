--- tests/unit/modules/keymap/terminators/test_arrow_shortcut_word_reset.lua

--- ==============================================================================
--- MODULE: Arrow And Shortcut Word Reset
--- DESCRIPTION:
--- An arrow emptied the buffer but declared the next run mid-word, and a
--- Cmd/Ctrl shortcut did the same except for Cmd/Ctrl+A, so a word-start
--- hotstring typed right after either stayed silent. Both now follow
--- hotstrings.arrow_resets_word and hotstrings.shortcut_resets_word (default
--- on): on, the next run starts a new word; off, the buffer and the word-start
--- state are left untouched and the word continues. Cmd/Ctrl+Backspace stay
--- an unconditional reset to an unknown boundary, Option+Backspace (delete the
--- previous word) always starts a word, and Option or Shift + letter stay
--- typing. The last section pins what erasing the typed text does
--- (bs-word-start).
---
--- The fixture registers TOML-shaped entries through the real load_toml path:
--- `r` -> `R` flagged word-start and `z` -> `Z` not flagged, and drives the
--- real keyDown tap with `a`, <event>, `r`: `aR` when on, `ar` when off.
--- ==============================================================================

local helpers = require("tests.helpers")

local KEYCODE_LETTER = 0
local KEYCODE_V = 9
local KEYCODE_Z = 6
local KEYCODE_BACKSPACE = 51
local KEYCODE_LEFT = 123
local KEYCODE_UP = 126
local KARABINER_PID = 4242

local NO_FLAGS = { cmd = false, ctrl = false, alt = false, shift = false }

local WORD_TOML = {
	sections_order = { "words" },
	sections = {
		words = {
			r = { output = "R", is_word = true, auto_expand = true },
			z = { output = "Z", auto_expand = true },
		},
	},
	meta = {},
}

--- Installs the external collaborators needed to drive the real keymap tap.
--- @param effects table Mutable output capture.
local function install_collaborators(effects)
	for name in pairs(package.loaded) do
		if type(name) == "string" and (name:match("^modules%.keymap") or name:match("^adapters%.")) then
			package.loaded[name] = nil
		end
	end
	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	package.loaded["modules.llm"] = {
		DEFAULT_STATE = { llm_after_hotstring = false, llm_reset_on_nav = true },
		check_modifiers = function() return false end,
	}
	package.loaded["modules.llm.prediction_engine"] = setmetatable({
		init = function() return true end,
		set_runtime_guard = function() end,
		get_llm_enabled = function() return false end,
		reset = function() effects.prediction_resets = effects.prediction_resets + 1; return true end,
		handle_chain_signal = function() return false end,
		is_visible = function() return false end,
	}, { __index = function() return function() end end })
	package.loaded["modules.keylogger"] = {
		log_hotstring_suggested = function() end,
		log_hotstring_dismissed = function() end,
		log_llm_accepted = function() end,
		log_hotstring = function() end,
		notify_synthetic = function(text, source)
			if source == "hotstring" then effects.emitted[#effects.emitted + 1] = text end
		end,
		set_buffer = function() end,
	}
	package.loaded["ui.tooltip"] = {
		set_runtime_guard = function() end,
		set_accept_callback = function() end,
		set_cancel_callback = function() end,
		set_on_show_callback = function() end,
		set_timeout = function() end,
		set_colorization_enabled = function() end,
		set_accent_color = function() end,
		tint = function() return {} end,
		show_stacked = function() return true end,
		hide = function() return true end,
		hide_forced = function() return true end,
		hide_forced_silent = function() return true end,
		is_visible = function() return false end,
		is_hotstring_visible = function() return false end,
		has_visible_hotstring_lease = function() return false end,
	}
	package.loaded["modules.hotstrings.hotstrings_config"] = {
		resolve = function() return nil end,
		get_user_override = function() return nil end,
	}
	package.loaded["adapters.tooltip_renderer"] = { hide = function() return true end }
	-- Only the fixture's virtual file is answered here; every other TOML (the
	-- shared timing constants, …) is still read by the real reader.
	package.loaded["infra.toml.reader"] = nil
	local RealReader = require("infra.toml.reader")
	package.loaded["infra.toml.reader"] = setmetatable({
		parse = function(path, ...)
			if path == "/virtual/word_reset.toml" then return WORD_TOML, true end
			return RealReader.parse(path, ...)
		end,
	}, { __index = RealReader })
end

--- Drains only zero-delay work; production keeps future TTL timers.
--- @param hs_stub table Hammerspoon stub.
local function drain_immediate_timers(hs_stub)
	for _ = 1, 32 do
		local pending = {}
		for _, timer in ipairs(hs_stub.timer.__timers) do
			if timer.running and timer.delay == 0 then pending[#pending + 1] = timer end
		end
		if #pending == 0 then return end
		for _, timer in ipairs(pending) do
			if timer.running then timer:fire() end
		end
	end
	error("immediate timer queue did not settle", 0)
end

--- Builds the real keymap with the word-start fixture and runs one body.
--- @param body function Receives the fixture.
local function with_keymap(body)
	local effects = { emitted = {}, prediction_resets = 0 }
	install_collaborators(effects)
	local state = nil
	local RealState = require("modules.keymap.state")
	package.loaded["modules.keymap.state"] = setmetatable({
		new = function(...)
			state = RealState.new(...)
			return state
		end,
	}, { __index = RealState })
	local Keymap = helpers.load_with_stubs("modules.keymap")
	local hs_stub = _G.hs
	local Utils = package.loaded["modules.keymap.utils"]
	local original_ignored, original_secure = Utils.is_ignored_window, Utils.is_secure_field
	Utils.is_ignored_window = function() return false, 0 end
	Utils.is_secure_field = function() return false, 0 end
	local now = 100
	hs_stub.timer.secondsSinceEpoch = function() return now end

	local tap = nil
	for _, candidate in ipairs(hs_stub.eventtap.__taps) do
		if #candidate.types == 1 and candidate.types[1] == hs_stub.eventtap.event.types.keyDown then tap = candidate end
	end
	local properties = hs_stub.eventtap.event.properties

	local function press(character, flags, keycode, source_pid)
		now = now + 0.01
		return tap.fn({
			getProperty = function(_self, property)
				if property == properties.eventSourceUserData then return 0 end
				return source_pid or 0
			end,
			getFlags = function() return flags or NO_FLAGS end,
			getKeyCode = function() return keycode or KEYCODE_LETTER end,
			getCharacters = function() return character end,
		})
	end

	local ok, err = xpcall(function()
		helpers.assert_not_nil(tap, "the real keymap must install one key-down eventtap")
		helpers.assert_not_nil(state, "the keymap must build its state through the state module")
		helpers.assert_eq(Keymap.load_toml("word_reset", "/virtual/word_reset.toml"), true,
			"the TOML-shaped entries register through the real loader")
		Keymap.sort_mappings()
		Keymap.set_base_delay(1)
		local flagged = {}
		for _, mapping in ipairs(state.mappings) do flagged[mapping.trigger] = mapping.is_word end
		helpers.assert_eq(flagged.r, true, "the r entry carries the word-start flag")
		helpers.assert_eq(flagged.z, false, "the z entry is not flagged")
		-- The first key binds the window context; start each scenario after it.
		press(" ")
		drain_immediate_timers(hs_stub)
		effects.emitted = {}
		body({
			keymap = Keymap, state = state, effects = effects,
			press = press,
			pause = function(seconds) now = now + seconds end,
			settle = function() drain_immediate_timers(hs_stub) end,
		})
	end, debug.traceback)
	pcall(Keymap.stop)
	Utils.is_ignored_window, Utils.is_secure_field = original_ignored, original_secure
	for name in pairs(package.loaded) do
		if type(name) == "string" and (name:match("^modules%.keymap") or name == "infra.toml.reader") then
			package.loaded[name] = nil
		end
	end
	if not ok then error(err, 0) end
end

--- Types `a`, the event, then `trigger`, and returns what the engine emitted.
--- @param f table Fixture.
--- @param event function Presses the event under test.
--- @param trigger string|nil The key typed after the event (default "r").
--- @return string emitted Concatenated hotstring output.
local function a_event_then(f, event, trigger)
	f.press("a")
	event(f)
	f.press(trigger or "r", nil, trigger == "z" and KEYCODE_Z or KEYCODE_LETTER)
	f.settle()
	local emitted = table.concat(f.effects.emitted)
	f.effects.emitted = {}
	-- A space closes the scenario so the next one starts on a known boundary.
	f.press(" ")
	f.settle()
	f.effects.emitted = {}
	return emitted
end

local ARROW_EVENTS = {
	{ name = "a physical Left arrow", fn = function(f) f.press("", nil, KEYCODE_LEFT) end },
	{ name = "a Karabiner-emitted Up arrow (foreign event)",
		fn = function(f) f.press("", nil, KEYCODE_UP, KARABINER_PID) end },
	{ name = "Shift+Left", fn = function(f)
		f.press("", { cmd = false, ctrl = false, alt = false, shift = true }, KEYCODE_LEFT) end },
	{ name = "Cmd+Left", fn = function(f)
		f.press("", { cmd = true, ctrl = false, alt = false, shift = false }, KEYCODE_LEFT) end },
}

local SHORTCUT_EVENTS = {
	{ name = "Cmd+V", fn = function(f)
		f.press("v", { cmd = true, ctrl = false, alt = false, shift = false }, KEYCODE_V) end },
	{ name = "Cmd+Shift+Z", fn = function(f)
		f.press("z", { cmd = true, ctrl = false, alt = false, shift = true }, KEYCODE_Z) end },
	{ name = "Ctrl+Cmd+V", fn = function(f)
		f.press("v", { cmd = true, ctrl = true, alt = false, shift = false }, KEYCODE_V) end },
	{ name = "Cmd+Option+V", fn = function(f)
		f.press("v", { cmd = true, ctrl = false, alt = true, shift = false }, KEYCODE_V) end },
	{ name = "Ctrl+V", fn = function(f)
		f.press("v", { cmd = false, ctrl = true, alt = false, shift = false }, KEYCODE_V) end },
}

helpers.describe("word-start fixture control", function()
	helpers.it("ships both options on, from the manifest", function()
		with_keymap(function(f)
			helpers.assert_eq(f.keymap.is_arrow_resets_word_enabled(), true)
			helpers.assert_eq(f.keymap.is_shortcut_resets_word_enabled(), true)
		end)
	end)

	helpers.it("ar types ar: the word-start entry does not fire mid-word", function()
		with_keymap(function(f)
			helpers.assert_eq(a_event_then(f, function() end), "")
			f.press("r")
			f.settle()
			helpers.assert_eq(table.concat(f.effects.emitted), "R", "the entry fires at a word start")
		end)
	end)

	helpers.it("refuses non-boolean values and keeps the current one", function()
		with_keymap(function(f)
			helpers.assert_eq(f.keymap.set_arrow_resets_word("yes"), false)
			helpers.assert_eq(f.keymap.set_shortcut_resets_word(1), false)
			helpers.assert_eq(f.keymap.is_arrow_resets_word_enabled(), true)
			helpers.assert_eq(f.keymap.is_shortcut_resets_word_enabled(), true)
		end)
	end)
end)

helpers.describe("hotstrings.arrow_resets_word", function()
	for _, event in ipairs(ARROW_EVENTS) do
		helpers.it(event.name .. " starts a new word when on: a, arrow, r gives aR", function()
			with_keymap(function(f)
				helpers.assert_eq(a_event_then(f, event.fn), "R")
			end)
		end)

		helpers.it(event.name .. " continues the word when off: a, arrow, r gives ar", function()
			with_keymap(function(f)
				helpers.assert_eq(f.keymap.set_arrow_resets_word(false), true)
				f.press("a")
				local buffer, boundary = f.state.buffer, f.state.start_is_word_boundary
				event.fn(f)
				helpers.assert_eq(f.state.buffer, buffer, "the buffer is left as it was")
				helpers.assert_eq(f.state.start_is_word_boundary, boundary, "the word-start state is left as it was")
				f.press(" ")
				f.settle()
				f.effects.emitted = {}
				helpers.assert_eq(a_event_then(f, event.fn), "")
			end)
		end)
	end

	helpers.it("the unflagged entry fires either way", function()
		for _, enabled in ipairs({ true, false }) do
			with_keymap(function(f)
				helpers.assert_eq(f.keymap.set_arrow_resets_word(enabled), true)
				helpers.assert_eq(a_event_then(f, ARROW_EVENTS[1].fn, "z"), "Z")
			end)
		end
	end)

	helpers.it("still withdraws predictions when off", function()
		with_keymap(function(f)
			helpers.assert_eq(f.keymap.set_arrow_resets_word(false), true)
			local before = f.effects.prediction_resets
			f.press("", nil, KEYCODE_LEFT)
			helpers.assert_true(f.effects.prediction_resets > before, "the moved caret resets the prediction")
		end)
	end)
end)

helpers.describe("hotstrings.shortcut_resets_word", function()
	for _, event in ipairs(SHORTCUT_EVENTS) do
		helpers.it(event.name .. " starts a new word when on: gives aR", function()
			with_keymap(function(f)
				helpers.assert_eq(a_event_then(f, event.fn), "R")
			end)
		end)

		helpers.it(event.name .. " continues the word when off: gives ar", function()
			with_keymap(function(f)
				helpers.assert_eq(f.keymap.set_shortcut_resets_word(false), true)
				f.press("a")
				local buffer, boundary = f.state.buffer, f.state.start_is_word_boundary
				event.fn(f)
				helpers.assert_eq(f.state.buffer, buffer, "the buffer is left as it was")
				helpers.assert_eq(f.state.start_is_word_boundary, boundary, "the word-start state is left as it was")
				f.press(" ")
				f.settle()
				f.effects.emitted = {}
				helpers.assert_eq(a_event_then(f, event.fn), "")
			end)
		end)
	end

	helpers.it("an arrow with Cmd follows the arrow option, not the shortcut one", function()
		with_keymap(function(f)
			helpers.assert_eq(f.keymap.set_shortcut_resets_word(false), true)
			helpers.assert_eq(a_event_then(f, ARROW_EVENTS[4].fn), "R", "arrow on, shortcut off")
			helpers.assert_eq(f.keymap.set_shortcut_resets_word(true), true)
			helpers.assert_eq(f.keymap.set_arrow_resets_word(false), true)
			helpers.assert_eq(a_event_then(f, ARROW_EVENTS[4].fn), "", "arrow off, shortcut on")
		end)
	end)

	helpers.it("the unflagged entry fires either way", function()
		for _, enabled in ipairs({ true, false }) do
			with_keymap(function(f)
				helpers.assert_eq(f.keymap.set_shortcut_resets_word(enabled), true)
				helpers.assert_eq(a_event_then(f, SHORTCUT_EVENTS[1].fn, "z"), "Z")
			end)
		end
	end)
end)

helpers.describe("typing chords and deletions are not governed", function()
	helpers.it("Option+letter is typing, never a shortcut", function()
		with_keymap(function(f)
			helpers.assert_eq(a_event_then(f, function()
				f.press(utf8.char(0x00E6), { cmd = false, ctrl = false, alt = true, shift = false }, KEYCODE_LETTER)
			end), "")
		end)
	end)

	helpers.it("Shift+letter is typing, never a shortcut", function()
		with_keymap(function(f)
			helpers.assert_eq(a_event_then(f, function()
				f.press("B", { cmd = false, ctrl = false, alt = false, shift = true }, KEYCODE_LETTER)
			end), "")
		end)
	end)

	for _, chord in ipairs({
		{ name = "Cmd+Backspace", flags = { cmd = true, ctrl = false, alt = false, shift = false }, starts = false },
		{ name = "Option+Backspace", flags = { cmd = false, ctrl = false, alt = true, shift = false }, starts = true },
		{ name = "Ctrl+Backspace", flags = { cmd = false, ctrl = true, alt = false, shift = false }, starts = false },
	}) do
		helpers.it(chord.name .. " empties the buffer with both options off", function()
			with_keymap(function(f)
				helpers.assert_eq(f.keymap.set_shortcut_resets_word(false), true)
				helpers.assert_eq(f.keymap.set_arrow_resets_word(false), true)
				f.press("a")
				f.press("", chord.flags, KEYCODE_BACKSPACE)
				helpers.assert_eq(f.state.buffer, "", "the deletion empties the buffer whatever the options")
				helpers.assert_eq(f.state.start_is_word_boundary, chord.starts, chord.starts
					and "Option+Backspace deleted the previous word: the caret is at a word start (bs-word-start)"
					or "an unknown amount of text was deleted: the boundary is unknown")
			end)
		end)
	end
end)

local KEYCODE_HOME = 115
local KEYCODE_RETURN = 36
local OPTION = { cmd = false, ctrl = false, alt = true, shift = false }
local CMD = { cmd = true, ctrl = false, alt = false, shift = false }

--- Makes the focused application the one named.
--- @param bundle string Bundle identifier.
--- @param name string Application name.
local function focus_app(bundle, name)
	require("adapters.text_sender").focusedAppIdentity = function() return bundle, name, {} end
end

--- Presses Backspace `count` times.
local function backspaces(f, count)
	for _ = 1, count do f.press("", nil, KEYCODE_BACKSPACE) end
end

--- Types `r` and returns what fired.
local function then_r(f)
	f.press("r")
	f.settle()
	local emitted = table.concat(f.effects.emitted)
	f.effects.emitted = {}
	return emitted
end

helpers.describe("erasing what was typed (bs-word-start)", function()
	helpers.it("bs-word-start: the Backspace that erases every typed letter starts a word", function()
		with_keymap(function(f)
			focus_app("com.apple.TextEdit", "TextEdit")
			f.press("", nil, KEYCODE_HOME)
			f.press("a")
			f.press("b")
			backspaces(f, 2)
			helpers.assert_eq(then_r(f), "R", "« ab » erased after an unknown start, then « r »")
		end)
	end)

	helpers.it("bs-word-start: a correction keeps the word open", function()
		with_keymap(function(f)
			focus_app("com.apple.TextEdit", "TextEdit")
			f.press("", nil, KEYCODE_HOME)
			f.press("a")
			f.press("b")
			backspaces(f, 1)
			helpers.assert_eq(then_r(f), "", "« ar » is inside a word")
		end)
	end)

	helpers.it("bs-word-start: a Backspace past the typed letters leaves an unknown start", function()
		with_keymap(function(f)
			focus_app("com.apple.TextEdit", "TextEdit")
			f.press("a")
			f.press("b")
			-- The fixture typed a space first: three Backspaces erase « ab » and
			-- that space, back to where the buffer started; the fourth goes past it.
			backspaces(f, 4)
			helpers.assert_eq(then_r(f), "", "the fourth Backspace deleted text the buffer never held")
		end)
	end)

	helpers.it("bs-word-start: a pause before the Backspaces keeps the word they erase", function()
		with_keymap(function(f)
			focus_app("com.apple.TextEdit", "TextEdit")
			f.press("", nil, KEYCODE_HOME)
			f.press("a")
			f.press("b")
			f.pause(10)
			backspaces(f, 2)
			helpers.assert_eq(then_r(f), "R", "« ab », a pause, both erased: a word start")
			f.press(" ")
			f.press("a")
			f.press("b")
			f.pause(10)
			backspaces(f, 1)
			helpers.assert_eq(then_r(f), "", "« ab », a pause, one erased: still inside the word")
		end)
	end)

	helpers.it("bs-word-start: Option+Backspace starts a word", function()
		with_keymap(function(f)
			focus_app("com.apple.TextEdit", "TextEdit")
			f.press("", nil, KEYCODE_HOME)
			f.press("a")
			f.press("", OPTION, KEYCODE_BACKSPACE)
			helpers.assert_eq(then_r(f), "R")
		end)
	end)

	helpers.it("bs-word-start: a terminal prompt after Return keeps its word start", function()
		with_keymap(function(f)
			focus_app("com.apple.Terminal", "Terminal")
			f.press("a")
			f.press("\r", nil, KEYCODE_RETURN)
			f.pause(10)
			f.press("a")
			backspaces(f, 2)
			helpers.assert_eq(then_r(f), "R", "the extra Backspace hit the empty prompt and deleted nothing")
		end)
		with_keymap(function(f)
			focus_app("com.apple.TextEdit", "TextEdit")
			f.press("a")
			f.press("\r", nil, KEYCODE_RETURN)
			f.press("a")
			backspaces(f, 2)
			helpers.assert_eq(then_r(f), "", "in an editor the extra Backspace joined the lines")
		end)
	end)

	helpers.it("bs-word-start: Cmd+A and a browser's Cmd+L leave an empty field", function()
		with_keymap(function(f)
			focus_app("com.apple.TextEdit", "TextEdit")
			f.press("a")
			f.press("a", CMD, KEYCODE_LETTER)
			backspaces(f, 2)
			helpers.assert_eq(then_r(f), "R", "Cmd+A then Backspace empties the field")
		end)
		with_keymap(function(f)
			focus_app("com.apple.Terminal", "Terminal")
			f.press("a")
			f.press("a", CMD, KEYCODE_LETTER)
			backspaces(f, 1)
			helpers.assert_eq(then_r(f), "", "Cmd+A in a terminal selects the scrollback, not the prompt")
		end)
		with_keymap(function(f)
			focus_app("com.apple.Safari", "Safari")
			f.press("l", CMD, KEYCODE_LETTER)
			backspaces(f, 1)
			helpers.assert_eq(then_r(f), "R", "Cmd+L selects the whole address")
		end)
		with_keymap(function(f)
			focus_app("com.apple.TextEdit", "TextEdit")
			f.press("l", CMD, KEYCODE_LETTER)
			backspaces(f, 1)
			helpers.assert_eq(then_r(f), "", "Cmd+L outside a browser promises no empty field")
		end)
	end)
end)

return true
