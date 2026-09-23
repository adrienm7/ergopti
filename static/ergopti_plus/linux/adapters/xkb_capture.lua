--- adapters/xkb_capture.lua

--- ==============================================================================
--- MODULE: XKB Capture Adapter (Linux)
--- DESCRIPTION:
--- Resolves raw evdev key events through the exact XKB keymap used by the active
--- graphical session. It owns the state machine for modifiers, locks, layout
--- groups, dead keys and Compose; keyboard_hook owns only event routing.
---
--- WHY A STATEFUL ADAPTER IS REQUIRED:
--- A keycode table answers only "what is key 30 on one nominal layout?". The
--- desktop answers a different question: "what does key 30 produce in this
--- keymap, with these depressed, latched and locked modifiers, in this group?".
--- Static QWERTY/AZERTY tables therefore diverge silently under CapsLock, AltGr,
--- BÉPO, Dvorak, multi-layout sessions and any compositor-side customization.
---
--- FEATURES & RATIONALE:
--- 1. Exact keymap text. keyboard_layout obtains one server dump and loads it
---    here as well as building the inverse injection table. Capture and output
---    cannot accidentally describe two different layouts.
--- 2. Exact event state. Every down and up transition reaches libxkbcommon;
---    repeats resolve again without applying a duplicate transition.
--- 3. Compose is first-class. Dead keys arm libxkbcommon's locale-specific
---    Compose state and emit only the completed UTF-8 result.
--- 4. Atomic reload. A new context, keymap, state and Compose state are fully
---    constructed before replacing the live session. A bad hot reload leaves
---    the last validated session intact.
--- 5. Swappable backend. Production uses LuaJIT FFI; unit tests use a stateful
---    oracle, so Windows CI proves event ordering without pretending to provide
---    a Linux display server.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Keysym = require("infra.keysym")
local EvdevCodes = require("infra.evdev_codes")

local LOG = "adapters.xkb_capture"





-- =========================================
-- =========================================
-- ======= 1/ Protocol constants ===========
-- =========================================
-- =========================================

-- Linux evdev codes are eight below the XKB keycodes in an Xorg-compatible
-- keymap. This is the protocol offset, not a layout-specific guess.
local EVDEV_TO_XKB_OFFSET = 8

local VALUE_UP = 0
local VALUE_DOWN = 1
local VALUE_REPEAT = 2

local XKB_KEY_UP = 0
local XKB_KEY_DOWN = 1

-- The two modifier keys the injector presses (modules/hotstrings/injector.lua
-- MODIFIER_CODES), in XKB numbering, so the inverse table is probed with the
-- very chords that will be emitted.
local XKB_LEFTSHIFT = EvdevCodes.KEY_LEFTSHIFT + EVDEV_TO_XKB_OFFSET
local XKB_RIGHTALT = EvdevCodes.KEY_RIGHTALT + EVDEV_TO_XKB_OFFSET

-- The highest evdev code the virtual keyboard registers (uinput_writer's
-- KEY_CODE_MAX); a character on a higher key could never be typed.
local UINPUT_KEY_MAX = 0x2FF





-- =========================================
-- =========================================
-- ======= 2/ Backend lifecycle =============
-- =========================================
-- =========================================

-- Backend contract:
--   create(keymap_text, locale) -> session|nil, err
--   destroy(session)
--   key_sym(session, xkb_keycode) -> keysym|nil
--   key_utf8(session, xkb_keycode) -> string|nil
--   sym_utf8(session, keysym) -> string|nil
--   update_key(session, xkb_keycode, XKB_KEY_{UP,DOWN})
--   compose_feed/status/utf8/reset(session, ...)
local _backend = nil
local _session = nil
local _keymap_text = nil
local _locale = nil

local function current_locale()
	-- Store NAMES rather than values: ipairs stops at the first nil, and LC_ALL
	-- is commonly unset while LANG carries the only valid Compose locale.
	for _, name in ipairs({ "LC_ALL", "LC_CTYPE", "LANG" }) do
		local value = os.getenv(name)
		if type(value) == "string" and value ~= "" then return value end
	end
	return "C"
end

