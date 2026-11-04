--- tests/unit/modules/keymap/synthetic/test_text_carrier_avoids_held_key.lua

--- ==============================================================================
--- MODULE: Replacement text never rides a held key (hsfix-held-carrier)
--- DESCRIPTION:
--- The maintainer's personal hotstring « axa » typed « XA » instead of « AXA »
--- on macOS, often but not always (field report 2026-10-28, 18:14). Fast typing
--- presses Space before the last A is released; the expansion is built inside
--- that Space key-down, while the A key is still down. Every synthetic Unicode
--- text event rode key code 0, the A key, so the first replacement character
--- was a second key-down of a key already down and was lost; after its
--- synthetic key-up the next characters landed. The test drives the production
--- keymap taps with that exact edge order and a receiver that, like the real
--- one, drops a key-down of a key it already holds.
--- ==============================================================================

local helpers = require("tests.helpers")

local CURRENT_PID = 7001
local KEYCODE_A = 0

--- Loads the production keymap and returns its taps and the synthetic adapter.
--- @return table fixture
local function load_fixture()
	for name in pairs(package.loaded) do
		if type(name) == "string" and (
			name:match("^modules%.keymap")
			or name:match("^modules%.llm")
			or name:match("^modules%.keystats")
			or name:match("^ui%.tooltip")
			or name == "adapters.synthetic_input"
			or name == "adapters.event_provenance"
			or name == "adapters.event_clock"
			or name == "adapters.unicode_carrier"
			or name == "infra.key_event_health"
		) then
			package.loaded[name] = nil
		end
	end
	package.loaded["tests.stubs.hs"] = nil
	local base_hs = require("tests.stubs.hs")
	local taps = {}
	local eventtap = {}
	for key, value in pairs(base_hs.eventtap) do eventtap[key] = value end
	eventtap.new = function(types, callback)
		local tap = {
			types = types,
			callback = callback,
			enabled = false,
			start = function(self) self.enabled = true; return self end,
			stop = function(self) self.enabled = false; return self end,
			isEnabled = function(self) return self.enabled end,
		}
		taps[#taps + 1] = tap
		return tap
	end
	helpers.load_with_stubs("modules.keymap", {
		eventtap = eventtap,
		processInfo = { processID = CURRENT_PID },
	})
	local Utils = require("modules.keymap.utils")
	Utils.is_ignored_window = function() return false, 1 end
	Utils.is_secure_field = function() return false, 1 end
	local hs_stub = require("hs")
	local down_tap, up_tap
	for _, tap in ipairs(taps) do
		if #tap.types == 1 and tap.types[1] == hs_stub.eventtap.event.types.keyDown then
			down_tap = down_tap or tap
		elseif #tap.types == 1 and tap.types[1] == hs_stub.eventtap.event.types.keyUp then
			up_tap = up_tap or tap
		end
	end
	helpers.assert_not_nil(down_tap, "the keymap keyDown tap must exist")
	helpers.assert_not_nil(up_tap, "the keymap keyUp tap must exist")
	return {
		down = down_tap.callback, up = up_tap.callback, hs = hs_stub,
		synthetic = require("adapters.synthetic_input"),
	}
end

--- Builds one untagged physical key event.
--- @param fixture table
--- @param keycode number
--- @param is_down boolean
--- @return table event
local function physical(fixture, keycode, is_down)
	local properties = fixture.hs.eventtap.event.properties
	return {
		physical = true,
		keycode = keycode,
		isDown = is_down,
		getType = function()
			return is_down and fixture.hs.eventtap.event.types.keyDown
				or fixture.hs.eventtap.event.types.keyUp
		end,
		getKeyCode = function() return keycode end,
		getFlags = function() return {} end,
		getCharacters = function() return "a" end,
		rawFlags = function() return 0 end,
		getProperty = function(_, property)
			if property == properties.eventSourceUnixProcessID then return 4242 end
			return 0
		end,
	}
end

--- A receiving application: it types the text of each key-down, except a
--- key-down of a key it already holds, which it drops.
--- @return table receiver
local function receiver()
	local held, typed = {}, {}
	local self = {}
	function self.deliver(event)
		local keycode = event.physical and event.keycode or event.key
		if event.isDown then
			if held[keycode] then return end
			held[keycode] = true
			typed[#typed + 1] = event.physical and "a" or event.unicode
		else
			held[keycode] = nil
		end
	end
	function self.text() return table.concat(typed) end
	return self
end

--- Builds the replacement the way the expander does: inside a key-down
--- callback, through the ambient collector, and returns the callback's events.
--- @param synthetic table
--- @param text string
--- @return table events
local function emit_in_callback(synthetic, text)
	synthetic.enter_callback()
	local tx = synthetic.begin("unit.held-carrier", "replacement")
	synthetic.with_transaction(tx, function()
		helpers.assert_true(synthetic.emit_key_strokes(text))
	end)
	helpers.assert_true(synthetic.seal(tx))
	local _, events = synthetic.leave_callback(true)
	helpers.assert_not_nil(events, "the replacement must be returned to Quartz")
	return events
end

helpers.describe("replacement text never rides a held key (hsfix-held-carrier)", function()
	helpers.it("types the whole replacement while the trigger's last key is still down", function()
		local fixture = load_fixture()
		local app = receiver()
		-- The A key-down reaches the keymap tap and passes to the application.
		local a_down = physical(fixture, KEYCODE_A, true)
		helpers.assert_true(fixture.down(a_down) ~= true, "a plain A passes through")
		app.deliver(a_down)
		-- Space arrives before the A is released: the expansion is built now.
		for _, event in ipairs(emit_in_callback(fixture.synthetic, "AXA")) do
			app.deliver(event)
		end
		local a_up = physical(fixture, KEYCODE_A, false)
		fixture.up(a_up)
		app.deliver(a_up)
		helpers.assert_eq(app.text(), "aAXA",
			"the first replacement character must not ride the held A key")
	end)

	helpers.it("keeps key code 0 once the key is released", function()
		local fixture = load_fixture()
		fixture.down(physical(fixture, KEYCODE_A, true))
		fixture.up(physical(fixture, KEYCODE_A, false))
		local events = emit_in_callback(fixture.synthetic, "AXA")
		helpers.assert_eq(#events, 6)
		for _, event in ipairs(events) do
			helpers.assert_eq(event.key, KEYCODE_A, "no key is held: the default carrier")
		end
	end)

	helpers.it("forgets a held key whose key-up was lost once it stops repeating", function()
		load_fixture()
		local Carrier = require("adapters.unicode_carrier")
		local KeyEventHealth = require("infra.key_event_health")
		local clock = require("adapters.timer_scheduler")
		local saved = clock.now_ns
		local now_ns = 1e12
		clock.now_ns = function() return now_ns end
		local ok, err = pcall(function()
			Carrier.reset()
			Carrier.note_physical_key("down", KEYCODE_A)
			local held_code, moved = Carrier.keycode()
			helpers.assert_true(moved and held_code ~= KEYCODE_A, "a held A moves the carrier")
			now_ns = now_ns + KeyEventHealth.STUCK_MS * 1e6
			local stale_code, stale_moved = Carrier.keycode()
			helpers.assert_eq(stale_code, KEYCODE_A, "a key silent for STUCK_MS is not held")
			helpers.assert_true(stale_moved == false)
		end)
		clock.now_ns = saved
		Carrier.reset()
		if not ok then error(err, 0) end
	end)
end)
