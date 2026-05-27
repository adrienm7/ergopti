--- modules/gestures/actions.lua

--- ==============================================================================
--- MODULE: Gestures Actions Registry
--- DESCRIPTION:
--- Maps internal logic representations to human-readable labels and concrete
--- Hammerspoon actions (keystrokes, system events, etc.).
--- ==============================================================================

local M = {}

local hs            = hs
local notifications = require("lib.notifications")
local Logger        = require("lib.logger")
local i18n          = require("lib.i18n")
local LOG           = "gestures.actions"

local _state = nil

--- Binds the global shared state reference.
--- @param core_state table The shared state object from the core module.
function M.init(core_state)
	_state = core_state
end





-- =========================================
-- =========================================
-- ======= 1/ Low-Level Key Helpers ========
-- =========================================
-- =========================================

--- Sends a system-level media or hardware key event.
--- @param key string The hardware key name (e.g. "SOUND_UP").
local function sysKey(key)
	pcall(function() hs.eventtap.event.newSystemKeyEvent(key, true):post() end)
	pcall(function() hs.eventtap.event.newSystemKeyEvent(key, false):post() end)
end

--- Simulates a keystroke with optional modifiers.
--- @param mods table List of modifiers (e.g. {"cmd", "shift"}).
--- @param key string The key code or character.
local function postKeyStroke(mods, key)
	pcall(function() hs.eventtap.keyStroke(mods, key, 0) end)
end





-- ===================================
-- ===================================
-- ======= 2/ Action Registry ========
-- ===================================
-- ===================================

local AX = {} -- Axis actions (continuous/scalable)
local SG = {} -- Single actions (discrete)

--- Registers an axis-based action (scalable).
local function ax(name, prev_fn, next_fn, scalable)
	AX[name] = { prev = prev_fn, next = next_fn, scalable = scalable }
end

--- Registers a discrete single-fire action.
local function sg(name, fn)
	SG[name] = { fn = fn }
end

--- Switch to the previous application in the MRU list.
local function switch_to_previous_application()
    local ok, kl = pcall(require, "modules.karabiner.ke_lifecycle")
    if ok and kl and type(kl.switch_to_previous_app) == "function" then
        pcall(kl.switch_to_previous_app)
    else
        pcall(hs.eventtap.keyStroke, {"cmd"}, "tab")
    end
end

--- Switch to the previous window precisely (same app or other).
local function switch_to_previous_window_precise()
    local ok, kl = pcall(require, "modules.karabiner.ke_lifecycle")
    if ok and kl and type(kl.switch_to_previous_window) == "function" then
        pcall(kl.switch_to_previous_window)
    else
        pcall(hs.eventtap.keyStroke, {"cmd"}, "tab")
    end
end

--- Triggers a macOS system-wide dictionary lookup/definition.
function M.trigger_lookup()
	local pos = hs.mouse.absolutePosition()
	pcall(function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.rightMouseDown, pos):post() end)
	pcall(function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.rightMouseUp, pos):post() end)
	hs.timer.doAfter(0.05, function()
		pcall(function() hs.eventtap.keyStroke({"cmd", "ctrl"}, "d") end)
	end)
end

-- Delay to ignore the spurious mouseUp from the gesture's own finger-lift.
local CLICK_COOLDOWN_SEC = 0.15

local rightClickHeld    = false
local leftClickHeld     = false
local rightMouseTap     = nil
local leftMouseTap      = nil
local click_key_watcher = nil

--- Stops the keyboard watcher that auto-releases held clicks on any keypress.
local function stop_click_key_watcher()
	if not click_key_watcher then return end
	pcall(function() click_key_watcher:stop() end)
	click_key_watcher = nil
end

--- Starts a keyboard watcher that releases all held synthetic clicks on the next keydown.
local function start_click_key_watcher()
	if click_key_watcher then return end
	click_key_watcher = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(_)
		local pos = hs.mouse.absolutePosition()
		if leftClickHeld then
			if leftMouseTap then pcall(function() leftMouseTap:stop() end); leftMouseTap = nil end
			pcall(function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseUp, pos):post() end)
			leftClickHeld = false
			Logger.info(LOG, "Synthetic Left-Click RELEASED by keydown.")
		end
		if rightClickHeld then
			if rightMouseTap then pcall(function() rightMouseTap:stop() end); rightMouseTap = nil end
			pcall(function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.rightMouseUp, pos):post() end)
			rightClickHeld = false
			Logger.info(LOG, "Synthetic Right-Click RELEASED by keydown.")
		end
		pcall(function() click_key_watcher:stop() end)
		click_key_watcher = nil
		return false
	end)
	pcall(function() click_key_watcher:start() end)
end

function M.force_cleanup()
	Logger.debug(LOG, "Forcefully releasing all held clicks…")
	stop_click_key_watcher()
	local pos = hs.mouse.absolutePosition()
	if leftMouseTap  then pcall(function() leftMouseTap:stop()  end); leftMouseTap  = nil end
	if rightMouseTap then pcall(function() rightMouseTap:stop() end); rightMouseTap = nil end
	if leftClickHeld then
		pcall(function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseUp,  pos):post() end)
		leftClickHeld = false
		Logger.info(LOG, "Synthetic Left-Click forcefully released.")
	end
	if rightClickHeld then
		pcall(function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.rightMouseUp, pos):post() end)
		rightClickHeld = false
		Logger.info(LOG, "Synthetic Right-Click forcefully released.")
	end
end

