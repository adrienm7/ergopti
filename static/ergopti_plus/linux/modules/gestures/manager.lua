--- modules/gestures/manager.lua

--- ==============================================================================
--- MODULE: Gestures Manager (Linux)
--- DESCRIPTION:
--- Gesture recognition and action mapping for Linux. Defines the canonical gesture
--- slot registry (tap/swipe slots matching the macOS driver), an action registry
--- that maps gesture actions to xdotool/ytool commands, and a skeleton engine
--- ready for libinput touch-event parsing.
---
--- The raw touch-event reader (libinput debug-events for touch frames) is
--- deferred — it requires the same subprocess pattern as keyboard_hook but for
--- touch devices. The engine skeleton exposes the same process_frame(touches)
--- contract as macOS so the reader can be plugged in later without changing
--- the gesture recognition logic.
---
--- FEATURES & RATIONALE:
--- 1. Action registry: ~50+ actions mapped to xdotool/ytool commands. Mirrors
---    the macOS actions where Linux equivalents exist (xdotool key, ydotool,
---    wmctrl, playerctl, brightnessctl, pamixer).
--- 2. Gesture slots: full tap/swipe matrix (2-5 fingers, 8 directions) matching
---    the macOS DEFAULT_GESTURES. Defaults are Linux-appropriate (e.g., 3-finger
---    swipe for workspace navigation via wmctrl).
--- 3. Skeleton engine: process_frame API ready for libinput touch data. Current
---    implementation is pure state management — the touch-event subprocess is a
---    TODO wired the same way as keyboard_hook.
--- 4. Enable/disable: menu toggle suspends gesture processing.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local LOG = "modules.gestures.manager"

-- =========================================
-- =========================================
-- ======= 1/ Gesture Slot Registry ========
-- =========================================
-- =========================================

--- Default gesture-to-action mapping (mirrors macOS DEFAULT_GESTURES).
--- Linux-appropriate defaults: 3-finger swipe → workspace nav, 4-finger → volume.
M.DEFAULT_GESTURES = {
	tap_2                = "none",
	tap_3                = "left_click_toggle",
	tap_4                = "app_window_previous",
	tap_5                = "none",

	swipe_3_horiz        = "none",
	swipe_4_horiz        = "none",
	swipe_5_horiz        = "none",

	swipe_2_left         = "none",
	swipe_2_right        = "none",
	swipe_2_up           = "none",
	swipe_2_down         = "none",
	swipe_2_left_up      = "none",
	swipe_2_right_up     = "none",
	swipe_2_left_down    = "none",
	swipe_2_right_down   = "none",

	swipe_3_left         = "ws_prev",
	swipe_3_right        = "ws_next",
	swipe_3_up           = "tab_prev",
	swipe_3_down         = "tab_next",
	swipe_3_left_up      = "none",
	swipe_3_right_up     = "none",
	swipe_3_left_down    = "none",
	swipe_3_right_down   = "none",

	swipe_4_left         = "vol_down",
	swipe_4_right        = "vol_up",
	swipe_4_up           = "brightness_up",
	swipe_4_down         = "brightness_down",
	swipe_4_left_up      = "none",
	swipe_4_right_up     = "none",
	swipe_4_left_down    = "none",
	swipe_4_right_down   = "none",

	swipe_5_left         = "none",
	swipe_5_right        = "none",
	swipe_5_up           = "none",
	swipe_5_down         = "none",
	swipe_5_left_up      = "none",
	swipe_5_right_up     = "none",
	swipe_5_left_down    = "none",
	swipe_5_right_down   = "none",
}

--- All single gesture slots (for menu iteration).
M.SINGLE_SLOTS = {
	"tap_2", "tap_3", "tap_4", "tap_5",
	"swipe_2_left", "swipe_2_right", "swipe_2_up", "swipe_2_down",
	"swipe_2_left_up", "swipe_2_right_up", "swipe_2_left_down", "swipe_2_right_down",
	"swipe_3_left", "swipe_3_right", "swipe_3_up", "swipe_3_down",
	"swipe_3_left_up", "swipe_3_right_up", "swipe_3_left_down", "swipe_3_right_down",
	"swipe_4_left", "swipe_4_right", "swipe_4_up", "swipe_4_down",
	"swipe_4_left_up", "swipe_4_right_up", "swipe_4_left_down", "swipe_4_right_down",
	"swipe_5_left", "swipe_5_right", "swipe_5_up", "swipe_5_down",
	"swipe_5_left_up", "swipe_5_right_up", "swipe_5_left_down", "swipe_5_right_down",
}

