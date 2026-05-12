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
local function ax(name, label, prev_fn, next_fn, scalable)
	AX[name] = { label = label, prev = prev_fn, next = next_fn, scalable = scalable }
end

--- Registers a discrete single-fire action.
local function sg(name, label, fn)
	SG[name] = { label = label, fn = fn }
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

--- Toggles a synthetic right-click hold state.
local rightClickHeld  = false
local leftClickHeld   = false
local click_key_watcher = nil

--- Starts the key watcher that releases any held synthetic click on the next keydown.
local function start_click_key_watcher()
	if click_key_watcher then return end
	click_key_watcher = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(_)
		local pos = hs.mouse.absolutePosition()
		if leftClickHeld then
			pcall(function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseUp, pos):post() end)
			leftClickHeld = false
			Logger.info(LOG, "Synthetic Left-Click RELEASED by keydown.")
		end
		if rightClickHeld then
			pcall(function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.rightMouseUp, pos):post() end)
			rightClickHeld = false
			Logger.info(LOG, "Synthetic Right-Click RELEASED by keydown.")
		end
		-- Stop watcher once no click is held
		pcall(function() click_key_watcher:stop() end)
		click_key_watcher = nil
		-- Pass the key event through unmodified
		return false
	end)
	pcall(function() click_key_watcher:start() end)
end

--- Stops the key watcher if running.
local function stop_click_key_watcher()
	if not click_key_watcher then return end
	pcall(function() click_key_watcher:stop() end)
	click_key_watcher = nil
end

function M.toggle_right_click()
	local pos = hs.mouse.absolutePosition()
	if rightClickHeld then
		pcall(function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.rightMouseUp, pos):post() end)
		rightClickHeld = false
		Logger.info(LOG, "Synthetic Right-Click RELEASED.")
		if not leftClickHeld then stop_click_key_watcher() end
	else
		pcall(function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.rightMouseDown, pos):post() end)
		rightClickHeld = true
		Logger.info(LOG, "Synthetic Right-Click HELD.")
		start_click_key_watcher()
	end
end

function M.toggle_left_click()
	local pos = hs.mouse.absolutePosition()
	if leftClickHeld then
		pcall(function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseUp, pos):post() end)
		leftClickHeld = false
		Logger.info(LOG, "Synthetic Left-Click RELEASED.")
		if not rightClickHeld then stop_click_key_watcher() end
	else
		pcall(function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseDown, pos):post() end)
		leftClickHeld = true
		Logger.info(LOG, "Synthetic Left-Click HELD.")
		start_click_key_watcher()
	end
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
ax("tabs",       "⧉ Onglets",
	function() pcall(hs.eventtap.keyStroke, {"ctrl", "shift"}, "tab") end,
	function() pcall(hs.eventtap.keyStroke, {"ctrl"}, "tab") end, true)

ax("char",       "A Lettres",
	function() postKeyStroke({}, "left") end,
	function() postKeyStroke({}, "right") end, true)

ax("char_sel",   "✎ A Sél. Lettres",
	function() postKeyStroke({"shift"}, "left") end,
	function() postKeyStroke({"shift"}, "right") end, true)

ax("line_arrow", "↕ Lignes (Flèches)",
	function() postKeyStroke({}, "up") end,
	function() postKeyStroke({}, "down") end, true)

ax("line_sel",   "✎ ↕ Sél. Lignes",
	function() postKeyStroke({"shift"}, "up") end,
	function() postKeyStroke({"shift"}, "down") end, true)

ax("words",      "W Mots",
	function() postKeyStroke({"alt"}, "left") end,
	function() postKeyStroke({"alt"}, "right") end, true)

ax("words_sel",  "✎ W Sél. Mots",
	function() postKeyStroke({"shift", "alt"}, "left") end,
	function() postKeyStroke({"shift", "alt"}, "right") end, true)

ax("windows",    "◱ Fenêtres",
	function() winNav(false) end, 
	function() winNav(true) end)

ax("spaces",     "▢ Spaces",
	function() spaceNav(false) end, 
	function() spaceNav(true) end)