function M.toggle_right_click()
	if rightClickHeld then
		if rightMouseTap then pcall(function() rightMouseTap:stop() end); rightMouseTap = nil end
		pcall(function()
			hs.eventtap.event.newMouseEvent(
				hs.eventtap.event.types.rightMouseUp, hs.mouse.absolutePosition()
			):post()
		end)
		rightClickHeld = false
		Logger.info(LOG, "Synthetic Right-Click RELEASED.")
		if not leftClickHeld then stop_click_key_watcher() end
		return
	end

	Logger.debug(LOG, "Enabling right-click hold mode…")
	pcall(function()
		local ev = hs.eventtap.event.newMouseEvent(
			hs.eventtap.event.types.rightMouseDown, hs.mouse.absolutePosition()
		)
		-- HID-sourced so the event reaches title bars and WindowServer-managed areas.
		pcall(function() ev:setProperty(hs.eventtap.event.properties.eventSourceStateID, 1) end)
		ev:post()
	end)
	rightClickHeld = true
	start_click_key_watcher()

	local t0       = hs.timer.secondsSinceEpoch()
	local evTypes  = hs.eventtap.event.types
	rightMouseTap  = hs.eventtap.new({ evTypes.mouseMoved, evTypes.rightMouseUp }, function(e)
		local t = e:getType()
		if t == evTypes.rightMouseUp then
			-- Swallow the spurious finger-lift mouseUp within the cooldown window.
			if hs.timer.secondsSinceEpoch() - t0 < CLICK_COOLDOWN_SEC then return true end
			hs.timer.doAfter(0, M.toggle_right_click)
			return true
		end
		-- Convert idle mouseMoved to rightMouseDragged for apps that need it.
		if t == evTypes.mouseMoved then
			pcall(function()
				hs.eventtap.event.newMouseEvent(evTypes.rightMouseDragged, e:location()):post()
			end)
			return false
		end
		return false
	end)
	if rightMouseTap then pcall(function() rightMouseTap:start() end) end
	Logger.info(LOG, "Synthetic Right-Click HELD.")
end

function M.toggle_left_click()
	if leftClickHeld then
		if leftMouseTap then pcall(function() leftMouseTap:stop() end); leftMouseTap = nil end
		pcall(function()
			hs.eventtap.event.newMouseEvent(
				hs.eventtap.event.types.leftMouseUp, hs.mouse.absolutePosition()
			):post()
		end)
		leftClickHeld = false
		Logger.info(LOG, "Synthetic Left-Click RELEASED.")
		if not rightClickHeld then stop_click_key_watcher() end
		return
	end

	Logger.debug(LOG, "Enabling left-click hold mode…")
	pcall(function()
		local ev = hs.eventtap.event.newMouseEvent(
			hs.eventtap.event.types.leftMouseDown, hs.mouse.absolutePosition()
		)
		-- HID-sourced so the event reaches title bars and WindowServer-managed areas.
		pcall(function() ev:setProperty(hs.eventtap.event.properties.eventSourceStateID, 1) end)
		ev:post()
	end)
	leftClickHeld = true
	start_click_key_watcher()

	local t0      = hs.timer.secondsSinceEpoch()
	local evTypes = hs.eventtap.event.types
	leftMouseTap  = hs.eventtap.new({ evTypes.mouseMoved, evTypes.leftMouseUp }, function(e)
		local t = e:getType()
		if t == evTypes.leftMouseUp then
			-- Swallow the spurious finger-lift mouseUp within the cooldown window.
			if hs.timer.secondsSinceEpoch() - t0 < CLICK_COOLDOWN_SEC then return true end
			hs.timer.doAfter(0, M.toggle_left_click)
			return true
		end
		-- Convert mouseMoved to leftMouseDragged so apps see a proper drag event.
		if t == evTypes.mouseMoved then
			pcall(function()
				hs.eventtap.event.newMouseEvent(evTypes.leftMouseDragged, e:location()):post()
			end)
			return false
		end
		return false
	end)
	if leftMouseTap then pcall(function() leftMouseTap:start() end) end
	Logger.info(LOG, "Synthetic Left-Click HELD.")
end

local function show_application_switcher_overlay()
    pcall(hs.eventtap.keyStroke, {"cmd"}, "tab")
end

--- Navigates between windows of the current application.
local function winNav(goNext)
	local key = goNext and "`" or "~"
	pcall(function() hs.eventtap.keyStroke({"cmd"}, key) end)
end

--- Navigates between macOS Spaces (Desktops).
local function spaceNav(goNext)
	local key_code = goNext and 124 or 123 -- 124=Right, 123=Left
	pcall(hs.osascript.applescript, string.format(
		"tell application \"System Events\" to key code %d using {control down}",
		key_code
	))
end

local CMD_LETTERS = {
	"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
	"n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
}

-- Axis actions (prev / next)
ax("tabs",       
	function() pcall(hs.eventtap.keyStroke, {"ctrl", "shift"}, "tab") end,
	function() pcall(hs.eventtap.keyStroke, {"ctrl"}, "tab") end, true)

ax("char",       
	function() postKeyStroke({}, "left") end,
	function() postKeyStroke({}, "right") end, true)

ax("char_sel",   
	function() postKeyStroke({"shift"}, "left") end,
	function() postKeyStroke({"shift"}, "right") end, true)

ax("line_arrow", 
	function() postKeyStroke({}, "up") end,
	function() postKeyStroke({}, "down") end, true)

ax("line_sel",   
	function() postKeyStroke({"shift"}, "up") end,
	function() postKeyStroke({"shift"}, "down") end, true)

ax("words",      
	function() postKeyStroke({"alt"}, "left") end,
	function() postKeyStroke({"alt"}, "right") end, true)

ax("words_sel",  
	function() postKeyStroke({"shift", "alt"}, "left") end,
	function() postKeyStroke({"shift", "alt"}, "right") end, true)

