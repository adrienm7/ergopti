--- modules/gestures/manager.lua

--- ==============================================================================
--- MODULE: Gestures Manager (Linux)
--- DESCRIPTION:
--- Binds gestures to actions, reads the touchpad, and runs the action a
--- completed gesture is bound to.
---
--- HOW A GESTURE GETS HERE:
--- `touchpad_finder` chooses the device by CAPABILITY rather than by name, and
--- reports how many fingers it can express before one has touched it.
--- `evdev_reader` opens its node — WITHOUT a grab, because grabbing a touchpad
--- takes the pointer from the compositor and leaves a dead cursor, and evdev is
--- broadcast so reading in parallel costs nothing. `mt_decoder` turns the
--- multitouch protocol into a finished gesture. This module dispatches it.
---
--- WHY NOT libinput, WHICH WOULD HAVE BEEN LESS CODE:
--- It gates its whole gesture state machine on `finger_count <= 4`, so
--- five-finger swipes never become events, and its documentation rules out taps
--- past three fingers. Against the 39 slots this project declares it can serve
--- 16 and none of the four taps. This module's header described that route as
--- the plan until 2026-08-05; it was never the plan, and scraping a subprocess
--- had already been removed from the keyboard path for four documented defects.
---
--- FEATURES & RATIONALE:
--- 1. Slot key-space shared with macOS, derived from
---    `_shared/modules/actions/actions.toml` so the two cannot drift.
--- 2. NO default bindings on this driver. The desktop acts on the same gesture —
---    every compositor claims 3- and 4-finger swipes, and two-finger motion is
---    scrolling everywhere — so a shipped binding fires twice with nothing on
---    screen to explain it. The user chooses.
--- 3. Emission through uinput, below the display server, so a chord reaches X11,
---    every Wayland compositor and a bare TTY alike. `xdotool` remains only as
---    the fallback for a device that could not be opened.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Paths = require("infra.paths")
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
local ACTIONS_TOML_REL_PATH = "modules/actions/actions.toml"
local UTF8_BOM = "\239\187\191"

--- Resolves the absolute path to the shared gesture actions TOML.
---
--- Through infra.paths, not by counting four path components up from this file.
--- The component count is the checkout layout written down: a system package
--- stages the driver flat under /usr/lib/ergopti, so four levels up leaves the
--- install entirely and every gesture silently falls back to its default.
--- @return string The absolute path, or "" when it cannot be resolved.
local function resolve_actions_toml_path()
	return Paths.shared(ACTIONS_TOML_REL_PATH) or ""
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

--- Linux ships NO default bindings. Every slot defaults to "none".
---
--- Emptied on 2026-08-05, on the maintainer's decision, and the reason is a
--- property of Linux rather than of this driver: the touchpad is read WITHOUT a
--- grab, because grabbing it would take the pointer from the compositor and
--- leave a dead cursor. evdev is broadcast, so the desktop sees every gesture
--- the daemon sees — and GNOME 47+, KWin, Hyprland and cosmic-comp all claim
--- 3- and 4-finger swipes already. A default binding there means the user's
--- gesture fires the daemon's action AND the desktop's, at once, on a fresh
--- install, with nothing on screen to explain it. Two-finger motion is scrolling
--- on every Linux desktop and has the same problem.
---
--- That is not fixable from here, so it is not papered over with a smaller
--- default set: the user chooses, and until they do the driver does nothing they
--- did not ask for.
---
--- The KEY-SPACE is untouched and comes from the shared TOML — all 36 single
--- slots and 3 axis slots are offered and configurable, exactly as on the other
--- two drivers. What differs is only which of them arrive pre-bound.
-- Where a gesture assignment is stored in the user's config.toml.
--
-- `[gestures]`, not `[linux.gestures]`. The driver-namespaced form was this
-- driver answering a question the shared manifest had already answered: the
-- manifest declares `gestures.swipe_3_up` and every feature under it, and a
-- second key space meant those features could never be declared for Linux
-- without the declaration being false. Two vocabularies for one setting is the
-- same defect as two defaults for one setting, and this repository has a gate
-- for the second and had nothing for the first.
--
-- The old section is still READ, once, and migrated — see load_user_config. A
-- rename that silently drops a user's bindings is worse than the divergence it
-- fixes.
local CONFIG_SECTION = "gestures"
local CONFIG_SECTION_PARAMS = "gesture_parameters"

-- What the section was called before 2026-08-06. Read on load so an existing
-- installation keeps its gestures, and never written.
local LEGACY_SECTION = "linux.gestures"
local LEGACY_SECTION_PARAMS = "linux.action_parameters"

