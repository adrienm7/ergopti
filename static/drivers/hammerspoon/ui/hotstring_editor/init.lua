--- ui/hotstring_editor/init.lua

--- ==============================================================================
--- MODULE: Hotstring Editor UI
--- DESCRIPTION:
--- Provides a webview-based interface for users to create, edit, and manage
--- custom hotstrings. Handles the communication between the JS frontend and
--- the Lua backend (file I/O, config generation, and window management).
---
--- FEATURES & RATIONALE:
--- 1. Singleton Preservation: Pressing the shortcut multiple times preserves the currently open window (and any ongoing text input) by bringing it to the front, creating a new window only if it is completely closed.
--- 2. Space Teleportation & Focus: Leverages the UI builder to natively teleport the window to the active macOS space and grant it focus, while allowing other apps to overlap it when clicked.
--- 3. Centralized Creation: Window properties are managed via the ui_builder factory.
--- ==============================================================================

local M = {}

local hs            = hs
local toml_reader   = require("lib.toml_reader")
local toml_writer   = require("lib.toml_writer")
local ui_builder    = require("ui.ui_builder")
local Logger        = require("lib.logger")
local notifications = require("lib.notifications")
local LOG           = "hotstring_editor"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local CUSTOM_GROUP_NAME = "custom"
local STAR_CANONICAL    = "★"

-- Determine absolute path to the assets directory
local _src  = debug.getinfo(1, "S").source:sub(2)
local ASSETS_DIR = _src:match("^(.*[/\\])") or "./"

-- Global module state
local _toml_path       = nil
local _keymap          = nil
local _webview         = nil
local _usercontent     = nil
local _hotkey          = nil
local _is_focused      = false
local _pending_mode    = "menu"

-- Callbacks
local _update_menu     = nil
local _update_pref     = nil
local _on_focus_change = nil

-- UI Preferences
local _prefs = {
	trigger_char    = STAR_CANONICAL,
	compact_view    = false,
	auto_close      = false,
	default_section = nil,
}





-- ======================================
-- ======================================
-- ======= 2/ Data Layer & Models =======
-- ======================================
-- ======================================



-- ================================
-- ===== 2.1) File Management =====
-- ================================

--- Returns an empty TOML configuration structure for hotstrings.
--- @return table The default empty configuration.
local function empty_toml_data()
	return { 
		meta = { description = "Hotstrings personnels" },
		sections_order = {}, 
		sections = {} 
	}
end

--- Ensures the configuration file exists. Creates it with default data if missing.
local function ensure_file()
	if type(_toml_path) ~= "string" or _toml_path == "" then return end
	
	local fh = io.open(_toml_path, "r")
	if fh then 
		fh:close()
		return 
	end
	
	-- The file does not exist, safely create an empty baseline
	pcall(toml_writer.write, _toml_path, empty_toml_data())
end



-- ================================
-- ===== 2.2) Data Formatting =====
-- ================================

--- Normalizes the output string by replacing line breaks and parsing alias tokens.
--- @param s string The raw output string.
--- @return string The normalized string with explicit {Token} syntax.
local function normalise_output(s)
	if type(s) ~= "string" then return "" end
	
	s = s:gsub("\r\n", "{Enter}"):gsub("\r", "{Enter}"):gsub("\n", "{Enter}")
	
	local aliases = {
		esc="Escape", escape="Escape",
		bs="BackSpace", backspace="BackSpace",
		del="Delete",  delete="Delete",
		["return"]="Enter", enter="Enter",
		left="Left", right="Right", up="Up", down="Down",
		home="Home", ["end"]="End", tab="Tab",
	}
	
	s = s:gsub("{([^}]+)}", function(name)
		local c = aliases[name:lower()]
		return "{" .. (c or (name:sub(1,1):upper() .. name:sub(2))) .. "}"
	end)
	return s
end

--- Loads and formats data from the TOML file to be injected into the JS frontend.
--- @param open_mode string The mode in which the editor was opened ("shortcut" or "menu").
--- @return table The structured data for the JS frontend.
local function load_js_data(open_mode)
	ensure_file()
	local raw = {}
	
	if type(_toml_path) == "string" then
		local ok, parsed = pcall(toml_reader.parse, _toml_path)
		if ok and type(parsed) == "table" then raw = parsed end
	end
	
	local sections = {}
	if type(raw.sections_order) == "table" then
		for _, name in ipairs(raw.sections_order) do
			if name ~= "-" and type(raw.sections) == "table" and type(raw.sections[name]) == "table" then
				local sec = raw.sections[name]
				local entries = {}
				
				if type(sec.entries) == "table" then
					for _, e in ipairs(sec.entries) do
						table.insert(entries, {
							trigger           = type(e.trigger) == "string" and e.trigger or "",
							output            = normalise_output(e.output),
							is_word           = (e.is_word == true),
							auto_expand       = (e.auto_expand == true),
							is_case_sensitive = (e.is_case_sensitive == true),
							final_result      = (e.final_result == true),
						})
					end
				end
				
				table.insert(sections, {
					name        = name, 
					description = type(sec.description) == "string" and sec.description or name, 
					entries     = entries,
				})
			end
		end
	end
	
	return {
		sections        = sections,
		trigger_char    = _prefs.trigger_char,
		star            = STAR_CANONICAL,
		compact_view    = _prefs.compact_view,
		auto_close      = _prefs.auto_close,
		default_section = _prefs.default_section,
		open_mode       = open_mode or "menu",
	}
