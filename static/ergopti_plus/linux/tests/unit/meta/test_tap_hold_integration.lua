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
	user_text = require("tests.support.tap_hold_fixture").with_preset(user_text)
	local Hook = helpers.load_module("adapters.keyboard_hook")
	local Manager = helpers.load_module("platform.remap.tap_hold_manager")
	local Writer = helpers.load_module("platform.remap.tap_hold_writer")
	local dir = os.tmpname()
	os.remove(dir)
	local made = os.execute('mkdir "' .. dir .. '"')
	assert(made == true or made == 0, "the isolated configuration folder must exist")
	local path = dir .. "/tap_hold.toml"
	require("tests.support.nav_layer_fixture").write(dir)
	if user_text then
		local fh = assert(io.open(path, "w"))
		fh:write(user_text)
		fh:close()
	else
		os.remove(path)
	end
	local actions = {}
	-- The capitals the scenarios type, where a US layout has them: the one-shot
	-- Shift presses Shift on a key whose Shift level is the capital.
	local Layout = helpers.load_module("adapters.keyboard_layout")
	Layout._set_table_for_test({
		A = { keycode = KEY_A, level = 2, mods = { "shift" } },
		J = { keycode = KEY_J, level = 2, mods = { "shift" } },
	})
	Manager.init({
		keyboard_hook = Hook,
		execute_action = function(action) actions[#actions + 1] = action end,
		action_names = function() return { "open_url" } end,
		on_text_injected = function() end,
		defaults_path = DEFAULTS,
		user_path = path,
	})
	Writer.init({
		path = path,
		reload = Manager.reload,
		is_tap_action = Manager.is_tap_action,
		canonical_hold = Manager.canonical_hold,
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
		Layout._set_table_for_test(nil)
		Manager._reset_for_test()
		Writer._reset_for_test()
		os.remove(path)
		os.remove(dir .. "/layers.toml")
		os.execute('rmdir "' .. dir .. '"')
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

	-- The hook tells the engine what a key types. Ctrl+A under an armed one-
	-- shot came out as Ctrl+Shift+A, Print as Shift+Print, and "1" as "!"
	-- (one-shot-types-nothing).
	helpers.it("lets a shortcut and Print through the one-shot, and types a digit as it is", function()
		with_session(nil, function(s)
			local d, u = tap(RCTRL, 0)
			local emitted = s.drive({ d, u,
				{ LCTRL, DOWN, 200 }, { KEY_A, DOWN, 210 }, { KEY_A, UP, 220 }, { LCTRL, UP, 230 },
				{ 99, DOWN, 300 }, { 99, UP, 310 },
				{ KEY_A, DOWN, 400 }, { KEY_A, UP, 410 } })
			helpers.assert_eq(emitted, "42:1 42:0 29:1 30:1 30:0 29:0 99:1 99:0 42:1 30:1 30:0 42:0",
				"Ctrl+A and Print pass as they are, and the letter after them is the capital")
			d, u = tap(RCTRL, 1000)
			emitted = s.drive({ d, u, { 2, DOWN, 1200 }, { 2, UP, 1210 }, { KEY_A, DOWN, 1300 }, { KEY_A, UP, 1310 } })
			helpers.assert_eq(emitted, "42:1 42:0 2:1 2:0 30:1 30:0", "the 1 is a 1, and it spent the one-shot")
		end)
	end)

	-- The results come from _shared/tap_hold/one_shot_shift.json, which the
	-- Windows one-shot reads too (one-shot-results-shared).
	helpers.it("types the shared one-shot results, and hands the injector what the layout lacks", function()
		with_session(nil, function(s)
			local Layout = require("adapters.keyboard_layout")
			Layout._set_table_for_test({
				["-"] = { keycode = 12, level = 1, mods = {} }, [" "] = { keycode = 57, level = 1, mods = {} },
				[":"] = { keycode = 39, level = 2, mods = { "shift" } },
			})
			local saved = package.loaded["modules.hotstrings.injector"]
			local injected = {}
			package.loaded["modules.hotstrings.injector"] = {
				inject = function(erase, text) injected[#injected + 1] = erase .. ":" .. text; return { ok = true } end,
			}
			local ok, err = pcall(function()
				local d, u = tap(RCTRL, 0)
				helpers.assert_eq(s.drive({ d, u, { 57, DOWN, 200 }, { 57, UP, 250 } }), "42:1 42:0 12:1 12:0",
					"one-shot Shift then Space types -")
				d, u = tap(RCTRL, 1000)
				helpers.assert_eq(s.drive({ d, u, { 52, DOWN, 1200 }, { 52, UP, 1250 } }),
					"42:1 42:0 57:1 57:0 42:1 39:1 39:0 42:0", "then a period types a space and a colon")
				d, u = tap(RCTRL, 2000)
				helpers.assert_eq(s.drive({ d, u, { 13, DOWN, 2200 }, { 13, UP, 2250 } }), "42:1 42:0",
					"then = types nothing on the keyboard")
				helpers.assert_eq(injected, { "0:º" }, "the injector types º, which the layout has no key for")
			end)
			package.loaded["modules.hotstrings.injector"] = saved
			if not ok then error(err, 0) end
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
			helpers.assert_eq(s.drive({ tap(ALTGR, 0) }), "100:1 194:1 194:0 100:0 15:1 15:0",
				"a lone AltGr is masked before its release, then Tab is typed")
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

	helpers.it("clears everything, then restores the recommended preset", function()
		with_session(nil, function(s)
			local preset = require("platform.remap.tap_hold_loader").preset_keys(DEFAULTS)
			local function scope(mode, rows)
				local path = s.manager.user_path()
				local fh = assert(io.open(path, "r"))
				local document = require("toml_codec").decode(fh:read("*a"))
				fh:close()
				helpers.assert_true(s.manager.apply_configuration(
					require("toml_codec").decode(s.writer.render_scope(mode, document, rows, preset))))
			end
			scope("clear", { { section = "tap_holds", key = "enabled", delete = true } })
			helpers.assert_eq(s.drive({ tap(CAPS, 0) }), "58:1 58:0")
			s.drive({ tap(LSHIFT, 500) })
			helpers.assert_eq(#s.actions, 0)
			scope("recommended", { { section = "tap_holds", key = "enabled", value = true } })
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

	helpers.it("keeps the native key when the user's file is broken", function()
		with_session("[tap_hold.keys.left_shift\n", function(s)
			helpers.assert_eq(s.drive({ tap(LSHIFT, 0) }), "42:1 42:0")
			helpers.assert_nil(s.actions[1])
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





-- =========================================
-- =========================================
-- ======= The hold picker's options =======
-- =========================================
-- =========================================

-- The maintainer's rule of 2026-10-01: whatever option the hold picker offers
-- (one modifier, every combination, the layer, none) is the hold the key has
-- after the pick, on a key that held another one before.
helpers.describe("tap-holds end to end: every option of the hold picker", function()

	helpers.it("(hold-picker-every-option-2026-10-01) the hold a key gets is the option picked, after Shift", function()
		local Engine = require("platform.remap.tap_hold_engine")
		local SPACE = Engine.KEY_CODES.space
		with_session('[tap_hold.keys.space]\nhold_modifier = "shift"\n', function(s)
			local options = s.manager.hold_options()
			local kinds = { none = 0, modifier = 0, layer = 0 }
			for index, option in ipairs(options) do
				local label = option.kind .. ":" .. option.id
				helpers.assert_true(s.writer.set_hold("space", option.kind, option.id), label .. " must be written")
				kinds[option.kind] = kinds[option.kind] + 1
				-- Space held past its threshold, J typed under it, Space released.
				local at = index * 10000
				local emitted = s.drive({ { SPACE, DOWN, at }, { KEY_J, DOWN, at + 600 }, { KEY_J, UP, at + 650 },
					{ SPACE, UP, at + 800 } })
				assert_balanced(s.last)
				if option.kind == "modifier" then
					local down, up = {}, {}
					for token in option.id:gmatch("[^+]+") do
						local code = assert(Engine.MODIFIER_CODES[token], "unknown modifier " .. token)
						down[#down + 1] = code .. ":1"
						table.insert(up, 1, code .. ":0")
					end
					helpers.assert_true(#down > 0, label .. " must name at least one modifier")
					helpers.assert_eq(emitted, table.concat(down, " ") .. " " .. KEY_J .. ":1 " .. KEY_J .. ":0 "
						.. table.concat(up, " "), label .. " presses its own keys and no other")
				elseif option.kind == "layer" then
					helpers.assert_true(not emitted:find(LSHIFT .. ":1", 1, true), label .. " keeps nothing of the previous Shift")
					helpers.assert_true(not emitted:find(KEY_J .. ":1", 1, true) and emitted ~= "",
						label .. " hands the key to its layer, got '" .. emitted .. "'")
				else
					helpers.assert_eq(emitted, SPACE .. ":1 " .. KEY_J .. ":1 " .. KEY_J .. ":0 " .. SPACE .. ":0",
						"the native option holds nothing: the key is itself again")
				end
			end
			helpers.assert_true(kinds.none == 1 and kinds.layer >= 1, "the picker offers the native option and the layer")
			helpers.assert_true(kinds.modifier >= 31, "the picker offers every combination of the five modifiers")
		end)
	end)

end)
