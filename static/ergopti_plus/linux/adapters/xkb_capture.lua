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
local NumberRow = require("layout.number_row_native")
local number_row_receipts = setmetatable({}, { __mode = "k" })

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

-- The keysyms (keysymdef.h) that make a key a modifier, by the role the
-- keyboard hook gives it: shift and altgr select a level of the layout and so
-- produce text, ctrl, alt and meta start a shortcut. A physical key has no
-- role of its own: Right Alt is ISO_Level3_Shift (AltGr) on a French or
-- Ergopti layout and plain Alt_R on a US one, and XKB options move roles
-- between keys.
local MODIFIER_ROLE_OF_KEYSYM = {
	[0xffe1] = "shift", [0xffe2] = "shift", -- Shift_L, Shift_R
	[0xffe3] = "ctrl",  [0xffe4] = "ctrl",  -- Control_L, Control_R
	[0xffe7] = "alt",   [0xffe8] = "alt",   -- Meta_L, Meta_R
	[0xffe9] = "alt",   [0xffea] = "alt",   -- Alt_L, Alt_R
	[0xffeb] = "meta",  [0xffec] = "meta",  -- Super_L, Super_R
	[0xffed] = "meta",  [0xffee] = "meta",  -- Hyper_L, Hyper_R
	[0xfe03] = "altgr",                     -- ISO_Level3_Shift
	[0xfe11] = "altgr",                     -- ISO_Level5_Shift
	[0xff7e] = "altgr",                     -- Mode_switch
}





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
local _source_generation = 0
local _physical_probe_epoch = 0
local _physical_chord_receipts = setmetatable({}, { __mode = "k" })
local _source_group = nil
local _source_native_generation = nil
local _capture_group, _capture_generation = nil, 0
local _inverse_receipts = setmetatable({}, { __mode = "k" })

--- Tracks source changes without treating an ordinary key-up as a rebind.
local function source_identity()
	if not _session or type(_backend.source_group) ~= "function" then return nil, "the capture backend cannot prove its active group" end
	local ok, group, native_generation, observed_current = pcall(_backend.source_group, _session)
	if not ok or type(group) ~= "number" or group < 0 or group % 1 ~= 0 then
		return nil, type(native_generation) == "string" and native_generation or "the capture backend returned no active group"
	end
	if _source_group ~= group or _source_native_generation ~= native_generation then
		_source_group, _source_native_generation = group, native_generation
		_source_generation = _source_generation + 1
	end
	return _source_generation, nil, observed_current
end

-- The reconstructed capture state is useful for native-library qualification,
-- but is never desktop source evidence. Production admission uses source_identity.
local function capture_identity()
	if not _session then return nil end
	local getter = _backend.capture_group or _backend.source_group
	if type(getter) ~= "function" then return nil end
	local ok, group = pcall(getter, _session)
	if not ok or type(group) ~= "number" then return nil end
	if _capture_group ~= group then _capture_group, _capture_generation = group, _capture_generation + 1 end
	return _capture_generation, group