ax("windows",    
	function() winNav(false) end, 
	function() winNav(true) end)

ax("spaces",     
	function() spaceNav(false) end, 
	function() spaceNav(true) end)

ax("volume",     
	function() sysKey("SOUND_DOWN") end, 
	function() sysKey("SOUND_UP") end, true)

ax("brightness", 
	function() sysKey("BRIGHTNESS_DOWN") end, 
	function() sysKey("BRIGHTNESS_UP") end, true)

ax("tracks",     
	function() sysKey("PREVIOUS") end, 
	function() sysKey("NEXT") end)

ax("lines",      
	function() hs.timer.doAfter(0, function() pcall(hs.eventtap.keyStroke, {"alt"}, "up") end) end,
	function() hs.timer.doAfter(0, function() pcall(hs.eventtap.keyStroke, {"alt"}, "down") end) end, true)

ax("line_bounds",
	function() hs.timer.doAfter(0, function() pcall(hs.eventtap.keyStroke, {"cmd"}, "left") end) end,
	function() hs.timer.doAfter(0, function() pcall(hs.eventtap.keyStroke, {"cmd"}, "right") end) end)

ax("paragraphs", 
	function() pcall(hs.eventtap.keyStroke, {"alt"}, "up") end,
	function() pcall(hs.eventtap.keyStroke, {"alt"}, "down") end, true)

ax("document",   
	function() pcall(hs.eventtap.keyStroke, {"cmd"}, "up") end,
	function() pcall(hs.eventtap.keyStroke, {"cmd"}, "down") end)

-- Single actions
sg("none",                         function() end)

-- Selection & navigation cursor
sg("left_click_toggle",   M.toggle_left_click)
sg("right_click_toggle",   M.toggle_right_click)
sg("lookup",               M.trigger_lookup)
sg("app_switcher",      show_application_switcher_overlay)
sg("app_previous",      switch_to_previous_application)
sg("app_window_previous",  switch_to_previous_window_precise)

-- Keys
sg("enter",                           function() pcall(hs.eventtap.keyStroke, {}, "return") end)
sg("tab",                                function() pcall(hs.eventtap.keyStroke, {}, "tab") end)
sg("escape",                           function() pcall(hs.eventtap.keyStroke, {}, "escape") end)
sg("backspace",               function() pcall(hs.eventtap.keyStroke, {}, "delete") end)
sg("delete",                    function() pcall(hs.eventtap.keyStroke, {}, "forwarddelete") end)

-- Tabs
sg("tab_new",                  function() pcall(hs.eventtap.keyStroke, {"cmd"}, "t") end)
sg("tab_close",                function() pcall(hs.eventtap.keyStroke, {"cmd"}, "w") end)
sg("tab_prev",              function() pcall(hs.eventtap.keyStroke, {"ctrl", "shift"}, "tab") end)
sg("tab_next",                function() pcall(hs.eventtap.keyStroke, {"ctrl"}, "tab") end)

-- Windows & Spaces
sg("win_prev",            function() winNav(false) end)
sg("win_next",              function() winNav(true) end)
sg("close_window",         function() pcall(hs.eventtap.keyStroke, {"cmd"}, "w") end)
sg("fullscreen",                 function() pcall(hs.eventtap.keyStroke, {"cmd", "ctrl"}, "f") end)
sg("snap_left",              function()
	local win = hs.window.focusedWindow()
	if win then pcall(function() win:moveToUnit(hs.layout.left50) end) end
end)
sg("snap_right",             function()
	local win = hs.window.focusedWindow()
	if win then pcall(function() win:maximize() end) end
end)
sg("maximize",                     function()
	local win = hs.window.focusedWindow()
	if win then pcall(function() win:maximize() end) end
end)
sg("space_prev",             function() spaceNav(false) end)
sg("space_next",               function() spaceNav(true) end)
sg("mission_control",        function() pcall(hs.osascript.applescript, "tell application \"System Events\" to key code 160") end)
sg("app_expose",                  function() pcall(hs.osascript.applescript, "tell application \"System Events\" to key code 125 using {control down}") end)

-- Cursor movement
sg("word_prev",                function() postKeyStroke({"alt"}, "left") end)
sg("word_next",                  function() postKeyStroke({"alt"}, "right") end)
sg("line_up",               function() hs.timer.doAfter(0, function() pcall(hs.eventtap.keyStroke, {"alt"}, "up") end) end)
sg("line_down",               function() hs.timer.doAfter(0, function() pcall(hs.eventtap.keyStroke, {"alt"}, "down") end) end)
sg("line_start",              function() hs.timer.doAfter(0, function() pcall(hs.eventtap.keyStroke, {"cmd"}, "left") end) end)
sg("line_end",                  function() hs.timer.doAfter(0, function() pcall(hs.eventtap.keyStroke, {"cmd"}, "right") end) end)
sg("para_prev",         function() pcall(hs.eventtap.keyStroke, {"alt"}, "up") end)
sg("para_next",           function() pcall(hs.eventtap.keyStroke, {"alt"}, "down") end)
sg("doc_start",            function() pcall(hs.eventtap.keyStroke, {"cmd"}, "up") end)
sg("doc_end",                function() pcall(hs.eventtap.keyStroke, {"cmd"}, "down") end)

-- Media
sg("vol_up",                        function() sysKey("SOUND_UP") end)
sg("vol_down",                      function() sysKey("SOUND_DOWN") end)
sg("mute",                       function() sysKey("MUTE") end)
sg("brightness_up",             function() sysKey("BRIGHTNESS_UP") end)
sg("brightness_down",           function() sysKey("BRIGHTNESS_DOWN") end)
sg("track_play",               function() sysKey("PLAY") end)
sg("track_next",              function() sysKey("NEXT") end)
sg("track_prev",            function() sysKey("PREVIOUS") end)

