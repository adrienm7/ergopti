--- tests/unit/modules/keymap/test_word_reset_policy.lua

--- ==============================================================================
--- MODULE: Word Reset After A Pause Or A Click
--- DESCRIPTION:
--- After a pause without typing, the keymap kept the previous word: its timeout
--- was derived from the largest expansion delay and was "never" as soon as one
--- delay was 0, which every shipped configuration has. The first key after the
--- pause was read as the middle of that word, so word-start hotstrings stayed
--- silent. A mouse click emptied the buffer but declared the new run mid-word,
--- with the same effect. Both now follow hotstrings.idle_reset_seconds (default
--- 3 s, 0 = never) and hotstrings.click_resets_word (default true), driven here
--- through the real keyDown and mouse taps.
--- ==============================================================================

local helpers = require("tests.helpers")
local Manifest = require("infra.manifest_reader")
local HotstringCore = require("infra.hotstring_engine")

--- Loads the real keymap with its taps captured and its LLM bridge inert.
--- @return table fixture
local function load_keymap()
	for name in pairs(package.loaded) do
		if type(name) == "string" and (name:match("^modules%.keymap") or name:match("^modules%.llm")
			or name == "adapters.synthetic_input" or name == "adapters.event_provenance") then
			package.loaded[name] = nil
		end
	end
	package.loaded["modules.keymap.llm_bridge"] = setmetatable({
		init = function() return true end,
		handle_llm_keys = function() return false end,
		check_escape_reset = function() return false end,
		get_llm_enabled = function() return false end,
		is_runtime_available = function() return true end,
		reset_for_action_epoch = function() return true end,
	}, { __index = function() return function() end end })

	local state = nil
	local RealState = require("modules.keymap.state")
	package.loaded["modules.keymap.state"] = setmetatable({
		new = function(...)
			state = RealState.new(...)
			return state
		end,
	}, { __index = RealState })

	package.loaded["tests.stubs.hs"] = nil
	local base_hs = require("tests.stubs.hs")
	local taps = {}
	local eventtap = {}
	for key, value in pairs(base_hs.eventtap) do eventtap[key] = value end
	eventtap.new = function(types, callback)
		local tap = {
			types = types, callback = callback, enabled = true,
			start = function(self) self.enabled = true; return self end,
			stop = function(self) self.enabled = false; return self end,
			isEnabled = function(self) return self.enabled end,
		}
		taps[#taps + 1] = tap
		return tap
	end
	local keymap = helpers.load_with_stubs("modules.keymap", { eventtap = eventtap })
	local Utils = require("modules.keymap.utils")
	Utils.is_ignored_window = function() return false, 1 end
	Utils.is_secure_field = function() return false, 1 end
	local hs_stub = require("hs")
	local types = hs_stub.eventtap.event.types
	local keydown, mouse = nil, nil
	for _, tap in ipairs(taps) do
		if #tap.types == 1 and tap.types[1] == types.keyDown then keydown = tap.callback end
		if tap.types[1] == types.leftMouseDown then mouse = tap.callback end
	end
	helpers.assert_not_nil(keydown, "the production keyDown tap must be created")
	helpers.assert_not_nil(mouse, "the production mouse tap must be created")
	helpers.assert_not_nil(state, "the keymap must build its state through the state module")

	local function event(event_type, keycode, chars)
		local properties = hs_stub.eventtap.event.properties
		return {
			getType = function() return event_type end,
			getKeyCode = function() return keycode end,
			getFlags = function() return {} end,
			getCharacters = function() return chars or "" end,
			getProperty = function(_self, property)
				if property == properties.eventSourceUserData then return 0 end
				return hs_stub.processInfo.processID
			end,
		}
	end
	return {
		keymap = keymap,
		state = state,
		now = function() return hs_stub.timer.secondsSinceEpoch() end,
		type_char = function(chars) return keydown(event(types.keyDown, 0, chars)) end,
		click = function() return mouse(event(types.leftMouseDown, 0)) end,
		cleanup = function()
			for name in pairs(package.loaded) do
				if type(name) == "string" and name:match("^modules%.keymap") then package.loaded[name] = nil end
			end
		end,
	}
end

--- Runs a body against a fresh keymap and always unloads it.
--- @param body function Receives the fixture.
local function with_keymap(body)
	local fixture = load_keymap()
	-- The first key binds the window context, which itself starts a new run;
	-- type it before the scenario so only the pause or the click is observed.
	local ok, err = pcall(fixture.type_char, "x")
	if ok then ok, err = pcall(body, fixture) end
	fixture.cleanup()
	if not ok then error(err, 0) end
end

--- Leaves the buffer mid-word, as if "abc" had been typed `pause` seconds ago.
--- @param fixture table
--- @param pause number Seconds since the previous key.
local function mid_word(fixture, pause)
	fixture.state.buffer = "abc"
	fixture.state.start_is_word_boundary = false
	fixture.state.last_key_time = fixture.now() - pause
end

helpers.describe("hotstrings.idle_reset_seconds: a pause starts a new word", function()
	helpers.it("ships 3 s and a click that starts a word, from the manifest", function()
		helpers.assert_eq(Manifest.default_for("hotstrings.idle_reset_seconds"), 3)
		helpers.assert_eq(Manifest.default_for("hotstrings.click_resets_word"), true)
		with_keymap(function(f)
			helpers.assert_eq(f.keymap.get_idle_reset_seconds(), 3)
			helpers.assert_eq(f.state.WORD_TIMEOUT_SEC, 3,
				"the delays must no longer turn the shipped pause into never")
			helpers.assert_eq(f.keymap.is_click_resets_word_enabled(), true)
		end)
	end)

	helpers.it("a pause of the configured length restarts the buffer at a word start", function()
		with_keymap(function(f)
			mid_word(f, 3)
			helpers.assert_eq(f.type_char("d"), false, "the letter is typed")
			helpers.assert_eq(f.state.buffer, "d", "the previous word is forgotten")
			helpers.assert_eq(f.state.start_is_word_boundary, true,
				"a word-start hotstring may fire on the new run")
		end)
	end)

	helpers.it("a shorter pause keeps the word in progress", function()
		with_keymap(function(f)
			mid_word(f, 2)
			f.type_char("d")
			helpers.assert_eq(f.state.buffer, "abcd")
			helpers.assert_eq(f.state.start_is_word_boundary, false)
		end)
	end)

	helpers.it("0 disables the reset whatever the pause", function()
		with_keymap(function(f)
			helpers.assert_eq(f.keymap.set_idle_reset_seconds(0), true)
			mid_word(f, 3600)
			f.type_char("d")
			helpers.assert_eq(f.state.buffer, "abcd")
			helpers.assert_eq(f.state.start_is_word_boundary, false)
		end)
	end)

	helpers.it("a custom delay is applied live", function()
		with_keymap(function(f)
			helpers.assert_eq(f.keymap.set_idle_reset_seconds(7.5), true)
			mid_word(f, 5)
			f.type_char("d")
			helpers.assert_eq(f.state.buffer, "abcd", "5 s is no pause under a 7.5 s setting")
			mid_word(f, 8)
			f.type_char("d")
			helpers.assert_eq(f.state.buffer, "d")
		end)
	end)

	helpers.it("the first key ever is never a pause", function()
		with_keymap(function(f)
			f.state.buffer = "abc"
			f.state.start_is_word_boundary = false
			f.state.last_key_time = 0
			f.type_char("d")
			helpers.assert_eq(f.state.buffer, "abcd")
		end)
	end)

	for _, invalid in ipairs({ -1, 0 / 0, math.huge, "3", true }) do
		helpers.it("refuses the idle value " .. tostring(invalid), function()
			with_keymap(function(f)
				helpers.assert_eq(f.keymap.set_idle_reset_seconds(invalid), false)
				helpers.assert_eq(f.keymap.get_idle_reset_seconds(), 3)
			end)
		end)
	end
end)

helpers.describe("hotstrings.click_resets_word: a click starts a new word", function()
	helpers.it("on, the run after a click starts a word", function()
		with_keymap(function(f)
			mid_word(f, 0)
			f.click()
			helpers.assert_eq(f.state.buffer, "")
			helpers.assert_eq(f.state.start_is_word_boundary, true)
		end)
	end)

	helpers.it("off, the click still empties the buffer but the run is mid-word", function()
		with_keymap(function(f)
			helpers.assert_eq(f.keymap.set_click_resets_word(false), true)
			mid_word(f, 0)
			f.click()
			helpers.assert_eq(f.state.buffer, "")
			helpers.assert_eq(f.state.start_is_word_boundary, false)
		end)
	end)

	helpers.it("refuses a non-boolean", function()
		with_keymap(function(f)
			helpers.assert_eq(f.keymap.set_click_resets_word("yes"), false)
			helpers.assert_eq(f.keymap.is_click_resets_word_enabled(), true)
		end)
	end)
end)

helpers.describe("shared idle-reset rule as the macOS driver uses it", function()
	helpers.it("resets at the delay, not before, and never when disabled", function()
		helpers.assert_eq(HotstringCore.idle_resets_word(1000, 4000, 3, 0), true)
		helpers.assert_eq(HotstringCore.idle_resets_word(1000, 3999, 3, 0), false)
		helpers.assert_eq(HotstringCore.idle_resets_word(nil, 999999, 3, 0), false)
		helpers.assert_eq(HotstringCore.idle_resets_word(0, 999999, 0, 0), false)
		helpers.assert_eq(HotstringCore.idle_resets_word(1000, 4000, 3, 1000), false,
			"a gap no wider than the clock resolution plus the delay is no proven pause")
	end)

	helpers.it("validates the stored value", function()
		helpers.assert_eq(HotstringCore.valid_idle_reset_seconds(0), true)
		helpers.assert_eq(HotstringCore.valid_idle_reset_seconds(2.5), true)
		for _, invalid in ipairs({ -0.5, 0 / 0, math.huge, "3", nil }) do
			helpers.assert_eq(HotstringCore.valid_idle_reset_seconds(invalid), false)
		end
		local ok, err = pcall(HotstringCore.idle_resets_word, 0, 1, -1, 0)
		helpers.assert_eq(ok, false)
		helpers.assert_true(tostring(err):find("idle delay", 1, true) ~= nil, "the refusal names the idle delay")
	end)
end)

return true
