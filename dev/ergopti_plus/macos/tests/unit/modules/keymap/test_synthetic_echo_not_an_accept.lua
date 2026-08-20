--- tests/unit/modules/keymap/test_synthetic_echo_not_an_accept.lua

--- ==============================================================================
--- MODULE: Synthetic Echo Must Not Accept An LLM Prediction
--- DESCRIPTION:
--- Drives the real keymap callback with a Return built by the real
--- SyntheticInput adapter. Its explicit ownership tag must bypass LLM accept
--- routing, while an otherwise identical untagged Return must still reach that
--- route. This pins behavior rather than a particular source layout.
--- ==============================================================================

local helpers = require("tests.helpers")

local KEYCODE_RETURN = 36


--- Adds keymap-native accessors to adapter-created key events.
--- @param event table
--- @param key string|number
--- @param is_down boolean
--- @return table event
local function decorate_event(event, key, is_down)
	event.getType = function()
		return is_down and hs.eventtap.event.types.keyDown
			or hs.eventtap.event.types.keyUp
	end
	event.getKeyCode = function()
		return key == "return" and KEYCODE_RETURN or 0
	end
	event.getFlags = function() return {} end
	event.getCharacters = function() return "" end
	return event
end


--- Loads a real keymap tap with a counting LLM boundary.
--- @return table fixture
local function load_fixture()
	for name in pairs(package.loaded) do
		if type(name) == "string" and (
			name:match("^modules%.keymap")
			or name:match("^modules%.llm")
			or name == "adapters.synthetic_input"
			or name == "adapters.event_provenance"
		) then
			package.loaded[name] = nil
		end
	end

	local accept_calls = 0
	local llm = setmetatable({
		init = function() return true end,
		observe_action_epoch = function() end,
		reset_for_action_epoch = function() return true end,
		handle_llm_keys = function()
			accept_calls = accept_calls + 1
			return true
		end,
		update_preview = function() end,
		reset_predictions = function() end,
		check_nav_reset = function() end,
		check_escape_reset = function() return false end,
		get_llm_enabled = function() return false end,
		is_runtime_available = function() return true end,
	}, {
		__index = function() return function() end end,
	})
	package.loaded["modules.keymap.llm_bridge"] = llm

	package.loaded["tests.stubs.hs"] = nil
	local base_hs = require("tests.stubs.hs")
	local base_eventtap = base_hs.eventtap
	local base_new_key_event = base_eventtap.event.newKeyEvent
	local taps = {}
	local eventtap = {}
	for key, value in pairs(base_eventtap) do eventtap[key] = value end
	eventtap.event = {}
	for key, value in pairs(base_eventtap.event) do eventtap.event[key] = value end
	eventtap.event.newKeyEvent = function(modifiers, key, is_down)
		return decorate_event(base_new_key_event(modifiers, key, is_down), key, is_down)
	end
	eventtap.new = function(types, callback)
		local tap = {
			types = types,
			callback = callback,
			enabled = true,
			start = function(self) self.enabled = true; return self end,
			stop = function(self) self.enabled = false; return self end,
			isEnabled = function(self) return self.enabled end,
		}
		taps[#taps + 1] = tap
		return tap
	end

	helpers.load_with_stubs("modules.keymap", { eventtap = eventtap })
	-- The captured eventtap is reachable only after the async focused-window
	-- prewarm has committed. Keep that unrelated boundary known-normal here.
	require("modules.keymap.utils").is_ignored_window = function() return false, 1 end
	local hs_stub = require("hs")
	local keydown = nil
	for _, tap in ipairs(taps) do
		if #tap.types == 1 and tap.types[1] == hs_stub.eventtap.event.types.keyDown then
			keydown = tap.callback
			break
		end
	end
	helpers.assert_not_nil(keydown, "production keyDown tap must be created")
	return {
		handle = keydown,
		synthetic = require("adapters.synthetic_input"),
		hs = hs_stub,
		accept_calls = function() return accept_calls end,
		cleanup = function()
			for name in pairs(package.loaded) do
				if type(name) == "string" and name:match("^modules%.keymap") then
					package.loaded[name] = nil
				end
			end
		end,
	}
end


--- Builds an untagged physical Return event.
--- @param fixture table
--- @return table event
local function physical_return(fixture)
	local properties = fixture.hs.eventtap.event.properties
	return {
		getType = function() return fixture.hs.eventtap.event.types.keyDown end,
		getKeyCode = function() return KEYCODE_RETURN end,
		getFlags = function() return {} end,
		getCharacters = function() return "" end,
		getProperty = function(_self, property)
			if property == properties.eventSourceUserData then return 0 end
			return fixture.hs.processInfo.processID
		end,
	}
end


helpers.describe("keymap: an owned Return is not an LLM accept", function()
	helpers.it("filters the tagged echo but routes an identical physical Return", function()
		local fixture = load_fixture()
		local tx = fixture.synthetic.begin("test.terminator", "replacement")
		local batch = fixture.synthetic.begin_callback(tx)
		fixture.synthetic.keyStroke(batch, {}, "return")
		local _, events = fixture.synthetic.finish_callback(batch, true)
		fixture.synthetic.seal(tx)

		local owned_consume = fixture.handle(events[1])
		helpers.assert_eq(owned_consume, false,
			"the injected Return must continue to the app without entering keymap logic")
		helpers.assert_eq(fixture.accept_calls(), 0,
			"a tagged terminator echo must not accept a prediction")

		local physical_consume = fixture.handle(physical_return(fixture))
		helpers.assert_true(physical_consume,
			"the real LLM route must remain reachable for an untagged Return")
		helpers.assert_eq(fixture.accept_calls(), 1)
		fixture.cleanup()
	end)
end)


helpers.describe("prediction engine: the debounce callback is guarded", function()
	helpers.it("reports a throw through the logger, not the console", function()
		local src = helpers.read_driver_source("_inactivity_timer")
		helpers.assert_true(src ~= nil and src ~= "", "the prediction engine must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("hs.timer.delayed.new", 1, true)
		helpers.assert_not_nil(at, "the debounce timer must still be created")
		local body = code:sub(at, at + 600)
		helpers.assert_true(body:find("xpcall", 1, true) ~= nil,
			"a debounce exception must be contained outside Hammerspoon Console")
		helpers.assert_true(body:find("Logger.error", 1, true) ~= nil,
			"the contained exception must reach the file logger")
	end)
end)
