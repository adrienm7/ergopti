--- ui/menu/menu_paths.lua

--- ==============================================================================
--- MODULE: Menu Paths (the path editor's GUI)
--- DESCRIPTION:
--- The menu item and webview form that let the user choose the single
--- machine-specific configuration directory. Resolution itself lives in
--- infra/config_paths.lua.
---
--- FEATURES & RATIONALE:
--- 1. This file holds the GUI and nothing else. The resolver moved to infra/
---    because infra/ depends on it — personal_hotstrings.lua and
---    personal_shortcuts.lua both resolve their file through get(key) — and
---    while it lived here the infrastructure layer imported the menu.
--- 2. It does NOT write paths.toml. ConfigPaths.set_config_dir is the single
---    writer; this file decides only what happens afterwards, which for the
---    editor is a reload so every module picks up the new location. The
---    onboarding wizard makes the opposite choice through the same call.
--- 3. Single Key: only ConfigDirPath is stored, so the form is one folder field
---    with a "Parcourir…" button.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("infra.logger")
local text_utils = require("infra.text_utils")
local i18n   = require("infra.i18n")
local Paths  = require("infra.paths")
local ConfigPaths = require("infra.config_paths")
local LOG    = "menu_paths"

-- Absolute path to the assets directory. The frontend (index.html, script.js,
-- style.css) lives in the cross-driver _shared/ui/ tree so the Windows WebView2
-- host renders the identical UI; both drivers resolve it through Paths.shared
-- (mirrors hotstring_editor / onboarding / model_browser).
local ASSETS_DIR = (Paths.shared("ui/paths_editor") or "") .. "/"

local _state = nil

-- WebView state (singleton)
local _webview     = nil
local _usercontent = nil





-- =============================
-- =============================
-- ======= 1/ Public API =======
-- =============================
-- =============================






local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — path editor not initialized.", func_name)
		return false
	end
	return true
end

--- Initializes the path editor and the resolver behind it.
--- @param base_dir string Absolute path to the driver directory (trailing slash).
--- @param reload_fn function Callback that triggers a Hammerspoon reload.
function M.init(base_dir, reload_fn)
	Logger.start(LOG, "Initializing paths editor…")
	if type(base_dir) ~= "string" or base_dir == "" then
		Logger.error(LOG, "M.init(): base_dir must be a non-empty string — editor unavailable.")
		return false
	end
	if type(reload_fn) ~= "function" then
		Logger.error(LOG, "M.init(): reload_fn must be a function — editor unavailable.")
		return false
	end
	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return false
	end
	if type(ConfigPaths.is_initialized) ~= "function" then
		Logger.error(LOG, "M.init(): ConfigPaths.is_initialized is unavailable.")
		return false
	end
	if not ConfigPaths.is_initialized() then
		local ok, init_err = xpcall(function() return ConfigPaths.init(base_dir) end, debug.traceback)
		if not ok or not ConfigPaths.is_initialized() then
			Logger.error(LOG, "M.init(): ConfigPaths initialization failed: %s.", tostring(init_err))
			return false
		end
	end
	_state = { reload_fn = reload_fn }
	Logger.success(LOG, "Paths editor initialized.")
	return true
end

--- True when this editor's own init() has run.
--- @return boolean
function M.is_initialized()
	return _state ~= nil
end

--- Resolves a well-known personal file by name.
--- @param key string See infra.config_paths for the accepted keys.
--- @return string
function M.get(key)
	return ConfigPaths.get(key)
end

--- Current config directory (with trailing slash).
--- @return string
function M.get_config_dir()
	return ConfigPaths.get_config_dir()
end

--- The OS-default config directory (with trailing slash).
--- @return string
function M.get_default_config_dir()
	return ConfigPaths.get_default_config_dir()
end

--- Persists a new config directory WITHOUT reloading. Used by the onboarding
--- wizard, which writes config.toml right after and reloads once at the end.
--- @param new_dir string|nil
function M.persist_config_dir_for_wizard(new_dir)
	ConfigPaths.set_config_dir(new_dir)
end






-- ==================================
-- ==================================
-- ======= 2/ Path Editor GUI =======
-- ==================================
-- ==================================








-- =====================================
-- ===== 2.1) Native Folder Picker =====
-- =====================================

