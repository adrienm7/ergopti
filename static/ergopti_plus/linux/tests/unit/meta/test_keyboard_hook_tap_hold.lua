--- tests/unit/meta/test_keyboard_hook_tap_hold.lua

--- ==============================================================================
--- MODULE: Tap-Holds Through The Keyboard Hook
--- DESCRIPTION:
--- The engine's events must reach the application AND the daemon's own view of
--- the keyboard: a CapsLock held for Ctrl is Ctrl to the virtual keyboard and to
--- the modifier state, an Enter tapped on it is an Enter to the hotstrings, and
--- nothing the engine pressed survives a release request.
--- ==============================================================================

local helpers = require("tests.helpers")
local Engine = require("platform.remap.tap_hold_engine")

local EV_KEY = 1

local KEYS = {
	caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = 10 },
	left_shift = { tap_action = "copy", hold_modifier = "shift", time_activation_seconds = 10 },
	left_alt = { tap_action = "backspace", hold_layer = "nav", time_activation_seconds = 10 },
}

--- Drives events through a fresh hook with the engine installed.
--- @param events table
--- @param extra table|nil callbacks
--- @return table emitted, table taps, table chars, table hook
local function drive(events, extra)
	local kh = helpers.load_module("adapters.keyboard_hook")
	-- A zero minimum tap: the drive has no clock between events.
	local engine = Engine.new({ keys = KEYS, tap_min_ms = 0, one_shot_timeout_ms = 2000 })
	local taps, emitted, chars = {}, {}, {}
	kh.set_remapper(engine, function(action) taps[#taps + 1] = action end)
	local callbacks = {
		onEmitRaw = function(code, value) emitted[#emitted + 1] = code .. ":" .. value; return true end,
		onChar = function(ch) chars[#chars + 1] = ch end,
	}
	for name, fn in pairs(extra and extra(kh) or {}) do callbacks[name] = fn end
	local stream = {}
	for index, pair in ipairs(events) do stream[index] = { type = EV_KEY, code = pair[1], value = pair[2] } end
	kh._test_drive(stream, callbacks, true)
	kh.set_remapper(nil)
	return table.concat(emitted, " "), taps, chars
end

helpers.describe("keyboard hook + tap-hold engine", function()

	helpers.it("sends Ctrl for a held CapsLock, never the lock itself", function()
		local emitted = drive({ { 58, 1 }, { 30, 1 }, { 30, 0 }, { 58, 0 } })
		helpers.assert_eq(emitted, "29:1 30:1 30:0 29:0", "CapsLock+A is Ctrl+A")
	end)

	helpers.it("types a real Enter for a tapped CapsLock, which the hotstrings see", function()
		local emitted, _, chars = drive({ { 58, 1 }, { 58, 0 } })
		helpers.assert_eq(emitted, "29:1 29:0 28:1 28:0")
		helpers.assert_eq(chars[1], "\n", "Enter reached the text path as a terminator")
	end)

	helpers.it("runs the tap action of a lone Shift and nothing after Shift+A", function()
		local _, taps = drive({ { 42, 1 }, { 42, 0 } })
		helpers.assert_eq(taps[1], "copy")
		local _, chord_taps = drive({ { 42, 1 }, { 30, 1 }, { 30, 0 }, { 42, 0 } })
		helpers.assert_eq(#chord_taps, 0)
	end)

	helpers.it("sends navigation chords while the layer key is held, and no Alt", function()
		local emitted = drive({ { 56, 1 }, { 36, 1 }, { 36, 0 }, { 56, 0 } })
		helpers.assert_eq(emitted, "29:1 105:1 105:0 29:0")
	end)

	helpers.it("releases a held Ctrl when asked, mid-hold", function()
		-- Ctrl+A arrives as a shortcut; the release is requested right there,
		-- while CapsLock is still physically down.
		local released_mid_hold = false
		drive({ { 58, 1 }, { 30, 1 } }, function(kh)
			return { onKey = function()
				kh.release_remapped()
				released_mid_hold = true
			end }
		end)
		helpers.assert_true(released_mid_hold, "the shortcut reached the hook")
		local emitted = drive({ { 58, 1 }, { 30, 1 }, { 30, 0 } }, function(kh)
			return { onKey = function() kh.release_remapped() end }
		end)
		helpers.assert_eq(emitted, "29:1 30:1 29:0 30:0", "Ctrl went up at the request, before A")
	end)

	helpers.it("swallows the release of a key the engine took before it was switched off", function()
		local emitted = {}
		drive({ { 58, 1 }, { 58, 0 } }, function(kh)
			return { onEmitRaw = function(code, value)
				emitted[#emitted + 1] = code .. ":" .. value
				if code == 29 and value == 1 then kh.set_remapper(nil) end
				return true
			end }
		end)
		helpers.assert_eq(table.concat(emitted, " "), "29:1 29:0",
			"Ctrl released at the switch, and no CapsLock up nothing pressed")
	end)

	helpers.it("forwards the release of a key pressed before the engine came in", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local emitted = {}
		local engine = Engine.new({ keys = KEYS, tap_min_ms = 0, one_shot_timeout_ms = 2000 })
		kh._test_drive({ { type = EV_KEY, code = 58, value = 1 }, { type = EV_KEY, code = 58, value = 0 } }, {
			onEmitRaw = function(code, value)
				emitted[#emitted + 1] = code .. ":" .. value
				if code == 58 and value == 1 then kh.set_remapper(engine, function() end) end
				return true
			end,
		}, true)
		kh.set_remapper(nil)
		helpers.assert_eq(table.concat(emitted, " "), "58:1 58:0", "the key does not stay down")
	end)


	--- A lone Shift through a 350 ms engine; events are { value, kernel µs, read ms }.
	local function shift_taps(stream)
		local kh = helpers.load_module("adapters.keyboard_hook")
		local engine = Engine.new({ keys = { left_shift = { tap_action = "copy", hold_modifier = "shift",
			time_activation_seconds = 0.35 } }, tap_min_ms = 50, one_shot_timeout_ms = 2000 })
		local taps = {}
		kh.set_remapper(engine, function(action) taps[#taps + 1] = action end)
		local events = {}
		for index, ev in ipairs(stream) do
			events[index] = { type = EV_KEY, code = 42, value = ev[1], timestamp_us = ev[2], at_ms = ev[3] }
		end
		kh._test_drive(events, { onEmitRaw = function() return true end }, true)
		kh.set_remapper(nil)
		return taps
	end

	helpers.it("times a tap by when the keys moved, not by when the daemon read them", function()
		-- Measured in CI: a 100 ms Shift tap, its release read 500 ms after
		-- the press by a daemon busy elsewhere, sent Shift and never copied.
		local taps = shift_taps({ { 1, 1000000000, 0 }, { 0, 1000100000, 500 } })
		helpers.assert_eq(taps[1], "copy", "100 ms between the kernel's stamps is a tap")
		local held = shift_taps({ { 1, 1000000000, 0 }, { 0, 1000500000, 10 } })
		helpers.assert_eq(#held, 0, "500 ms between the stamps is a hold, however fast it was read")
	end)

end)

-- Ctrl+Backspace deletes a word and Alt+Backspace undoes in some
-- applications, but the hook reported both as a bare "backspace": the daemon
-- then undid the last expansion over a word that was already gone, or edited
-- its buffer by one character. The modifiers travel with every control key
-- (modified-backspace-2026-09-25).
helpers.describe("keyboard hook: the modifiers held with a control key", function()

	local EvdevCodes = require("infra.evdev_codes")
	local SHORTCUT_MODIFIERS = { ctrl = 29, alt = 56, meta = 125 }

	--- Drives `events` through a fresh hook and returns every onKey call.
	local function control_keys(events)
		local kh = helpers.load_module("adapters.keyboard_hook")
		local keys = {}
		local stream = {}
		for index, pair in ipairs(events) do stream[index] = { type = EV_KEY, code = pair[1], value = pair[2] } end
		kh._test_drive(stream, {
			captureEvent = function() return nil, nil, nil end,
			onEmitRaw = function() return true end,
			onChar = function() end,
			onKey = function(name, detail) keys[#keys + 1] = { name = name, detail = detail } end,
		}, true)
		return keys
	end

	helpers.it("names the shortcut modifier held with every control key (modified-backspace)", function()
		for code, name in pairs(EvdevCodes.CONTROL_NAME_OF) do
			for role, modifier in pairs(SHORTCUT_MODIFIERS) do
				local keys = control_keys({ { modifier, 1 }, { code, 1 }, { code, 0 }, { modifier, 0 } })
				helpers.assert_eq(#keys, 1, role .. "+" .. name .. " reaches the control callback once")
				helpers.assert_eq(keys[1].name, name)
				local mods = type(keys[1].detail) == "table" and keys[1].detail.mods or {}
				helpers.assert_true(mods[role] == true,
					role .. "+" .. name .. " must say " .. role .. " is held, or it reads as the bare key")
			end
		end
	end)

	helpers.it("names no shortcut modifier with a bare Backspace (modified-backspace)", function()
		local keys = control_keys({ { 14, 1 }, { 14, 0 } })
		helpers.assert_eq(#keys, 1)
		local mods = type(keys[1].detail) == "table" and keys[1].detail.mods or {}
		helpers.assert_true(not mods.ctrl and not mods.alt and not mods.meta, "a bare Backspace is one character")
	end)

	helpers.it("says Ctrl for the Backspace tapped on the layer key while CapsLock holds Ctrl (modified-backspace)", function()
		local keys = {}
		drive({ { 58, 1 }, { 56, 1 }, { 56, 0 }, { 58, 0 } }, function()
			return { onKey = function(name, detail) keys[#keys + 1] = { name = name, detail = detail } end }
		end)
		helpers.assert_eq(#keys, 1, "one Backspace")
		helpers.assert_eq(keys[1].name, "backspace")
		helpers.assert_true(type(keys[1].detail) == "table" and keys[1].detail.mods.ctrl == true,
			"CapsLock's Ctrl is held: this Backspace deletes a word")
	end)

end)

-- A click or a wheel turn during a hold makes it a chord (Ctrl+click,
-- Ctrl+wheel), as on Windows and macOS. Every EV_REL counted, so a hand that
-- merely moved the mouse while tapping CapsLock typed no Enter
-- (pointer-motion-tap-2026-09-25).
helpers.describe("keyboard hook + tap-hold engine: the pointer during a tap", function()

	local InputEvent = require("infra.input_event")
	-- Kernel ABI values (input-event-codes.h), spelled here rather than read
	-- from the driver so a wrong driver constant cannot agree with itself.
	local EV_REL, CAPS, CTRL, ENTER, BTN_LEFT = 2, 58, 29, 28, 0x110
	local REL_AXES = {
		[0] = "REL_X", [1] = "REL_Y", [2] = "REL_Z", [3] = "REL_RX", [4] = "REL_RY", [5] = "REL_RZ",
		[6] = "REL_HWHEEL", [7] = "REL_DIAL", [8] = "REL_WHEEL", [9] = "REL_MISC",
		[11] = "REL_WHEEL_HI_RES", [12] = "REL_HWHEEL_HI_RES",
	}
	local WHEELS = { REL_HWHEEL = true, REL_WHEEL = true, REL_WHEEL_HI_RES = true, REL_HWHEEL_HI_RES = true }

	--- A readable file standing in for a device node.
	local function fake_node(label)
		local path = os.tmpname()
		local fh = assert(io.open(path, "w"))
		fh:write(label)
		fh:close()
		return path
	end

	--- Taps CapsLock on a keyboard while one pointer event arrives between its
	--- press and release, through the real merge of the two sources.
	--- @param clicks table|nil Collects the codes the click callback receives.
	--- @return string What the virtual keyboard received.
	local function tap_with_pointer(ev_type, code, value, clicks)
		local keyboard, pointer = fake_node("keyboard"), fake_node("pointer")
		local queues = {
			[keyboard] = {
				InputEvent.encode(EV_KEY, CAPS, InputEvent.VALUE_DOWN, nil, 1000),
				InputEvent.encode(EV_KEY, CAPS, InputEvent.VALUE_UP, nil, 3000),
			},
			[pointer] = { InputEvent.encode(ev_type, code, value, nil, 2000) },
		}
		local saved = {}
		for _, name in ipairs({ "modules.hotstrings.device_finder", "adapters.xkb_capture" }) do
			saved[name] = package.loaded[name]
		end
		package.loaded["modules.hotstrings.device_finder"] = {
			find_devices = function() return { keyboard }, { pointer } end,
			is_key_device = function() return true, nil end,
		}
		package.loaded["adapters.xkb_capture"] = {
			is_ready = function() return true end,
			reset_state = function() return true end,
			process = function() return nil, nil, nil end,
		}
		local reader = helpers.load_module("adapters.evdev_reader")
		reader._set_backend({
			open = function(path) return path end,
			ioctl = function() return true end,
			read = function(fd) return table.remove(queues[fd] or {}, 1) end,
			poll = function() return false end,
			close = function() end,
		})
		local kh = helpers.load_module("adapters.keyboard_hook")
		local emitted = {}
		local ok, err = pcall(function()
			kh.set_remapper(Engine.new({ keys = KEYS, tap_min_ms = 0, one_shot_timeout_ms = 2000 }),
				function() end)
			kh.start({
				intercept = true,
				onEmitRaw = function(key, key_value) emitted[#emitted + 1] = key .. ":" .. key_value; return true end,
				onClick = function(button) if clicks then clicks[#clicks + 1] = tostring(button) end end,
			})
			kh.pump()
		end)
		kh.set_remapper(nil)
		kh.stop()
		reader._reset_backend()
		for name, module in pairs(saved) do package.loaded[name] = module end
		os.remove(keyboard)
		os.remove(pointer)
		assert(ok, err)
		return table.concat(emitted, " ")
	end

	local TAPPED = CTRL .. ":1 " .. CTRL .. ":0 " .. ENTER .. ":1 " .. ENTER .. ":0"
	local CHORD = CTRL .. ":1 " .. CTRL .. ":0"

	helpers.it("keeps the tap across pointer motion and cancels it on a wheel turn (pointer-motion-tap)", function()
		for code, name in pairs(REL_AXES) do
			local expected = WHEELS[name] and CHORD or TAPPED
			helpers.assert_eq(tap_with_pointer(EV_REL, code, 1), expected,
				name .. (WHEELS[name] and " is a wheel turn: Ctrl+wheel, no Enter"
					or " is not a wheel: the CapsLock tap still types Enter"))
		end
	end)

	-- Every button of a mouse (BTN_MISC 0x100 to 0x11f), and the codes a
	-- touchpad reports for a finger or a tool landing (BTN_DIGI 0x140 and up).
	local BUTTONS = {
		[0x100] = "BTN_0", [0x109] = "BTN_9", [BTN_LEFT] = "BTN_LEFT", [0x111] = "BTN_RIGHT",
		[0x112] = "BTN_MIDDLE", [0x113] = "BTN_SIDE", [0x114] = "BTN_EXTRA", [0x115] = "BTN_FORWARD",
		[0x116] = "BTN_BACK", [0x117] = "BTN_TASK", [0x11f] = "the last button code",
	}
	local CONTACTS = {
		[0x140] = "BTN_TOOL_PEN", [0x145] = "BTN_TOOL_FINGER", [0x14a] = "BTN_TOUCH",
		[0x14d] = "BTN_TOOL_DOUBLETAP", [0x14e] = "BTN_TOOL_TRIPLETAP", [0x14f] = "BTN_TOOL_QUADTAP",
	}

	helpers.it("cancels the tap on a button press and on its release, as on Windows (pointer-motion-tap)", function()
		for code, name in pairs(BUTTONS) do
			helpers.assert_eq(tap_with_pointer(EV_KEY, code, InputEvent.VALUE_DOWN), CHORD,
				name .. " pressed: Ctrl+click, no Enter")
			-- Windows' hook cancels on every button's release too (_OnLUp ...
			-- _OnX2Up): a click that began before the tap ends inside it.
			helpers.assert_eq(tap_with_pointer(EV_KEY, code, InputEvent.VALUE_UP), CHORD,
				name .. " released: a click ending inside the tap, no Enter")
		end
	end)

	helpers.it("keeps the tap when a finger lands on or leaves a touchpad (pointer-motion-tap)", function()
		for code, name in pairs(CONTACTS) do
			for _, value in ipairs({ InputEvent.VALUE_DOWN, InputEvent.VALUE_UP }) do
				helpers.assert_eq(tap_with_pointer(EV_KEY, code, value), TAPPED,
					name .. " " .. value .. " is a contact, not a click: the CapsLock tap still types Enter")
			end
		end
	end)

	helpers.it("resets the typing buffer on a button press only, never on its release (pointer-motion-tap)", function()
		for code, name in pairs(BUTTONS) do
			local clicks = {}
			tap_with_pointer(EV_KEY, code, InputEvent.VALUE_DOWN, clicks)
			helpers.assert_eq(table.concat(clicks, " "), tostring(code), name .. " pressed is one click")
			clicks = {}
			tap_with_pointer(EV_KEY, code, InputEvent.VALUE_UP, clicks)
			helpers.assert_eq(#clicks, 0, name .. " released is no second click")
		end
	end)

	-- With tap-to-click the kernel reports a touch and no BTN_LEFT, and the
	-- touch still moves the caret: the daemon's click callback invalidates the
	-- password-field verdict and the typing buffer on it. Only the tap-hold
	-- keeps its tap (touch-still-clicks).
	helpers.it("still reports a touch as a click to the daemon while the tap survives it (touch-still-clicks)", function()
		for code, name in pairs(CONTACTS) do
			local clicks = {}
			helpers.assert_eq(tap_with_pointer(EV_KEY, code, InputEvent.VALUE_DOWN, clicks), TAPPED,
				name .. " pressed: the CapsLock tap still types Enter")
			helpers.assert_eq(table.concat(clicks, " "), tostring(code),
				name .. " pressed may be a tap-to-click: the click callback must run once")
			clicks = {}
			tap_with_pointer(EV_KEY, code, InputEvent.VALUE_UP, clicks)
			helpers.assert_eq(#clicks, 0, name .. " released is no second click")
		end
	end)

end)
