--- ui/menu/menu_keyboard_layout.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Menu
--- DESCRIPTION:
--- Provides the "Disposition clavier" submenu in the Hammerspoon menu bar.
--- Lets the user install the bundled Ergopti keyboard layout (user or system),
--- open the macOS input-source preferences, switch the menubar logo variant,
--- and inspect / activate any of the input sources currently enabled in macOS.
---
--- FEATURES & RATIONALE:
--- 1. Single source of truth for bundle discovery: the highest version found
---    in static/drivers/macos/bundles/ wins, so no hardcoded version string.
--- 2. Idempotent install detection: items become disabled with an
---    "Ergopti (<scope>) installé ✅" label when the bundle already lives at
---    the target path, so the user can tell at a glance where it landed.
--- 3. Resilient input-source listing: parsing macOS preferences plist is fragile,
---    so failure paths fall back to opening the Keyboard preferences panel and
---    are logged explicitly — no silent failures.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")
local LOG    = "menu.keyboard_layout"




-- ===================================
-- ===================================
-- ======= 1/ Module Constants =======
-- ===================================
-- ===================================

-- Path of the bundles directory relative to the Hammerspoon driver root.
-- Resolved at runtime against base_dir (which already ends with "/")
local BUNDLES_RELDIR = "../macos/bundles/"

-- Target install paths on macOS
local USER_LAYOUTS_DIR   = os.getenv("HOME") and (os.getenv("HOME") .. "/Library/Keyboard Layouts/") or "~/Library/Keyboard Layouts/"
local SYSTEM_LAYOUTS_DIR = "/Library/Keyboard Layouts/"

-- Persisted preference key for the menubar logo variant
local LOGO_VARIANT_KEY     = "ergopti_menubar_logo_variant"
local LOGO_VARIANT_DEFAULT = "simple"

-- macOS URL that opens System Settings → Keyboard → Input Sources directly
local KEYBOARD_PREFS_URL = "x-apple.systempreferences:com.apple.preference.keyboard?InputSources"

-- All Ergopti variants packaged in the bundle. Used to expose a submenu with
-- a one-click TISEnableInputSource entry for each. The order shown in the
-- menu mirrors the natural progression: base → ANSI → plus → plus ANSI →
-- plus_plus → plus_plus ANSI.
local ERGOPTI_VARIANTS = {
	{ id = "com.apple.keylayout.ergopti",                label = "Ergopti" },
	{ id = "com.apple.keylayout.ergopti.ansi",           label = "Ergopti ANSI" },
	{ id = "com.apple.keylayout.ergopti.plus",           label = "Ergopti+" },
	{ id = "com.apple.keylayout.ergopti.plus.ansi",      label = "Ergopti+ ANSI" },
	{ id = "com.apple.keylayout.ergopti.plus_plus",      label = "Ergopti++" },
	{ id = "com.apple.keylayout.ergopti.plus_plus.ansi", label = "Ergopti++ ANSI" },
}

-- Delay before rebuilding the menu after a bundle install. macOS reloads the
-- input-source list asynchronously; calling hs.keycodes too quickly during
-- that window has been observed to crash Hammerspoon. 1.5 s is a safe margin.
local POST_INSTALL_REFRESH_DELAY = 1.5

-- Delay before firing a TIS (Text Input Sources) call from a menu-click
-- handler. macOS posts kTISNotifyEnabledKeyboardInputSourcesChanged /
-- kTISNotifySelectedKeyboardInputSourceChanged synchronously when those
-- functions run, and Hammerspoon's hs.keycodes observers can re-enter Lua
-- state mid-handler. Bouncing through hs.timer guarantees the menu click
-- has fully unwound before the TIS call mutates input-source state.
local TIS_CALL_DELAY = 0.1




-- =====================================
-- =====================================
-- ======= 2/ Bundle Discovery =========
-- =====================================
-- =====================================

