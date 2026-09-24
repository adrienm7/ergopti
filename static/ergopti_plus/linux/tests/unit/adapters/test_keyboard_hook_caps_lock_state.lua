--- tests/unit/adapters/test_keyboard_hook_caps_lock_state.lua

--- ==============================================================================
--- MODULE: Keyboard Hook CapsLock State
--- DESCRIPTION:
--- The diagnostics window shows whether CapsLock is locked. The daemon forwards
--- CapsLock and keeps no lock state of its own, so keyboard_hook.caps_lock_on()
--- asks the kernel for the LED of the keyboard it reads.
---
--- WHY THIS IS THE ASSERTION:
--- An unlocked CapsLock is a successful false, not a failure; a query the
--- kernel refuses, or no keyboard open at all, is an unknown state with its
--- reason, never a guessed false the window would show as a measurement.
--- ==============================================================================

local helpers = require("tests.helpers")

-- The CapsLock LED code, as <linux/input-event-codes.h> numbers it
local LED_CAPSL = 1

--- Loads the hook with a validated XKB-state stub and a finder that accepts
--- the synthetic node, as the device watchdog tests do. start() requires the
--- finder lazily, so both stubs stay installed until restore() is called.
--- @return table keyboard_hook
--- @return function restore Puts the real modules back.
local function load_hook()
	local saved = {
		xkb = package.loaded["adapters.xkb_capture"],
		finder = package.loaded["modules.hotstrings.device_finder"],
	}
	package.loaded["adapters.xkb_capture"] = {
		is_ready = function() return true end,
		reset_state = function() return true end,
		process = function() return nil, nil, nil end,
	}
	package.loaded["modules.hotstrings.device_finder"] = {
		find_keyboard = function() return nil end,
		is_key_device = function() return true, nil end,
	}
	return helpers.load_module("adapters.keyboard_hook"), function()
		package.loaded["adapters.xkb_capture"] = saved.xkb
		package.loaded["modules.hotstrings.device_finder"] = saved.finder
	end
end

--- Creates a readable file to stand in for a device node.
--- @return string path
local function fake_node()
	local path = os.tmpname()
	local fh = assert(io.open(path, "w"))
	fh:write("caps")
	fh:close()
	return path
end

--- A syscall backend whose LED answer can change between queries. A one-byte
--- request is the LED bitset; the wider ones are the pressed-key bitset.
--- @return table backend
--- @return function set_leds (byte|nil, err|nil)
local function backend()
	local leds, leds_err = "\0", nil
	return {
		open = function(path) return path end,
		ioctl = function() return true end,
		read = function() return nil end,
		poll = function() return false end,
		close = function() end,
		read_bits = function(_, _, count)
			if count ~= 1 then return string.rep("\0", count) end
			if leds == nil then return nil, leds_err end
			return leds
		end,
	}, function(next_leds, next_err) leds, leds_err = next_leds, next_err end
end

helpers.describe("keyboard_hook: caps_lock_on reads the keyboard's LED", function()
	helpers.it("answers true and false from the open keyboard, without guessing", function()
		local node = fake_node()
		local reader = helpers.load_module("adapters.evdev_reader")
		local syscalls, set_leds = backend()
		reader._set_backend(syscalls)
		local kh, restore = load_hook()
		kh.start({ device = node, intercept = true, onEmitRaw = function() return true end })
		helpers.assert_true(kh.isRunning(), "the hook must start on the synthetic keyboard")

		set_leds(string.char(2 ^ LED_CAPSL))
		local on, on_err = kh.caps_lock_on()
		helpers.assert_eq(on, true, "a lit CapsLock LED is a locked CapsLock")
		helpers.assert_nil(on_err)

		set_leds("\0")
		local off, off_err = kh.caps_lock_on()
		helpers.assert_eq(off, false, "an unlit LED is a successful false, not a failure")
		helpers.assert_nil(off_err)

		set_leds(nil, "EIO")
		local unknown, why = kh.caps_lock_on()
		helpers.assert_nil(unknown, "a refused query must not read as unlocked")
		helpers.assert_contains(why, "EIO")

		kh.stop()
		local closed, closed_err = kh.caps_lock_on()
		helpers.assert_nil(closed, "no open keyboard means no answer")
		helpers.assert_contains(closed_err, "no keyboard is open")
		reader._reset_backend()
		restore()
		os.remove(node)
	end)
end)
