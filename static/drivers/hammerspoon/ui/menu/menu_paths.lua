--- ui/menu/menu_paths.lua

--- ==============================================================================
--- MODULE: Menu Paths
--- DESCRIPTION:
--- Provides a menu item and GUI panel to let the user configure all
--- machine-specific file paths used by Hammerspoon : personal.toml, the
--- driver config.json, the Karabiner user config, and the hotstrings directory.
---
--- FEATURES & RATIONALE:
--- 1. Bootstrap File: Paths are persisted in a gitignored bootstrap JSON file
---    (ergopti_bootstrap.json next to init.lua) so users can relocate every
---    personal file outside the repository for private version control.
--- 2. Driver-Agnostic Defaults: Default paths mirror the repository layout,
---    identical to the defaults used by the AutoHotkey driver.
--- 3. Live Reload: A path change that affects loaded data (personal.toml,
---    hotstrings dir) triggers a Hammerspoon reload automatically.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("lib.logger")
local LOG    = "menu_paths"

-- Bootstrap file lives next to init.lua (gitignored).
-- Holds absolute paths so the user can store personal files anywhere.
local BOOTSTRAP_FILENAME = "ergopti_bootstrap.json"

-- Keys present in the bootstrap file — mirrors AHK's ScriptInformation map.
local PATH_KEYS = {
	"PersonalTomlPath",
	"HotstringsDirPath",
	"ConfigJsonPath",
	"KarabinerConfigPath",
}

-- Human labels shown in the dialog for each key (French, user-facing).
local PATH_LABELS = {
	PersonalTomlPath    = "Fichier personal.toml :",
	HotstringsDirPath   = "Dossier des hotstrings :",
	ConfigJsonPath      = "Fichier de configuration (config.json) :",
	KarabinerConfigPath = "Configuration Karabiner (karabiner_user_config.json) :",
}

-- File-type filter hints for each key (used in the open-panel title).
local PATH_FILTERS = {
	PersonalTomlPath    = { kind = "file",   ext = "toml" },
	HotstringsDirPath   = { kind = "folder"              },
	ConfigJsonPath      = { kind = "file",   ext = "json" },
	KarabinerConfigPath = { kind = "file",   ext = "json" },
}

local _base_dir     = nil
local _reload_fn    = nil
local _bootstrap    = {}   -- in-memory cache of the loaded bootstrap table




-- ====================================
-- ====================================
-- ======= 1/ Bootstrap Helpers =======
-- ====================================
-- ====================================

--- Computes the absolute default path for a given key relative to base_dir.
--- @param key string One of the PATH_KEYS.
--- @return string The default absolute path.
local function default_path(key)
	local b = _base_dir or ""
	if key == "PersonalTomlPath"    then return b .. "../hotstrings/personal.toml"           end
	if key == "HotstringsDirPath"   then return b .. "../hotstrings/"                        end
	if key == "ConfigJsonPath"      then return b .. "config.json"                           end
	if key == "KarabinerConfigPath" then return b .. "karabiner_user_config.json"            end
	return ""
end

--- Returns the bootstrap file path.
--- @return string
local function bootstrap_file()
	return (_base_dir or "") .. BOOTSTRAP_FILENAME
end

--- Loads the bootstrap JSON from disk into _bootstrap.
local function load_bootstrap()
	local fh = io.open(bootstrap_file(), "r")
	if not fh then _bootstrap = {}; return end
	local raw = fh:read("*a")
	fh:close()
	local ok, tbl = pcall(hs.json.decode, raw)
	_bootstrap = (ok and type(tbl) == "table") and tbl or {}
	Logger.debug(LOG, "Bootstrap loaded from '%s'.", bootstrap_file())
end

--- Persists the current _bootstrap table to disk.
local function save_bootstrap()
	local ok_enc, encoded = pcall(hs.json.encode, _bootstrap, true)
	if not ok_enc or not encoded then
		Logger.error(LOG, "Failed to encode bootstrap JSON.")
		return
	end
	local fh = io.open(bootstrap_file(), "w")
	if not fh then
		Logger.error(LOG, "Cannot open bootstrap file for writing: '%s'.", bootstrap_file())
		return
	end
	fh:write(encoded)
	fh:close()
	Logger.info(LOG, "Bootstrap saved to '%s'.", bootstrap_file())
end




-- ==============================
-- ==============================
-- ======= 2/ Public API =======
-- ==============================
-- ==============================

--- Initializes the module with the driver base directory and a reload callback.
--- Must be called before any other function.
--- @param base_dir string Absolute path to the Hammerspoon driver directory (with trailing slash).
--- @param reload_fn function Callback that triggers a Hammerspoon reload.
function M.init(base_dir, reload_fn)
	if type(base_dir) ~= "string" or base_dir == "" then
		Logger.error(LOG, "M.init(): base_dir must be a non-empty string — module non-functional.")
		return
	end
	_base_dir  = base_dir
	_reload_fn = reload_fn
	load_bootstrap()
	Logger.info(LOG, "Paths module initialized (base: '%s').", base_dir)
end

--- Returns true if M.init() has already been called successfully.
--- @return boolean
function M.is_initialized()
	return _base_dir ~= nil
end