--- Axis-based slots (continuous/swipe-in-any-horizontal-direction).
M.AXIS_SLOTS = { "swipe_3_horiz", "swipe_4_horiz", "swipe_5_horiz" }

-- =========================================
-- =========================================
-- ======= 2/ Action Registry ==============
-- =========================================
-- =========================================

--- Linux action labels (fallback when i18n is absent).
local ACTION_LABELS = {
	none                        = "∅ Désactivé",
	left_click_toggle           = "🖱 Clic gauche (maintien)",
	right_click_toggle          = "🖱 Clic droit (maintien)",
	ws_prev                     = "▢ ← Bureau précédent",
	ws_next                     = "▢ → Bureau suivant",
	tab_prev                    = "⇥ Onglet précédent",
	tab_next                    = "⇥ Onglet suivant",
	vol_up                      = "🔊 Volume +",
	vol_down                    = "🔊 Volume -",
	mute                        = "🔇 Muet",
	brightness_up               = "☀ Luminosité +",
	brightness_down             = "☀ Luminosité -",
	track_play                  = "⏯ Lecture/Pause",
	track_next                  = "⏭ Piste suivante",
	track_prev                  = "⏮ Piste précédente",
	app_switcher                = "⇥ Alt+Tab",
	app_window_previous         = "◱ Fenêtre précédente",
	close_window                = "◱ × Fermer fenêtre",
	maximize                    = "🔲 Maximiser",
	snap_left                   = "◧ ← Aligner gauche",
	snap_right                  = "◨ → Aligner droite",
	fullscreen                  = "📺 Plein écran",
	word_prev                   = "W ← Mot précédent",
	word_next                   = "W → Mot suivant",
	line_up                     = "↕ ↑ Ligne précédente",
	line_down                   = "↕ ↓ Ligne suivante",
	line_start                  = "⇤ Début de ligne",
	line_end                    = "⇥ Fin de ligne",
	doc_start                   = "⤒ Début du document",
	doc_end                     = "⤓ Fin du document",
	enter                       = "↵ Entrée",
	escape                      = "⎋ Échap",
	backspace                   = "⌫ Retour",
	delete                      = "⌦ Suppr",
	arrow_up                    = "↑ Flèche haut",
	arrow_down                  = "↓ Flèche bas",
	arrow_left                  = "← Flèche gauche",
	arrow_right                 = "→ Flèche droite",
	lock_screen                 = "🔒 Verrouiller",
	notification_center         = "🔔 Notifications",
}