end

--- Converts the frontend JS state back into a TOML-compatible Lua table structure.
--- @param save_data table The data received from the JS frontend.
--- @return table The TOML-compatible structure.
local function js_to_toml(save_data)
	local data = { 
		meta = { description = "Hotstrings personnels" },
		sections_order = (type(save_data.sections_order) == "table") and save_data.sections_order or {},
		sections = {} 
	}
	
	for _, name in ipairs(data.sections_order) do
		local s = (type(save_data.sections) == "table") and save_data.sections[name] or nil
		if type(s) == "table" then
			data.sections[name] = {
				description = type(s.description) == "string" and s.description or name,
				entries     = (type(s.entries) == "table") and s.entries or {},
			}
		end
	end
	
	return data
end





-- =====================================
-- =====================================
-- ======= 3/ Bridge & Messaging =======
-- =====================================
-- =====================================



-- ============================
-- ===== 3.1) JS Updaters =====
-- ============================

--- Pushes the current state to the active Webview frontend.
local function push_update_to_webview()
	if not _webview then return end
	
	local js_data = load_js_data(_pending_mode)
	local ok_enc, json = pcall(hs.json.encode, js_data)
	
	if ok_enc and type(json) == "string" then
		pcall(function() _webview:evaluateJavaScript("if(window.updateData) window.updateData(" .. json .. ")") end)
	end
end



-- ===============================
-- ===== 3.2) Message Router =====
-- ===============================

--- Handles incoming messages/actions from the JS frontend.
--- @param msg table The message payload containing "action" and "data".
local function handle_message(msg)
	if type(msg) ~= "table" then return end
	local action, data = msg.action, msg.data

	if action == "ready" then
		if not _webview then return end
		local mode = type(msg.open_mode) == "string" and msg.open_mode or _pending_mode
		local js_data = load_js_data(mode)
		local ok_enc, json = pcall(hs.json.encode, js_data)
		
		if ok_enc and type(json) == "string" then
			pcall(function() _webview:evaluateJavaScript("if(window.initData) window.initData(" .. json .. ")") end)
		end
		return
	end

	if action == "save" then
		if type(_toml_path) ~= "string" or _toml_path == "" then return end
		
		local toml_data = js_to_toml(data)
		local ok_write, err = pcall(toml_writer.write, _toml_path, toml_data)
		
		if ok_write and err == true then
			if type(_keymap) == "table" and type(_keymap.load_toml) == "function" then
				pcall(function()
					_keymap.disable_group(CUSTOM_GROUP_NAME)
					_keymap.load_toml(CUSTOM_GROUP_NAME, _toml_path)
					_keymap.enable_group(CUSTOM_GROUP_NAME)
					if type(_keymap.sort_mappings) == "function" then _keymap.sort_mappings() end
				end)
			end
			if type(_update_menu) == "function" then hs.timer.doAfter(0, function() pcall(_update_menu) end) end
		else
			pcall(notifications.notify, "Erreur de sauvegarde", tostring(err))
		end
		return
	end

	if action == "save_pref" then
		if type(data) == "table" and type(data.key) == "string" then
			if data.key == "compact_view"    then _prefs.compact_view    = (data.value == true) end
			if data.key == "auto_close"      then _prefs.auto_close      = (data.value == true) end
			if data.key == "default_section" then _prefs.default_section = data.value end
		end
		if type(_update_pref) == "function" then pcall(_update_pref, data) end
		return
	end

	if action == "window_focus" then
		_is_focused = (type(data) == "table" and data.focused == true)
		if type(_on_focus_change) == "function" then pcall(_on_focus_change, _is_focused) end
		return
	end

	if action == "close" then 
		M.close() 
	end
end





-- ====================================
-- ====================================
-- ======= 4/ Webview Lifecycle =======
-- ====================================
-- ====================================

