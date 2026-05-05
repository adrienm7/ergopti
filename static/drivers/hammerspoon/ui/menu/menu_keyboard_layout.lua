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

--- Lists the keyboard layouts currently enabled in macOS, using the proper
--- Hammerspoon API. `hs.keycodes.layouts(true)` returns only the user-selected
--- (sourceable) layouts, mirroring exactly what the macOS menubar input-source
--- icon shows. Falls back to an empty list when the API is unavailable.
--- @return table Sorted list of layout names.
local function list_enabled_input_sources()
	if not (hs.keycodes and type(hs.keycodes.layouts) == "function") then
		Logger.warn(LOG, "hs.keycodes.layouts unavailable — returning empty list.")
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

--- Activates the given keyboard layout via the proper Hammerspoon API.
--- @param name string Layout name as returned by hs.keycodes.layouts.
--- @return boolean true on success.
local function set_input_source(name)
	if not (hs.keycodes and type(hs.keycodes.setLayout) == "function") then return false end
	local ok = pcall(hs.keycodes.setLayout, name)
	if ok then
		Logger.info(LOG, "Active layout switched to '%s'.", name)
	else
		Logger.warn(LOG, "Failed to switch active layout to '%s'.", name)
	end
	return ok
end

--- Strips the Apple keylayout / keyboardlayout / inputmethod prefixes from a
--- raw input-source identifier so the menu shows readable names like "French"
--- or "ergopti.v2_2_0" instead of the verbose com.apple.* form.
--- @param name string Raw layout name as returned by hs.keycodes.layouts.
--- @return string Cleaned name suitable for display.
local function clean_layout_name(name)
	if type(name) ~= "string" then return tostring(name) end
	return (name
		:gsub("^com%.apple%.keylayout%.", "")
		:gsub("^com%.apple%.keyboardlayout%.", "")
		:gsub("^com%.apple%.inputmethod%.", "")
		:gsub("^com%.apple%.inputsource%.", ""))
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

	local latest = M.pick_latest_bundle(bundles_dir)
	if latest then
		local latest_ver  = parse_version(latest)
		local user_best   = highest_installed(USER_LAYOUTS_DIR)
		local system_best = highest_installed(SYSTEM_LAYOUTS_DIR)
		Logger.debug(LOG, "Install probe — latest=%s, user_best=%s, system_best=%s.",
			latest, user_best and user_best.name or "none", system_best and system_best.name or "none")

		submenu[#submenu + 1] = build_install_item(
			"utilisateur", "📥", user_best, latest, latest_ver,
			function()
				install_user(bundles_dir, latest)
				if update_menu then update_menu() end
			end
		)
		submenu[#submenu + 1] = build_install_item(
			"système", "🔐", system_best, latest, latest_ver,
			function()
				install_system(bundles_dir, latest)
				if update_menu then update_menu() end
			end
		)
	else
		Logger.warn(LOG, "No Ergopti bundle found in %s.", bundles_dir)
		submenu[#submenu + 1] = {
			title    = "Aucun bundle Ergopti trouvé",
			disabled = true,
		}
	end

	-- Add / upgrade Ergopti in the macOS input-source list. macOS does not
	-- expose a clean programmatic API for this, so we open the Keyboard panel
	-- and let the user finish the action manually. The label adapts to:
	--   - absent      → "➕ Ajouter Ergopti à la liste"
	--   - older active → "📥 Mettre à jour Ergopti dans la liste (vOLD → vLATEST)"
	--   - latest active → greyed-out success label
	local latest_ver = latest and parse_version(latest) or nil
	local list_label, list_disabled, list_fn
	if list_state.present and latest_ver and list_state.version
		and not version_gt(latest_ver, list_state.version) then
		list_label    = string.format("Ergopti v%s dans la liste des dispositions ✅", version_str(list_state.version))
		list_disabled = true
	elseif list_state.present and latest_ver then
		local old_str = version_str(list_state.version or { 0 })
		local new_str = version_str(latest_ver)
		list_label = string.format("📥 Mettre à jour Ergopti dans la liste — v%s → v%s", old_str, new_str)
		list_fn    = function()
			Logger.info(LOG, "Opening Keyboard panel for in-list upgrade (manual swap).")
			if hs.alert then
				pcall(hs.alert.show,
					"Retirez l’ancienne version puis ajoutez la nouvelle dans la liste.", 4)
			end
			pcall(hs.execute, "open '" .. KEYBOARD_PREFS_URL .. "'")
		end
	else
		list_label = "➕ Ajouter Ergopti à la liste des dispositions"
		list_fn    = function()
			Logger.info(LOG, "Opening Keyboard input-source preferences pane.")
			pcall(hs.execute, "open '" .. KEYBOARD_PREFS_URL .. "'")
		end
	end
	submenu[#submenu + 1] = {
		title    = list_label,
		disabled = list_disabled or nil,
		fn       = list_fn,
	}

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
					set_input_source(raw_name)
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

-- Late-bound test hooks: the helpers below are defined after section 2, so we
-- expose them here to keep section 2 self-contained.
M._version_str             = version_str
M._clean_layout_name       = clean_layout_name
M._extract_ergopti_version = extract_ergopti_version

return M
