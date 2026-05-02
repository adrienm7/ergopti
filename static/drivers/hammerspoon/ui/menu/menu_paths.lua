--- ui/menu/menu_paths.lua

--- ==============================================================================
--- MODULE: Menu Paths
--- DESCRIPTION:
--- Provides a menu item and a webview-based form panel that lets the user
--- configure all machine-specific file paths used by Hammerspoon: personal.toml,
--- the driver config.json, the Karabiner user config, and the hotstrings
--- directory.
---
--- FEATURES & RATIONALE:
--- 1. Bootstrap File: Paths are persisted in a gitignored bootstrap JSON file
---    (ergopti_bootstrap.json next to init.lua) so users can relocate every
---    personal file outside the repository for private version control.
--- 2. Driver-Agnostic Defaults: Default paths mirror the repository layout,
---    identical to the defaults used by the AutoHotkey driver.
--- 3. Live Reload: A path change that affects loaded data (personal.toml,
---    hotstrings dir) triggers a Hammerspoon reload automatically.
--- 4. WebView Form: All five paths are presented simultaneously in a single
---    native-looking form, with per-field "Parcourir…" buttons that open a
---    proper file/folder picker.  Replaces the old sequential blockAlert loop.
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
	"PersonalInfoTomlPath",
	"HotstringsDirPath",
	"ConfigJsonPath",
	"KarabinerConfigPath",
}

-- Human labels shown in the form for each key (French, user-facing).
local PATH_LABELS = {
	PersonalTomlPath     = "Fichier personal.toml",
	PersonalInfoTomlPath = "Fichier personal_info.toml (coordonnées personnelles)",
	HotstringsDirPath    = "Dossier des hotstrings",
	ConfigJsonPath       = "Fichier de configuration (config.json)",
	KarabinerConfigPath  = "Configuration Karabiner (karabiner_user_config.json)",
}

-- File-type filter hints for each key (used in the open-panel title).
local PATH_FILTERS = {
	PersonalTomlPath     = { kind = "file",   ext = "toml" },
	PersonalInfoTomlPath = { kind = "file",   ext = "toml" },
	HotstringsDirPath    = { kind = "folder"              },
	ConfigJsonPath       = { kind = "file",   ext = "json" },
	KarabinerConfigPath  = { kind = "file",   ext = "json" },
}

-- Absolute path to the assets directory (same folder as this file).
local _src       = debug.getinfo(1, "S").source:sub(2)
local ASSETS_DIR = (_src:match("^(.*[/\\])") or "./"):gsub("menu[/\\]$", "") .. "paths_editor/"

local _base_dir  = nil
local _reload_fn = nil
local _bootstrap = {}   -- in-memory cache of the loaded bootstrap table

-- WebView state (singleton)
local _webview     = nil
local _usercontent = nil




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
	if key == "PersonalTomlPath"     then return b .. "../hotstrings/personal.toml"           end
	if key == "PersonalInfoTomlPath" then return b .. "../hotstrings/personal_info.toml"      end
	if key == "HotstringsDirPath"    then return b .. "../hotstrings/"                        end
	if key == "ConfigJsonPath"       then return b .. "config.json"                           end
	if key == "KarabinerConfigPath"  then return b .. "karabiner_user_config.json"            end
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


-- =========================================
-- ===== 3.1) Native File/Folder Picker =====
-- =========================================