local DEFAULT_ACTIONS = {}

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

--- The webview window each `open_*` action raises, by action id.
---
--- Data rather than branches so the set can be compared against the shared
--- catalogue by a gate: a table has a length, a chain of `elseif` does not.
local OPEN_WINDOW = {
	["open_metrics_typing"]    = "metrics_typing",
	["open_metrics_apps"]      = "metrics_apps",
	["open_hotstrings_editor"] = "hotstring_editor",
	["open_paths_editor"]      = "hotstrings_config_window",
}

--- The user-editable file each `open_*` action reveals, as a path resolver.
---
--- Resolvers rather than strings: the paths depend on $XDG_CONFIG_HOME and on
--- today's date, and freezing them at load would open yesterday's log after
--- midnight and the wrong directory under a changed environment.
local OPEN_PATH = {
	["open_config"]             = function(Paths) return Paths.config("config.toml") end,
	["open_personal_info"]      = function(Paths) return Paths.config("personal_info.toml") end,
	["open_personal_hotstrings"] = function(Paths) return Paths.config("personal_hotstrings.toml") end,
	["open_personal_shortcuts"] = function(Paths) return Paths.config("personal_shortcuts.toml") end,
	["open_logs_folder"]        = function() return require("infra.logger_sink").log_dir() end,
	["open_today_log"]          = function() return require("infra.logger_sink").main_log_path() end,
	["open_error_log"]          = function() return require("infra.logger_sink").errors_log_path() end,
}

--- The screenshot command for each capture action, one shell cascade per id.
---
--- WHY A CASCADE AND NOT ONE TOOL: there is no screenshot binary every Linux
--- desktop has. GNOME ships gnome-screenshot, KDE spectacle, wlroots
--- compositors grim + slurp, and X11 sessions usually have maim or scrot. Under
--- Wayland the X11 tools talk to nothing and exit ZERO, which is why the Wayland
--- candidates come first: a cascade ordered the other way would "succeed" and
--- capture nothing on exactly the desktops this driver targets.
---
--- `%s` is replaced with the destination path for the SAVE variants; the
--- clipboard variants take no path.
local SCREENSHOT_COMMANDS = {
	["screenshot_fullscreen_clipboard"] =
		"grim - | wl-copy || gnome-screenshot -c || spectacle -bnc || maim | xclip -selection clipboard -t image/png",
	["screenshot_fullscreen_save"] =
		"grim %s || gnome-screenshot -f %s || spectacle -bno %s || maim %s",
	["screenshot_region_clipboard"] =
		"grim -g \"$(slurp)\" - | wl-copy || gnome-screenshot -ac || spectacle -bnrc || maim -s | xclip -selection clipboard -t image/png",
	["screenshot_region_save"] =
		"grim -g \"$(slurp)\" %s || gnome-screenshot -af %s || spectacle -bnro %s || maim -s %s",
	["screenshot_window_clipboard"] =
		"gnome-screenshot -wc || spectacle -bnac || maim -i \"$(xdotool getactivewindow)\" | xclip -selection clipboard -t image/png",
	["screenshot_window_save"] =
		"gnome-screenshot -wf %s || spectacle -bnao %s || maim -i \"$(xdotool getactivewindow)\" %s",
}

--- Where a saved screenshot lands, and under what name.
---
--- $XDG_PICTURES_DIR when the user's desktop declares one, the conventional
--- ~/Pictures otherwise. The stamp is second-resolution so two captures in the
--- same minute do not overwrite each other — the failure would be silent, and
--- the file the user wanted is the one that disappeared.
--- @param kind string Short tag: "full", "reg" or "win".
--- @return string An absolute path.
local function screenshot_path(kind)
	local dir = os.getenv("XDG_PICTURES_DIR")
	if not dir or dir == "" then
		local ok, Paths = pcall(require, "infra.config_paths")
		dir = (ok and Paths.home() or ".") .. "/Pictures"
	end
	return string.format("%s/ergopti_%s_%s.png", dir, kind, os.date("%Y-%m-%d_%H-%M-%S"))
end

--- The tag each save action stamps into its filename.
local SCREENSHOT_KIND = {
	["screenshot_fullscreen_save"] = "full",
	["screenshot_region_save"]     = "reg",
	["screenshot_window_save"]     = "win",
}