local function destroy(session)
	if session and _backend and type(_backend.destroy) == "function" then
		pcall(_backend.destroy, session)
	end
end

--- Installs a backend and clears any session owned by the previous one.
--- Test seam; production binds lazily through bind_ffi_backend().
--- @param backend table|nil
function M._set_backend(backend)
	destroy(_session)
	_backend = backend
	_session = nil
	_keymap_text = nil
	_locale = nil
end

--- Drops the test backend and all retained keymap state.
function M._reset_backend()
	M._set_backend(nil)
end





-- =========================================
-- =========================================
-- ======= 3/ LuaJIT FFI backend ============
-- =========================================
-- =========================================

local function bind_ffi_backend()
	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi or type(ffi) ~= "table" then
		return false, "LuaJIT FFI unavailable"
	end

	local ok_cdef, cdef_err = pcall(ffi.cdef, [[
		struct xkb_context;
		struct xkb_keymap;
		struct xkb_state;
		struct xkb_compose_table;
		struct xkb_compose_state;

		struct xkb_context *xkb_context_new(int flags);
		void xkb_context_unref(struct xkb_context *context);
		struct xkb_keymap *xkb_keymap_new_from_string(
			struct xkb_context *context,
			const char *string,
			int format,
			int flags);
		void xkb_keymap_unref(struct xkb_keymap *keymap);
		struct xkb_state *xkb_state_new(struct xkb_keymap *keymap);
		void xkb_state_unref(struct xkb_state *state);
		unsigned int xkb_state_update_key(
			struct xkb_state *state,
			unsigned int key,
			int direction);
		int xkb_state_key_get_utf8(
			struct xkb_state *state,
			unsigned int key,
			char *buffer,
			unsigned long size);
		unsigned int xkb_state_key_get_one_sym(
			struct xkb_state *state,
			unsigned int key);
		unsigned int xkb_keymap_min_keycode(struct xkb_keymap *keymap);
		unsigned int xkb_keymap_max_keycode(struct xkb_keymap *keymap);
		const char *xkb_keymap_key_get_name(struct xkb_keymap *keymap, unsigned int key);
		int xkb_state_mod_name_is_active(struct xkb_state *state, const char *name, int type);

		struct xkb_compose_table *xkb_compose_table_new_from_locale(
			struct xkb_context *context,
			const char *locale,
			int flags);
		void xkb_compose_table_unref(struct xkb_compose_table *table);
		struct xkb_compose_state *xkb_compose_state_new(
			struct xkb_compose_table *table,
			int flags);
		void xkb_compose_state_unref(struct xkb_compose_state *state);
		int xkb_compose_state_feed(
			struct xkb_compose_state *state,
			unsigned int keysym);
		int xkb_compose_state_get_status(struct xkb_compose_state *state);
		int xkb_compose_state_get_utf8(
			struct xkb_compose_state *state,
			char *buffer,
			unsigned long size);
		void xkb_compose_state_reset(struct xkb_compose_state *state);
	]])
	if not ok_cdef and not tostring(cdef_err):find("redefin", 1, true) then
		return false, "ffi.cdef failed: " .. tostring(cdef_err)
	end

	local ok_lib, lib = pcall(ffi.load, "xkbcommon.so.0")
	if not ok_lib then ok_lib, lib = pcall(ffi.load, "xkbcommon") end
	if not ok_lib then return false, "libxkbcommon.so.0 is not loadable" end

	local XKB_KEYMAP_FORMAT_TEXT_V1 = 1
	local XKB_COMPOSE_NOTHING = 0
	local XKB_COMPOSE_COMPOSING = 1
	local XKB_COMPOSE_COMPOSED = 2
	local XKB_COMPOSE_CANCELLED = 3
	local small_buffer = ffi.new("char[64]")

	local function utf8_from(call)
		local required = tonumber(call(small_buffer, 64)) or 0
		if required <= 0 then return nil end
		if required < 64 then return ffi.string(small_buffer, required) end
		local buffer = ffi.new("char[?]", required + 1)
		local written = tonumber(call(buffer, required + 1)) or 0
		if written <= 0 then return nil end
		return ffi.string(buffer, written)
	end

	local backend = {}

	function backend.create(text, locale)
		local session = {}
		session.context = lib.xkb_context_new(0)
		if session.context == nil then return nil, "xkb_context_new failed" end

		session.keymap = lib.xkb_keymap_new_from_string(
			session.context, text, XKB_KEYMAP_FORMAT_TEXT_V1, 0)
		if session.keymap == nil then
			lib.xkb_context_unref(session.context)
			return nil, "xkb_keymap_new_from_string rejected the active keymap"
		end

		session.state = lib.xkb_state_new(session.keymap)
		if session.state == nil then
			lib.xkb_keymap_unref(session.keymap)
			lib.xkb_context_unref(session.context)
			return nil, "xkb_state_new failed"
		end

		session.compose_table = lib.xkb_compose_table_new_from_locale(
			session.context, locale, 0)
		if session.compose_table == nil then
			lib.xkb_state_unref(session.state)
			lib.xkb_keymap_unref(session.keymap)
			lib.xkb_context_unref(session.context)
			return nil, "no Compose table for locale " .. tostring(locale)
		end

		session.compose_state = lib.xkb_compose_state_new(session.compose_table, 0)
		if session.compose_state == nil then
			lib.xkb_compose_table_unref(session.compose_table)
			lib.xkb_state_unref(session.state)
			lib.xkb_keymap_unref(session.keymap)
			lib.xkb_context_unref(session.context)
			return nil, "xkb_compose_state_new failed"
		end
		return session
	end

	function backend.destroy(session)
		lib.xkb_compose_state_unref(session.compose_state)
		lib.xkb_compose_table_unref(session.compose_table)
		lib.xkb_state_unref(session.state)
		lib.xkb_keymap_unref(session.keymap)
		lib.xkb_context_unref(session.context)
	end

	function backend.key_sym(session, keycode)
		local sym = tonumber(lib.xkb_state_key_get_one_sym(session.state, keycode)) or 0
		return sym ~= 0 and sym or nil
	end

	function backend.key_utf8(session, keycode)
		return utf8_from(function(buffer, size)
			return lib.xkb_state_key_get_utf8(session.state, keycode, buffer, size)
		end)
	end

	function backend.sym_utf8(_session, sym)
		return Keysym.from_id(sym)
	end

	function backend.update_key(session, keycode, direction)
		lib.xkb_state_update_key(session.state, keycode, direction)
	end

	function backend.compose_feed(session, sym)
		lib.xkb_compose_state_feed(session.compose_state, sym or 0)
	end

	function backend.compose_status(session)
		local status = tonumber(lib.xkb_compose_state_get_status(session.compose_state))
		if status == XKB_COMPOSE_COMPOSING then return "composing" end
		if status == XKB_COMPOSE_COMPOSED then return "composed" end
		if status == XKB_COMPOSE_CANCELLED then return "cancelled" end
		if status == XKB_COMPOSE_NOTHING then return "nothing" end
		return "invalid"
	end

	function backend.compose_utf8(session)
		return utf8_from(function(buffer, size)
			return lib.xkb_compose_state_get_utf8(session.compose_state, buffer, size)
		end)
	end

	function backend.compose_reset(session)
		lib.xkb_compose_state_reset(session.compose_state)
	end

	-- XKB_STATE_MODS_LOCKED: CapsLock toggles the Lock modifier into the locked set.
	local XKB_STATE_MODS_LOCKED = 4
	function backend.caps_locked(session)
		return lib.xkb_state_mod_name_is_active(session.state, "Lock", XKB_STATE_MODS_LOCKED) == 1
	end

	-- The physical chords the injector can press, cheapest first. Each is
	-- pressed on a FRESH state, so the answer is what an application receives
	-- from exactly that chord — whatever the key's type says a level means.
	local CHORDS = {
		{ level = 1, mods = {},                  keys = {} },
		{ level = 2, mods = { "shift" },         keys = { XKB_LEFTSHIFT } },
		{ level = 3, mods = { "altgr" },         keys = { XKB_RIGHTALT } },
		{ level = 4, mods = { "shift", "altgr" }, keys = { XKB_LEFTSHIFT, XKB_RIGHTALT } },
	}

	-- The typing block first (evdev 1-58 and the ISO key 86), across every
	-- chord, before anything else. A keymap also binds characters to exotic
	-- keys — EuroSign on a multimedia key at level 1, a parenthesis on
	-- KEY_KPLEFTPAREN — that some applications ignore; a real key with a
	-- modifier is what a person would press, so it wins.
	local function in_typing_block(evdev)
		return (evdev >= 1 and evdev <= 58) or evdev == 86
	end

	function backend.inverse(session)
		local table_out = {}
		local low = math.max(tonumber(lib.xkb_keymap_min_keycode(session.keymap)) or 8, 8)
		local high = tonumber(lib.xkb_keymap_max_keycode(session.keymap)) or 255
		for _, typing_block in ipairs({ true, false }) do
		for _, chord in ipairs(CHORDS) do
			for keycode = low, math.min(high, UINPUT_KEY_MAX + EVDEV_TO_XKB_OFFSET) do
				if in_typing_block(keycode - EVDEV_TO_XKB_OFFSET) ~= typing_block then goto next_key end
				local name_ptr = lib.xkb_keymap_key_get_name(session.keymap, keycode)
				local name = name_ptr ~= nil and ffi.string(name_ptr) or nil
				-- Keypad keys are never used: their levels depend on NumLock,
				-- which the injector neither reads nor presses, so the same
				-- chord types a digit or moves the caret depending on a LED.
				if name and not name:match("^KP") then
					local state = lib.xkb_state_new(session.keymap)
					if state ~= nil then
						for _, mod_key in ipairs(chord.keys) do
							lib.xkb_state_update_key(state, mod_key, XKB_KEY_DOWN)
						end
						local text = utf8_from(function(buffer, size)
							return lib.xkb_state_key_get_utf8(state, keycode, buffer, size)
						end)
						lib.xkb_state_unref(state)
						local first = text and text:byte(1)
						if first and first >= 32 and first ~= 127 and not table_out[text] then
							table_out[text] = {
								keycode = keycode - EVDEV_TO_XKB_OFFSET,
								level = chord.level,
								mods = chord.mods,
							}
						end
					end
				end
				::next_key::
			end
		end
		end
		return table_out
	end

	_backend = backend
	Logger.debug(LOG, "libxkbcommon capture backend bound.")
	return true
