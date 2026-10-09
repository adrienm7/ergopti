--- infra/keysym.lua

--- ==============================================================================
--- MODULE: Keysym Resolution (Linux)
--- DESCRIPTION:
--- Turns an X11 keysym NAME — what an XKB keymap is written in — into the
--- character it produces.
---
--- WHY THIS IS SEPARATE FROM THE KEYMAP PARSER:
--- A keymap says `key <AD03> { [ e, E, EuroSign, cent ] }`. Those are protocol
--- constants, not text: "EuroSign" is a name for U+20AC and "e" happens to spell
--- its own character only by coincidence of the ASCII block. The keymap parser's
--- job is the layout; this module's job is the alphabet, and the two are
--- independent — which is what makes both testable without a display server.
---
--- TWO PATHS, AND WHY BOTH:
--- 1. libxkbcommon through FFI, when it is there. It is the authority: it knows
---    every keysym including the ones no table here will ever list, and it is
---    installed on any machine that has a graphical session at all.
--- 2. A pure-Lua table otherwise. It covers the Latin-1 block — the complete
---    keysymdef.h range for U+0020 to U+00FF — plus the Unicode spellings a
---    modern keymap uses for everything else.
---
--- The table is NOT a layout table and must not be mistaken for one. It maps
--- protocol names to Unicode and is identical on every machine and every layout
--- on earth; the thing this driver may never hardcode is which KEY produces
--- which character, and that comes from the server's own keymap.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "infra.keysym"




-- ==============================================
-- ==============================================
-- ======= 1/ Unicode encoding ==================
-- ==============================================
-- ==============================================

--- Encodes a Unicode codepoint as UTF-8.
---
--- Hand-rolled rather than utf8.char: LuaJIT is Lua 5.1 and has no utf8 library,
--- and the shim the test runner installs is not loaded in production.
--- @param cp integer Codepoint.
--- @return string|nil UTF-8 bytes, or nil for an out-of-range value.
function M.utf8_encode(cp)
	if type(cp) ~= "number" or cp < 0 or cp > 0x10FFFF then return nil end
	if cp < 0x80 then
		return string.char(cp)
	elseif cp < 0x800 then
		return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
	elseif cp < 0x10000 then
		return string.char(
			0xE0 + math.floor(cp / 0x1000),
			0x80 + math.floor(cp / 0x40) % 0x40,
			0x80 + cp % 0x40)
	end
	return string.char(
		0xF0 + math.floor(cp / 0x40000),
		0x80 + math.floor(cp / 0x1000) % 0x40,
		0x80 + math.floor(cp / 0x40) % 0x40,
		0x80 + cp % 0x40)
end




-- ==============================================
-- ==============================================
-- ======= 2/ The protocol alphabet =============
-- ==============================================
-- ==============================================

-- keysymdef.h, ASCII punctuation. The letters and digits are generated below
-- rather than listed, because there their name IS their character and writing
-- 62 identity entries by hand only creates 62 chances to mistype one.
local ASCII_NAMES = {
	space = 0x20, exclam = 0x21, quotedbl = 0x22, numbersign = 0x23,
	dollar = 0x24, percent = 0x25, ampersand = 0x26, apostrophe = 0x27,
	parenleft = 0x28, parenright = 0x29, asterisk = 0x2A, plus = 0x2B,
	comma = 0x2C, minus = 0x2D, period = 0x2E, slash = 0x2F,
	colon = 0x3A, semicolon = 0x3B, less = 0x3C, equal = 0x3D,
	greater = 0x3E, question = 0x3F, at = 0x40,
	bracketleft = 0x5B, backslash = 0x5C, bracketright = 0x5D,
	asciicircum = 0x5E, underscore = 0x5F, grave = 0x60,
	braceleft = 0x7B, bar = 0x7C, braceright = 0x7D, asciitilde = 0x7E,
	-- Deprecated aliases still emitted by older keymaps.
	quoteright = 0x27, quoteleft = 0x60,
}

