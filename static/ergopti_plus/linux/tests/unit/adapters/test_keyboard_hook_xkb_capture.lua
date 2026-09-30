--- tests/unit/adapters/test_keyboard_hook_xkb_capture.lua

--- ==============================================================================
--- MODULE: Keyboard Hook to XKB Capture Integration Tests
--- DESCRIPTION:
--- Pins the join between raw evdev routing and the stateful XKB adapter. The XKB
--- unit tests prove state semantics; these cases prove keyboard_hook does not
--- bypass that state for modifiers, locks, releases, repeats or shortcuts.
---
--- ROOT CAUSE ENCODED:
--- The old hook returned early for modifiers and CapsLock, discarded releases,
--- and resolved printable keys through a static table. Even a correct XKB
--- adapter would therefore drift immediately if the hook forwarded only the
--- events that happened to produce text.
--- ==============================================================================

local helpers = require("tests.helpers")

local function key(code, value)
	return { type = 1, code = code, value = value }
end





-- =========================================
-- =========================================
-- ======= 1/ Complete event stream =========
-- =========================================
-- =========================================

helpers.describe("keyboard_hook: live XKB capture stream", function()
	helpers.it("refuses to open a keyboard before live XKB state is ready", function()
		local module_name = "adapters.xkb_capture"
		local saved = package.loaded[module_name]
		package.loaded[module_name] = {
			is_ready = function() return false end,
			reset_state = function() error("must not reset an absent state") end,
			process = function() error("must not process without state") end,
		}
		local hook = helpers.load_module("adapters.keyboard_hook")
		package.loaded[module_name] = saved

		hook.start({ intercept = false })
		helpers.assert_true(not hook.isRunning(),
			"a guessed static layout must never become a valid-looking capture path")
	end)

	helpers.it("forwards every key transition to live XKB before routing", function()
		local hook = helpers.load_module("adapters.keyboard_hook")
		local seen = {}
		local chars = {}
		local events = {
			key(42, 1),  -- Shift down
			key(30, 1),  -- printable down
			key(30, 2),  -- printable repeat
			key(30, 0),  -- printable release
			key(58, 1),  -- CapsLock down
			key(58, 0),  -- CapsLock release
			key(42, 0),  -- Shift release
		}

		hook._test_drive(events, {
			captureEvent = function(code, value)
				seen[#seen + 1] = { code, value }
				if code == 30 and value ~= 0 then return "q", "q" end
				return nil, nil, nil
			end,
			onChar = function(char) chars[#chars + 1] = char end,
			onEmitRaw = function() return true end,
		}, true)

		helpers.assert_eq(seen, {
			{ 42, 1 }, { 30, 1 }, { 30, 2 }, { 30, 0 },
			{ 58, 1 }, { 58, 0 }, { 42, 0 },
		}, "modifiers, locks and releases must reach XKB instead of an early return")
		helpers.assert_eq(chars, { "q", "q" }, "only press and repeat become text")
	end)

	helpers.it("keeps the second Shift held after the first Shift is released", function()
		local hook = helpers.load_module("adapters.keyboard_hook")
		hook._test_drive({
			key(42, 1),
			key(54, 1),
			key(42, 0),
		}, {
			captureEvent = function() return nil, nil, nil end,
			onEmitRaw = function() return true end,
		}, true)

		helpers.assert_eq(hook.held_text_modifiers(), { "shift" },
			"one boolean cannot represent two physical Shift keys")
	end)
end)





-- =========================================
-- =========================================
-- ======= 2/ Right Alt follows the layout ==
-- =========================================
-- =========================================

-- Right Alt is AltGr (ISO_Level3_Shift) on a French or Ergopti layout and
-- plain Alt_R on a US one. The hook used to call it AltGr whatever the layout,
-- so on a US layout Alt_R+Q reached the hotstring buffer as the text "q" while
-- the application received the Alt shortcut.
helpers.describe("keyboard_hook: Right Alt follows the live layout", function()
	local XKB = 8
	local KEY_RIGHTALT, KEY_Q = 100, 16
	local SYMS = { Alt_R = 0xffea, ISO_Level3_Shift = 0xfe03, Shift_L = 0xffe1 }

	--- A stateful XKB double whose Right Alt carries `ralt_sym`: level 3 of Q
	--- is "@" while an ISO_Level3_Shift is down.
	local function backend(ralt_sym)
		return {
			create = function() return { held = {} } end,
			destroy = function() end,
			key_sym = function(session, keycode)
				if keycode == KEY_RIGHTALT + XKB then return ralt_sym end
				if keycode == 42 + XKB then return SYMS.Shift_L end
				if keycode == KEY_Q + XKB then
					return session.held[KEY_RIGHTALT + XKB] and ralt_sym == SYMS.ISO_Level3_Shift and "at" or "q"
				end
				return nil
			end,
			key_utf8 = function(session, keycode)
				if keycode ~= KEY_Q + XKB then return nil end
				return session.held[KEY_RIGHTALT + XKB] and ralt_sym == SYMS.ISO_Level3_Shift and "@" or "q"
			end,
			sym_utf8 = function(_, sym)
				if sym == "at" then return "@" end
				return type(sym) == "string" and sym or nil
			end,
			update_key = function(session, keycode, direction) session.held[keycode] = direction == 1 or nil end,
			compose_feed = function() end,
			compose_status = function() return "nothing" end,
			compose_utf8 = function() return nil end,
			compose_reset = function() end,
		}
	end

	--- Drives Right Alt + Q through the live XKB adapter on a keymap whose
	--- Right Alt is `ralt_sym`, and reports what the hook made of it.
	local function drive(ralt_sym, events)
		local Capture = helpers.load_module("adapters.xkb_capture")
		Capture._set_backend(backend(ralt_sym))
		helpers.assert_true(Capture.load("keymap", "C"), "the double keymap loads")
		local hook = helpers.load_module("adapters.keyboard_hook")
		local seen = { chars = {}, shortcuts = {} }
		local ok, err = pcall(hook._test_drive, events, {
			liveXkb = true,
			onChar = function(char) seen.chars[#seen.chars + 1] = char end,
			onKey = function(name, payload)
				if name == "shortcut" then seen.shortcuts[#seen.shortcuts + 1] = payload end
			end,
			onEmitRaw = function() return true end,
		}, true)
		seen.text_modifiers = hook.held_text_modifiers()
		seen.shortcut_codes = hook.held_shortcut_modifier_codes()
		Capture._reset_backend()
		if not ok then error(err, 0) end
		return seen
	end

	helpers.it("is Alt on a layout where it is Alt_R: Alt+Q is a shortcut, not text", function()
		local seen = drive(SYMS.Alt_R, { key(KEY_RIGHTALT, 1), key(KEY_Q, 1), key(KEY_Q, 0) })
		helpers.assert_eq(seen.chars, {}, "Alt_R+Q must not reach the hotstring buffer as 'q'")
		helpers.assert_eq(#seen.shortcuts, 1, "it is the shortcut the application receives")
		helpers.assert_eq(seen.shortcuts[1].key, "q")
		helpers.assert_true(seen.shortcuts[1].mods.alt == true and seen.shortcuts[1].mods.altgr == nil,
			"held as Alt, not as AltGr")
		helpers.assert_eq(seen.text_modifiers, {}, "Alt selects no level")
		helpers.assert_eq(seen.shortcut_codes, { KEY_RIGHTALT }, "an injection releases it as a shortcut modifier")
	end)

	helpers.it("is AltGr on a layout where it is ISO_Level3_Shift: AltGr+Q is text", function()
		local seen = drive(SYMS.ISO_Level3_Shift, { key(KEY_RIGHTALT, 1), key(KEY_Q, 1), key(KEY_Q, 0) })
		helpers.assert_eq(seen.chars, { "@" }, "the level-3 character is typed text")
		helpers.assert_eq(seen.shortcuts, {}, "and no shortcut")
		helpers.assert_eq(seen.text_modifiers, { "altgr" })
		helpers.assert_eq(seen.shortcut_codes, {})
	end)

	helpers.it("releases a Right Alt under the role it was pressed with", function()
		local seen = drive(SYMS.Alt_R, { key(KEY_RIGHTALT, 1), key(KEY_RIGHTALT, 0), key(KEY_Q, 1) })
		helpers.assert_eq(seen.chars, { "q" }, "a released Alt holds nothing: Q is text again")
		helpers.assert_eq(seen.shortcut_codes, {})
	end)
end)





-- =========================================
-- =========================================
-- ======= 3/ Shortcut identity =============
-- =========================================
-- =========================================

helpers.describe("keyboard_hook: XKB shortcut identity", function()
	helpers.it("uses the keysym identity instead of Ctrl-transformed UTF-8", function()
		local hook = helpers.load_module("adapters.keyboard_hook")
		local shortcut = nil
		hook._test_drive({
			key(29, 1), -- Ctrl down
			key(31, 1), -- S down
		}, {
			captureEvent = function(code)
				if code == 31 then return string.char(19), "s", nil end
				return nil, nil, nil
			end,
			onKey = function(name, payload)
				if name == "shortcut" then shortcut = payload end
			end,
			onEmitRaw = function() return true end,
		}, true)

		helpers.assert_not_nil(shortcut, "Ctrl+S must remain a shortcut event")
		helpers.assert_eq(shortcut.key, "s",
			"xkb_state UTF-8 is a control byte; the keysym preserves shortcut identity")
		helpers.assert_true(shortcut.mods.ctrl == true, "the physical Ctrl role remains attached")
	end)
end)





-- =============================================
-- =============================================
-- ======= 4/ Modifiers the XKB options move ===
-- =============================================
-- =============================================

-- XKB options put a modifier on another key: ctrl:nocaps makes CapsLock a
-- Ctrl, caps:super a Super, lv3:caps_switch and lv3:menu_switch an AltGr, and
-- ctrl:swapcaps trades Ctrl and CapsLock. The hook asked XKB about the eight
-- usual modifier keys only, so under ctrl:nocaps CapsLock+C was the letter c
-- in the hotstring buffer and never a shortcut (xkb-options-modifier-role).
helpers.describe("keyboard_hook: a modifier the XKB options put on another key", function()
	local XKB = 8
	local KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_CAPSLOCK, KEY_COMPOSE, KEY_C, KEY_Q = 29, 42, 58, 127, 46, 16
	local SYM = { Control_L = 0xffe3, Caps_Lock = 0xffe5, Super_L = 0xffeb, ISO_Level3_Shift = 0xfe03 }

	--- A stateful keymap double: `syms` gives the keysym of each moved key, C
	--- types "c" and Q types "q", or "@" while an ISO_Level3_Shift key is down.
	local function backend(syms)
		local function level3(session)
			for keycode in pairs(session.held) do
				if syms[keycode - XKB] == SYM.ISO_Level3_Shift then return true end
			end
			return false
		end
		return {
			create = function() return { held = {} } end,
			destroy = function() end,
			key_sym = function(session, keycode)
				local code = keycode - XKB
				if syms[code] ~= nil then
					if syms[code] == "fails" then error("keymap unavailable") end
					return syms[code]
				end
				if code == KEY_C then return "c" end
				if code == KEY_Q then return level3(session) and "at" or "q" end
				return nil
			end,
			key_utf8 = function(session, keycode)
				local code = keycode - XKB
				if code == KEY_C then return "c" end
				if code == KEY_Q then return level3(session) and "@" or "q" end
				return nil
			end,
			sym_utf8 = function(_, sym)
				if sym == "at" then return "@" end
				return type(sym) == "string" and sym or nil
			end,
			update_key = function(session, keycode, direction) session.held[keycode] = direction == 1 or nil end,
			compose_feed = function() end,
			compose_status = function() return "nothing" end,
			compose_utf8 = function() return nil end,
			compose_reset = function() end,
		}
	end

	--- Drives `events` through the live XKB adapter on a keymap with `syms`.
	local function drive(syms, events)
		local Capture = helpers.load_module("adapters.xkb_capture")
		Capture._set_backend(backend(syms))
		helpers.assert_true(Capture.load("keymap", "C"), "the double keymap loads")
		local hook = helpers.load_module("adapters.keyboard_hook")
		local seen = { chars = {}, shortcuts = {} }
		local ok, err = pcall(hook._test_drive, events, {
			liveXkb = true,
			onChar = function(char) seen.chars[#seen.chars + 1] = char end,
			onKey = function(name, payload)
				if name == "shortcut" then seen.shortcuts[#seen.shortcuts + 1] = payload end
			end,
			onEmitRaw = function() return true end,
		}, true)
		seen.text_modifiers = hook.held_text_modifiers()
		Capture._reset_backend()
		if not ok then error(err, 0) end
		return seen
	end

	helpers.it("reads CapsLock as Ctrl under ctrl:nocaps, and Super under caps:super", function()
		for sym, mod in pairs({ [SYM.Control_L] = "ctrl", [SYM.Super_L] = "meta" }) do
			local seen = drive({ [KEY_CAPSLOCK] = sym }, { key(KEY_CAPSLOCK, 1), key(KEY_C, 1), key(KEY_C, 0) })
			helpers.assert_eq(seen.chars, {}, mod .. ": CapsLock+C must not reach the buffer as 'c'")
			helpers.assert_eq(#seen.shortcuts, 1, mod .. ": CapsLock+C is a shortcut")
			helpers.assert_eq(seen.shortcuts[1].key, "c")
			helpers.assert_true(seen.shortcuts[1].mods[mod] == true, "held as " .. mod)
		end
	end)

	helpers.it("types the level-3 character with CapsLock or Menu as AltGr (lv3:caps_switch, lv3:menu_switch)", function()
		for _, code in ipairs({ KEY_CAPSLOCK, KEY_COMPOSE }) do
			local seen = drive({ [code] = SYM.ISO_Level3_Shift }, { key(code, 1), key(KEY_Q, 1), key(KEY_Q, 0) })
			helpers.assert_eq(seen.chars, { "@" }, code .. " selects level 3")
			helpers.assert_eq(seen.shortcuts, {})
			helpers.assert_eq(seen.text_modifiers, { "altgr" })
		end
	end)

	helpers.it("trades Ctrl and CapsLock under ctrl:swapcaps", function()
		local syms = { [KEY_CAPSLOCK] = SYM.Control_L, [KEY_LEFTCTRL] = SYM.Caps_Lock }
		local seen = drive(syms, { key(KEY_LEFTCTRL, 1), key(KEY_C, 1), key(KEY_C, 0), key(KEY_LEFTCTRL, 0) })
		helpers.assert_eq(seen.chars, { "c" }, "left Ctrl is the Caps Lock key there: C is text")
		helpers.assert_eq(seen.shortcuts, {})
		seen = drive(syms, { key(KEY_CAPSLOCK, 1), key(KEY_C, 1), key(KEY_C, 0) })
		helpers.assert_eq(#seen.shortcuts, 1, "CapsLock is the Ctrl there: CapsLock+C is a shortcut")
		helpers.assert_eq(seen.chars, {})
	end)

	-- The capture of each event failed as well, and said so at every event
	-- next to the role's one line (xkb-failure-once).
	helpers.it("says once, not at every key, that XKB cannot tell a role or capture a key (xkb-options-modifier-role)", function()
		local Logger = require("logger.shim")
		local real_error, errors = Logger.error, {}
		Logger.error = function(_, fmt, ...)
			local line = string.format(fmt, ...)
			if line:find("XKB", 1, true) then errors[#errors + 1] = line end
		end
		local ok, err = pcall(drive, { [KEY_LEFTSHIFT] = "fails" }, {
			key(KEY_LEFTSHIFT, 1), key(KEY_LEFTSHIFT, 0), key(KEY_LEFTSHIFT, 1), key(KEY_LEFTSHIFT, 0),
			key(KEY_LEFTSHIFT, 1), key(KEY_LEFTSHIFT, 0),
		})
		Logger.error = real_error
		if not ok then error(err, 0) end
		helpers.assert_eq(#errors, 1, "three presses, one error: " .. table.concat(errors, " | "))
	end)
end)





-- ==================================================
-- ==================================================
-- ======= 5/ A consumed key composes nothing =======
-- ==================================================
-- ==================================================

-- A consumer (the physical magic key, a tap key) keeps a press from the
-- application, but XKB had already read it: a dead key chosen as the magic key
-- (French ^, US-international ') left Compose pending here, so the next "e"
-- entered the buffer as "é" while the application typed "e".
helpers.describe("keyboard_hook: a consumed dead key leaves no Compose pending", function()
	local XKB = 8
	local KEY_DEAD, KEY_E = 26, 18

	--- A keymap double whose KEY_DEAD is dead_circumflex and composes ê with E.
	local function backend()
		return {
			create = function() return { held = {}, compose = "nothing" } end,
			destroy = function() end,
			key_sym = function(_, keycode)
				local code = keycode - XKB
				if code == KEY_DEAD then return "dead_circumflex" end
				if code == KEY_E then return "e" end
				return nil
			end,
			key_utf8 = function(_, keycode) return keycode - XKB == KEY_E and "e" or nil end,
			sym_utf8 = function(_, sym) return sym == "e" and "e" or nil end,
			update_key = function(session, keycode, direction) session.held[keycode] = direction == 1 or nil end,
			compose_feed = function(session, sym)
				if sym == "dead_circumflex" then
					session.compose = "composing"
				elseif session.compose == "composing" then
					session.compose = sym == "e" and "composed" or "cancelled"
				else
					session.compose = "nothing"
				end
			end,
			compose_status = function(session) return session.compose end,
			compose_utf8 = function(session) return session.compose == "composed" and "ê" or nil end,
			compose_reset = function(session) session.compose = "nothing" end,
		}
	end

	local function drive(consume)
		local Capture = helpers.load_module("adapters.xkb_capture")
		Capture._set_backend(backend())
		helpers.assert_true(Capture.load("keymap", "C"), "the double keymap loads")
		local hook = helpers.load_module("adapters.keyboard_hook")
		local chars = {}
		local ok, err = pcall(hook._test_drive,
			{ key(KEY_DEAD, 1), key(KEY_DEAD, 0), key(KEY_E, 1), key(KEY_E, 0) }, {
			liveXkb = true,
			onConsume = function(detail) return consume and detail.code == KEY_DEAD end,
			onChar = function(char) chars[#chars + 1] = char end,
			onEmitRaw = function() return true end,
		}, true)
		Capture._reset_backend()
		if not ok then error(err, 0) end
		return chars
	end

	helpers.it("(magic-key-source) reads the next key plain after a consumed dead key", function()
		helpers.assert_eq(drive(false), { "ê" }, "a dead key the application received still composes")
		helpers.assert_eq(drive(true), { "e" }, "the application never saw the dead key: E is plain there")
	end)
end)