--- Opens the Hotstring Editor window.
--- @param open_mode string|nil The context of opening ("menu" or "shortcut").
function M.open(open_mode)
	_pending_mode = type(open_mode) == "string" and open_mode or "menu"

	-- Early return: Reuse the webview if it is already open to strictly preserve user input and focus
	-- This completely bypasses any Javascript evaluation or reloading keeping the text intact
	if _webview then
		ui_builder.force_focus(_webview)
		return
	end

	-- Initialize the User Content bridge
	local ok_uc, uc = pcall(hs.webview.usercontent.new, "hsEditor")
	if not ok_uc or not uc then
		Logger.error(LOG, "Failed to create webview usercontent bridge.")
		return
	end
	
	_usercontent = uc
	_usercontent:setCallback(function(message)
		if message and type(message.body) == "table" then
			local body = message.body
			if body.action == "ready" then body.open_mode = _pending_mode end
			handle_message(body)
		end
	end)

	-- Prepare standardized UI styles
	local masks = hs.webview.windowMasks
	local window_style = (masks["titled"] or 1) + (masks["closable"] or 2) + (masks["resizable"] or 8) + (masks["miniaturizable"] or 4)

	-- Request the webview creation/focus from the centralized UI builder
	_webview = ui_builder.show_webview({
		frame       = ui_builder.get_centered_frame(760, 640),
		title       = "Hotstrings personnels",
		style_masks = window_style,
		usercontent = _usercontent,
		assets_dir  = ASSETS_DIR,
		on_close    = function()
			_is_focused = false
			if type(_on_focus_change) == "function" then pcall(_on_focus_change, false) end
			_webview     = nil
			_usercontent = nil
		end
	})
end

--- Returns true when the editor window is currently open.
--- @return boolean
function M.is_open()
	return _webview ~= nil
end

--- Closes the Hotstring Editor window and cleans up resources.
function M.close()
	if _webview then
		if type(_webview.delete) == "function" then pcall(function() _webview:delete() end) end
		_webview     = nil
		_usercontent = nil
		_is_focused  = false
		if type(_on_focus_change) == "function" then pcall(_on_focus_change, false) end
	end
end





-- =============================
-- =============================
-- ======= 5/ Public API =======
-- =============================
-- =============================

--- Initializes the module with the necessary dependencies and file paths.
--- @param toml_path string The absolute path to the hotstrings TOML file.
--- @param keymap_mod table Reference to the keymap module for hotkey reloading.
--- @param update_menu_fn function Callback to refresh the main menu UI.
function M.init(toml_path, keymap_mod, update_menu_fn)
	_toml_path   = toml_path
	_keymap      = keymap_mod
	_update_menu = update_menu_fn
	ensure_file()
end

--- Checks if the editor window is currently open.
--- @return boolean True if open, false otherwise.
function M.is_open() 
	return _webview ~= nil 
end

--- Checks if the editor window currently has the system focus.
--- @return boolean True if focused, false otherwise.
function M.is_editor_focused()
	return _is_focused
end

--- Sets the callback for menu UI updates.
--- @param fn function The callback function.
function M.set_update_menu(fn)     _update_menu = fn     end

--- Sets the callback for preference updates.
--- @param fn function The callback function.
function M.set_update_pref(fn)     _update_pref = fn     end

--- Sets the callback triggered when the window focus changes.
--- @param fn function The callback function taking a boolean (focused).
function M.set_on_focus_change(fn) _on_focus_change = fn end

--- Sets the character used as the trigger indicator in the UI.
--- @param char string The trigger character (defaults to STAR_CANONICAL).
function M.set_trigger_char(char)
	_prefs.trigger_char = type(char) == "string" and char or STAR_CANONICAL
	push_update_to_webview()
end

--- Sets the default section to select when opened via shortcut.
--- @param section_name string|nil The target section name, or nil for main view.
function M.set_default_section(section_name)
	_prefs.default_section = type(section_name) == "string" and section_name or nil
	push_update_to_webview()
end

--- Sets whether the editor should automatically close after adding an entry via shortcut.
--- @param bool boolean True to enable auto-close.
function M.set_close_on_add(bool)
	_prefs.auto_close = (bool == true)
	push_update_to_webview()
end

--- Batch sets the UI preferences.
--- @param prefs table A table containing compact_view, auto_close, and default_section.
function M.set_ui_prefs(prefs)
	if type(prefs) ~= "table" then return end
	if type(prefs.compact_view) == "boolean" then _prefs.compact_view    = prefs.compact_view    end
	if type(prefs.auto_close)   == "boolean" then _prefs.auto_close      = prefs.auto_close      end
	if type(prefs.default_section) == "string" or prefs.default_section == nil then 
		_prefs.default_section = prefs.default_section 
	end
end



-- ====================================
-- ===== 5.1) Shortcut Management =====
-- ====================================

--- Binds a global hotkey to open the editor.
--- @param mods table Array of modifier keys (e.g., {"cmd", "alt"}).
--- @param key string The character key.
function M.set_shortcut(mods, key)
	M.clear_shortcut()
	if type(mods) == "table" and type(key) == "string" and key ~= "" then
		-- Toggle: close the editor if already open, otherwise open it.
		local ok, hk = pcall(hs.hotkey.new, mods, key, function()
			if _webview then M.close() else M.open("shortcut") end
		end)
		if ok and hk then
			_hotkey = hk
			pcall(function() _hotkey:enable() end)
		end
	end
end

--- Unbinds the global hotkey if set.
function M.clear_shortcut()
	if _hotkey then 
		if type(_hotkey.delete) == "function" then pcall(function() _hotkey:delete() end) end
		_hotkey = nil 
	end
end

return M
