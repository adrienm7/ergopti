--- tests/unit/adapters/test_xkb_capture.lua

--- ==============================================================================
--- MODULE: Live XKB Capture Regression Tests
--- DESCRIPTION:
--- Proves that evdev events are resolved through one stateful XKB session rather
--- than through a static keycode table. The fake backend below is an executable
--- oracle for the state transitions the adapter owns; the production backend is
--- libxkbcommon and has the same narrow contract.
---
--- DEFECTS GUARDED:
--- 1. evdev keycodes need the XKB offset of eight. Omitting it maps every physical
---    key to a different symbol while still returning plausible characters.
--- 2. A key is resolved against the state that existed before its own key-down,
---    then the transition is committed. This is what lets Shift, CapsLock, AltGr
---    and group-switch keys affect the following key without becoming text.
--- 3. Repeats produce text but must not apply a second state transition. Applying
---    CapsLock or a group action twice makes held-key behaviour depend on repeat.
--- 4. Compose is a state machine. A dead key produces nothing, and the completed
---    sequence produces one UTF-8 result instead of two unrelated characters.
--- ==============================================================================

local helpers = require("tests.helpers")





-- =========================================
-- =========================================
-- ======= 1/ Stateful backend model =======
-- =========================================
-- =========================================

local XKB_OFFSET = 8
local KEY_A = 30 + XKB_OFFSET
local KEY_E = 18 + XKB_OFFSET
local KEY_DEAD = 40 + XKB_OFFSET
local KEY_LEFTSHIFT = 42 + XKB_OFFSET
local KEY_RIGHTSHIFT = 54 + XKB_OFFSET
local KEY_CAPSLOCK = 58 + XKB_OFFSET
local KEY_ALTGR = 100 + XKB_OFFSET
local KEY_GROUP = 99 + XKB_OFFSET

