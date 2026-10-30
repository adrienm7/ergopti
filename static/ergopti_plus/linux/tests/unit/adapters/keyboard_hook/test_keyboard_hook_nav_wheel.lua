--- tests/unit/adapters/keyboard_hook/test_keyboard_hook_nav_wheel.lua

--- ==============================================================================
--- MODULE: The Navigation Layer's Wheel Through The Keyboard Hook
--- DESCRIPTION:
--- The recommended layer makes the wheel the volume while its key is held, as on
--- Windows and macOS. A bound notch must reach the desktop as the volume key and
--- never also scroll, so the hook takes the mouse for the hold only: every other
--- report of it (motion, a click, an unbound direction) goes on through the
--- virtual device, and the grab ends with the layer, after the last forwarded
--- button is released. A touchpad is never taken.
---
--- The real reader, hook, engine and layer compiler run over a controlled
--- syscall backend (no device, no kernel): this is the hardware-free harness of
--- the pointer-during-a-tap tests, with a mouse capability mask.
--- ==============================================================================

local helpers = require("tests.helpers")
local Engine = require("platform.remap.tap_hold_engine")
local InputEvent = require("infra.input_event")

-- Kernel ABI values (input-event-codes.h), spelled here rather than read from
-- the driver so a wrong driver constant cannot agree with itself.
local EV_KEY, EV_REL, EV_SYN = 1, 2, 0
local LEFT_ALT, KEY_K, VOLUME_UP, VOLUME_DOWN = 56, 37, 115, 114
local BTN_LEFT, REL_X, REL_WHEEL, REL_HWHEEL, REL_WHEEL_HI_RES = 0x110, 0, 8, 6, 11
local EVIOCGRAB = 0x40044590

local KEYS = { left_alt = { tap_action = "backspace", hold_layer = "nav", time_activation_seconds = 10 } }

--- EVIOCGBIT(0) bytes: SYN, KEY, MSC for a keyboard; SYN, KEY, REL for a mouse;
--- SYN, KEY, ABS for a touchpad.
local MASKS = { keyboard = string.char(19, 0, 18, 0), mouse = string.char(7, 0, 0, 0), touchpad = string.char(11, 0, 0, 0) }

local function fake_node(label)
	local path = os.tmpname()
	local fh = assert(io.open(path, "w"))
	fh:write(label)
	fh:close()
	return path
end

--- A navigation layer with the wheel as the volume, as the recommended one has,
--- compiled by the production compiler against the shared key registry.
local function wheel_layer()
	local ctx = require("keymap.layers").load_context({
		shared_root = helpers.driver_root() .. "/../_shared", json_decode = require("json").decode,
		toml_decode = require("toml_codec").decode, read_file = require("keymap.layer_editor").read_shipped,
	})
	local function key(name) return { kind = "keystroke", chords = { { mods = {}, key = name } } } end
	return require("platform.remap.nav_layer").compile({
		WheelUp = key("AudioVolumeUp"), WheelDown = key("AudioVolumeDown"), KeyJ = key("ArrowLeft"),
	}, ctx.registry)
end