end

local function ensure_backend()
	if _backend then return true end
	return bind_ffi_backend()
end





-- =========================================
-- =========================================
-- ======= 4/ Keymap state =================
-- =========================================
-- =========================================

local function candidate(text, locale)
	local ok_backend, backend_err = ensure_backend()
	if not ok_backend then return nil, backend_err end

	local ok_create, session, create_err = pcall(_backend.create, text, locale)
	if not ok_create then return nil, tostring(session) end
	if not session then return nil, create_err or "backend refused the keymap" end
	return session
end

--- Loads keymap text into a fresh XKB and Compose state, then publishes it.
--- @param text string Complete XKB keymap text.
--- @param locale string|nil Compose locale; defaults to the process locale.
--- @return boolean ok, string|nil error
function M.load(text, locale)
	if type(text) ~= "string" or text == "" then
		return false, "non-empty XKB keymap text is required"
	end
	local selected_locale = type(locale) == "string" and locale ~= "" and locale or current_locale()
	local next_session, err = candidate(text, selected_locale)
	if not next_session then return false, err end

	local previous = _session
	_session = next_session
	_keymap_text = text
	_locale = selected_locale
	destroy(previous)
	return true
end

--- Recreates a clean state from the last validated keymap.
--- @return boolean ok, string|nil error
function M.reset_state()
	if not _keymap_text then return false, "no validated XKB keymap is loaded" end
	local next_session, err = candidate(_keymap_text, _locale)
	if not next_session then return false, err end
	local previous = _session
	_session = next_session
	destroy(previous)
	return true
