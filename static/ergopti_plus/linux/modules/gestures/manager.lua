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
local Timings = require("infra.timings")
local Monotonic = require("infra.monotonic")
local TomlCodec = require("toml_codec")
local i18n = require("infra.i18n")
local LOG = "modules.gestures.manager"

-- Actions the shared catalogue describes as a single xdotool combo, generated
-- from _shared/modules/actions/actions.toml. Loaded once at require time.
--
-- Fails loudly rather than falling back to an empty table: an empty table means
-- 26 gestures silently do nothing, which is indistinguishable from a user
-- mis-configuring them and is exactly the class of failure this driver has been
-- bitten by before.
local _ok_emit, _EMIT_ROWS = pcall(require, "_generated.gesture_emit_actions")
if not _ok_emit or type(_EMIT_ROWS) ~= "table" then
	Logger.error(LOG, "_generated/gesture_emit_actions.lua is missing or invalid (%s) — "
		.. "26 gesture actions will not fire. Run `npm run gen`.", tostring(_EMIT_ROWS))
	_EMIT_ROWS = {}
end
local _writer_ok, TomlWriter = pcall(require, "toml_codec.writer")
if not _writer_ok then TomlWriter = nil end

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

-- The gesture slot key-space (tap/swipe slot names) is the SINGLE SOURCE shared
-- with the macOS driver, declared once in _shared/modules/actions/actions.toml
-- under [slots]. This driver derives SINGLE_SLOTS / AXIS_SLOTS and the
-- DEFAULT_GESTURES key-space from that file at load time so the two drivers can
-- never drift. Only the default action VALUES below stay Linux-specific.
local ACTIONS_TOML_REL_PATH = "/_shared/modules/actions/actions.toml"
local UTF8_BOM = "\239\187\191"

--- Resolves the absolute path to the shared gesture actions TOML from this
--- module's own location (…/linux/modules/gestures/manager.lua → …/_shared/…).
--- @return string The absolute path, or "" when it cannot be resolved.
local function resolve_actions_toml_path()
	local src = debug and debug.getinfo and debug.getinfo(1, "S")
	if src and src.source then
		local s = src.source
		if s:sub(1, 1) == "@" or s:sub(1, 1) == "=" then s = s:sub(2) end
		s = s:gsub("\\", "/")
		local root = s:match("^(.*)/[^/]+/[^/]+/[^/]+/[^/]+$")
		if root then
			return root .. ACTIONS_TOML_REL_PATH
		end
	end
	return ""
end

--- Reads the ordered [slots].single / [slots].axis lists from the shared actions
--- TOML. Fails loud with an ERROR log and returns empty lists on any
--- resolve/read/parse failure — the slot-space is a shipped resource, so a
--- failure is a broken install, never a reason to duplicate a hardcoded list.
--- @return table, table The ordered single-slot and axis-slot name lists.
local function load_slot_space()
	local path = resolve_actions_toml_path()
	if path == "" then
		Logger.error(LOG, "Could not resolve the shared gesture actions TOML path — slot-space not loaded.")
		return {}, {}
	end
	local fh = io.open(path, "r")
	if not fh then
		Logger.error(LOG, "Shared gesture actions TOML unreadable at '%s'.", path)
		return {}, {}
	end
	local content = fh:read("*a")
	fh:close()
	if type(content) == "string" and content:sub(1, 3) == UTF8_BOM then
		content = content:sub(4)
	end
	local ok, data = pcall(TomlCodec.decode, content)
	if not ok or type(data) ~= "table" or type(data.slots) ~= "table" then
		Logger.error(LOG, "Shared gesture actions TOML failed to parse — slot-space not loaded.")
		return {}, {}
	end
	local single = type(data.slots.single) == "table" and data.slots.single or {}
	local axis   = type(data.slots.axis) == "table"   and data.slots.axis   or {}
	return single, axis
end

--- Reads parameter metadata from the same shared catalogue as the picker, so
--- future configurable actions do not require a Linux-specific allowlist.
local function load_action_parameter_specs()
	local path = resolve_actions_toml_path()
	local fh = path ~= "" and io.open(path, "r") or nil
	if not fh then return {} end
	local content = fh:read("*a")
	fh:close()
	if content:sub(1, 3) == UTF8_BOM then content = content:sub(4) end
	local ok, data = pcall(TomlCodec.decode, content)
	if not ok or type(data) ~= "table" or type(data.sg_actions) ~= "table" then return {} end
	local specs = {}
	for name, meta in pairs(data.sg_actions) do
		if type(meta) == "table" and type(meta.parameter) == "string" then specs[name] = meta.parameter end
	end
	return specs
