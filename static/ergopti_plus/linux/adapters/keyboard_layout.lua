--- adapters/keyboard_layout.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Adapter (Linux)
--- DESCRIPTION:
--- Answers the question injection actually has: to type this character, which
--- keycode do I press, and with which modifiers?
---
--- WHY THE QUESTION IS THIS SHAPE:
--- uinput sends keycodes. The compositor applies the user's XKB layout on top —
--- identically under X11 and Wayland, because XKB is the only mapping stage
--- there is. So typing a character is the inverse problem, and it has exactly one
--- correct source: the keymap the server has actually loaded. ydotool assumes US
--- and produces gibberish on AZERTY, BÉPO, Dvorak and German; this driver's
--- replacements are overwhelmingly accented French, so that is the common path
--- here rather than an edge case.
---
--- Note what this does NOT imply. Capture and injection remain display-server
--- agnostic — evdev in, uinput out, no branch. The only thing that differs is
--- which command prints the keymap, which is one line in this file.
---
--- FEATURES & RATIONALE:
--- 1. The lowest level wins. A character reachable both unshifted and at level 3
---    is typed unshifted: fewer synthetic modifiers means fewer ways for a
---    modifier to be left held if an injection is interrupted.
--- 2. Built once, cached, rebuilt on demand. Dumping and parsing a keymap costs
---    a subprocess and a few thousand pattern matches — fine at startup, absurd
---    per keystroke. refresh() exists because a user can change layout at
---    runtime and the table would otherwise be wrong until the next login.
--- 3. Degrades to nothing, never to a guess. With no keymap available every
---    resolve() returns nil, and the caller routes through the clipboard instead.
---    Falling back to a built-in US table is exactly the bug this replaces: it
---    does not fail, it types the wrong characters.
--- 4. An explicit override exists. A user whose session cannot be probed at all
---    can name a keymap file in the config, which is the one escape hatch that
---    does not involve guessing on their behalf.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Shell = require("adapters.shell_runner")
local DisplayServer = require("infra.display_server")
local XkbKeymap = require("infra.xkb_keymap")
local Keysym = require("infra.keysym")
local XkbCapture = require("adapters.xkb_capture")
local XkbRmlvo = require("infra.xkb_rmlvo")
local ConfigPaths = require("infra.config_paths")

local LOG = "adapters.keyboard_layout"

-- How the keymap is obtained, in order of preference.
--   xkbcli dump-keymap-{wayland,x11} — libxkbcommon 1.8.0+ (Feb 2025), the
--     only command that works on both servers and the reason this is one code
--     path rather than two.
--   xkbcomp — the pre-xkbcli X11 answer, present wherever xorg is. On Wayland
--     it reads XWAYLAND's keymap, which is exact rather than approximate:
--     XWayland is a Wayland client and receives the compositor's keymap
--     through wl_keyboard.keymap like any other. Xwayland itself needs xkbcomp,
--     so every Wayland desktop that runs X applications has it.
--   xkbcli compile-keymap from the session's layout names — the last resort,
--     for a compositor without XWayland on a libxkbcommon older than 1.8.
--     Every LTS distribution shipped such a libxkbcommon when this was written
--     (Ubuntu 24.04: 1.6), and without these two fallbacks the daemon refused
--     the keyboard and exited on their default Wayland session.
local WAYLAND_DUMP = "xkbcli dump-keymap-wayland 2>/dev/null"
local X11_DUMP     = "xkbcli dump-keymap-x11 2>/dev/null"
local X11_FALLBACK = "xkbcomp -xkb \"$DISPLAY\" - 2>/dev/null"

-- Where each desktop keeps the layout names, read in this order. GNOME's most
-- recently used source is the active one; `sources` is only its fallback when
-- the MRU list has never been written.
local GNOME_MRU     = "gsettings get org.gnome.desktop.input-sources mru-sources 2>/dev/null"
local GNOME_SOURCES = "gsettings get org.gnome.desktop.input-sources sources 2>/dev/null"
local GNOME_OPTIONS = "gsettings get org.gnome.desktop.input-sources xkb-options 2>/dev/null"
local LOCALECTL     = "localectl status 2>/dev/null"
local KEYBOARD_DEFAULTS = { "/etc/default/keyboard", "/etc/vconsole.conf" }

-- A parsed keymap with fewer entries than this is a parse that went wrong, not a
-- minimal layout: the smallest real keymap still carries a full alphabet, digits
-- and punctuation across several levels.
local MIN_PLAUSIBLE_ENTRIES = 60

-- char → { keycode = integer, level = integer, mods = table }. nil until built.
local _table = nil

-- What produced the loaded keymap (a command or "override"), for diagnostics.
local _source = nil