local function _execute_action(action_name, go_next, binding)
	if not action_name or action_name == "none" then return end

	local function _run(cmd)
		pcall(function() os.execute(cmd .. " 2>/dev/null &") end)
	end

	--- Raises one of the driver's own windows, or reveals one of its files.
	--- @param name string The action id.
	--- @return boolean True when this action was handled here.
	local function _open_driver_surface(name)
		local window = OPEN_WINDOW[name]
		if window then
			local ok, Webview = pcall(require, "ui.webview_manager")
			if not ok or type(Webview.show) ~= "function" then
				-- Loud, because the user asked for a window and none appeared. A
				-- headless daemon (no GTK, no display) is the ordinary reason and it
				-- is worth naming rather than leaving the chord looking dead.
				Logger.error(LOG, "No webview manager — '%s' cannot open its window.", name)
				return true
			end
			pcall(Webview.show, window)
			return true
		end

		local resolver = OPEN_PATH[name]
		if not resolver then return false end
		local ok_paths, Paths = pcall(require, "infra.config_paths")
		if not ok_paths then
			Logger.error(LOG, "Cannot resolve paths — '%s' has nothing to open.", name)
			return true
		end
		local ok_path, target = pcall(resolver, Paths)
		if not ok_path or type(target) ~= "string" or target == "" then
			Logger.error(LOG, "'%s' resolved to no path — nothing opened.", name)
			return true
		end
		-- xdg-open on a file that does not exist fails silently, so say so here
		-- instead: a personal_*.toml the user has never created is the common case
		-- and "nothing happened" is not a usable answer.
		local probe = io.open(target, "r")
		if probe then
			probe:close()
		elseif not target:match("/$") then
			Logger.warn(LOG, "'%s' points at '%s', which does not exist yet.", name, target)
		end
		_run("xdg-open " .. shell_quote(target))
		return true
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
		-- uinput first, xdotool only if it could not be written.
		--
		-- `xdotool key` is X11 only, and under Wayland it talks to nothing: the
		-- command succeeds, the shell exits zero, and the gesture does nothing.
		-- That is the worst shape of failure, because there is no error to find.
		-- uinput sits BELOW the display server, so the same chord reaches X11,
		-- every Wayland compositor and a bare TTY alike.
		--
		-- The fallback stays for the case where the device could not be opened at
		-- all — on X11 that still works, and losing it would trade a real failure
		-- mode for a worse one.
		local ok_emitter, Emitter = pcall(require, "modules.gestures.combo_emitter")
		if ok_emitter and Emitter.press(emit_combo) then return end
		Logger.debug(LOG, "uinput unavailable for '%s' — falling back to xdotool (X11 only).",
			emit_combo)
		_run("xdotool key " .. emit_combo)
		return
	end

	-- The driver's own windows and files. These are declared platform = "all" in
	-- the shared catalogue, so the picker has always offered them as bindable on
	-- Linux — and binding one stored the assignment, fired on the chord, and hit
	-- the "Unknown action" branch at DEBUG. No error at bind time, none at fire
	-- time; the user concludes the shortcut feature is broken.
	if _open_driver_surface(action_name) then return end

	-- Screenshots, likewise declared for every platform and implemented on none
	-- of Linux until now.
	local shot = SCREENSHOT_COMMANDS[action_name]
	if shot then
		local kind = SCREENSHOT_KIND[action_name]
		if kind then
			-- Quoted once and substituted everywhere: the same path goes to each
			-- candidate in the cascade, and a path with a space in it must survive
			-- all four of them.
			shot = shot:gsub("%%s", (shell_quote(screenshot_path(kind)):gsub("%%", "%%%%")))
		end
		_run(shot)
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
local _reading       = false -- the touchpad's evdev node is open and being drained
local _decoder       = nil   -- the multitouch frame decoder for that device
local _touchpad      = nil   -- what touchpad_finder chose, and what it can express

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

--- Enables gesture processing after the touchpad reader is live.
--- @return boolean True when gestures are enabled and readable.
function M.enable()
	if not M.start_reading() then
		_enabled = false
		Logger.error(LOG, "Gestures remain disabled because the touchpad reader could not start.")
		return false
	end
	_enabled = true
	Logger.info(LOG, "Gestures enabled.")
	return true
end

--- Disables gesture processing.
function M.disable()
	_enabled = false
	M.stop_reading()
	Logger.info(LOG, "Gestures disabled.")
end