end

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
	if _backend and _backend.desktop_proof then require("adapters.xkb_source_probe").close() end
	_backend = backend
	_session = nil
	_keymap_text = nil
	_locale = nil
	_source_group, _source_native_generation = nil, nil
	_capture_group, _capture_generation = nil, _capture_generation + 1
	_source_generation = _source_generation + 1
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
		unsigned int xkb_keymap_num_layouts(struct xkb_keymap *keymap);
		unsigned int xkb_keymap_mod_get_index(struct xkb_keymap *keymap, const char *name);
		char *xkb_keymap_get_as_string(struct xkb_keymap *keymap, int format);
		void free(void *pointer);
		const char *xkb_keymap_key_get_name(struct xkb_keymap *keymap, unsigned int key);
		int xkb_state_mod_name_is_active(struct xkb_state *state, const char *name, int type);
		int xkb_keysym_get_name(unsigned int keysym, char *buffer, unsigned long size);
		unsigned int xkb_state_serialize_layout(struct xkb_state *state, int components);
		unsigned int xkb_state_serialize_mods(struct xkb_state *state, int components);
		unsigned int xkb_state_update_mask(struct xkb_state *state,
			unsigned int depressed_mods, unsigned int latched_mods, unsigned int locked_mods,
			unsigned int depressed_layout, unsigned int latched_layout, unsigned int locked_layout);

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

	local soname = require("_generated.native_runtime").xkbcommon
	local ok_lib, lib = pcall(ffi.load, soname)
	if not ok_lib then return false, soname .. " is not loadable" end

	local XKB_KEYMAP_FORMAT_TEXT_V1 = 1
	local XKB_STATE_LAYOUT_EFFECTIVE = 128
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

	local backend = { desktop_proof = true }
	local SourceProbe = require("adapters.xkb_source_probe")
	local source_read = SourceProbe.read
	local source_close = SourceProbe.close
	local function probe_current()
		return package.loaded["adapters.xkb_source_probe"] == SourceProbe
			and SourceProbe.read == source_read and SourceProbe.close == source_close
	end

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
		local identity = lib.xkb_keymap_get_as_string(session.keymap, XKB_KEYMAP_FORMAT_TEXT_V1)
		session.identity = identity ~= nil and ffi.string(identity) or nil
		if identity ~= nil then ffi.C.free(identity) end
		session.groups = tonumber(lib.xkb_keymap_num_layouts(session.keymap))
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

	-- The physical chords the injector can press, cheapest first. Each is
	-- pressed on a FRESH state, so the answer is what an application receives
	-- from exactly that chord — whatever the key's type says a level means.
	local CHORDS = {
		{ level = 1, mods = {},                  keys = {} },
		{ level = 2, mods = { "shift" },         keys = { XKB_LEFTSHIFT } },
		{ level = 3, mods = { "altgr" },         keys = { XKB_RIGHTALT } },
		{ level = 4, mods = { "shift", "altgr" }, keys = { XKB_LEFTSHIFT, XKB_RIGHTALT } },
	}


	function backend.capture_group(session)
		return tonumber(lib.xkb_state_serialize_layout(session.state, XKB_STATE_LAYOUT_EFFECTIVE))
	end

	function backend.source_group(session, allow_seed)
		if not session.identity then return nil, "native-keymap-identity-unavailable" end
		if not probe_current() then return nil, "native-source-issuer-replaced" end
		local receipt, reason = source_read(session.identity, session.groups)
		if not receipt then return nil, reason end
		local observed_current = receipt.observed_current
		if type(observed_current) ~= "function" then return nil, "native-source-issuer-unsealed" end
		if backend.capture_group(session) ~= receipt.group then
			lib.xkb_state_update_mask(session.state,
				lib.xkb_state_serialize_mods(session.state, 1), lib.xkb_state_serialize_mods(session.state, 2),
				lib.xkb_state_serialize_mods(session.state, 4), 0, 0, receipt.group)
			if not allow_seed then return nil, "native-group-resynchronized" end
		end
		return receipt.group, receipt.generation, function()
			return probe_current() and observed_current() == true
		end
	end

	function backend.direct_sources(session, codes, group)
		local probe = nil
		local name_buffer = ffi.new("char[128]")
		local ok, result = pcall(function()
			local rows = {}
			for _, chord in ipairs(CHORDS) do
				probe = lib.xkb_state_new(session.keymap)
				assert(probe ~= nil, "xkb_state_new failed for direct sources")
				-- Keep the active group and discard held/latched/locked modifiers.
				-- Detached level probes never feed Compose or change capture state.
				lib.xkb_state_update_mask(probe, 0, 0, 0, 0, 0, group)
				for _, code in ipairs(chord.keys) do lib.xkb_state_update_key(probe, code, XKB_KEY_DOWN) end
				for _, code in ipairs(codes) do
					local sym = tonumber(lib.xkb_state_key_get_one_sym(probe, code + EVDEV_TO_XKB_OFFSET)) or 0
					local text = Keysym.from_id(sym) or ""
					local name_length = tonumber(lib.xkb_keysym_get_name(sym, name_buffer, 128)) or 0
					local name = name_length > 0 and ffi.string(name_buffer) or ""
					rows[#rows + 1] = { code = code, text = text, mods = { unpack(chord.mods) },
						plain = #chord.keys == 0, direct = #chord.keys == 0 and text ~= "",
						dead = name:sub(1, 5) == "dead_" }
				end
				lib.xkb_state_unref(probe)
				probe = nil
			end
			return rows
		end)
		if probe ~= nil then lib.xkb_state_unref(probe) end
		if not ok then return nil, tostring(result) end
		return result
	end


	-- Forty detached native translations retain the selected group and native
	-- lock semantics without touching live Compose or the capture state.
	function backend.number_row_levels(session, codes, group)
		local bit = require("bit")
		local lock = tonumber(lib.xkb_keymap_mod_get_index(session.keymap, "Lock"))
		if not lock or lock < 0 or lock >= 32 then return nil, "number-row-lock-modifier-unavailable" end
		local shift_index = tonumber(lib.xkb_keymap_mod_get_index(session.keymap, "Shift"))
		if not shift_index or shift_index < 0 or shift_index >= 32 then return nil, "number-row-shift-modifier-unavailable" end
		local shift_mask = tonumber(ffi.cast("uint32_t", bit.lshift(1, shift_index)))
		local shift_proof = lib.xkb_state_new(session.keymap)
		if shift_proof == nil then return nil, "number-row-shift-state-unavailable" end
		lib.xkb_state_update_key(shift_proof, XKB_LEFTSHIFT, XKB_KEY_DOWN)
		local effective_shift = tonumber(lib.xkb_state_serialize_mods(shift_proof, 1))
		local shift_locks = tonumber(lib.xkb_state_serialize_mods(shift_proof, 4))
		local shift_group = tonumber(lib.xkb_state_serialize_layout(shift_proof, XKB_STATE_LAYOUT_EFFECTIVE))
		lib.xkb_state_unref(shift_proof)
		if effective_shift ~= shift_mask or shift_locks ~= 0 or shift_group ~= 0 then
			return nil, "number-row-shift-emitter-unverified"
		end
		local lock_mask = bit.lshift(1, lock)
		local locked = tonumber(lib.xkb_state_serialize_mods(session.state, 4))
		local probe
		local name_buffer = ffi.new("char[128]")
		local called, result = pcall(function()
			local rows = {}
			for _, caps in ipairs({ false, true }) do
				for _, shift in ipairs({ false, true }) do
					probe = lib.xkb_state_new(session.keymap)
					assert(probe ~= nil, "number-row-state-unavailable")
					local mask = caps and bit.bor(locked, lock_mask) or bit.band(locked, bit.bnot(lock_mask))
					lib.xkb_state_update_mask(probe, 0, 0, tonumber(ffi.cast("uint32_t", mask)), 0, 0, group)
					if shift then lib.xkb_state_update_key(probe, XKB_LEFTSHIFT, XKB_KEY_DOWN) end
					for _, code in ipairs(codes) do
						local sym = tonumber(lib.xkb_state_key_get_one_sym(probe, code + EVDEV_TO_XKB_OFFSET)) or 0
						local text = Keysym.from_id(sym) or ""
						local length = tonumber(lib.xkb_keysym_get_name(sym, name_buffer, 128)) or 0
						local name = length > 0 and ffi.string(name_buffer) or ""
						rows[#rows + 1] = { code = code, caps = caps, shift = shift,
							text = text, keysym = sym, dead = name:sub(1, 5) == "dead_" }
					end
					lib.xkb_state_unref(probe)
					probe = nil
				end
			end
			return rows
		end)
		if probe ~= nil then lib.xkb_state_unref(probe) end
		if not called then return nil, "number-row-native-translation-refused" end
		return result
	end

	function backend.chord_source_identity(session)
		if not session.identity then return nil end
		local Probe = require("adapters.xkb_source_probe")
		if type(Probe.read_input_state) ~= "function" then return nil, "physical-input-modifiers-unavailable" end
		return Probe.read_input_state(session.identity, session.groups)
	end

	function backend.chord_sources(session, requests, group, locked_mods)
		local probe, rows = nil, {}
		local names = { ctrl = "Control", alt = "Alt", shift = "Shift", super = "Super" }
		local indices = {}
		for role, name in pairs(names) do
			local index = tonumber(lib.xkb_keymap_mod_get_index(session.keymap, name))
			if index and index < 32 then indices[role] = index end
		end
		local locked = locked_mods or tonumber(lib.xkb_state_serialize_mods(session.state, 4))
		local bit = require("bit")
		local lock = tonumber(lib.xkb_keymap_mod_get_index(session.keymap, "Lock"))
		if not lock or lock < 0 or lock >= 32 then return nil, "physical-lock-modifier-unavailable" end
		local lock_mask = bit.lshift(1, lock)
		local unlocked = bit.band(locked, bit.bnot(lock_mask))
		local name_buffer = ffi.new("char[128]")
		local called, reason = pcall(function()
			for _, request in ipairs(requests) do
				local depressed, used = 0, {}
				for role, wanted in pairs(request.mods) do
					if wanted then
						assert(indices[role] ~= nil, "physical modifier unavailable in this XKB keymap")
						if not used[indices[role]] then depressed = depressed + 2 ^ indices[role]; used[indices[role]] = true end
					end
				end
				for _, caps in ipairs({ false, true }) do
				probe = lib.xkb_state_new(session.keymap)
				assert(probe ~= nil, "xkb_state_new failed for physical chord")
				lib.xkb_state_update_mask(probe, depressed, 0, caps and bit.bor(unlocked, lock_mask) or unlocked, 0, 0, group)
				local symbol = tonumber(lib.xkb_state_key_get_one_sym(probe, request.code + EVDEV_TO_XKB_OFFSET)) or 0
				local size = tonumber(lib.xkb_keysym_get_name(symbol, name_buffer, 128)) or 0
				local name = size > 0 and ffi.string(name_buffer) or ""
				local mods = {}; for role, wanted in pairs(request.mods) do mods[role] = wanted end
				rows[#rows + 1] = { code = request.code, mods = mods, caps = caps, identity = Keysym.from_id(symbol), dead = name:sub(1, 5) == "dead_",
					keysym = symbol > 0 and symbol or nil }
				lib.xkb_state_unref(probe); probe = nil
				end
			end
		end)
		if probe ~= nil then lib.xkb_state_unref(probe) end
		if not called then return nil, tostring(reason) end
		return rows
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


	-- The typing block first (evdev 1-58 and the ISO key 86), across every
	-- chord, before anything else. A keymap also binds characters to exotic
	-- keys — EuroSign on a multimedia key at level 1, a parenthesis on
	-- KEY_KPLEFTPAREN — that some applications ignore; a real key with a
	-- modifier is what a person would press, so it wins.
	local function in_typing_block(evdev)
		return (evdev >= 1 and evdev <= 58) or evdev == 86
	end

	function backend.inverse(session, group)
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
						-- Detached output chords retain the selected group while
						-- discarding held, latched and locked modifiers.
						lib.xkb_state_update_mask(state, 0, 0, 0, 0, 0, group)
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
	if _backend.desktop_proof then pcall(_backend.source_group, _session, true) end
	_keymap_text = text
	_locale = selected_locale
	_source_group, _source_native_generation = nil, nil
	_capture_group, _capture_generation = nil, _capture_generation + 1
	_source_generation = _source_generation + 1
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
	if _backend.desktop_proof then pcall(_backend.source_group, _session, true) end
	_source_group, _source_native_generation = nil, nil
	_capture_group, _capture_generation = nil, _capture_generation + 1
	_source_generation = _source_generation + 1
	destroy(previous)
	return true