end

--- Releases all native objects and forgets the retained keymap.
function M.clear()
	destroy(_session)
	_session = nil
	_keymap_text = nil
	_locale = nil
end

--- @return boolean True when process() has a validated live state.
function M.is_ready()
	return _session ~= nil
end

--- Whether CapsLock is locked in the live capture state.
---
--- The state follows every physical key transition, CapsLock included, so it
--- is the session's own answer; the LED is not, because under the grab the
--- kernel drops the compositor's LED writes to the grabbed keyboard.
--- @return boolean
function M.caps_locked()
	if not _session or type(_backend.caps_locked) ~= "function" then return false end
	local ok, locked = pcall(_backend.caps_locked, _session)
	return ok and locked == true
end

--- The character → keystroke table injection types with, asked of libxkbcommon.
---
--- Built by pressing each chord the injector can emit (none, Shift, AltGr,
--- Shift+AltGr) on a fresh state of the LOADED keymap and recording what comes
--- out, cheapest chord first and lowest keycode first. It replaced a text
--- parser that assumed every key followed the standard four-level type and
--- walked keys in hash order: on AZERTY a digit could be planned as Shift+KP1,
--- which moves the caret, differently from one start to the next; on the
--- Ergopti layout, whose types put Shift on level 3, most characters came out
--- wrong or went through the clipboard.
--- @return table|nil char → { keycode = evdev, level = integer, mods = table }
--- @return string|nil error
function M.inverse_table()
	if not _session then return nil, "XKB capture state is not ready" end
	if type(_backend.inverse) ~= "function" then
		return nil, "the capture backend cannot enumerate the keymap"
	end
	local ok, built = pcall(_backend.inverse, _session)
	if not ok then return nil, tostring(built) end
	return built
