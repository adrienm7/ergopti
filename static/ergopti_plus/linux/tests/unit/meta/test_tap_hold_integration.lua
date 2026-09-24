--- tests/unit/meta/test_tap_hold_integration.lua

--- ==============================================================================
--- MODULE: Tap-Holds End To End (hook, manager, writer, shared defaults)
--- DESCRIPTION:
--- The real keyboard hook with the real manager on the shipped defaults and the
--- production timings, fed timestamped key streams; the real writer changing the
--- user's file as the tray does. Each case reads what the desktop would receive
--- and which actions ran, and every stream must leave no key down: a stuck Ctrl
--- is the failure a user notices first and forgives last.
--- ==============================================================================

local helpers = require("tests.helpers")

local DEFAULTS = require("infra.paths").shared("tap_hold/defaults.toml")
local EV_KEY = 1
local DOWN, UP, REPEAT = 1, 0, 2

local CAPS, LSHIFT, LCTRL, LALT, RCTRL, ALTGR, TAB = 58, 42, 29, 56, 97, 100, 15
local KEY_A, KEY_J, KEY_K, KEY_U = 30, 36, 37, 22

--- Starts a hook + manager + writer session on a user file holding `user_text`.
local function session(user_text)
	local Hook = helpers.load_module("adapters.keyboard_hook")
	local Manager = helpers.load_module("platform.remap.tap_hold_manager")
	local Writer = helpers.load_module("platform.remap.tap_hold_writer")
	local path = os.tmpname()
	if user_text then
		local fh = assert(io.open(path, "w"))
		fh:write(user_text)
		fh:close()
	else
		os.remove(path)
	end
	local actions = {}
	Manager.init({
		keyboard_hook = Hook,
		execute_action = function(action) actions[#actions + 1] = action end,
		action_names = function() return { "open_url" } end,
		defaults_path = DEFAULTS,
		user_path = path,
	})
	Writer.init({
		path = path,
		reload = Manager.reload,
		is_tap_action = Manager.is_tap_action,
		is_hold_option = Manager.is_hold_option,
	})
	local s = { hook = Hook, manager = Manager, writer = Writer, actions = actions }

	--- Drives { code, value, at_ms } events; returns "code:value …" and the chars.
	function s.drive(events)
		local emitted, chars, stream = {}, {}, {}
		for index, e in ipairs(events) do
			stream[index] = { type = EV_KEY, code = e[1], value = e[2], at_ms = e[3] }
		end
		Hook._test_drive(stream, {
			onEmitRaw = function(code, value) emitted[#emitted + 1] = code .. ":" .. value; return true end,
			onChar = function(ch) chars[#chars + 1] = ch end,
		}, true)
		s.last = emitted
		return table.concat(emitted, " "), chars
	end

	function s.close()
		Manager._reset_for_test()
		Writer._reset_for_test()
		os.remove(path)
	end
	return s
end

--- Asserts every key the stream pressed was released, and none was pressed
--- twice: the kernel keeps one bit per key, so a second press followed by one
--- release lifts a key another hold still needs.
local function assert_balanced(emitted)
	local down = {}
	for _, pair in ipairs(emitted) do
		local code, value = pair:match("^(%d+):(%d+)$")
		if value == "1" then
			helpers.assert_true(not down[code], "key " .. code .. " pressed while already down")
			down[code] = true
		elseif value == "0" then
			down[code] = nil
		end
	end
	local left = {}
	for code in pairs(down) do left[#left + 1] = code end
	table.sort(left)
	helpers.assert_eq(table.concat(left, ","), "", "keys left down")
end

--- Runs `body(s)` in a session and always closes it.
local function with_session(user_text, body)
	local s = session(user_text)
	local ok, err = pcall(body, s)
	s.close()
	if not ok then error(err, 0) end
end

--- A tap of `code`: down at `at`, up `ms` later.
local function tap(code, at, ms)
	return { code, DOWN, at }, { code, UP, at + (ms or 100) }
end




-- =========================================
-- =========================================
-- ======= 1/ The shipped defaults =========
-- =========================================
-- =========================================

helpers.describe("tap-holds end to end: the shipped defaults", function()

	helpers.it("copies on a Shift tap and pastes on a left Ctrl tap", function()
		with_session(nil, function(s)
			local down, up = tap(LSHIFT, 0)
			s.drive({ down, up })
			assert_balanced(s.last)
			local cdown, cup = tap(LCTRL, 1000)
			s.drive({ cdown, cup })
			helpers.assert_eq(table.concat(s.actions, ","), "copy,paste")
		end)
	end)

	helpers.it("ignores a bounce below the minimum and a hold past the threshold", function()
		with_session(nil, function(s)
			s.drive({ { LSHIFT, DOWN, 0 }, { LSHIFT, UP, 20 } })
			s.drive({ { LSHIFT, DOWN, 1000 }, { LSHIFT, UP, 1600 } })
			helpers.assert_eq(#s.actions, 0)
			assert_balanced(s.last)
		end)
	end)

	helpers.it("types Shift+A, not a copy, for a Shift chord", function()
		with_session(nil, function(s)
			local emitted = s.drive({ { LSHIFT, DOWN, 0 }, { KEY_A, DOWN, 30 }, { KEY_A, UP, 60 }, { LSHIFT, UP, 90 } })
			helpers.assert_eq(emitted, "42:1 30:1 30:0 42:0")
			helpers.assert_eq(#s.actions, 0)
		end)
	end)

	helpers.it("makes CapsLock Ctrl when held and a hotstring-ending Enter when tapped", function()
		with_session(nil, function(s)
			local held = s.drive({ { CAPS, DOWN, 0 }, { KEY_A, DOWN, 100 }, { KEY_A, UP, 150 }, { CAPS, UP, 600 } })
			helpers.assert_eq(held, "29:1 30:1 30:0 29:0")
			local tapped, chars = s.drive({ tap(CAPS, 1000) })
			helpers.assert_eq(tapped, "29:1 29:0 28:1 28:0")
			helpers.assert_eq(chars[#chars], "\n")
		end)
	end)

	helpers.it("never lets CapsLock toggle the lock, however long it is held", function()
		with_session(nil, function(s)
			local emitted = s.drive({ { CAPS, DOWN, 0 }, { CAPS, REPEAT, 500 }, { CAPS, REPEAT, 530 }, { CAPS, UP, 900 } })
			helpers.assert_true(not emitted:find("58:", 1, true), emitted)
			assert_balanced(s.last)
		end)
	end)

	helpers.it("runs the navigation layer on left Alt, with repeats and no Alt", function()
		with_session(nil, function(s)
			local emitted = s.drive({
				{ LALT, DOWN, 0 },
				{ KEY_K, DOWN, 50 }, { KEY_K, REPEAT, 400 }, { KEY_K, UP, 450 },
				{ KEY_U, DOWN, 500 }, { KEY_U, UP, 550 },
				{ LALT, UP, 600 },
			})
			helpers.assert_eq(emitted, "105:1 105:2 105:0 29:1 42:1 105:1 105:0 42:0 29:0")
			helpers.assert_eq(#s.actions, 0, "a used layer is not a Backspace tap")
		end)
	end)

	helpers.it("types Backspace for a lone left Alt tap", function()
		with_session(nil, function(s)
			helpers.assert_eq(s.drive({ tap(LALT, 0) }), "14:1 14:0")
		end)
	end)

	helpers.it("shifts the next letter after a right Ctrl tap, once", function()
		with_session(nil, function(s)
			local d, u = tap(RCTRL, 0)
			local emitted = s.drive({ d, u, { KEY_A, DOWN, 300 }, { KEY_A, UP, 350 },
				{ KEY_A, DOWN, 400 }, { KEY_A, UP, 450 } })
			helpers.assert_eq(emitted, "42:1 42:0 42:1 30:1 30:0 42:0 30:1 30:0")
		end)
	end)

	helpers.it("sends Alt+Tab for a Tab tap and Shift+Tab under Shift", function()
		with_session(nil, function(s)
			s.drive({ tap(TAB, 0) })
			helpers.assert_eq(s.actions[1], "alt_tab_monitor")
			local emitted = s.drive({ { LSHIFT, DOWN, 1000 }, { TAB, DOWN, 1050 }, { TAB, UP, 1100 }, { LSHIFT, UP, 1150 } })
			helpers.assert_eq(emitted, "42:1 15:1 15:0 42:0", "focus goes back a field")
			helpers.assert_eq(#s.actions, 1, "no window switch under Shift")
		end)
	end)

	helpers.it("holds AltGr as AltGr and taps it as Tab", function()
		with_session(nil, function(s)
			helpers.assert_eq(s.drive({ tap(ALTGR, 0) }), "100:1 100:0 15:1 15:0")
		end)
	end)

	helpers.it("keeps Ctrl down while CapsLock or left Ctrl still holds it", function()
		with_session(nil, function(s)
			local emitted = s.drive({ { CAPS, DOWN, 0 }, { LCTRL, DOWN, 30 }, { LCTRL, UP, 500 },
				{ KEY_A, DOWN, 550 }, { KEY_A, UP, 580 }, { CAPS, UP, 700 } })
			helpers.assert_eq(emitted, "29:1 30:1 30:0 29:0", "one Ctrl, lifted by the last holder")
			assert_balanced(s.last)
		end)
	end)

	helpers.it("gives Ctrl+Shift for CapsLock and left Shift held together", function()
		with_session(nil, function(s)
			local emitted = s.drive({ { LSHIFT, DOWN, 0 }, { CAPS, DOWN, 30 },
				{ KEY_A, DOWN, 60 }, { KEY_A, UP, 90 }, { CAPS, UP, 120 }, { LSHIFT, UP, 150 } })
			helpers.assert_eq(emitted, "42:1 29:1 30:1 30:0 29:0 42:0")
			helpers.assert_eq(#s.actions, 0)
		end)
	end)

end)




-- =========================================
-- =========================================
-- ======= 2/ Changes from the tray ========
-- =========================================
-- =========================================

helpers.describe("tap-holds end to end: a tray change is live", function()

	helpers.it("runs a new tap action on the next keystroke", function()
		with_session(nil, function(s)
			helpers.assert_true(s.writer.set_tap("left_shift", "paste"))
			s.drive({ tap(LSHIFT, 0) })
			helpers.assert_eq(s.actions[1], "paste")
		end)
	end)

	helpers.it("moves the navigation layer to CapsLock", function()
		with_session(nil, function(s)
			helpers.assert_true(s.writer.set_hold("caps_lock", "layer", "nav"))
			local emitted = s.drive({ { CAPS, DOWN, 0 }, { KEY_J, DOWN, 50 }, { KEY_J, UP, 80 }, { CAPS, UP, 500 } })
			helpers.assert_eq(emitted, "29:1 105:1 105:0 29:0")
		end)
	end)

	helpers.it("gives a key back to the keyboard when made native", function()
		with_session(nil, function(s)
			helpers.assert_true(s.writer.set_native("caps_lock"))
			helpers.assert_eq(s.drive({ tap(CAPS, 0) }), "58:1 58:0")
		end)
	end)

	helpers.it("swallows a key whose tap is none and which has no hold", function()
		with_session(nil, function(s)
			s.writer.set_tap("caps_lock", "none")
			s.writer.set_hold("caps_lock", "none", "")
			helpers.assert_eq(s.drive({ tap(CAPS, 0) }), "")
		end)
	end)

	helpers.it("holds a modifier combination", function()
		with_session(nil, function(s)
			helpers.assert_true(s.writer.set_hold("caps_lock", "modifier", "ctrl+shift"))
			local emitted = s.drive({ { CAPS, DOWN, 0 }, { KEY_A, DOWN, 50 }, { KEY_A, UP, 80 }, { CAPS, UP, 500 } })
			helpers.assert_eq(emitted, "29:1 42:1 30:1 30:0 42:0 29:0")
		end)
	end)

	helpers.it("uses a key's own delay", function()
		with_session(nil, function(s)
			s.drive({ { LSHIFT, DOWN, 0 }, { LSHIFT, UP, 500 } })
			helpers.assert_eq(#s.actions, 0, "500 ms is a hold at the default 350 ms")
			helpers.assert_true(s.writer.set_threshold("left_shift", 0.6))
			s.drive({ { LSHIFT, DOWN, 1000 }, { LSHIFT, UP, 1500 } })
			helpers.assert_eq(s.actions[1], "copy", "and a tap at 600 ms")
		end)
	end)

	helpers.it("disables everything, then resets to the defaults", function()
		with_session(nil, function(s)
			helpers.assert_true(s.writer.disable_all())
			helpers.assert_eq(s.drive({ tap(CAPS, 0) }), "58:1 58:0")
			s.drive({ tap(LSHIFT, 500) })
			helpers.assert_eq(#s.actions, 0)
			helpers.assert_true(s.writer.reset_all())
			s.drive({ tap(LSHIFT, 1000) })
			helpers.assert_eq(s.actions[1], "copy")
		end)
	end)

	helpers.it("switches the feature off and on from the file", function()
		with_session(nil, function(s)
			helpers.assert_true(s.writer.set_enabled(false))
			helpers.assert_eq(s.drive({ tap(CAPS, 0) }), "58:1 58:0")
			helpers.assert_true(s.writer.set_enabled(true))
			helpers.assert_eq(s.drive({ tap(CAPS, 500) }), "29:1 29:0 28:1 28:0")
		end)
	end)

	helpers.it("starts off when the user's file says so", function()
		with_session("[tap_hold]\nenabled = false\n", function(s)
			helpers.assert_true(not s.manager.is_active())
			helpers.assert_eq(s.drive({ tap(CAPS, 0) }), "58:1 58:0")
		end)
	end)

	helpers.it("keeps running the defaults when the user's file is broken", function()
		with_session("[tap_hold.keys.left_shift\n", function(s)
			s.drive({ tap(LSHIFT, 0) })
			helpers.assert_eq(s.actions[1], "copy")
			helpers.assert_true(not s.writer.set_tap("left_shift", "paste"), "and the tray refuses to overwrite it")
		end)
	end)

end)




-- =========================================
-- =========================================
-- ======= 3/ Nothing stays pressed ========
-- =========================================
-- =========================================

helpers.describe("tap-holds end to end: nothing stays pressed", function()

	helpers.it("releases a held CapsLock's Ctrl when the script pauses", function()
		with_session(nil, function(s)
			local emitted = {}
			s.hook._test_drive({
				{ type = EV_KEY, code = CAPS, value = DOWN, at_ms = 0 },
				{ type = EV_KEY, code = KEY_A, value = DOWN, at_ms = 100 },
				{ type = EV_KEY, code = KEY_A, value = UP, at_ms = 150 },
				{ type = EV_KEY, code = CAPS, value = UP, at_ms = 600 },
			}, {
				onEmitRaw = function(code, value)
					emitted[#emitted + 1] = code .. ":" .. value
					-- The pause lands while CapsLock is still down.
					if code == KEY_A and value == DOWN then s.manager.set_paused(true) end
					return true
				end,
			}, true)
			helpers.assert_eq(table.concat(emitted, " "), "29:1 30:1 29:0 30:0",
				"Ctrl released at the pause; CapsLock's release is swallowed, not sent as a lock")
			assert_balanced(emitted)
			helpers.assert_eq(s.drive({ tap(CAPS, 1000) }), "58:1 58:0", "paused: CapsLock is itself")
			s.manager.set_paused(false)
			helpers.assert_eq(s.drive({ tap(CAPS, 2000) }), "29:1 29:0 28:1 28:0", "resumed")
		end)
	end)

	helpers.it("releases the layer's chord when the tray reloads mid-hold", function()
		with_session(nil, function(s)
			local emitted = {}
			s.hook._test_drive({
				{ type = EV_KEY, code = LALT, value = DOWN, at_ms = 0 },
				{ type = EV_KEY, code = KEY_K, value = DOWN, at_ms = 50 },
				{ type = EV_KEY, code = KEY_K, value = UP, at_ms = 90 },
				{ type = EV_KEY, code = LALT, value = UP, at_ms = 400 },
			}, {
				onEmitRaw = function(code, value)
					emitted[#emitted + 1] = code .. ":" .. value
					if code == 105 and value == DOWN then s.writer.set_tap("left_shift", "paste") end
					return true
				end,
			}, true)
			assert_balanced(emitted)
			helpers.assert_true(not table.concat(emitted, " "):find("37:", 1, true),
				"K's release after the swap is not sent as a lone K up")
		end)
	end)

	helpers.it("releases everything the engine holds when the hook stops", function()
		with_session(nil, function(s)
			local emitted = {}
			s.hook._test_drive({
				{ type = EV_KEY, code = CAPS, value = DOWN, at_ms = 0 },
				{ type = EV_KEY, code = LSHIFT, value = DOWN, at_ms = 10 },
			}, {
				onEmitRaw = function(code, value)
					emitted[#emitted + 1] = code .. ":" .. value
					if code == LSHIFT and value == DOWN then s.hook.release_remapped() end
					return true
				end,
			}, true)
			assert_balanced(emitted)
		end)
	end)

	helpers.it("leaves nothing down over a long random session on the defaults", function()
		with_session(nil, function(s)
			local codes = { CAPS, LSHIFT, LCTRL, LALT, RCTRL, ALTGR, TAB, KEY_A, KEY_J, KEY_K, KEY_U, 57, 28, 14 }
			local seed, now, physical, events = 11, 0, {}, {}
			local function random(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n + 1 end
			for _ = 1, 2000 do
				now = now + random(120)
				local code = codes[random(#codes)]
				local value = physical[code] and UP or DOWN
				physical[code] = value == DOWN or nil
				events[#events + 1] = { code, value, now }
			end
			for code in pairs(physical) do events[#events + 1] = { code, UP, now + 1000 } end
			s.drive(events)
			assert_balanced(s.last)
		end)
	end)

end)
