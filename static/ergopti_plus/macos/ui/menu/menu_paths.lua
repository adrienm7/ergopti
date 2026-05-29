--- ui/menu/menu_paths.lua

--- ==============================================================================
--- MODULE: Menu Paths
--- DESCRIPTION:
--- Provides a menu item and a webview-based form panel that lets the user
--- configure the single machine-specific configuration directory used by
--- Hammerspoon. All personal files are resolved relative to that directory.
---
--- FEATURES & RATIONALE:
--- 1. Single Key: Only ConfigDirPath is stored in paths.toml; all file paths
---    are derived from it with fixed names, keeping the form simple.
--- 2. Bootstrap File: Paths are persisted in a gitignored paths.toml file
---    (next to init.lua) so users can relocate every personal file outside
---    the repository for private version control.
--- 3. Live Reload: Any directory change triggers a Hammerspoon reload so that
---    all modules immediately pick up files from the new location.
--- 4. WebView Form: A single folder field with a "Parcourir…" button replaces
---    the old five-field form.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("lib.logger")
local i18n   = require("lib.i18n")
local LOG    = "menu_paths"

-- Bootstrap file lives next to init.lua (gitignored).
local PATHS_FILENAME = "paths.toml"

-- The single key stored in paths.toml.
local CONFIG_DIR_KEY = "ConfigDirPath"

-- Absolute path to the assets directory (same folder as this file).
local _src       = debug.getinfo(1, "S").source:sub(2)
local ASSETS_DIR = (_src:match("^(.*[/\\])") or "./"):gsub("menu[/\\]$", "") .. "paths_editor/"

-- Driver root (where paths.toml lives) — derived at module-load time from
-- this file's own path so that get_config_dir() can read paths.toml even
-- before M.init() has been called. M.init() may override this later.
local _base_dir  = (_src:match("^(.*[/\\])") or "./"):gsub("ui[/\\]menu[/\\]$", "")
-- Default user config dir is computed at module-load time, not in M.init(), so
-- that get_config_dir() always returns a usable absolute path even when
-- consumers (e.g. keylogger.init module-load IIFE) require this module before
-- init() has run. Anything written under config_dir() must therefore land
-- outside the source tree by construction.
local _default_config_dir = (function()
	local home = os.getenv("HOME")
	if type(home) == "string" and home ~= "" then
		return home .. "/.config/ergopti_plus/"
	end
	return ""
end)()
local _reload_fn = nil
local _bootstrap = nil   -- in-memory cache: { ConfigDirPath = "..." } or {}; nil = not yet loaded

-- WebView state (singleton)
local _webview     = nil
local _usercontent = nil




-- ====================================
--- ====================================
-- ======= 1/ Bootstrap Helpers =======
--- ====================================
-- ====================================

--- Returns the absolute path to paths.toml.
--- @return string
local function paths_file()
	return (_base_dir or "") .. PATHS_FILENAME
end

--- Returns the resolved config directory (with trailing slash).
--- Falls back to ~/.config/ergopti_plus/ when no override is set.
--- Lazy-loads paths.toml on first call so that modules requiring this
--- module before M.init() still get the user-configured path.
--- @return string
local function config_dir()
	-- Lazy-load: read paths.toml once if _bootstrap has never been populated
	if _bootstrap == nil then
		_bootstrap = {}
		local fh = io.open((_base_dir or "") .. PATHS_FILENAME, "r")
		if fh then
			local raw = fh:read("*a")
			fh:close()
			for line in raw:gmatch("[^\r\n]+") do
				local trimmed = line:match("^%s*(.-)%s*$")
				if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
					local key, val = trimmed:match('^(%S+)%s*=%s*"(.*)"$')
					if key and val then _bootstrap[key] = val end
				end
			end
		end
	end
	local v = _bootstrap[CONFIG_DIR_KEY]
	if type(v) == "string" and v ~= "" then return v end
	return _default_config_dir or _base_dir or ""
end

--- Ensures a directory exists (idempotent), creating parents as needed.
--- @param path string Absolute path with trailing slash.
local function ensure_dir(path)
	if not path or path == "" then return end
	pcall(hs.execute, string.format("mkdir -p %q", path))
end

--- Returns the absolute path for a named personal file inside config_dir().
--- Used for SHARED files (hotstrings TOML, personal info) that live at
--- the root of the synced config dir and can be read by either driver.
--- @param filename string Bare filename (e.g. "personal_hotstrings.toml").
--- @return string
local function file_in_config(filename)
	local d = config_dir()
	if not d:match("[/\\]$") then d = d .. "/" end
	return d .. filename
