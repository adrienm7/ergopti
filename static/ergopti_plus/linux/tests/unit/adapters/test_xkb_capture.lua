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

	-- The one-shot Shift asks what the next key types before it goes down: a
	-- key that types nothing must leave it armed (one-shot-types-nothing).
	helpers.it("tells what a key would type without pressing it (one-shot-types-nothing)", function()
		local capture, calls = loaded("fr")
		helpers.assert_eq(capture.peek_text(30), "q")
		capture.process(42, 1)
		local before = #calls
		helpers.assert_eq(capture.peek_text(30), "Q", "with the levels held now")
		helpers.assert_eq(capture.peek_text(30), "Q", "asking twice answers the same")
		for index = before + 1, #calls do
			helpers.assert_true(calls[index][1] == "utf8", "a peek commits nothing: " .. tostring(calls[index][1]))
		end
		helpers.assert_eq(capture.peek_text(40), "", "a dead key types nothing by itself")
		helpers.assert_eq(capture.peek_text(99), "", "nor does a key without a character")
		helpers.assert_eq((capture.process(30, 1)), "Q", "the press that follows is not disturbed")
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

helpers.describe("xkb_capture: a modifier key's role comes from the live keymap", function()

	helpers.it("names the role of the keysym the key carries, and refuses before a keymap", function()
		local Capture = helpers.load_module("adapters.xkb_capture")
		local backend = oracle_backend()
		local ralt = 0xfe03
		backend.key_sym = function(_, keycode)
			if keycode == KEY_ALTGR then return ralt end
			if keycode == KEY_A then return "a" end
			return nil
		end
		Capture._set_backend(backend)
		local role, err = Capture.modifier_role(100)
		helpers.assert_nil(role)
		helpers.assert_contains(err, "not ready")
		helpers.assert_true(Capture.load("keymap text", "C"))
		helpers.assert_eq(Capture.modifier_role(100), "altgr", "ISO_Level3_Shift selects a level")
		ralt = 0xffea
		helpers.assert_eq(Capture.modifier_role(100), "alt", "Alt_R starts a shortcut")
		helpers.assert_nil((Capture.modifier_role(30)), "a letter is no modifier")
		Capture._reset_backend()
	end)

end)

helpers.describe("xkb_capture: the injection table comes from the loaded keymap", function()

	helpers.it("refuses before a keymap is loaded", function()
		local Capture = helpers.load_module("adapters.xkb_capture")
		Capture._set_backend(oracle_backend())
		local built, err = Capture.inverse_table()
		helpers.assert_nil(built)
		helpers.assert_contains(err, "not ready")
		Capture._reset_backend()
	end)

	helpers.it("asks the backend that holds the loaded keymap", function()
		-- The real enumeration presses chords on libxkbcommon states and is
		-- proven against compiled fr and Ergopti keymaps by
		-- tests/hardware/run_layout_resolution.lua; here, only the wiring.
		local Capture = helpers.load_module("adapters.xkb_capture")
		local backend = oracle_backend()
		local seen = nil
		backend.inverse = function(session)
			seen = session
			return { a = { keycode = 30, level = 1, mods = {} } }
		end
		Capture._set_backend(backend)
		helpers.assert_true(Capture.load("keymap text", "C"))
		local built = Capture.inverse_table()
		helpers.assert_eq(built.a.keycode, 30)
		helpers.assert_true(seen ~= nil, "the live session must be the one enumerated")
		Capture._reset_backend()
	end)

	helpers.it("reports a backend that cannot enumerate instead of guessing", function()
		local Capture = helpers.load_module("adapters.xkb_capture")
		Capture._set_backend(oracle_backend())
		helpers.assert_true(Capture.load("keymap text", "C"))
		local built, err = Capture.inverse_table()
		helpers.assert_nil(built)
		helpers.assert_contains(err, "cannot enumerate")
		Capture._reset_backend()
	end)

end)

helpers.describe("xkb_capture: physical magic editor source receipts", function()
	local function source_backend()
		local backend = oracle_backend()
		backend.source_group = function(session) return session.group end
		backend.direct_sources = function(session, codes)
			local rows = {}
			for _, code in ipairs(codes) do
				rows[#rows + 1] = { code = code, text = session.group == 1 and ";" or "ù",
					plain = true, direct = true, dead = false }
			end
			return rows
		end
		return backend
	end

	helpers.it("(magic-editor-native) preserves duplicate physical sources and owns the active group epoch", function()
		local capture = helpers.load_module("adapters.xkb_capture")
		capture._set_backend(source_backend())
		helpers.assert_true(capture.load("fr", "C"))
		local first = capture.source_generation()
		local rows = capture.direct_sources({ 30, 40 })
		helpers.assert_eq(#rows, 2, "every actual candidate survives enumeration")
		helpers.assert_eq(rows[1].text, ";")
		helpers.assert_eq(rows[2].text, ";", "an inverse map would silently discard this ambiguity")
		capture.process(30, 1)
		capture.process(30, 0)
		helpers.assert_eq(capture.source_generation(), first, "ordinary down/up does not invalidate delivery")
		capture.process(99, 1)
		capture.process(99, 0)
		helpers.assert_true(capture.source_generation() > first)
		helpers.assert_eq(capture.direct_sources({ 40 })[1].text, "ù", "the same live session proves its new group")
		local switched = capture.source_generation()
		helpers.assert_eq(capture.load("invalid", "C"), false)
		helpers.assert_eq(capture.source_generation(), switched, "a refused keymap leaves its receipt intact")
		helpers.assert_true(capture.reset_state())
		helpers.assert_true(capture.source_generation() > switched, "a real state replacement cancels old receipts")
		capture._reset_backend()
	end)

	helpers.it("(magic-editor-native) refuses unproved groups, invalid registries and backend failures", function()
		local capture = helpers.load_module("adapters.xkb_capture")
		capture._set_backend(oracle_backend())
		helpers.assert_true(capture.load("us", "C"))
		helpers.assert_nil(capture.source_generation(), "a first-match inverse table is no active-group proof")
		helpers.assert_nil(capture.direct_sources({ 30 }))
		local backend = source_backend()
		capture._set_backend(backend)
		helpers.assert_true(capture.load("us", "C"))
		for _, codes in ipairs({ { 30, 30 }, { -1 }, { 768 }, { 30, extra = 40 } }) do
			helpers.assert_nil(capture.direct_sources(codes), "invalid codes must never reach native enumeration")
		end
		backend.direct_sources = function() error("native enumeration refused") end
		local rows, why = capture.direct_sources({ 30 })
		helpers.assert_nil(rows)
		helpers.assert_contains(why, "native enumeration refused")
		capture.clear()
		helpers.assert_nil(capture.source_generation())
		helpers.assert_nil(capture.direct_sources({ 30 }))
		capture._reset_backend()
	end)
end)


helpers.describe("xkb_capture: direct source callback currency", function()
	local function fixture(body)
		local capture = helpers.load_module("adapters.xkb_capture")
		local state = { group = 0, generation = 7, calls = 0 }
		local backend = {
			create = function() return { identity = "controlled-direct-map" } end,
			destroy = function() end,
			update_key = function() end,
		}
		backend.source_group = function()
			state.calls = state.calls + 1
			if state.on_group then state.on_group() end
			return state.group, state.generation
		end
		backend.direct_sources = function(_, codes, group)
			local rows = { { code = codes[1], text = group == 0 and ";" or "ù",
				mods = {}, plain = true, direct = true, dead = false } }
			if state.on_rows then state.on_rows(codes, rows) end
			return rows
		end
		capture._set_backend(backend)
		helpers.assert_true(capture.load("controlled-direct-map", "C"))
		local called, err = pcall(body, capture, state, backend)
		capture._reset_backend()
		if not called then error(err, 0) end
	end

	helpers.it("refuses stale plain rows after a native group transition during enumeration", function()
		fixture(function(capture, state)
			state.on_rows = function() state.group, state.generation = 1, 8 end
			helpers.assert_nil(capture.direct_sources({ 36 }), "old semicolon rows cannot identify the new ù source")
		end)
	end)

	helpers.it("refuses a later native source epoch despite the same group", function()
		fixture(function(capture, state)
			state.on_rows = function() state.generation = 8 end
			helpers.assert_nil(capture.direct_sources({ 36 }))
		end)
	end)

	helpers.it("refuses retired-session rows after a same-map replacement during enumeration", function()
		fixture(function(capture, state)
			state.on_rows = function() helpers.assert_true(capture.load("controlled-direct-map", "C")) end
			helpers.assert_nil(capture.direct_sources({ 36 }))
		end)
	end)

	helpers.it("refuses a session replaced by the initial source observation", function()
		fixture(function(capture, state)
			state.on_group = function()
				state.on_group = nil
				helpers.assert_true(capture.load("controlled-direct-map", "C"))
			end
			helpers.assert_nil(capture.direct_sources({ 36 }))
		end)
	end)

	helpers.it("refuses a session replaced by the final source observation", function()
		fixture(function(capture, state)
			state.on_rows = function()
				state.on_group = function()
					state.on_group = nil
					helpers.assert_true(capture.load("controlled-direct-map", "C"))
				end
			end
			helpers.assert_nil(capture.direct_sources({ 36 }))
		end)
	end)

	helpers.it("detaches requested positions and refuses backend request substitution", function()
		fixture(function(capture, state)
			local codes = { 36 }
			state.on_rows = function(copy, rows) copy[1], rows[1].code = 40, 40 end
			helpers.assert_nil(capture.direct_sources(codes))
			helpers.assert_eq(codes, { 36 }, "native enumeration does not own the caller's request")
		end)
	end)

	helpers.it("keeps the validated positions when source callbacks mutate the caller", function()
		fixture(function(capture, state)
			local codes = { 36 }
			state.on_group = function() codes[1] = 40 end
			local rows = assert(capture.direct_sources(codes))
			helpers.assert_eq(rows[1].code, 36, "only the detached validated position reaches enumeration")
		end)
	end)

	helpers.it("keeps direct-source proof across ordinary reconstructed key events", function()
		fixture(function(capture, state)
			state.on_rows = function() capture.process(42, 0) end
			local rows = assert(capture.direct_sources({ 36 }))
			helpers.assert_eq(rows[1].text, ";")
		end)
	end)
end)


helpers.describe("xkb_capture: selected-group inverse source currency", function()
	local function fixture(body)
		local capture = helpers.load_module("adapters.xkb_capture")
		local state = { calls = 0 }
		local backend = {
			create = function() return { identity = "controlled-inverse-map", group = 0, groups = 2 } end,
			destroy = function() end,
			key_sym = function() return nil end,
			key_utf8 = function() return nil end,
			compose_feed = function() end,
			compose_status = function() return "nothing" end,
			update_key = function(session, code, direction)
				if code == 107 and direction == 1 then session.group = 1 - session.group end
			end,
		}
		backend.capture_group = function(session)
			if state.on_group then state.on_group() end
			return session.group
		end
		backend.inverse = function(session, group)
			state.calls = state.calls + 1
			state.group = group
			if state.on_rows then state.on_rows(session) end
			return { z = { keycode = 44, level = 1, mods = {} } }
		end
		capture._set_backend(backend)
		helpers.assert_true(capture.load("controlled-inverse-map", "C"))
		local called, err = pcall(body, capture, state, backend)
		capture._reset_backend()
		if not called then error(err, 0) end
	end

	helpers.it("passes the actual selected group to inverse enumeration", function()
		fixture(function(capture, state)
			capture.process(99, 1)
			helpers.assert_true(capture.inverse_table() ~= nil)
			helpers.assert_eq(state.group, 1, "the native enumerator must receive the actual selected group")
		end)
	end)

	helpers.it("refuses inverse rows after native group reentry", function()
		fixture(function(capture, state)
			state.on_rows = function() capture.process(99, 1) end
			helpers.assert_nil(capture.inverse_table())
		end)
	end)

	helpers.it("refuses inverse rows after an observed group away-and-back", function()
		fixture(function(capture, state)
			state.on_rows = function() capture.process(99, 1); capture.process(99, 1) end
			helpers.assert_nil(capture.inverse_table(), "equal final group cannot revive a retired inverse source epoch")
		end)
	end)

	helpers.it("refuses inverse rows from a retired same-map session", function()
		fixture(function(capture, state)
			state.on_rows = function() helpers.assert_true(capture.load("controlled-inverse-map", "C")) end
			helpers.assert_nil(capture.inverse_table())
		end)
	end)

	helpers.it("refuses session replacement by initial group observation", function()
		fixture(function(capture, state)
			state.on_group = function()
				state.on_group = nil
				helpers.assert_true(capture.load("controlled-inverse-map", "C"))
			end
			helpers.assert_nil(capture.inverse_table())
		end)
	end)

	helpers.it("refuses session replacement by final group observation", function()
		fixture(function(capture, state)
			state.on_rows = function()
				state.on_group = function()
					state.on_group = nil
					helpers.assert_true(capture.load("controlled-inverse-map", "C"))
				end
			end
			helpers.assert_nil(capture.inverse_table())
		end)
	end)

	helpers.it("refuses invalid native groups before enumeration", function()
		for _, group in ipairs({ -1, 0.5, 2, math.huge, false }) do
			fixture(function(capture, state, backend)
				backend.capture_group = function() return group end
				helpers.assert_nil(capture.inverse_table())
				helpers.assert_eq(state.calls, 0)
			end)
		end
	end)

	helpers.it("preserves native inverse rows across ordinary key transitions", function()
		fixture(function(capture, state)
			state.on_rows = function() capture.process(42, 0) end
			helpers.assert_true(capture.inverse_table() ~= nil)
			helpers.assert_eq(capture.inverse_table().z.keycode, 44)
		end)
	end)
end)

--- Drives real capture, refresh and planning over a controlled native protocol.
--- @param body function
local function cohort_fixture(body)
	local capture = helpers.load_module("adapters.xkb_capture")
	local state = { rows = {} }
	local backend = {
		create = function() return { identity = "owned-cohort-map", group = 0, groups = 2 } end,
		destroy = function() end,
		key_sym = function() return nil end,
		key_utf8 = function() return nil end,
		compose_feed = function() end,
		compose_status = function() return "nothing" end,
		update_key = function(session, code, direction)
			if code == 107 and direction == 1 then session.group = 1 - session.group end
		end,
		capture_group = function(session)
			if state.on_group then state.on_group() end
			return session.group
		end,
		caps_locked = function()
			if state.on_caps then state.on_caps() end
			return state.caps == true
		end,
	}
	backend.inverse = function(session, group)
		local rows = {}
		for code = 32, 126 do rows[string.char(code)] = { keycode = code, level = 1, mods = {} } end
		rows.z = { keycode = group == 1 and 21 or 44, level = 1, mods = {} }
		rows.Z = { keycode = group == 1 and 21 or 44, level = 2, mods = { "shift" } }
		state.rows = rows
		if state.on_inverse then state.on_inverse() end
		return rows
	end
	capture._set_backend(backend)
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	file:write("owned-cohort-map")
	file:close()
	local layout = helpers.load_module("adapters.keyboard_layout")
	local ok, err = pcall(function()
		helpers.assert_true(layout.refresh(path))
		body(capture, layout, state, backend, path)
	end)
	layout._set_table_for_test(nil)
	capture._reset_backend()
	os.remove(path)
	if not ok then error(err, 0) end
end




helpers.describe("xkb_capture: inverse receipt ownership", function()
	helpers.it("retains original source currency without granting caller capabilities", function()
		cohort_fixture(function(capture)
			local _, _, receipt = capture.inverse_table()
			helpers.assert_true(capture.inverse_current(receipt))
			helpers.assert_eq(capture.inverse_current({}), false)
			capture.process(42, 1)
			capture.process(42, 0)
			helpers.assert_true(capture.inverse_current(receipt))
		end)
	end)
	helpers.it("retires receipt after actual group change and observed ABA", function()
		cohort_fixture(function(capture)
			local _, _, receipt = capture.inverse_table()
			capture.process(99, 1)
			helpers.assert_eq(capture.inverse_current(receipt), false)
			capture.process(99, 1)
			helpers.assert_eq(capture.inverse_current(receipt), false)
		end)
	end)
	helpers.it("retires receipt when the same native map gets a new session", function()
		cohort_fixture(function(capture)
			local _, _, receipt = capture.inverse_table()
			capture.reset_state()
			helpers.assert_eq(capture.inverse_current(receipt), false)
		end)
	end)
	helpers.it("refuses getter reentry replacing the original session", function()
		cohort_fixture(function(capture, _, state)
			local _, _, receipt = capture.inverse_table()
			state.on_group = function()
				state.on_group = nil
				capture.reset_state()
			end
			helpers.assert_eq(capture.inverse_current(receipt), false)
		end)
	end)
	helpers.it("refuses replacement of captured enumeration and observation exports", function()
		cohort_fixture(function(capture, _, state, backend)
			local _, _, receipt = capture.inverse_table()
			backend.inverse = function() return state.rows end
			helpers.assert_eq(capture.inverse_current(receipt), false)
		end)
		cohort_fixture(function(capture, _, _, backend)
			local _, _, receipt = capture.inverse_table()
			backend.capture_group = function() return 0 end
			helpers.assert_eq(capture.inverse_current(receipt), false)
		end)
	end)
	helpers.it("detaches native rows and modifier arrays for every enumeration", function()
		cohort_fixture(function(capture, _, state)
			local built = capture.inverse_table()
			state.rows.Z.keycode = 30
			state.rows.Z.mods[1] = "altgr"
			helpers.assert_eq(built.Z.keycode, 44)
			helpers.assert_eq(built.Z.mods[1], "shift")
		end)
	end)
	helpers.it("refuses enumerator replacement within its native callback", function()
		cohort_fixture(function(capture, _, state, backend)
			state.on_inverse = function() backend.inverse = function() return state.rows end end
			helpers.assert_nil(capture.inverse_table())
		end)
	end)
	helpers.it("refuses malformed native inverse modifier data", function()
		cohort_fixture(function(capture, _, state)
			state.on_inverse = function() state.rows.Z.mods[3] = "altgr" end
			helpers.assert_nil(capture.inverse_table())
		end)
	end)
end)

helpers.describe("xkb_capture: terminal inverse observation seal", function()
	helpers.it("seals observations in RAM and never revives a refused full receipt", function()
		cohort_fixture(function(capture, _, state)
			local _, _, receipt = capture.inverse_table()
			state.on_group = function() error("native reads are forbidden in the terminal RAM seal") end
			helpers.assert_true(capture.inverse_current(receipt, true))
			helpers.assert_eq(capture.inverse_current({}, true), false)
			helpers.assert_eq(capture.inverse_current(receipt), false)
			helpers.assert_eq(capture.inverse_current(receipt, true), false)
		end)
	end)
end)
