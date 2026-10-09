--- tests/unit/modules/keymap/test_cmdv_paste_counter_order.lua

--- ==============================================================================
--- MODULE: Cmd+V physical/synthetic provenance separation
--- DESCRIPTION:
--- Drives the production keymap callback with a real adapter-built Cmd+V batch.
--- Immutable Quartz tags must filter our paste without invalidating the typing
--- context, while a genuinely physical Cmd+V must invalidate that context.
--- ==============================================================================

local helpers = require("tests.helpers")

local CURRENT_PID = 7001
local KEYCODE_A = 0
local KEYCODE_V = 9


local function modifier_flags(modifiers)
	local flags = {}
	for key, value in pairs(modifiers or {}) do
		if type(key) == "number" then flags[value] = true
		elseif value == true then flags[key] = true end
	end
	return flags
end


local function decorate_key_event(event, key, is_down)
	event.getType = function()
		return is_down and hs.eventtap.event.types.keyDown
			or hs.eventtap.event.types.keyUp
	end
	event.getKeyCode = function()
		if type(key) == "number" then return key end
		if key == "v" then return KEYCODE_V end
		return KEYCODE_A
	end
	event.getFlags = function(self) return modifier_flags(self.mods) end
	event.getCharacters = function(self)
		if self.unicode ~= nil then return self.unicode end
		return type(key) == "string" and #key == 1 and key or ""
	end
	return event
end


local function load_fixture()
	for name in pairs(package.loaded) do
		if type(name) == "string" and (
			name:match("^modules%.keymap")
			or name:match("^modules%.llm")
			or name:match("^modules%.keylogger")
			or name:match("^ui%.tooltip")
			or name:match("^adapters%.")
			or name:match("^infra%.")
		) then
			package.loaded[name] = nil
		end
	end

	package.loaded["tests.stubs.hs"] = nil
	local base_hs = require("tests.stubs.hs")
	base_hs.__reset()
	local base_eventtap = base_hs.eventtap
	local native_new_key_event = base_eventtap.event.newKeyEvent
	local taps = {}
	local eventtap = {}
	for key, value in pairs(base_eventtap) do eventtap[key] = value end
	eventtap.event = {}
	for key, value in pairs(base_eventtap.event) do eventtap.event[key] = value end
	eventtap.event.newKeyEvent = function(modifiers, key, is_down)
		return decorate_key_event(native_new_key_event(modifiers, key, is_down), key, is_down)
	end
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

	local keymap = helpers.load_with_stubs("modules.keymap", {
		eventtap = eventtap,
		processInfo = { processID = CURRENT_PID },
	})
	-- This fixture invokes the tap in its reachable post-prewarm state; leaving
	-- the unrelated AX cache unknown correctly quarantines production input but
	-- would prevent this provenance test from reaching either paste branch.
	local Utils = require("modules.keymap.utils")
	Utils.is_ignored_window = function() return false, 1 end
	Utils.is_secure_field = function() return false, 1 end
	local hs_stub = require("hs")
	local callback = nil
	for _, tap in ipairs(taps) do
		if #tap.types == 1 and tap.types[1] == hs_stub.eventtap.event.types.keyDown then
			callback = tap.callback
			break
		end
	end
	helpers.assert_not_nil(callback, "the production keyDown callback must exist")
	return {
		keymap = keymap,
		synthetic = require("adapters.synthetic_input"),
		hs = hs_stub,
		handle = callback,
	}
end


local function physical_event(fixture, chars, keycode, flags)
	local properties = fixture.hs.eventtap.event.properties
	return {
		getType = function() return fixture.hs.eventtap.event.types.keyDown end,
		getKeyCode = function() return keycode or KEYCODE_A end,
		getFlags = function() return flags or {} end,
		getCharacters = function() return chars end,
		getProperty = function(_, property)
			if property == properties.eventSourceUserData then return 0 end
			if property == properties.eventSourceUnixProcessID then return CURRENT_PID end
			return 0
		end,
	}
end


local function tagged_paste(fixture)
	local tx = fixture.synthetic.begin("test.cmdv", "replacement")
	local batch = fixture.synthetic.begin_callback(tx)
	fixture.synthetic.keyStroke(batch, { "cmd" }, "v")
	local consume, events = fixture.synthetic.finish_callback(batch, true)
	fixture.synthetic.seal(tx)
	helpers.assert_true(consume)
	helpers.assert_eq(#events, 2)
	return events
end


helpers.describe("keymap Cmd+V uses exact event provenance", function()
	helpers.it("filters a tagged paste while a physical paste invalidates context", function()
		local fixture = load_fixture()
		local observed = {}
		fixture.keymap.register_interceptor(function(_event, buffer, context)
			if context and context.chars == "~" then observed[#observed + 1] = buffer end
			return nil
		end)

		fixture.handle(physical_event(fixture, "q"))
		local events = tagged_paste(fixture)
		local property = fixture.hs.eventtap.event.properties.eventSourceUserData
		local metadata = fixture.synthetic.lookup_tag(events[1]:getProperty(property))
		helpers.assert_eq(metadata.owner, "test.cmdv")
		helpers.assert_eq(metadata.effect, "replacement")
		helpers.assert_eq(metadata.phase, "down")
		fixture.handle(events[1])
		fixture.handle(physical_event(fixture, "~"))

		fixture.handle(physical_event(fixture, "v", KEYCODE_V, { cmd = true }))
		fixture.handle(physical_event(fixture, "z"))
		fixture.handle(physical_event(fixture, "~"))

		helpers.assert_eq(observed[1], "q",
			"our tagged Cmd+V must not erase the context it did not physically edit")
		helpers.assert_eq(observed[2], "z",
			"a physical Cmd+V must invalidate prior context before the next character")
	end)
end)