ax("volume",     "🔊 Volume",
	function() sysKey("SOUND_DOWN") end, 
	function() sysKey("SOUND_UP") end, true)

ax("brightness", "☀ Luminosité",
	function() sysKey("BRIGHTNESS_DOWN") end, 
	function() sysKey("BRIGHTNESS_UP") end, true)

ax("tracks",     "♫ Pistes",
	function() sysKey("PREVIOUS") end, 
	function() sysKey("NEXT") end)

ax("lines",      "↕ Lignes (Alt)",
	function() hs.timer.doAfter(0, function() pcall(hs.eventtap.keyStroke, {"alt"}, "up") end) end,
	function() hs.timer.doAfter(0, function() pcall(hs.eventtap.keyStroke, {"alt"}, "down") end) end, true)

ax("line_bounds","↔ Ligne (début/fin)",
	function() hs.timer.doAfter(0, function() pcall(hs.eventtap.keyStroke, {"cmd"}, "left") end) end,
	function() hs.timer.doAfter(0, function() pcall(hs.eventtap.keyStroke, {"cmd"}, "right") end) end)

ax("paragraphs", "¶ Paragraphes",
	function() pcall(hs.eventtap.keyStroke, {"alt"}, "up") end,
	function() pcall(hs.eventtap.keyStroke, {"alt"}, "down") end, true)

ax("document",   "📄 Document (début/fin)",
	function() pcall(hs.eventtap.keyStroke, {"cmd"}, "up") end,
	function() pcall(hs.eventtap.keyStroke, {"cmd"}, "down") end)

-- Single actions
sg("none",             "∅ Désactivé",            function() end)

-- Selection & navigation cursor
sg("left_click_toggle",  "🖱 L Clic gauche (maint.)", M.toggle_left_click)
sg("right_click_toggle", "🖱 R Clic droit (maint.)",  M.toggle_right_click)
sg("lookup",           "🔍 Définition du mot",    M.trigger_lookup)
sg("app_switcher",     "⇥ Alt+Tab — Liste apps", show_application_switcher_overlay)
sg("app_previous",     "⇥ ← Alt+Tab — App préc.", switch_to_previous_application)
sg("app_window_previous", "⇥ ◱ ← Alt+Tab — Fenêtre préc.", switch_to_previous_window_precise)

-- Keys
sg("enter",            "↵ Entrée",               function() pcall(hs.eventtap.keyStroke, {}, "return") end)
sg("tab",              "⇥ Tab",                  function() pcall(hs.eventtap.keyStroke, {}, "tab") end)
sg("escape",           "⎋ Échap",                function() pcall(hs.eventtap.keyStroke, {}, "escape") end)
sg("backspace",        "⌫ Suppr. arrière",       function() pcall(hs.eventtap.keyStroke, {}, "delete") end)
sg("delete",           "⌦ Suppr. avant",         function() pcall(hs.eventtap.keyStroke, {}, "forwarddelete") end)

-- Tabs
sg("tab_new",          "⧉ + Nouvel onglet",        function() pcall(hs.eventtap.keyStroke, {"cmd"}, "t") end)
sg("tab_close",        "⧉ × Fermer onglet",        function() pcall(hs.eventtap.keyStroke, {"cmd"}, "w") end)
sg("tab_prev",         "⧉ ← Onglet précédent",     function() pcall(hs.eventtap.keyStroke, {"ctrl", "shift"}, "tab") end)
sg("tab_next",         "⧉ → Onglet suivant",       function() pcall(hs.eventtap.keyStroke, {"ctrl"}, "tab") end)