end

--- Releases all native objects and forgets the retained keymap.
function M.clear()
	destroy(_session)
	if _backend and _backend.desktop_proof then require("adapters.xkb_source_probe").close() end
	_session = nil
	_keymap_text = nil
	_locale = nil
	_source_group, _source_native_generation = nil, nil
	_capture_group, _capture_generation = nil, _capture_generation + 1
	_source_generation = _source_generation + 1
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
--- @param require_source boolean|nil Require the existing native desktop acknowledgement.
--- @return table|nil char → { keycode = evdev, level = integer, mods = table }
--- @return string|nil error
--- @return table|nil Opaque reconstructed-state receipt, never desktop authority.
function M.inverse_table(require_source)
	if not _session then return nil, "XKB capture state is not ready" end
	if type(_backend.inverse) ~= "function" then
		return nil, "the capture backend cannot enumerate the keymap"
	end
	local session, backend, raw_map = _session, _backend, _keymap_text
	local native_map = session.identity
	local getter = backend.capture_group or backend.source_group
	local enumerate = backend.inverse
	local source_getter = backend.source_group
	local desktop_generation, desktop_observed, desktop_error
	if require_source == true then desktop_generation, desktop_error, desktop_observed = source_identity() end
	if require_source == true and (not desktop_generation or type(_source_native_generation) ~= "number"
		or _source_native_generation < 0 or _source_native_generation % 1 ~= 0
		or type(desktop_observed) ~= "function") then return nil, "inverse-desktop-source-unavailable" end
	local desktop_epoch = _source_generation
	local generation, group = capture_identity()
	if _session ~= session or _backend ~= backend or _keymap_text ~= raw_map
		or session.identity ~= native_map or backend.inverse ~= enumerate
		or require_source == true and backend.source_group ~= source_getter
		or (backend.capture_group or backend.source_group) ~= getter then return nil, "inverse-source-changed" end
	if type(getter) == "function" and (not generation or type(group) ~= "number"
		or group < 0 or group % 1 ~= 0 or type(session.groups) == "number" and group >= session.groups) then
		return nil, "inverse-group-unavailable"
	end
	local epoch = _capture_generation
	local ok, built = pcall(enumerate, session, group)
	if not ok then return nil, tostring(built) end
	local after_desktop, after_observed, after_error
	if require_source == true then after_desktop, after_error, after_observed = source_identity() end
	local after_generation, after_group = capture_identity()
	local sealed, current = true, true
	if require_source == true then sealed, current = pcall(after_observed) end
	if _session ~= session or _backend ~= backend or _keymap_text ~= raw_map
		or session.identity ~= native_map or _capture_generation ~= epoch
		or backend.inverse ~= enumerate or (backend.capture_group or backend.source_group) ~= getter
		or require_source == true and (not after_desktop or after_desktop ~= desktop_generation
			or _source_generation ~= desktop_epoch or backend.source_group ~= source_getter or not sealed or current ~= true)
		or after_generation ~= generation or after_group ~= group then return nil, "inverse-source-changed" end
	if type(built) ~= "table" or getmetatable(built) ~= nil then return nil, "invalid-inverse-table" end
	local detached = {}
	for char, row in pairs(built) do
		if type(char) ~= "string" or type(row) ~= "table" or getmetatable(row) ~= nil
			or type(row.keycode) ~= "number" or row.keycode < 0 or row.keycode % 1 ~= 0
			or type(row.level) ~= "number" or row.level < 1 or row.level % 1 ~= 0
			or type(row.mods) ~= "table" or getmetatable(row.mods) ~= nil then return nil, "invalid-inverse-table" end
		local mods = {}
		for index, mod in ipairs(row.mods) do
			if type(mod) ~= "string" then return nil, "invalid-inverse-table" end
			mods[index] = mod
		end
		for index in pairs(row.mods) do
			if type(index) ~= "number" or index < 1 or index % 1 ~= 0 or index > #mods then return nil, "invalid-inverse-table" end
		end
		detached[char] = { keycode = row.keycode, level = row.level, mods = mods }
	end
	-- Legacy no-getter fixtures retain enumeration without acquiring currency.
	if type(getter) ~= "function" then return detached end
	local receipt = {}
	_inverse_receipts[receipt] = { session = session, backend = backend, raw_map = raw_map,
		native_map = native_map, getter = getter, inverse = enumerate, generation = generation,
		group = group, epoch = epoch, desktop_generation = desktop_generation,
		desktop_epoch = desktop_epoch, source_getter = source_getter, observed_current = after_observed }
	return detached, nil, receipt