--- Toggles gestures on/off.
function M.toggle()
	if _enabled then
		M.disable()
		return false
	end
	return M.enable()
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
	M._persist_updates({ { section = CONFIG_SECTION, key = slot, value = action_name } })
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
	M._persist_updates({ { section = CONFIG_SECTION_PARAMS, key = key, value = value } })
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
		updates[#updates + 1] = { section = CONFIG_SECTION, key = k, value = v }
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
		updates[#updates + 1] = { section = CONFIG_SECTION, key = slot, value = "none" }
	end
	M._persist_updates(updates)
	Logger.info(LOG, "Every gesture binding was set to none.")
end

-- =========================================
-- =========================================
-- ======= 5/ Geometry Helpers =============
-- =========================================
-- =========================================

-- The thresholds, the centroid helper, _compute_dir and _slot_for_dir were
-- removed on 2026-08-05 along with process_frame, the only thing that used
-- them. mt_decoder carries its own threshold and names directions itself;
-- a second copy of the naming rule is what let the decoder emit "up_right"
-- against a slot space that spells it "right_up".

-- ======= 6/ Touch Event Engine ===========
-- =========================================
-- =========================================

-- The per-gesture tracking state that lived here went with process_frame: the
-- decoder owns it now, because tracking a gesture and decoding the protocol that
-- describes it are the same job and splitting them across two modules is how the
-- two came to disagree about what a diagonal is called.

--- The slot name a completed gesture belongs to.
--- @param fingers integer
--- @param direction string|nil
--- @param tap boolean
--- @return string|nil
local function _slot_for_gesture(fingers, direction, tap)
	if type(fingers) ~= "number" or fingers < 1 then return nil end
	if tap then return "tap_" .. math.min(fingers, 5) end
	if type(direction) ~= "string" or direction == "" then return nil end
	return string.format("swipe_%d_%s", math.min(fingers, 5), direction)
end

--- Runs one action by name, whatever asked for it.
---
--- Exposed because the gesture manager owns the action catalogue, the labels and
--- the execution, and the configurable keyboard shortcuts bind the same
--- catalogue. A second executor there would be a second implementation of
--- "select the word", drifting from this one the first time either is touched.
--- @param action_name string From M.get_action_names().
--- @param binding string|nil What asked for it, for the logs and the parameters.
--- @return boolean True when a name was given at all.
function M.execute_action(action_name, binding)
	if type(action_name) ~= "string" or action_name == "" or action_name == "none" then
		return false
	end
	_execute_action(action_name, nil, binding)
	return true
end

--- Runs the action bound to a gesture the decoder has already classified.
---
--- Separate from process_frame, which does its own classification from a list of
--- touch points. This takes the finished answer — how many fingers, which way —
--- because the decoder reads the count the KERNEL reports rather than inferring
--- it from how many contacts it could locate. libinput describes devices that
--- count more fingers than they can position as "the vast majority of
--- touchpads", so inferring it is wrong on most hardware.
--- @param gesture table { fingers, direction, tap }
--- @return boolean True when an action ran.
function M.dispatch_gesture(gesture)
	if not _enabled or type(gesture) ~= "table" then return false end

	local slot = _slot_for_gesture(gesture.fingers, gesture.direction, gesture.tap)
	if not slot then
		Logger.debug(LOG, "Gesture with no slot: fingers=%s direction=%s tap=%s",
			tostring(gesture.fingers), tostring(gesture.direction), tostring(gesture.tap))
		return false
	end

	local action = _actions[slot]
	if not action or action == "none" then
		-- Not a warning. Linux ships no default bindings, so an unbound slot is
		-- the normal state until the user chooses — saying so at INFO would make
		-- every stray touch a log line.
		Logger.debug(LOG, "No action bound to %s.", slot)
		return false
	end

	Logger.info(LOG, "GESTURE FIRE: slot=%s action=%s", slot, action)
	_execute_action(action, nil, slot)
	return true
end

--- Starts reading the touchpad.
---
--- Reads the device's evdev node directly, WITHOUT a grab, and decodes the
--- multitouch protocol in process. The docstring here used to describe scraping
--- `libinput debug-events`; that route is rejected in todo_linux.md §12.3 for
--- two independent reasons — this driver removed exactly that pattern from the
--- keyboard path for four documented defects, and libinput gates its whole
--- gesture state machine on `finger_count <= 4`, so five-finger swipes and
--- multi-finger taps never leave it at all.
--- @return boolean True when a touchpad was found and opened.
function M.start_reading()
	if _reading then return true end

	local ok_finder, Finder = pcall(require, "modules.gestures.touchpad_finder")
	local ok_reader, Reader = pcall(require, "adapters.evdev_reader")
	local ok_decoder, Decoder = pcall(require, "modules.gestures.mt_decoder")
	if not (ok_finder and ok_reader and ok_decoder) then
		Logger.error(LOG, "Gesture reading needs touchpad_finder, evdev_reader and mt_decoder — one is missing.")
		return false
	end

	local touchpad, reason = Finder.find()
	if not touchpad then
		-- Not an error: a desktop machine has no touchpad, and gestures are simply
		-- unavailable there. Said once, at INFO, so a user who expected them can
		-- tell this apart from a silent failure.
		Logger.info(LOG, "No touchpad found (%s) — gestures are unavailable on this machine.",
			tostring(reason))
		return false
	end

	if not Reader.open(touchpad.path, Reader.TOUCHPAD) then
		Logger.error(LOG, "Could not open %s for reading — check membership of the 'input' group.",
			touchpad.path)
		return false
	end

	_decoder = Decoder.new()
	_touchpad = touchpad
	_reading = true
	Logger.success(LOG, "Reading %s (%s), up to %d finger(s)%s.",
		touchpad.path, touchpad.name, touchpad.max_fingers,
		touchpad.semi_mt and ", semi-MT" or "")
	return true
end

--- Drains whatever the touchpad has produced since the last call.
---
--- Called from the daemon's pump, like the keyboard's. Returns the number of
--- events consumed so a caller can tell a quiet tick from a stalled reader.
--- @return integer
function M.pump()
	if not _reading or not _decoder then return 0 end

	local ok_reader, Reader = pcall(require, "adapters.evdev_reader")
	if not ok_reader then return 0 end

	return Reader.drain(function(event)
		local gesture = _decoder:feed(event)
		if gesture then M.dispatch_gesture(gesture) end
	end, Reader.TOUCHPAD)
end

--- Stops reading the touchpad.
function M.stop_reading()
	if _reading then
		local ok_reader, Reader = pcall(require, "adapters.evdev_reader")
		if ok_reader and type(Reader.close) == "function" then
			pcall(Reader.close, Reader.TOUCHPAD)
		end
	end
	-- Dropping the decoder IS the reset: it holds the slot state and the latched
	-- finger count, so a half-finished gesture cannot survive into the next
	-- reader. There is no separate tracking state left to clear.
	_reading = false
	_decoder = nil
	_touchpad = nil
	Logger.info(LOG, "Touchpad reader stopped.")
end

--- The touchpad being read, or nil.
--- @return table|nil
function M.touchpad()
	return _touchpad
end

--- Test seam: puts the manager into the reading state with a given decoder.
---
--- `start_reading` needs a real /proc entry and a real device node, so the join
--- between the reader, the decoder and the dispatcher could only be exercised on
--- a machine with a touchpad — which is to say nowhere the unit suite runs. This
--- opens that seam and nothing else: the pump, the decoder and the dispatch are
--- all the real ones, and only the device underneath is faked.
--- @param decoder table An mt_decoder instance.
function M._test_begin_reading(decoder)
	_decoder = decoder
	_reading = true
end

--- Returns true if the touch reader is active.
--- @return boolean
function M.is_reading()
	return _reading
end

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
	if not ok or type(config) ~= "table" then return end

	--- Applies one section's slot→action pairs.
	--- @param section table|nil
	local function apply_actions(section)
		if type(section) ~= "table" then return end
		for slot, action in pairs(section) do
			if M.DEFAULT_GESTURES[slot]
				and (action == "none" or ACTION_I18N_KEYS[action] or ACTION_COMPUTED_LABELS[action])
			then
				_actions[slot] = action
			end
		end
	end

	--- Applies one section's parameter overrides.
	--- @param section table|nil
	local function apply_params(section)
		if type(section) ~= "table" then return end
		for key, value in pairs(section) do
			local binding, action = M.split_action_parameter_key(key)
			if binding and action and M.validate_action_parameter(action, value) then
				_action_params[key] = value
			end
		end
	end

	-- The legacy `[linux.gestures]` section FIRST, then the canonical one over
	-- it. Order matters: a user who has already written a binding under the new
	-- name after the migration must not have it overwritten by whatever the old
	-- section still says. A rename that silently drops a user's bindings is worse
	-- than the divergence it fixes.
	local legacy = type(config.linux) == "table" and config.linux or nil
	if legacy then
		apply_actions(legacy.gestures)
		apply_params(legacy.action_parameters)
		if type(legacy.gestures) == "table" and next(legacy.gestures) ~= nil then
			Logger.info(LOG,
				"Gestures read from the legacy [%s] section — they will be rewritten under [%s] on the next change.",
				LEGACY_SECTION, CONFIG_SECTION)
		end
	end

	apply_actions(config[CONFIG_SECTION])
	apply_params(config[CONFIG_SECTION_PARAMS])
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

	if opts.enabled == true then M.enable() end

	Logger.info(LOG, "Gestures manager initialised (enabled=%s).", tostring(_enabled))
end

return M