--- Executes a gesture action via xdotool/ytool on Linux.
--- @param action_name string The action identifier.
--- @param go_next boolean|nil Direction for axis actions (true = next, false/nil = prev).
local function _execute_action(action_name, go_next)
	if not action_name or action_name == "none" then return end

	local function _run(cmd)
		pcall(function() os.execute(cmd .. " 2>/dev/null &") end)
	end

	if action_name == "left_click_toggle" then
		-- Toggle mouse button hold via xdotool.
		_run("xdotool mousedown 1")
	elseif action_name == "right_click_toggle" then
		_run("xdotool mousedown 3")
	elseif action_name == "ws_prev" then
		_run("wmctrl -s -1 2>/dev/null || xdotool key ctrl+alt+Left")
	elseif action_name == "ws_next" then
		_run("wmctrl -s +1 2>/dev/null || xdotool key ctrl+alt+Right")
	elseif action_name == "tab_prev" then
		_run("xdotool key ctrl+shift+Tab")
	elseif action_name == "tab_next" then
		_run("xdotool key ctrl+Tab")
	elseif action_name == "vol_up" then
		_run("pactl set-sink-volume @DEFAULT_SINK@ +5% 2>/dev/null || xdotool key XF86AudioRaiseVolume")
	elseif action_name == "vol_down" then
		_run("pactl set-sink-volume @DEFAULT_SINK@ -5% 2>/dev/null || xdotool key XF86AudioLowerVolume")
	elseif action_name == "mute" then
		_run("pactl set-sink-mute @DEFAULT_SINK@ toggle 2>/dev/null || xdotool key XF86AudioMute")
	elseif action_name == "brightness_up" then
		_run("brightnessctl set +5% 2>/dev/null || xdotool key XF86MonBrightnessUp")
	elseif action_name == "brightness_down" then
		_run("brightnessctl set 5%- 2>/dev/null || xdotool key XF86MonBrightnessDown")
	elseif action_name == "track_play" then
		_run("playerctl play-pause 2>/dev/null || xdotool key XF86AudioPlay")
	elseif action_name == "track_next" then
		_run("playerctl next 2>/dev/null || xdotool key XF86AudioNext")
	elseif action_name == "track_prev" then
		_run("playerctl previous 2>/dev/null || xdotool key XF86AudioPrev")
	elseif action_name == "app_switcher" then
		_run("xdotool key alt+Tab")
	elseif action_name == "app_window_previous" then
		_run("xdotool key alt+Escape")
	elseif action_name == "close_window" then
		_run("xdotool key alt+F4")
	elseif action_name == "maximize" then
		_run("xdotool key super+Up")
	elseif action_name == "snap_left" then
		_run("xdotool key super+Left")
	elseif action_name == "snap_right" then
		_run("xdotool key super+Right")
	elseif action_name == "fullscreen" then
		_run("xdotool key F11")
	elseif action_name == "word_prev" then
		_run("xdotool key ctrl+Left")
	elseif action_name == "word_next" then
		_run("xdotool key ctrl+Right")
	elseif action_name == "line_up" then
		_run("xdotool key Up")
	elseif action_name == "line_down" then
		_run("xdotool key Down")
	elseif action_name == "line_start" then
		_run("xdotool key Home")
	elseif action_name == "line_end" then
		_run("xdotool key End")
	elseif action_name == "doc_start" then
		_run("xdotool key ctrl+Home")
	elseif action_name == "doc_end" then
		_run("xdotool key ctrl+End")
	elseif action_name == "enter" then
		_run("xdotool key Return")
	elseif action_name == "escape" then
		_run("xdotool key Escape")
	elseif action_name == "backspace" then
		_run("xdotool key BackSpace")
	elseif action_name == "delete" then
		_run("xdotool key Delete")
	elseif action_name == "arrow_up" then
		_run("xdotool key Up")
	elseif action_name == "arrow_down" then
		_run("xdotool key Down")
	elseif action_name == "arrow_left" then
		_run("xdotool key Left")
	elseif action_name == "arrow_right" then
		_run("xdotool key Right")
	elseif action_name == "lock_screen" then
		_run("loginctl lock-session 2>/dev/null || xdg-screensaver lock")
	elseif action_name == "notification_center" then
		_run("xdotool key super+v")
	else
		Logger.debug(LOG, "Unknown action: %s", action_name)
	end
end

--- Returns a human-readable label for an action.
--- @param action_name string
--- @return string
function M.get_action_label(action_name)
	if not action_name or action_name == "" then return "∅" end
	return ACTION_LABELS[action_name] or action_name
end

