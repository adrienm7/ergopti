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

	local function drive(consume, held)
		local Capture = helpers.load_module("adapters.xkb_capture")
		Capture._set_backend(backend())
		helpers.assert_true(Capture.load("keymap", "C"), "the double keymap loads")
		local hook = helpers.load_module("adapters.keyboard_hook")
		local chars = {}
		local events = { key(KEY_DEAD, 1), key(KEY_DEAD, 0), key(KEY_E, 1), key(KEY_E, 0) }
		if held then table.insert(events, 2, key(KEY_DEAD, 2)) end
		local ok, err = pcall(hook._test_drive, events, {
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

	helpers.it("(magic-key-source) reads the next key plain after a consumed dead key was held", function()
		helpers.assert_eq(drive(true, true), { "e" }, "nor any auto-repeat of it")
	end)
end)

-- These actual Reader/Hook consumers use controlled FFI bytes, not kernel devices.
local function with_position_capture(options, body)
	local previous = package.loaded["adapters.xkb_capture"]
	package.loaded["adapters.xkb_capture"] = nil
	local Capture = require("adapters.xkb_capture")
	local state = { epoch = 7 }
	local backend = { create = function() return { identity = "controlled-position-map" } end,
		destroy = function() end, update_key = function() end, key_sym = function(_, code) return code end,
		sym_utf8 = function(code) return code == 30 and "a" or nil end,
		key_utf8 = function(_, code) return code == 30 and "a" or nil end,
		compose_feed = function() end, compose_status = function() return "nothing" end,
		compose_reset = function() end, modifier_role = function(code) return require("infra.evdev_codes").MODIFIER_OF[code] end }
	backend.source_group = function()
		local epoch = state.epoch
		return 0, epoch, function() return state.epoch == epoch end
	end
	Capture._set_backend(backend); assert(Capture.load("controlled-position-source", "C.UTF-8"))
	options = options or {}; options.position_bits, options.capture = true, Capture
	local called, detail = pcall(function()
		require("tests.support.input_owner_fixture").with_session(options, function(session) body(session, state, Capture) end)
	end)
	Capture._reset_backend(); package.loaded["adapters.xkb_capture"] = previous
	if not called then error(detail, 0) end
end

helpers.describe("Original Hook physical editor position observation", function()
	helpers.it("captures detached original positions/modifiers without changing key forwarding", function()
		with_position_capture(nil, function(s)
			local captured, rows = {}, #s.rows
			local token = s.hook.capture_position(function() return true end, function(facts)
				captured[#captured + 1] = facts; return true
			end)
			helpers.assert_true(type(token) == "table", "original Reader source owner under controlled grab ACK enrolls observation")
			s.edge("b", 42, 1, 10); s.edge("a", 30, 1, 20); s.edge("a", 30, 2, 30); s.edge("a", 30, 0, 40)
			helpers.assert_eq(captured, { { native_code = 30, mods = { shift = true } } }, "original two-source physical bitmap owns modifier facts")
			helpers.assert_eq({ s.rows[rows + 1], s.rows[rows + 2], s.rows[rows + 3], s.rows[rows + 4] },
				{ { 42, 1 }, { 30, 1 }, { 30, 2 }, { 30, 0 } }, "capture borrows no suppressed DOWN/repeat/UP")
			helpers.assert_true(s.hook.cancel_position(token), "exact completed observation cancellation remains idempotent")
			helpers.assert_true(not s.hook.cancel_position({}), "copied token cannot retire a successor")
		end)
	end)
	helpers.it("cannot authenticate fabricated positive predicates and caller-created event rows", function()
		with_position_capture(nil, function(s)
			local calls = 0
			s.hook.capture_position(function() return true end, function() calls = calls + 1; return true end)
			s.hook._test_drive({ { type = 1, code = 30, value = 1 } }, { physicalSource = true, onEmitRaw = function() return true end }, true)
			helpers.assert_eq(calls, 0, "public detail/positive predicate has no actual Reader event capability")
		end)
	end)
	helpers.it("refuses virtual sources and custom Reader providers before enrollment", function()
		with_position_capture(nil, function(s)
			s.virtual = true; s.hook.physical_source_receipt()
			helpers.assert_eq(s.hook.capture_position(function() return true end, function() error("no virtual capture") end), nil)
		end)
		with_position_capture({ custom_reader = true }, function(s)
			helpers.assert_eq(s.hook.capture_position(function() return true end, function() error("no custom backend capture") end), nil)
		end)
	end)
	helpers.it("refuses ambiguous physical RightAlt instead of inventing AltGr or Alt", function()
		with_position_capture(nil, function(s)
			local calls = 0
			s.edge("b", 100, 1, 10)
			s.hook.capture_position(function() return true end, function() calls = calls + 1; return true end)
			s.edge("a", 30, 1, 20)
			helpers.assert_eq(calls, 0, "native RightAlt observation is not a proved W3C modifier role")
		end)
	end)
	helpers.it("rechecks page/source currency after native key queries and the final callback", function()
		local options = {}
		with_position_capture(options, function(s, state)
			local calls, page = 0, true
			local token = s.hook.capture_position(function() return page end, function() calls = calls + 1; return true end)
			options.on_key_query = function() page = false end
			s.edge("a", 30, 1, 10)
			helpers.assert_eq(calls, 0, "query callback cannot revoke page and still deliver")
			helpers.assert_true(s.hook.cancel_position(token))
			options.on_key_query, page = nil, true
			token = s.hook.capture_position(function() return page end, function()
				calls = calls + 1; state.epoch = state.epoch + 1
				helpers.assert_eq(s.hook.capture_position(function() return true end, function() end), nil, "receive cannot reenter enrollment")
				return true
			end)
			s.edge("a", 31, 1, 20)
			helpers.assert_eq(calls, 1, "actual original occurrence was observed once")
			helpers.assert_true(s.hook.cancel_position(token), "revoked source retains exact cancellation capability without output")
		end)
	end)
	helpers.it("refuses replacement Reader/source/page guards without invoking foreign callbacks", function()
		with_position_capture(nil, function(s)
			local calls = 0
			local token = s.hook.capture_position(function() return true end, function() calls = calls + 1; return true end)
			local original = s.reader.pressed_keys_current
			s.reader.pressed_keys_current = function() error("foreign observation port") end
			s.edge("a", 30, 1, 10)
			helpers.assert_eq(calls, 0, "public replacement is refused before receipt observations")
			s.reader.pressed_keys_current = original
			helpers.assert_true(s.hook.cancel_position(token))
		end)
	end)
	helpers.it("requires complete held-byte acknowledgements and the actual primary held key", function()
		with_position_capture({ short_key_query = true }, function(s)
			local calls = 0
			local token = s.hook.capture_position(function() return true end, function() calls = calls + 1; return true end)
			helpers.assert_true(type(token) == "table", "observation is enrolled before actual held IO")
			s.edge("a", 30, 1, 10)
			helpers.assert_eq(calls, 0, "successful syscall without complete copied bytes cannot supply modifiers")
			helpers.assert_true(s.hook.cancel_position(token))
		end)
		local options = {}
		with_position_capture(options, function(s)
			local calls = 0
			local token = s.hook.capture_position(function() return true end, function() calls = calls + 1; return true end)
			options.on_key_query = function() s.held[s.paths.a][30] = nil end
			s.edge("a", 30, 1, 10)
			helpers.assert_eq(calls, 0, "queued original DOWN does not prove the primary is still physically held")
			helpers.assert_true(s.hook.cancel_position(token))
		end)
	end)
	helpers.it("withdraws observation when the final page callback changes the native source", function()
		with_position_capture(nil, function(s, state)
			local calls, page_reads = 0, 0
			local token = s.hook.capture_position(function()
				page_reads = page_reads + 1
				if page_reads == 3 then state.epoch = state.epoch + 1 end
				return true
			end, function() calls = calls + 1; return true end)
			helpers.assert_true(type(token) == "table")
			s.edge("a", 30, 1, 10)
			helpers.assert_eq(page_reads, 3, "the final page query actually runs after native source seal acquisition")
			helpers.assert_eq(calls, 0, "positive page callback cannot conceal a changed source seal")
			helpers.assert_true(s.hook.cancel_position(token))
		end)
	end)
	helpers.it("withdraws when original source classification is republished during observation", function()
		with_position_capture(nil, function(s)
			local calls, page_reads = 0, 0
			local token = s.hook.capture_position(function()
				page_reads = page_reads + 1
				if page_reads == 3 then s.virtual = true; s.hook.physical_source_receipt() end
				return true
			end, function() calls = calls + 1; return true end)
			helpers.assert_true(type(token) == "table")
			s.edge("a", 30, 1, 10)
			helpers.assert_eq(calls, 0, "published physical-source revocation survives a positive page callback")
			helpers.assert_true(s.hook.cancel_position(token))
		end)
	end)
	helpers.it("rejects replaced observation exports and exact cancellation during a native query", function()
		with_position_capture(nil, function(s)
			local calls, foreign = 0, 0
			local token = s.hook.capture_position(function() return true end, function() calls = calls + 1; return true end)
			local original = s.hook.position_capture_available
			s.hook.position_capture_available = function() foreign = foreign + 1; return true end
			s.edge("a", 30, 1, 10)
			helpers.assert_eq(calls, 0, "public query replacement withdraws the original enrollment")
			helpers.assert_eq(foreign, 0, "native observation never executes a foreign public export")
			s.hook.position_capture_available = original
			helpers.assert_true(s.hook.cancel_position(token))
		end)
		local options = {}
		with_position_capture(options, function(s)
			local calls = 0
			local token = s.hook.capture_position(function() return true end, function() calls = calls + 1; return true end)
			options.on_key_query = function()
				helpers.assert_eq(s.hook.capture_position(function() return true end, function() end), nil, "native query cannot reenter enrollment")
				helpers.assert_true(s.hook.cancel_position(token), "exact observation retires without claiming a key UP")
			end
			s.edge("a", 30, 1, 10)
			helpers.assert_eq(calls, 0, "cancelled request cannot receive even when IO acknowledges")
			helpers.assert_eq(s.rows[#s.rows], { 30, 1 }, "cancellation preserves actual forwarding")
		end)
	end)

	helpers.it("retains idempotent cancellation without retaining completed page callbacks", function()
		local weak = setmetatable({}, { __mode = "k" })
		local original_hook, original_registry, completed_record, retire_page
		-- End the setup/caller scope before collection, while retaining the actual
		-- Hook and exact issued record. A compiled caller may keep its own locals.
		with_position_capture(nil, function(s)
			original_hook = s.hook
			local function observe()
				local page = {}
				retire_page = function() page = nil end
				local token = s.hook.capture_position(function() return page ~= nil end, function() return true end)
				weak[token], weak[page] = "token", "page"
				-- Inspection grants no runtime authority: read the original private
				-- registry entry that the actual producer bound to its original token.
				local index = 1
				while true do
					local name, registry = debug.getupvalue(original_hook.capture_position, index)
					if name == nil then break end
					if name == "position_capture" then
						original_registry, completed_record = registry, registry.tokens[token]
						break
					end
					index = index + 1
				end
				helpers.assert_true(type(completed_record) == "table" and rawequal(completed_record.token, token),
					"inspection retains the exact private native producer record, never a fabricated record")
				s.edge("a", 30, 1, 10)
				collectgarbage("collect")
				helpers.assert_true(s.hook.cancel_position(token), "completed identity survives collection while its page owns the token")
			end
			observe()
		end)
		for _, name in ipairs({ "token", "current", "receive", "session", "options", "sources", "observers", "finder", "classify" }) do
			helpers.assert_eq(completed_record[name], nil, "acknowledged record relinquishes its original " .. name)
		end
		helpers.assert_true(type(original_hook.cancel_position) == "function", "original Hook remains strongly live during lifetime proof")
		-- The real page owner retires its getter cell only after exact native ACK
		-- and after proving the producer has relinquished every original closure.
		retire_page(); retire_page = nil
		collectgarbage("collect"); collectgarbage("collect")
		local _, kind = next(weak)
		helpers.assert_eq(kind, nil, "settled registry does not retain its own weak key or retired page closure")
		helpers.assert_true(type(original_hook.cancel_position) == "function" and type(original_registry.tokens) == "table",
			"original Hook and private registry stay strongly live through both collections")
	end)
	helpers.it("joins the original Reader occurrence to the actual host and shared editor without writes", function()
		with_position_capture(nil, function(s)
			local names = { "ui.physical_shortcuts.bridge", "ui.webview_manager", "modules.gestures.manager",
				"infra.paths", "infra.i18n", "logger.shim" }
			local previous = {}; for _, name in ipairs(names) do previous[name] = { package.loaded[name] } end
			local host, receipt, epoch, sends, writes, paused = nil, {}, 0, {}, 0, false
			local called, detail = pcall(function()
				package.loaded["ui.webview_manager"] = { native_available = function() return true end,
					current_epoch = function() return epoch > 0 and epoch or nil end,
					page_current = function(_, exact) return epoch > 0 and epoch == exact end,
					show = function() epoch = 53; return host.on_window_acquiring(epoch) end,
					hide = function(_, exact) if exact ~= epoch then return false end; local old = epoch; epoch = 0; host.on_window_closed(old); return true end,
					eval_js = function(_, script) sends[#sends + 1] = script; return true end }
				package.loaded["modules.gestures.manager"] = { is_assignable = function(action) return action == "none" end,
					get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
					split_action_parameter_key = function() end, get_action_label = function(action) return action end }
				package.loaded["infra.paths"] = { shared = function(path) return helpers.driver_root() .. "/../_shared/" .. path end }
				package.loaded["infra.i18n"] = { get = function(key) return key end }
				package.loaded["logger.shim"] = helpers.make_logger_stub()
				host = helpers.load_module("ui.physical_shortcuts.bridge")
				local scope = { physical_delivery_available = function() return true end,
					capture_editor_inventory = function() return { assignments = {}, parameters = {} }, receipt end,
					editor_source_current = function(exact) return rawequal(exact, receipt) end,
					edit = function() writes = writes + 1; return false end }
				helpers.assert_true(host.open({ scope = scope, is_paused = function() return paused end }),
					"controlled host prerequisite is not public native delivery qualification")
				local function message(value) return host.on_message(value, {}, { app_name = "physical_shortcuts", epoch = epoch }) end
				helpers.assert_true(message({ action = "ready" }))
				helpers.assert_true(message({ action = "capture_position", request = { request_id = 7 } }))
				s.edge("b", 42, 1, 10); s.edge("a", 36, 1, 20)
				local json = sends[#sends]:match("^captured%((.*)%)$")
				helpers.assert_true(type(json) == "string", "actual original Hook emits through the retained page controller")
				local packet = require("json").decode(json)
				helpers.assert_eq(packet.code, "KeyJ", "original native36 crosses the shared registry")
				helpers.assert_eq(packet.mods, { shift = true }, "another original physical source owns Shift")
				helpers.assert_eq(packet.request_id, 7, "page request identity survives all producers")
				helpers.assert_eq(writes, 0, "joint capture publishes no assignment, parameter or output")
				helpers.assert_true(message({ action = "capture_position", request = { request_id = 8 } }))
				local sent = #sends
				paused = true
				s.edge("a", 37, 1, 25)
				helpers.assert_eq(#sends, sent, "live pause withdraws the actual host enrollment before Reader delivery")
				helpers.assert_true(host.close(), "page retirement cancels only observation")
				s.edge("a", 36, 0, 30); s.edge("b", 42, 0, 40)
				helpers.assert_eq(s.rows[#s.rows - 1], { 36, 0 }, "closing page cannot orphan primary physical UP")
				helpers.assert_eq(s.rows[#s.rows], { 42, 0 }, "closing page cannot orphan modifier physical UP")
			end)
			if host then host.close() end
			for _, name in ipairs(names) do package.loaded[name] = previous[name][1] end
			if not called then error(detail, 0) end
		end)
	end)

end)

helpers.describe("Position capture native effect ownership", function()
	helpers.it("refuses a replaced native effect port and permits a fresh original request after restoration", function()
		with_position_capture(nil, function(s)
			local names = { "ui.physical_shortcuts.bridge", "ui.webview_manager", "modules.gestures.manager",
				"infra.paths", "infra.i18n", "logger.shim" }
			local previous = {}; for _, name in ipairs(names) do previous[name] = { package.loaded[name] } end
			local host, receipt, epoch, sends, writes, paused = nil, {}, 0, {}, 0, false
			local called, detail = pcall(function()
				package.loaded["ui.webview_manager"] = { native_available = function() return true end,
					current_epoch = function() return epoch > 0 and epoch or nil end,
					page_current = function(_, exact) return epoch > 0 and epoch == exact end,
					show = function() epoch = 53; return host.on_window_acquiring(epoch) end,
					hide = function(_, exact) if exact ~= epoch then return false end; local old = epoch; epoch = 0; host.on_window_closed(old); return true end,
					eval_js = function(_, script) sends[#sends + 1] = script; return true end }
				package.loaded["modules.gestures.manager"] = { is_assignable = function(action) return action == "none" end,
					get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
					split_action_parameter_key = function() end, get_action_label = function(action) return action end }
				package.loaded["infra.paths"] = { shared = function(path) return helpers.driver_root() .. "/../_shared/" .. path end }
				package.loaded["infra.i18n"] = { get = function(key) return key end }
				package.loaded["logger.shim"] = helpers.make_logger_stub()
				host = helpers.load_module("ui.physical_shortcuts.bridge")
				local scope = { physical_delivery_available = function() return true end,
					capture_editor_inventory = function() return { assignments = {}, parameters = {} }, receipt end,
					editor_source_current = function(exact) return rawequal(exact, receipt) end,
					edit = function() writes = writes + 1; return false end }
				helpers.assert_true(host.open({ scope = scope, is_paused = function() return paused end }),
					"controlled host prerequisite is not public native delivery qualification")
				local function message(value) return host.on_message(value, {}, { app_name = "physical_shortcuts", epoch = epoch }) end
				helpers.assert_true(message({ action = "ready" }))
				helpers.assert_true(message({ action = "capture_position", request = { request_id = 7 } }))
				local manager = package.loaded["ui.webview_manager"]
				local original_eval = manager.eval_js
				local foreign_calls = 0
				manager.eval_js = function(_, script)
					foreign_calls = foreign_calls + 1
					sends[#sends + 1] = script
					return true
				end
				s.edge("b", 42, 1, 10); s.edge("a", 36, 1, 20)
				print("INDEPENDENT_FOREIGN_EFFECT_CALLS", foreign_calls, "WRITES", writes)
				manager.eval_js = original_eval
				helpers.assert_eq(foreign_calls, 0, "replacement native effect port must not receive physical position")
				for _, script in ipairs(sends) do
					helpers.assert_true(not script:match("^captured%("), "refused event reaches no retained or foreign page effect")
				end
				helpers.assert_eq(writes, 0, "effect replacement never authorizes a publisher")
				s.edge("a", 36, 0, 30); s.edge("b", 42, 0, 40)
				helpers.assert_true(message({ action = "capture_position", request = { request_id = 8 } }), "original port restoration permits a separate observation")
				s.edge("b", 42, 1, 50); s.edge("a", 36, 1, 60)
				local json = sends[#sends]:match("^captured%((.*)%)$")
				helpers.assert_true(type(json) == "string", "actual original Hook emits through the retained page controller")
				local packet = require("json").decode(json)
				helpers.assert_eq(packet.code, "KeyJ", "original native36 crosses the shared registry")
				helpers.assert_eq(packet.mods, { shift = true }, "another original physical source owns Shift")
				helpers.assert_eq(packet.request_id, 8, "page request identity survives all producers")
				helpers.assert_eq(writes, 0, "joint capture publishes no assignment, parameter or output")
				helpers.assert_true(message({ action = "capture_position", request = { request_id = 9 } }))
				local sent = #sends
				paused = true
				s.edge("a", 37, 1, 70)
				helpers.assert_eq(#sends, sent, "live pause withdraws the actual host enrollment before Reader delivery")
				helpers.assert_true(host.close(), "page retirement cancels only observation")
				s.edge("a", 36, 0, 80); s.edge("b", 42, 0, 90)
				helpers.assert_eq(s.rows[#s.rows - 1], { 36, 0 }, "closing page cannot orphan primary physical UP")
				helpers.assert_eq(s.rows[#s.rows], { 42, 0 }, "closing page cannot orphan modifier physical UP")
			end)
			if host then host.close() end
			for _, name in ipairs(names) do package.loaded[name] = previous[name][1] end
			if not called then error(detail, 0) end
		end)
	end)

	helpers.it("refuses effect replacement inside an original canonical getter before delivery", function()
		with_position_capture(nil, function(s)
			local names = { "ui.physical_shortcuts.bridge", "ui.webview_manager", "modules.gestures.manager",
				"infra.paths", "infra.i18n", "logger.shim" }
			local previous = {}; for _, name in ipairs(names) do previous[name] = { package.loaded[name] } end
			local host, receipt, epoch, sends, writes, paused = nil, {}, 0, {}, 0, false
			local replace_on_current
			local called, detail = pcall(function()
				package.loaded["ui.webview_manager"] = { native_available = function() return true end,
					current_epoch = function() return epoch > 0 and epoch or nil end,
					page_current = function(_, exact) return epoch > 0 and epoch == exact end,
					show = function() epoch = 53; return host.on_window_acquiring(epoch) end,
					hide = function(_, exact) if exact ~= epoch then return false end; local old = epoch; epoch = 0; host.on_window_closed(old); return true end,
					eval_js = function(_, script) sends[#sends + 1] = script; return true end }
				package.loaded["modules.gestures.manager"] = { is_assignable = function(action) return action == "none" end,
					get_action_parameter_spec = function() end, validate_action_parameter = function() return false end,
					split_action_parameter_key = function() end, get_action_label = function(action) return action end }
				package.loaded["infra.paths"] = { shared = function(path) return helpers.driver_root() .. "/../_shared/" .. path end }
				package.loaded["infra.i18n"] = { get = function(key) return key end }
				package.loaded["logger.shim"] = helpers.make_logger_stub()
				host = helpers.load_module("ui.physical_shortcuts.bridge")
				local scope = { physical_delivery_available = function() return true end,
					capture_editor_inventory = function() return { assignments = {}, parameters = {} }, receipt end,
					editor_source_current = function(exact)
						if replace_on_current then local replace = replace_on_current; replace_on_current = nil; replace() end
						return rawequal(exact, receipt)
					end,
					edit = function() writes = writes + 1; return false end }
				helpers.assert_true(host.open({ scope = scope, is_paused = function() return paused end }),
					"controlled host prerequisite is not public native delivery qualification")
				local function message(value) return host.on_message(value, {}, { app_name = "physical_shortcuts", epoch = epoch }) end
				helpers.assert_true(message({ action = "ready" }))
				helpers.assert_true(message({ action = "capture_position", request = { request_id = 7 } }))
				local manager = package.loaded["ui.webview_manager"]
				local original_eval = manager.eval_js
				local foreign_calls = 0
				replace_on_current = function() manager.eval_js = function(_, script)
					foreign_calls = foreign_calls + 1
					sends[#sends + 1] = script
					return true
				end end
				s.edge("b", 42, 1, 10); s.edge("a", 36, 1, 20)
				print("INDEPENDENT_FOREIGN_EFFECT_CALLS", foreign_calls, "WRITES", writes)
				manager.eval_js = original_eval
				helpers.assert_eq(foreign_calls, 0, "replacement native effect port must not receive physical position")
				for _, script in ipairs(sends) do
					helpers.assert_true(not script:match("^captured%("), "refused event reaches no retained or foreign page effect")
				end
				helpers.assert_eq(writes, 0, "effect replacement never authorizes a publisher")
				s.edge("a", 36, 0, 30); s.edge("b", 42, 0, 40)
				helpers.assert_true(message({ action = "capture_position", request = { request_id = 8 } }), "original port restoration permits a separate observation")
				s.edge("b", 42, 1, 50); s.edge("a", 36, 1, 60)
				local json = sends[#sends]:match("^captured%((.*)%)$")
				helpers.assert_true(type(json) == "string", "actual original Hook emits through the retained page controller")
				local packet = require("json").decode(json)
				helpers.assert_eq(packet.code, "KeyJ", "original native36 crosses the shared registry")
				helpers.assert_eq(packet.mods, { shift = true }, "another original physical source owns Shift")
				helpers.assert_eq(packet.request_id, 8, "page request identity survives all producers")
				helpers.assert_eq(writes, 0, "joint capture publishes no assignment, parameter or output")
				helpers.assert_true(message({ action = "capture_position", request = { request_id = 9 } }))
				local sent = #sends
				paused = true
				s.edge("a", 37, 1, 70)
				helpers.assert_eq(#sends, sent, "live pause withdraws the actual host enrollment before Reader delivery")
				helpers.assert_true(host.close(), "page retirement cancels only observation")
				s.edge("a", 36, 0, 80); s.edge("b", 42, 0, 90)
				helpers.assert_eq(s.rows[#s.rows - 1], { 36, 0 }, "closing page cannot orphan primary physical UP")
				helpers.assert_eq(s.rows[#s.rows], { 42, 0 }, "closing page cannot orphan modifier physical UP")
			end)
			if host then host.close() end
			for _, name in ipairs(names) do package.loaded[name] = previous[name][1] end
			if not called then error(detail, 0) end
		end)
	end)
end)