-- Windows & Spaces
sg("win_prev",         "◱ ← Fenêtre précédente",   function() winNav(false) end)
sg("win_next",         "◱ → Fenêtre suivante",     function() winNav(true) end)
sg("close_window",     "◱ × Fermer la fenêtre",    function() pcall(hs.eventtap.keyStroke, {"cmd"}, "w") end)
sg("fullscreen",       "📺 Plein écran",          function() pcall(hs.eventtap.keyStroke, {"cmd", "ctrl"}, "f") end)
sg("snap_left",        "◧ ← Ancrer à gauche",      function()
	local win = hs.window.focusedWindow()
	if win then pcall(function() win:moveToUnit(hs.layout.left50) end) end
end)
sg("snap_right",       "◨ → Ancrer à droite",      function()
	local win = hs.window.focusedWindow()
	if win then pcall(function() win:maximize() end) end
end)
sg("maximize",         "🔲 Maximiser",            function()
	local win = hs.window.focusedWindow()
	if win then pcall(function() win:maximize() end) end
end)
sg("space_prev",       "▢ ← Space précédent",      function() spaceNav(false) end)
sg("space_next",       "▢ → Space suivant",        function() spaceNav(true) end)
sg("mission_control",  "▢ Mission Control",      function() pcall(hs.osascript.applescript, "tell application \"System Events\" to key code 160") end)
sg("app_expose",       "◱ App Exposé",           function() pcall(hs.osascript.applescript, "tell application \"System Events\" to key code 125 using {control down}") end)

-- Cursor movement
sg("word_prev",        "W ← Mot précédent",        function() postKeyStroke({"alt"}, "left") end)
sg("word_next",        "W → Mot suivant",          function() postKeyStroke({"alt"}, "right") end)
sg("line_up",          "↕ ↑ Ligne précédente",     function() hs.timer.doAfter(0, function() pcall(hs.eventtap.keyStroke, {"alt"}, "up") end) end)
sg("line_down",        "↕ ↓ Ligne suivante",       function() hs.timer.doAfter(0, function() pcall(hs.eventtap.keyStroke, {"alt"}, "down") end) end)
sg("line_start",       "⇤ Début de ligne",       function() hs.timer.doAfter(0, function() pcall(hs.eventtap.keyStroke, {"cmd"}, "left") end) end)
sg("line_end",         "⇥ Fin de ligne",         function() hs.timer.doAfter(0, function() pcall(hs.eventtap.keyStroke, {"cmd"}, "right") end) end)
sg("para_prev",        "¶ ↑ Paragraphe précédent", function() pcall(hs.eventtap.keyStroke, {"alt"}, "up") end)
sg("para_next",        "¶ ↓ Paragraphe suivant",   function() pcall(hs.eventtap.keyStroke, {"alt"}, "down") end)
sg("doc_start",        "⤒ Début du document",    function() pcall(hs.eventtap.keyStroke, {"cmd"}, "up") end)
sg("doc_end",          "⤓ Fin du document",      function() pcall(hs.eventtap.keyStroke, {"cmd"}, "down") end)

-- Media
sg("vol_up",           "🔊 + Volume +",             function() sysKey("SOUND_UP") end)
sg("vol_down",         "🔊 - Volume -",             function() sysKey("SOUND_DOWN") end)
sg("mute",             "🔇 Muet/Unmute",          function() sysKey("MUTE") end)
sg("brightness_up",    "☀ + Luminosité +",         function() sysKey("BRIGHTNESS_UP") end)
sg("brightness_down",  "☀ - Luminosité -",         function() sysKey("BRIGHTNESS_DOWN") end)
sg("track_play",       "⏯ Lecture/Pause",        function() sysKey("PLAY") end)
sg("track_next",       "⏭ Piste suivante",       function() sysKey("NEXT") end)
sg("track_prev",       "⏮ Piste précédente",     function() sysKey("PREVIOUS") end)

-- Single arrows
sg("arrow_up",         "↑ Flèche Haut",          function() postKeyStroke({}, "up") end)
sg("arrow_down",       "↓ Flèche Bas",           function() postKeyStroke({}, "down") end)
sg("arrow_left",       "← Flèche Gauche",        function() postKeyStroke({}, "left") end)
sg("arrow_right",      "→ Flèche Droite",        function() postKeyStroke({}, "right") end)

-- Shift + Arrows
sg("sel_up",           "✎ ↑ Sélection Haut",       function() postKeyStroke({"shift"}, "up") end)
sg("sel_down",         "✎ ↓ Sélection Bas",        function() postKeyStroke({"shift"}, "down") end)
sg("sel_left",         "✎ ← Sélection Gauche",     function() postKeyStroke({"shift"}, "left") end)
sg("sel_right",        "✎ → Sélection Droite",     function() postKeyStroke({"shift"}, "right") end)