--- Opens a native AppleScript-based dialog to pick a folder.
--- Returns the selected path (with trailing slash), or nil if cancelled.
--- @param current string Currently configured directory shown as default location.
--- @return string|nil
local function pick_dir(current)
	local default_dir = current or ConfigPaths.get_config_dir() or "/"
	if not default_dir:match("[/\\]$") then
		default_dir = default_dir:match("^(.+[/\\])") or default_dir
	end
	local ok_attr, attr = pcall(hs.fs.attributes, default_dir)
	if not ok_attr or not attr or attr.mode ~= "directory" then
		default_dir = os.getenv("HOME") or "/"
	end

	-- Both values need escaping and only one used to get it. default_dir is the
	-- user-configurable config directory (or HOME): a backslash in it was silently
	-- eaten by AppleScript, the `as alias` coercion then failed, and the on-error
	-- branch returned "" — the folder picker did nothing at all, with no
	-- diagnostic. The prompt is i18n text from a 21-locale corpus, and the other
	-- copy of this very script (ui/onboarding/init.lua) escaped it while this one
	-- did not. applescript_format removes the choice.
	local script = text_utils.applescript_format([[
		try
			set r to choose folder with prompt "%s" default location ((POSIX file "%s") as alias)
			return POSIX path of r
		on error
			return ""
		end try
	]], i18n.get("menu.paths.pick_prompt") or "", default_dir)

	local ok, r2, raw = hs.osascript.applescript(script)
	Logger.debug(LOG, "pick_dir: ok=%s r2=%s.", tostring(ok), tostring(r2))

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



-- ==================================
-- ===== 2.2) WebView Lifecycle =====
-- ==================================

--- Closes and cleans up the paths editor webview.
local function close_webview()
	if _webview then
		pcall(function() _webview:delete() end)
	end
	_webview     = nil
	_usercontent = nil
end

--- Applies the new config directory and triggers a reload.
--- @param new_dir string The chosen directory (with trailing slash).
local function apply_and_reload(new_dir)
	-- The store itself is ConfigPaths.set_config_dir — the single writer. What is
	-- left here is the editor's own decision: reload afterwards, so every module
	-- picks up the new location. The wizard calls the same writer and deliberately
	-- does not reload, which is the entire difference between the two writers this
	-- replaces.
	local changed = ConfigPaths.set_config_dir(new_dir)
	close_webview()

	if not changed then
		Logger.debug(LOG, "Paths editor: directory unchanged, skipping reload.")
		return
	end

	Logger.start(LOG, "Applying new config directory and reloading…")
	local ok_reload, reload_err = xpcall(_state.reload_fn, debug.traceback)
	if not ok_reload or reload_err == false then
		Logger.error(LOG, "Paths editor reload callback failed: %s.", tostring(reload_err))
		return false
	end
	return true
end

--- Builds the form data payload and injects it into the webview via initData().
local function inject_init_data()
	if not _webview then return end

	local current_dir = ConfigPaths.get_config_dir()
	local default_dir = ConfigPaths.get_default_config_dir()

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
	Logger.debug(LOG, "usercontent message received: action='%s'.", tostring(action))

	if action == "ready" then
		inject_init_data()
	elseif action == "browse" then
		hs.timer.doAfter(0, function()
			Logger.start(LOG, "Opening native folder picker…")
			local picked = pick_dir(ConfigPaths.get_config_dir())
			Logger.success(LOG, "Picker returned: '%s'.", tostring(picked))
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

--- Builds or focuses the paths editor after public lifecycle validation.
--- @return boolean opened
local function open_editor_impl()
	if _webview then
		local ok_ui = pcall(require, "ui.ui_builder")
		if ok_ui then
			local ui_builder = require("ui.ui_builder")
			ui_builder.force_focus(_webview)
		else
			pcall(function() _webview:bringToFront() end)
		end
		return true
	end

	local ok_uc, uc = pcall(hs.webview.usercontent.new, "hsPaths")
	if not ok_uc or not uc then
		Logger.error(LOG, "Failed to create webview usercontent bridge.")
		return false
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
		return false
	end

	local masks       = hs.webview.windowMasks
	local style_masks = (masks["titled"] or 1) + (masks["closable"] or 2)

	local screen  = hs.screen.mainScreen()
	local sf      = screen and type(screen.frame) == "function" and screen:frame() or { h = 800 }
	-- Manifest is the SSoT max; clamp to a screen fraction so the window fits on
	-- small displays. See _shared/ui/apps.manifest.json (paths_editor).
	local geo     = ui_builder.get_app_geometry("paths_editor")
	if not geo then return false end
	local win_h   = math.min(geo.height, math.floor(sf.h * 0.35))
	local win_w   = math.min(geo.width, math.floor((sf.w or 1440) * 0.55))

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
	if not _webview then
		_usercontent = nil
		Logger.error(LOG, "Paths editor webview could not be created.")
		return false
	end
	return true
end

--- Opens the paths editor as a webview form.
--- @return boolean opened
function M.open_editor()
	if not require_state("open_editor") then return false end
	local ok, opened_or_err = xpcall(open_editor_impl, debug.traceback)
	if ok and opened_or_err == true then return true end
	close_webview()
	if not ok then
		Logger.error(LOG, "Paths editor open failed: %s.", tostring(opened_or_err))
	end
	return false
end





-- =========================================
-- =========================================
-- ======= 3/ Menu Item Construction =======
-- =========================================
-- =========================================






--- Builds the "Dossier de configuration…" menu item for the tray menu.
--- @return table Menu item table.
function M.build_menu_item()
	return {
		label  = i18n.get("menu.paths.menu_item"),
		action = function()
			hs.timer.doAfter(0.05, M.open_editor)
		end,
	}
end

return M
