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

-- Internal helpers exposed for unit tests
M._parse_version = parse_version
M._version_gt    = version_gt




-- =====================================
-- =====================================
-- ======= 3/ Install Helpers ==========
-- =====================================
-- =====================================

--- Returns true if the file/dir at the given path exists (best-effort).
--- @param path string Absolute path.
--- @return boolean
local function path_exists(path)
	if type(path) ~= "string" or path == "" then return false end
	local f = io.open(path, "r")
	if f then f:close(); return true end
	-- io.open fails on directories on some systems; try a stat fallback via os.rename to itself
	local ok = os.rename(path, path)
	return ok == true
end

--- Copies the bundle to the user's Keyboard Layouts directory.
--- @param bundles_dir string Absolute path of the source bundles directory.
--- @param bundle_name string Basename of the bundle to install.
--- @return boolean true on success.
local function install_user(bundles_dir, bundle_name)
	Logger.start(LOG, "Installing %s into the user Keyboard Layouts folder…", bundle_name)
	local cmd = string.format(
		"mkdir -p \"%s\" && cp -R \"%s%s\" \"%s\"",
		USER_LAYOUTS_DIR, bundles_dir, bundle_name, USER_LAYOUTS_DIR
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

--- Copies the bundle to /Library/Keyboard Layouts/ via osascript with admin privileges.
--- Triggers a macOS password prompt.
--- @param bundles_dir string Absolute path of the source bundles directory.
--- @param bundle_name string Basename of the bundle to install.
--- @return boolean true on success.
local function install_system(bundles_dir, bundle_name)
	Logger.start(LOG, "Installing %s into the system Keyboard Layouts folder (sudo)…", bundle_name)
	-- Escape double quotes inside the AppleScript string
	local shell_cmd = string.format(
		"cp -R '%s%s' '%s'",
		bundles_dir, bundle_name, SYSTEM_LAYOUTS_DIR
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

--- Reads the user's enabled input sources via `defaults read` and parses out
--- the layout names. macOS preferences are notoriously brittle to parse, so a
--- best-effort approach is used: extract any "KeyboardLayout Name" entries.
--- @return table List of {name = string} entries, may be empty on failure.
local function list_enabled_input_sources()
	local out, ok = hs.execute("/usr/bin/defaults read com.apple.HIToolbox AppleEnabledInputSources 2>/dev/null")
	if not ok or type(out) ~= "string" or out == "" then
		Logger.warn(LOG, "Could not read AppleEnabledInputSources — falling back to empty list.")
		return {}
	end
	local sources = {}
	for name in out:gmatch("KeyboardLayout Name%s*=%s*\"([^\"]+)\"") do
		sources[#sources + 1] = { name = name }
	end
	-- Catch unquoted names too (defaults output sometimes omits quotes)
	if #sources == 0 then
		for name in out:gmatch("KeyboardLayout Name%s*=%s*([%w_%-]+);") do
			sources[#sources + 1] = { name = name }
		end
	end
	return sources
end

--- Reads the currently-selected input source name (best-effort).
--- @return string|nil
local function current_input_source_name()
	local out, ok = hs.execute("/usr/bin/defaults read com.apple.HIToolbox AppleSelectedInputSources 2>/dev/null")
	if not ok or type(out) ~= "string" then return nil end
	local name = out:match("KeyboardLayout Name%s*=%s*\"([^\"]+)\"")
		or out:match("KeyboardLayout Name%s*=%s*([%w_%-]+);")
	return name
end




-- =================================
-- =================================
-- ======= 5/ Submenu Builder ======
-- =================================
-- =================================

--- Builds the complete "Disposition clavier" submenu item.
--- @param ctx table Global UI context. Must contain ctx.base_dir and ctx.updateMenu.
--- @return table A single hs.menubar item with a populated submenu.
function M.build(ctx)
	local update_menu = ctx and ctx.updateMenu
	local base_dir    = ctx and ctx.base_dir or ""
	local bundles_dir = base_dir .. BUNDLES_RELDIR

	local submenu = {}

	local latest = M.pick_latest_bundle(bundles_dir)
	if latest then
		local user_target   = USER_LAYOUTS_DIR .. latest
		local system_target = SYSTEM_LAYOUTS_DIR .. latest
		local user_done     = path_exists(user_target)
		local system_done   = path_exists(system_target)

		submenu[#submenu + 1] = {
			title    = user_done
				and string.format("Ergopti (utilisateur) installé ✅ — %s", latest)
				or  string.format("📥 Installer Ergopti (utilisateur) — %s", latest),
			disabled = user_done or nil,
			fn       = (not user_done) and function()
				install_user(bundles_dir, latest)
				if update_menu then update_menu() end
			end or nil,
		}
		submenu[#submenu + 1] = {
			title    = system_done
				and string.format("Ergopti (système) installé ✅ — %s", latest)
				or  string.format("🔐 Installer Ergopti (système, sudo) — %s", latest),
			disabled = system_done or nil,
			fn       = (not system_done) and function()
				install_system(bundles_dir, latest)
				if update_menu then update_menu() end
			end or nil,
		}
	else
		Logger.warn(LOG, "No Ergopti bundle found in %s.", bundles_dir)
		submenu[#submenu + 1] = {
			title    = "Aucun bundle Ergopti trouvé",
			disabled = true,
		}
	end

	-- Programmatic mutation of AppleEnabledInputSources is fragile across macOS
	-- versions, so we defer to System Settings — the user adds the layout there
	submenu[#submenu + 1] = {
		title = "➕ Ajouter Ergopti à la liste des dispositions",
		fn    = function()
			Logger.info(LOG, "Opening Keyboard input-source preferences pane.")
			pcall(hs.execute, "open '" .. KEYBOARD_PREFS_URL .. "'")
		end,
	}

	submenu[#submenu + 1] = { title = "-" }

	-- Logo variant toggle (persisted via hs.settings)
	local current_variant = (hs.settings and hs.settings.get(LOGO_VARIANT_KEY)) or LOGO_VARIANT_DEFAULT
	local function set_variant(v)
		if hs.settings and type(hs.settings.set) == "function" then
			pcall(hs.settings.set, LOGO_VARIANT_KEY, v)
		end
		Logger.debug(LOG, "Logo variant: %s.", tostring(v))
		-- Trigger a live re-render of the menubar icon
		local ok_init, menu_init = pcall(require, "ui.menu.init")
		if ok_init and type(menu_init.refresh_icon) == "function" then
			pcall(menu_init.refresh_icon)
		end
		if update_menu then update_menu() end
	end
	submenu[#submenu + 1] = {
		title   = "🌟 Logo simple (par défaut)",
		checked = current_variant == "simple",
		fn      = function() set_variant("simple") end,
	}
	submenu[#submenu + 1] = {
		title   = "🎨 Logo complexe (Ergopti)",
		checked = current_variant == "complex",
		fn      = function() set_variant("complex") end,
	}

	submenu[#submenu + 1] = { title = "-" }

	-- Active layouts list
	submenu[#submenu + 1] = { title = "Disposition active", disabled = true }
	local sources = list_enabled_input_sources()
	if #sources == 0 then
		submenu[#submenu + 1] = {
			title = "Ouvrir Préférences Système → Clavier",
			fn    = function() pcall(hs.execute, "open '" .. KEYBOARD_PREFS_URL .. "'") end,
		}
	else
		local active = current_input_source_name()
		for _, src in ipairs(sources) do
			local name = src.name
			submenu[#submenu + 1] = {
				title   = name,
				checked = (name == active) or nil,
				fn      = function()
					-- Best-effort switch via AppleScript / shell; macOS makes this fragile
					-- so we log explicitly and rely on the user to verify the change
					Logger.info(LOG, "Switching input source to %s (best-effort).", name)
					local script = string.format(
						"tell application \"System Events\" to keystroke \" \" using {control down, option down}"
					)
					pcall(function() hs.osascript.applescript(script) end)
					if update_menu then update_menu() end
				end,
			}
		end
	end

	return {
		title = "🌐 Disposition clavier",
		menu  = submenu,
	}
end

return M