-- Set once when no keymap could be obtained, so the reason is logged once rather
-- than per expansion.
local _reported_absent = false




-- ===============================================
-- ===============================================
-- ======= 1/ Obtaining the keymap ===============
-- ===============================================
-- ===============================================

--- Reads a whole file, or nil.
--- @param path string
--- @return string|nil
local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text
end

--- The session's layout names, from the first desktop store that has them.
--- @return table|nil Descriptor from infra/xkb_rmlvo.lua.
local function session_layout_names()
	local options = nil
	if Shell.has_command("gsettings") then
		options = Shell.exec(GNOME_OPTIONS)
		local desc = XkbRmlvo.parse_gnome(Shell.exec(GNOME_MRU), options)
			or XkbRmlvo.parse_gnome(Shell.exec(GNOME_SOURCES), options)
		if desc then return desc end
	end

	local desc = XkbRmlvo.parse_kxkbrc(read_file(ConfigPaths.config_home() .. "/kxkbrc"))
		or XkbRmlvo.from_env()
		or XkbRmlvo.parse_localectl(Shell.exec(LOCALECTL))
	if desc then return desc end

	for _, path in ipairs(KEYBOARD_DEFAULTS) do
		desc = XkbRmlvo.parse_keyboard_defaults(read_file(path))
		if desc then return desc end
	end
	return nil
end