-- Single arrows
sg("arrow_up",                   function() postKeyStroke({}, "up") end)
sg("arrow_down",                  function() postKeyStroke({}, "down") end)
sg("arrow_left",               function() postKeyStroke({}, "left") end)
sg("arrow_right",              function() postKeyStroke({}, "right") end)

-- Shift + Arrows
sg("sel_up",                  function() postKeyStroke({"shift"}, "up") end)
sg("sel_down",                 function() postKeyStroke({"shift"}, "down") end)
sg("sel_left",              function() postKeyStroke({"shift"}, "left") end)
sg("sel_right",             function() postKeyStroke({"shift"}, "right") end)

-- Shift + Alt + Arrows (Word selection)
sg("sel_word_prev",     function() postKeyStroke({"shift", "alt"}, "left") end)
sg("sel_word_next",       function() postKeyStroke({"shift", "alt"}, "right") end)

-- System
sg("screenshot_window_clipboard",     function() pcall(hs.execute, "screencapture -cw") end)
sg("screenshot_window_save",          function() pcall(hs.execute, "screencapture -w ~/Pictures/screenshots/win_$(date +%Y%m%d%H%M%S).png") end)
sg("screenshot_region_clipboard",      function() pcall(hs.execute, "screencapture -ci") end)
sg("screenshot_region_save",           function() pcall(hs.execute, "screencapture -i ~/Pictures/screenshots/reg_$(date +%Y%m%d%H%M%S).png") end)
sg("screenshot_fullscreen_clipboard",   function() pcall(hs.execute, "screencapture -c") end)
sg("screenshot_fullscreen_save",        function() pcall(hs.execute, "screencapture ~/Pictures/screenshots/full_$(date +%Y%m%d%H%M%S).png") end)

sg("lock_screen",                    function() pcall(hs.caffeinate.lockScreen) end)
sg("notification_center",          function() pcall(hs.osascript.applescript, "tell application \"System Events\" to click menu bar item \"Notification Center\" of menu bar 1 of application process \"ControlCenter\"") end)

-- Applications and Stats
sg("open_metrics_typing",            function() pcall(function() require("ui.metrics_overlay").toggle("typing") end) end)
sg("open_metrics_apps",        function() pcall(function() require("ui.metrics_overlay").toggle("apps") end) end)
sg("open_hotstrings_editor",    function() pcall(function() require("ui.hotstrings_editor").show() end) end)
sg("open_paths_editor",            function() pcall(function() require("ui.paths_editor").show() end) end)
sg("open_script_source",               function() pcall(hs.execute, string.format("open %q", hs.configdir)) end)
sg("open_personal_shortcuts",     function() pcall(hs.execute, string.format("open %q/personal_shortcuts.toml", hs.configdir)) end)
sg("open_personal_hotstrings",    function()
	local ok_mp, mp = pcall(require, "ui.menu.menu_paths")
	local p = ok_mp and type(mp.get) == "function" and mp.get("PersonalTomlPath")
	if p and p ~= "" then pcall(hs.execute, string.format("open %q", p))
	else pcall(hs.execute, string.format("open %q/hotstrings/personal_hotstrings.toml", hs.configdir)) end
end)
sg("open_personal_info",               function() pcall(hs.execute, string.format("open %q/personal_info.toml", hs.configdir)) end)
sg("open_config",                    function() pcall(hs.execute, string.format("open %q/config.toml", hs.configdir)) end)
sg("open_logs_folder",                function() pcall(hs.execute, string.format("open %q/logs", hs.configdir)) end)
sg("open_today_log",                   function()
	local ok_p, path = pcall(function()
		local ok_u, utils = pcall(require, "lib.utils")
		if ok_u and type(utils.get_logs_dir) == "function" then
			return utils.get_logs_dir() .. "ErgoptiPlus_" .. os.date("%Y-%m-%d") .. ".log"
		end
		return hs.configdir .. "/logs/ErgoptiPlus_" .. os.date("%Y-%m-%d") .. ".log"
	end)
	pcall(hs.execute, string.format("open %q", path))
end)

-- Script management
sg("script_pause_toggle",     function()
	local ok, sc = pcall(require, "modules.shortcuts.script_control")
	if ok and type(sc.toggle) == "function" then pcall(sc.toggle) end
end)
sg("script_reload",                       function() pcall(hs.reload) end)
sg("script_save_reload",      function()
	pcall(hs.eventtap.keyStroke, {"cmd"}, "s")
	hs.timer.doAfter(0.3, function() pcall(hs.reload) end)
end)
sg("script_quit",                         function()
	pcall(function() hs.closeConsole() end)
	pcall(function() hs.timer.doAfter(0.1, function() os.exit(0) end) end)
end)

-- Debug
sg("open_console",                        function() pcall(hs.openConsole) end)

-- Cmd letter shortcuts
for _, letter in ipairs(CMD_LETTERS) do
	local upper = string.upper(letter)
	sg("cmd_" .. letter,
		"⌘ " .. upper .. " — Cmd+" .. upper,
		function() pcall(hs.eventtap.keyStroke, {"cmd"}, letter) end)
end

for _, letter in ipairs(CMD_LETTERS) do
	local upper = string.upper(letter)
	sg("cmd_shift_" .. letter,
		"⌘⇧ " .. upper .. " — Cmd+Shift+" .. upper,
		function() pcall(hs.eventtap.keyStroke, {"cmd", "shift"}, letter) end)
end