end





-- =========================================
-- =========================================
-- ======= 5/ Event resolution ==============
-- =========================================
-- =========================================

local function resolve_press(keycode)
	local sym = _backend.key_sym(_session, keycode)
	local identity = sym and _backend.sym_utf8(_session, sym) or nil
	local text = _backend.key_utf8(_session, keycode)

	_backend.compose_feed(_session, sym)
	local status = _backend.compose_status(_session)
	if status == "composing" then
		text = nil
	elseif status == "composed" then
		text = _backend.compose_utf8(_session)
		_backend.compose_reset(_session)
	elseif status == "cancelled" then
		-- The dead key itself emitted nothing. On cancellation, preserve the
		-- current ordinary key, exactly as higher-level XKB clients do.
		_backend.compose_reset(_session)
	elseif status ~= "nothing" then
		error("invalid Compose status: " .. tostring(status))
	end
	return text, identity
end

--- Applies one evdev key transition and resolves its UTF-8 output.
---
--- Resolution deliberately happens before committing a key-down. Modifier,
--- lock and group actions affect the next key; the current key is interpreted
--- against the state that led to the event. Repeats resolve against the current
--- state and never apply a duplicate action.
--- @param evdev_code integer Linux input-event keycode.
--- @param value integer 0 release, 1 press, 2 repeat.
--- @return string|nil text, string|nil identity, string|nil error
function M.process(evdev_code, value)
	if not _session then return nil, nil, "XKB capture state is not ready" end
	if type(evdev_code) ~= "number" or evdev_code < 0 or evdev_code % 1 ~= 0 then
		return nil, nil, "evdev keycode must be a non-negative integer"
	end
	if value ~= VALUE_UP and value ~= VALUE_DOWN and value ~= VALUE_REPEAT then
		return nil, nil, "evdev value must be 0, 1 or 2"
	end

	local keycode = evdev_code + EVDEV_TO_XKB_OFFSET
	if value == VALUE_UP then
		local ok, err = pcall(_backend.update_key, _session, keycode, XKB_KEY_UP)
		if not ok then return nil, nil, tostring(err) end
		return nil, nil, nil
	end

	local ok_resolve, text, identity = pcall(resolve_press, keycode)
	if not ok_resolve then return nil, nil, tostring(text) end
	if value == VALUE_DOWN then
		local ok_update, update_err = pcall(
			_backend.update_key, _session, keycode, XKB_KEY_DOWN)
		if not ok_update then return nil, nil, tostring(update_err) end
	end
	return text, identity, nil
end

M.EVDEV_TO_XKB_OFFSET = EVDEV_TO_XKB_OFFSET

return M