--- Returns the resolved path for a given key, falling back to the default.
--- @param key string One of the PATH_KEYS.
--- @return string The resolved absolute path.
function M.get(key)
	local override = _bootstrap[key]
	if type(override) == "string" and override ~= "" then return override end
	return default_path(key)
end




-- ===================================
-- ===================================
-- ======= 3/ Path Editor GUI =======
-- ===================================
-- ===================================

--- Opens a native AppleScript-based dialog to pick a file or folder.
--- Returns the selected path, or nil if cancelled.
--- @param current string Currently configured path shown as default location.
--- @param filter table {kind="file"|"folder", ext="toml"|"json"|nil}
--- @return string|nil
local function pick_path(current, filter)
	local script
	if filter and filter.kind == "folder" then
		script = string.format(
			'tell application "Finder"\n'
			.. '  set d to POSIX file "%s" as alias\n'
			.. '  set r to choose folder with prompt "Sélectionner un dossier" default location d\n'
			.. '  return POSIX path of r\n'
			.. 'end tell',
			current:gsub('"', '\\"')
		)
	else
		local ext_filter = ""
		if filter and filter.ext then
			ext_filter = string.format(' of type {"%s"}', filter.ext)
		end
		script = string.format(
			'tell application "Finder"\n'
			.. '  set d to POSIX file "%s" as alias\n'
			.. '  set r to choose file with prompt "Sélectionner un fichier"%s default location d\n'
			.. '  return POSIX path of r\n'
			.. 'end tell',
			current:gsub('"', '\\"'),
			ext_filter
		)
	end
	local ok, result = pcall(hs.osascript.applescript, script)
	if ok and type(result) == "string" and result ~= "" then
		-- Strip trailing newline
		return result:match("^(.-)%s*$")
	end
	return nil
end

--- Opens the paths editor as a webview-based dialog (using hs.dialog.blockAlert
--- for confirmation, AppleScript open panels for picking).
function M.open_editor()
	if not _base_dir then
		Logger.error(LOG, "open_editor() called before M.init().")
		return
	end

	-- Collect current values
	local current = {}
	for _, key in ipairs(PATH_KEYS) do
		current[key] = M.get(key)
	end

	-- Build a summary text for the alert
	local lines = { "Chemins actuels :\n" }
	for _, key in ipairs(PATH_KEYS) do
		lines[#lines + 1] = PATH_LABELS[key] .. "\n" .. current[key]
	end
	local summary = table.concat(lines, "\n\n")

	-- Present the editor loop: pick paths one by one, then confirm
	local changed_keys = {}

	for _, key in ipairs(PATH_KEYS) do
		local label  = PATH_LABELS[key]
		local filter = PATH_FILTERS[key]
		local cur    = current[key]

		local btn = hs.dialog.blockAlert(
			label,
			"Valeur actuelle :\n" .. cur .. "\n\nCliquez « Modifier » pour choisir un autre emplacement, ou « Ignorer » pour conserver cette valeur.",
			"Modifier…",
			"Ignorer"
		)

		if btn == "Modifier…" then
			-- Use the directory of the current file/folder as the default location
			local default_loc
			if filter and filter.kind == "folder" then
				default_loc = cur:match("^(.+[/\\])") or cur
			else
				default_loc = cur:match("^(.+[/\\])") or (_base_dir or "")
			end

			local picked = pick_path(default_loc, filter)
			if picked then
				-- Normalize folder paths to always end with /
				if filter and filter.kind == "folder" and not picked:match("[/\\]$") then
					picked = picked .. "/"
				end
				current[key]   = picked
				changed_keys[#changed_keys + 1] = key
			end
		end
	end

	if #changed_keys == 0 then
		Logger.debug(LOG, "Paths editor closed without changes.")
		return
	end

	-- Show summary of new values before saving
	local new_lines = { "Nouvelles valeurs :\n" }
	for _, key in ipairs(changed_keys) do
		new_lines[#new_lines + 1] = PATH_LABELS[key] .. "\n" .. current[key]
	end

	local confirm = hs.dialog.blockAlert(
		"Confirmer les modifications",
		table.concat(new_lines, "\n\n") .. "\n\nUn rechargement sera nécessaire pour appliquer les changements.",
		"Appliquer et recharger",
		"Annuler"
	)

	if confirm ~= "Appliquer et recharger" then
		Logger.debug(LOG, "Paths editor: user cancelled save.")
		return
	end

	-- Persist changed keys to bootstrap
	for _, key in ipairs(changed_keys) do
		-- Store nil (omit from bootstrap) when the value matches the default,
		-- so the file stays clean and portable
		if current[key] == default_path(key) then
			_bootstrap[key] = nil
		else
			_bootstrap[key] = current[key]
		end
	end
	save_bootstrap()

	Logger.start(LOG, "Applying new paths and reloading…")
	if type(_reload_fn) == "function" then
		_reload_fn()
	else
		pcall(hs.reload)
	end
end




-- ============================================
-- ============================================
-- ======= 4/ Menu Item Construction =======
-- ============================================
-- ============================================

--- Builds the "Chemins des fichiers…" menu item for the tray menu.
--- @return table Menu item table.
function M.build_menu_item()
	return {
		title = "Chemins des fichiers…",
		fn    = function()
			hs.timer.doAfter(0.05, function() pcall(M.open_editor) end)
		end,
	}
end

return M