end

--- All single / axis gesture slots (derived from the shared [slots] section).
M.SINGLE_SLOTS, M.AXIS_SLOTS = load_slot_space()
M.ACTION_PARAMETER_SPECS = load_action_parameter_specs()

--- Linux-specific default action VALUES. Every slot not listed defaults to
--- "none". The KEY-SPACE comes from the shared TOML, never from these keys:
--- 3-finger swipe → workspace nav, 4-finger swipe → volume/brightness.
local DEFAULT_ACTIONS = {
	tap_3         = "left_click_toggle",
	tap_4         = "app_window_previous",
	swipe_3_left  = "ws_prev",
	swipe_3_right = "ws_next",
	swipe_3_up    = "tab_prev",
	swipe_3_down  = "tab_next",
	swipe_4_left  = "vol_down",
	swipe_4_right = "vol_up",
	swipe_4_up    = "brightness_up",
	swipe_4_down  = "brightness_down",
}

--- Default gesture-to-action mapping. The key-space is the union of the derived
--- single and axis slots; each value is the Linux default (or "none").
M.DEFAULT_GESTURES = {}
for _, slot in ipairs(M.SINGLE_SLOTS) do
	M.DEFAULT_GESTURES[slot] = DEFAULT_ACTIONS[slot] or "none"
end
for _, slot in ipairs(M.AXIS_SLOTS) do
	M.DEFAULT_GESTURES[slot] = DEFAULT_ACTIONS[slot] or "none"
end

-- =========================================
-- =========================================
-- ======= 2/ Action Registry ==============
-- =========================================
-- =========================================

--- The registry of supported action ids, mapped to their suffix in the shared
--- `sg_actions.*` catalogue.
---
--- This table used to hold hardcoded FRENCH labels, described as a "fallback
--- when i18n is absent" — but nothing ever replaced them, so every user of the
--- other 20 locales read French gesture names. The catalogue they belong in
--- already existed, already carried all 21 translations, and was already
--- consumed by the two other drivers; only Linux was not reading it.
---
--- Two ids differ from their catalogue name: this driver calls a virtual desktop
--- a "workspace", the shared catalogue calls it a desktop. The mapping lives
--- here rather than in a rename so the persisted config.toml of existing users
--- keeps resolving.
local ACTION_I18N_KEYS = {
	open_url                    = "open_url",
	search_web                  = "search_web",
	none                        = "none",
	left_click_toggle           = "left_click_toggle",
	right_click_toggle          = "right_click_toggle",
	ws_prev                     = "desktop_prev",
	ws_next                     = "desktop_next",
	tab_prev                    = "tab_prev",
	tab_next                    = "tab_next",
	vol_up                      = "vol_up",
	vol_down                    = "vol_down",
	mute                        = "mute",
	brightness_up               = "brightness_up",
	brightness_down             = "brightness_down",
	track_play                  = "track_play",
	track_next                  = "track_next",
	track_prev                  = "track_prev",
	app_switcher                = "app_switcher",
	app_window_previous         = "app_window_previous",
	close_window                = "close_window",
	maximize                    = "maximize",
	snap_left                   = "snap_left",
	snap_right                  = "snap_right",
	fullscreen                  = "fullscreen",
	word_prev                   = "word_prev",
	word_next                   = "word_next",
	line_up                     = "line_up",
	line_down                   = "line_down",
	line_start                  = "line_start",
	line_end                    = "line_end",
	doc_start                   = "doc_start",
	doc_end                     = "doc_end",
	enter                       = "enter",
	escape                      = "escape",
	backspace                   = "backspace",
	delete                      = "delete",
	arrow_up                    = "arrow_up",
	arrow_down                  = "arrow_down",
	arrow_left                  = "arrow_left",
	arrow_right                 = "arrow_right",
	lock_screen                 = "lock_screen",
	notification_center         = "notification_center",
}

--- Labels COMPUTED at registration time for the modifier-chord actions
--- ("Ctrl + Shift + A"). They are language-neutral by construction — modifier
--- and key names are the same in every locale — so they are stored as labels
--- rather than as catalogue keys.
local ACTION_COMPUTED_LABELS = {}