--- Runs a keyboard and a pointer through the hook with the layer engine installed.
--- @param pointer_kind string "mouse" or "touchpad"
--- @param keyboard_events table { {code, value, at_us} }
--- @param pointer_events table { {type, code, value, at_us} }
--- @return table emitted { "key:code:value" | "rel:axis:value" }, table grabs { [path] = {on, off} }
local function drive(pointer_kind, keyboard_events, pointer_events)
	local keyboard, pointer = fake_node("keyboard"), fake_node(pointer_kind)
	local queues = { [keyboard] = {}, [pointer] = {} }
	for _, ev in ipairs(keyboard_events) do
		queues[keyboard][#queues[keyboard] + 1] = InputEvent.encode(EV_KEY, ev[1], ev[2], nil, ev[3])
	end
	for _, ev in ipairs(pointer_events) do
		queues[pointer][#queues[pointer] + 1] = InputEvent.encode(ev[1], ev[2], ev[3], nil, ev[4])
	end
	local grabs = { [keyboard] = { on = 0, off = 0 }, [pointer] = { on = 0, off = 0 } }
	local doubled, saved = { "modules.hotstrings.device_finder", "adapters.xkb_capture" }, {}
	for _, name in ipairs(doubled) do saved[name] = package.loaded[name] end
	package.loaded["modules.hotstrings.device_finder"] = {
		find_devices = function() return { keyboard }, { pointer } end,
		is_key_device = function() return true, nil end,
		is_interceptable_key_device = function() return true, nil end,
		is_interceptable_event_mask = require("tests.support.evdev_capabilities_fixture").policy,
	}
	package.loaded["adapters.xkb_capture"] = {
		is_ready = function() return true end,
		reset_state = function() return true end,
		process = function() return nil, nil, nil end,
		modifier_role = function(code) return require("infra.evdev_codes").MODIFIER_OF[code], nil end,
	}
	local reader = helpers.load_module("adapters.evdev_reader")
	reader._set_backend({
		read_event_bits = function(fd) return fd == pointer and MASKS[pointer_kind] or MASKS.keyboard end,
		open = function(path) return path end,
		ioctl = function(fd, request, value)
			if request == EVIOCGRAB and grabs[fd] then
				if value == 1 then grabs[fd].on = grabs[fd].on + 1 else grabs[fd].off = grabs[fd].off + 1 end
			end
			return true
		end,
		read = function(fd) return table.remove(queues[fd] or {}, 1) end,
		poll = function() return false end,
		close = function() end,
	})
	local kh = helpers.load_module("adapters.keyboard_hook")
	local emitted = {}
	local ok, err = pcall(function()
		kh.set_remapper(Engine.new({ keys = KEYS, tap_min_ms = 0, one_shot_timeout_ms = 2000,
			nav_layer = wheel_layer() }), function() end)
		kh.start({
			intercept = true,
			onEmitRaw = function(code, value) emitted[#emitted + 1] = "key:" .. code .. ":" .. value; return true end,
			onEmitRelative = function(axis, value) emitted[#emitted + 1] = "rel:" .. axis .. ":" .. value; return true end,
			onClick = function() end,
		})
		kh.pump()
	end)
	kh.set_remapper(nil)
	kh.stop()
	reader._reset_backend()
	-- By name: an absent original must become absent again, which pairs() would skip.
	for _, name in ipairs(doubled) do package.loaded[name] = saved[name] end
	os.remove(keyboard)
	os.remove(pointer)
	assert(ok, err)
	return emitted, grabs[pointer]
end

local function has(list, item)
	for _, value in ipairs(list) do if value == item then return true end end
	return false
end

local function count(list, item)
	local found = 0
	for _, value in ipairs(list) do if value == item then found = found + 1 end end
	return found
end

-- The layer key goes down at 1 ms and up at 9 ms; the pointer reports fall between.
local HOLD = { { LEFT_ALT, 1, 1000 }, { LEFT_ALT, 0, 9000 } }

helpers.describe("keyboard hook: the navigation layer's wheel (layer-wheel-linux)", function()
	helpers.it("compiles a wheel direction under its own code, never a key's", function()
		local layer = wheel_layer()
		local up = layer[InputEvent.wheel_layer_code("vertical", 1)]
		local down = layer[InputEvent.wheel_layer_code("vertical", -1)]
		helpers.assert_eq(up and up.chords and up.chords[1].keys[1], VOLUME_UP, "WheelUp is volume up")
		helpers.assert_eq(down and down.chords and down.chords[1].keys[1], VOLUME_DOWN, "WheelDown is volume down")
		helpers.assert_true(InputEvent.wheel_layer_code("vertical", 1) > 0x2ff, "above every evdev key code")
	end)

	helpers.it("turns each bound notch into the volume key and never scrolls", function()
		local emitted, grabs = drive("mouse", HOLD, {
			{ EV_REL, REL_WHEEL_HI_RES, 240, 3000 }, { EV_REL, REL_WHEEL, 2, 3000 }, { EV_SYN, 0, 0, 3000 },
			{ EV_REL, REL_WHEEL, -1, 4000 }, { EV_SYN, 0, 0, 4000 },
		})
		helpers.assert_eq(count(emitted, "key:" .. VOLUME_UP .. ":1"), 2, "two notches up, two volume-up presses")
		helpers.assert_eq(count(emitted, "key:" .. VOLUME_UP .. ":0"), 2)
		helpers.assert_eq(count(emitted, "key:" .. VOLUME_DOWN .. ":1"), 1, "one notch down")
		for _, item in ipairs(emitted) do
			helpers.assert_true(not item:find("^rel:" .. REL_WHEEL .. ":") and not item:find("^rel:" .. REL_WHEEL_HI_RES .. ":"),
				"a bound notch does not also scroll: " .. item)
		end
		helpers.assert_eq(grabs.on, 1, "the mouse is taken for the hold")
		helpers.assert_eq(grabs.off, 1, "and given back when the layer ends")
		helpers.assert_true(not has(emitted, "key:" .. LEFT_ALT .. ":1"), "the layer key itself types nothing")
	end)

	helpers.it("forwards the mouse's motion, clicks and unbound directions during the hold", function()
		local emitted = drive("mouse", HOLD, {
			{ EV_REL, REL_X, 5, 3000 }, { EV_SYN, 0, 0, 3000 },
			{ EV_KEY, BTN_LEFT, 1, 3500 }, { EV_SYN, 0, 0, 3500 },
			{ EV_KEY, BTN_LEFT, 0, 4000 }, { EV_SYN, 0, 0, 4000 },
			{ EV_REL, REL_HWHEEL, 1, 4500 }, { EV_SYN, 0, 0, 4500 },
		})
		helpers.assert_true(has(emitted, "rel:" .. REL_X .. ":5"), "motion goes on: " .. table.concat(emitted, " "))
		helpers.assert_true(has(emitted, "key:" .. BTN_LEFT .. ":1") and has(emitted, "key:" .. BTN_LEFT .. ":0"),
			"the click goes on")
		helpers.assert_true(has(emitted, "rel:" .. REL_HWHEEL .. ":1"), "a direction the layer leaves alone scrolls")
	end)

	helpers.it("keeps the mouse until a button pressed under the layer is released", function()
		local emitted, grabs = drive("mouse", HOLD, {
			{ EV_KEY, BTN_LEFT, 1, 3000 }, { EV_SYN, 0, 0, 3000 },
			{ EV_KEY, BTN_LEFT, 0, 9500 }, { EV_SYN, 0, 0, 9500 },
		})
		helpers.assert_true(has(emitted, "key:" .. BTN_LEFT .. ":0"),
			"the release after the layer ended still reaches the virtual device that has the button down")
		helpers.assert_eq(grabs.off, 1, "the mouse is given back once, after its button")
	end)

	helpers.it("leaves the wheel and the mouse alone outside the layer and under an unbound key", function()
		local emitted, grabs = drive("mouse", { { KEY_K, 1, 1000 }, { KEY_K, 0, 9000 } }, {
			{ EV_REL, REL_WHEEL, 1, 3000 }, { EV_SYN, 0, 0, 3000 },
		})
		helpers.assert_eq(grabs.on, 0, "no layer, no grab")
		helpers.assert_true(not has(emitted, "key:" .. VOLUME_UP .. ":1"), "the wheel scrolls as usual")
		helpers.assert_true(not has(emitted, "rel:" .. REL_WHEEL .. ":1"), "and is not forwarded: the desktop saw it")
	end)

	helpers.it("never takes a touchpad", function()
		local emitted, grabs = drive("touchpad", HOLD, { { EV_REL, REL_WHEEL, 1, 3000 }, { EV_SYN, 0, 0, 3000 } })
		helpers.assert_eq(grabs.on, 0, "a touchpad scrolls with its fingers and is not taken")
		helpers.assert_true(not has(emitted, "key:" .. VOLUME_UP .. ":1"))
	end)
end)