-- keysymdef.h, the Latin-1 block: U+00A0 to U+00FF, in order. Listed as an array
-- so the codepoint is the index rather than a number repeated beside every name
-- — a transposed digit in a hand-written pair is invisible, a missing entry in
-- an ordered list shifts everything after it and every test fails at once.
local LATIN1_NAMES = {
	"nobreakspace", "exclamdown", "cent", "sterling", "currency", "yen",
	"brokenbar", "section", "diaeresis", "copyright", "ordfeminine",
	"guillemotleft", "notsign", "hyphen", "registered", "macron",
	"degree", "plusminus", "twosuperior", "threesuperior", "acute", "mu",
	"paragraph", "periodcentered", "cedilla", "onesuperior", "masculine",
	"guillemotright", "onequarter", "onehalf", "threequarters", "questiondown",
	"Agrave", "Aacute", "Acircumflex", "Atilde", "Adiaeresis", "Aring",
	"AE", "Ccedilla", "Egrave", "Eacute", "Ecircumflex", "Ediaeresis",
	"Igrave", "Iacute", "Icircumflex", "Idiaeresis", "ETH", "Ntilde",
	"Ograve", "Oacute", "Ocircumflex", "Otilde", "Odiaeresis", "multiply",
	"Oslash", "Ugrave", "Uacute", "Ucircumflex", "Udiaeresis", "Yacute",
	"THORN", "ssharp",
	"agrave", "aacute", "acircumflex", "atilde", "adiaeresis", "aring",
	"ae", "ccedilla", "egrave", "eacute", "ecircumflex", "ediaeresis",
	"igrave", "iacute", "icircumflex", "idiaeresis", "eth", "ntilde",
	"ograve", "oacute", "ocircumflex", "otilde", "odiaeresis", "division",
	"oslash", "ugrave", "uacute", "ucircumflex", "udiaeresis", "yacute",
	"thorn", "ydiaeresis",
}

-- The handful outside Latin-1 that European layouts put on a base level. Not an
-- attempt at completeness — libxkbcommon is that — but these appear on the
-- French, Belgian and Nordic layouts this driver's users actually run, and a
-- driver that cannot type € on a machine without libxkbcommon is a driver that
-- cannot type.
local EXTRA_NAMES = {
	EuroSign = 0x20AC, OE = 0x0152, oe = 0x0153, Ydiaeresis = 0x0178,
	Scaron = 0x0160, scaron = 0x0161, Zcaron = 0x017D, zcaron = 0x017E,
	leftsinglequotemark = 0x2018, rightsinglequotemark = 0x2019,
	leftdoublequotemark = 0x201C, rightdoublequotemark = 0x201D,
	ellipsis = 0x2026, endash = 0x2013, emdash = 0x2014,
	dagger = 0x2020, permille = 0x2030, minutes = 0x2032, seconds = 0x2033,
}

--- Name → codepoint, built once.
local _names = nil

--- Builds the name table, generating the identity entries.
--- @return table
local function names()
	if _names then return _names end
	local t = {}
	for name, cp in pairs(ASCII_NAMES) do t[name] = cp end
	for name, cp in pairs(EXTRA_NAMES) do t[name] = cp end
	for i, name in ipairs(LATIN1_NAMES) do t[name] = 0x9F + i end
	-- Digits and letters name themselves.
	for cp = 0x30, 0x39 do t[string.char(cp)] = cp end
	for cp = 0x41, 0x5A do t[string.char(cp)] = cp end
	for cp = 0x61, 0x7A do t[string.char(cp)] = cp end
	_names = t
	return t
end




-- ==============================================
-- ==============================================
-- ======= 3/ libxkbcommon through FFI ==========
-- ==============================================
-- ==============================================

-- nil until probed; false when this machine has no usable library.
local _xkb = nil

