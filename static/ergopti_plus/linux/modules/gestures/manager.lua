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
--- 1. Slot key-space and action catalogue shared with the other drivers,
---    generated from `_shared/modules/actions/actions.toml` into
---    `_generated/action_catalogue.lua` so none of them can drift.
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
local ConfigOutdated = require("config_outdated")
local BindingIdentity = require("config_binding_identity")
local Paths = require("infra.paths")
local Timings = require("infra.timings")
local Monotonic = require("infra.monotonic")
local Manifest = require("infra.manifest_reader")
local ParameterLabel = require("action_parameter_label")
local PromptAction = require("llm.prompt_action")
local Vision = require("llm.vision")
local AppParameter = require("app_parameter")
local TomlCodec = require("toml_codec")
local i18n = require("infra.i18n")
local ScriptActions = require("modules.shortcuts.script_actions")
local ShellRunner = require("adapters.shell_runner")
local DesktopNavigation = require("desktop_navigation")
local SystemActions = require("modules.gestures.system_actions")
local LOG = "modules.gestures.manager"
local ENABLED_PATH = "gestures.enabled"
local DEFAULT_ENABLED = Manifest.default_for(ENABLED_PATH)

if type(DEFAULT_ENABLED) ~= "boolean" then
	error("The manifest default for " .. ENABLED_PATH .. " must be a boolean.")
end

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

-- The Linux action catalogue, generated from _shared/modules/actions/actions.toml
-- by tools/codegen/codegen-action-catalogue.cjs and already filtered to this
-- platform: the slot key-space, the picker order with heading levels and locale
-- keys, and per-action metadata (label key, parameter kind, requirements).
--
-- It replaces a hard-coded table of 42 ids that the picker listed
-- alphabetically, without a heading and without the platform filter, so it hid
-- 38 actions this driver runs and offered none of the catalogue's structure.
-- Missing is a broken install: failing here names the cause, where an empty
-- table would leave every gesture binding silently doing nothing.
local _ok_catalogue, Catalogue = pcall(require, "_generated.action_catalogue")
if not _ok_catalogue or type(Catalogue) ~= "table" or type(Catalogue.actions) ~= "table"
	or type(Catalogue.sg_items) ~= "table" or type(Catalogue.slots) ~= "table" then
	error("_generated/action_catalogue.lua is missing or invalid — run `npm run gen`: "
		.. tostring(Catalogue))
end

-- Publish binding identity only from both complete generated inventories.
-- Runtime assignments and manifest defaults cannot prove a retired slot.
local parameter_binding_catalogue = { prefix = "", slots = {} }
for _, family in ipairs({ "single", "axis" }) do
	local slots = Catalogue.slots[family]
	assert(type(slots) == "table" and next(slots) ~= nil,
		"generated gesture " .. family .. " slots must be a nonempty dense string array")
	local count = 0
	for index, slot in pairs(slots) do
		assert(type(index) == "number" and index >= 1 and index % 1 == 0
			and type(slot) == "string" and slot ~= "" and not slot:find("__", 1, true),
			"generated gesture " .. family .. " slots must be a nonempty dense string array")
		assert(parameter_binding_catalogue.slots[slot] == nil,
			"generated gesture slot occurs more than once: " .. slot)
		parameter_binding_catalogue.slots[slot] = true
		count = count + 1
	end
	for index = 1, count do
		assert(slots[index] ~= nil, "generated gesture " .. family .. " slots must be dense")
	end
end

-- A confirmation is chained in front of a shell command (system_actions), so
-- an action the catalogue asks to confirm must be one: anything else would run
-- unasked. Checked once, here, rather than discovered on the first press.
for action_name, meta in pairs(Catalogue.actions) do
	if meta.confirm == true and SystemActions.COMMANDS[action_name] == nil then
		error("the catalogue asks to confirm '" .. action_name
			.. "', which is not a system command this driver can confirm")
	end
end

-- Wall-clock source (seconds) for gesture tap/swipe timing. Defaults to the
-- monotonic clock and is injectable via M.init for tests. Deliberately NOT
-- os.clock(): its CPU time barely advances in an I/O-bound daemon, so a gesture
-- held for seconds would report elapsed ~= 0 and be misclassified as a tap.
local _now_sec = Monotonic.now_sec

-- Which mouse buttons the click-toggle actions currently hold down ("1" for
-- left, "3" for right). Without this the toggle fires mousedown on every
-- invocation and the button sticks down in a drag until a manual mouseup.
local _click_toggle_down = { ["1"] = false, ["3"] = false }

--- Returns the xdotool command toggling one button hold, flipping the
--- remembered state: odd fires press, even fires release.
--- @param button string "1" for left, "3" for right.
--- @return string The xdotool command to run.
local function _click_toggle_command(button)
	_click_toggle_down[button] = not _click_toggle_down[button]
	if _click_toggle_down[button] then
		return "xdotool mousedown " .. button
	end
	return "xdotool mouseup " .. button
end

-- =========================================
-- =========================================
-- ======= 1/ Gesture Slot Registry ========
-- =========================================
-- =========================================

-- The gesture slot key-space (tap/swipe slot names) is the SINGLE SOURCE shared
-- with the macOS driver, declared once in _shared/modules/actions/actions.toml
-- under [slots] and carried into this driver's generated catalogue. Only the
-- default action VALUES below stay Linux-specific.

--- Copies one string list out of the generated catalogue, so a caller that
--- edits the result cannot edit the catalogue.
--- @param list table
--- @return table
local function copy_list(list)
	local out = {}
	for i, value in ipairs(list) do out[i] = value end
	return out
end

--- All single / axis gesture slots (the shared [slots] section).
M.SINGLE_SLOTS = copy_list(Catalogue.slots.single)
M.AXIS_SLOTS = copy_list(Catalogue.slots.axis)

