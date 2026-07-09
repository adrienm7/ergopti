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
local Timings = require("lib.timings")
local Monotonic = require("lib.monotonic")
local LOG = "modules.gestures.manager"

-- Wall-clock source (seconds) for gesture tap/swipe timing. Defaults to the
-- monotonic clock and is injectable via M.init for tests. Deliberately NOT
-- os.clock(): its CPU time barely advances in an I/O-bound daemon, so a gesture
-- held for seconds would report elapsed ~= 0 and be misclassified as a tap.
local _now_sec = Monotonic.now_sec

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
-- ======= 5/ Geometry Helpers =============
-- =========================================
-- =========================================

-- Thresholds (match macOS Geometry module).
local SWIPE_MIN     = 1.5    -- 3+ fingers: minimum travel to validate a swipe
local SWIPE_MIN_2   = 3.0    -- 2 fingers: higher threshold (left to macOS native)
local DIAG_MIN_2    = 5.0    -- 2-finger diagonal: minimum total distance
local TAP_MAX_SEC   = Timings.sec("gestures", "tap_max_ms")   -- Canonical tap ceiling (shared registry; was a drifted 0.25 literal)
local TAP_MAX_DELTA = 8.0    -- Maximum centroid displacement for tap classification

--- Computes the centroid position from an array of touch points.
--- @param touches table Array of {x=number, y=number} points.
--- @return table {x, y}
local function _avg_pos(touches)
	local x, y = 0, 0
	if type(touches) ~= "table" or #touches == 0 then return { x = 0, y = 0 } end
	for _, t in ipairs(touches) do
		if type(t) == "table" then
			x = x + (tonumber(t.x) or 0)
			y = y + (tonumber(t.y) or 0)
		end
	end
	return { x = x / #touches, y = y / #touches }
end

--- Classifies a displacement into a direction (horiz/vert/diag).
--- @param dx number X delta.
--- @param dy number Y delta.
--- @param mf number Finger count (2 uses looser thresholds).
--- @return string|nil "horiz", "vert", "diag", or nil if below threshold.
local function _compute_dir(dx, dy, mf)
	local adx  = math.abs(dx)
	local ady  = math.abs(dy)
	local dist = adx + ady
	local min  = (mf == 2) and SWIPE_MIN_2 or SWIPE_MIN

	if dist < min then return nil end

	local angle = math.deg(math.atan(ady, adx))

	if angle >= 65 then
		return "vert"
	elseif angle <= 25 then
		return "horiz"
	else
		local diag_min = (mf == 2) and DIAG_MIN_2 or (min * 1.5)
		if dist >= diag_min then return "diag" end
		return (adx >= ady) and "horiz" or "vert"
	end
end

--- Resolves a finger count + direction + delta into an action slot name.
--- @param mf number Finger count.
--- @param dir string "horiz" | "vert" | "diag".
--- @param dx number X delta.
--- @param dy number Y delta.
--- @return string|nil Slot name like "swipe_3_left".
local function _slot_for_dir(mf, dir, dx, dy)
	local prefix = "swipe_" .. tostring(mf) .. "_"
	if dir == "horiz" then
		return prefix .. (dx > 0 and "right" or "left")
	elseif dir == "vert" then
		return prefix .. (dy > 0 and "down" or "up")
	elseif dir == "diag" then
		if dx > 0 then
			return prefix .. (dy > 0 and "right_down" or "right_up")
		else
			return prefix .. (dy > 0 and "left_down" or "left_up")
		end
	end
	return nil
end


-- =========================================
-- =========================================
-- ======= 6/ Touch Event Engine ===========
-- =========================================
-- =========================================

-- Gesture tracking state (per-gesture, cleared on finger lift).
local _gesture = {
	active     = false,
	start_time = nil,
	start_pos  = nil,
	end_pos    = nil,
	max_fingers = 0,
}

--- Resets gesture tracking state.
local function _reset_gesture()
	_gesture = {
		active      = false,
		start_time  = nil,
		start_pos   = nil,
		end_pos     = nil,
		max_fingers = 0,
	}
end

--- Starts reading touch events from libinput.
--- Spawns `libinput debug-events --device <touchpad>` subprocess and parses
--- touch frames (same pattern as keyboard_hook). Touch events are:
---   event3  TOUCH_DOWN  +0.00s    0 (0) 45.00/67.00
---   event3  TOUCH_FRAME +0.02s
---   event3  TOUCH_UP    +0.50s    0
---   event3  TOUCH_FRAME +0.50s
--- The subprocess pipe is read in a pump loop (mirroring keyboard_hook.pump())
--- and each complete TOUCH_FRAME batch is passed to process_frame().
function M.start_reading()
	if _reading then return end
	_reading = true
	Logger.info(LOG, "Touch event reader started (libinput subprocess deferred — implement same pattern as keyboard_hook).")
end

--- Stops the touch event subprocess.
function M.stop_reading()
	_reading = false
	_reset_gesture()
	Logger.info(LOG, "Touch event reader stopped.")
end

--- Returns true if the touch reader is active.
--- @return boolean
function M.is_reading()
	return _reading
end

--- Processes a raw touch frame from libinput.
--- The contract matches macOS Engine.process_frame(touches).
---
--- Algorithm (simplified port of macOS gestures/engine.lua):
--- 1. On first frame with >=2 touches: record start position and time.
--- 2. Track centroid through subsequent frames.
--- 3. On all fingers lifted (n=0): classify as tap or swipe, dispatch action.
---
--- @param touches table Array of touch points { x, y }.
function M.process_frame(touches)
	if not _enabled then return end
	if type(touches) ~= "table" then return end

	local n = #touches
	local now = _now_sec()

	if n == 0 then
		-- All fingers lifted — commit the gesture.
		if not _gesture.active or not _gesture.start_pos or not _gesture.end_pos then
			_reset_gesture()
			return
		end

		local dx = _gesture.end_pos.x - _gesture.start_pos.x
		local dy = _gesture.end_pos.y - _gesture.start_pos.y
		local elapsed = now - (_gesture.start_time or now)
		local total_delta = math.abs(dx) + math.abs(dy)
		local mf = _gesture.max_fingers

		-- Tap detection: short duration + minimal movement.
		if total_delta < TAP_MAX_DELTA and elapsed <= TAP_MAX_SEC then
			local tap_slot = nil
			if     mf == 2 then tap_slot = "tap_2"
			elseif mf == 3 then tap_slot = "tap_3"
			elseif mf == 4 then tap_slot = "tap_4"
			elseif mf >= 5 then tap_slot = "tap_5" end

			if tap_slot and _actions[tap_slot] and _actions[tap_slot] ~= "none" then
				Logger.info(LOG, "TAP FIRE: slot=%s action=%s fingers=%d elapsed=%.3fs",
					tap_slot, _actions[tap_slot], mf, elapsed)
				_execute_action(_actions[tap_slot])
			end
			_reset_gesture()
			return
		end

		-- Swipe detection.
		local dir = _compute_dir(dx, dy, mf)
		if not dir then
			Logger.debug(LOG, "Swipe below threshold: dx=%.2f dy=%.2f mf=%d", dx, dy, mf)
			_reset_gesture()
			return
		end

		local slot = _slot_for_dir(mf, dir, dx, dy)
		if not slot or not _actions[slot] or _actions[slot] == "none" then
			Logger.debug(LOG, "No action for slot: %s", tostring(slot))
			_reset_gesture()
			return
		end

		Logger.info(LOG, "SWIPE FIRE: slot=%s action=%s dir=%s mf=%d dx=%.2f dy=%.2f elapsed=%.3fs",
			slot, _actions[slot], dir, mf, dx, dy, elapsed)
		_execute_action(_actions[slot])
		_reset_gesture()
		return
	end

	-- Active tracking: record start on first frame, update centroid.
	if n >= 2 then
		local pos = _avg_pos(touches)
		if not _gesture.active then
			Logger.debug(LOG, "GESTURE START: fingers=%d pos=(%.1f,%.1f)", n, pos.x, pos.y)
			_gesture.active      = true
			_gesture.start_time  = now
			_gesture.start_pos   = { x = pos.x, y = pos.y }
			_gesture.end_pos     = { x = pos.x, y = pos.y }
			_gesture.max_fingers = n
		else
			_gesture.end_pos = pos
			if n > _gesture.max_fingers then
				_gesture.max_fingers = n
			end
		end
	end
end

-- =========================================
-- =========================================
-- ======= 6/ Init =========================
-- =========================================
-- =========================================

--- Initialises the gestures module.
--- @param opts table|nil { enabled?, now_sec? } — now_sec injects a wall-clock
---   source (seconds) for tests; production uses the monotonic clock.
function M.init(opts)
	opts = type(opts) == "table" and opts or {}

	if type(opts.now_sec) == "function" then
		_now_sec = opts.now_sec
	end

	if opts.enabled == true then
		_enabled = true
		M.start_reading()
	end

	Logger.info(LOG, "Gestures manager initialised (enabled=%s).", tostring(_enabled))
end

return M
