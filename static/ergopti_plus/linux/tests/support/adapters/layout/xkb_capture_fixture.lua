--- tests/support/adapters/layout/xkb_capture_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_xkb_capture
--- DESCRIPTION:
--- Prelude shared by the test_xkb_capture_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
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

local function with_original_direct_producer(body)
 local prior = package.loaded['adapters.xkb_capture']
 package.loaded['adapters.xkb_capture'] = nil
 local capture = require('adapters.xkb_capture')
 local state = { calls = 0, generation = 7, group = 0, enumerations = 0, updates = 0 }
 local session
 local backend = {
  create = function() session = { identity = 'controlled-direct-map', groups = 2 }; return session end,
  destroy = function() end,
  source_group = function()
   state.calls = state.calls + 1
   if state.on_source then state.on_source(state.calls) end
   return state.group, state.generation, function() return true end
  end,
  direct_sources = function(_, requested, group)
   state.enumerations = state.enumerations + 1
   state.requested = requested
   local rows = {}
   for _, code in ipairs(requested) do
    rows[#rows + 1] = { code = code, text = group == 0 and ';' or 'ù',
     mods = {}, plain = true, direct = true, dead = false }
   end
   if state.on_rows then state.on_rows(requested, rows) end
   return rows
  end,
  update_key = function() state.updates = state.updates + 1 end,
 }
 capture._set_backend(backend)
 local called, reason = pcall(function()
  helpers.assert_true(capture.load('controlled-direct-map', 'C'))
  body(capture, state, backend, session)
 end)
 capture._reset_backend()
 package.loaded['adapters.xkb_capture'] = prior
 if not called then error(reason, 0) end
end

return {
	helpers = helpers,
	XKB_OFFSET = XKB_OFFSET,
	KEY_A = KEY_A,
	KEY_E = KEY_E,
	KEY_DEAD = KEY_DEAD,
	KEY_LEFTSHIFT = KEY_LEFTSHIFT,
	KEY_RIGHTSHIFT = KEY_RIGHTSHIFT,
	KEY_CAPSLOCK = KEY_CAPSLOCK,
	KEY_ALTGR = KEY_ALTGR,
	KEY_GROUP = KEY_GROUP,
	oracle_backend = oracle_backend,
	loaded = loaded,
	cohort_fixture = cohort_fixture,
	with_original_direct_producer = with_original_direct_producer,
}
