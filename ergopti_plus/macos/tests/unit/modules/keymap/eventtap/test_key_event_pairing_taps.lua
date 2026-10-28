--- tests/unit/modules/keymap/eventtap/test_key_event_pairing_taps.lua

--- ==============================================================================
--- MODULE: Keymap Tap Key Pairing Regression
--- DESCRIPTION:
--- Drives the production keymap keyDown and keyUp eventtaps with physical
--- events and checks that every one of them reaches the session's pairing
--- counters (infra/key_event_health.lua), so the next macOS report says
--- whether a key-down or a key-up went missing (issues #99 and #100), while
--- Ergopti's own tagged output is never counted as typing (key-event-pairing).
--- ==============================================================================

local helpers = require("tests.helpers")

local CURRENT_PID = 7001
local KEYCODE_A = 0
local KEYCODE_E = 14

--- Loads the production keymap and returns its keyDown and keyUp callbacks.
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
	local Health = require("infra.key_event_health")
	Health.reset()
	return { down = down_tap.callback, up = up_tap.callback, hs = hs_stub, health = Health }
end

--- Builds one untagged physical key event.
--- @param fixture table
--- @param keycode number
--- @param is_down boolean
--- @param user_data number|nil Quartz user data (an Ergopti tag when set).
--- @return table event
local function physical(fixture, keycode, is_down, user_data)
	local properties = fixture.hs.eventtap.event.properties
	return {
		getType = function()
			return is_down and fixture.hs.eventtap.event.types.keyDown
				or fixture.hs.eventtap.event.types.keyUp
		end,
		getKeyCode = function() return keycode end,
		getFlags = function() return {} end,
		getCharacters = function() return "a" end,
		rawFlags = function() return 0 end,
		getProperty = function(_, property)
			if property == properties.eventSourceUserData then return user_data or 0 end
			if property == properties.eventSourceUnixProcessID then return 4242 end
			return 0
		end,
	}
end

helpers.describe("keymap taps feed the key pairing counters (key-event-pairing)", function()
	helpers.it("counts a tapped key once on each edge", function()
		local fixture = load_fixture()
		fixture.down(physical(fixture, KEYCODE_A, true))
		fixture.up(physical(fixture, KEYCODE_A, false))
		local counts = fixture.health.counts()
		helpers.assert_eq(counts.downs, 1, "the keyDown tap records the press")
		helpers.assert_eq(counts.ups, 1, "the keyUp tap records the release")
		helpers.assert_eq(counts.ups_without_down + counts.downs_without_up, 0)
	end)

	helpers.it("names a key-up that arrives without its key-down and a key-down whose key-up was lost", function()
		local fixture = load_fixture()
		fixture.up(physical(fixture, KEYCODE_E, false))
		fixture.down(physical(fixture, KEYCODE_A, true))
		fixture.down(physical(fixture, KEYCODE_A, true))
		local counts = fixture.health.counts()
		helpers.assert_eq(counts.ups_without_down, 1)
		helpers.assert_eq(counts.downs_without_up, 1)
	end)

	-- A key the keymap tap sees after a main-thread stall may already be in the
	-- application: hotstring work on it deleted or retyped the wrong text
	-- (stale-physical-event).
	helpers.it("passes a key that waited behind the main thread untouched and counts it", function()
		local fixture = load_fixture()
		local host_ns = 3600 * 1e9
		local saved = hs.timer.absoluteTime
		hs.timer.absoluteTime = function() return host_ns end
		local ok, err = pcall(function()
			local function stamped(event, ms_ago)
				local stamp = math.floor(host_ns - ms_ago * 1e6)
				event.timestamp = function() return stamp end
				return event
			end
			fixture.down(stamped(physical(fixture, KEYCODE_E, true), 1))
			fixture.up(stamped(physical(fixture, KEYCODE_E, false), 1))
			local consumed = fixture.down(stamped(physical(fixture, KEYCODE_A, true), 1200))
			helpers.assert_true(consumed ~= true, "a late key reaches the application as typed")
			local counts = fixture.health.counts()
			helpers.assert_eq(counts.stale_passed, 1, "the late key is counted for the next report")
			helpers.assert_eq(counts.late_downs, 1)
		end)
		hs.timer.absoluteTime = saved
		if not ok then error(err, 0) end
	end)

	helpers.it("never counts Ergopti's own tagged output as typing", function()
		local fixture = load_fixture()
		local synthetic = require("adapters.synthetic_input")
		local tx = synthetic.begin("test.key-pairing", "replacement")
		local batch = synthetic.begin_callback(tx)
		synthetic.keyStroke(batch, {}, "a")
		local consume, events = synthetic.finish_callback(batch, true)
		helpers.assert_true(consume)
		helpers.assert_true(synthetic.seal(tx))
		for _, event in ipairs(events) do
			event.getKeyCode = function() return KEYCODE_A end
			event.getFlags = function() return {} end
			event.getCharacters = function() return "a" end
			if event.isDown then fixture.down(event) else fixture.up(event) end
		end
		local counts = fixture.health.counts()
		helpers.assert_eq(counts.downs + counts.ups, 0, "owned events are not physical input")
	end)
end)