end

--- Checks an exact inverse receipt against its original reconstructed source.
--- Ordinary key transitions preserve it; observed group ABA and reload retire it.
--- @param receipt table Opaque receipt returned by inverse_table().
--- @param cached boolean|nil True for an observation-only RAM seal after callbacks.
--- @return boolean Never a desktop, seat or physical delivery capability.
function M.inverse_current(receipt, cached)
	local owned = _inverse_receipts[receipt]
	if not owned or owned.revoked then return false end
	local function refuse()
		owned.revoked = true
		return false
	end
	local function same_owner()
		return _session == owned.session and _backend == owned.backend and _keymap_text == owned.raw_map
			and owned.session.identity == owned.native_map and _capture_generation == owned.epoch
			and (_backend.capture_group or _backend.source_group) == owned.getter and _backend.inverse == owned.inverse
			and (not owned.desktop_generation or _source_generation == owned.desktop_epoch
				and _backend.source_group == owned.source_getter)
	end
	if not same_owner() then return refuse() end
	if cached == true then
		if owned.desktop_generation then
			local ok, current = pcall(owned.observed_current)
			if not ok or current ~= true or not same_owner() then return refuse() end
		end
		if _capture_group ~= owned.group then return refuse() end
		return true
	end
	if owned.desktop_generation then
		local desktop_generation, _, observed_current = source_identity()
		if not same_owner() or desktop_generation ~= owned.desktop_generation then return refuse() end
		if type(observed_current) ~= "function" then return refuse() end
		owned.observed_current = observed_current
	end
	local generation, group = capture_identity()
	if not same_owner() or generation ~= owned.generation or group ~= owned.group then return refuse() end
	if owned.desktop_generation then
		local ok, current = pcall(owned.observed_current)
		if not ok or current ~= true or not same_owner() then return refuse() end
	end
	return true