--- Parses a bundle directory name like "Ergopti_v2.2.1.bundle" into a
--- comparable version table {2, 2, 1}.
--- @param name string Bundle directory basename.
--- @return table|nil Numeric version components, or nil if unparseable.
local function parse_version(name)
	local v = name:match("_v([%d%.]+)%.bundle$")
	if not v then return nil end
	local parts = {}
	for n in v:gmatch("(%d+)") do parts[#parts + 1] = tonumber(n) end
	if #parts == 0 then return nil end
	return parts
end

--- Compares two version tables lexicographically.
--- @param a table
--- @param b table
--- @return boolean true if a > b.
local function version_gt(a, b)
	for i = 1, math.max(#a, #b) do
		local ai, bi = a[i] or 0, b[i] or 0
		if ai ~= bi then return ai > bi end
	end
	return false
end

--- Lists every "Ergopti_v*.bundle" inside the given directory.
--- Pure-Lua via lfs-less directory scan using io.popen (cross-platform-ish).
--- @param dir string Absolute path of the bundles directory.
--- @return table List of basenames (no trailing slash).
local function list_bundles(dir)
	local out = {}
	local cmd
	if package.config:sub(1, 1) == "\\" then
		-- Windows (used during Lua test runs)
		cmd = string.format('cmd /c dir /b /a:d "%s"', dir:gsub("/", "\\"))
	else
		cmd = string.format("ls -1 '%s'", dir)
	end
	local p = io.popen(cmd)
	if not p then return out end
	for line in p:lines() do
		line = line:gsub("[\r\n]+$", "")
		if line:match("^Ergopti_v[%d%.]+%.bundle$") then
			out[#out + 1] = line
		end
	end
	p:close()
	return out
end

--- Picks the highest-version bundle inside dir.
--- @param dir string Absolute path of the bundles directory.
--- @return string|nil Basename of the latest bundle, or nil if none found.
function M.pick_latest_bundle(dir)
	local best, best_ver = nil, nil
	for _, name in ipairs(list_bundles(dir)) do
		local ver = parse_version(name)
		if ver and (not best_ver or version_gt(ver, best_ver)) then
			best, best_ver = name, ver
		end
	end
	return best
end

-- Internal helpers exposed for unit tests (additional helpers defined later in
-- this file are wired up at the bottom, just before `return M`).
M._parse_version = parse_version
M._version_gt    = version_gt




-- =====================================
-- =====================================
-- ======= 3/ Install Helpers ==========
-- =====================================
-- =====================================

--- Returns true if the file/dir at the given path exists (best-effort).
--- io.open(path, "r") fails on directories on macOS, and os.rename() on a
--- system-protected location like "/Library/Keyboard Layouts" can hit SIP
--- restrictions even for stat-style probes — so we shell out to /bin/test
--- which handles files, directories, and bundles uniformly.
--- @param path string Absolute path.
--- @return boolean
local function path_exists(path)
	if type(path) ~= "string" or path == "" then return false end
	if hs and hs.fs and type(hs.fs.attributes) == "function" then
		local attrs = hs.fs.attributes(path)
		if attrs then return true end
	end
	-- Shell fallback. -e tests for any kind of filesystem object.
	local cmd = string.format("/bin/test -e %q && echo OK", path)
	local out = hs.execute and hs.execute(cmd) or nil
	if type(out) == "string" and out:find("OK") then return true end
	-- Last-resort fallbacks for plain Lua test runs (no hs available)
	local f = io.open(path, "r")
	if f then f:close(); return true end
	local ok = os.rename(path, path)
	return ok == true
end

--- Lists every Ergopti_v*.bundle currently installed in `dir`.
--- Returns the parsed version components for each so callers can compare to
--- the latest available version without having to re-parse strings.
--- @param dir string Absolute path of the Keyboard Layouts directory.
--- @return table Array of { name = string, version = table } entries.
local function find_installed_bundles(dir)
	local out = {}
	if type(dir) ~= "string" or dir == "" then return out end
	local cmd = string.format("ls -1 %q 2>/dev/null", dir)
	local p = io.popen(cmd)
	if not p then return out end
	for line in p:lines() do
		line = line:gsub("[\r\n]+$", "")
		if line:match("^Ergopti_v[%d%.]+%.bundle$") then
			local v = parse_version(line)
			if v then out[#out + 1] = { name = line, version = v } end
		end
	end
	p:close()
	return out
end

--- Returns the highest installed Ergopti version in the given directory.
--- @param dir string Absolute path of the Keyboard Layouts directory.
--- @return table|nil { name = string, version = table } or nil if none.
local function highest_installed(dir)
	local best
	for _, entry in ipairs(find_installed_bundles(dir)) do
		if not best or version_gt(entry.version, best.version) then
			best = entry
		end
	end
	return best
end

--- Renders a version components table back to a human-readable string.
--- @param v table Numeric version components, e.g. {2,2,1}.
--- @return string e.g. "2.2.1".
local function version_str(v)
	if type(v) ~= "table" then return "?" end
	local parts = {}
	for _, n in ipairs(v) do parts[#parts + 1] = tostring(n) end
	return table.concat(parts, ".")
end

--- Copies the latest bundle to the user's Keyboard Layouts directory.
--- Existing Ergopti_v*.bundle entries are removed first so the layout list
--- doesn't end up with multiple side-by-side versions.
--- @param bundles_dir string Absolute path of the source bundles directory.
--- @param bundle_name string Basename of the bundle to install.
--- @return boolean true on success.
local function install_user(bundles_dir, bundle_name)
	Logger.start(LOG, "Installing %s into the user Keyboard Layouts folder…", bundle_name)
	local cmd = string.format(
		'mkdir -p %q && rm -rf %q/Ergopti_v*.bundle && cp -R %q %q',
		USER_LAYOUTS_DIR,
		USER_LAYOUTS_DIR:gsub("/$", ""),
		bundles_dir .. bundle_name,
		USER_LAYOUTS_DIR
	)
	local out, ok = hs.execute(cmd)
	if ok then
		Logger.success(LOG, "User install done — %s.", bundle_name)
		if hs.alert then pcall(hs.alert.show, "Ergopti installé pour l'utilisateur.") end
		return true
	end
	Logger.error(LOG, "User install failed: %s.", tostring(out))
	return false
end

--- Copies the latest bundle to /Library/Keyboard Layouts/ via osascript with
--- administrator privileges. Triggers a macOS password prompt. Existing
--- Ergopti_v*.bundle entries are removed first to keep the list clean.
--- @param bundles_dir string Absolute path of the source bundles directory.
--- @param bundle_name string Basename of the bundle to install.
--- @return boolean true on success.
local function install_system(bundles_dir, bundle_name)
	Logger.start(LOG, "Installing %s into the system Keyboard Layouts folder (sudo)…", bundle_name)
	local shell_cmd = string.format(
		"rm -rf '%sErgopti_v'*.bundle && cp -R '%s%s' '%s'",
		SYSTEM_LAYOUTS_DIR, bundles_dir, bundle_name, SYSTEM_LAYOUTS_DIR
	)
	local script = string.format(
		"do shell script \"%s\" with administrator privileges",
		shell_cmd
	)
	local ok = false
	if hs.osascript and type(hs.osascript.applescript) == "function" then
		ok = hs.osascript.applescript(script) and true or false
	end
	if ok then
		Logger.success(LOG, "System install done — %s.", bundle_name)
		if hs.alert then pcall(hs.alert.show, "Ergopti installé pour le système.") end
		return true
	end
	Logger.error(LOG, "System install failed (sudo cancelled or copy error).")
	return false
end




-- ============================================
-- ============================================
-- ======= 4/ Input Source Enumeration ========
-- ============================================
-- ============================================

--- Reads the raw list of enabled input source identifiers straight from
--- com.apple.HIToolbox.plist. Unlike `hs.keycodes.layouts(true)` — which
--- silently drops entries it cannot resolve to an installed bundle — this
--- helper returns every entry in the user's enabled-list, including
--- orphaned legacy IDs that lost their backing bundle after an upgrade.
--- @return table Deduplicated list of identifiers (Bundle ID or KeyboardLayout Name).
local function read_enabled_raw_ids()
	if type(hs.execute) ~= "function" then return {} end
	local out, ok = hs.execute("/usr/bin/defaults read com.apple.HIToolbox AppleEnabledInputSources 2>/dev/null")
	if not ok or type(out) ~= "string" or out == "" then return {} end
	local seen, sources = {}, {}
	local function push(s)
		if s and s ~= "" and not seen[s] then
			seen[s] = true
			sources[#sources + 1] = s
		end
	end
	-- "Bundle ID" entries (custom keylayout bundles)
	for id in out:gmatch('"Bundle ID"%s*=%s*"([^"]+)"') do push(id) end
	for id in out:gmatch('Bundle ID%s*=%s*([%w%.%-_]+);') do push(id) end
	-- "KeyboardLayout Name" entries (system layouts like French, U.S.)
	for nm in out:gmatch('"KeyboardLayout Name"%s*=%s*"([^"]+)"') do push(nm) end
	for nm in out:gmatch('KeyboardLayout Name%s*=%s*([%w%-_]+);') do push(nm) end
	return sources
end

--- Lists every keyboard layout currently enabled in macOS by combining the
--- raw enabled-list from preferences with whatever `hs.keycodes.layouts(true)`
--- returns. The raw list is authoritative — hs.keycodes filters orphaned
--- entries, but the user still wants to see them so they can clean up.
--- @return table Sorted list of layout identifiers / names.
local function list_enabled_input_sources()
	local raw = read_enabled_raw_ids()
	if #raw > 0 then
		table.sort(raw)
		return raw
	end
	-- Fallback when defaults isn't available (e.g. test environment): use
	-- the hs.keycodes API. Returns localised names rather than raw IDs.
	if not (hs.keycodes and type(hs.keycodes.layouts) == "function") then
		Logger.warn(LOG, "Both `defaults read` and hs.keycodes.layouts unavailable — empty list.")
		return {}
	end
	local ok, layouts = pcall(hs.keycodes.layouts, true)
	if not ok or type(layouts) ~= "table" then
		Logger.warn(LOG, "hs.keycodes.layouts() failed: %s.", tostring(layouts))
		return {}
	end
	table.sort(layouts)
	return layouts
end

--- Returns the name of the currently-selected keyboard layout.
--- @return string|nil
local function current_input_source_name()
	if not (hs.keycodes and type(hs.keycodes.currentLayout) == "function") then return nil end
	local ok, name = pcall(hs.keycodes.currentLayout)
	if ok and type(name) == "string" and name ~= "" then return name end
	return nil
end

--- Runs an AppleScript in a child osascript process so that any failure or
--- crash inside Carbon/TIS stays contained — `hs.osascript.applescript` runs
--- in-process and was crashing Hammerspoon on every TIS-mutating call. The
--- script is written to a temp file, executed by `/usr/bin/osascript`, then
--- the file is removed.
--- @param script string The AppleScript source code to execute.
--- @return boolean ok, string|nil output Stdout produced by the script.
local function run_osascript_isolated(script)
	if type(hs.execute) ~= "function" then return false, nil end
	local path = os.tmpname()
	-- Lua's os.tmpname returns paths under /tmp on macOS; the file does not
	-- exist yet, so io.open with "w" is safe.
	local fh = io.open(path, "w")
	if not fh then return false, nil end
	fh:write(script)
	fh:close()
	local out, ok = hs.execute(string.format("/usr/bin/osascript %q", path))
	os.remove(path)
	return ok and true or false, out
end

--- Activates the given keyboard layout. First tries hs.keycodes.setLayout
--- (works when the bundle's localisation is intact); on failure, runs
--- TISSelectInputSource via osascript in an isolated subprocess so that any
--- TIS-side error cannot crash Hammerspoon.
--- @param raw_id string Either the localised name or the TISInputSourceID.
--- @return boolean true on success.
local function set_input_source(raw_id)
	if hs.keycodes and type(hs.keycodes.setLayout) == "function" then
		local ok = pcall(hs.keycodes.setLayout, raw_id)
		if ok then
			Logger.info(LOG, "Active layout switched to '%s' (hs.keycodes).", raw_id)
			return true
		end
	end
	local script = string.format([[
use framework "Carbon"
use framework "Foundation"
on run
	set theProps to current application's NSDictionary's dictionaryWithObjects:{"%s"} forKeys:{"TISPropertyInputSourceID"}
	set theSources to current application's TISCreateInputSourceList(theProps, true)
	if theSources is not missing value and (count of (theSources as list)) > 0 then
		set theSource to item 1 of (theSources as list)
		current application's TISSelectInputSource(theSource)
		return "OK"
	end if
	return "MISS"
end run
]], raw_id:gsub('"', '\\"'))
	local ok, out = run_osascript_isolated(script)
	if ok and out and tostring(out):find("OK") then
		Logger.info(LOG, "Active layout switched to '%s' (TIS subprocess).", raw_id)
		return true
	end
	Logger.warn(LOG, "Failed to switch active layout to '%s' (out=%s).", raw_id, tostring(out))
	return false
end

--- Enables the given input source in the user's enabled-list and selects it,
--- via TISEnableInputSource + TISSelectInputSource. The bundle providing the
--- source MUST already be on disk, otherwise TISCreateInputSourceList returns
--- no match. The script runs in an isolated osascript subprocess (see
--- run_osascript_isolated) so any TIS-side error stays contained.
--- @param raw_id string TISInputSourceID, e.g. "com.apple.keylayout.ergopti.plus".
--- @return boolean true on success.
local function enable_and_select_source(raw_id)
	if type(raw_id) ~= "string" or raw_id == "" then return false end
	local script = string.format([[
use framework "Carbon"
use framework "Foundation"
on run
	set theProps to current application's NSDictionary's dictionaryWithObjects:{"%s"} forKeys:{"TISPropertyInputSourceID"}
	set theSources to current application's TISCreateInputSourceList(theProps, true)
	if theSources is missing value then return "MISS"
	set theList to theSources as list
	if (count of theList) = 0 then return "MISS"
	set theSource to item 1 of theList
	current application's TISEnableInputSource(theSource)
	current application's TISSelectInputSource(theSource)
	return "OK"
end run
]], raw_id:gsub('"', '\\"'))
	local ok, out = run_osascript_isolated(script)
	if ok and out and tostring(out):find("OK") then
		Logger.success(LOG, "Enabled and selected '%s'.", raw_id)
		return true
	end
	Logger.warn(LOG, "Failed to enable '%s' (out=%s).", raw_id, tostring(out))
	return false
end

--- Returns true if the given layout name looks like a legacy Ergopti bundle
--- identifier (the pre-v2.2.2 'com.apple.keyboardlayout.ergopti.vX_Y_Z…' form).
--- Used to decide whether the active list contains entries that need to be
--- replaced by their stable-id counterparts.
--- @param name string
--- @return boolean
local function is_legacy_ergopti_id(name)
	if type(name) ~= "string" then return false end
	local lower = name:lower()
	return lower:find("keyboardlayout%.ergopti", 1) ~= nil
		or lower:find("ergopti[._]v%d", 1) ~= nil
end

--- Maps a legacy Ergopti identifier to its v2.2.2+ stable equivalent.
--- com.apple.keyboardlayout.ergopti.v2_2_0[.suffix] → com.apple.keylayout.ergopti[.suffix]
--- @param old string
--- @return string
local function migrate_legacy_id(old)
	if type(old) ~= "string" then return old end
	local m = old:gsub("^com%.apple%.keyboardlayout%.", "com.apple.keylayout.")
	-- Strip the version segment .vX_Y_Z (or .vX.Y.Z) wherever it appears
	m = m:gsub("%.v%d+[._]%d+[._]%d+", "")
	m = m:gsub("%.v%d+[._]%d+", "")
	m = m:gsub("%.v%d+", "")
	return m
end

--- Replaces legacy Ergopti entries in the user's active input-source list with
--- their v2.2.2+ stable-id equivalents, then re-activates the appropriate
--- variant. Uses TISDisableInputSource / TISEnableInputSource via the
--- AppleScript ObjC bridge so no external tooling is required.
--- The latest bundle MUST already be installed locally — TIS only enables
--- input sources for layouts present on disk.
--- @param legacy_active table Names from list_enabled_input_sources() that look legacy.
--- @return boolean true on success.
local function upgrade_active_list(legacy_active)
	if type(legacy_active) ~= "table" or #legacy_active == 0 then return false end
	-- Build the AppleScript: a sequence of disable+enable operations
	local lines = {
		"use framework \"Carbon\"",
		"use framework \"Foundation\"",
		"on findSource(theID)",
		"\tset theProps to current application's NSDictionary's dictionaryWithObjects:{theID} forKeys:{\"TISPropertyInputSourceID\"}",
		"\tset theSources to current application's TISCreateInputSourceList(theProps, true)",
		"\tif theSources is missing value then return missing value",
		"\tset theList to theSources as list",
		"\tif (count of theList) = 0 then return missing value",
		"\treturn item 1 of theList",
		"end findSource",
		"on run",
		"\tset disabled to {}",
		"\tset enabled to {}",
	}
	-- Disable each legacy id, then enable its migrated equivalent. The last
	-- migrated id is also selected so the active layout follows the upgrade.
	local last_new
	for _, old in ipairs(legacy_active) do
		local new_id = migrate_legacy_id(old)
		last_new = new_id
		table.insert(lines, string.format("\tset oldSrc to my findSource(\"%s\")", old:gsub('"', '\\"')))
		table.insert(lines, "\tif oldSrc is not missing value then")
		table.insert(lines, "\t\tcurrent application's TISDisableInputSource(oldSrc)")
		table.insert(lines, "\t\tset end of disabled to oldSrc")
		table.insert(lines, "\tend if")
		table.insert(lines, string.format("\tset newSrc to my findSource(\"%s\")", new_id:gsub('"', '\\"')))
		table.insert(lines, "\tif newSrc is not missing value then")
		table.insert(lines, "\t\tcurrent application's TISEnableInputSource(newSrc)")
		table.insert(lines, "\t\tset end of enabled to newSrc")
		table.insert(lines, "\tend if")
	end
	if last_new then
		table.insert(lines, string.format("\tset selSrc to my findSource(\"%s\")", last_new:gsub('"', '\\"')))
		table.insert(lines, "\tif selSrc is not missing value then current application's TISSelectInputSource(selSrc)")
	end
	table.insert(lines, "\treturn (count of disabled) & \"/\" & (count of enabled)")
	table.insert(lines, "end run")
	local script = table.concat(lines, "\n")
	Logger.start(LOG, "Upgrading %d legacy Ergopti entry(ies) in the active input-source list…", #legacy_active)
	local ok, out = run_osascript_isolated(script)
	if ok then
		Logger.success(LOG, "List upgrade applied (%s).", tostring(out))
		return true
	end
	Logger.error(LOG, "List upgrade failed (out=%s).", tostring(out))
	return false
end

--- Extracts the Ergopti version embedded in an input-source identifier.
--- Supports both legacy ("com.apple.keyboardlayout.ergopti.v2_2_0") and
--- current macOS-standard ("com.apple.keylayout.ergopti.v2.2.1") forms.
--- @param name string Raw or cleaned layout name.
--- @return table|nil Numeric version components or nil if not an Ergopti id.
local function extract_ergopti_version(name)
	if type(name) ~= "string" then return nil end
	local lower = name:lower()
	if not lower:find("ergopti", 1, true) then return nil end
	-- Match v<major>(_|.)<minor>(_|.)<patch> after the ergopti keyword
	local maj, min, pat = lower:match("ergopti[._]v(%d+)[._%-](%d+)[._%-](%d+)")
	if maj then return { tonumber(maj), tonumber(min), tonumber(pat) } end
	-- Match shorter forms like ergopti_v2.2 or ergopti.v2
	local m1, m2 = lower:match("ergopti[._]v(%d+)[._%-](%d+)")
	if m1 then return { tonumber(m1), tonumber(m2), 0 } end
	local m = lower:match("ergopti[._]v(%d+)")
	if m then return { tonumber(m), 0, 0 } end
	-- An Ergopti layout with no version suffix is treated as version 0
	return { 0, 0, 0 }
end

--- Renders an Ergopti input-source identifier as a human-friendly display
--- name (e.g. "Ergopti+ v2.2.0 ANSI"). macOS normally provides this string
--- via the bundle's InfoPlist.strings file, but bundles generated before the
--- v2.2.2 fix used the keylayout filename as the localisation key instead of
--- the TISInputSourceID, so hs.keycodes fell back to the raw ID. This helper
--- recovers the pretty form purely from the ID structure.
--- @param id string Raw or already-prefix-stripped Ergopti identifier.
--- @return string|nil Friendly display name, or nil if the id is not Ergopti.
local function format_ergopti_display(id)
	if type(id) ~= "string" then return nil end
	local lower = id:lower()
	if not lower:find("ergopti", 1, true) then return nil end
	-- Variant detection — order matters because "plus_plus" must match before "plus"
	local variant
	if lower:find("plus_plus") or lower:find("plus%.plus") then
		variant = "++"
	elseif lower:find("plus") then
		variant = "+"
	else
		variant = ""
	end
	local is_ansi = lower:find("ansi") ~= nil
	local v = extract_ergopti_version(id)
	local version_part = ""
	if v and (v[1] ~= 0 or v[2] ~= 0 or v[3] ~= 0) then
		version_part = string.format(" v%d.%d.%d", v[1] or 0, v[2] or 0, v[3] or 0)
	end
	local ansi_part = is_ansi and " ANSI" or ""
	return "Ergopti" .. variant .. ansi_part .. version_part
end

--- Strips the Apple keylayout / keyboardlayout / inputmethod prefixes from a
--- raw input-source identifier and reformats Ergopti entries into their
--- friendly form (e.g. "Ergopti+ v2.2.0 ANSI"). Non-Ergopti layouts keep
--- their verbose-prefix-stripped form so "com.apple.keylayout.French"
--- becomes "French".
--- @param name string Raw layout name as returned by hs.keycodes.layouts.
--- @return string Cleaned name suitable for display.
local function clean_layout_name(name)
	if type(name) ~= "string" then return tostring(name) end
	-- For Ergopti, prefer the pretty formatter so a broken-localisation bundle
	-- still renders nicely in the menu
	local pretty = format_ergopti_display(name)
	if pretty then return pretty end
	return (name
		:gsub("^com%.apple%.keylayout%.", "")
		:gsub("^com%.apple%.keyboardlayout%.", "")
		:gsub("^com%.apple%.inputmethod%.", "")
		:gsub("^com%.apple%.inputsource%.", ""))
end

--- Inspects the active input-source list and reports whether an Ergopti
--- layout is present along with its installed version (if extractable).
--- @param sources table List of layout names returned by list_enabled_input_sources.
--- @return table { present = boolean, name = string|nil, version = table|nil }
local function ergopti_in_active_layouts(sources)
	for _, n in ipairs(sources) do
		if type(n) == "string" and n:lower():find("ergopti", 1, true) then
			return { present = true, name = n, version = extract_ergopti_version(n) }
		end
	end
	return { present = false }
end




-- =================================
-- =================================
-- ======= 5/ Submenu Builder ======
-- =================================
-- =================================

--- Builds the complete "Disposition clavier" submenu item.
--- @param ctx table Global UI context. Must contain ctx.base_dir and ctx.updateMenu.
--- @return table A single hs.menubar item with a populated submenu.
--- Schedules a deferred menu rebuild. macOS reloads its input-source list
--- asynchronously after a bundle is added or removed, and calling hs.keycodes
--- in the middle of that window has been observed to crash Hammerspoon — so
--- we wait POST_INSTALL_REFRESH_DELAY seconds before refreshing.
--- @param update_menu function|nil Callback that rebuilds the menu structure.
local function schedule_menu_refresh(update_menu)
	if type(update_menu) ~= "function" then return end
	if hs.timer and type(hs.timer.doAfter) == "function" then
		hs.timer.doAfter(POST_INSTALL_REFRESH_DELAY, function() pcall(update_menu) end)
	else
		pcall(update_menu)
	end
end

--- Defers `fn` so it runs AFTER the current menu-click handler has unwound.
--- TIS (Text Input Sources) calls — TISEnableInputSource, TISSelectInputSource,
--- TISDisableInputSource — synchronously trigger macOS input-source change
--- notifications that hs.keycodes observes. Running them inside the menu
--- callback frame has been observed to re-enter Lua state and crash
--- Hammerspoon. A short hs.timer.doAfter() gives the click handler a chance
--- to return before the TIS mutation is dispatched.
--- @param fn function The TIS-touching callback to defer.
local function defer_tis_call(fn)
	if type(fn) ~= "function" then return end
	if hs.timer and type(hs.timer.doAfter) == "function" then
		hs.timer.doAfter(TIS_CALL_DELAY, function() pcall(fn) end)
	else
		pcall(fn)
	end
end

--- Wraps an install action so that, on success, every legacy Ergopti entry
--- still sitting in the user's enabled-list is replaced by its stable-id
--- counterpart, and the menu is rebuilt after a small delay.
--- @param install_fn function The actual install callback (returns true on success).
--- @param legacy_active table Legacy entries in the active input-source list.
--- @param update_menu function|nil Menu rebuild callback.
local function run_install_and_chain(install_fn, legacy_active, update_menu)
	local ok = false
	pcall(function() ok = install_fn() end)
	if ok and type(legacy_active) == "table" and #legacy_active > 0 then
		Logger.info(LOG, "Install succeeded — auto-upgrading %d legacy entry(ies) in the active list.", #legacy_active)
		pcall(upgrade_active_list, legacy_active)
	end
	schedule_menu_refresh(update_menu)
end

--- Builds an install/update menu item for one scope (user or system).
--- The label and click handler are derived from the relationship between the
--- highest installed version and the latest available bundle:
---   - latest already installed → greyed out with a success label
---   - older version installed  → "Mettre à jour (vOLD → vLATEST)"
---   - nothing installed        → "Installer (vLATEST)"
--- @param scope_label string Short scope tag for the menu label ("utilisateur"|"système").
--- @param emoji_install string Emoji prefix shown for the fresh-install label.
--- @param installed table|nil { name, version } from highest_installed(target_dir).
--- @param latest_name string Basename of the latest bundle.
--- @param latest_ver table Numeric components of the latest version.
--- @param do_install function Callback invoked when the user clicks install/update.
--- @return table A single hs.menubar item.
local function build_install_item(scope_label, emoji_install, installed, latest_name, latest_ver, do_install)
	local latest_str = version_str(latest_ver)
	if installed and not version_gt(latest_ver, installed.version) then
		-- Latest already installed — nothing to do
		return {
			title    = string.format("Ergopti (%s) v%s installé ✅", scope_label, latest_str),
			disabled = true,
		}
	end
	if installed then
		-- An older version is on disk; offer an in-place upgrade
		local old_str = version_str(installed.version)
		return {
			title = string.format("📥 Mettre à jour Ergopti (%s) — v%s → v%s", scope_label, old_str, latest_str),
			fn    = do_install,
		}
	end
	return {
		title = string.format("%s Installer Ergopti (%s) — v%s", emoji_install, scope_label, latest_str),
		fn    = do_install,
	}
end

function M.build(ctx)
	local update_menu  = ctx and ctx.updateMenu
	local refresh_icon = ctx and ctx.refresh_icon
	local base_dir     = ctx and ctx.base_dir or ""
	local bundles_dir  = base_dir .. BUNDLES_RELDIR

	local submenu = {}

	-- Pull the live state once so the closures below capture stable values
	local sources    = list_enabled_input_sources()
	local list_state = ergopti_in_active_layouts(sources)
	-- Legacy entries that need to be replaced by their stable-id counterparts
	-- when the user clicks "upgrade in list".
	local legacy_active = {}
	for _, n in ipairs(sources) do
		if is_legacy_ergopti_id(n) then legacy_active[#legacy_active + 1] = n end
	end

	local latest = M.pick_latest_bundle(bundles_dir)
	-- The list-upgrade only makes sense once the latest bundle is on disk —
	-- TIS can't enable an input source whose .bundle isn't installed.
	local latest_installed_anywhere = false
	if latest then
		local latest_ver  = parse_version(latest)
		local user_best   = highest_installed(USER_LAYOUTS_DIR)
		local system_best = highest_installed(SYSTEM_LAYOUTS_DIR)
		latest_installed_anywhere =
			(user_best   and not version_gt(latest_ver, user_best.version))
			or (system_best and not version_gt(latest_ver, system_best.version))
			or false
		Logger.debug(LOG, "Install probe — latest=%s, user_best=%s, system_best=%s, latest_installed=%s.",
			latest, user_best and user_best.name or "none",
			system_best and system_best.name or "none",
			tostring(latest_installed_anywhere))

		submenu[#submenu + 1] = build_install_item(
			"utilisateur", "📥", user_best, latest, latest_ver,
			function()
				run_install_and_chain(
					function() return install_user(bundles_dir, latest) end,
					legacy_active, update_menu
				)
			end
		)
		submenu[#submenu + 1] = build_install_item(
			"système", "🔐", system_best, latest, latest_ver,
			function()
				run_install_and_chain(
					function() return install_system(bundles_dir, latest) end,
					legacy_active, update_menu
				)
			end
		)
	else
		Logger.warn(LOG, "No Ergopti bundle found in %s.", bundles_dir)
		submenu[#submenu + 1] = {
			title    = "Aucun bundle Ergopti trouvé",
			disabled = true,
		}
	end

	-- Add / upgrade Ergopti in the macOS input-source list.
	--
	-- Five possible states:
	--   1. latest active in list           → greyed-out success label
	--   2. older active, latest installed  → in-place TIS swap (programmatic)
	--   3. older active, latest NOT installed → greyed: install latest first
	--   4. absent, latest installed        → submenu of variants for one-click TIS add
	--   5. absent, latest NOT installed    → greyed: install latest first
	local latest_ver = latest and parse_version(latest) or nil
	local latest_str = latest_ver and version_str(latest_ver) or "?"
	if list_state.present and latest_ver and list_state.version
		and not version_gt(latest_ver, list_state.version) then
		-- 1. Already up to date
		submenu[#submenu + 1] = {
			title    = string.format("Ergopti v%s dans la liste des dispositions ✅", version_str(list_state.version)),
			disabled = true,
		}
	elseif list_state.present and latest_ver and not latest_installed_anywhere then
		-- 3. Older active but latest bundle missing — block the upgrade
		local old_str = version_str(list_state.version or { 0 })
		submenu[#submenu + 1] = {
			title    = string.format("Mettre à jour la liste — installer Ergopti v%s d’abord (v%s actif)",
				latest_str, old_str),
			disabled = true,
		}
	elseif list_state.present and latest_ver then
		-- 2. Older active and latest installed — programmatic swap via TIS
		local old_str = version_str(list_state.version or { 0 })
		submenu[#submenu + 1] = {
			title = string.format("📥 Mettre à jour Ergopti dans la liste — v%s → v%s", old_str, latest_str),
			fn    = function()
				-- Same crash-avoidance pattern as the add-variant items below
				defer_tis_call(function()
					local ok = upgrade_active_list(legacy_active)
					if ok and hs.alert then pcall(hs.alert.show, "Liste des dispositions mise à jour.") end
					if not ok and hs.alert then
						pcall(hs.alert.show, "Échec de la mise à jour — voir la console.", 3)
					end
					schedule_menu_refresh(update_menu)
				end)
			end,
		}
	elseif latest_installed_anywhere then
		-- 4. Absent and bundle present — submenu listing each variant. Clicking
		-- a variant calls TISEnableInputSource + TISSelectInputSource in an
		-- isolated osascript subprocess, so the user no longer has to detour
		-- through System Settings AND a TIS-side failure can no longer crash
		-- Hammerspoon. Variants already enabled in the user's input-source
		-- list are greyed out and prefixed with ✅.
		local active_id_set = {}
		for _, raw in ipairs(sources) do active_id_set[raw] = true end

		local add_sub = {}
		for _, var in ipairs(ERGOPTI_VARIANTS) do
			local id = var.id
			local already_added = active_id_set[id] == true
			if already_added then
				add_sub[#add_sub + 1] = {
					title    = string.format("✅ %s v%s — déjà ajouté", var.label, latest_str),
					disabled = true,
				}
			else
				add_sub[#add_sub + 1] = {
					title = string.format("%s v%s", var.label, latest_str),
					fn    = function()
						-- Bounce the TIS call out of the menu-click frame so macOS
						-- can dispatch the resulting input-source notifications
						-- without re-entering us mid-handler.
						defer_tis_call(function()
							local ok = enable_and_select_source(id)
							if ok and hs.alert then
								pcall(hs.alert.show, string.format("%s ajouté à la liste.", var.label))
							end
							if not ok and hs.alert then
								pcall(hs.alert.show, "Échec de l’ajout — voir la console.", 3)
							end
							schedule_menu_refresh(update_menu)
						end)
					end,
				}
			end
		end
		submenu[#submenu + 1] = {
			title = string.format("➕ Ajouter Ergopti v%s à la liste des dispositions", latest_str),
			menu  = add_sub,
		}
	else
		-- 5. Absent and bundle missing — greyed
		submenu[#submenu + 1] = {
			title    = "Installer Ergopti d’abord pour pouvoir l’ajouter à la liste",
			disabled = true,
		}
	end

	submenu[#submenu + 1] = { title = "-" }

	-- Logo variant toggle (persisted via hs.settings)
	local current_variant = (hs.settings and hs.settings.get(LOGO_VARIANT_KEY)) or LOGO_VARIANT_DEFAULT
	local function set_variant(v)
		if hs.settings and type(hs.settings.set) == "function" then
			pcall(hs.settings.set, LOGO_VARIANT_KEY, v)
		end
		Logger.debug(LOG, "Logo variant: %s.", tostring(v))
		-- Re-render the menubar icon and rebuild the submenu so the checkmarks
		-- reflect the new state. refresh_icon is provided directly by ui.menu.init
		-- via ctx, avoiding a require() round-trip that previously could re-enter
		-- a partially-initialized module
		if type(refresh_icon) == "function" then pcall(refresh_icon) end
		-- pcall guards a hard crash from any rebuild path
		if type(update_menu) == "function" then pcall(update_menu) end
	end
	submenu[#submenu + 1] = {
		title   = "🌟 Logo par défaut",
		checked = current_variant == "simple",
		fn      = function() set_variant("simple") end,
	}
	submenu[#submenu + 1] = {
		title   = "🎨 Logo distinct de l’icône de la disposition",
		checked = current_variant == "complex",
		fn      = function() set_variant("complex") end,
	}

	submenu[#submenu + 1] = { title = "-" }

	-- Active layouts list — one item per enabled input source, with a checkmark
	-- on the currently selected one. Clicking a row switches the active layout
	-- via hs.keycodes.setLayout. Display names are stripped of the verbose
	-- com.apple.{key,keyboard,input}* prefixes for readability.
	submenu[#submenu + 1] = { title = "Dispositions actives", disabled = true }
	if #sources == 0 then
		submenu[#submenu + 1] = {
			title = "Ouvrir Préférences Système → Clavier",
			fn    = function() pcall(hs.execute, "open '" .. KEYBOARD_PREFS_URL .. "'") end,
		}
	else
		local active = current_input_source_name()
		for _, raw_name in ipairs(sources) do
			local display = clean_layout_name(raw_name)
			-- The original raw name is captured by the closure so that
			-- hs.keycodes.setLayout still receives a value the API recognises
			submenu[#submenu + 1] = {
				title   = display,
				checked = (raw_name == active) or nil,
				fn      = function()
					-- Defer the TIS call out of the menu-click frame so the
					-- input-source change notification doesn't re-enter HS
					defer_tis_call(function()
						set_input_source(raw_name)
						schedule_menu_refresh(update_menu)
					end)
				end,
			}
		end
	end

	return {
		title = "🌐 Disposition clavier",
		menu  = submenu,
	}
end

-- Late-bound test hooks: the helpers below are defined after section 2, so we
-- expose them here to keep section 2 self-contained.
M._version_str             = version_str
M._clean_layout_name       = clean_layout_name
M._extract_ergopti_version = extract_ergopti_version
M._format_ergopti_display  = format_ergopti_display
M._is_legacy_ergopti_id    = is_legacy_ergopti_id
M._migrate_legacy_id       = migrate_legacy_id

return M