end

--- Returns the absolute path for a HS-specific file under the
--- ``hammerspoon/`` subfolder of config_dir(). Used for files whose
--- semantics differ from the AHK side (config.toml with macOS bundle
--- IDs, config_karabiner.toml which is Mac-only by definition, etc.).
--- The subfolder is auto-created on first call so callers do not have
--- to worry about ENOENT on a fresh install.
--- @param filename string Bare filename inside the hammerspoon/ folder.
--- @return string
local function file_in_driver_subdir(filename)
	local d = config_dir()
	if not d:match("[/\\]$") then d = d .. "/" end
	local sub = d .. "hammerspoon/"
	ensure_dir(sub)
	return sub .. filename
end


--- Parses a simple flat TOML file (key = "value" pairs, ignoring comments).
--- @param content string Raw file content.
--- @return table Parsed key-value map.
local function parse_toml(content)
	local result = {}
	for line in content:gmatch("[^\r\n]+") do
		local trimmed = line:match("^%s*(.-)%s*$")
		if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
			local key, val = trimmed:match('^(%S+)%s*=%s*"(.*)"$')
			if key and val then
				result[key] = val
			end
		end
	end
	return result
end

--- Serializes the bootstrap table to TOML.
--- The header mirrors the AutoHotkey driver's paths.toml so the two driver
--- bootstrap files stay visually identical, and is intentionally English —
--- this file is developer-facing (gitignored, manually edited when relocating
--- the config dir), not user-facing.
--- @return string
local function serialize_toml()
	local default_dir = _default_config_dir ~= "" and _default_config_dir
		or "~/.config/ergopti_plus/"
	local lines = { "# Custom paths — auto-generated by ErgoptiPlus." }
	lines[#lines + 1] = "# Edit this file to point to your personal configuration folder."
	lines[#lines + 1] = string.format(
		"# If absent or commented out, files are looked up in: %s",
		default_dir
	)
	lines[#lines + 1] = ""
	local v = _bootstrap[CONFIG_DIR_KEY]
	if type(v) == "string" and v ~= "" then
		lines[#lines + 1] = string.format('%s = "%s"', CONFIG_DIR_KEY, v)
	else
		lines[#lines + 1] = string.format('# %s = "%s"', CONFIG_DIR_KEY, default_dir)
	end
	lines[#lines + 1] = ""
	return table.concat(lines, "\n")
end

--- Persists the current _bootstrap table to disk as TOML.
local function save_bootstrap()
	local content = serialize_toml()
	local fh = io.open(paths_file(), "w")
	if not fh then
		Logger.error(LOG, "Cannot open paths file for writing: '{1}'.", paths_file())
		return
	end
	fh:write(content)
	fh:close()
	Logger.info(LOG, "Paths saved to '{1}'.", paths_file())
end

--- Loads paths.toml from disk into _bootstrap.
--- Creates the file with a commented example if it does not exist yet.
local function load_bootstrap()
	local fh = io.open(paths_file(), "r")
	if not fh then
		Logger.info(LOG, "paths.toml not found — generating with defaults at '{1}'.", paths_file())
		_bootstrap = {}
		save_bootstrap()
		return
	end
	local raw = fh:read("*a")
	fh:close()
	_bootstrap = parse_toml(raw)
	Logger.debug(LOG, "Paths loaded from '{1}'.", paths_file())
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
	ensure_dir(_base_dir)  -- Ensure the driver directory exists before loading paths.toml
	load_bootstrap()
	-- Only create the default fallback directory when no custom path is configured;
	-- otherwise the user ends up with an unwanted ~/.config/ergopti_plus/ on every reload
	local resolved = config_dir()
	if resolved == _default_config_dir then
		ensure_dir(_default_config_dir)
	end
	Logger.info(LOG, "Paths module initialized (base: '{1}', config: '{2}').",
		base_dir, resolved)
end

--- Returns true if M.init() has already been called successfully.
--- @return boolean
function M.is_initialized()
	return _base_dir ~= nil
end

--- Returns the resolved path for a well-known personal file.
--- Returns the absolute path to the user's personal hotstrings folder.
--- The folder is auto-created on first access so callers need not guard ENOENT.
--- @return string Absolute path with trailing slash.
local function personal_hotstrings_dir()
	local d = config_dir()
	if not d:match("[/\\]$") then d = d .. "/" end
	local p = d .. "hotstrings/"
	ensure_dir(p)
	-- Bootstrap an empty personal_hotstrings.toml on first use so the user
	-- always has a file to open rather than a confusing ENOENT.
	local toml_path = p .. "personal_hotstrings.toml"
	local existing  = io.open(toml_path, "r")
	if not existing then
		local fh = io.open(toml_path, "w")
		if fh then fh:write("") fh:close() end
	else
		existing:close()
	end
	return p
end

--- Callers use named constants rather than bare filenames.
--- @param key string One of: "PersonalTomlPath", "PersonalInfoTomlPath",
---   "HotstringsDirPath", "PersonalHotstringsDir", "ConfigTomlPath", "KarabinerConfigPath".
--- @return string The resolved absolute path.
function M.get(key)
	-- Shared at the root of config_dir (both drivers may read these):
	if key == "PersonalTomlPath"     then return personal_hotstrings_dir() .. "personal_hotstrings.toml" end
	if key == "PersonalInfoTomlPath" then return file_in_config("personal_info.toml")                   end
	if key == "HotstringsDirPath"    then return config_dir()                                           end
	if key == "PersonalHotstringsDir" then return personal_hotstrings_dir()                             end
	-- Hammerspoon-specific (under <config_dir>/hammerspoon/):
	if key == "ConfigTomlPath"           then return file_in_driver_subdir("config.toml")              end
	if key == "KarabinerConfigPath"      then return file_in_driver_subdir("config_karabiner.toml")      end
	if key == "PersonalShortcutsLuaPath" then return file_in_driver_subdir("personal_shortcuts.lua")   end
	return ""
end

--- Returns the current config directory (with trailing slash).
--- @return string
function M.get_config_dir()
	return config_dir()
end

--- Returns the OS-default config directory (with trailing slash). Used by
--- the onboarding wizard to pre-fill the form and to detect "user kept
--- the default" so we don't write a redundant override to paths.toml.
--- @return string
function M.get_default_config_dir()
	return _default_config_dir or _base_dir or ""
end

--- Persists a new config directory to paths.toml WITHOUT reloading
--- Hammerspoon. Used by the onboarding wizard which writes config.toml
--- right after this call and triggers its own reload at the end —
--- chaining hs.reload() inside the menu_paths path-editor flow would
--- restart the script mid-wizard and lose the rest of the answers.
--- @param new_dir string Absolute path with trailing slash, or "" / nil
---                       to mean "use the OS default".
function M.persist_config_dir_for_wizard(new_dir)
	if type(new_dir) ~= "string" then new_dir = "" end
	if new_dir ~= "" and not new_dir:match("[/\\]$") then
		new_dir = new_dir .. "/"
	end
	-- An empty path or one equal to the default → clear the override so
	-- paths.toml stays as a commented-out template (lets a future
	-- ``hs.reload`` follow the OS default path).
	if new_dir == "" or new_dir == (_default_config_dir or "") then
		_bootstrap[CONFIG_DIR_KEY] = nil
	else
		_bootstrap[CONFIG_DIR_KEY] = new_dir
		ensure_dir(new_dir)
	end
	save_bootstrap()
end




-- ===================================
-- ===================================
-- ======= 3/ Path Editor GUI =======
-- ===================================
-- ===================================


--- =====================================
-- ===== 3.1) Native Folder Picker =====
--- =====================================

--- Opens a native AppleScript-based dialog to pick a folder.
--- Returns the selected path (with trailing slash), or nil if cancelled.
--- @param current string Currently configured directory shown as default location.
--- @return string|nil
local function pick_dir(current)
	local default_dir = current or _base_dir or "/"
	if not default_dir:match("[/\\]$") then
		default_dir = default_dir:match("^(.+[/\\])") or default_dir
	end
	local ok_attr, attr = pcall(hs.fs.attributes, default_dir)
	if not ok_attr or not attr or attr.mode ~= "directory" then
		default_dir = os.getenv("HOME") or "/"
	end

	local escaped = default_dir:gsub('"', '\\"')
	local script  = string.format([[
		try
			set r to choose folder with prompt "%s" default location ((POSIX file "%s") as alias)
			return POSIX path of r
		on error
			return ""
		end try
	]], i18n.get("menu.paths.pick_prompt"), escaped)

	local ok, r2, raw = hs.osascript.applescript(script)
	Logger.debug(LOG, "pick_dir: ok={1} r2={2}.", tostring(ok), tostring(r2))

	if type(r2) == "string" and r2 ~= "" then
		local p = r2:match("^(.-)%s*$")
		if not p:match("[/\\]$") then p = p .. "/" end
		return p
	end
	if type(raw) == "string" and raw ~= "" then
		local stripped = (raw:match('^"(.*)"$') or raw):match("^(.-)%s*$")
		if stripped ~= "" then
			if not stripped:match("[/\\]$") then stripped = stripped .. "/" end
			return stripped
		end
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

--- Applies the new config directory and triggers a reload.
--- @param new_dir string The chosen directory (with trailing slash).
local function apply_and_reload(new_dir)
	if type(new_dir) ~= "string" or new_dir == "" then
		new_dir = _default_config_dir or _base_dir or ""
	end
	if not new_dir:match("[/\\]$") then new_dir = new_dir .. "/" end

	local old_dir = config_dir()
	if new_dir == old_dir then
		Logger.debug(LOG, "Paths editor: directory unchanged, skipping reload.")
		close_webview()
		return
	end

	-- Store only when it differs from the default
	if new_dir == _default_config_dir then
		_bootstrap[CONFIG_DIR_KEY] = nil
	else
		_bootstrap[CONFIG_DIR_KEY] = new_dir
		ensure_dir(new_dir)
	end

	save_bootstrap()
	close_webview()

	Logger.start(LOG, "Applying new config directory and reloading…")
	if type(_reload_fn) == "function" then
		_reload_fn()
	else
		pcall(hs.reload)
	end
end

--- Builds the form data payload and injects it into the webview via initData().
local function inject_init_data()
	if not _webview then return end

	local current_dir = config_dir()
	local default_dir = _default_config_dir or _base_dir or ""

	local i18n_keys = {
		"menu.paths.window_title",
		"paths_editor.heading", "paths_editor.subtitle", "paths_editor.label_config_dir",
		"paths_editor.tag_default", "paths_editor.tag_modified",
		"paths_editor.btn_browse", "paths_editor.btn_reset",
		"paths_editor.btn_cancel", "paths_editor.btn_save",
	}
	local strings = {}
	for _, k in ipairs(i18n_keys) do
		strings[k] = i18n.get(k)
	end

	local payload = {
		configDir        = current_dir,
		defaultConfigDir = default_dir,
		strings          = strings,
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
	Logger.debug(LOG, "usercontent message received: action='{1}'.", tostring(action))

	if action == "ready" then
		inject_init_data()
	elseif action == "browse" then
		hs.timer.doAfter(0, function()
			Logger.start(LOG, "Opening native folder picker…")
			local picked = pick_dir(config_dir())
			Logger.success(LOG, "Picker returned: '{1}'.", tostring(picked))
			if picked and picked ~= "" then
				local function js_str(s)
					return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
				end
				local js = "window.applyBrowseResult(" .. js_str(picked) .. ")"
				hs.timer.doAfter(0.1, function()
					if _webview then
						pcall(function() _webview:evaluateJavaScript(js) end)
					end
				end)
			else
				Logger.warn(LOG, "browse: picker returned nothing — user cancelled.")
			end
		end)
	elseif action == "save" then
		apply_and_reload(type(body.configDir) == "string" and body.configDir or "")
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

	local screen  = hs.screen.mainScreen()
	local sf      = screen and type(screen.frame) == "function" and screen:frame() or { h = 800 }
	local win_h   = math.min(220, math.floor(sf.h * 0.35))
	local win_w   = math.min(700, math.floor((sf.w or 1440) * 0.55))

	_webview = ui_builder.show_webview({
		frame       = ui_builder.get_centered_frame(win_w, win_h),
		title       = i18n.get("menu.paths.window_title"),
		style_masks = style_masks,
		usercontent = _usercontent,
		assets_dir    = ASSETS_DIR,
		on_close      = function()
			_webview     = nil
			_usercontent = nil
		end,
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
--- =========================================
-- ======= 4/ Menu Item Construction =======
--- =========================================
-- ============================================

--- Builds the "Dossier de configuration…" menu item for the tray menu.
--- @return table Menu item table.
function M.build_menu_item()
	return {
		title = i18n.get("menu.paths.menu_item"),
		fn    = function()
			hs.timer.doAfter(0.05, function() pcall(M.open_editor) end)
		end,
	}
end

return M