-- Shift + Alt + Arrows (Word selection)
sg("sel_word_prev",    "✎ W ← Sél. Mot préc.", function() postKeyStroke({"shift", "alt"}, "left") end)
sg("sel_word_next",    "✎ W → Sél. Mot suiv.",   function() postKeyStroke({"shift", "alt"}, "right") end)

-- System
sg("screenshot_window_clipboard",    "📸 ⊞ Copier fenêtre", function() pcall(hs.execute, "screencapture -cw") end)
sg("screenshot_window_save",         "📸 ⊞ Sauver fenêtre", function() pcall(hs.execute, "screencapture -w ~/Pictures/screenshots/win_$(date +%Y%m%d%H%M%S).png") end)
sg("screenshot_region_clipboard",    "📸 ⬚ Copier région",  function() pcall(hs.execute, "screencapture -ci") end)
sg("screenshot_region_save",         "📸 ⬚ Sauver région",  function() pcall(hs.execute, "screencapture -i ~/Pictures/screenshots/reg_$(date +%Y%m%d%H%M%S).png") end)
sg("screenshot_fullscreen_clipboard","📸 🖥 Copier écran",   function() pcall(hs.execute, "screencapture -c") end)
sg("screenshot_fullscreen_save",     "📸 🖥 Sauver écran",   function() pcall(hs.execute, "screencapture ~/Pictures/screenshots/full_$(date +%Y%m%d%H%M%S).png") end)

sg("lock_screen",           "🔒 Verrouiller",         function() pcall(hs.caffeinate.lockScreen) end)
sg("notification_center",   "🔔 Notifications",       function() pcall(hs.osascript.applescript, "tell application \"System Events\" to click menu bar item \"Notification Center\" of menu bar 1 of application process \"ControlCenter\"") end)

