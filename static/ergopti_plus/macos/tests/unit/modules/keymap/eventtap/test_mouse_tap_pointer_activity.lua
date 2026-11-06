--- tests/unit/modules/keymap/eventtap/test_mouse_tap_pointer_activity.lua

--- ==============================================================================
--- MODULE: modules.keymap — pointer and key activity cancel a pending prediction
--- DESCRIPTION:
--- Predictions run only while the user does nothing (maintainer decision
--- 2026-11-06). The keymap mouse tap therefore also sees motion, drags, scroll
--- and trackpad gestures, and the keyDown tap reports every key the tooltip did
--- not own. Scroll used to be excluded because each frame ran
--- check_nav_reset()/reset_predictions() (60 Hz ObjC dispatch, scroll and
--- typing lag): the activity branch now reads one flag while nothing is
--- pending, never resets the hotstring buffer, and never reaches the click reset.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the real keymap with its taps captured and a recording LLM bridge.
--- @return table fixture
local function load_keymap()
	for name in pairs(package.loaded) do
		if type(name) == "string" and (name:match("^modules%.keymap") or name:match("^modules%.llm")
			or name == "adapters.synthetic_input" or name == "adapters.event_provenance") then
			package.loaded[name] = nil
		end
	end
	local calls = { activity = {}, keys = {}, nav_reset = 0 }
	local bridge = { pending = false, owns_key = false }
	package.loaded["modules.keymap.llm_bridge"] = setmetatable({
		init = function() return true end,
		handle_llm_keys = function() return bridge.owns_key end,
		check_escape_reset = function() return false end,
		get_llm_enabled = function() return false end,
		is_runtime_available = function() return true end,
		reset_for_action_epoch = function() return true end,
		check_nav_reset = function() calls.nav_reset = calls.nav_reset + 1 end,
		has_pending_prediction = function() return bridge.pending end,
		note_user_activity = function(reason)
			calls.activity[#calls.activity + 1] = reason
			return true
		end,
		note_key_activity = function(keycode)
			calls.keys[#calls.keys + 1] = keycode
			return bridge.pending
		end,
	}, { __index = function() return function() end end })

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
	local properties = hs_stub.eventtap.event.properties
	local keydown, mouse = nil, nil
	for _, tap in ipairs(taps) do
		if #tap.types == 1 and tap.types[1] == types.keyDown then keydown = tap
		elseif tap.types[1] == types.leftMouseDown then mouse = tap end
	end
	helpers.assert_not_nil(keydown, "the production keyDown tap must be created")
	helpers.assert_not_nil(mouse, "the production mouse tap must be created")

	--- Builds one physical (or owned) event.
	local function event(event_type, fields)
		fields = fields or {}
		return {
			getType = function() return event_type end,
			getKeyCode = function() return fields.keycode or 0 end,
			getFlags = function() return {} end,
			getCharacters = function() return fields.chars or "" end,
			getProperty = function(_self, property)
				if property == properties.eventSourceUserData then return fields.tag or 0 end
				if property == properties.mouseEventDeltaX then return fields.dx or 0 end
				if property == properties.mouseEventDeltaY then return fields.dy or 0 end
				return hs_stub.processInfo.processID
			end,
		}
	end
	return {
		keymap = keymap, calls = calls, bridge = bridge, types = types, mouse = mouse,
		pointer = function(type_name, fields) return mouse.callback(event(types[type_name], fields)) end,
		key = function(keycode, chars)
			return keydown.callback(event(types.keyDown, { keycode = keycode, chars = chars }))
		end,
		cleanup = function()
			for name in pairs(package.loaded) do
				if type(name) == "string" and name:match("^modules%.keymap") then package.loaded[name] = nil end
			end
		end,
	}
end

--- Runs a body against a fresh keymap and always unloads it.
local function with_keymap(body)
	local fixture = load_keymap()
	local ok, err = pcall(fixture.key, 0, "x")
	if ok then ok, err = pcall(body, fixture) end
	fixture.cleanup()
	if not ok then error(err, 0) end
end

local CURSOR_NEUTRAL = { "mouseMoved", "leftMouseDragged", "scrollWheel", "gesture",
	"magnify", "swipe", "rotate", "smartMagnify" }

helpers.describe("keymap mouse tap — pointer activity cancels a pending prediction", function()
	helpers.it("observes motion, drags, scroll and gestures besides the clicks", function()
		with_keymap(function(f)
			local listed = {}
			for _, code in ipairs(f.mouse.types) do listed[code] = true end
			for _, name in ipairs({ "leftMouseDown", "rightMouseDown", "middleMouseDown" }) do
				helpers.assert_true(listed[f.types[name]], name .. " must stay observed")
			end
			for _, name in ipairs(CURSOR_NEUTRAL) do
				helpers.assert_true(listed[f.types[name]], name .. " must be observed")
			end
		end)
	end)

	helpers.it("does nothing but read the flag while no prediction is pending", function()
		with_keymap(function(f)
			f.bridge.pending = false
			for _, name in ipairs(CURSOR_NEUTRAL) do
				helpers.assert_eq(f.pointer(name, { dx = 5, dy = 3 }), false, name .. " passes through")
			end
			helpers.assert_eq(#f.calls.activity, 0)
			helpers.assert_eq(f.calls.nav_reset, 0, "scroll and motion never run the click reset")
		end)
	end)

	helpers.it("cancels on every cursor-neutral activity while a prediction is pending", function()
		with_keymap(function(f)
			f.bridge.pending = true
			for _, name in ipairs(CURSOR_NEUTRAL) do
				helpers.assert_eq(f.pointer(name, { dx = 1, dy = 0 }), false, name .. " is never consumed")
			end
			helpers.assert_eq(#f.calls.activity, #CURSOR_NEUTRAL)
			helpers.assert_eq(f.calls.activity[1], "mouseMoved")
			helpers.assert_eq(f.calls.nav_reset, 0, "motion leaves the caret and the buffer alone")
		end)
	end)

	helpers.it("ignores a zero-distance move", function()
		with_keymap(function(f)
			f.bridge.pending = true
			f.pointer("mouseMoved", { dx = 0, dy = 0 })
			helpers.assert_eq(#f.calls.activity, 0)
		end)
	end)

	helpers.it("still resets on a click", function()
		with_keymap(function(f)
			f.bridge.pending = true
			f.pointer("leftMouseDown")
			helpers.assert_eq(#f.calls.activity, 0, "a click keeps its own full reset")
		end)
	end)
end)

helpers.describe("keymap keyDown tap — keys the tooltip does not own cancel", function()
	helpers.it("reports a key the tooltip did not consume", function()
		with_keymap(function(f)
			f.bridge.pending = true
			f.calls.keys = {}
			f.key(0, "a")
			helpers.assert_eq(#f.calls.keys, 1)
			helpers.assert_eq(f.calls.keys[1], 0)
		end)
	end)

	helpers.it("leaves a key the tooltip consumed (accept, cycle, select) alone", function()
		with_keymap(function(f)
			f.bridge.pending = true
			f.bridge.owns_key = true
			f.calls.keys = {}
			helpers.assert_eq(f.key(48, "\t"), true, "the tooltip consumes Tab")
			helpers.assert_eq(#f.calls.keys, 0, "an accepting key is not cancelling activity")
		end)
	end)
end)