-- Dynamic modifier-key actions use the same shared catalogue as Windows and
-- macOS. Their labels are intentionally language-neutral (for example
-- "Ctrl + A") and therefore bypass the locale layer entirely.
local MODIFIER_ACTION_COMMANDS = {}

local function load_modifier_chords()
	-- The JSON path is derived by rewriting the FILENAME of actions.toml, so the
	-- two files must stay siblings. That is not obvious from either end, and it
	-- broke exactly once: moving actions.toml to _shared/modules/actions/ while
	-- modifier_chords.json stayed behind made this resolve to a file that does not
	-- exist, and the only symptom was the modifier-chord labels quietly going
	-- missing from the action picker.
	local actions_path = resolve_actions_toml_path()
	local path = actions_path:gsub("actions%.toml$", "modifier_chords.json")
	if path == actions_path then return nil end
	local fh = io.open(path, "r")
	if not fh then
		Logger.warn(LOG, "Shared modifier chords JSON unreadable at '%s'.", path)
		return nil
	end
	local raw = fh:read("*a")
	fh:close()
	local ok_json, json = pcall(require, "json")
	if not ok_json or type(json) ~= "table" or type(json.decode) ~= "function" then
		Logger.warn(LOG, "JSON decoder unavailable — modifier chord actions skipped.")
		return nil
	end
	local ok_decode, data = pcall(json.decode, raw)
	if not ok_decode or type(data) ~= "table" then
		Logger.warn(LOG, "Shared modifier chords JSON failed to parse.")
		return nil
	end
	return data
end