--- Opens a native AppleScript-based dialog to pick a file or folder.
--- Returns the selected path, or nil if cancelled.
--- @param current string Currently configured path shown as default location.
--- @param filter table {kind="file"|"folder", ext="toml"|"json"|nil}
--- @return string|nil
local function pick_path(current, filter)
	-- Resolve a default location that exists as a directory on disk.
	-- choose file/folder default location requires a directory alias, not a file path.
	local default_dir = current or ""
	-- Strip to parent directory if current is a file path
	if not default_dir:match("[/\\]$") then
		default_dir = default_dir:match("^(.+[/\\])") or default_dir
	end
	local ok_attr, attr = pcall(hs.fs.attributes, default_dir)
	if not ok_attr or not attr or attr.mode ~= "directory" then
		default_dir = os.getenv("HOME") or "/"
	end

	local is_folder = filter and filter.kind == "folder"
	local verb      = is_folder and "choose folder" or "choose file"
	local prompt    = is_folder and "Sélectionner un dossier" or "Sélectionner un fichier"

	-- Use 'POSIX file ... as alias' which works for both file and folder defaults.
	-- AppleScript raises error -128 on user cancel — we capture and treat as nil.
	local escaped = default_dir:gsub('"', '\\"')
	local script  = string.format([[
		try
			set r to %s with prompt "%s" default location ((POSIX file "%s") as alias)
			return POSIX path of r
		on error errMsg number errNum
			return ""
		end try
	]], verb, prompt, escaped)

	Logger.debug(LOG, "pick_path: AppleScript with default_dir='%s'.", default_dir)
	local ok, r2, raw = hs.osascript.applescript(script)
	Logger.debug(LOG, "pick_path: ok=%s r2=%s raw=%s.", tostring(ok), tostring(r2), tostring(raw))

	if type(r2) == "string" and r2 ~= "" then
		return (r2:match("^(.-)%s*$"))
	end
	-- Fallback: parse raw string if r2 isn't a clean string
	if type(raw) == "string" and raw ~= "" then
		local stripped = raw:match('^"(.*)"$') or raw
		stripped = stripped:match("^(.-)%s*$")
		if stripped ~= "" then return stripped end
	end
	return nil
end


-- ===================================
-- ===== 3.2) WebView Lifecycle =====
-- ===================================

--- Closes and cleans up the paths editor webview.
local function close_webview()
	if _webview then
		pcall(function() _webview:delete() end)
		_webview     = nil
		_usercontent = nil
	end
end

--- Applies changed paths to the bootstrap file and triggers a reload.
--- @param new_values table key → path string for all keys.
local function apply_and_reload(new_values)
	local changed = false
	for _, key in ipairs(PATH_KEYS) do
		local v = type(new_values[key]) == "string" and new_values[key] or ""
		-- Omit from bootstrap when equal to default, keeping the file portable
		if v == default_path(key) then
			if _bootstrap[key] ~= nil then _bootstrap[key] = nil; changed = true end
		else
			if _bootstrap[key] ~= v then _bootstrap[key] = v; changed = true end
		end
	end

	if not changed then
		Logger.debug(LOG, "Paths editor: no effective changes, skipping reload.")
		close_webview()
		return
	end

	save_bootstrap()
	close_webview()

	Logger.start(LOG, "Applying new paths and reloading…")
	if type(_reload_fn) == "function" then
		_reload_fn()
	else
		pcall(hs.reload)
	end
end

--- Builds the form data payload and injects it into the webview via initData().
local function inject_init_data()
	if not _webview then return end

	local defaults = {}
	local current  = {}
	for _, key in ipairs(PATH_KEYS) do
		defaults[key] = default_path(key)
		current[key]  = M.get(key)
	end

	local payload = {
		keys     = PATH_KEYS,
		labels   = PATH_LABELS,
		defaults = defaults,
		current  = current,
	}

	local ok_enc, json = pcall(hs.json.encode, payload)
	if not ok_enc or not json then
		Logger.error(LOG, "Failed to encode initData payload.")
		return
	end

	Logger.debug(LOG, "Injecting initData into webview…")
	pcall(function()
		_webview:evaluateJavaScript("if(window.initData) window.initData(" .. json .. ")")
	end)
end