local function oracle_backend()
	local calls = {}

	local function shifted(session)
		local held = session.held[KEY_LEFTSHIFT] or session.held[KEY_RIGHTSHIFT]
		return (held and not session.caps) or (session.caps and not held)
	end

	local function symbol(session, keycode)
		if keycode == KEY_DEAD then return "dead_acute" end
		if keycode == KEY_E and session.held[KEY_ALTGR] then return "EuroSign" end
		if keycode ~= KEY_A then return keycode == KEY_E and "e" or nil end

		local base
		if session.layout == "fr" then
			base = session.group == 1 and "q" or "a"
		else
			base = session.group == 1 and "a" or "q"
		end
		return shifted(session) and base:upper() or base
	end

	local backend = {
		create = function(text, locale)
			calls[#calls + 1] = { "create", text, locale }
			if text == "invalid" then return nil, "invalid keymap" end
			return {
				layout = text,
				locale = locale,
				held = {},
				caps = false,
				group = 1,
				compose = "nothing",
			}
		end,
		destroy = function(session)
			session.destroyed = true
			calls[#calls + 1] = { "destroy", session.layout }
		end,
		key_sym = function(session, keycode)
			calls[#calls + 1] = { "sym", keycode }
			return symbol(session, keycode)
		end,
		key_utf8 = function(session, keycode)
			calls[#calls + 1] = { "utf8", keycode }
			local sym = symbol(session, keycode)
			if sym == "EuroSign" then return "€" end
			if sym == "dead_acute" then return nil end
			return sym
		end,
		sym_utf8 = function(_session, sym)
			if sym == "EuroSign" then return "€" end
			if sym == "dead_acute" then return nil end
			return sym
		end,
		update_key = function(session, keycode, direction)
			calls[#calls + 1] = { "update", keycode, direction }
			local down = direction == 1
			if keycode == KEY_LEFTSHIFT or keycode == KEY_RIGHTSHIFT or keycode == KEY_ALTGR then
				session.held[keycode] = down or nil
			elseif down and keycode == KEY_CAPSLOCK then
				session.caps = not session.caps
			elseif down and keycode == KEY_GROUP then
				session.group = session.group == 1 and 2 or 1
			end
		end,
		compose_feed = function(session, sym)
			if sym == "dead_acute" then
				session.compose = "composing"
			elseif session.compose == "composing" and sym == "e" then
				session.compose = "composed"
			elseif session.compose == "composing" then
				session.compose = "cancelled"
			else
				session.compose = "nothing"
			end
		end,
		compose_status = function(session) return session.compose end,
		compose_utf8 = function(session)
			return session.compose == "composed" and "é" or nil
		end,
		compose_reset = function(session) session.compose = "nothing" end,
	}

	return backend, calls
end

local function loaded(layout)
	local capture = helpers.load_module("adapters.xkb_capture")
	local backend, calls = oracle_backend()
	capture._set_backend(backend)
	local ok, err = capture.load(layout or "us", "fr_FR.UTF-8")
	helpers.assert_true(ok, "the oracle keymap should load: " .. tostring(err))
	return capture, calls
end





-- =========================================
-- =========================================
-- ======= 2/ Event ordering ===============
-- =========================================
-- =========================================

helpers.describe("xkb_capture: exact evdev event semantics", function()
	helpers.it("adds the XKB offset and resolves before committing key-down", function()
		local capture, calls = loaded("fr")
		local text, identity = capture.process(30, 1)

		helpers.assert_eq(text, "q", "physical KEY_A is Q in the live French keymap")
		helpers.assert_eq(identity, "q", "shortcut identity comes from the active keysym")
		helpers.assert_eq(calls[2], { "sym", KEY_A }, "keysym sees evdev code plus eight")
		helpers.assert_eq(calls[3], { "utf8", KEY_A }, "UTF-8 uses the same exact keycode")
		helpers.assert_eq(calls[4], { "update", KEY_A, 1 },
			"the current key resolves before its own down transition is committed")
	end)

	helpers.it("updates releases but does not resolve or reapply repeats", function()
		local capture, calls = loaded("us")
		capture.process(30, 1)
		local before_repeat = #calls
		helpers.assert_eq((capture.process(30, 2)), "a", "autorepeat still produces text")
		helpers.assert_eq(#calls, before_repeat + 2,
			"repeat resolves keysym and UTF-8 but adds no state transition")

		local before_release = #calls
		helpers.assert_eq((capture.process(30, 0)), nil, "release produces no text")
		helpers.assert_eq(#calls, before_release + 1, "release performs exactly one update")
		helpers.assert_eq(calls[#calls], { "update", KEY_A, 0 }, "release direction is exact")
	end)
end)





-- =========================================
-- =========================================
-- ======= 3/ Stateful layout behaviour ====
-- =========================================
-- =========================================

helpers.describe("xkb_capture: locks, levels and groups", function()
	helpers.it("keeps Shift active until both physical Shift keys are released", function()
		local capture = loaded("fr")
		capture.process(42, 1)
		capture.process(54, 1)
		capture.process(42, 0)
		helpers.assert_eq((capture.process(30, 1)), "Q",
			"releasing Left Shift must not clear Right Shift")
		capture.process(30, 0)
		capture.process(54, 0)
		helpers.assert_eq((capture.process(30, 1)), "q", "both releases clear Shift")
	end)

	helpers.it("applies CapsLock and AltGr through XKB state", function()
		local capture = loaded("fr")
		capture.process(58, 1)
		capture.process(58, 0)
		helpers.assert_eq((capture.process(30, 1)), "Q", "CapsLock affects the next letter")
		capture.process(30, 0)

		capture.process(100, 1)
		local euro, identity = capture.process(18, 1)
		helpers.assert_eq(euro, "€", "AltGr selects the live keymap's third level")
		helpers.assert_eq(identity, "€", "the keysym identity is not a Ctrl transformation")
	end)

	helpers.it("switches groups from the keymap action without reloading a table", function()
		local capture = loaded("fr")
		helpers.assert_eq((capture.process(30, 1)), "q", "group one is French")
		capture.process(30, 0)
		capture.process(99, 1)
		capture.process(99, 0)
		helpers.assert_eq((capture.process(30, 1)), "a",
			"the group-switch event changes the following key immediately")
	end)
end)





-- =========================================
-- =========================================
-- ======= 4/ Compose and reload ============
-- =========================================
-- =========================================

helpers.describe("xkb_capture: Compose and atomic keymap reload", function()
	helpers.it("suppresses a dead key and emits the completed composed string", function()
		local capture = loaded("fr")
		helpers.assert_eq((capture.process(40, 1)), nil, "dead key arms Compose and types nothing")
		capture.process(40, 0)
		helpers.assert_eq((capture.process(18, 1)), "é", "the sequence emits one composed result")
	end)

	helpers.it("keeps the previous session when a replacement keymap is invalid", function()
		local capture = loaded("fr")
		local ok = capture.load("invalid", "fr_FR.UTF-8")
		helpers.assert_true(not ok, "invalid keymap must be refused")
		helpers.assert_true(capture.is_ready(), "the last valid state remains available")
		helpers.assert_eq((capture.process(30, 1)), "q",
			"failed hot reload cannot publish a half-built replacement")
	end)

	helpers.it("recreates a clean state while retaining the validated keymap", function()
		local capture = loaded("us")
		capture.process(58, 1)
		capture.process(58, 0)
		helpers.assert_eq((capture.process(30, 1)), "A", "lock is active before reset")
		helpers.assert_true(capture.reset_state(), "reset should rebuild from the retained keymap")
		helpers.assert_eq((capture.process(30, 1)), "a", "a new capture session starts clean")
	end)
end)