-- Exclude picker headings and modifier groups from the declared action rows.
M.LINUX_DECLARED_ACTIONS = {}
for _, item in ipairs(Catalogue.sg_items) do
	if item.kind == "action" and item.id ~= "none" then
		M.LINUX_DECLARED_ACTIONS[#M.LINUX_DECLARED_ACTIONS + 1] = item.id
	end
end
table.sort(M.LINUX_DECLARED_ACTIONS)

--- action id -> parameter kind ("url", "search_url"), from the same catalogue
--- as the picker, so a configurable action needs no Linux-specific allowlist.
M.ACTION_PARAMETER_SPECS = {}
for action_name, meta in pairs(Catalogue.actions) do
	if meta.parameter then M.ACTION_PARAMETER_SPECS[action_name] = meta.parameter end
end

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

--- Default gesture-to-action mapping. The key-space is the union of the derived
--- single and axis slots; neutral values come from the shared manifest.
M.DEFAULT_GESTURES = {}
M.RECOMMENDED_GESTURES = {}
for _, slot in ipairs(M.SINGLE_SLOTS) do
	M.DEFAULT_GESTURES[slot] = Manifest.default_for("gestures." .. slot)
	M.RECOMMENDED_GESTURES[slot] = Manifest.recommended_for("gestures." .. slot)
end
for _, slot in ipairs(M.AXIS_SLOTS) do
	M.DEFAULT_GESTURES[slot] = Manifest.default_for("gestures." .. slot)
	M.RECOMMENDED_GESTURES[slot] = Manifest.recommended_for("gestures." .. slot)
end

-- =========================================
-- =========================================
-- ======= 2/ Action Registry ==============
-- =========================================
-- =========================================

--- Labels COMPUTED at registration time for the modifier-chord actions
--- ("Ctrl + Shift + A"). They are language-neutral by construction — modifier
--- and key names are the same in every locale — so they are stored as labels
--- rather than as catalogue keys.
local ACTION_COMPUTED_LABELS = {}

-- Dynamic modifier-key actions use the same shared catalogue as Windows and
-- macOS. Their labels are intentionally language-neutral (for example
-- "Ctrl + A") and therefore bypass the locale layer entirely.
local MODIFIER_ACTION_COMMANDS = {}

-- The chord matrix in picker order: one { label, actions } group per modifier
-- combination, as the other two drivers build it.
local MODIFIER_ACTION_GROUPS = {}

local function load_modifier_chords()
	local path = Paths.shared("modules/actions/modifier_chords.json")
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "Could not resolve the shared modifier chords JSON path.")
		return nil
	end
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
		local group = { label = label_prefix, actions = {} }
		for _, key_def in ipairs(keys) do
			local action_id = id_prefix .. "_" .. key_def.id
			local key = key_def.linux_key or key_def.id
			ACTION_COMPUTED_LABELS[action_id] = label_prefix .. " + " .. key_def.label
			MODIFIER_ACTION_COMMANDS[action_id] = table.concat(native_modifiers, "+") .. "+" .. key
			group.actions[#group.actions + 1] = action_id
		end
		MODIFIER_ACTION_GROUPS[#MODIFIER_ACTION_GROUPS + 1] = group
	end
end

register_modifier_chords(load_modifier_chords())

--- Runs a shell command in the background, discarding its output.
--- @param cmd string A fully composed command.
local function run_background(cmd)
	pcall(function() os.execute(cmd .. " 2>/dev/null &") end)
end

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

-- The four workspace actions and the step each asks for. The plain pair stops
-- at the first and the last workspace, as Windows and macOS do; the _wrap pair
-- goes on to the other end. modules/gestures/workspace_switcher.lua drives
-- whatever interface the session offers and presses the desktop's own shortcut
-- when there is none.
local WORKSPACE_ACTIONS = {
	desktop_prev      = { direction = DesktopNavigation.PREVIOUS, wrap = false },
	desktop_next      = { direction = DesktopNavigation.NEXT,     wrap = false },
	desktop_prev_wrap = { direction = DesktopNavigation.PREVIOUS, wrap = true },
	desktop_next_wrap = { direction = DesktopNavigation.NEXT,     wrap = true },
}

-- How long a media tool may take before its key is pressed instead.
local MEDIA_TOOL_TIMEOUT_S = 1

-- The media and brightness actions: the tool that drives the system, and the
-- media key the desktop binds to the same thing, pressed when the tool is
-- missing or refuses. The fallback was `xdotool key XF86...`, which exits zero
-- and presses nothing under Wayland, so a missing brightnessctl or playerctl
-- left the action dead with no error.
local BrightnessActions = require("brightness_actions")
local Brightness = BrightnessActions.load()
local MEDIA_ACTIONS = {
	vol_up          = { tool = "pactl set-sink-volume @DEFAULT_SINK@ +5%", key = "XF86AudioRaiseVolume" },
	vol_down        = { tool = "pactl set-sink-volume @DEFAULT_SINK@ -5%", key = "XF86AudioLowerVolume" },
	mute            = { tool = "pactl set-sink-mute @DEFAULT_SINK@ toggle", key = "XF86AudioMute" },
	brightness_up   = { tool = BrightnessActions.linux_command(Brightness, "brightness_up"), key = Brightness.actions.brightness_up.linux_key },
	brightness_down = { tool = BrightnessActions.linux_command(Brightness, "brightness_down"), key = Brightness.actions.brightness_down.linux_key },
	track_play      = { tool = "playerctl play-pause", key = "XF86AudioPlay" },
	track_next      = { tool = "playerctl next", key = "XF86AudioNext" },
	track_prev      = { tool = "playerctl previous", key = "XF86AudioPrev" },
}

--- The webview window each `open_*` action raises, by action id.
---
--- Data rather than branches so the set can be compared against the shared
--- catalogue by a gate: a table has a length, a chain of `elseif` does not.
local OPEN_WINDOW = {
	["open_metrics_typing"]    = "metrics_typing",
	["open_metrics_apps"]      = "metrics_apps",
	["open_hotstrings_editor"] = "hotstring_editor",
	["open_paths_editor"]      = "paths_editor",
}

--- The user-editable file each `open_*` action reveals, as a path resolver.
---
--- Resolvers rather than strings: the paths depend on $XDG_CONFIG_HOME, and
--- freezing them at load would open the wrong directory under a changed
--- environment.
local OPEN_PATH = {
	["open_script_source"]      = function() return require("infra.paths").driver_root() .. "/ergopti_hotstrings.lua" end,
	["open_config"]             = function(Paths) return Paths.config("config.toml") end,
	["open_personal_info"]      = function(Paths) return Paths.config("personal_info.toml") end,
	["open_personal_hotstrings"] = function(Paths) return Paths.config("personal_hotstrings.toml") end,
	["open_personal_shortcuts"] = function(Paths) return Paths.config("personal_shortcuts.toml") end,
}

--- The three log actions, by ui/log_openers function: shared with the tray, so
--- a missing errors file is announced there and here alike.
local OPEN_LOG = {
	["open_logs_folder"] = "open_logs_folder",
	["open_today_log"]   = "open_today_log",
	["open_error_log"]   = "open_today_errors",
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

--- Actions this driver performs as one fixed shell command, by action id.
---
--- Data rather than an elseif chain, so the set of ids the executor answers is
--- enumerable and the catalogue parity test can compare it with the catalogue:
--- a chain of branches has no length, and an id falling off its end reached
--- "Unknown action" at DEBUG, the silent failure this table replaces.
local DIRECT_COMMANDS = {
	["lock_screen"] = "loginctl lock-session 2>/dev/null || xdg-screensaver lock",
	-- The user's own XDG Downloads directory (localised, relocatable), never a
	-- guessed ~/Downloads.
	["open_downloads"]    = 'xdg-open "$(xdg-user-dir DOWNLOAD)"',
	["open_file_manager"] = 'xdg-open "$HOME"',
}

--- The settings applications open_system_settings tries, in order: GNOME, KDE,
--- Xfce, Cinnamon, MATE, LXQt. Data, so the order is visible and testable.
local SETTINGS_APPLICATIONS = {
	"gnome-control-center", "systemsettings", "xfce4-settings-manager",
	"cinnamon-settings", "mate-control-center", "lxqt-config",
}

--- Actions that need more than one fixed command, by action id. Each receives
--- the binding that fired it, which parameterized actions read their value by.
local BUILTIN_HANDLERS = {
	["open_system_settings"] = function()
		local Shell = require("adapters.shell_runner")
		for _, application in ipairs(SETTINGS_APPLICATIONS) do
			if Shell.has_command(application) then
				run_background(shell_quote(application))
				return
			end
		end
		Logger.error(LOG, "open_system_settings: none of %s is installed — nothing opened.",
			table.concat(SETTINGS_APPLICATIONS, ", "))
	end,
	["left_click_toggle"] = function() run_background(_click_toggle_command("1")) end,
	["right_click_toggle"] = function() run_background(_click_toggle_command("3")) end,
	["open_chatgpt"] = function()
		return require("modules.shortcuts.chatgpt").open()
	end,
	["open_url"] = function(binding)
		local url = M.get_action_parameter(binding, "open_url")
		if M.validate_action_parameter("open_url", url) then
			run_background("xdg-open " .. shell_quote(url))
		end
	end,
	-- The binding's desktop-file id, launched the way the desktop's own
	-- launcher does (its Exec line, environment and startup notification).
	["open_app"] = function(binding)
		local app = M.get_action_parameter(binding, "open_app")
		if not M.validate_action_parameter("open_app", app) then
			Logger.warn(LOG, "open_app ignored for binding '%s': no valid application is stored.", tostring(binding))
			return
		end
		Logger.info(LOG, "Opening the application '%s'.", app)
		-- Desktop-file ids can begin with a dash; shell quoting preserves the
		-- argument but only the option boundary makes it an application operand.
		run_background("gtk-launch -- " .. shell_quote(app))
	end,
	["search_web"] = function(binding)
		local template = M.get_action_parameter(binding, "search_web")
		if not M.validate_action_parameter("search_web", template) then return end
		local query = primary_selection()
		if query == "" then
			Logger.warn(LOG, "search_web: no primary selection to search for — nothing opened.")
			return
		end
		-- Function replacement: the encoded query carries %XX sequences and a
		-- string replacement would read them as capture references ("invalid
		-- capture index" on the first space).
		local encoded = url_encode_query(query)
		run_background("xdg-open " .. shell_quote((template:gsub("%%s", function() return encoded end))))
	end,
}


-- Daemon-owned actions are injected during initialisation. Keeping lifecycle
-- operations out of this module prevents the gesture layer from owning reload
-- and shutdown state while still giving every catalogue action one executor.
local _action_handlers = {}

-- The daemon's pause state, injected by init(). Declared above every reader.
local function NEVER_PAUSED() return false end
local _is_paused = NEVER_PAUSED

local function _execute_action(action_name, go_next, binding)
	if not action_name or action_name == "none" then return end

	local function _run(cmd)
		pcall(function() os.execute(cmd .. " 2>/dev/null &") end)
	end

	--- Presses one combination: uinput first, xdotool only if it could not be
	--- written.
	---
	--- `xdotool key` is X11 only, and under Wayland it talks to nothing: the
	--- command succeeds, the shell exits zero, and the gesture does nothing.
	--- That is the worst shape of failure, because there is no error to find.
	--- uinput sits BELOW the display server, so the same chord reaches X11,
	--- every Wayland compositor and a bare TTY alike.
	---
	--- The fallback stays for the case where the device could not be opened at
	--- all — on X11 that still works, and losing it would trade a real failure
	--- mode for a worse one.
	--- @param combo string X keysym names joined by "+", as xdotool takes them.
	local function _press_combo(combo)
		local ok_emitter, Emitter = pcall(require, "modules.gestures.combo_emitter")
		if ok_emitter and Emitter.press(combo) then return end
		Logger.debug(LOG, "uinput unavailable for '%s' — falling back to xdotool (X11 only).", combo)
		_run("xdotool key " .. combo)
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

		local log_opener = OPEN_LOG[name]
		if log_opener then
			require("ui.log_openers")[log_opener](function(target)
				_run("xdg-open " .. shell_quote(target))
				return true
			end)
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
		run_background("xdg-open " .. shell_quote(target))
		return true
	end

	-- A modifier chord (Ctrl+A, the only Select All on Linux) and an action the
	-- shared catalogue describes as one xdotool combo are both one keystroke.
	--
	-- 26 elseif branches used to sit here, each spelling out a combo that the
	-- macOS and Windows registries also spelled out in their own vocabularies.
	-- They now come from _shared/modules/actions/actions.toml via
	-- _generated/gesture_emit_actions.lua. The combos are X11 keysym syntax and
	-- are Linux's own: Linux and Windows agree far more often than either agrees
	-- with macOS (alt+F4 and ctrl+Right on both, against cmd+w and alt+right).
	-- The modifier chords used to run their own `xdotool key` in the background,
	-- which did nothing under Wayland; they take the uinput path below as well.
	local emit_combo = MODIFIER_ACTION_COMMANDS[action_name] or _EMIT_ROWS[action_name]
	if emit_combo then
		_press_combo(emit_combo)
		return
	end

	-- The driver's own windows and files. These are declared platform = "all" in
	-- the shared catalogue, so the picker has always offered them as bindable on
	-- Linux — and binding one stored the assignment, fired on the chord, and hit
	-- the "Unknown action" branch at DEBUG. No error at bind time, none at fire
	-- time; the user concludes the shortcut feature is broken.
	if _open_driver_surface(action_name) then return end

	local handler = _action_handlers[action_name]
	if handler then
		-- A parameterized action receives the value stored for its binding, checked
		-- here once for every provider rather than by each handler.
		local parameter = nil
		if M.ACTION_PARAMETER_SPECS[action_name] then
			parameter = M.get_action_parameter(binding, action_name)
			if not M.validate_action_parameter(action_name, parameter) then
				Logger.warn(LOG, "'%s' ignored for binding '%s': its parameter is missing or invalid.",
					action_name, tostring(binding))
				return
			end
		end
		local ok, err = pcall(handler, binding, parameter)
		if not ok then
			Logger.error(LOG, "Action '%s' failed: %s.", action_name, tostring(err))
		end
		return
	end

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
		run_background(shot)
		return
	end

	local direct = DIRECT_COMMANDS[action_name]
	if direct then
		run_background(direct)
		return
	end

	if SystemActions.COMMANDS[action_name] then
		local meta = Catalogue.actions[action_name]
		local command = SystemActions.command_for(action_name, M.get_action_label(action_name),
			meta ~= nil and meta.confirm == true)
		if command then run_background(command) end
		return
	end
	local system_handler = SystemActions.HANDLERS[action_name]
	if system_handler then
		local ok, err = pcall(system_handler, {
			run_background = run_background,
			clipboard = require("adapters.clipboard"),
			emit_combo = require("modules.gestures.combo_emitter").press,
			sleep_ms = require("adapters.event_loop").sleep_ms,
		})
		if not ok then Logger.error(LOG, "Action '%s' failed: %s.", action_name, tostring(err)) end
		return
	end

	local workspace = WORKSPACE_ACTIONS[action_name]
	if workspace then
		-- Waited for: only the switcher's answer says whether the desktop's own
		-- shortcut is still needed.
		require("modules.gestures.workspace_switcher").switch(
			workspace.direction, workspace.wrap, _press_combo)
		return
	elseif MEDIA_ACTIONS[action_name] then
		-- The tool on its own, and waited for: only its exit status says whether
		-- the media key is still needed.
		local media = MEDIA_ACTIONS[action_name]
		if not ShellRunner.run("timeout " .. MEDIA_TOOL_TIMEOUT_S .. " " .. media.tool .. " >/dev/null 2>&1") then
			_press_combo(media.key)
		end
		return
	else
		local builtin = BUILTIN_HANDLERS[action_name]
		if builtin then
			builtin(binding)
			return
		end
	end

	-- WARN, not DEBUG: set_action refuses an id the catalogue does not offer, so
	-- reaching this line means a caller bypassed it or the catalogue lists an id
	-- no table here answers — the parity test's job, and worth seeing in a log.
	Logger.warn(LOG, "Unknown action: %s", action_name)
end

--- Returns a human-readable label for an action.
--- @param action_name string
--- @return string
function M.get_action_label(action_name)
	if not action_name or action_name == "" then return "∅" end
	local computed = ACTION_COMPUTED_LABELS[action_name]
	if computed then return computed end
	local meta = Catalogue.actions[action_name]
	if not meta then return action_name end
	return i18n.get(meta.label_key)
end

--- Returns the action ids the picker lists, in catalogue order, the
--- modifier-chord block expanded. "none" is included: it is a valid binding.
--- @return table
function M.get_action_names()
	local names = {}
	for _, item in ipairs(Catalogue.sg_items) do
		if item.kind == "action" then
			names[#names + 1] = item.id
		elseif item.kind == "modifier_chords" then
			for _, group in ipairs(MODIFIER_ACTION_GROUPS) do
				for _, action_id in ipairs(group.actions) do names[#names + 1] = action_id end
			end
		elseif item.kind ~= "heading" then
			error("unknown action catalogue item kind '" .. tostring(item.kind) .. "'")
		end
	end
	return names
end

--- Every id a binding may name: the listed actions and "none". Built once — the
--- catalogue and the chord matrix are fixed for the life of the daemon.
local ASSIGNABLE = {}
for _, action_name in ipairs(M.get_action_names()) do ASSIGNABLE[action_name] = true end
ASSIGNABLE["none"] = true

--- True when `action_name` is an action the catalogue offers on Linux.
--- @param action_name any
--- @return boolean
function M.is_assignable(action_name)
	return type(action_name) == "string" and ASSIGNABLE[action_name] == true
end

--- True when the executor has something that runs `action_name`. The same
--- tables _execute_action walks, so this cannot drift from the dispatch.
--- @param action_name string
--- @return boolean
function M.is_runnable(action_name)
	if action_name == "none" then return true end
	return MODIFIER_ACTION_COMMANDS[action_name] ~= nil
		or _EMIT_ROWS[action_name] ~= nil
		or OPEN_WINDOW[action_name] ~= nil
		or OPEN_PATH[action_name] ~= nil
		or OPEN_LOG[action_name] ~= nil
		or WORKSPACE_ACTIONS[action_name] ~= nil
		or MEDIA_ACTIONS[action_name] ~= nil
		or _action_handlers[action_name] ~= nil
		or SCREENSHOT_COMMANDS[action_name] ~= nil
		or DIRECT_COMMANDS[action_name] ~= nil
		or BUILTIN_HANDLERS[action_name] ~= nil
		or SystemActions.COMMANDS[action_name] ~= nil
		or SystemActions.HANDLERS[action_name] ~= nil
end

--- Every id the executor can run, for the catalogue parity test's reverse
--- direction: a handler the catalogue does not list is a feature nobody can
--- bind. Daemon-injected handlers count only once init() has them.
--- @return table Sorted ids.
function M.runnable_action_ids()
	local seen, out = { none = true }, { "none" }
	for _, source in ipairs({ MODIFIER_ACTION_COMMANDS, _EMIT_ROWS, OPEN_WINDOW, OPEN_PATH,
		OPEN_LOG, WORKSPACE_ACTIONS, MEDIA_ACTIONS,
		_action_handlers, SCREENSHOT_COMMANDS, DIRECT_COMMANDS, BUILTIN_HANDLERS,
		SystemActions.COMMANDS, SystemActions.HANDLERS }) do
		for action_name in pairs(source) do
			if not seen[action_name] then
				seen[action_name] = true
				out[#out + 1] = action_name
			end
		end
	end
	table.sort(out)
	return out
end

--- Returns declared action ids for the daemon's configurable keyboard bindings.
--- Tap-holds load before daemon handlers are registered, so this admission list
--- follows the catalogue rather than the executor's current registrations.
--- @return table Sorted action ids, excluding the no-op binding.
function M.get_executable_action_names()
	local names = {}
	for _, id in ipairs(M.get_action_names()) do
		if id ~= "none" then names[#names + 1] = id end
	end
	table.sort(names)
	return names
end

--- Whether one requirement token from the catalogue holds on this machine.
--- @param token string "tool:<binary>", "session:x11" or "session:workspaces".
--- @return boolean|nil True/false when proven, nil when it cannot be told —
---   a probe that could not read the machine must never take a binding away.
--- @return string|nil hint Localized reason when the requirement is absent.
local function requirement_holds(token)
	local tool = token:match("^tool:(.+)$")
	if tool then
		local ok, Shell = pcall(require, "adapters.shell_runner")
		if not ok or type(Shell.has_command) ~= "function" then return nil, nil end
		if Shell.has_command(tool) then return true, nil end
		local hint = i18n.get("dialog.action_picker.requires_tool"):gsub("{1}", function() return tool end)
		return false, hint
	end
	if token == "session:x11" then
		local ok, Display = pcall(require, "infra.display_server")
		if not ok or type(Display.kind) ~= "function" then return nil, nil end
		local kind = Display.kind()
		if kind == Display.X11 then return true, nil end
		if kind == Display.WAYLAND then return false, i18n.get("dialog.action_picker.requires_x11") end
		return nil, nil
	end
	if token == "session:workspaces" then
		-- A session that lets another process read and pick its workspaces:
		-- X11 (wmctrl), KDE Plasma (KWin over D-Bus), sway or Hyprland.
		local backend, reason = require("modules.gestures.workspace_switcher").detect()
		if backend then return true, nil end
		local missing = reason:match("^tool:(.+)$")
		if missing then
			local hint = i18n.get("dialog.action_picker.requires_tool"):gsub("{1}", function() return missing end)
			return false, hint
		end
		if reason == "unsupported" then return false, i18n.get("dialog.action_picker.requires_workspaces") end
		return nil, nil
	end
	error("unknown action requirement token '" .. tostring(token) .. "'")
end

--- Ordered picker items for the active language: headings with their level
--- and translated text, actions with their label, and — when a requirement the
--- catalogue declares is proven absent — `disabled` plus the reason as `hint`.
--- Greyed rather than hidden: a row that vanishes reads as a bug, and the user
--- cannot tell "this session cannot" from "this driver forgot". "none" is left
--- out because the page adds its own translated row for it.
--- @return table
function M.get_picker_items()
	local items, probed = {}, {}
	--- Resolves one action's availability, probing each token once per build.
	local function availability(action_name)
		local meta = Catalogue.actions[action_name]
		for _, token in ipairs(meta and meta.requires or {}) do
			if probed[token] == nil then
				local holds, hint = requirement_holds(token)
				probed[token] = { holds = holds, hint = hint }
			end
			if probed[token].holds == false then return false, probed[token].hint end
		end
		return true, nil
	end
	local function push_action(action_name)
		local available, hint = availability(action_name)
		items[#items + 1] = {
			type = "action",
			id = action_name,
			label = M.get_action_label(action_name),
			disabled = not available or nil,
			hint = hint,
		}
	end
	for _, item in ipairs(Catalogue.sg_items) do
		if item.kind == "heading" then
			items[#items + 1] = {
				type = "heading", level = item.level, text = (i18n.get(item.key):gsub("^#+", "")),
			}
		elseif item.kind == "action" then
			if item.id ~= "none" then push_action(item.id) end
		elseif item.kind == "modifier_chords" then
			local template = i18n.get(item.group_key)
			for _, group in ipairs(MODIFIER_ACTION_GROUPS) do
				items[#items + 1] = {
					type = "heading", level = item.level,
					text = (template:gsub("{1}", function() return group.label end)),
				}
				for _, action_name in ipairs(group.actions) do push_action(action_name) end
			end
		else
			error("unknown action catalogue item kind '" .. tostring(item.kind) .. "'")
		end
	end
	return items
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
local _reader_stop_error = nil -- an unacknowledged close must fence reacquisition
local _decoder       = nil   -- the multitouch frame decoder for that device
local _touchpad      = nil   -- what touchpad_finder chose, and what it can express
local _parameter_configuration_owner = nil
local _scope_owner   = nil   -- retains refused runtime compensation
local _scope_native = false -- admits only the scope's synchronous native inverse
local _scope_sequence = 0

--- Keeps captured preferences exclusively owned until compensation completes.
--- @return boolean admitted
local function admit_mutation()
	if _parameter_configuration_owner ~= nil then return false end
	if _scope_owner and _scope_owner.pending() then
		Logger.error(LOG, "Gesture configuration remains owned by a pending scope transaction.")
		return false
	end
	return true
end

--- Copies one flat state map for a persistence-before-publication transaction.
--- @param source table
--- @return table
local function copy_state(source)
	local staged = {}
	for key, value in pairs(source) do staged[key] = value end
	return staged
end

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
	if not admit_mutation() then return false end
	local reading, unavailable = M.start_reading()
	if not reading then
		_enabled = false
		-- A machine without a touchpad is not a failure (start_reading said so at
		-- INFO): an ERROR here opened the error window at every start of a
		-- desktop whose config.toml enables gestures (hardening-a-startup-zero-error).
		if unavailable ~= "no_touchpad" then
			Logger.error(LOG, "Gestures remain disabled because the touchpad reader could not start.")
		end
		return false
	end
	_enabled = true
	Logger.info(LOG, "Gestures enabled.")
	return true
end

--- Disables gesture processing.
function M.disable()
	if not admit_mutation() then return false end
	if M.stop_reading() ~= true then return false end
	_enabled = false
	Logger.info(LOG, "Gestures disabled.")
	return true
end

--- Persists and applies the master gesture state as one transaction.
--- @param enabled boolean
--- @return boolean True when the requested state was committed.
function M.set_enabled(enabled)
	if not admit_mutation() then return false end
	if type(enabled) ~= "boolean" then
		Logger.error(LOG, "Gesture state must be a boolean — nothing changed.")
		return false
	end

	local snapshot = M.capture_scope_state()
	if not snapshot then return false end
	local candidate = M.capture_scope_state()
	candidate.enabled, candidate.reading = enabled, enabled
	local applied = M.apply_scope_state(candidate)
	if applied == true and M._persist_updates({ { section = CONFIG_SECTION, key = "enabled", value = enabled } }) then
		return true
	end
	-- The native boundary can fail after releasing ownership. Keep the exact
	-- inverse admitted until it succeeds; a later setter must not supersede it.
	local debt = snapshot
	local owner = {}
	function owner.pending() return debt ~= nil end
	function owner.retry_restore()
		if debt == nil then return true end
		if M.apply_scope_state(debt) ~= true then return false end
		debt = nil
		return true
	end
	-- A refused switch commits nothing, so a composed scope has nothing to undo.
	function owner.revert() return false, "no committed gesture scope to revert" end
	function owner.release() end
	_scope_owner = owner
	if owner.retry_restore() then
		Logger.error(LOG, "Gesture state was refused — the previous runtime was restored.")
	else
		Logger.error(LOG, "Gesture state was refused — runtime rollback remains pending.")
	end
	return false
end

--- Toggles gestures on/off.
function M.toggle()
	M.set_enabled(not _enabled)
	return _enabled
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
--- @return boolean True only after the assignment is durable when persistence is enabled.
function M.set_action(slot, action_name)
	if not admit_mutation() then return false end
	if type(slot) ~= "string" or type(action_name) ~= "string" then
		Logger.error(LOG, "Gesture slot and action must be strings — nothing changed.")
		return false
	end
	if not M.DEFAULT_GESTURES[slot] and not _actions[slot] then
		Logger.warn(LOG, "Unknown gesture slot: %s", tostring(slot))
		return false
	end
	-- Refused like Windows refuses it. This used to warn and commit anyway, so an
	-- id the catalogue does not offer here was stored and then dispatched as a
	-- no-op on every gesture — no error at bind time and none at fire time.
	if not M.is_assignable(action_name) then
		Logger.warn(LOG, "Refusing unknown action '%s' for slot '%s'.",
			tostring(action_name), tostring(slot))
		return false
	end
	local staged = copy_state(_actions)
	staged[slot] = action_name
	if not M._persist_updates({ { section = CONFIG_SECTION, key = slot, value = action_name } }) then
		Logger.error(LOG, "Gesture assignment was not persisted — nothing changed.")
		return false
	end
	_actions = staged
	Logger.info(LOG, "Gesture '%s' → '%s'.", slot, tostring(action_name))
	return true
end

function M.get_action_parameter_spec(action_name)
	return M.ACTION_PARAMETER_SPECS[action_name]
end

-- The parameter kinds the shortcuts manager parses (_shared/lua/send_input).
local SEND_INPUT_KINDS = { text = true, key = true, shortcut = true }

--- Replaces the {1} of a localized template on plain indices: the detail may
--- hold a % that gsub would read as a capture reference.
--- @param template string
--- @param detail string
--- @return string
local function fill_placeholder(template, detail)
	local at = template:find("{1}", 1, true)
	if not at then return template end
	return template:sub(1, at - 1) .. detail .. template:sub(at + 3)
end

--- The shortcuts manager, which owns the wrap-pair catalogue. Required lazily:
--- the daemon loads it after this module.
--- @return table|nil
local function shortcuts_manager()
	local ok, Shortcuts = pcall(require, "modules.shortcuts.manager")
	if not ok or type(Shortcuts) ~= "table" or type(Shortcuts.resolve_wrap_pair) ~= "function" then
		Logger.error(LOG, "The wrap-pair catalogue is unavailable: %s.", tostring(Shortcuts))
		return nil
	end
	return Shortcuts
end

--- The send-input vocabulary the shortcuts manager reads. Raises when that
--- manager is unavailable: a prompt or refusal without it would name no key.
--- @return table
local function send_vocabulary()
	local Shortcuts = shortcuts_manager()
	if not Shortcuts then error("the send-input vocabulary is unavailable: no shortcuts manager") end
	return Shortcuts.send_vocabulary()
end

function M.validate_action_parameter(action_name, value)
	local spec = M.get_action_parameter_spec(action_name)
	if not spec then return true end
	if spec == "wrap_pair" then
		local Shortcuts = shortcuts_manager()
		return Shortcuts ~= nil and (Shortcuts.resolve_wrap_pair(value)) ~= nil
	end
	if SEND_INPUT_KINDS[spec] then
		local Shortcuts = shortcuts_manager()
		return Shortcuts ~= nil and Shortcuts.parse_send_input(spec, value) ~= nil
	end
	-- Syntax only: whether the named prompt still exists is checked when the
	-- action runs, so deleting a custom prompt does not drop its bindings.
	if spec == "llm_prompt" then return PromptAction.is_valid(value) end
	-- Syntax only as well: whether the provider exists, has a key and a
	-- default model is checked when the action runs.
	if spec == "llm_vision" then return Vision.is_valid(value) end
	-- A closed list: "ui" or a shipped locale code (translate.lua).
	if spec == "llm_language" then return require("modules.llm.translation").is_valid(value) end
	-- Syntax only: whether the desktop entry exists is gtk-launch's to say.
	if spec == "app" then return AppParameter.is_valid(value) end
	if type(value) ~= "string" or not value:match("^https?://%S+$") then return false end
	if spec == "search_url" then
		local _, placeholders = value:gsub("%%s", "")
		return placeholders == 1
	end
	if spec == "url" then return true end
	error("no validator for parameter kind '" .. tostring(spec) .. "'")
end

--- The text a binding editor shows to ask for an action's parameter. The
--- search-URL prompt holds a LITERAL %s the user types, and a wrap-pair sample
--- may hold a %, so {1} is replaced by plain indices, never gsub.
--- @param action_name string Action id with a parameter.
--- @return string
function M.get_action_parameter_prompt(action_name)
	local spec = M.get_action_parameter_spec(action_name)
	if spec == "search_url" then return i18n.get("dialog.gestures.param_search_url") end
	if spec == "url" then return i18n.get("dialog.gestures.param_link") end
	if spec == "app" then return i18n.get("dialog.gestures.param_app") end
	if spec == "wrap_pair" then
		local Shortcuts = shortcuts_manager()
		local WrapPair = require("wrap_pair")
		local samples = WrapPair.describe(Shortcuts and Shortcuts.get_wrap_pair_list() or {})
		local template = i18n.get("dialog.gestures.param_wrap_pair")
		local at = template:find("{1}", 1, true)
		if not at then return template .. "\n" .. samples end
		return template:sub(1, at - 1) .. samples .. template:sub(at + 3)
	end
	if SEND_INPUT_KINDS[spec] then
		local vocabulary = send_vocabulary()
		local detail = spec == "text" and tostring(vocabulary.text_max_code_points)
			or require("send_input").describe_keys(vocabulary)
		return fill_placeholder(i18n.get("dialog.gestures.param_" .. spec), detail)
	end
	if spec == "llm_prompt" then
		local lines = {}
		for _, choice in ipairs(require("modules.llm.profile_settings").choices()) do
			lines[#lines + 1] = choice.value .. " — " .. choice.label
		end
		return fill_placeholder(i18n.get("dialog.gestures.param_llm_prompt"), table.concat(lines, "\n"))
	end
	if spec == "llm_vision" then
		local lines = {}
		for _, choice in ipairs(require("modules.llm.vision_request").backend_choices()) do
			lines[#lines + 1] = choice.value .. " — " .. choice.label
		end
		return fill_placeholder(i18n.get("dialog.gestures.param_llm_vision"), table.concat(lines, "\n"))
	end
	if spec == "llm_language" then
		local lines = {}
		for _, choice in ipairs(require("modules.llm.translation").choices()) do
			lines[#lines + 1] = choice.value .. " — " .. choice.label
		end
		return fill_placeholder(i18n.get("dialog.gestures.param_llm_language"), table.concat(lines, "\n"))
	end
	error("no prompt for parameter kind '" .. tostring(spec) .. "'")
end

--- The text shown when a typed parameter is refused.
--- @param action_name string Action id with a parameter.
--- @return string
function M.get_action_parameter_error(action_name)
	local spec = M.get_action_parameter_spec(action_name)
	if spec == "wrap_pair" then return i18n.get("dialog.gestures.param_err_wrap_pair") end
	if spec == "llm_prompt" then return i18n.get("dialog.gestures.param_err_llm_prompt") end
	if spec == "llm_vision" then return i18n.get("dialog.gestures.param_err_llm_vision") end
	if spec == "llm_language" then return i18n.get("dialog.gestures.param_err_llm_language") end
	if spec == "app" then return i18n.get("dialog.gestures.param_err_app") end
	if SEND_INPUT_KINDS[spec] then
		return fill_placeholder(i18n.get("dialog.gestures.param_err_" .. spec),
			tostring(send_vocabulary().text_max_code_points))
	end
	if spec == "search_url" then
		return i18n.get("dialog.gestures.param_err_url") .. " "
			.. i18n.get("dialog.gestures.param_err_many_placeholders")
	end
	return i18n.get("dialog.gestures.param_err_url")
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

--- Readies picker items for the picker's own parameter editor: each action that
--- takes a parameter is marked with its kind and the value `binding` holds for
--- it, so the page's "edit the current action" button can reopen any of them.
--- The page edits a text, a key, a shortcut, a prompt, a vision backend or a
--- target language itself, with the prompts, refusals, vocabulary and choices
--- returned here; any other kind is confirmed without a value and prompted for
--- natively.
--- @param items table get_picker_items() output, marked in place.
--- @param binding string|nil The binding the pick is for; nil marks no value.
--- @return table { send_vocabulary, parameter_strings, prompt_choices,
---   vision_choices, language_choices, default_count, edit_current_label },
---   the options the picker bridge's open() reads.
function M.get_picker_parameter_fields(items, binding)
	local prompts, errors = {}, {}
	for _, item in ipairs(items) do
		local kind = item.type == "action" and M.get_action_parameter_spec(item.id) or nil
		if kind then
			item.parameter = kind
			item.parameterValue = binding and M.get_action_parameter(binding, item.id) or ""
			if SEND_INPUT_KINDS[kind] or kind == "llm_prompt" or kind == "llm_vision" or kind == "llm_language" then
				prompts[kind] = M.get_action_parameter_prompt(item.id)
				errors[kind] = M.get_action_parameter_error(item.id)
			end
		end
	end
	local ProfileSettings = require("modules.llm.profile_settings")
	return {
		send_vocabulary = send_vocabulary(),
		prompt_choices = ProfileSettings.choices(),
		vision_choices = require("modules.llm.vision_request").backend_choices(),
		language_choices = require("modules.llm.translation").choices(),
		default_count = ProfileSettings.get("num_predictions"),
		edit_current_label = i18n.get("dialog.action_picker.edit_current"),
		parameter_strings = {
			save = i18n.get("button.save"),
			back = i18n.get("dialog.action_picker.back"),
			captureKey = i18n.get("dialog.action_picker.capture_key"),
			captureShortcut = i18n.get("dialog.action_picker.capture_shortcut"),
			promptLabel = i18n.get("dialog.action_picker.prompt_label"),
			countLabel = i18n.get("dialog.action_picker.count_label"),
			countDefault = i18n.get("dialog.action_picker.count_default"),
			visionProviderLabel = i18n.get("dialog.action_picker.vision_provider_label"),
			visionModelLabel = i18n.get("dialog.action_picker.vision_model_label"),
			-- Raw: the page fills {1} with the chosen backend's default model.
			visionModelDefault = i18n.get("dialog.action_picker.vision_model_default"),
			visionModelRequired = i18n.get("dialog.action_picker.vision_model_required"),
			languageLabel = i18n.get("dialog.action_picker.language_label"),
			prompts = prompts,
			errors = errors,
		},
	}
end

--- Judges only already-published native parameter domains; no catalogue IO occurs here.
--- @param binding any Native binding identity.
--- @return boolean|nil fits
--- @return string detail
function M.action_parameter_binding_fits(binding)
	if type(binding) == "string" and binding:sub(1, 8) == "script__" then
		local chords = package.loaded["modules.shortcuts.script_chords"]
		local catalogue
		if type(chords) == "table" and type(chords.published_binding_catalogue) == "function" then
			catalogue = chords.published_binding_catalogue()
		end
		return BindingIdentity.script_binding_fits(binding, catalogue), BindingIdentity.RETIRED_SCRIPT
	end
	return BindingIdentity.gesture_binding_fits(binding, parameter_binding_catalogue), BindingIdentity.RETIRED_GESTURE
end

function M.set_action_parameter(binding, action_name, value)
	if not admit_mutation() then return false end
	if M.action_parameter_binding_fits(binding) == false then return false end
	if not M.validate_action_parameter(action_name, value) then return false end
	local key = parameter_key(binding, action_name)
	local staged = copy_state(_action_params)
	staged[key] = value
	if not M._persist_updates({ { section = CONFIG_SECTION_PARAMS, key = key, value = value } }) then
		Logger.error(LOG, "Gesture action parameter was not persisted — nothing changed.")
		return false
	end
	_action_params = staged
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
	return ParameterLabel.format(label, value)
end

--- Returns all gesture actions.
--- @return table slot → action_name
function M.get_all_actions()
	local t = {}
	for k, v in pairs(_actions) do t[k] = v end
	return t
end

--- Captures detached preferences and the acknowledged touchpad reader state.
--- @return table|nil snapshot Nil when the current master has no live reader.
function M.capture_scope_state()
	if _reader_stop_error or (_enabled and not _reading) then return nil end
	return {
		enabled = _enabled, reading = _reading,
		actions = copy_state(_actions), parameters = copy_state(_action_params),
	}
end

--- Applies a complete validated runtime snapshot without writing preferences.
--- A failed native transition belongs to the caller's retained compensation.
--- @param candidate table Detached scope runtime snapshot.
--- @return boolean acknowledged
function M.apply_scope_state(candidate)
	if _parameter_configuration_owner ~= nil then return false end
	if type(candidate) ~= "table" or type(candidate.enabled) ~= "boolean"
		or type(candidate.reading) ~= "boolean" or (candidate.enabled and not candidate.reading)
		or type(candidate.actions) ~= "table" or type(candidate.parameters) ~= "table" then return false end
	local actions, parameters = {}, {}
	for slot in pairs(M.DEFAULT_GESTURES) do
		local action = candidate.actions[slot]
		if type(action) ~= "string" or not M.is_assignable(action) then return false end
		actions[slot] = action
	end
	for slot in pairs(candidate.actions) do
		if M.DEFAULT_GESTURES[slot] == nil then return false end
	end
	for key, value in pairs(candidate.parameters) do
		local binding, action = M.split_action_parameter_key(key)
		if not binding or not action or not M.validate_action_parameter(action, value) then return false end
		parameters[key] = value
	end
	_scope_native = true
	local called, acknowledged = pcall(function()
		if candidate.reading then return M.start_reading() == true and M.is_reading() end
		return M.stop_reading() == true and not M.is_reading()
	end)
	_scope_native = false
	if not called or acknowledged ~= true then return false end
	_enabled = candidate.enabled
	_actions, _action_params = actions, parameters
	return true
end

--- Restores or clears all gesture-owned preferences and native reader state.
--- @param mode string `recommended` or `clear`.
--- @return boolean committed
--- @return string|nil detail
function M.apply_scope(mode)
	if _parameter_configuration_owner ~= nil then return false end
	if mode ~= "recommended" and mode ~= "clear" then return false, "invalid gesture scope mode" end
	if _is_paused() then return false, "gesture configuration is paused" end
	if not _persist or type(_config_path) ~= "string" then return false, "gesture persistence is not initialized" end
	if _scope_owner and _scope_owner.pending() then
		if not _scope_owner.retry_restore() then return false, "gesture runtime rollback remains pending" end
	end
	_scope_sequence = _scope_sequence + 1
	local backup = _config_path .. ".gestures-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. _scope_sequence .. ".bak"
	_scope_owner = require("infra.gesture_scope").new({
		path = _config_path,
		backup_path = backup,
		gestures = M,
	})
	local committed, detail = _scope_owner.apply(mode)
	if not committed then Logger.error(LOG, "Gesture scope '%s' was refused: %s.", mode, tostring(detail)) end
	return committed, detail, backup
end

--- Whether a gesture scope can be acknowledged on this machine: the reader is
--- already running, or the finder selects a touchpad to start it on. Without
--- one, « recommended » can never start the reader it requires.
--- @return boolean available
function M.scope_available()
	if _reading then return true end
	return require("modules.gestures.touchpad_finder").find() ~= nil
end

--- The gesture participant of a composed scope, bound to the retained owner.
--- @return table participant See config_scope_composition.
function M.scope_participant()
	return require("config_scope_participant").synchronous({
		apply = function(mode) return M.apply_scope(mode) end,
		owner = function() return _scope_owner end,
	})
end

--- Resets all gesture actions to defaults.
--- @return boolean True only after every default is durable when persistence is enabled.
function M.reset_defaults()
	local staged = copy_state(_actions)
	local updates = {}
	for k, v in pairs(M.RECOMMENDED_GESTURES) do
		staged[k] = v
		updates[#updates + 1] = { section = CONFIG_SECTION, key = k, value = v }
	end
	if not M._persist_updates(updates) then
		Logger.error(LOG, "Gesture defaults were not persisted — nothing changed.")
		return false
	end
	_actions = staged
	Logger.info(LOG, "Gestures reset to defaults.")
	return true
end

--- Replaces every gesture action by the empty no-op without changing the
--- master enable flag.
--- @return boolean True only after every empty binding is durable when persistence is enabled.
function M.disable_all_actions()
	local staged = copy_state(_actions)
	local updates = {}
	for slot in pairs(M.DEFAULT_GESTURES) do
		staged[slot] = "none"
		updates[#updates + 1] = { section = CONFIG_SECTION, key = slot, value = "none" }
	end
	if not M._persist_updates(updates) then
		Logger.error(LOG, "Gesture bindings were not disabled because persistence failed — nothing changed.")
		return false
	end
	_actions = staged
	Logger.info(LOG, "Every gesture binding was set to none.")
	return true
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

	-- A pause stops every gesture but the script-control ones, which are how the
	-- user resumes; the reader keeps running so those still arrive.
	if _is_paused() and not ScriptActions.is_script_action(action) then
		Logger.debug(LOG, "Gesture %s → %s held back: the script is paused.", slot, action)
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
--- @return string|nil "no_touchpad" when the machine has none, which is not a failure.
function M.start_reading()
	if not _scope_native and not admit_mutation() then return false end
	if _reader_stop_error then return false end
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
		return false, "no_touchpad"
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
	if not _reading or not _decoder or _reader_stop_error then return 0 end

	local ok_reader, Reader = pcall(require, "adapters.evdev_reader")
	if not ok_reader then return 0 end

	local drained, status = Reader.drain(function(event)
		local gesture = _decoder:feed(event)
		if gesture then M.dispatch_gesture(gesture) end
	end, Reader.TOUCHPAD)
	if status == "fatal" or status == "closed" then
		Logger.error(LOG, "Touchpad drain %s — stopping gesture reading; re-enable gestures to retry.",
			tostring(status))
		M.stop_reading()
	end
	return drained or 0
end

--- Stops reading the touchpad.
--- @return boolean True only when the reader acknowledges closure.
function M.stop_reading()
	if not _scope_native and not admit_mutation() then return false end
	if _reading then
		local ok_reader, Reader = pcall(require, "adapters.evdev_reader")
		local called, acknowledged, detail = false, nil, "reader close is unavailable"
		if ok_reader and type(Reader) == "table" and type(Reader.close) == "function" then
			called, acknowledged, detail = pcall(Reader.close, Reader.TOUCHPAD)
		end
		if not called or acknowledged ~= true then
			_reader_stop_error = tostring(not called and acknowledged or detail or "reader did not acknowledge close")
			Logger.error(LOG, "Touchpad stop is not acknowledged: %s.", _reader_stop_error)
			return false
		end
	end
	-- Dropping the decoder IS the reset: it holds the slot state and the latched
	-- finger count, so a half-finished gesture cannot survive into the next
	-- reader. There is no separate tracking state left to clear.
	_reading = false
	_reader_stop_error = nil
	_decoder = nil
	_touchpad = nil
	Logger.info(LOG, "Touchpad reader stopped.")
	return true
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
	if not admit_mutation() then return false end
	if not _persist then return true end
	if type(updates) ~= "table" or #updates == 0 then
		Logger.error(LOG, "Could not persist gesture configuration: update batch is empty or invalid.")
		return false
	end
	if type(TomlWriter) ~= "table" or type(TomlWriter.batch_write) ~= "function" then
		Logger.error(LOG, "Could not persist gesture configuration: TOML writer is unavailable.")
		return false
	end
	if type(_config_path) ~= "string" or _config_path == "" then
		Logger.error(LOG, "Could not persist gesture configuration: config path is unavailable.")
		return false
	end

	local call_ok, committed, err = pcall(TomlWriter.batch_write, _config_path, updates)
	if not call_ok or committed ~= true then
		Logger.error(LOG, "Could not persist gesture configuration: %s",
			tostring(call_ok and err or committed))
		return false
	end
	return true
end

--- Walks a decoded config.toml exactly as the loader applies it: the legacy
--- `[linux.gestures]` section FIRST, then the canonical one over it, each slot
--- and parameter through the same acceptance test. The loader and the
--- unused-key cleanup both walk through here, so a key the cleanup offers to
--- remove is exactly one the loader never takes.
--- @param config table Decoded config.toml.
--- @param visit table `{ action(section, slot, action), param(section, key, value),
---   enabled(value) }`; every field is optional.
local function walk_user_config(config, visit)
	--- Path segments of one entry of a (possibly dotted) section.
	--- @param section_name string
	--- @param key any
	--- @return table segments
	local function entry_path(section_name, key)
		local segments = {}
		for part in section_name:gmatch("[^.]+") do segments[#segments + 1] = part end
		segments[#segments + 1] = key
		return segments
	end

	--- Visits one section's slot→action pairs the loader binds.
	--- @param section_name string
	--- @param section table|nil
	local function walk_actions(section_name, section)
		if type(section) ~= "table" or not visit.action then return end
		for slot, action in pairs(section) do
			-- An unknown slot, a non-text action or a retired one is outdated
			-- configuration: neither the loader nor the cleanup marker takes it,
			-- so it is warned about once and offered for removal instead of
			-- being skipped in silence. `enabled` is the master switch.
			if slot == "enabled" and section_name == CONFIG_SECTION then
				-- Read by the enabled visitor below.
			elseif not M.DEFAULT_GESTURES[slot] then
				ConfigOutdated.report(entry_path(section_name, slot), "no gesture slot of this build has this name", Logger)
			elseif type(action) ~= "string" then
				ConfigOutdated.report(entry_path(section_name, slot), "the value is not an action id", Logger)
			elseif M.is_assignable(action) then
				visit.action(section_name, slot, action)
			else
				ConfigOutdated.report(entry_path(section_name, slot), "action '" .. action .. "' no longer exists", Logger)
			end
		end
	end

	--- Visits one section's parameter overrides the loader keeps.
	--- @param section_name string
	--- @param section table|nil
	local function walk_params(section_name, section)
		if type(section) ~= "table" or not visit.param then return end
		for key, value in pairs(section) do
			local binding, action = M.split_action_parameter_key(key)
			local fits, detail = M.action_parameter_binding_fits(binding)
			if binding and action and fits == false then
				ConfigOutdated.report(entry_path(section_name, key), detail, Logger)
			elseif binding and action and M.validate_action_parameter(action, value) then
				visit.param(section_name, key, value)
			else
				-- Outdated configuration, named once and offered by the cleanup.
				ConfigOutdated.report(entry_path(section_name, key), binding and action
					and "the value no longer fits its action's parameter"
					or "no action parameter of this build has this name", Logger)
			end
		end
	end

	-- Order matters: a user who has already written a binding under the new
	-- name after the migration must not have it overwritten by whatever the old
	-- section still says. A rename that silently drops a user's bindings is
	-- worse than the divergence it fixes.
	local legacy = type(config.linux) == "table" and config.linux or nil
	if legacy then
		walk_actions(LEGACY_SECTION, legacy.gestures)
		walk_params(LEGACY_SECTION_PARAMS, legacy.action_parameters)
	end
	walk_actions(CONFIG_SECTION, config[CONFIG_SECTION])
	walk_params(CONFIG_SECTION_PARAMS, config[CONFIG_SECTION_PARAMS])
	if visit.enabled and type(config[CONFIG_SECTION]) == "table"
		and type(config[CONFIG_SECTION].enabled) == "boolean" then
		visit.enabled(config[CONFIG_SECTION].enabled)
	end
end

--- Removes only legacy leaves consumed by the gesture scope's runtime reader.
--- @param config table Decoded configuration before a scoped transaction.
--- @return table operations Explicit deletions preserving other owners.
function M.scope_legacy_operations(config)
	local operations = {}
	walk_user_config(config, {
		action = function(section, slot)
			if section == LEGACY_SECTION then
				operations[#operations + 1] = { section = section, key = slot, delete = true }
			end
		end,
		param = function(section, key)
			local binding = M.split_action_parameter_key(key)
			if section == LEGACY_SECTION_PARAMS and M.DEFAULT_GESTURES[binding] ~= nil then
				operations[#operations + 1] = { section = section, key = key, delete = true }
			end
		end,
	})
	return operations
end

--- Marks every config.toml path the gesture loader takes.
--- @param config table Decoded config.toml.
--- @param mark function mark(...segments) from config_unused_keys.
function M.mark_config_reads(config, mark)
	local unpack_segments = table.unpack or unpack
	--- Marks `key` under a dotted section path such as "linux.gestures".
	--- @param section_name string
	--- @param key string
	local function mark_at(section_name, key)
		local segments = {}
		for segment in section_name:gmatch("[^%.]+") do segments[#segments + 1] = segment end
		segments[#segments + 1] = key
		mark(unpack_segments(segments))
	end
	walk_user_config(config, {
		action = function(section_name, slot) mark_at(section_name, slot) end,
		param = function(section_name, key) mark_at(section_name, key) end,
		enabled = function() mark(CONFIG_SECTION, "enabled") end,
	})
end

local function load_user_config(path)
	if type(path) ~= "string" or path == "" then return nil end
	local fh = io.open(path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	local ok, config = pcall(TomlCodec.decode, content)
	if not ok or type(config) ~= "table" then return nil end

	local configured = nil
	walk_user_config(config, {
		action = function(_section_name, slot, action)
			if not M.is_assignable(action) then
				-- set_action refuses such an id, so it can only come from a hand edit
				-- or a config written by another OS. Kept out, loudly: binding it
				-- would dispatch a no-op on every gesture.
				Logger.warn(LOG, "Unknown action '%s' for slot '%s' in config.toml — ignored.",
					tostring(action), tostring(slot))
				return
			end
			_actions[slot] = action
		end,
		param = function(_section_name, key, value)
			_action_params[key] = value
		end,
		enabled = function(value) configured = value end,
	})
	local legacy = type(config.linux) == "table" and config.linux or nil
	if legacy and type(legacy.gestures) == "table" and next(legacy.gestures) ~= nil then
		Logger.info(LOG,
			"Gestures read from the legacy [%s] section — they will be rewritten under [%s] on the next change.",
			LEGACY_SECTION, CONFIG_SECTION)
	end
	return configured
end

--- Initialises the gestures module.
--- @param opts table|nil { enabled?, now_sec?, action_handlers? } — now_sec
---   injects a wall-clock source (seconds) for tests; production uses the
---   monotonic clock. action_handlers owns daemon lifecycle operations.
function M.init(opts)
	if not admit_mutation() then return false end
	opts = type(opts) == "table" and opts or {}
	if opts.action_handlers ~= nil and type(opts.action_handlers) ~= "table" then
		error("gestures action_handlers must be a table")
	end
	if opts.is_paused ~= nil and type(opts.is_paused) ~= "function" then
		error("gestures is_paused must be a function")
	end
	_is_paused = opts.is_paused or NEVER_PAUSED
	_action_handlers = {}
	for action_name, handler in pairs(opts.action_handlers or {}) do
		if type(action_name) ~= "string" or type(handler) ~= "function" then
			error("every gestures action handler must map a string id to a function")
		end
		_action_handlers[action_name] = handler
	end

	if type(opts.now_sec) == "function" then
		_now_sec = opts.now_sec
	end
	_config_path = opts.config_path or require("infra.config_paths").config("config.toml")
	_persist = opts.persist == true
	local configured_enabled = nil
	if _persist then configured_enabled = load_user_config(_config_path) end

	local enabled = configured_enabled
	if type(opts.enabled) == "boolean" then enabled = opts.enabled end
	if enabled == nil then enabled = DEFAULT_ENABLED end
	if enabled then M.enable() end

	Logger.info(LOG, "Gestures manager initialised (enabled=%s).", tostring(_enabled))
	require("ui.gesture_conflicts").notify_boot(M)
end


--- Acquires only the shared parameter map, without touching the touchpad reader.
--- @param owner table Exact transaction token.
--- @return boolean acquired
function M.acquire_parameter_configuration(owner)
	if type(owner) ~= "table" or not admit_mutation() then return false end
	_parameter_configuration_owner = owner
	return true
end

--- Releases exact parameter ownership after acknowledged completion.
--- @param owner table Exact transaction token.
--- @return boolean released
function M.release_parameter_configuration(owner)
	if type(owner) ~= "table" or _parameter_configuration_owner ~= owner then return false end
	_parameter_configuration_owner = nil
	return true
end

--- Captures parameters independently from evdev acquisition and close state.
--- @param owner table Exact transaction token.
--- @return table|nil parameters
function M.parameter_configuration_snapshot(owner)
	if _parameter_configuration_owner ~= owner then return nil end
	return M.get_all_action_parameters()
end

--- Applies a detached parameter map without changing gesture actions or devices.
--- @param owner table Exact transaction token.
--- @param parameters table Validated candidate or exact prior state.
--- @return boolean acknowledged
function M.apply_parameter_configuration(owner, parameters)
	if _parameter_configuration_owner ~= owner or type(parameters) ~= "table" then return false end
	local copy = {}
	for key, value in pairs(parameters) do
		local binding, action = M.split_action_parameter_key(key)
		if not binding or not M.validate_action_parameter(action, value) then return false end
		copy[key] = value
	end
	_action_params = copy
	return true
end

--- Enumerates only recognized parameter bindings consumed by this loader.
--- @param document table Decoded configuration.
--- @param recognizes function Binding domain resolver supplied by the runtime owner.
--- @return table paths Canonical dynamic paths.
--- @return table legacy Explicit legacy deletions for the same bindings.
function M.parameter_configuration_inventory(document, recognizes)
	local paths, legacy = {}, {}
	walk_user_config(document, {
		param = function(section, key)
			local binding = M.split_action_parameter_key(key)
			if recognizes(binding) then
				if section == CONFIG_SECTION_PARAMS then paths[#paths + 1] = section .. "." .. key end
				if section == LEGACY_SECTION_PARAMS then legacy[#legacy + 1] = { section = section, key = key, delete = true } end
			end
		end,
	})
	for key in pairs(_action_params) do
		local binding = M.split_action_parameter_key(key)
		if recognizes(binding) then paths[#paths + 1] = CONFIG_SECTION_PARAMS .. "." .. key end
	end
	return paths, legacy
end

return M