-- Ctrl letter shortcuts (macOS)
for _, letter in ipairs(CMD_LETTERS) do
	local upper = string.upper(letter)
	sg("hs_ctrl_" .. letter,
		"^ " .. upper .. " — Ctrl+" .. upper,
		function() pcall(hs.eventtap.keyStroke, {"ctrl"}, letter) end)
end

for _, letter in ipairs(CMD_LETTERS) do
	local upper = string.upper(letter)
	sg("hs_ctrl_shift_" .. letter,
		"^⇧ " .. upper .. " — Ctrl+Shift+" .. upper,
		function() pcall(hs.eventtap.keyStroke, {"ctrl", "shift"}, letter) end)
end

-- Option (alt) letter shortcuts (macOS)
for _, letter in ipairs(CMD_LETTERS) do
	local upper = string.upper(letter)
	sg("hs_option_" .. letter,
		"⌥ " .. upper .. " — Option+" .. upper,
		function() pcall(hs.eventtap.keyStroke, {"alt"}, letter) end)
end

-- Digit shortcuts: cmd_0..9, hs_ctrl_0..9, hs_option_0..9
local DIGITS = {"0","1","2","3","4","5","6","7","8","9"}
for _, d in ipairs(DIGITS) do
	sg("cmd_"        .. d, "⌘ " .. d .. " — Cmd+"    .. d, function() pcall(hs.eventtap.keyStroke, {"cmd"},          d) end)
	sg("hs_ctrl_"    .. d, "^ " .. d .. " — Ctrl+"   .. d, function() pcall(hs.eventtap.keyStroke, {"ctrl"},         d) end)
	sg("hs_option_"  .. d, "⌥ " .. d .. " — Option+" .. d, function() pcall(hs.eventtap.keyStroke, {"alt"},          d) end)
end

-- Special key shortcuts: space, enter, period, comma
local HS_SPECIAL_KEYS = {
	{id = "space",  key = "space",  label = "Espace"},
	{id = "enter",  key = "return", label = i18n.get("common.key_enter")},
	{id = "period", key = ".",      label = "Point"},
	{id = "comma",  key = ",",      label = "Virgule"},
}
for _, sk in ipairs(HS_SPECIAL_KEYS) do
	sg("cmd_"       .. sk.id, function() pcall(hs.eventtap.keyStroke, {"cmd"},  sk.key) end)
	sg("hs_ctrl_"   .. sk.id, function() pcall(hs.eventtap.keyStroke, {"ctrl"}, sk.key) end)
	sg("hs_option_" .. sk.id, function() pcall(hs.eventtap.keyStroke, {"alt"},  sk.key) end)
end





-- =============================
--- =============================
-- ======= 3/ Public API =======
--- =============================
-- =============================