local function register_modifier_chords(catalogue)
	local platform = catalogue and catalogue.platforms and catalogue.platforms.linux
	local modifiers = platform and platform.modifiers
	local keys = catalogue and catalogue.keys
	if type(modifiers) ~= "table" or type(keys) ~= "table" then return end

	local max_mask = (2 ^ #modifiers) - 1
	for mask = 1, max_mask do
		local ids, labels, native_modifiers = {}, {}, {}
		for index, modifier in ipairs(modifiers) do
			if math.floor(mask / (2 ^ (index - 1))) % 2 == 1 then
				ids[#ids + 1] = modifier.id
				labels[#labels + 1] = modifier.label
				native_modifiers[#native_modifiers + 1] = modifier.xdotool
			end
		end
		local id_prefix = table.concat(ids, "_")
		local label_prefix = table.concat(labels, " + ")
		for _, key_def in ipairs(keys) do
			local action_id = id_prefix .. "_" .. key_def.id
			local key = key_def.linux_key or key_def.id
			ACTION_COMPUTED_LABELS[action_id] = label_prefix .. " + " .. key_def.label
			MODIFIER_ACTION_COMMANDS[action_id] = table.concat(native_modifiers, "+") .. "+" .. key
		end
	end
end

register_modifier_chords(load_modifier_chords())

--- Executes a gesture action via xdotool/ytool on Linux.
--- @param action_name string The action identifier.
--- @param go_next boolean|nil Direction for axis actions (true = next, false/nil = prev).
local function shell_quote(value)
	return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function url_encode_query(value)
	return (tostring(value or ""):gsub("[^%w%-%._~]", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

local function primary_selection()
	local pipe = io.popen("xclip -o -selection primary 2>/dev/null", "r")
	if not pipe then return "" end
	local value = pipe:read("*a") or ""
	pipe:close()
	return (value:gsub("%s+$", ""))
end

--- A shell command that switches to the workspace `delta` steps away.
---
--- `wmctrl -s` takes an ABSOLUTE, zero-based desktop index and has no relative
--- form. This shipped as `wmctrl -s -1` and `wmctrl -s +1`, which wmctrl rejects
--- every time — so the wmctrl branch was dead and the `||` fallback carried the
--- feature, which makes both actions silently X11-only. libinput-gestures hit the
--- same wall and had to add its own ws_up/ws_down for exactly this reason.
---
--- The neighbour is therefore computed from `wmctrl -d`, whose current desktop is
--- the row marked `*`, with wraparound at both ends. The keystroke fallback stays
--- for the case where wmctrl is absent, and it is the only thing that can work at
--- all under Wayland — where switching workspace from another process is not
--- expressible except as a combination the compositor already binds.
--- @param delta integer -1 for the previous workspace, 1 for the next.
--- @param fallback_keys string An xdotool key combination to try when wmctrl fails.
--- @return string
local function workspace_switch_command(delta, fallback_keys)
	-- Single-quoted so the awk program reaches the shell intact; it contains no
	-- single quotes of its own, which is what makes that safe here.
	local awk = "awk -v d=" .. tostring(delta)
		.. " '$2==\"*\"{cur=$1} END{n=NR; if(n>0){t=(cur+d)%n; if(t<0)t+=n; print t}}'"
	return "{ wmctrl -d | " .. awk .. " | xargs -r wmctrl -s ; } 2>/dev/null"
		.. " || xdotool key " .. fallback_keys
end

local function _execute_action(action_name, go_next, binding)
	if not action_name or action_name == "none" then return end

	local function _run(cmd)
		pcall(function() os.execute(cmd .. " 2>/dev/null &") end)
	end

	local modifier_command = MODIFIER_ACTION_COMMANDS[action_name]
	if modifier_command then
		_run("xdotool key " .. modifier_command)
		return
	end

	-- Actions the shared catalogue describes as one xdotool combo.
	--
	-- 26 elseif branches used to sit here, each spelling out a combo that the
	-- macOS and Windows registries also spelled out in their own vocabularies.
	-- They now come from _shared/modules/actions/actions.toml via
	-- _generated/gesture_emit_actions.lua. The combos are X11 keysym syntax and
	-- are Linux's own: Linux and Windows agree far more often than either agrees
	-- with macOS (alt+F4 and ctrl+Right on both, against cmd+w and alt+right).
	local emit_combo = _EMIT_ROWS[action_name]
	if emit_combo then
		_run("xdotool key " .. emit_combo)
		return
	end

	if action_name == "open_url" then
		local url = M.get_action_parameter(binding, action_name)
		if M.validate_action_parameter(action_name, url) then _run("xdg-open " .. shell_quote(url)) end
		return
	elseif action_name == "search_web" then
		local template = M.get_action_parameter(binding, action_name)
		if M.validate_action_parameter(action_name, template) then
			_run("xdg-open " .. shell_quote((template:gsub("%%s", url_encode_query(primary_selection())))))
		end
		return
	end

	if action_name == "left_click_toggle" then
		-- Toggle mouse button hold via xdotool.
		_run("xdotool mousedown 1")
	elseif action_name == "right_click_toggle" then
		_run("xdotool mousedown 3")
	elseif action_name == "ws_prev" then
		_run(workspace_switch_command(-1, "ctrl+alt+Left"))
	elseif action_name == "ws_next" then
		_run(workspace_switch_command(1, "ctrl+alt+Right"))
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
	elseif action_name == "lock_screen" then
		_run("loginctl lock-session 2>/dev/null || xdg-screensaver lock")
	else
		Logger.debug(LOG, "Unknown action: %s", action_name)
	end
end

--- Returns a human-readable label for an action.
--- @param action_name string
--- @return string
function M.get_action_label(action_name)
	if not action_name or action_name == "" then return "∅" end
	local computed = ACTION_COMPUTED_LABELS[action_name]
	if computed then return computed end
	local suffix = ACTION_I18N_KEYS[action_name]
	if not suffix then return action_name end
	return i18n.get("sg_actions." .. suffix)
end

--- Returns the list of all available action names.
--- @return table
function M.get_action_names()
	local names = {}
	for k in pairs(ACTION_I18N_KEYS) do
		names[#names + 1] = k
	end
	for k in pairs(ACTION_COMPUTED_LABELS) do
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
local _action_params = {}   -- binding__action -> configured value
local _config_path   = nil
local _persist       = false
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
	if action_name ~= "none" and not (ACTION_I18N_KEYS[action_name] or ACTION_COMPUTED_LABELS[action_name]) then
		Logger.warn(LOG, "Unknown action '%s' for slot '%s' — will be a no-op.",
			tostring(action_name), tostring(slot))
	end
	_actions[slot] = action_name
	M._persist_updates({ { section = "linux.gestures", key = slot, value = action_name } })
	Logger.info(LOG, "Gesture '%s' → '%s'.", slot, tostring(action_name))
end

function M.get_action_parameter_spec(action_name)
	return M.ACTION_PARAMETER_SPECS[action_name]
end

function M.validate_action_parameter(action_name, value)
	local spec = M.get_action_parameter_spec(action_name)
	if not spec then return true end
	if type(value) ~= "string" or not value:match("^https?://%S+$") then return false end
	if spec == "search_url" then
		local _, placeholders = value:gsub("%%s", "")
		return placeholders == 1
	end
	return true
end

local function parameter_key(binding, action_name)
	return tostring(binding or "") .. "__" .. tostring(action_name or "")
end

--- Splits a persisted binding__action key by the known action suffix, rather
--- than the first delimiter. Bindings such as keyboard__ctrl_k therefore keep
--- their scope intact when preferences are restored.
function M.split_action_parameter_key(key)
	if type(key) ~= "string" then return nil, nil end
	for action_name in pairs(M.ACTION_PARAMETER_SPECS) do
		local suffix = "__" .. action_name
		if key:sub(-#suffix) == suffix then
			return key:sub(1, #key - #suffix), action_name
		end
	end
	return nil, nil
end

function M.get_action_parameter(binding, action_name)
	return _action_params[parameter_key(binding, action_name)] or ""
end

function M.set_action_parameter(binding, action_name, value)
	if not M.validate_action_parameter(action_name, value) then return false end
	local key = parameter_key(binding, action_name)
	_action_params[key] = value
	M._persist_updates({ { section = "linux.action_parameters", key = key, value = value } })
	return true
end

function M.get_all_action_parameters()
	local copy = {}
	for key, value in pairs(_action_params) do copy[key] = value end
	return copy
end

function M.get_action_display_label(slot)
	local action = M.get_action(slot) or "none"
	local label = M.get_action_label(action)
	local value = M.get_action_parameter(slot, action)
	return value ~= "" and (label .. " (" .. value .. ")") or label
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
	local updates = {}
	for k, v in pairs(M.DEFAULT_GESTURES) do
		_actions[k] = v
		updates[#updates + 1] = { section = "linux.gestures", key = k, value = v }
	end
	M._persist_updates(updates)
	Logger.info(LOG, "Gestures reset to defaults.")
end

--- Replaces every gesture action by the empty no-op without changing the
--- master enable flag.
function M.disable_all_actions()
	local updates = {}
	for slot in pairs(M.DEFAULT_GESTURES) do
		_actions[slot] = "none"
		updates[#updates + 1] = { section = "linux.gestures", key = slot, value = "none" }
	end
	M._persist_updates(updates)
	Logger.info(LOG, "Every gesture binding was set to none.")
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
				_execute_action(_actions[tap_slot], nil, tap_slot)
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
		_execute_action(_actions[slot], nil, slot)
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

function M._persist_updates(updates)
	if not _persist or not TomlWriter or not _config_path or type(updates) ~= "table" or #updates == 0 then return true end
	local ok, err = TomlWriter.batch_write(_config_path, updates)
	if not ok then Logger.error(LOG, "Could not persist gesture configuration: %s", tostring(err)) end
	return ok
end

local function load_user_config(path)
	if type(path) ~= "string" or path == "" then return end
	local fh = io.open(path, "r")
	if not fh then return end
	local content = fh:read("*a")
	fh:close()
	local ok, config = pcall(TomlCodec.decode, content)
	local linux = ok and type(config) == "table" and config.linux or nil
	if type(linux) ~= "table" then return end
	if type(linux.gestures) == "table" then
		for slot, action in pairs(linux.gestures) do
			if M.DEFAULT_GESTURES[slot] and (action == "none" or ACTION_I18N_KEYS[action] or ACTION_COMPUTED_LABELS[action]) then _actions[slot] = action end
		end
	end
	if type(linux.action_parameters) == "table" then
		for key, value in pairs(linux.action_parameters) do
			local binding, action = M.split_action_parameter_key(key)
			if binding and action and M.validate_action_parameter(action, value) then _action_params[key] = value end
		end
	end
end

--- Initialises the gestures module.
--- @param opts table|nil { enabled?, now_sec? } — now_sec injects a wall-clock
---   source (seconds) for tests; production uses the monotonic clock.
function M.init(opts)
	opts = type(opts) == "table" and opts or {}

	if type(opts.now_sec) == "function" then
		_now_sec = opts.now_sec
	end
	_config_path = opts.config_path or require("infra.config_paths").config("config.toml")
	_persist = opts.persist == true
	if _persist then load_user_config(_config_path) end

	if opts.enabled == true then
		_enabled = true
		M.start_reading()
	end

	Logger.info(LOG, "Gestures manager initialised (enabled=%s).", tostring(_enabled))
end

return M