-- Applications and Stats
sg("open_metrics_typing",    "📊 Stats Frappe",        function() pcall(function() require("ui.metrics_overlay").toggle("typing") end) end)
sg("open_metrics_apps",      "📊 Stats Applications",  function() pcall(function() require("ui.metrics_overlay").toggle("apps") end) end)
sg("open_hotstrings_editor", "⌨ Éditeur Hotstrings",   function() pcall(function() require("ui.hotstrings_editor").show() end) end)
sg("open_paths_editor",      "📂 Éditeur Chemins",      function() pcall(function() require("ui.paths_editor").show() end) end)
sg("open_script_source",     "🛠 Code Source",          function() pcall(hs.execute, string.format("open %q", hs.configdir)) end)
sg("open_personal_shortcuts","👤 Raccourcis perso",     function() pcall(hs.execute, string.format("open %q/personal_shortcuts.toml", hs.configdir)) end)
sg("open_personal_hotstrings","👤 Hotstrings perso",    function() pcall(hs.execute, string.format("open %q/personal_hotstrings.toml", hs.configdir)) end)
sg("open_personal_info",     "👤 Infos perso",          function() pcall(hs.execute, string.format("open %q/personal_info.toml", hs.configdir)) end)
sg("open_config",            "⚙ Configuration",        function() pcall(hs.execute, string.format("open %q/config.toml", hs.configdir)) end)
sg("open_logs_folder",       "📁 Dossier Logs",         function() pcall(hs.execute, string.format("open %q/logs", hs.configdir)) end)
sg("open_today_log",         "📄 Log du jour",          function()
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
sg("script_pause_toggle",    "⏸/▶ Suspendre / Reprendre", function()
	local ok, sc = pcall(require, "modules.shortcuts.script_control")
	if ok and type(sc.toggle) == "function" then pcall(sc.toggle) end
end)
sg("script_reload",          "↻ Recharger",             function() pcall(hs.reload) end)
sg("script_save_reload",     "↻ Sauver et recharger", function()
	pcall(hs.eventtap.keyStroke, {"cmd"}, "s")
	hs.timer.doAfter(0.3, function() pcall(hs.reload) end)
end)
sg("script_quit",            "✕ Quitter",             function()
	pcall(function() hs.closeConsole() end)
	pcall(function() hs.timer.doAfter(0.1, function() os.exit(0) end) end)
end)

-- Debug
sg("open_console",           "▤ Console",             function() pcall(hs.openConsole) end)

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





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

-- Path to the shared gesture_actions.toml, resolved relative to this file.
-- actions.lua lives at static/drivers/hammerspoon/modules/gestures/actions.lua
-- so we climb 4 levels to reach static/, then enter shared/.
local _self_path = (debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./")
local _shared_toml = _self_path .. "../../../../shared/actions.toml"

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
			out[#out + 1] = item
		elseif item == "_cmd_placeholder" then
			out[#out + 1] = "#Raccourcis ⌘ (Cmd)"
			for _, l in ipairs(CMD_LETTERS) do out[#out + 1] = "cmd_" .. l end
		elseif item == "_cmd_shift_placeholder" then
			out[#out + 1] = "#Raccourcis ⌘⇧ (Cmd+Shift)"
			for _, l in ipairs(CMD_LETTERS) do out[#out + 1] = "cmd_shift_" .. l end
		elseif item == "_hs_ctrl_placeholder" then
			out[#out + 1] = "#Raccourcis ^ (Ctrl) — macOS"
			for _, l in ipairs(CMD_LETTERS) do out[#out + 1] = "hs_ctrl_" .. l end
		elseif item == "_hs_ctrl_shift_placeholder" then
			out[#out + 1] = "#Raccourcis ^⇧ (Ctrl+Shift) — macOS"
			for _, l in ipairs(CMD_LETTERS) do out[#out + 1] = "hs_ctrl_shift_" .. l end
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
	local out = {}
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

M.SG_NAMES = build_sg_names(_shared) or {
	"none", "-",
	"#Souris et Navigation",
	"left_click_toggle", "right_click_toggle", "lookup",
	"app_switcher", "app_previous", "app_window_previous",
	"-", "#Touches",
	"enter", "tab", "escape", "backspace", "delete",
	"-", "#Onglets",
	"tab_new", "tab_close", "tab_prev", "tab_next",
	"-", "#Fenêtres",
	"win_prev", "win_next", "close_window", "fullscreen",
	"snap_left", "snap_right", "maximize",
	"-", "#Espaces / Bureaux",
	"space_prev", "space_next", "mission_control", "app_expose",
	"-", "#Curseur et Texte",
	"arrow_up", "arrow_down", "arrow_left", "arrow_right",
	"word_prev", "word_next",
	"line_up", "line_down", "line_start", "line_end",
	"para_prev", "para_next", "doc_start", "doc_end",
	"-", "#Sélection de Texte",
	"sel_up", "sel_down", "sel_left", "sel_right",
	"sel_word_prev", "sel_word_next",
	"-", "#Médias",
	"vol_up", "vol_down", "mute", "brightness_up", "brightness_down",
	"track_play", "track_next", "track_prev",
	"-", "#Captures d'écran",
	"screenshot_window_clipboard", "screenshot_window_save",
	"screenshot_region_clipboard", "screenshot_region_save",
	"screenshot_fullscreen_clipboard", "screenshot_fullscreen_save",
	"-", "#Système",
	"lock_screen", "notification_center",
	"-", "#Interface",
	"open_metrics_typing", "open_metrics_apps",
	"open_hotstrings_editor", "open_paths_editor",
	"-", "#Fichiers",
	"open_script_source", "open_personal_shortcuts",
	"open_personal_hotstrings", "open_personal_info",
	"open_config", "open_logs_folder", "open_today_log",
	"-", "#Gestion du Script",
	"script_pause_toggle", "script_reload", "script_save_reload", "script_quit",
	"-", "#Debug",
	"open_console",
	"-", "#Raccourcis ⌘ (Cmd)",
	"-", "#Raccourcis ⌘⇧ (Cmd+Shift)",
}

function M.get_label(name)
	if not name then return AX["none"].label end
	if AX[name] then return AX[name].label end
	if SG[name] then return SG[name].label end
	return name
end

function M.execute_single(name)
	local s = SG[name]
	if s and type(s.fn) == "function" then
		pcall(s.fn)
	end
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

return M