--- Runs the dump command appropriate to this session.
--- @return string|nil The keymap text, or nil when nothing could produce one.
--- @return string|nil The command that produced it, for the log.
local function dump_keymap()
	local candidates = {}
	if DisplayServer.is_wayland() then
		candidates[#candidates + 1] = WAYLAND_DUMP
		local display = os.getenv("DISPLAY")
		if display and display ~= "" then candidates[#candidates + 1] = X11_FALLBACK end
	elseif DisplayServer.is_x11() then
		candidates[#candidates + 1] = X11_DUMP
		candidates[#candidates + 1] = X11_FALLBACK
	else
		-- No display server means no keymap to read and nothing to type into.
		return nil, nil
	end

	for _, cmd in ipairs(candidates) do
		local out = Shell.exec(cmd)
		if type(out) == "string" and out:find("xkb_keymap", 1, true) then
			return out, cmd
		end
	end

	local desc = session_layout_names()
	if desc then
		local cmd = XkbRmlvo.compile_command(desc)
		local out = Shell.exec(cmd)
		if type(out) == "string" and out:find("xkb_keymap", 1, true) then
			return out, cmd .. " (layout names from " .. desc.source .. ")"
		end
		Logger.warn(LOG, "Compiling the session layout (%s from %s) produced no keymap.",
			desc.layout, desc.source)
	end
	return nil, nil
end

--- Reads a user-supplied keymap file, when one is configured.
--- @param path string|nil Absolute path to a keymap dump.
--- @return string|nil
local function read_override(path)
	if type(path) ~= "string" or path == "" then return nil end
	local fh = io.open(path, "r")
	if not fh then
		Logger.warn(LOG, "Keymap override '%s' is not readable — ignoring it.", path)
		return nil
	end
	local text = fh:read("*a")
	fh:close()
	return text
end




-- ===============================================
-- ===============================================
-- ======= 2/ Building the table =================
-- ===============================================
-- ===============================================

--- Builds char → (keycode, level, mods) from a keymap dump, by text alone.
---
--- NOT what refresh() uses. The text model assumes every key follows the
--- standard four-level type (level 2 = Shift, 3 = AltGr), which the keypad
--- (NumLock) and the Ergopti layout (Shift on level 3) are not; the live table
--- comes from libxkbcommon through XkbCapture.inverse_table(). This remains the
--- libxkbcommon-free model the planner's fixture tests drive plan() with.
--- @param text string Keymap dump.
--- @return table char → { keycode, level, mods }, and the count.
function M.build(text)
	local built = {}
	local entries = XkbKeymap.parse(text or "")

	for _, entry in ipairs(entries) do
		local char = Keysym.to_char(entry.keysym)
		if char then
			local existing = built[char]
			-- Lowest level wins. Every extra level is a synthetic modifier held
			-- across the keystroke, and a modifier is the thing that stays stuck
			-- when an injection is interrupted.
			if not existing or entry.level < existing.level then
				built[char] = {
					keycode = entry.keycode,
					level   = entry.level,
					mods    = XkbKeymap.LEVEL_MODIFIERS[entry.level] or {},
				}
			end
		end
	end

	local count = 0
	for _ in pairs(built) do count = count + 1 end
	return built, count
end




-- ===============================================
-- ===============================================
-- ======= 3/ Public API =========================
-- ===============================================
-- ===============================================

--- Builds the table from the running session, replacing any cached one.
--- @param override_path string|nil Optional keymap file to use instead of probing.
--- @return boolean True when a usable table is loaded.
function M.refresh(override_path)
	Logger.start(LOG, "Resolving the active keyboard layout…")

	local text, source = read_override(override_path), "override"
	if not text then text, source = dump_keymap() end

	if not text then
		_table = nil
		if not _reported_absent then
			_reported_absent = true
			Logger.error(LOG,
				"No keymap available (%s session) — characters cannot be typed as "
					.. "keystrokes. Install libxkbcommon-tools, or expansions will go "
					.. "through the clipboard.",
				DisplayServer.kind())
		end
		return false
	end

	-- Capture and injection consume the SAME server dump. Loading capture first
	-- is intentional: libxkbcommon validates the complete keymap and publishes a
	-- fresh state atomically, while the inverse table below is only an injection
	-- optimisation. If that partial parser cannot cover a valid keymap, capture
	-- must still mirror what the desktop types and injection can safely fall back
	-- to the clipboard.
	local capture_ok, capture_err = XkbCapture.load(text)
	if not capture_ok then
		_table = nil
		Logger.error(LOG, "Active keymap cannot initialise XKB capture via %s — %s.",
			tostring(source), tostring(capture_err))
		return false
	end

	-- Asked of libxkbcommon on the keymap capture just validated, not parsed
	-- from the text: the parser assumed standard four-level types, which the
	-- keypad (NumLock) and the Ergopti layout (Shift on level 3) are not.
	local built, inverse_err = XkbCapture.inverse_table()
	if not built then
		_table = nil
		Logger.error(LOG, "Cannot enumerate the keymap via %s — %s.", tostring(source), tostring(inverse_err))
		return false
	end
	local count = 0
	for _ in pairs(built) do count = count + 1 end
	if count < MIN_PLAUSIBLE_ENTRIES then
		-- A keymap that parsed to almost nothing is a parse failure wearing the
		-- shape of a success, and the consequence is silent: every expansion
		-- quietly reroutes to the clipboard and nobody knows why.
		_table = nil
		Logger.error(LOG, "Keymap parsed to %d character(s) via %s — refusing it as a parse failure.",
			count, tostring(source))
		return false
	end

	_table = built
	_source = source
	_reported_absent = false
	Logger.success(LOG, "Layout resolved: %d typable character(s) via %s.", count, tostring(source))
	return true
end

--- What produced the loaded keymap, or nil when none is loaded.
--- @return string|nil
function M.source()
	return _table and _source or nil
end

--- The key a Ctrl shortcut on `letter` must press in the live layout.
---
--- Applications match Ctrl+V by the SYMBOL the key produces, so the physical key
--- depends on the layout: the same on QWERTY and AZERTY for c, v and t, but not
--- for w (Ctrl+KEY_W is Ctrl+Z, undo, on AZERTY), and different for nearly every
--- letter on Ergopti, where KEY_V types a comma. A letter the layout has no
--- unmodified key for (a Cyrillic layout) keeps `us_code`: that is exactly the
--- key GTK and Qt fall back to for shortcuts on a non-Latin layout.
--- @param letter string A single lowercase ASCII letter.
--- @param us_code integer The letter's evdev code on a US layout.
--- @return integer
function M.shortcut_keycode(letter, us_code)
	local hit = _table and _table[letter]
	if hit and #hit.mods == 0 then return hit.keycode end
	return us_code
end

--- True when a layout table is loaded.
--- @return boolean
function M.is_ready()
	return _table ~= nil
end

--- Resolves one character to the keystroke that produces it.
--- @param char string A single UTF-8 character.
--- @return table|nil { keycode = integer, level = integer, mods = table }.
function M.resolve(char)
	if not _table or type(char) ~= "string" or char == "" then return nil end
	return _table[char]
end

--- Resolves a whole string, stopping at the first character the layout cannot
--- type.
---
--- All-or-nothing on purpose: a partial keystroke plan would type the first half
--- of a replacement and drop the rest, which is worse than not typing it at all
--- because the trigger has already been erased. The caller routes an
--- unresolvable string through the clipboard instead.
--- @param text string
--- @return table|nil Array of { keycode, mods } in order, or nil.
--- @return string|nil The character that could not be typed.
function M.plan(text)
	if type(text) ~= "string" then return nil, nil end
	if not _table then return nil, text:sub(1, 1) end

	local plan = {}
	for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		local hit = _table[char]
		if not hit then return nil, char end
		plan[#plan + 1] = hit
	end
	return plan, nil
end

--- Test seam: installs a table directly, bypassing the probe.
--- @param built table|nil
function M._set_table_for_test(built)
	_table = built
	_reported_absent = false
end

return M