--- Handles an incoming message from the JavaScript frontend via usercontent bridge.
--- @param body table The decoded message body.
local function handle_message(body)
	if type(body) ~= "table" then return end
	local action = body.action
	Logger.debug(LOG, "usercontent message received: action='%s'.", tostring(action))

	if action == "ready" then
		inject_init_data()
	elseif action == "browse" then
		local key    = body.key
		local filter = PATH_FILTERS[key]
		Logger.debug(LOG, "browse: key='%s', filter.kind='%s', filter.ext='%s'.",
			tostring(key), tostring(filter and filter.kind), tostring(filter and filter.ext))
		if not filter then
			Logger.error(LOG, "browse: no filter for key '%s'.", tostring(key))
			return
		end
		hs.timer.doAfter(0, function()
			local cur_val  = M.get(key)
			local base_loc = filter.kind == "folder"
				and (cur_val:match("^(.+[/\\])") or cur_val)
				or  (cur_val:match("^(.+[/\\])") or (_base_dir or ""))
			Logger.debug(LOG, "browse: cur_val='%s', base_loc='%s'.", tostring(cur_val), tostring(base_loc))
			Logger.start(LOG, "Opening native file picker…")
			local picked = pick_path(base_loc, filter)
			Logger.success(LOG, "Picker returned: '%s' (type=%s).", tostring(picked), type(picked))
			if picked and picked ~= "" then
				if filter.kind == "folder" and not picked:match("[/\\]$") then picked = picked .. "/" end
				-- Manual JS string escaping — avoids hs.json.encode pitfalls on bare strings
				local function js_str(s)
					return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
				end
				local js = "window.applyBrowseResult(" .. js_str(key) .. "," .. js_str(picked) .. ")"
				Logger.debug(LOG, "browse: injecting JS: %s.", js)
				hs.timer.doAfter(0.1, function()
					if _webview then
						local ok_js, err_js = pcall(function() _webview:evaluateJavaScript(js) end)
						if ok_js then
							Logger.success(LOG, "browse: applyBrowseResult JS dispatched.")
						else
							Logger.error(LOG, "browse: evaluateJavaScript failed: %s.", tostring(err_js))
						end
					else
						Logger.error(LOG, "browse: _webview is nil when applying result.")
					end
				end)
			else
				Logger.warn(LOG, "browse: picker returned nothing — user cancelled or AppleScript failed.")
			end
		end)
	elseif action == "save" then
		local vals = type(body.current) == "table" and body.current or {}
		apply_and_reload(vals)
	elseif action == "cancel" then
		close_webview()
	end
end

--- Opens the paths editor as a webview form.
function M.open_editor()
	if not _base_dir then
		Logger.error(LOG, "open_editor() called before M.init().")
		return
	end

	-- Reuse the existing window if already open
	if _webview then
		local ok_ui = pcall(require, "ui.ui_builder")
		if ok_ui then
			local ui_builder = require("ui.ui_builder")
			ui_builder.force_focus(_webview)
		else
			pcall(function() _webview:bringToFront() end)
		end
		return
	end

	-- Initialize the User Content bridge
	local ok_uc, uc = pcall(hs.webview.usercontent.new, "hsPaths")
	if not ok_uc or not uc then
		Logger.error(LOG, "Failed to create webview usercontent bridge.")
		return
	end

	_usercontent = uc
	_usercontent:setCallback(function(message)
		if message and type(message.body) == "table" then
			handle_message(message.body)
		end
	end)

	local ok_ui, ui_builder = pcall(require, "ui.ui_builder")
	if not ok_ui or not ui_builder then
		Logger.error(LOG, "Failed to load ui_builder module.")
		return
	end

	local masks       = hs.webview.windowMasks
	local style_masks = (masks["titled"] or 1) + (masks["closable"] or 2)

	-- Compute a height that fits comfortably on the current screen without
	-- overflowing: 88 % of usable height, capped at 540 px so it is never
	-- taller than a 13" MacBook allows without feeling cramped.
	local screen    = hs.screen.mainScreen()
	local sf        = screen and type(screen.frame) == "function" and screen:frame() or { h = 800 }
	local win_h     = math.min(500, math.floor(sf.h * 0.80))
	local win_w     = math.min(900, math.floor((sf.w or 1440) * 0.7))

	_webview = ui_builder.show_webview({
		frame       = ui_builder.get_centered_frame(win_w, win_h),
		title       = "Chemins des fichiers — Ergopti",
		style_masks = style_masks,
		usercontent = _usercontent,
		assets_dir  = ASSETS_DIR,
		on_close    = function()
			_webview     = nil
			_usercontent = nil
		end,
		-- Inject initData once the page has finished loading
		on_navigation = function(action)
			if action == "didFinishNavigation" then
				Logger.debug(LOG, "Navigation finished — injecting initData.")
				hs.timer.doAfter(0.05, inject_init_data)
			end
			return true
		end,
	})
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