end

--- Enumerates every plain output in a detached state of the active group.
--- This preserves duplicates for the shared owner to refuse ambiguity.
--- @param codes table Dense array of registry evdev codes.
--- @return table|nil rows { code, text, mods, plain, direct, dead }.
--- @return string|nil error
function M.direct_sources(codes)
	if not _session then return nil, "XKB capture state is not ready" end
	if type(codes) ~= "table" then return nil, "direct source codes are required" end
	local count, seen, expected = 0, {}, {}
	for key, code in pairs(codes) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #codes
			or type(code) ~= "number" or code < 1 or code > UINPUT_KEY_MAX or code % 1 ~= 0 or seen[code] then
			return nil, "invalid direct source codes"
		end
		seen[code], expected[key], count = true, code, count + 1
	end
	if count ~= #codes then return nil, "direct source codes must be dense" end
	if type(_backend.direct_sources) ~= "function" then return nil, "the capture backend cannot prove direct sources" end
	local session, backend, raw_map = _session, _backend, _keymap_text
	local generation, detail = source_identity()
	if not generation then return nil, detail end
	if _session ~= session or _backend ~= backend or _keymap_text ~= raw_map then
		return nil, "direct-source-changed"
	end
	local group, native_map = _source_group, session.identity
	local snapshot = {}; for index, code in ipairs(expected) do snapshot[index] = code end
	local ok, rows, err = pcall(backend.direct_sources, session, snapshot, group)
	if not ok then return nil, tostring(rows) end
	if type(rows) ~= "table" then return nil, err or "the capture backend returned no direct sources" end
	local after_generation = source_identity()
	if _session ~= session or _backend ~= backend or _keymap_text ~= raw_map
		or after_generation ~= generation or _source_group ~= group or session.identity ~= native_map then
		return nil, "direct-source-changed"
	end
	local snapshot_count = 0
	for index, code in pairs(snapshot) do
		if expected[index] ~= code then return nil, "direct-source-invalid-response" end
		snapshot_count = snapshot_count + 1
	end
	if snapshot_count ~= count then return nil, "direct-source-invalid-response" end
	return rows
end