-- Hard-coded action labels — same in every locale (symbols + universal terms).
-- app_expose and mission_control are intentionally absent: they vary by language
-- and are served from the locale JSON.
local LABELS = {
	-- SG actions
	none                             = "∅ Disabled",
	left_click_toggle                = "🖱 L Left click (hold)",
	right_click_toggle               = "🖱 R Right click (hold)",
	lookup                           = "🔍 Word definition",
	app_switcher                     = "⇥ Alt+Tab — Previous app",
	app_previous                     = "⇥ ← Alt+Tab — Prev. app",
	app_window_previous              = "⇥ ◱ ← Alt+Tab — Prev. window",
	copy                             = "⎘ Copy",
	paste                            = "⎘ Paste",
	cut                              = "⎘ Cut",
	undo                             = "↩ Undo",
	redo                             = "↪ Redo",
	select_all                       = "⬚ Select all",
	find                             = "🔍 Find",
	enter                            = "↵ Enter",
	tab                              = "⇥ Tab",
	escape                           = "⎋ Escape",
	backspace                        = "⌫ Backspace",
	delete                           = "⌦ Delete",
	tab_new                          = "⧉ + New tab",
	tab_close                        = "⧉ × Close tab",
	tab_prev                         = "⧉ ← Previous tab",
	tab_next                         = "⧉ → Next tab",
	nav_back                         = "← Back (navigation)",
	nav_forward                      = "→ Forward (navigation)",
	win_prev                         = "◱ ← Previous window",
	win_next                         = "◱ → Next window",
	win_app_prev                     = "◱ ← Prev. window (same app)",
	win_app_next                     = "◱ → Next window (same app)",
	close_window                     = "◱ × Close window",
	fullscreen                       = "📺 Fullscreen",
	snap_left                        = "◧ ← Snap left",
	snap_right                       = "◨ → Snap right",
	maximize                         = "🔲 Maximize",
	space_prev                       = "▢ ← Previous Space",
	space_next                       = "▢ → Next Space",
	desktop_prev                     = "▢ ← Previous desktop",
	desktop_next                     = "▢ → Next desktop",
	desktop_new                      = "▢ + New desktop",
	desktop_close                    = "▢ × Close desktop",
	task_view                        = "▢ Task View",
	minimize_all                     = "◱ Minimize all",
	word_prev                        = "W ← Previous word",
	word_next                        = "W → Next word",
	line_up                          = "↕ ↑ Previous line",
	line_down                        = "↕ ↓ Next line",
	line_start                       = "⇤ Line start",
	line_end                         = "⇥ Line end",
	para_prev                        = "¶ ↑ Previous paragraph",
	para_next                        = "¶ ↓ Next paragraph",
	doc_start                        = "⤒ Document start",
	doc_end                          = "⤓ Document end",
	arrow_up                         = "↑ Arrow Up",
	arrow_down                       = "↓ Arrow Down",
	arrow_left                       = "← Arrow Left",
	arrow_right                      = "→ Arrow Right",
	sel_up                           = "✎ ↑ Select Up",
	sel_down                         = "✎ ↓ Select Down",
	sel_left                         = "✎ ← Select Left",
	sel_right                        = "✎ → Select Right",
	sel_word_prev                    = "✎ W ← Sel. prev. word",
	sel_word_next                    = "✎ W → Sel. next word",
	vol_up                           = "🔊 + Volume +",
	vol_down                         = "🔊 - Volume -",
	mute                             = "🔇 Mute/Unmute",
	brightness_up                    = "☀ + Brightness +",
	brightness_down                  = "☀ - Brightness -",
	track_play                       = "⏯ Play/Pause",
	track_next                       = "⏭ Next track",
	track_prev                       = "⏮ Previous track",
	screenshot_window_clipboard      = "📸 ⊞ Copy window",
	screenshot_window_save           = "📸 ⊞ Save window",
	screenshot_region_clipboard      = "📸 ⬚ Copy region",
	screenshot_region_save           = "📸 ⬚ Save region",
	screenshot_fullscreen_clipboard  = "📸 🖥 Copy screen",
	screenshot_fullscreen_save       = "📸 🖥 Save screen",
	screen_record                    = "⏺ Screen recording",
	lock_screen                      = "🔒 Lock screen",
	notification_center              = "🔔 Notifications",
	open_metrics_typing              = "📊 Typing stats",
	open_metrics_apps                = "📊 App stats",
	open_hotstrings_editor           = "⌨ Hotstrings editor",
	open_paths_editor                = "📂 Paths editor",
	open_script_source               = "🛠 Source code",
	open_personal_shortcuts          = "👤 Personal shortcuts",
	open_personal_hotstrings         = "👤 Personal hotstrings",
	open_personal_info               = "👤 Personal info",
	open_config                      = "⚙ Configuration",
	open_logs_folder                 = "📁 Logs folder",
	open_today_log                   = "📄 Today's log",
	script_pause_toggle              = "⏸/▶ Suspend / Resume",
	script_reload                    = "↻ Reload",
	script_save_reload               = "↻ Save and reload",
	script_quit                      = "✕ Quit",
	select_line                      = "☰ Select line",
	screen_capture                   = "📸 Selective capture (Win+Shift+S)",
	screen_capture_instant           = "📸 Instant capture (window)",
	open_url                         = "🌐 Open a link (configurable)",
	pick_color                       = "🎨 HEX colour under cursor",
	take_note                        = "📝 Take a note",
	activity_simulation              = "🖱 Simulate activity (anti-sleep)",
	surround_parens                  = "() Surround with parentheses",
	search_web                       = "🔍 Web search (configurable)",
	teleport_mouse                   = "🖱 Teleport mouse",
	uppercase_selection              = "AA Uppercase / lowercase",
	titlecase_selection              = "Aa Title case",
	spotlight_mouse                  = "🔦 Mouse spotlight",
	toggle_capslock                  = "⇪ Toggle CapsLock",
	microsoft_bold                   = "𝐁 Ctrl+B Microsoft (→ Ctrl+G)",
	paste_plain                      = "⎘ Paste without formatting",
	open_console                     = "▤ Console",
	open_window_spy                  = "Window Spy",
	open_list_vars                   = "Variable state",
	open_key_history                 = "Key history",
	-- AX actions
	["ax.tabs"]                      = "⧉ Tabs",
	["ax.char"]                      = "A Characters",
	["ax.char_sel"]                  = "✎ A Sel. Characters",
	["ax.line_arrow"]                = "↕ Lines (Arrows)",
	["ax.line_sel"]                  = "✎ ↕ Sel. Lines",
	["ax.words"]                     = "W Words",
	["ax.words_sel"]                 = "✎ W Sel. Words",
	["ax.windows"]                   = "◱ Windows",
	["ax.spaces"]                    = "▢ Spaces",
	["ax.desktops"]                  = "▢ Desktops",
	["ax.volume"]                    = "🔊 Volume",
	["ax.brightness"]                = "☀ Brightness",
	["ax.tracks"]                    = "♫ Tracks",
	["ax.lines"]                     = "↕ Lines (Alt)",
	["ax.line_bounds"]               = "↔ Line (start/end)",
	["ax.paragraphs"]                = "¶ Paragraphs",
	["ax.document"]                  = "📄 Document (start/end)",
}

