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
local DeferredWork = require("infra.deferred_work")
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
local _webview_committed = false
local _focus_owner = nil
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

--- Persists through ConfigPaths and distinguishes a returned I/O failure from a
--- no-change success. Lua file writes normally return false rather than raise,
--- so pcall status alone is not a commit acknowledgement.
--- @param new_dir string|nil
--- @return boolean persisted
--- @return boolean|string changed_or_err
local function persist_config_dir(new_dir)
	local ok, changed, save_err = xpcall(function()
		return ConfigPaths.set_config_dir(new_dir)
	end, debug.traceback)
	if not ok then return false, changed end
	if save_err ~= nil then return false, tostring(save_err) end
	return true, changed == true
end

--- Persists a new config directory WITHOUT reloading. Used by the onboarding
--- wizard, which writes config.toml right after and reloads once at the end.
--- @param new_dir string|nil
--- @return boolean persisted
--- @return boolean|string changed_or_err
function M.persist_config_dir_for_wizard(new_dir)
	return persist_config_dir(new_dir)
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
	Logger.debug(LOG, "Folder picker completed (ok=%s, result_type=%s).", tostring(ok), type(r2))

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
--- @return boolean committed
local function close_webview()
	_focus_owner = nil
	if not _webview then
		_webview_committed = false
		_usercontent = nil
		return true
	end
	local owned = _webview
	local owned_usercontent = _usercontent
	if type(owned.delete) ~= "function" then
		Logger.error(LOG, "Paths editor close refused; owned WebView has no delete method.")
		return false
	end
	_webview_committed = false
	local ok, err = xpcall(function() owned:delete() end, debug.traceback)
	if not ok then
		-- Native deletion may synchronously deliver on_close before raising. Restore
		-- both exact owners so cancel and open requests remain retryable.
		_webview = owned
		_usercontent = owned_usercontent
		Logger.error(LOG, "Paths editor close did not commit; exact WebView retained: %s.",
			tostring(err))
		return false
	end
	if _webview == owned then _webview = nil end
	_webview_committed = false
	if _usercontent == owned_usercontent then _usercontent = nil end
	return true
end

--- Applies the new config directory and triggers a reload.
--- @param new_dir string The chosen directory (with trailing slash).
local function apply_and_reload(new_dir)
	-- The store itself is ConfigPaths.set_config_dir — the single writer. What is
	-- left here is the editor's own decision: reload afterwards, so every module
	-- picks up the new location. The wizard calls the same writer and deliberately
	-- does not reload, which is the entire difference between the two writers this
	-- replaces.
	local persisted, changed_or_err = persist_config_dir(new_dir)
	if not persisted then
		Logger.error(LOG, "Paths editor save failed: %s.", tostring(changed_or_err))
		local ok_dialog, dialog = pcall(require, "infra.dialog_util")
		if ok_dialog and dialog and type(dialog.block_alert) == "function" then
			pcall(dialog.block_alert,
				i18n.get("paths_editor.save_failed_title"),
				i18n.get("paths_editor.save_failed"),
				i18n.get("onboarding.btn.ok"))
		end
		return false
	end

	local changed = changed_or_err == true
	close_webview()

	if not changed then
		Logger.debug(LOG, "Paths editor: directory unchanged, skipping reload.")
		return true
	end

	Logger.start(LOG, "Applying new config directory and reloading…")
	local ok_reload, reload_err = xpcall(_state.reload_fn, debug.traceback)
	if not ok_reload or reload_err == false then
		Logger.error(LOG, "Paths editor reload callback failed: %s.", tostring(reload_err))
		return false
	end
	return true
end

--- Captures presentation authority separately from retained native cleanup state.
--- @return table|nil owner Exact active presentation owner.
local function capture_owner()
	if not _webview or not _focus_owner then return nil end
	return { view = _webview, controller = _usercontent, token = _focus_owner }
end

--- Checks the exact owner at each deferred or native boundary.
--- @param owner table|nil Captured presentation owner.
--- @param pending boolean|nil Whether construction may still be uncommitted.
--- @return boolean current
local function owner_is_current(owner, pending)
	return owner ~= nil and owner.view == _webview and owner.controller == _usercontent
		and owner.token == _focus_owner and (pending == true or _webview_committed == true)
		and (owner.browse == nil or owner.token.browse == owner.browse)
end

--- Reports bounded fixed metadata without paths or JavaScript payloads.
--- @param owner table Captured presentation owner.
--- @param category string Fixed failure category.
--- @param pending boolean|nil Whether an exact construction owner may report scheduling failure.
local function report_delivery_failure(owner, category, pending)
	if not owner_is_current(owner, pending) then return end
	owner.token.reported = owner.token.reported or {}
	if owner.token.reported[category] then return end
	owner.token.reported[category] = true
	Logger.error(LOG, "Paths editor delivery %s; repeats suppressed for this window.", category)
end

--- Observes both native JavaScript admission and its asynchronous execution.
--- @param owner table Captured presentation owner.
--- @param code string JavaScript source.
--- @return boolean submitted
local function submit_javascript(owner, code)
	if not owner_is_current(owner) then return false end
	local completed = false
	local ok, result = pcall(function()
		return owner.view:evaluateJavaScript(code, function(_, script_error)
			if completed then return end
			completed = true
			if script_error ~= nil then report_delivery_failure(owner, "execution failed") end
		end)
	end)
	if not ok or result ~= owner.view then
		completed = true
		report_delivery_failure(owner, ok and "submission refused" or "submission raised")
		return false
	end
	return owner_is_current(owner)
end