--- Captures forty Caps/Shift levels from the exact selected native keymap.
--- Generation, group and session must survive every native probe callback.
--- @param codes table Ten unique physical evdev positions in number-row order.
--- @return table|nil receipt Native map/source identity and ordered levels.
--- @return string|nil reason Closed refusal category.
function M.number_row_levels(codes)
	if not _session or type(codes) ~= "table" or #codes ~= 10
		or type(_backend.number_row_levels) ~= "function" then return nil, "number-row-source-unavailable" end
	local count, seen = 0, {}
	for key, code in pairs(codes) do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > 10
			or type(code) ~= "number" or code % 1 ~= 0 or code < 1 or code > UINPUT_KEY_MAX
			or seen[code] then return nil, "number-row-invalid-positions" end
		count, seen[code] = count + 1, true
	end
	if count ~= 10 then return nil, "number-row-invalid-positions" end
	local generation = source_identity()
	if not generation then return nil, "number-row-native-source-unverified" end
	local session, backend, group, raw_map = _session, _backend, _source_group, _keymap_text
	local groups = session.groups
	if type(groups) ~= "number" or groups % 1 ~= 0 or groups < 1 or groups > 32 then return nil, "number-row-native-groups-unavailable" end
	local map = session.identity
	if type(map) ~= "string" or map == "" then return nil, "number-row-native-map-unavailable" end
	local called, rows = pcall(backend.number_row_levels, session, codes, group)
	local after_generation = source_identity()
	if not called or type(rows) ~= "table" or _session ~= session or _backend ~= backend
		or after_generation ~= generation or _source_group ~= group or _keymap_text ~= raw_map
		or session.identity ~= map or session.groups ~= groups then
		return nil, "number-row-native-source-changed"
	end
	local levels = NumberRow.levels("linux", rows, codes)
	if not levels then return nil, "number-row-native-levels-refused" end
	local capability = setmetatable({}, { __newindex = function() error("native row receipts are immutable", 2) end, __metatable = false })
	local exact_codes = {}; for index, code in ipairs(codes) do exact_codes[index] = code end
	number_row_receipts[capability] = { generation = generation, group = group, keymap = map, raw_map = raw_map,
		session = session, backend = backend, groups = groups, levels = levels, codes = exact_codes }
	return capability
end

--- Reads only this producer's exact native receipt while its source is current.
--- Returned action descriptors are detached; callers cannot mutate retained proof.
function M.number_row_view(capability, codes)
	local owned = number_row_receipts[capability]
	if not owned then return nil end
	local generation = source_identity()
	if owned.session ~= _session or owned.backend ~= _backend
		or owned.raw_map ~= _keymap_text or owned.keymap ~= owned.session.identity or owned.generation ~= generation
		or owned.group ~= _source_group or owned.session.groups ~= owned.groups or type(codes) ~= "table" or #codes ~= 10 then return nil end
	for index, code in ipairs(owned.codes) do if codes[index] ~= code then return nil end end
	local function copy(value)
		if type(value) ~= "table" then return value end
		local result = {}; for key, child in pairs(value) do result[key] = copy(child) end; return result
	end
	return { generation = owned.generation, group = owned.group, groups = owned.groups, keymap = owned.keymap,
		levels = copy(owned.levels), codes = copy(owned.codes) }
end

--- Native-library qualification only; this does not prove a desktop source.
function M._capture_number_row_levels_for_test(codes)
	local _, group = capture_identity()
	if group == nil or not _backend or type(_backend.number_row_levels) ~= "function" then return nil end
	return _backend.number_row_levels(_session, codes, group)
end

--- Reads exact source-owner locks independently of reconstructed capture state.
local function physical_locked_identity(session, backend)
 local called, proof = pcall(backend.chord_source_identity, session)
 if not called or type(proof) ~= "table" then return nil, "physical-input-modifiers-unavailable" end
 for _, field in ipairs({ "group", "generation", "locked_mods", "locked_generation", "input_generation",
  "mods", "base_mods", "latched_mods" }) do
  local value = proof[field]
  if type(value) ~= "number" or value < 0 or value % 1 ~= 0 then return nil, "physical-input-modifiers-unavailable" end
 end
 for _, field in ipairs({ "mods", "base_mods", "latched_mods", "locked_mods" }) do
  if proof[field] > 255 then return nil, "physical-input-modifiers-unavailable" end
 end
 if proof.base_mods ~= 0 or proof.latched_mods ~= 0 or proof.mods ~= proof.locked_mods then
  return nil, "physical-input-modifiers-unsupported"
 end
 return { group = proof.group, generation = proof.generation,
  locked_mods = proof.locked_mods, locked_generation = proof.locked_generation,
  input_generation = proof.input_generation, mods = proof.mods,
  base_mods = proof.base_mods, latched_mods = proof.latched_mods,
  observed_current = type(proof.observed_current) == "function" and proof.observed_current or nil }
end
local function physical_same_locked(left, right)
 return left and right and left.group == right.group and left.generation == right.generation
  and left.locked_mods == right.locked_mods and left.locked_generation == right.locked_generation
  and left.input_generation == right.input_generation and left.mods == right.mods
  and left.base_mods == right.base_mods and left.latched_mods == right.latched_mods
end