--- Binds libxkbcommon, or records that it is absent.
--- @return table|nil { from_name = fn, to_utf8 = fn }
local function xkb()
	if _xkb ~= nil then return _xkb or nil end
	_xkb = false

	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi or type(ffi) ~= "table" then return nil end

	local ok_cdef, cdef_err = pcall(ffi.cdef, [[
		unsigned int xkb_keysym_from_name(const char *name, int flags);
		int xkb_keysym_to_utf8(unsigned int keysym, char *buffer, unsigned long size);
	]])
	if not ok_cdef and not tostring(cdef_err):find("redefin", 1, true) then return nil end

	-- The soname, not the development symlink: libxkbcommon-dev is not installed
	-- on a user's machine and dlopen("libxkbcommon.so") would fail there while
	-- succeeding on every developer's.
	local ok_lib, lib = pcall(ffi.load, "xkbcommon.so.0")
	if not ok_lib then ok_lib, lib = pcall(ffi.load, "xkbcommon") end
	if not ok_lib then
		Logger.debug(LOG, "libxkbcommon not loadable — using the built-in name table.")
		return nil
	end

	-- 8 bytes holds any UTF-8 sequence plus its terminator; xkb_keysym_to_utf8
	-- writes at most 5.
	local buffer = ffi.new("char[8]")
	_xkb = {
		from_name = function(name)
			local sym = lib.xkb_keysym_from_name(name, 0)
			-- XKB_KEY_NoSymbol is 0.
			return sym ~= 0 and sym or nil
		end,
		to_utf8 = function(sym)
			local n = lib.xkb_keysym_to_utf8(sym, buffer, 8)
			-- The count includes the NUL terminator, and 0 or 1 means the keysym
			-- has no character — a modifier or a dead key.
			if n <= 1 then return nil end
			return ffi.string(buffer, n - 1)
		end,
	}
	Logger.debug(LOG, "libxkbcommon bound.")
	return _xkb
end

--- Test seam: forces the FFI path off or clears the probe.
--- @param value table|false|nil
function M._set_xkb_for_test(value)
	_xkb = value
end




-- ==============================================
-- ==============================================
-- ======= 4/ Resolution ========================
-- ==============================================
-- ==============================================

--- Resolves a keysym name to the character it produces.
---
--- Returns nil for anything that produces no character: modifiers, function
--- keys, and dead keys. A dead key returning its accent would be actively wrong
--- — pressing it types nothing and arms the next keystroke.
--- @param name string Keysym name as written in an XKB keymap.
--- @return string|nil A UTF-8 character.
function M.to_char(name)
	if type(name) ~= "string" or name == "" then return nil end

	-- A dead key composes with what follows; on its own it produces nothing, and
	-- libxkbcommon agrees. Checked first so the answer does not depend on which
	-- path is available.
	if name:sub(1, 5) == "dead_" then return nil end

	local table_hit = names()[name]
	if table_hit then return M.utf8_encode(table_hit) end

	-- The Unicode spellings a keymap uses for symbols with no legacy name.
	-- "U20AC" is the XKB form; "0x10020ac" is the numeric keysym form.
	local hex = name:match("^U([%dA-Fa-f]+)$")
	if hex then return M.utf8_encode(tonumber(hex, 16)) end
	local numeric = name:match("^0x0*100(%x+)$")
	if numeric then return M.utf8_encode(tonumber(numeric, 16)) end

	local lib = xkb()
	if lib then
		local sym = lib.from_name(name)
		if sym then return lib.to_utf8(sym) end
	end

	return nil
end

--- Resolves an already-numeric keysym to its UTF-8 identity.
---
--- Capture gets numeric keysyms directly from xkb_state. Routing them through
--- this module keeps the libxkbcommon binding in one place and, unlike
--- xkb_state_key_get_utf8(), does not apply Ctrl transformations. That makes the
--- result suitable for shortcut identity while the state-derived UTF-8 remains
--- the text path.
--- @param sym integer Numeric xkb_keysym_t.
--- @return string|nil UTF-8 identity, or nil for non-text keysyms.
function M.from_id(sym)
	if type(sym) ~= "number" or sym == 0 then return nil end
	local lib = xkb()
	return lib and lib.to_utf8(sym) or nil
end

return M