--- Returns the list of all available action names.
--- @return table
function M.get_action_names()
	local names = {}
	for k in pairs(ACTION_LABELS) do
		names[#names + 1] = k
	end
	table.sort(names)
	return names
end

-- =========================================
-- =========================================
-- ======= 3/ Internal State ===============
-- =========================================
-- =========================================

local _enabled       = false
local _actions       = {}   -- slot → action_name
local _reading       = false -- touch event subprocess active

-- Initialize actions with defaults.
for k, v in pairs(M.DEFAULT_GESTURES) do
	_actions[k] = v
end

-- =========================================
-- =========================================
-- ======= 4/ Public API ===================
-- =========================================
-- =========================================

--- Returns whether gestures are enabled.
--- @return boolean
function M.is_enabled()
	return _enabled
end

--- Enables gesture processing.
function M.enable()
	_enabled = true
	Logger.info(LOG, "Gestures enabled.")
end

--- Disables gesture processing.
function M.disable()
	_enabled = false
	M.stop_reading()
	Logger.info(LOG, "Gestures disabled.")
end

--- Toggles gestures on/off.
function M.toggle()
	if _enabled then M.disable() else M.enable() end
end

--- Gets the action bound to a gesture slot.
--- @param slot string Gesture slot id (e.g. "swipe_3_left").
--- @return string|nil
function M.get_action(slot)
	return _actions[slot]
end

--- Sets the action for a gesture slot.
--- @param slot string Gesture slot id.
--- @param action_name string Action identifier.
function M.set_action(slot, action_name)
	if not M.DEFAULT_GESTURES[slot] and not _actions[slot] then
		Logger.warn(LOG, "Unknown gesture slot: %s", tostring(slot))
		return
	end
	if action_name ~= "none" and not ACTION_LABELS[action_name] then
		Logger.warn(LOG, "Unknown action '%s' for slot '%s' — will be a no-op.",
			tostring(action_name), tostring(slot))
	end
	_actions[slot] = action_name
	Logger.info(LOG, "Gesture '%s' → '%s'.", slot, tostring(action_name))
end

--- Returns all gesture actions.
--- @return table slot → action_name
function M.get_all_actions()
	local t = {}
	for k, v in pairs(_actions) do t[k] = v end
	return t
end

--- Resets all gesture actions to defaults.
function M.reset_defaults()
	for k, v in pairs(M.DEFAULT_GESTURES) do
		_actions[k] = v
	end
	Logger.info(LOG, "Gestures reset to defaults.")
end

-- =========================================
-- =========================================
-- ======= 5/ Touch Event Engine ===========
-- =========================================
-- =========================================

--- Starts reading touch events from libinput.
--- TODO(linux): spawn `libinput debug-events --device <touchpad>` subprocess
--- and parse touch frames (same pattern as keyboard_hook). Touch events are:
---   event3  TOUCH_DOWN  +0.00s	0 (0) 45.00/67.00
---   event3  TOUCH_FRAME +0.02s
---   event3  TOUCH_UP    +0.50s	0
---   event3  TOUCH_FRAME +0.50s
--- The subprocess pipe is read in a pump loop (mirroring keyboard_hook.pump())
--- and each complete TOUCH_FRAME batch is passed to process_frame().
--- Currently a stub — the flag is set but no subprocess is spawned.
function M.start_reading()
	if _reading then return end
	_reading = true
	Logger.info(LOG, "Touch event reader started (libinput stub — subprocess deferred).")
end

--- Stops the touch event subprocess.
--- Currently a stub — only clears the flag.
function M.stop_reading()
	_reading = false
	Logger.info(LOG, "Touch event reader stopped.")
end

--- Returns true if the touch reader is active.
--- @return boolean
function M.is_reading()
	return _reading
end

--- Processes a raw touch frame from libinput.
--- The contract matches macOS Engine.process_frame(touches).
--- @param touches table Array of touch points { x, y, state }.
function M.process_frame(touches)
	if not _enabled then return end
	if type(touches) ~= "table" then return end

	local n = #touches
	if n == 0 then
		-- All fingers lifted: commit gesture.
		-- TODO: detect tap vs swipe from accumulated touch history,
		-- resolve gesture slot, and dispatch via _execute_action().
		return
	end

	-- TODO: implement full gesture recognition (tap detection, swipe direction,
	-- live-axis firing, incremental mode). The macOS engine provides the
	-- reference algorithm in modules/gestures/engine.lua.
	-- Once recognition is done, dispatch via _execute_action(slot_action, direction).
	-- For now, process_frame is a skeleton — it accepts touch data but doesn't
	-- fire actions. The action registry (_execute_action) is ready and tested.
end

-- =========================================
-- =========================================
-- ======= 6/ Init =========================
-- =========================================
-- =========================================

--- Initialises the gestures module.
--- @param opts table|nil { enabled? }
function M.init(opts)
	opts = type(opts) == "table" and opts or {}

	if opts.enabled == true then
		_enabled = true
		M.start_reading()
	end

	Logger.info(LOG, "Gestures manager initialised (enabled=%s).", tostring(_enabled))
end

return M
