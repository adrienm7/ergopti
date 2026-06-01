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
---    in static/ergopti/macos/bundles/ wins, so no hardcoded version string.
--- 2. Idempotent install detection: items become disabled with an
---    "Ergopti (<scope>) installé ✅" label when the bundle already lives at
---    the target path, so the user can tell at a glance where it landed.
--- 3. Resilient input-source listing: parsing macOS preferences plist is fragile,
---    so failure paths fall back to opening the Keyboard preferences panel and
---    are logged explicitly — no silent failures.
--- ==============================================================================

local M = {}

local hs            = hs
local Logger        = require("lib.logger")
local dialog        = require("lib.dialog_util")
local notifications = require("lib.notifications")
local i18n          = require("lib.i18n")
local LOG           = "menu.keyboard_layout"




-- ===================================
--- ===================================
-- ======= 1/ Module Constants =======
--- ===================================
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
-- TIS IDs use the `com.apple.keyboardlayout.*` namespace (third-party convention).
-- The shorter `com.apple.keylayout.*` namespace is reserved by macOS for system
-- input sources; using it for a third-party bundle causes the OS to silently
-- refuse to register the bundle, so it never appears in the input-source list.
-- Note: Ergopti++ variants are intentionally absent here — they are not
-- included in the current bundle and must not be offered to the user.
local ERGOPTI_VARIANTS = {
	{ id = "com.apple.keyboardlayout.ergopti",           label = "Ergopti",      suffix = ""          },
	{ id = "com.apple.keyboardlayout.ergopti.ansi",      label = "Ergopti ANSI", suffix = "_ansi"     },
	{ id = "com.apple.keyboardlayout.ergopti.plus",      label = "Ergopti+",     suffix = "_plus"     },
	{ id = "com.apple.keyboardlayout.ergopti.plus.ansi", label = "Ergopti+ ANSI", suffix = "_plus_ansi" },
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
	for raw_line in p:lines() do
		local line = raw_line:gsub("[\r\n]+$", "")
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
	-- Shell fallback — handles SIP-protected paths that hs.fs.attributes can't stat.
	-- /bin/test -e accepts any filesystem object (file, dir, bundle symlink).
	local cmd = string.format("/bin/test -e %q && echo OK", path)
	local out = hs.execute and hs.execute(cmd) or nil
	if type(out) == "string" and out:find("OK") then return true end
	-- Pure-Lua fallback for unit-test runs where hs is unavailable.
	-- os.rename is intentionally omitted: on SIP-protected paths it returns true
	-- even when the file does not exist, which would make find_installed_bundles
	-- report a phantom installed bundle and show "Mettre à jour" instead of "Installer".
	local f = io.open(path, "r")
	if f then f:close(); return true end
	return false
end

--- Lists every Ergopti_v*.bundle currently installed in `dir`.
--- Returns the parsed version components for each so callers can compare to
--- the latest available version without having to re-parse strings.
---
--- Bundle entries are only counted when their internal Contents/Info.plist
--- exists — a stray empty .bundle directory left behind by a failed install
--- (or by macOS while moving files between locations) would otherwise be
--- picked up here, with the upstream menu builder then offering an
--- "in-place upgrade" against a non-existent install. The structural check
--- guarantees `installed` only points at bundles that the OS would itself
--- treat as a real keyboard layout.
--- @param dir string Absolute path of the Keyboard Layouts directory.
--- @return table Array of { name = string, version = table } entries.
local function find_installed_bundles(dir)
	local out = {}
	if type(dir) ~= "string" or dir == "" then return out end
	local cmd = string.format("ls -1 %q 2>/dev/null", dir)
	local p = io.popen(cmd)
	if not p then return out end
	local dir_with_slash = dir:match("[/\\]$") and dir or (dir .. "/")
	for raw_line in p:lines() do
		local line = raw_line:gsub("[\r\n]+$", "")
		if line:match("^Ergopti_v[%d%.]+%.bundle$") then
			local v = parse_version(line)
			local info_plist = dir_with_slash .. line .. "/Contents/Info.plist"
			local plist_ok = v and path_exists(info_plist)
			Logger.debug(LOG, "Bundle probe — dir=%s name=%s plist_exists=%s.", dir, line, tostring(plist_ok))
			if plist_ok then
				out[#out + 1] = { name = line, version = v }
			end
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
--- Removes any Ergopti_v*.bundle from BOTH the user and system directories
--- first, so a user install always becomes the single canonical copy.
--- @param bundles_dir string Absolute path of the source bundles directory.
--- @param bundle_name string Basename of the bundle to install.
--- @return boolean true on success.
local function install_user(bundles_dir, bundle_name)
	Logger.start(LOG, "Installing %s into the user Keyboard Layouts folder…", bundle_name)
	-- Remove the system-scope copy first (requires no privilege since we only
	-- touch the user's own Library here — system removal is skipped silently
	-- when it fails due to permission; the user will see an outdated entry in
	-- the system folder but it won't conflict because macOS prefers the user
	-- scope when both exist for the same bundle identifier).
	hs.execute(string.format('rm -rf %q/Ergopti_v*.bundle', SYSTEM_LAYOUTS_DIR:gsub("/$", "")))
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
		pcall(notifications.notify, i18n.get("menu.layout.installed_user"), nil, "success")
		return true
	end
	Logger.error(LOG, "User install failed: %s.", tostring(out))
	return false
end

--- Copies the latest bundle to /Library/Keyboard Layouts/ via osascript with
--- administrator privileges. Triggers a macOS password prompt. Removes any
--- Ergopti_v*.bundle from BOTH the user and system directories first, so the
--- system copy becomes the single canonical installation.
--- @param bundles_dir string Absolute path of the source bundles directory.
--- @param bundle_name string Basename of the bundle to install.
--- @return boolean true on success.
local function install_system(bundles_dir, bundle_name)
	Logger.start(LOG, "Installing %s into the system Keyboard Layouts folder (sudo)…", bundle_name)
	-- Remove both the user copy (no privilege needed) and the old system copy
	-- (done inside the privileged shell so both are cleaned atomically).
	hs.execute(string.format('rm -rf %q/Ergopti_v*.bundle', USER_LAYOUTS_DIR:gsub("/$", "")))
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
		pcall(notifications.notify, i18n.get("menu.layout.installed_system"), nil, "success")
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

--- Enumerates every enabled keyboard-layout input source via Carbon TIS
--- in an isolated osascript subprocess. Returns a list of records:
---
---     { id = "com.apple.keylayout.ergopti.plus",
---       name = "Ergopti+",
---       selected = false }
---
--- The result is filtered to ``kTISTypeKeyboardLayout`` so non-keyboard
--- entries that always sit in ``AppleEnabledInputSources`` (PressAndHold,
--- CharacterPalette, IMEs) are dropped at the source rather than after the
--- fact. Exactly one record carries ``selected = true`` — the layout
--- macOS would route a keystroke to right now — which is what the menu
--- uses to render the checkmark on the active row.
---
--- A defensive Lua-side filter also drops ids that look like input methods
--- or services in case the TIS type predicate is partially honoured by
--- older macOS versions.
---
--- Returns an empty list when osascript or TIS fails (logged), so callers
--- can fall back to a "no layout" placeholder without having to handle
--- nil. Pure-Lua test runs (no ``hs.execute``) hit this branch silently.
--- @return table List of input-source records (possibly empty).
--- Reads AppleEnabledInputSources from HIToolbox via a Python plist parser and
--- returns a list of records {id, name, selected} for every enabled keyboard
--- layout. Using Python avoids the regex-on-XML fragility that caused duplicate
--- entries when the same KeyboardLayout Name appeared in multiple plist sections.
--- HIToolbox is the macOS source of truth — changes in System Settings are
--- reflected immediately, without the TIS cache lag from osascript/hs.keycodes.
local function list_active_keyboard_layouts()
	-- Read via `defaults export` (cfprefsd) — reflects deletions made in System
	-- Settings immediately. Reading the plist file directly returned stale entries
	-- for layouts the user had already removed.
	local py = [[
import subprocess, sys, plistlib, json

DOMAIN = "com.apple.HIToolbox"
KEY    = "AppleEnabledInputSources"

# Read via cfprefsd (defaults export) — reflects System Settings changes
# immediately, unlike reading the plist file directly which can be stale.
try:
    raw = subprocess.check_output(
        ["defaults", "export", DOMAIN, "-"], stderr=subprocess.DEVNULL)
    prefs = plistlib.loads(raw)
except Exception as e:
    print("ERR:" + str(e)); sys.exit(1)

sources = prefs.get(KEY, [])
out = []
for s in sources:
    kind = s.get("InputSourceKind", "")
    name = s.get("KeyboardLayout Name", "")
    if name and (kind == "Keyboard Layout" or kind == ""):
        out.append(name)
print(json.dumps(out))
]]
	local tmp = os.tmpname() .. ".py"
	local fh = io.open(tmp, "w")
	if not fh then
		Logger.warn(LOG, "list_active_keyboard_layouts: cannot write temp script.")
		return {}
	end
	fh:write(py); fh:close()
	local raw_out, ok = hs.execute("/usr/bin/python3 " .. tmp .. " 2>&1")
	os.remove(tmp)
	Logger.debug(LOG, "HIToolbox defaults export raw: ok=%s out=%s.", tostring(ok), tostring(raw_out):gsub("[\r\n]", " "))

	local current_name = (hs.keycodes and type(hs.keycodes.currentLayout) == "function")
		and hs.keycodes.currentLayout() or nil

	local out = {}
	if ok and type(raw_out) == "string" and raw_out:sub(1, 1) == "[" then
		-- Decode the JSON array of KeyboardLayout Name strings
		for kl_name in raw_out:gmatch('"([^"]+)"') do
			local display = kl_name:gsub("_", " "):gsub("%s+v%d.*$", "")
			local selected = (current_name ~= nil and (
				kl_name == current_name or display == current_name
			)) or false
			out[#out + 1] = { id = kl_name, name = display, selected = selected }
		end
	else
		Logger.warn(LOG, "HIToolbox Python parse failed (%s) — falling back to hs.keycodes.", tostring(raw_out))
		if hs.keycodes and type(hs.keycodes.layouts) == "function" then
			local layouts = hs.keycodes.layouts() or {}
			local current = (type(hs.keycodes.currentLayout) == "function") and hs.keycodes.currentLayout() or nil
			for _, name in ipairs(layouts) do
				out[#out + 1] = { id = name, name = name, selected = (current ~= nil and name == current) or false }
			end
		end
	end

	Logger.debug(LOG, "Active layouts from HIToolbox: %d.", #out)
	return out
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

--- Returns a set of TIS IDs for Ergopti variants currently present in
--- AppleEnabledInputSources, read directly from HIToolbox via `defaults export`.
--- Maps KeyboardLayout Name (internal name) back to TIS IDs via ERGOPTI_VARIANTS.
--- This bypasses the TIS osascript path that fails on macOS Sequoia.
--- @return table Set of TIS IDs, e.g. { ["com.apple.keyboardlayout.ergopti.plus"] = true }.
--- Builds a mapping from KeyboardLayout Name (internal HIToolbox name) to stable TIS ID
--- for every variant in the currently installed bundle. Returns nil if no bundle is installed.
--- Example: { ["Ergopti_v2_2_2_plus"] = "com.apple.keyboardlayout.ergopti.plus", ... }
--- @return table|nil
local function build_kl_name_to_tis_id()
	local sb_sys  = highest_installed(SYSTEM_LAYOUTS_DIR)
	local sb_user = highest_installed(USER_LAYOUTS_DIR)
	local sb      = sb_sys or sb_user
	local sb_dir  = sb_sys and SYSTEM_LAYOUTS_DIR or (sb_user and USER_LAYOUTS_DIR) or nil
	if not sb or not sb_dir then return nil end
	local installed_bundle = sb.name:gsub("%.bundle$", ""):gsub("%.", "_")
	local bundle_path = sb_dir:gsub("[/\\]$", "") .. "/" .. sb.name
	local map = {}
	for _, var in ipairs(ERGOPTI_VARIANTS) do
		local internal   = installed_bundle .. (var.suffix or "")
		local keylayout  = bundle_path .. "/Contents/Resources/" .. internal .. ".keylayout"
		if path_exists(keylayout) then
			map[internal] = var.id
		end
	end
	return map
end


--- Adds the given TIS input source to the user's enabled-list via
--- `defaults write com.apple.HIToolbox`, then restarts SystemUIServer so
--- the change takes effect immediately.
---
--- The Carbon TIS ObjC-bridge approach (TISCreateInputSourceList +
--- TISEnableInputSource called from osascript) was tried extensively but
--- crashes silently on macOS Sequoia: NSMutableDictionary bridged to
--- CFDictionaryRef causes osascript to exit without writing any output,
--- leaving the Lua caller with status=<no-output>. The `defaults write`
--- approach is what Karabiner-Elements and other third-party tools use and
--- is known to work reliably on macOS 12–15.
---
--- The AppleEnabledInputSources preference is an array of dicts. We read
--- the current list, check whether the target ID is already present, append
--- it if not, and write back.  The whole operation is a single Python 3
--- one-liner that ships with macOS and needs no extra dependencies.
--- @param raw_id string TISInputSourceID, e.g. "com.apple.keyboardlayout.ergopti.plus".
--- @param label string Human-readable label used in log messages.
--- @return boolean true on success.
local function enable_and_select_source(raw_id, label, bundle_path, internal_name)
	if type(raw_id) ~= "string" or raw_id == "" then return false end
	if type(bundle_path) ~= "string" or bundle_path == "" then
		Logger.error(LOG, "enable_and_select_source: bundle_path missing for '%s'.", raw_id)
		return false
	end
	if type(internal_name) ~= "string" or internal_name == "" then
		Logger.error(LOG, "enable_and_select_source: internal_name missing for '%s'.", raw_id)
		return false
	end
	local display = (type(label) == "string" and label ~= "") and label or raw_id

	-- bundle_path: absolute path to the installed .bundle directory
	-- internal_name: the keylayout filename base (e.g. "Ergopti_v2_2_2_plus")
	-- The correct HIToolbox entry format matches macOS built-in layouts (e.g. French):
	--   InputSourceKind  → "Keyboard Layout"
	--   KeyboardLayout ID   → integer id= from the .keylayout XML (no Bundle ID needed)
	--   KeyboardLayout Name → name= from the .keylayout XML (= internal_name)
	-- Adding a Bundle ID or using a string for KeyboardLayout ID causes macOS to silently
	-- ignore the entry at next login / SystemUIServer restart.
	local py_script = string.format([[
import subprocess, sys, plistlib, re, os

DOMAIN        = "com.apple.HIToolbox"
KEY           = "AppleEnabledInputSources"
BUNDLE_PATH   = "%s"
INTERNAL_NAME = "%s"

# Extract KeyboardLayout ID (integer) from the .keylayout XML
keylayout_file = os.path.join(BUNDLE_PATH, "Contents", "Resources", INTERNAL_NAME + ".keylayout")
try:
    with open(keylayout_file, "r", encoding="utf-8") as f:
        content = f.read(4096)
    m = re.search(r'<keyboard\b[^>]*\bid=["\']?(-?\d+)["\']?', content)
    if not m:
        print("PARSE_ERR:no id= in " + keylayout_file); sys.exit(1)
    kl_id = int(m.group(1))
except Exception as e:
    print("PARSE_ERR:" + str(e)); sys.exit(1)

try:
    raw = subprocess.check_output(
        ["defaults", "export", DOMAIN, "-"], stderr=subprocess.DEVNULL)
    prefs = plistlib.loads(raw)
except Exception as e:
    print("READ_ERR:" + str(e)); sys.exit(1)

sources = prefs.get(KEY, [])

# Remove only entries that are stale for THIS variant:
#   - any Ergopti entry that still has a Bundle ID (wrong legacy format), OR
#   - the exact same KeyboardLayout Name we are about to add (dedup).
# Other Ergopti variants that are already clean are left untouched.
def is_stale_entry(s):
    bid  = s.get("Bundle ID", "")
    name = s.get("KeyboardLayout Name", "")
    if "ergopti" in bid.lower(): return True
    if name == INTERNAL_NAME: return True
    return False

sources = [s for s in sources if not is_stale_entry(s)]

# Format mirrors macOS built-in keyboard layout entries (e.g. French):
# no Bundle ID, KeyboardLayout ID is a native integer in the plist.
sources.append({
    "InputSourceKind":     "Keyboard Layout",
    "KeyboardLayout ID":   kl_id,
    "KeyboardLayout Name": INTERNAL_NAME,
})
prefs[KEY] = sources

plist_bytes = plistlib.dumps(prefs, fmt=plistlib.FMT_XML)
import tempfile
with tempfile.NamedTemporaryFile(suffix=".plist", delete=False) as f:
    f.write(plist_bytes)
    tmp = f.name

try:
    subprocess.check_call(
        ["defaults", "import", DOMAIN, tmp],
        stderr=subprocess.DEVNULL)
finally:
    os.unlink(tmp)

# Reload the input-source list. launchctl kickstart is safer than killall
# on Sequoia: it re-spawns the agent cleanly without flushing the cfprefsd cache.
uid = str(os.getuid())
subprocess.call(
    ["launchctl", "kickstart", "-k", "user/" + uid + "/com.apple.SystemUIServer"],
    stderr=subprocess.DEVNULL)
print("OK")
]], bundle_path, internal_name)

	-- Write the Python script to a temp file and run it with the system Python 3.
	local tmp_py = os.tmpname() .. ".py"
	local fh = io.open(tmp_py, "w")
	if not fh then
		Logger.error(LOG, "enable_and_select_source: could not write temp script.")
		return false
	end
	fh:write(py_script)
	fh:close()

	local out, ok = hs.execute("/usr/bin/python3 " .. tmp_py .. " 2>&1")
	os.remove(tmp_py)

	local out_text = tostring(out or ""):gsub("[\r\n]+$", "")
	if ok and (out_text == "OK" or out_text == "ALREADY_PRESENT") then
		Logger.success(LOG, "Input source '%s' (%s) added to enabled list (%s).",
			display, raw_id, out_text)
		return true
	end
	Logger.warn(LOG, "Failed to add '%s' (%s) — status=%s.",
		display, raw_id, (out_text ~= "") and out_text or "<no-output>")
	return false
end

--- Returns true if the given layout name looks like a legacy versioned Ergopti
--- identifier (pre-v2.2.2 form: 'com.apple.keyboardlayout.ergopti.v2_2_1.plus'),
--- OR the short-namespace form mistakenly used between v2.2.2 and the
--- com.apple.keylayout.* fix ('com.apple.keylayout.ergopti.*' — never registered
--- by macOS, but may be in users' active-list from a previous install attempt).
--- Both forms must be replaced by their stable third-party counterparts.
--- @param name string
--- @return boolean
local function is_legacy_ergopti_id(name)
	if type(name) ~= "string" then return false end
	local lower = name:lower()
	-- Versioned IDs (any namespace)
	if lower:find("ergopti[._]v%d", 1) ~= nil then return true end
	-- Short reserved namespace, only for Ergopti
	if lower:find("^com%.apple%.keylayout%.ergopti", 1) ~= nil then return true end
	return false
end

--- Maps a legacy Ergopti identifier to its v2.2.2+ stable equivalent.
--- com.apple.keyboardlayout.ergopti.v2_2_0[.suffix] → com.apple.keyboardlayout.ergopti[.suffix]
--- com.apple.keylayout.ergopti[.suffix]            → com.apple.keyboardlayout.ergopti[.suffix]
--- @param old string
--- @return string
local function migrate_legacy_id(old)
	if type(old) ~= "string" then return old end
	-- Lift the short reserved namespace to the third-party one.
	local m = old:gsub("^com%.apple%.keylayout%.", "com.apple.keyboardlayout.")
	-- Strip the version segment .vX_Y_Z (or .vX.Y.Z) wherever it appears.
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
--- @param legacy_active table TIS ids from list_active_keyboard_layouts() that look legacy.
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
	-- Variant detection — order matters: ++ before +, and symbol forms before word forms.
	-- "plus_plus" / "plus.plus" cover bundle IDs; "++" / "+" cover localised names
	-- returned by hs.keycodes (e.g. "Ergopti+" when TIS osascript is unavailable).
	local variant
	if lower:find("plus_plus") or lower:find("plus%.plus") or id:find("%+%+") then
		variant = "++"
	elseif lower:find("plus") or id:find("%+") then
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

--- Returns the highest Ergopti version installed across the user and system
--- keyboard-layout directories, or nil when none is present.
--- @return table|nil Numeric version components, e.g. {2,2,1}.
local function resolve_installed_ergopti_version()
	local user_best   = highest_installed(USER_LAYOUTS_DIR)
	local system_best = highest_installed(SYSTEM_LAYOUTS_DIR)
	if user_best and system_best then
		return version_gt(user_best.version, system_best.version)
			and user_best.version or system_best.version
	end
	return (user_best and user_best.version) or (system_best and system_best.version) or nil
end

--- Inspects the active input-source list and reports whether an Ergopti
--- layout is present along with the version the user is running.
---
--- v2.2.2+ bundles publish a stable TIS id (``com.apple.keylayout.ergopti.plus``)
--- with no version segment, so :func:`extract_ergopti_version` returns
--- ``{0,0,0}`` for those entries — the version lives only in the bundle
--- filename. We fall back to the highest version found on disk so the menu
--- never has to display ``v0.0.0`` for an entry that the user is happily
--- running.
--- @param records table List of records from :func:`list_active_keyboard_layouts`.
--- @return table { present = boolean, name = string|nil, id = string|nil, version = table|nil }
local function ergopti_in_active_layouts(records)
	for _, r in ipairs(records) do
		local id = (r and r.id) or ""
		if type(id) == "string" and id:lower():find("ergopti", 1, true) then
			local v = extract_ergopti_version(id)
			-- Stable-id entries (no version embedded): substitute the version
			-- of whatever bundle is installed locally.
			if v and v[1] == 0 and v[2] == 0 and v[3] == 0 then
				v = resolve_installed_ergopti_version() or v
			end
			return { present = true, name = r.name, id = id, version = v }
		end
	end
	return { present = false }
end





-- =================================
--- ==================================
--- ======= 5/ Submenu Builder =======
--- ==================================
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
			title    = string.format(i18n.get("menu.layout.installed_version"), scope_label, latest_str),
			disabled = true,
		}
	end
	if installed then
		-- An older version is on disk; offer an in-place upgrade
		local old_str = version_str(installed.version)
		return {
			title = string.format(i18n.get("menu.layout.update_version"), scope_label, old_str, latest_str),
			fn    = do_install,
		}
	end
	return {
		title = string.format(i18n.get("menu.layout.install_version"), emoji_install, scope_label, latest_str),
		fn    = do_install,
	}
end

function M.build(ctx)
	local update_menu  = ctx and ctx.updateMenu
	local refresh_icon = ctx and ctx.refresh_icon
	local base_dir     = ctx and ctx.base_dir or ""
	local bundles_dir  = base_dir .. BUNDLES_RELDIR

	local submenu = {}

	-- Pull the live state once so the closures below capture stable values.
	-- list_active_keyboard_layouts() returns rich records {id, name, selected}
	-- filtered to actual keyboard layouts, so the menu never displays
	-- internal services (PressAndHold, CharacterPalette, …).
	local records    = list_active_keyboard_layouts()
	-- Build the active-Ergopti set directly from records — the same source used
	-- to display the i18n.get("menu.layout.active_layouts") list below. If an entry appears there
	-- it is truly active; no need to read HIToolbox separately.
	--
	-- records[i].id is the KeyboardLayout Name from HIToolbox (e.g. "Ergopti_v2_2_2_plus"),
	-- NOT a TIS ID. We map it to a stable TIS ID via the installed bundle's keylayout files.
	-- Records whose KeyboardLayout Name doesn't match any installed variant are orphan entries
	-- (old bundle, different version) — we flag them so the menu can offer an upgrade.
	local kl_name_to_tis = build_kl_name_to_tis_id() or {}
	local active_id_set_pre = {}
	local legacy_active     = {}
	for _, r in ipairs(records) do
		local kl_name = r.id or ""
		if kl_name:lower():find("ergopti", 1, true) then
			local stable_id = kl_name_to_tis[kl_name]
			if stable_id then
				-- Matches an installed variant → genuinely active
				active_id_set_pre[stable_id] = true
			else
				-- No match in the installed bundle → orphan/legacy entry
				legacy_active[#legacy_active + 1] = kl_name
			end
		end
	end
	local list_state = ergopti_in_active_layouts(records)

	local latest = M.pick_latest_bundle(bundles_dir)
	-- The list-upgrade only makes sense once the latest bundle is on disk —
	-- TIS can't enable an input source whose .bundle isn't installed.
	-- user_best and system_best are declared here so they remain in scope for the
	-- "Ajouter" submenu closures below (which live outside the `if latest then` block).
	local user_best   = highest_installed(USER_LAYOUTS_DIR)
	local system_best = highest_installed(SYSTEM_LAYOUTS_DIR)
	local latest_installed_anywhere = false
	if latest then
		local latest_ver  = parse_version(latest)
		latest_installed_anywhere =
			(user_best   and not version_gt(latest_ver, user_best.version))
			or (system_best and not version_gt(latest_ver, system_best.version))
			or false
		Logger.debug(LOG, "Install probe — latest=%s, user_best=%s, system_best=%s, latest_installed=%s.",
			latest, user_best and user_best.name or "none",
			system_best and system_best.name or "none",
			tostring(latest_installed_anywhere))

		-- System scope is listed first: it is the preferred install target
		-- because it makes the layout available for all users and avoids
		-- duplication between ~/Library and /Library. A system install also
		-- removes the user copy automatically, keeping a single canonical bundle.
		submenu[#submenu + 1] = build_install_item(
			i18n.get("menu.layout.scope_system"), "🔐", system_best, latest, latest_ver,
			function()
				run_install_and_chain(
					function() return install_system(bundles_dir, latest) end,
					legacy_active, update_menu
				)
			end
		)
		submenu[#submenu + 1] = build_install_item(
			i18n.get("menu.layout.scope_user"), "📥", user_best, latest, latest_ver,
			function()
				run_install_and_chain(
					function() return install_user(bundles_dir, latest) end,
					legacy_active, update_menu
				)
			end
		)
	else
		Logger.warn(LOG, "No Ergopti bundle found in %s.", bundles_dir)
		submenu[#submenu + 1] = {
			title    = i18n.get("menu.layout.no_bundle"),
			disabled = true,
		}
	end

	-- Add / upgrade Ergopti in the macOS input-source list.
	--
	-- Five possible states:
	--   1. ALL variants active in list     → greyed-out success label
	--   2. older active, latest installed  → in-place TIS swap (programmatic)
	--   3. older active, latest NOT installed → greyed: install latest first
	--   4. some/no variants present, latest installed → submenu (added ones greyed)
	--   5. absent, latest NOT installed    → greyed: install latest first
	local latest_ver = latest and parse_version(latest) or nil
	local latest_str = latest_ver and version_str(latest_ver) or "?"
	local all_variants_active = true
	for _, var in ipairs(ERGOPTI_VARIANTS) do
		if not active_id_set_pre[var.id] then all_variants_active = false; break end
	end
	-- Installed bundle version: system preferred, then user. Used for the label in state 1.
	-- We derive this from the filesystem, not from TIS, which is unreliable on Sequoia.
	local installed_ver = (system_best and system_best.version) or (user_best and user_best.version)
	if all_variants_active and installed_ver then
		-- 1. All variants already in list and up to date
		submenu[#submenu + 1] = {
			title    = string.format(i18n.get("menu.layout.in_list"), version_str(installed_ver)),
			disabled = true,
		}
	elseif #legacy_active > 0 and latest ~= nil and not latest_installed_anywhere then
		-- 3. Legacy entry active but latest bundle missing — block the upgrade
		-- Extract version from the first legacy KeyboardLayout Name (e.g. "Ergopti_v2_1_0" → "2.1.0")
		local _m = (legacy_active[1] or ""):match("_v(%d+_%d+_%d+)")
		local old_str = _m and _m:gsub("_", ".") or "?"
		submenu[#submenu + 1] = {
			title    = string.format(i18n.get("menu.layout.update_list_install_first"),
				latest_str, old_str),
			disabled = true,
		}
	elseif #legacy_active > 0 then
		-- 2. Legacy entry active and latest installed — programmatic swap via TIS
		local _m = (legacy_active[1] or ""):match("_v(%d+_%d+_%d+)")
		local old_str = _m and _m:gsub("_", ".") or "?"
		submenu[#submenu + 1] = {
			title = string.format(i18n.get("menu.layout.update_list"), old_str, latest_str),
			fn    = function()
				defer_tis_call(function()
					local ok = upgrade_active_list(legacy_active)
					if ok then pcall(notifications.notify, i18n.get("menu.layout.update_list_ok"), nil, "success") end
					if not ok then pcall(notifications.notify, i18n.get("menu.layout.update_list_fail"), nil, "error") end
					schedule_menu_refresh(update_menu)
				end)
			end,
		}
	elseif latest_installed_anywhere then
		-- 4. Some or no variants present, bundle installed — submenu listing each
		-- variant. Already-added variants are greyed individually with ✅.
		local active_id_set = active_id_set_pre

		-- Resolve the installed bundle path (system preferred over user).
		-- The keylayout internal name base is the bundle basename without ".bundle",
		-- with dots replaced by underscores (e.g. "Ergopti_v2.2.2.bundle" → "Ergopti_v2_2_2").
		local installed_dir, installed_name
		if system_best then
			installed_dir  = SYSTEM_LAYOUTS_DIR
			installed_name = system_best.name
		elseif user_best then
			installed_dir  = USER_LAYOUTS_DIR
			installed_name = user_best.name
		end
		local bundle_base = installed_name and installed_name:gsub("%.bundle$", ""):gsub("%.", "_") or ""
		local bundle_full_path = (installed_dir and installed_name) and
			(installed_dir:gsub("[/\\]$", "") .. "/" .. installed_name) or ""

		local add_sub = {}
		for _, var in ipairs(ERGOPTI_VARIANTS) do
			local id            = var.id
			local suffix        = var.suffix or ""
			local internal_name = bundle_base .. suffix
			local already_added = active_id_set[id] == true
			if already_added then
				add_sub[#add_sub + 1] = {
					title    = string.format(i18n.get("menu.layout.already_added"), var.label, latest_str),
					disabled = true,
				}
			else
				add_sub[#add_sub + 1] = {
					title = string.format("%s v%s", var.label, latest_str),
					fn    = function()
						defer_tis_call(function()
							local ok = enable_and_select_source(id, var.label, bundle_full_path, internal_name)
							if ok then pcall(notifications.notify, string.format(i18n.get("menu.layout.add_ok"), var.label), nil, "success") end
							if not ok then pcall(notifications.notify, i18n.get("menu.layout.add_fail"), nil, "error") end
							schedule_menu_refresh(update_menu)
						end)
					end,
				}
			end
		end
		submenu[#submenu + 1] = {
			title = string.format(i18n.get("menu.layout.add_to_list"), latest_str),
			menu  = add_sub,
		}
	else
		-- 5. Absent and bundle missing — greyed
		submenu[#submenu + 1] = {
			title    = i18n.get("menu.layout.install_first"),
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
		title   = i18n.get("menu.layout.logo_default"),
		checked = current_variant == "simple",
		fn      = function() set_variant("simple") end,
	}
	submenu[#submenu + 1] = {
		title   = i18n.get("menu.layout.logo_custom"),
		checked = current_variant == "complex",
		fn      = function() set_variant("complex") end,
	}

	submenu[#submenu + 1] = { title = "-" }

	-- Active layouts list — one item per enabled keyboard layout, with a
	-- checkmark on the currently selected one. Clicking a row switches the
	-- active layout via TISSelectInputSource (the TIS bundle id is captured
	-- in each closure so we never have to round-trip through localised
	-- names, which can collide across languages). Ergopti entries get the
	-- bundle's actual installed version appended to their localised name
	-- so a stable-id row no longer shows up as a bare "Ergopti+".
	local resolved_ergopti_v = resolve_installed_ergopti_version()
	local function display_for_record(r)
		local id = r.id or ""
		if id:lower():find("ergopti", 1, true) then
			local pretty = format_ergopti_display(id)
			if pretty and not pretty:find("v%d") and resolved_ergopti_v then
				pretty = pretty .. " v" .. version_str(resolved_ergopti_v)
			end
			if pretty then return pretty end
		end
		-- Non-Ergopti rows: prefer the localised name macOS published; fall
		-- back to a prefix-stripped id when it isn't available.
		if type(r.name) == "string" and r.name ~= "" and r.name ~= id then
			return r.name
		end
		return clean_layout_name(id)
	end

	submenu[#submenu + 1] = { title = i18n.section("menu.layout.active_layouts"), disabled = true }
	if #records == 0 then
		submenu[#submenu + 1] = {
			title = i18n.get("menu.layout.open_prefs"),
			fn    = function() pcall(hs.execute, "open '" .. KEYBOARD_PREFS_URL .. "'") end,
		}
	else
		for _, r in ipairs(records) do
			local title    = display_for_record(r)
			-- Pass the display name to set_input_source: hs.keycodes.setLayout expects
			-- the localised name (e.g. "French"), not the internal KeyboardLayout Name.
			local target_id = r.name
			submenu[#submenu + 1] = {
				title   = title,
				checked = r.selected or nil,
				-- Greyed out when already selected — clicking the checked
				-- row would be a no-op TIS call and confuse macOS' input
				-- source watchers when the menu refreshes mid-frame.
				disabled = r.selected or nil,
				fn       = function()
					-- Defer the TIS call out of the menu-click frame so the
					-- input-source change notification doesn't re-enter HS.
					defer_tis_call(function()
						set_input_source(target_id)
						schedule_menu_refresh(update_menu)
					end)
				end,
			}
		end
	end

	-- Magic key config items — specific to the Ergopti layout (★ is a dedicated Ergopti key)
	local hs_state  = ctx and ctx.state
	local hs_paused = ctx and ctx.paused
	submenu[#submenu + 1] = { title = "-" }
	submenu[#submenu + 1] = {
		title    = i18n.get("menu.hotstrings.magic_key_item_prefix") .. (hs_state and hs_state.trigger_char or "★"),
		disabled = hs_paused or nil,
		fn       = not hs_paused and function()
			if not hs_state then return end
			local ok_p, btn, raw = pcall(dialog.text_prompt,
				i18n.get("menu.hotstrings.magic_key_title"),
				i18n.get("menu.hotstrings.magic_key_prompt"),
				hs_state.trigger_char, "OK", i18n.get("common.cancel")
			)
			if ok_p and btn == "OK" and type(raw) == "string" and raw ~= "" then
				local new_char = raw:match("^([%z\1-\127\194-\244][\128-\191]*)") or raw:sub(1,1)
				if new_char and new_char ~= hs_state.trigger_char then
					hs_state.trigger_char = new_char
					if ctx.keymap and type(ctx.keymap.set_trigger_char) == "function" then
						pcall(ctx.keymap.set_trigger_char, new_char)
					end
					if ctx.hotstring_editor and type(ctx.hotstring_editor.set_trigger_char) == "function" then
						pcall(ctx.hotstring_editor.set_trigger_char, new_char)
					end
					ctx.save_prefs()
					ctx.do_reload("menu")
				end
			end
		end or nil,
	}
	local repeat_enabled = ctx and ctx.keymap
		and type(ctx.keymap.is_repeat_feature_enabled) == "function"
		and ctx.keymap.is_repeat_feature_enabled()
	submenu[#submenu + 1] = {
		title    = i18n.get("menu.hotstrings.repeat_key_toggle"),
		checked  = repeat_enabled,
		disabled = hs_paused or nil,
		fn       = not hs_paused and function()
			if ctx and ctx.keymap and type(ctx.keymap.set_repeat_feature_enabled) == "function" then
				pcall(ctx.keymap.set_repeat_feature_enabled, not repeat_enabled)
			end
			ctx.do_reload("menu")
		end or nil,
	}

	return {
		title = i18n.get("menu.layout.title"),
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