-- Path to the shared gesture_actions.toml, resolved relative to this file.
-- actions.lua lives at static/ergopti_plus/macos/modules/gestures/actions.lua
-- so we climb 3 levels to reach ergopti_plus/, then enter shared/.
local _self_path = (debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./")
local _shared_toml = _self_path .. "../../../shared/actions.toml"

--- Parses the shared actions.toml using a lightweight line-by-line reader.
--- Returns { sg_order = [...], ax_order = [...], sg_actions = {name={platform=...}}, ax_actions = {name={platform=...}} }
local function load_shared_actions(path)
	local result = { sg_order = {}, ax_order = {}, sg_actions = {}, ax_actions = {} }
	local ok, f = pcall(io.open, path, "r")
	if not ok or not f then
		Logger.warn("gestures.actions", "Shared actions TOML not found: %s — using fallback.", tostring(path))
		return nil
	end

	local current_section = nil
	local current_key     = nil
	local in_array        = false
	local array_buf       = {}
	local current_action  = nil  -- e.g. "sg_actions.left_click_toggle"

	for line in f:lines() do
		local trimmed = line:match("^%s*(.-)%s*$")

		-- Skip blank lines and comments
		if trimmed == "" or trimmed:sub(1, 1) == "#" then goto continue end

		-- Multi-line array continuation
		if in_array then
			if trimmed:sub(1, 1) == "]" then
				-- End of array
				if current_section == "sg_order" then
					result.sg_order = array_buf
				elseif current_section == "ax_order" then
					result.ax_order = array_buf
				end
				in_array  = false
				array_buf = {}
			else
				-- Collect array items: strip trailing comma and quotes
				local item = trimmed:match('^"(.-)"')
				if item then array_buf[#array_buf + 1] = item end
			end
			goto continue
		end

		-- Section header [name] or [name.subkey]
		local section = trimmed:match("^%[([^%[%]]+)%]$")
		if section then
			current_section = section
			current_action  = nil
			-- Pre-create entry for known action sections
			local kind, name = section:match("^(sg_actions)%.(.+)$")
			if not kind then kind, name = section:match("^(ax_actions)%.(.+)$") end
			if kind and name then
				current_action = section
				result[kind][name] = result[kind][name] or {}
			end
			goto continue
		end

		-- Key = value
		local key, val = trimmed:match("^([%w_]+)%s*=%s*(.+)$")
		if key and val then
			-- Unquote string values
			local str_val = val:match('^"(.-)"$') or val
			-- Array opening without closing on same line
			if val:sub(1, 1) == "[" and not val:find("]", 2, true) then
				current_key = key
				in_array    = true
				array_buf   = {}
			elseif current_action then
				-- Store attribute of current [sg_actions.X] or [ax_actions.X]
				local kind, name = current_action:match("^(sg_actions)%.(.+)$")
				if not kind then kind, name = current_action:match("^(ax_actions)%.(.+)$") end
				if kind and name then
					result[kind][name][key] = str_val
				end
			end
		end

		::continue::
	end
	f:close()
	return result
end

local _shared = load_shared_actions(_shared_toml)

--- Builds a picker-order list from the shared TOML, keeping only entries
--- matching the given platform ("hs") plus sentinels ("--", "#…").
--- Placeholder keys (_cmd_placeholder, _cmd_shift_placeholder) are replaced
--- inline with the dynamically-registered cmd_* / cmd_shift_* names.
local function build_sg_names(shared)
	if not shared then
		-- Fallback: keep previous hard-coded list intact via inline table
		return nil
	end
	local out = {}
	for _, item in ipairs(shared.sg_order) do
		-- Sentinels and headers always pass through (TOML uses "--" and "#…")
		if item == "--" then
			out[#out + 1] = "-"
		elseif item:sub(1, 1) == "#" then
			-- Header key from TOML: "#mouse_nav" -> translated section title
			local key_suffix = item:sub(2)
			local i18n_key   = "sg_actions.sg_order.header." .. key_suffix
			local translated = i18n.get(i18n_key)
			-- Keep the # prefix so menu_gestures.lua can detect it as a disabled header
			out[#out + 1] = "#" .. ((translated ~= i18n_key) and translated or key_suffix)
		elseif item == "_cmd_placeholder" then
			out[#out + 1] = "#" .. i18n.get("sg_actions.sg_order.header.cmd")
			for _, l in ipairs(CMD_LETTERS) do out[#out + 1] = "cmd_" .. l end
			for d = 0, 9 do out[#out + 1] = "cmd_" .. d end
			for _, sk in ipairs({"space","enter","period","comma"}) do out[#out + 1] = "cmd_" .. sk end
		elseif item == "_cmd_shift_placeholder" then
			out[#out + 1] = "#" .. i18n.get("sg_actions.sg_order.header.cmd_shift")
			for _, l in ipairs(CMD_LETTERS) do out[#out + 1] = "cmd_shift_" .. l end
		elseif item == "_hs_ctrl_placeholder" then
			out[#out + 1] = "#" .. i18n.get("sg_actions.sg_order.header.hs_ctrl")
			for _, l in ipairs(CMD_LETTERS) do out[#out + 1] = "hs_ctrl_" .. l end
			for d = 0, 9 do out[#out + 1] = "hs_ctrl_" .. d end
			for _, sk in ipairs({"space","enter","period","comma"}) do out[#out + 1] = "hs_ctrl_" .. sk end
		elseif item == "_hs_ctrl_shift_placeholder" then
			out[#out + 1] = "#" .. i18n.get("sg_actions.sg_order.header.hs_ctrl_shift")
			for _, l in ipairs(CMD_LETTERS) do out[#out + 1] = "hs_ctrl_shift_" .. l end
		elseif item == "_hs_option_placeholder" then
			out[#out + 1] = "#" .. i18n.get("sg_actions.sg_order.header.hs_option")
			for _, l in ipairs(CMD_LETTERS) do out[#out + 1] = "hs_option_" .. l end
			for d = 0, 9 do out[#out + 1] = "hs_option_" .. d end
			for _, sk in ipairs({"space","enter","period","comma"}) do out[#out + 1] = "hs_option_" .. sk end
		elseif item:sub(1, 1) == "_" then
			-- ahk-only placeholders (_ctrl_placeholder, _win_placeholder…): skip silently
		else
			local meta = shared.sg_actions[item]
			local platform = meta and meta.platform or "all"
			if platform == "all" or platform == "hs" then
				out[#out + 1] = item
			end
		end
	end
	return out
end

local function build_ax_names(shared)
	if not shared then return nil end
	-- "none" is the disabled-axis sentinel; always first, never in the TOML order list
	local out = {"none"}
	for _, item in ipairs(shared.ax_order) do
		local meta = shared.ax_actions[item]
		local platform = meta and meta.platform or "all"
		if platform == "all" or platform == "hs" then
			out[#out + 1] = item
		end
	end
	return out
end

M.AX_NAMES = build_ax_names(_shared) or {
	"none", "char", "char_sel", "words", "words_sel",
	"line_arrow", "line_sel", "lines", "paragraphs", "line_bounds", "document",
	"tabs", "windows", "spaces", "volume", "brightness", "tracks",
}

-- Static export so callers (script_control, tests) can read SG_NAMES directly
-- without calling get_sg_names(); mirrors the AX_NAMES pattern above.
-- Built once at module load time using the fallback list when _shared is absent.
M.SG_NAMES = nil  -- populated below after get_sg_names() is defined

--- Returns the ordered list of SG action names with translated section headers.
--- Called at menu-build time so headers always reflect the active locale.
function M.get_sg_names()
	local names = build_sg_names(_shared)
	if names then return names end
	-- Fallback when the shared TOML could not be loaded
	local h = function(key) return "#" .. i18n.get(key) end
	return {
		"none", "-",
		h("sg_actions.sg_order.header.mouse_nav"),
		"left_click_toggle", "right_click_toggle", "lookup",
		"app_switcher", "app_previous", "app_window_previous",
		"-", h("sg_actions.sg_order.header.keys"),
		"enter", "tab", "escape", "backspace", "delete",
		"-", h("sg_actions.sg_order.header.tabs"),
		"tab_new", "tab_close", "tab_prev", "tab_next",
		"-", h("sg_actions.sg_order.header.windows"),
		"win_prev", "win_next", "close_window", "fullscreen",
		"snap_left", "snap_right", "maximize",
		"-", h("sg_actions.sg_order.header.spaces"),
		"space_prev", "space_next", "mission_control", "app_expose",
		"-", h("sg_actions.sg_order.header.cursor"),
		"arrow_up", "arrow_down", "arrow_left", "arrow_right",
		"word_prev", "word_next",
		"line_up", "line_down", "line_start", "line_end",
		"para_prev", "para_next", "doc_start", "doc_end",
		"-", h("sg_actions.sg_order.header.selection"),
		"sel_up", "sel_down", "sel_left", "sel_right",
		"sel_word_prev", "sel_word_next",
		"-", h("sg_actions.sg_order.header.media"),
		"vol_up", "vol_down", "mute", "brightness_up", "brightness_down",
		"track_play", "track_next", "track_prev",
		"-", h("sg_actions.sg_order.header.screenshot"),
		"screenshot_window_clipboard", "screenshot_window_save",
		"screenshot_region_clipboard", "screenshot_region_save",
		"screenshot_fullscreen_clipboard", "screenshot_fullscreen_save",
		"-", h("sg_actions.sg_order.header.system"),
		"lock_screen", "notification_center",
		"-", h("sg_actions.sg_order.header.ui"),
		"open_metrics_typing", "open_metrics_apps",
		"open_hotstrings_editor", "open_paths_editor",
		"-", h("sg_actions.sg_order.header.files"),
		"open_script_source", "open_personal_shortcuts",
		"open_personal_hotstrings", "open_personal_info",
		"open_config", "open_logs_folder", "open_today_log",
		"-", h("sg_actions.sg_order.header.script"),
		"script_pause_toggle", "script_reload", "script_save_reload", "script_quit",
		"-", h("sg_actions.sg_order.header.debug"),
		"open_console",
		"-", h("sg_actions.sg_order.header.cmd"),
		"-", h("sg_actions.sg_order.header.cmd_shift"),
	}
end

function M.get_label(name)
	if not name or name == "none" then
		local s = i18n.get("sg_actions.none")
		return (s ~= "sg_actions.none") and s or LABELS.none
	end
	-- Prefer locale JSON so the label is translated for the active language
	local key_sg = "sg_actions." .. name
	local s = i18n.get(key_sg)
	if s ~= key_sg then return s end
	local key_ax = "ax_actions." .. name
	local s_ax = i18n.get(key_ax)
	if s_ax ~= key_ax then return s_ax end
	-- Fall back to hardcoded English label so new locales never show raw keys
	if LABELS[name] then return LABELS[name] end
	if LABELS["ax." .. name] then return LABELS["ax." .. name] end
	return name
end

function M.execute_single(name)
	local s = SG[name]
	if not s or type(s.fn) ~= "function" then return end
	-- Any tap action (other than the click-toggle itself) must deactivate a held click
	-- so that a selection started with left_click_toggle is properly released first.
	if name ~= "left_click_toggle" and name ~= "right_click_toggle" then
		local pos = hs.mouse.absolutePosition()
		if leftClickHeld then
			if leftMouseTap then pcall(function() leftMouseTap:stop() end); leftMouseTap = nil end
			pcall(function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseUp, pos):post() end)
			leftClickHeld = false
			Logger.info(LOG, "Synthetic Left-Click RELEASED by tap action '%s'.", name)
		end
		if rightClickHeld then
			if rightMouseTap then pcall(function() rightMouseTap:stop() end); rightMouseTap = nil end
			pcall(function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.rightMouseUp, pos):post() end)
			rightClickHeld = false
			Logger.info(LOG, "Synthetic Right-Click RELEASED by tap action '%s'.", name)
		end
		if not leftClickHeld and not rightClickHeld then stop_click_key_watcher() end
	end
	pcall(s.fn)
end

function M.execute_axis(name, goNext)
	local a = AX[name]
	if not a then return end
	local fn = goNext and a.next or a.prev
	if type(fn) == "function" then
		pcall(fn)
	end
end

function M.is_scalable(name)
	local a = AX[name]
	return a and a.scalable == true
end

function M.is_right_click_held()
	return rightClickHeld
end

function M.set_gesture_in_progress(active)
	gestureInProgress = active
end

-- Populate the static SG_NAMES now that get_sg_names() is defined
M.SG_NAMES = M.get_sg_names()

return M