--- Proves actual chord identities for physical editor admission on the current source.
--- Requests are detached; callbacks cannot mutate the original request snapshot.
function M.chord_sources(requests)
	if not _session or type(requests) ~= "table" or getmetatable(requests) ~= nil
		or type(_backend.chord_sources) ~= "function" or type(_backend.chord_source_identity) ~= "function" then return nil, "physical-source-unavailable" end
	local count, snapshot, expected = 0, {}, {}
	for index, request in pairs(requests) do
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #requests
			or type(request) ~= "table" or getmetatable(request) ~= nil or type(request.code) ~= "number"
			or request.code < 1 or request.code > UINPUT_KEY_MAX or request.code % 1 ~= 0
			or type(request.mods) ~= "table" or getmetatable(request.mods) ~= nil then return nil, "physical-source-invalid-request" end
		for field in pairs(request) do if field ~= "code" and field ~= "mods" then return nil, "physical-source-invalid-request" end end
		local mods = {}
		for role, value in pairs(request.mods) do
			if role ~= "ctrl" and role ~= "alt" and role ~= "shift" and role ~= "super" or type(value) ~= "boolean" then
				return nil, "physical-source-invalid-request"
			end
			mods[role] = value
		end
		snapshot[index], count = { code = request.code, mods = mods }, count + 1
		local expected_mods = {}; for role, value in pairs(mods) do expected_mods[role] = value end
		expected[index] = { code = request.code, mods = expected_mods }
	end
	if count ~= #requests then return nil, "physical-source-invalid-request" end
	local session, backend, probe_epoch = _session, _backend, _physical_probe_epoch
	local generation = source_identity()
	if not generation or _session ~= session or _backend ~= backend or _physical_probe_epoch ~= probe_epoch then return nil, "physical-source-unverified" end
	local group, epoch = _source_group, _source_generation
	local proof, proof_reason = physical_locked_identity(session, backend)
	if not proof then return nil, proof_reason end
	if proof.group ~= group or proof.generation ~= _source_native_generation
		or _session ~= session or _backend ~= backend or _source_generation ~= epoch
		or _physical_probe_epoch ~= probe_epoch then return nil, "physical-source-unverified" end
	local called, rows = pcall(backend.chord_sources, session, snapshot, group, proof.locked_mods)
	if not called or type(rows) ~= "table" or _session ~= session or _backend ~= backend or _source_generation ~= epoch or _physical_probe_epoch ~= probe_epoch then
		return nil, "physical-source-changed"
	end
	local current = source_identity()
	local final_proof = physical_locked_identity(session, backend)
	if not physical_same_locked(proof, final_proof) or current ~= generation or _session ~= session or _backend ~= backend or _source_generation ~= epoch or _physical_probe_epoch ~= probe_epoch then return nil, "physical-source-changed" end
	local facts, row_count = {}, 0
	for index, row in pairs(rows) do
		local request = type(index) == "number" and index % 1 == 0 and expected[math.floor((index + 1) / 2)] or nil
		if type(index) ~= "number" or not request or type(row) ~= "table" or row.code ~= request.code
			or type(row.mods) ~= "table" or type(row.dead) ~= "boolean" or row.caps ~= (index % 2 == 0)
			or row.keysym ~= nil and (type(row.keysym) ~= "number" or row.keysym % 1 ~= 0 or row.keysym < 1 or row.keysym > 4294967295)
			or row.identity ~= nil and type(row.identity) ~= "string" then return nil, "physical-source-invalid-response" end
		for role, value in pairs(row.mods) do if request.mods[role] ~= value then return nil, "physical-source-invalid-response" end end
		local mods = {}; for role, value in pairs(request.mods) do
			if row.mods[role] ~= value then return nil, "physical-source-invalid-response" end
			mods[role] = value
		end
		facts[index], row_count = { code = row.code, mods = mods, caps = row.caps, identity = row.identity, dead = row.dead, keysym = row.keysym }, row_count + 1
	end
	if row_count ~= #snapshot * 2 then return nil, "physical-source-invalid-response" end
	local capability = {}
	_physical_chord_receipts[capability] = { session = session, backend = backend, epoch = epoch,
		probe_epoch = probe_epoch, generation = generation, group = group, locked = final_proof,
		raw_map = _keymap_text, native_map = session.identity, chords = facts }
	return capability
end

--- Reads only capabilities issued by this actual source owner while still current.
function M.chord_source_view(capability)
	local record = _physical_chord_receipts[capability]
	if not record then return nil, "physical-source-unowned" end
	local function current()
		return _session == record.session and _backend == record.backend and _source_generation == record.epoch
			and _physical_probe_epoch == record.probe_epoch and _source_group == record.group
	end
	if not current() then return nil, "physical-source-changed" end
	local generation = source_identity()
	local proof, proof_reason = physical_locked_identity(record.session, record.backend)
	if not proof then return nil, proof_reason end
	if not physical_same_locked(proof, record.locked) or not current() or generation ~= record.generation then return nil, "physical-source-changed" end
	local rows = {}
	for index, row in ipairs(record.chords) do
		local mods = {}; for role, value in pairs(row.mods) do mods[role] = value end
		rows[index] = { code = row.code, mods = mods, caps = row.caps, identity = row.identity, dead = row.dead, keysym = row.keysym }
	end
	return { generation = record.generation, group = record.group, chords = rows }
end