--- Owns deferred delivery and makes scheduling or callback failure visible.
--- @param owner table Captured presentation owner.
--- @param delay number Delay in seconds.
--- @param label string Fixed scheduler label.
--- @param callback function Owned continuation.
--- @return boolean scheduled
local function defer_delivery(owner, delay, label, callback)
	if not owner_is_current(owner, true) then return false end
	local ok, scheduled = pcall(DeferredWork.after, delay, function()
		if not owner_is_current(owner) then return end
		local ran = pcall(callback)
		if not ran then report_delivery_failure(owner, "callback raised") end
	end, label)
	if not ok or scheduled ~= true then
		report_delivery_failure(owner, "scheduling refused", true)
		return false
	end
	return owner_is_current(owner, true)
end

--- Builds the form data payload and injects it into the exact active webview.
--- @param owner table Captured presentation owner.
local function inject_init_data(owner)
	if not owner_is_current(owner) then return end
	local built, payload = pcall(function()

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

		return {
			configDir        = current_dir,
			defaultConfigDir = default_dir,
			strings          = strings,
		}
	end)
	if not built then report_delivery_failure(owner, "initialization raised"); return end

	local ok_enc, json = pcall(hs.json.encode, payload)
	if not ok_enc or type(json) ~= "string" then
		report_delivery_failure(owner, "encoding failed")
		return
	end

	Logger.debug(LOG, "Injecting initData into webview…")
	return submit_javascript(owner, "window.initData(" .. json .. ")")
end

--- Handles an incoming message from the JavaScript frontend via usercontent bridge.
--- @param body table The decoded message body.
local function handle_message(body)
	if type(body) ~= "table" then return end
	local owner = capture_owner()
	if not owner then return end
	local action = body.action
	Logger.debug(LOG, "Paths editor bridge message received.")
	if not owner_is_current(owner) then return end

	if action == "ready" then
		inject_init_data(owner)
	elseif action == "browse" then
		owner.browse = {}
		owner.token.browse = owner.browse
		defer_delivery(owner, 0, "menu_paths.browse", function()
			Logger.start(LOG, "Opening native folder picker…")
			if not owner_is_current(owner) then return end
			local picked = pick_dir(ConfigPaths.get_config_dir())
			if not owner_is_current(owner) then return end
			Logger.success(LOG, "Folder picker completed.")
			if picked and picked ~= "" then
				local encoded_ok, encoded = pcall(hs.json.encode, picked)
				if not encoded_ok or type(encoded) ~= "string" then
					report_delivery_failure(owner, "encoding failed")
					return
				end
				defer_delivery(owner, 0.1, "menu_paths.browse_result", function()
					submit_javascript(owner, "window.applyBrowseResult(" .. encoded .. ")")
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
		if _webview_committed ~= true then
			if close_webview() ~= true then return false, true end
		else
			local ok_ui = pcall(require, "ui.ui_builder")
			if ok_ui then
				local ui_builder = require("ui.ui_builder")
				local view, controller, focus_owner = _webview, _usercontent, _focus_owner
				ui_builder.force_focus(view, false, { is_current = function()
					return focus_owner ~= nil and _focus_owner == focus_owner
						and _webview == view and _usercontent == controller and _webview_committed == true
				end })
			else
				pcall(function() _webview:bringToFront() end)
			end
			return true
		end
	end

	local ok_uc, uc = pcall(hs.webview.usercontent.new, "hsPaths")
	if not ok_uc or not uc then
		Logger.error(LOG, "Failed to create webview usercontent bridge.")
		return false
	end

	uc:setCallback(function(message)
		if _webview_committed ~= true or _usercontent ~= uc then return end
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

	local candidate = nil
	local closed = false
	local focus_owner = {}
	_focus_owner = focus_owner
	local function candidate_is_owned()
		return closed ~= true and candidate ~= nil
			and _webview == candidate and _usercontent == uc and _focus_owner == focus_owner
	end
	local webview = ui_builder.show_webview({
		frame       = ui_builder.get_centered_frame(win_w, win_h),
		title       = i18n.get("menu.paths.window_title"),
		style_masks = style_masks,
		usercontent = uc,
		assets_dir    = ASSETS_DIR,
		on_close      = function()
			closed = true
			if _webview ~= candidate then return end
			_webview     = nil
			_webview_committed = false
			if _usercontent == uc then _usercontent = nil end
		end,
		on_navigation = function(action)
			if action == "didFinishNavigation" then
				if not candidate_is_owned() then return true end
				local owner = capture_owner()
				Logger.debug(LOG, "Navigation finished — injecting initData.")
				defer_delivery(owner, 0.05, "menu_paths.navigation", function() inject_init_data(owner) end)
			end
			return true
		end,
		on_webview_created = function(owned)
			if _webview ~= nil or _usercontent ~= nil then return false end
			candidate = owned
			_webview = owned
			_webview_committed = false
			_usercontent = uc
			return true
		end,
		is_current = function()
			return candidate_is_owned()
		end,
	})
	if webview == nil or webview ~= candidate or closed then
		if candidate == nil and _usercontent == uc then _usercontent = nil end
		Logger.error(LOG, "Paths editor webview could not be created.")
		return false
	end
	_webview_committed = true
	return true
end

--- Opens the paths editor as a webview form.
--- @return boolean opened
function M.open_editor()
	if not require_state("open_editor") then return false end
	local ok, opened_or_err, cleanup_attempted = xpcall(open_editor_impl, debug.traceback)
	if ok and opened_or_err == true then return true end
	if cleanup_attempted ~= true then close_webview() end
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
			DeferredWork.after(0.05, M.open_editor, "menu_paths.open_editor")
		end,
	}
end

return M