--- Seals private and already-observed source currency without another read.
--- This does not attest an unobserved external native source transition.
--- @param capability table Exact opaque receipt issued by this capture owner.
--- @return boolean current
function M.chord_source_current(capability)
	local record = _physical_chord_receipts[capability]
	if not record or type(record.locked.observed_current) ~= "function" then return false end
	local function private()
		return _session == record.session and _backend == record.backend and _source_generation == record.epoch
			and _physical_probe_epoch == record.probe_epoch and _source_group == record.group
			and _source_native_generation == record.locked.generation
			and _keymap_text == record.raw_map and record.session.identity == record.native_map
	end
	if not private() then return false end
	local called, observed = pcall(record.locked.observed_current)
	return called and observed == true and private()
end

--- Native-library-only probe; never qualifies desktop source or physical delivery.
function M._capture_chord_sources_for_test(requests)
	local _, group = capture_identity()
	if group == nil or not _backend or type(_backend.chord_sources) ~= "function" then return nil end
	return _backend.chord_sources(_session, requests, group)
end

--- The validated keymap and active-group epoch, independent of ordinary keys.
--- @return integer|nil generation
--- @return string|nil error
function M.source_generation()
	local session, backend, map, epoch = _session, _backend, _keymap_text, _capture_generation
	local getter = backend and backend.source_group
	local native_map = session and session.identity
	local function same_owner()
		return _session == session and _backend == backend and _keymap_text == map and _capture_generation == epoch
			and (not session or session.identity == native_map) and (not backend or backend.source_group == getter)
	end
	local generation, reason, observed_current = source_identity()
	if not same_owner() then return nil, "native-source-owner-changed" end
	-- Missing issuer currency remains missing; a controlled tuple is not a lease.
	if not generation or type(observed_current) ~= "function" then return generation, reason, observed_current end
	local group, native_generation = _source_group, _source_native_generation
	local function current()
		return same_owner() and _source_generation == generation
			and _source_group == group and _source_native_generation == native_generation
	end
	return generation, reason, function()
		if not current() then return false end
		local called, observed = pcall(observed_current)
		return called and observed == true and current()
	end
end

--- Native-library test seam; intentionally supplies no desktop qualification.
function M._capture_source_generation_for_test() return capture_identity() end

--- Native-library test seam for detached probes of reconstructed capture state.
function M._capture_direct_sources_for_test(codes)
	local _, group = capture_identity()
	if group == nil then return nil, "no reconstructed native capture group" end
	return _backend.direct_sources(_session, codes, group)
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

--- Ends a pending Compose sequence, leaving the key state as it is. For a press
--- the application never received: the dead key it fed must not compose with
--- the next key here while the application types that key plain.
--- @return boolean ok, string|nil error
function M.cancel_compose()
	if not _session then return false, "XKB capture state is not ready" end
	local ok, err = pcall(_backend.compose_reset, _session)
	if not ok then return false, tostring(err) end
	return true, nil
end

--- The text a key would type in the live keymap and state, without pressing
--- it: nothing is committed and no Compose sequence is fed. "" for a key that
--- types nothing (an arrow, a function key, a keypad key with NumLock off).
--- @param evdev_code integer Linux input-event keycode.
--- @return string|nil text, string|nil error
function M.peek_text(evdev_code)
	if not _session then return nil, "XKB capture state is not ready" end
	if type(evdev_code) ~= "number" or evdev_code < 0 or evdev_code % 1 ~= 0 then
		return nil, "evdev keycode must be a non-negative integer"
	end
	local ok, text = pcall(_backend.key_utf8, _session, evdev_code + EVDEV_TO_XKB_OFFSET)
	if not ok then return nil, tostring(text) end
	return text or "", nil
end

--- The modifier role a key has in the live keymap and state: "shift",
--- "altgr", "ctrl", "alt" or "meta", or nil when its keysym is no modifier.
--- Asked before the key's own press is committed, like its text.
--- @param evdev_code integer Linux input-event keycode.
--- @return string|nil role, string|nil error
function M.modifier_role(evdev_code)
	if not _session then return nil, "XKB capture state is not ready" end
	if type(evdev_code) ~= "number" or evdev_code < 0 or evdev_code % 1 ~= 0 then
		return nil, "evdev keycode must be a non-negative integer"
	end
	local ok, sym = pcall(_backend.key_sym, _session, evdev_code + EVDEV_TO_XKB_OFFSET)
	if not ok then return nil, tostring(sym) end
	return MODIFIER_ROLE_OF_KEYSYM[sym], nil
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
	_physical_probe_epoch = _physical_probe_epoch + 1
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
		capture_identity()
		return nil, nil, nil
	end

	local ok_resolve, text, identity = pcall(resolve_press, keycode)
	if not ok_resolve then return nil, nil, tostring(text) end
	if value == VALUE_DOWN then
		local ok_update, update_err = pcall(
			_backend.update_key, _session, keycode, XKB_KEY_DOWN)
		if not ok_update then return nil, nil, tostring(update_err) end
		capture_identity()
	end
	return text, identity, nil
end

M.EVDEV_TO_XKB_OFFSET = EVDEV_TO_XKB_OFFSET

return M
