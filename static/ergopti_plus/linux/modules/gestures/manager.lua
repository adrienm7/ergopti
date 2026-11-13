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
---    generated from `_shared/shortcuts/data/actions/actions.toml` into
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

local Logger = require("core.logger.engine.shim")
local ConfigOutdated = require("settings.engine.migration.outdated")
local BindingIdentity = require("settings.engine.publication.binding_identity")
local KeyboardPublication = require("settings.engine.publication.keyboard_publication")
local BindingPublication = require("settings.engine.publication.binding_publication")
local Paths = require("core.fs.engine.paths")
local Timings = require("core.timing.engine.timings")
local Monotonic = require("core.logger.engine.monotonic")
local Manifest = require("menu.engine.manifest_reader")
local ParameterLabel = require("shortcuts.engine.action_parameter_label")
local ProgramParameter = require("settings.engine.program_parameter")
local ProgramOwner = require("modules.gestures.program_owner")
local UserActions = require("modules.gestures.user_actions")
local UserActionParameter = require("shortcuts.engine.user_action_parameter")
local WindowSwitch = require("adapters.window_switch")
local PromptAction = require("ai.engine.prediction.prompt_action")
local Vision = require("ai.engine.prediction.vision")
local AppParameter = require("apps.engine.parameter")
local TomlCodec = require("core.text.engine.toml_codec")
local i18n = require("core.i18n.engine.i18n")
local KeyNames = require("platform.input.keycodes.key_names")
local ScriptActions = require("modules.shortcuts.script_actions")
local AiActions = require("modules.shortcuts.ai_actions")
local ShellRunner = require("core.process.adapters.shell_runner")
local DesktopNavigation = require("keyboard.engine.desktop_navigation")
local SystemActions = require("modules.gestures.system_actions")
local BackgroundCommands = require("modules.gestures.background_commands")
local TableUtil = require("core.text.engine.table_util")
local TextUtils = require("core.text.engine.utils_core")
local ConfigKeys = require("settings.engine.keys")

-- Retain the admitted issuer at owner construction. Later module/export swaps
-- cannot appoint another producer or certify unavailable custody.
local _emitter_ok, _emitter_owner = pcall(require, "modules.gestures.combo_emitter")
local _emitter_press, _emitter_certify
if _emitter_ok and type(_emitter_owner) == "table" and getmetatable(_emitter_owner) == nil then
	_emitter_press = rawget(_emitter_owner, "press")
	_emitter_certify = rawget(_emitter_owner, "can_fallback")
end
local function emitter_authority_current()
	return _emitter_ok and type(_emitter_owner) == "table"
		and getmetatable(_emitter_owner) == nil and type(_emitter_press) == "function"
		and rawequal(package.loaded["modules.gestures.combo_emitter"], _emitter_owner)
		and rawequal(rawget(_emitter_owner, "press"), _emitter_press)
		and rawequal(rawget(_emitter_owner, "can_fallback"), _emitter_certify)
end
local LOG = "modules.gestures.manager"
local ENABLED_PATH = ConfigKeys.KEY.GESTURES_ENABLED
local DEFAULT_ENABLED = Manifest.default_for(ENABLED_PATH)

if type(DEFAULT_ENABLED) ~= "boolean" then
	error("The manifest default for " .. ENABLED_PATH .. " must be a boolean.")
end

-- Actions the shared catalogue describes as a single xdotool combo, generated
-- from _shared/shortcuts/data/actions/actions.toml. Loaded once at require time.
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
local _writer_ok, TomlWriter = pcall(require, "core.text.engine.toml_codec.writer")
if not _writer_ok then TomlWriter = nil end

-- The Linux action catalogue, generated from _shared/shortcuts/data/actions/actions.toml
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
local parameter_source_slots = Catalogue.slots
local parameter_source_arrays, parameter_source_values, parameter_source_counts = {}, {}, {}
for _, family in ipairs({ "single", "axis" }) do
	local slots = Catalogue.slots[family]
	parameter_source_arrays[family], parameter_source_values[family] = slots, {}
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
		parameter_source_values[family][index] = slot
		count = count + 1
	end
	for index = 1, count do
		assert(slots[index] ~= nil, "generated gesture " .. family .. " slots must be dense")
	end
	parameter_source_counts[family] = count
end

--- Returns only the constructor's complete genuine generated binding image.
--- Public runtime copies do not certify identities. A replaced package owner,
--- accessor or private generated source withdraws judgment without IO.
--- @return table|nil catalogue Detached native gesture identities.
function M.published_binding_catalogue()
	if not BindingPublication.owner_is_current("gesture", "modules.gestures.manager", M)
		or not rawequal(rawget(package.loaded, "_generated.action_catalogue"), Catalogue)
		or getmetatable(Catalogue) ~= nil
		or not rawequal(rawget(Catalogue, "slots"), parameter_source_slots)
		or type(parameter_source_slots) ~= "table" or getmetatable(parameter_source_slots) ~= nil then return nil end
	for _, family in ipairs({ "single", "axis" }) do
		local slots = rawget(parameter_source_slots, family)
		if not rawequal(slots, parameter_source_arrays[family])
			or type(slots) ~= "table" or getmetatable(slots) ~= nil then return nil end
		local count, expected = 0, parameter_source_counts[family]
		for index in next, slots do
			if type(index) ~= "number" or index < 1 or index % 1 ~= 0 or index > expected
				or not rawequal(rawget(slots, index), parameter_source_values[family][index]) then return nil end
			count = count + 1
		end
		if count ~= expected then return nil end
	end
	local publication = { prefix = parameter_binding_catalogue.prefix, slots = {} }
	for slot, present in next, parameter_binding_catalogue.slots do publication.slots[slot] = present end
	return publication
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

-- Click holds are independent from the touchpad reader: keyboard shortcuts
-- may acquire them on a desktop without a touchpad too.
local function NEVER_PAUSED() return false end
local _is_paused = NEVER_PAUSED
local _parameter_configuration_owner = nil
local _gesture_click_fence = nil
local _click_holds = require("modules.gestures.click_hold").new(function() return not _is_paused() end)

-- =========================================
-- =========================================
-- ======= 1/ Gesture Slot Registry ========
-- =========================================
-- =========================================

-- The gesture slot key-space (tap/swipe slot names) is the SINGLE SOURCE shared
-- with the macOS driver, declared once in _shared/shortcuts/data/actions/actions.toml
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

-- The horizontal axis slot each finger count falls back to. An axis slot is
-- the binding of BOTH horizontal directions of one count: a straight left or
-- right swipe whose own direction slot is unbound runs it (decided 2026-11-06,
-- docs/memory/maintainer-decisions.md). Derived from the shared slot list so a
-- renamed or added axis slot cannot leave a stale literal here; a name this
-- rule does not understand is refused at load rather than never firing.
local AXIS_SLOT_FOR_FINGERS = {}
for _, slot in ipairs(M.AXIS_SLOTS) do
	local fingers = slot:match("^swipe_(%d)_horiz$")
	assert(fingers, "unsupported axis gesture slot in the shared catalogue: " .. tostring(slot))
	AXIS_SLOT_FOR_FINGERS[tonumber(fingers)] = slot
end

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

--- Incremental mode per swipe slot and its step in millimetres, from the
--- shared manifest, as on macOS; config.toml `[gestures.modes]` and
--- `[gestures.sensitivities]` override them. An incremental slot acts while
--- the fingers move (modules/gestures/incremental_tracker.lua).
M.MODE_SINGLE, M.MODE_INCREMENTAL = "x1", "incremental"
local MODES_SECTION = ConfigKeys.KEY.GESTURES_MODES
local SENSITIVITIES_SECTION = ConfigKeys.KEY.GESTURES_SENSITIVITIES
M.DEFAULT_MODES, M.DEFAULT_SENSITIVITIES = {}, {}
-- The manifest declares a mode and a step for every swipe direction; taps and
-- the axis slots have none.
for _, slot in ipairs(M.SINGLE_SLOTS) do
	if not slot:match("^swipe_") then goto continue end
	M.DEFAULT_MODES[slot] = Manifest.default_for(MODES_SECTION .. "." .. slot)
	M.DEFAULT_SENSITIVITIES[slot] = Manifest.default_for(SENSITIVITIES_SECTION .. "." .. slot)
	::continue::
end
local _modes, _sensitivities = {}, {}
-- The live tracker of the touch in progress; nil while the pad has no scale.
local _incremental = nil

-- =========================================
-- =========================================
-- ======= 2/ Action Registry ==============
-- =========================================
-- =========================================

--- The parts each modifier-chord action is named from at every read: its
--- modifier ids and its catalogue key, which the shared key name table turns
--- into « Ctrl + Maj + Entrée » in the active language. They used to be English
--- labels computed once, the same in every locale.
local MODIFIER_ACTION_PARTS = {}

-- Dynamic modifier-key actions use the same shared catalogue as Windows and
-- macOS.
local MODIFIER_ACTION_COMMANDS = {}

-- The chord matrix in picker order: one { label, actions } group per modifier
-- combination, as the other two drivers build it.
local MODIFIER_ACTION_GROUPS = {}

local function load_modifier_chords()
	local path = Paths.shared("shortcuts/data/actions/modifier_chords.json")
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "Could not resolve the shared modifier chords JSON path.")
		return nil
	end
	if type(TomlWriter) ~= "table" or type(TomlWriter.read_classified) ~= "function" then
		Logger.warn(LOG, "Shared modifier chords JSON cannot be read: classified reader unavailable.")
		return nil
	end
	local raw, status = TomlWriter.read_classified(path)
	if status ~= "ok" then
		Logger.warn(LOG, "Shared modifier chords JSON unreadable at '%s'.", path)
		return nil
	end
	local ok_json, json = pcall(require, "core.text.engine.json")
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
		local ids, native_modifiers = {}, {}
		for index, modifier in ipairs(modifiers) do
			if math.floor(mask / (2 ^ (index - 1))) % 2 == 1 then
				ids[#ids + 1] = modifier.id
				native_modifiers[#native_modifiers + 1] = modifier.xdotool
			end
		end
		local id_prefix = table.concat(ids, "_")
		local group = { modifiers = ids, actions = {} }
		for _, key_def in ipairs(keys) do
			local action_id = id_prefix .. "_" .. key_def.id
			local key = key_def.linux_key or key_def.id
			MODIFIER_ACTION_PARTS[action_id] = { modifiers = ids, key = key_def }
			MODIFIER_ACTION_COMMANDS[action_id] = table.concat(native_modifiers, "+") .. "+" .. key
			group.actions[#group.actions + 1] = action_id
		end
		MODIFIER_ACTION_GROUPS[#MODIFIER_ACTION_GROUPS + 1] = group
	end
end

register_modifier_chords(load_modifier_chords())

--- Launches an application for the user (xdg-open, gtk-launch, a settings
--- app) in the background, discarding its output. The shell that forks it
--- answers at once, and its refusal is logged, never dropped; the command
--- itself is not logged, as it can carry a selected path or URL. The child is
--- the application, which outlives the action, so it has no completion to
--- report: one-shot commands go through BackgroundCommands instead.
--- @param cmd string A fully composed command.
--- @return boolean started
local function run_background(cmd)
	local called, result, _, code = pcall(os.execute, cmd .. " 2>/dev/null &")
	-- LuaJIT returns the status number; Lua 5.2+ returns true, or nil and the code.
	if called and (result == true or result == 0) then return true end
	Logger.error(LOG, "The shell refused to start a background action command (%s).",
		tostring(called and (code or result) or result))
	return false
end

local function shell_quote(value)
	return TextUtils.shell_quote(value or "")
end

local function url_encode_query(value)
	return TextUtils.percent_encode(tostring(value or ""))
end

local function primary_selection()
	local called, ok, value = pcall(function() return require("clipboard.adapters.clipboard").read_primary() end)
	if not called or ok ~= true or type(value) ~= "string" then return "" end
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
local BrightnessActions = require("shortcuts.engine.brightness_actions")
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

--- The webview window each `open_*` action toggles, by action id: closed
--- opens it, covered brings it to the front, frontmost closes it
--- (core/ui/ui/webview_manager.lua toggle()).
---
--- Data rather than branches so the set can be compared against the shared
--- catalogue by a gate: a table has a length, a chain of `elseif` does not.
local OPEN_WINDOW = {
	["open_metrics_typing"]      = "metrics_typing",
	["open_metrics_apps"]        = "metrics_apps",
	["open_hotstrings_editor"]   = "hotstring_editor",
	["open_paths_editor"]        = "paths_editor",
	["open_hotstrings_settings"] = ConfigKeys.COMMAND.HOTSTRINGS_CONFIG_WINDOW,
	["open_layout_manager"]      = ConfigKeys.COMMAND.LAYOUT_MANAGER,
	["open_layer_editor"]        = "layer_editor",
	["open_model_browser"]       = "model_browser",
	["open_changelog"]           = "changelog",
	["open_healthcheck"]         = ConfigKeys.COMMAND.HEALTHCHECK,
}

--- The pages whose opener is not the manager's show(), by app name: the
--- diagnostics window starts its probes in its bridge's open().
local OPEN_WINDOW_OPENER = {
	[ConfigKeys.COMMAND.HEALTHCHECK] = function() return require("ui.healthcheck.bridge").open() end,
}

--- The user-editable file each `open_*` action reveals, as a path resolver.
---
--- Resolvers rather than strings: the paths depend on $XDG_CONFIG_HOME, and
--- freezing them at load would open the wrong directory under a changed
--- environment.
local OPEN_PATH = {
	["open_script_source"]      = function() return require("core.fs.engine.paths").driver_root() .. "/ergopti_hotstrings.lua" end,
	["open_config"]             = function(Paths) return Paths.config("config.toml") end,
	["open_personal_info"]      = function(Paths) return Paths.config("personal_info.toml") end,
	["open_personal_hotstrings"] = function(Paths) return Paths.config("personal_hotstrings.toml") end,
	-- The programmable personal source, created from its template when absent,
	-- as Windows and macOS create theirs before opening it.
	["open_personal_shortcuts"] = function() return require("infra.personal_shortcuts").path_for_editing() end,
}

--- The three log actions, by ui/log_openers function: shared with the tray, so
--- a missing errors file is announced there and here alike.
local OPEN_LOG = {
	["open_logs_folder"] = "open_logs_folder",
	[ConfigKeys.COMMAND.OPEN_TODAY_LOG]   = ConfigKeys.COMMAND.OPEN_TODAY_LOG,
	[ConfigKeys.COMMAND.OPEN_ERROR_LOG]   = "open_today_errors",
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
-- A pipeline reports the clipboard writer's status even if the capture tool
-- failed. Stage the PNG privately so a failed or empty capture cannot erase the
-- clipboard or stop the fallback cascade.
local function screenshot_to_clipboard(capture, writer)
	return '( d=$(mktemp -d "${TMPDIR:-/tmp}/ergopti-screenshot.XXXXXXXX") || exit 1; '
		.. [=[f="$d/capture.png"; trap 'rm -f "$f"; rmdir "$d"' 0; ]=]
		.. [=[trap 'exit 1' HUP INT TERM; ]=] .. capture .. ' "$f" && [ -s "$f" ] && '
		.. writer .. ' < "$f" )'
end

-- Each candidate gets an empty reserved destination: a later command's
-- successful exit cannot turn an earlier command's partial output into a PNG.
local function screenshot_to_file(capture)
	return "{ : > %s && " .. capture .. " %s && [ -s %s ]; }"
end

local SCREENSHOT_COMMANDS = {
	["screenshot_fullscreen_clipboard"] =
		screenshot_to_clipboard("grim", "wl-copy --type image/png")
		.. " || gnome-screenshot -c || spectacle -bnc || "
		.. screenshot_to_clipboard("maim", "xclip -selection clipboard -t image/png"),
	["screenshot_fullscreen_save"] =
		screenshot_to_file("grim") .. " || " .. screenshot_to_file("gnome-screenshot -f")
		.. " || " .. screenshot_to_file("spectacle -bno") .. " || " .. screenshot_to_file("maim"),
	["screenshot_region_clipboard"] =
		screenshot_to_clipboard('grim -g "$(slurp)"', "wl-copy --type image/png")
		.. " || gnome-screenshot -ac || spectacle -bnrc || "
		.. screenshot_to_clipboard("maim -s", "xclip -selection clipboard -t image/png"),
	["screenshot_region_save"] =
		screenshot_to_file('grim -g "$(slurp)"') .. " || " .. screenshot_to_file("gnome-screenshot -af")
		.. " || " .. screenshot_to_file("spectacle -bnro") .. " || " .. screenshot_to_file("maim -s"),
	["screenshot_window_clipboard"] =
		"gnome-screenshot -wc || spectacle -bnac || "
		.. screenshot_to_clipboard('maim -i "$(xdotool getactivewindow)"', "xclip -selection clipboard -t image/png"),
	["screenshot_window_save"] =
		screenshot_to_file("gnome-screenshot -wf") .. " || " .. screenshot_to_file("spectacle -bnao")
		.. " || " .. screenshot_to_file('maim -i "$(xdotool getactivewindow)"'),
}
-- The frontmost window saved at once, with no selection: what macOS and
-- Windows name screen_capture_instant is this driver's window capture.
SCREENSHOT_COMMANDS["screen_capture_instant"] = SCREENSHOT_COMMANDS["screenshot_window_save"]

--- ocr_screenshot: the region the user draws, captured by the region cascade
--- into a private temporary file, read by tesseract in every language it has
--- installed (its own "osd" script detector is not a language), and the text
--- left on the clipboard, Wayland first as for the captures. The capture is
--- removed whatever happens; a cancelled selection leaves the clipboard alone.
local OCR_COMMAND = '( d=$(mktemp -d "${TMPDIR:-/tmp}/ergopti-ocr.XXXXXXXX") || exit 1; '
	.. [=[f="$d/capture.png"; trap 'rm -f "$f"; rmdir "$d"' 0; trap 'exit 1' HUP INT TERM; { ]=]
	.. SCREENSHOT_COMMANDS["screenshot_region_save"]:gsub("%%s", '"$f"')
	.. "; } && [ -s \"$f\" ]"
	.. " && langs=$(tesseract --list-langs 2>/dev/null | tail -n +2 | grep -vx osd | tr '\\n' '+')"
	.. " && text=$(tesseract \"$f\" - ${langs:+-l \"${langs%+}\"} 2>/dev/null)"
	.. " && [ -n \"$text\" ]"
	.. " && { printf '%s' \"$text\" | wl-copy 2>/dev/null || printf '%s' \"$text\" | xclip -selection clipboard; };"
	.. " )"

--- Where a saved screenshot lands, and under what name.
---
--- $XDG_PICTURES_DIR when the user's desktop declares one, the conventional
--- ~/Pictures otherwise. This is a prefix; the shell reserves a unique name
--- before the capture tool can write it.
--- @param kind string Short tag: "full", "reg" or "win".
--- @return string An absolute path.
local function screenshot_path(kind)
	local dir = os.getenv("XDG_PICTURES_DIR")
	if not dir or dir == "" then
		local ok, Paths = pcall(require, "settings.engine.paths")
		dir = (ok and Paths.home() or ".") .. "/Pictures"
	end
	return string.format("%s/ergopti_%s_%s", dir, kind, os.date("%Y-%m-%d_%H-%M-%S"))
end

--- The tag each save action stamps into its filename.
local SCREENSHOT_KIND = {
	["screenshot_fullscreen_save"] = "full",
	["screenshot_region_save"]     = "reg",
	["screenshot_window_save"]     = "win",
	["screen_capture_instant"]     = "win",
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
	["ocr_screenshot"]    = OCR_COMMAND,
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
	["run_program"] = function(binding) return M.run_program(binding) end,
	-- The user's own command line and file or folder: each value is decoded by
	-- _shared/user_action_parameter and never logged.
	["run_command"] = function(binding)
		local fields = UserActionParameter.parse("command", M.get_action_parameter(binding, "run_command"))
		if not fields then
			Logger.warn(LOG, "run_command ignored for binding '%s': no valid command is stored.", tostring(binding))
			return false
		end
		-- The shortcuts manager owns the send-input vocabulary (read here, not
		-- through send_vocabulary(), which is declared below this table)
		return UserActions.run_command(fields, require("modules.shortcuts.manager").send_vocabulary().text_max_code_points)
	end,
	["open_path"] = function(binding)
		local fields = UserActionParameter.parse("path", M.get_action_parameter(binding, "open_path"))
		if not fields then
			Logger.warn(LOG, "open_path ignored for binding '%s': no valid path is stored.", tostring(binding))
			return false
		end
		return UserActions.open_path(fields)
	end,
	["alt_tab_monitor"] = function(binding) return M.run_window_switch(binding) end,
	["open_system_settings"] = function()
		local Shell = require("core.process.adapters.shell_runner")
		for _, application in ipairs(SETTINGS_APPLICATIONS) do
			if Shell.has_command(application) then
				run_background(shell_quote(application))
				return
			end
		end
		Logger.error(LOG, "open_system_settings: none of %s is installed — nothing opened.",
			table.concat(SETTINGS_APPLICATIONS, ", "))
	end,
	["left_click_toggle"] = function(binding)
		if (_parameter_configuration_owner or _gesture_click_fence) and M.DEFAULT_GESTURES[binding] ~= nil then return false end
		return _click_holds.toggle("1", binding)
	end,
	["right_click_toggle"] = function(binding)
		if (_parameter_configuration_owner or _gesture_click_fence) and M.DEFAULT_GESTURES[binding] ~= nil then return false end
		return _click_holds.toggle("3", binding)
	end,
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
	-- The selected files' paths in a file manager, otherwise what the primary
	-- selection names: modules/shortcuts/open_selection.
	["copy_selected_path"] = function()
		return require("modules.shortcuts.open_selection").copy_selected_path(primary_selection)
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


-- The observer told about every key combination the catalogue emitted AND the
-- virtual keyboard acknowledged, whoever asked for it (a gesture, a keyboard
-- shortcut, a tap-hold). The emitted keys never reach the hook, so this is the
-- only place their logical effect (an arrow word and AI-context reset, a
-- word-capitalisation delimiter) can be published, once, after the output is certain.
local _effect_observer = nil

local function _execute_action(action_name, go_next, binding)
	if not action_name or action_name == "none" then return end

	local function _run(cmd)
		pcall(function() os.execute(cmd .. " 2>/dev/null &") end)
	end

	--- Presses one combination: xdotool requires a positively observed unavailable
	--- channel before native acquisition, never a failed or unsettled native send.
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
		if not emitter_authority_current() then
			Logger.error(LOG, "The gesture emitter is unavailable; '%s' was refused.", combo)
			return false
		end
		local press, certify = _emitter_press, _emitter_certify
		local emitted, result = press(combo)
		if emitted == true then return true end
		Logger.debug(LOG, "Checking pre-acquisition fallback admission for '%s' (X11 only).", combo)
		if emitted ~= false or type(certify) ~= "function"
			or not emitter_authority_current()
			or certify(result, combo) ~= true
			or not emitter_authority_current() then
			Logger.warn(LOG, "Gesture '%s' refused another output producer after native refusal or unknown custody.", combo)
			return false
		end
		_run("xdotool key " .. combo)
		return true
	end

	--- Raises one of the driver's own windows, or reveals one of its files.
	--- @param name string The action id.
	--- @return boolean True when this action was handled here.
	local function _open_driver_surface(name)
		local window = OPEN_WINDOW[name]
		if window then
			local ok, Webview = pcall(require, "core.ui.ui.webview_manager")
			if not ok or type(Webview.toggle) ~= "function" then
				-- Loud, because the user asked for a window and none appeared. A
				-- headless daemon (no GTK, no display) is the ordinary reason and it
				-- is worth naming rather than leaving the chord looking dead.
				Logger.error(LOG, "No webview manager — '%s' cannot open its window.", name)
				return true
			end
			local called, err = pcall(Webview.toggle, window, OPEN_WINDOW_OPENER[window])
			if not called then
				Logger.error(LOG, "Toggling the '%s' window raised: %s.", window, tostring(err))
			end
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
		local ok_paths, Paths = pcall(require, "settings.engine.paths")
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
		local kind, detail, code = require("core.fs.engine.native_directory").target_kind(target)
		if kind == nil and code == "ENOENT" and not target:match("/$") then
			Logger.warn(LOG, "'%s' points at '%s', which does not exist yet.", name, target)
		elseif kind == nil and code ~= "ENOENT" then
			Logger.error(LOG, "Cannot inspect '%s': %s.", name, tostring(detail or code))
			return true
		elseif kind == "other" then
			Logger.error(LOG, "Cannot open '%s': the target is not a regular file or directory.", name)
			return true
		end
		run_background("xdg-open " .. shell_quote(target))
		return true
	end

	-- A modifier chord (Ctrl+A, the only Select All on Linux) and an action the
	-- shared catalogue describes as one xdotool combo are both one keystroke.
	--
	-- 26 elseif branches used to sit here, each spelling out a combo that the
	-- macOS and Windows registries also spelled out in their own vocabularies.
	-- They now come from _shared/shortcuts/data/actions/actions.toml via
	-- _generated/gesture_emit_actions.lua. The combos are X11 keysym syntax and
	-- are Linux's own: Linux and Windows agree far more often than either agrees
	-- with macOS (alt+F4 and ctrl+Right on both, against cmd+w and alt+right).
	-- The modifier chords used to run their own `xdotool key` in the background,
	-- which did nothing under Wayland; they take the uinput path below as well.
	local emit_combo = MODIFIER_ACTION_COMMANDS[action_name] or _EMIT_ROWS[action_name]
	if emit_combo then
		if _press_combo(emit_combo) == true and _effect_observer then
			local observed, detail = pcall(_effect_observer, action_name, emit_combo, binding)
			if not observed then
				Logger.error(LOG, "The action effect observer raised for '%s': %s.", action_name, tostring(detail))
			end
		end
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
			-- mktemp -d provides a fresh name without GNU's --suffix option. The
			-- noclobber reservation also refuses an existing PNG from an older run.
			local template = shell_quote(screenshot_path(kind) .. ".XXXXXXXX")
			shot = shot:gsub("%%s", '"$f"')
			shot = '( d=$(mktemp -d ' .. template .. ') || exit 1; f="$d.png"; '
				.. '( set -C; : > "$f" ) || { rmdir "$d"; exit 1; }; rmdir "$d"; '
				.. [=[trap 'rm -f "$f"' 0; trap 'exit 1' HUP INT TERM; { ]=] .. shot
				.. '; } && [ -s "$f" ] && trap - 0 )'
		end
		-- One-shot commands report their own failure (LDS-001); the
		-- application launches above keep run_background, whose child is the
		-- application itself.
		BackgroundCommands.run(shot, action_name)
		return
	end

	local direct = DIRECT_COMMANDS[action_name]
	if direct then
		BackgroundCommands.run(direct, action_name)
		return
	end

	if SystemActions.COMMANDS[action_name] then
		local meta = Catalogue.actions[action_name]
		local command = SystemActions.command_for(action_name, M.get_action_label(action_name),
			meta ~= nil and meta.confirm == true)
		if command then BackgroundCommands.run(command, action_name) end
		return
	end
	local system_handler = SystemActions.HANDLERS[action_name]
	if system_handler then
		local ok, err = pcall(system_handler, {
			-- Handler commands can name the user's files: their stderr stays out of the log.
			run_background = function(command) return BackgroundCommands.run(command, action_name, true) end,
			clipboard = require("clipboard.adapters.clipboard"),
			emit_combo = require("modules.gestures.combo_emitter").press,
			sleep_ms = require("core.events.loop").sleep_ms,
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

--- The name of one gesture slot in the user's language, the same
--- gesture.slots.* text the Windows and macOS menus show. The menu rows used
--- to read a French sentence built there (« Balayage 3 doigts vers haut ») in
--- every locale.
--- @param slot string A slot of the shared gesture catalogue.
--- @return string
function M.slot_label(slot)
	return i18n.get("gesture.slots." .. tostring(slot))
end

--- Returns a human-readable label for an action.
--- @param action_name string
--- @return string
function M.get_action_label(action_name)
	if not action_name or action_name == "" then return "∅" end
	local chord = MODIFIER_ACTION_PARTS[action_name]
	if chord then return KeyNames.chord_label(chord.modifiers, chord.key, "linux", i18n.get) end
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
--- @param token string "tool:<binary>", "session:x11", "session:workspaces",
---   "file_manager:folder" or "ai:on".
--- @return boolean|nil True/false when proven, nil when it cannot be told —
---   a probe that could not read the machine must never take a binding away.
--- @return string|nil hint Localized reason when the requirement is absent.
local function requirement_holds(token)
	local tool = token:match("^tool:(.+)$")
	if tool then
		local ok, Shell = pcall(require, "core.process.adapters.shell_runner")
		if not ok or type(Shell.has_command) ~= "function" then return nil, nil end
		if Shell.has_command(tool, true) then return true, nil end
		local hint = i18n.get("dialog.action_picker.requires_tool"):gsub("{1}", function() return tool end)
		return false, hint
	end
	if token == "session:x11" then
		local ok, Display = pcall(require, "core.ui.engine.display_server")
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
	if token == "file_manager:folder" then
		-- A file manager that publishes its windows' folders (Nautilus): with
		-- only Thunar, Dolphin or another one installed, the row stays greyed
		-- with the reason (core/fs/adapters/file_manager_folder.lua).
		if require("core.fs.adapters.file_manager_folder").supported_installed() then return true, nil end
		return false, i18n.get("platform_reason.action_file_manager_folder_is_unreadable_on_linux")
	end
	if token == "ai:on" then
		-- The AI menu's switch: nothing of the AI runs while it is off, so the
		-- row stays visible and greyed with the AI-off hint.
		if AiActions.off() then return false, i18n.get("dialog.action_picker.requires_ai") end
		return true, nil
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
		if action_name == "run_program" and not ProgramOwner.available() then
			return false, i18n.get("platform_reason.program_runner_unavailable")
		end
		if action_name == "alt_tab_monitor" then
			local available, reason, tool = WindowSwitch.available()
			if available ~= true then
				local hint = i18n.get(reason)
				if tool then hint = hint:gsub("{1}", function() return tool end) end
				return false, hint
			end
		end
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
				local names = KeyNames.modifiers_label(group.modifiers, "linux", i18n.get)
				items[#items + 1] = {
					type = "heading", level = item.level,
					text = (template:gsub("{1}", function() return names end)),
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
local _parameter_delivery_epoch = 0
local _scope_owner   = nil   -- retains refused runtime compensation
require("settings.engine.scope.registry").register("gesture_scope", function()
	return _scope_owner ~= nil and _scope_owner.pending() == true
end)
local _scope_native = false -- admits only the scope's synchronous native inverse
local _scope_sequence = 0
local _program_owner = nil
local _window_owner = nil
local _program_revision = 0

--- Revokes scoped native activation before configuration gains publication rights.
--- @return boolean retired Exact window process, files and timer are settled.
local function retire_window_operation()
	if not _window_owner or not _window_owner.has_pending() then return true end
	local owner, revision = _window_owner, _program_revision
	return owner.invalidate() == true and _window_owner == owner and _program_revision == revision
		and not owner.has_pending()
end

--- Keeps captured preferences exclusively owned until compensation completes.
--- @return boolean admitted
local function admit_mutation(owner)
	if _gesture_click_fence ~= nil and _gesture_click_fence ~= owner then return false end
	local bindings = package.loaded["settings.engine.preferences.program_binding_transaction"]
	if type(bindings) == "table" and bindings.pending() and not bindings.owns(owner) then return false end
	if _parameter_configuration_owner ~= nil then return false end
	if _scope_owner and _scope_owner ~= owner and _scope_owner.pending() then
		Logger.error(LOG, "Gesture configuration remains owned by a pending scope transaction.")
		return false
	end
	return true
end

--- Copies one flat state map for a persistence-before-publication transaction.
--- @param source table
--- @return table
local copy_state = TableUtil.shallow_copy

-- Initialize actions with defaults.
for k, v in pairs(M.DEFAULT_GESTURES) do
	_actions[k] = v
end

-- Retire only clicks acquired by gesture bindings that no longer name them.
local function retire_changed_click_bindings(previous, candidate)
	for slot, old in pairs(previous) do
		if candidate[slot] ~= old then
			if old == "left_click_toggle" then _click_holds.retire_binding("1", slot)
			elseif old == "right_click_toggle" then _click_holds.retire_binding("3", slot) end
		end
	end
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

local preserve_scope_clicks = {}
local stop_reading_preserving_clicks
-- Defined with the dispatch below; declared here for the incremental tracker.
local answering_slot

--- Persists and applies the master gesture state as one transaction.
--- @param enabled boolean
--- @return boolean True when the requested state was committed.
function M.set_enabled(enabled)
	if _gesture_click_fence ~= nil or not admit_mutation() then return false end
	if type(enabled) ~= "boolean" then
		Logger.error(LOG, "Gesture state must be a boolean — nothing changed.")
		return false
	end

	local snapshot = M.capture_scope_state()
	if not snapshot then return false end
	local candidate = M.capture_scope_state()
	candidate.enabled, candidate.reading = enabled, enabled
	-- Install the recovery owner before reader, process or persistence callbacks.
	local debt, uncertain, source, candidate_bytes = snapshot, false, nil, nil
	local owner, retire_clicks = {}, nil
	function owner.pending() return debt ~= nil end
	function owner.retry_restore()
		if debt == nil then return true end
		if uncertain then
			if not source or type(candidate_bytes) ~= "string" then return false end
			local called, bytes, status = pcall(TomlWriter.read_classified, _config_path)
			if not called then return false end
			if status == "ok" and bytes == candidate_bytes then
				debt = nil
				if retire_clicks then pcall(retire_clicks) end
				if _gesture_click_fence == owner then _gesture_click_fence = nil end
				return true, "committed"
			end
			if status ~= source.status or (status == "ok" and bytes ~= source.content) then return false end
			uncertain = false
		end
		local called, restored = pcall(M.apply_scope_state, debt, preserve_scope_clicks)
		if not called or restored ~= true then return false end
		debt = nil
		if _gesture_click_fence == owner then _gesture_click_fence = nil end
		return true
	end
	function owner.revert() return false, "no committed gesture scope to revert" end
	function owner.release() end
	_scope_owner = owner
	_gesture_click_fence = owner
	retire_clicks = not enabled and _click_holds.capture_retirement() or nil
	local updates = { { section = CONFIG_SECTION, key = "enabled", value = enabled } }
	if _persist then
		local prepared, accepted, _, bytes, original = pcall(TomlWriter.prepare_batch, _config_path, updates)
		if not prepared or accepted ~= true then
			debt = nil
			if _gesture_click_fence == owner then _gesture_click_fence = nil end
			return false
		end
		candidate_bytes, source = bytes, original
	end
	local called, applied = pcall(M.apply_scope_state, candidate, preserve_scope_clicks)
	if called and applied == true then
		local saved, accepted, detail = pcall(M._persist_updates,
			updates, nil, owner, source)
		if saved and accepted == true then
			debt = nil
			if retire_clicks then
				local ok = pcall(retire_clicks)
				if not ok then pcall(Logger.error, LOG, "Could not advance captured gesture click cleanup; its owner retains the debt.") end
			end
			if _gesture_click_fence == owner then _gesture_click_fence = nil end
			return true
		end
		-- An exception may follow publication; do not guess which bytes won.
		if not saved or detail == "publication_unknown" then uncertain = true end
	end
	local recovered, resolution = owner.retry_restore()
	if recovered and resolution == "committed" then
		Logger.warn(LOG, "Gesture state publication was confirmed after an uncertain response.")
		return true
	elseif recovered then
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
	local previous = _actions
	local staged = copy_state(previous)
	staged[slot] = action_name
	if not M._persist_updates({ { section = CONFIG_SECTION, key = slot, value = action_name } }) then
		Logger.error(LOG, "Gesture assignment was not persisted — nothing changed.")
		return false
	end
	_actions = staged
	_program_revision = _program_revision + 1
	retire_changed_click_bindings(previous, staged)
	Logger.info(LOG, "Gesture '%s' → '%s'.", slot, tostring(action_name))
	return true
end

function M.get_action_parameter_spec(action_name)
	return M.ACTION_PARAMETER_SPECS[action_name]
end

-- The parameter kinds the shortcuts manager parses (_shared/platform/input).
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
	if spec == "llm_prompt" then
		local parsed = PromptAction.parse(value)
		return parsed ~= nil and (parsed.translation_target == nil
			or require("ai.engine.prediction.translation").is_valid(parsed.translation_target))
	end
	-- Syntax only as well: whether the provider exists, has a key and a
	-- default model is checked when the action runs.
	if spec == "llm_vision" then return Vision.is_valid(value) end
	-- An admitted per-binding language name or retained locale code (translate.lua).
	if spec == "llm_language" then return require("ai.engine.prediction.translation").is_valid(value) end
	-- Syntax only: whether the desktop entry exists is gtk-launch's to say.
	if spec == "app" then return AppParameter.is_valid(value) end
	if spec == "program" then return ProgramParameter.parse(value, "posix") ~= nil end
	-- Syntax only: whether the path still exists is checked when it opens.
	if UserActionParameter.KINDS[spec] then return UserActionParameter.parse(spec, value) ~= nil end
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
	if spec == "program" then return i18n.get("dialog.gestures.param_program") end
	if UserActionParameter.KINDS[spec] then return i18n.get(UserActionParameter.PROMPT_KEYS[spec]) end
	if spec == "wrap_pair" then
		local Shortcuts = shortcuts_manager()
		local WrapPair = require("keyboard.engine.wrap_pair")
		local samples = WrapPair.describe(Shortcuts and Shortcuts.get_wrap_pair_list() or {})
		local template = i18n.get("dialog.gestures.param_wrap_pair")
		local at = template:find("{1}", 1, true)
		if not at then return template .. "\n" .. samples end
		return template:sub(1, at - 1) .. samples .. template:sub(at + 3)
	end
	if SEND_INPUT_KINDS[spec] then
		local vocabulary = send_vocabulary()
		local detail = spec == "text" and tostring(vocabulary.text_max_code_points)
			or require("platform.input.send_input").describe_keys(vocabulary)
		return fill_placeholder(i18n.get("dialog.gestures.param_" .. spec), detail)
	end
	if spec == "llm_prompt" then
		local lines = {}
		for _, choice in ipairs(require("ai.engine.settings.profile_settings").choices()) do
			lines[#lines + 1] = choice.value .. " — " .. choice.label
		end
		return fill_placeholder(i18n.get("dialog.gestures.param_llm_prompt"), table.concat(lines, "\n"))
	end
	if spec == "llm_vision" then
		local lines = {}
		for _, choice in ipairs(require("ai.engine.prediction.vision_request").backend_choices()) do
			lines[#lines + 1] = choice.value .. " — " .. choice.label
		end
		return fill_placeholder(i18n.get("dialog.gestures.param_llm_vision"), table.concat(lines, "\n"))
	end
	if spec == "llm_language" then
		local data = require("ai.engine.prediction.translation").data()
		if not data then error("the translation parameter is unavailable") end
		return fill_placeholder(i18n.get("dialog.gestures.param_llm_language"), tostring(data.config.max_language_bytes))
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
	if spec == "program" then return i18n.get("dialog.gestures.param_err_program") end
	if spec == "command" then
		return fill_placeholder(i18n.get(UserActionParameter.ERROR_KEYS.command),
			tostring(UserActionParameter.MAX_COMMAND_BYTES))
	end
	if UserActionParameter.KINDS[spec] then return i18n.get(UserActionParameter.ERROR_KEYS[spec]) end
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
	if type(binding) == "string" and (binding:sub(1, 9) == "tap_key__" or binding:sub(1, 10) == "keyboard__" or binding:sub(1, 8) == "script__" or binding:sub(1, 13) == "combination__") then
		local fits, reason = M.action_parameter_binding_fits(binding)
		if fits == false then
			if _action_params[parameter_key(binding, action_name)] ~= nil then
				ConfigOutdated.report({ CONFIG_SECTION_PARAMS, parameter_key(binding, action_name) }, reason, Logger)
			end
			return ""
		end
	end
	return _action_params[parameter_key(binding, action_name)] or ""
end

local function binding_action(binding)
	if M.DEFAULT_GESTURES[binding] ~= nil then return M.get_action(binding), "gestures", binding end
	local tap_id = type(binding) == "string" and binding:match("^tap_hold__(.+)$") or nil
	if tap_id then
		return require("platform.remap.tap_hold_manager").get_tap_action(tap_id), "tap_hold", tap_id
	end
	local descriptors = {
		{ "keyboard__", "modules.shortcuts.keyboard_shortcuts", "keyboard" },
		{ "script__", "modules.shortcuts.script_chords", ConfigKeys.LEAF.SCRIPT_CONTROL },
		{ "tap_key__", "modules.shortcuts.tap_keys", "tap_keys" },
		{ "combination__", "modules.shortcuts.key_combinations", "key_combination_taps" },
	}
	for _, descriptor in ipairs(descriptors) do
		if binding:sub(1, #descriptor[1]) == descriptor[1] then
			local id = binding:sub(#descriptor[1] + 1)
			local loaded, provider = pcall(require, descriptor[2])
			if not loaded or type(provider) ~= "table" or type(provider.get_action) ~= "function" then return nil end
			return provider.get_action(id), descriptor[3], id
		end
	end
	return nil
end

--- Captures the actual binding and exact canonical source before native acquisition.
local function capture_program(binding)
	if _persist ~= true or type(binding) ~= "string" or not admit_mutation() then return nil end
	local FileSystem = require("core.fs.adapters.file_system")

	local runtime, section, id = binding_action(binding)
	if runtime ~= "run_program" then return nil end
	local pair_guard
	if section == "key_combination_taps" then
		pair_guard = require("modules.shortcuts.key_combinations").capture_action(binding, "run_program")
		if type(pair_guard) ~= "function" or pair_guard() ~= true then return nil end
	end
	local scalar = M.get_action_parameter(binding, "run_program")
	if ProgramParameter.parse(scalar, "posix") == nil then return nil end
	local content, status = FileSystem.read_with_status(_config_path)
	if status ~= "ok" or type(content) ~= "string" then return nil end
	local decoded, config = pcall(TomlCodec.decode, content)
	if not decoded or type(config) ~= "table" then return nil end
	local parameters = config[CONFIG_SECTION_PARAMS]
	local actions = section == "gestures" and config.gestures
		or type(config.shortcuts) == "table" and config.shortcuts[section]
	if type(actions) ~= "table" or actions[id] ~= "run_program" or type(parameters) ~= "table"
		or parameters[parameter_key(binding, "run_program")] ~= scalar then return nil end
	local revision = _program_revision
	return scalar, function()
		local paused_ok, paused = pcall(_is_paused)
		if pair_guard and pair_guard() ~= true then return false end
		if not paused_ok or paused ~= false or revision ~= _program_revision or not admit_mutation()
			or M.get_action_parameter(binding, "run_program") ~= scalar or binding_action(binding) ~= "run_program" then return false end
		local current, current_status = FileSystem.read_with_status(_config_path)
		return current_status == "ok" and current == content
	end
end

--- Returns the physical native start receipt, independently of dispatch ownership.
function M.run_program(binding)
	if _program_owner == nil then _program_owner = ProgramOwner.new(capture_program) end
	return _program_owner.run(binding)
end

function M.set_program_paused(paused)
	-- The hidden run_command children follow the same pause as user programs
	local commands_settled = UserActions.set_paused(paused)
	local inhibitor = package.loaded["modules.keep_awake"]
	if paused == true and inhibitor and inhibitor.stop() ~= true then commands_settled = false end
	if _program_owner == nil then return type(paused) == "boolean" and commands_settled end
	return _program_owner.set_paused(paused) and commands_settled
end

function M.stop_programs()
	local commands_settled = UserActions.stop()
	local inhibitor = package.loaded["modules.keep_awake"]
	if inhibitor and inhibitor.stop() ~= true then commands_settled = false end
	if _program_owner == nil then return commands_settled end
	return _program_owner.stop() and commands_settled
end

function M.when_programs_settled(callback)
	if type(callback) ~= "function" then return false end
	local inhibitor = package.loaded["modules.keep_awake"]
	local commands_done, programs_done, inhibitor_done, delivered = false, _program_owner == nil, inhibitor == nil, false
	local function notify()
		if commands_done and programs_done and inhibitor_done and not delivered then
			delivered = true
			local ok = pcall(callback)
			if not ok then Logger.error(LOG, "Program settlement listener failed.") end
		end
	end
	if UserActions.when_settled(function() commands_done = true; notify() end) ~= true then return false end
	if inhibitor and inhibitor.when_settled(function() inhibitor_done = true; notify() end) ~= true then return false end
	if _program_owner ~= nil then
		if _program_owner.when_settled(function() programs_done = true; notify() end) ~= true then return false end
	end
	notify()
	return true
end

--- Captures canonical action ownership and the current physical input generation.
local function capture_window(binding)
	if _persist ~= true or type(binding) ~= "string" or not admit_mutation() then return nil end
	local action, section, id = binding_action(binding)
	if action ~= "alt_tab_monitor" then return nil end
	local pair_guard
	if section == "key_combination_taps" then
		pair_guard = require("modules.shortcuts.key_combinations").capture_action(binding, action)
		if type(pair_guard) ~= "function" or pair_guard() ~= true then return nil end
	end
	local FileSystem = require("core.fs.adapters.file_system")
	local Keyboard = require("platform.input.keyboard_hook")
	local physical = Keyboard.physical_source_receipt()
	if type(physical) ~= "table" or physical.ready ~= true then return nil end
	if section == "tap_hold" then
		local tap_guard, path = require("platform.remap.tap_hold_manager").capture_tap_action(binding, "alt_tab_monitor")
		if type(tap_guard) ~= "function" then return nil end
		local revision = _program_revision
		return function()
			local ok, paused = pcall(_is_paused)
			if not ok or paused ~= false or revision ~= _program_revision or not admit_mutation()
				or binding_action(binding) ~= "alt_tab_monitor" or tap_guard() ~= true then return false end
			local current = Keyboard.physical_source_receipt()
			return type(current) == "table" and current.ready == true and current.generation == physical.generation
		end, path
	end
	local content, status = FileSystem.read_with_status(_config_path)
	if status ~= "ok" or type(content) ~= "string" then return nil end
	local decoded, config = pcall(TomlCodec.decode, content)
	if not decoded or type(config) ~= "table" then return nil end
	local actions = section == "gestures" and config.gestures
		or type(config.shortcuts) == "table" and config.shortcuts[section]
	if type(actions) ~= "table" or actions[id] ~= "alt_tab_monitor" then return nil end
	local revision = _program_revision
	return function()
		local ok, paused = pcall(_is_paused)
		if pair_guard and pair_guard() ~= true then return false end
		if not ok or paused ~= false or revision ~= _program_revision or not admit_mutation()
			or binding_action(binding) ~= "alt_tab_monitor" then return false end
		local current = Keyboard.physical_source_receipt()
		if type(current) ~= "table" or current.ready ~= true or current.generation ~= physical.generation then return false end
		local text, current_status = FileSystem.read_with_status(_config_path)
		return current_status == "ok" and text == content
	end, _config_path
end

--- Starts the scoped operation; completion never substitutes global Alt+Tab.
function M.run_window_switch(binding, done)
	if _window_owner == nil then _window_owner = WindowSwitch.new(capture_window) end
	return _window_owner.run(binding, done)
end

function M.set_window_switch_paused(paused)
	if _window_owner == nil then return type(paused) == "boolean" end
	return _window_owner.set_paused(paused)
end

function M.window_switches_pending()
	return _window_owner ~= nil and _window_owner.has_pending()
end

function M.stop_window_switches()
	if _window_owner == nil then return true end
	return _window_owner.stop()
end

function M.when_window_switches_settled(callback)
	if _window_owner == nil then
		if type(callback) ~= "function" then return false end
		pcall(callback); return true
	end
	return _window_owner.when_settled(callback)
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
	local combination = type(binding) == "string" and binding:match("^combination__") ~= nil
		and require("modules.shortcuts.key_combinations").configuration_domain(binding) == "combination"
	for _, item in ipairs(items) do
		local kind = item.type == "action" and M.get_action_parameter_spec(item.id) or nil
		if kind then
			if kind == "program" and (type(binding) ~= "string"
				or (M.DEFAULT_GESTURES[binding] == nil and not binding:match("^keyboard__.+$")
					and not binding:match("^script__.+$") and not binding:match("^tap_key__.+$") and not combination)) then
				item.disabled = true
				item.hint = i18n.get("platform_reason.program_runner_unavailable")
			end
			item.parameter = kind
			item.parameterValue = binding and M.get_action_parameter(binding, item.id) or ""
			if SEND_INPUT_KINDS[kind] or kind == "llm_prompt" or kind == "llm_vision" or kind == "llm_language" or kind == "program" then
				prompts[kind] = M.get_action_parameter_prompt(item.id)
				errors[kind] = M.get_action_parameter_error(item.id)
			end
		end
	end
	local ProfileSettings = require("ai.engine.settings.profile_settings")
	return {
		send_vocabulary = send_vocabulary(),
		prompt_choices = ProfileSettings.choices(),
		vision_choices = require("ai.engine.prediction.vision_request").backend_choices(),
		language_choices = require("ai.engine.prediction.translation").choices(),
		default_count = ProfileSettings.get(ConfigKeys.LEAF.NUM_PREDICTIONS),
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
			programExecutableLabel = i18n.get("dialog.action_picker.program_executable"),
			programArgumentsLabel = i18n.get("dialog.action_picker.program_arguments"),
			programAddLabel = i18n.get("dialog.action_picker.program_add_argument"),
			programRemoveLabel = i18n.get("dialog.action_picker.program_remove_argument"),
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
	if type(binding) == "string" and binding:sub(1, 13) == "combination__" then
		local owner = rawget(package.loaded, "platform.remap.tap_hold_manager")
		local catalogue = BindingPublication.current("combination", "platform.remap.tap_hold_manager", owner)
		return BindingIdentity.combination_binding_fits(binding, catalogue), BindingIdentity.RETIRED_COMBINATION
	end
	if type(binding) == "string" and binding:sub(1, 10) == "keyboard__" then
		local catalogue = KeyboardPublication.current(rawget(package.loaded, "modules.shortcuts.keyboard_shortcuts"))
		return BindingIdentity.keyboard_binding_fits(binding, catalogue), BindingIdentity.RETIRED_KEYBOARD
	end
	if type(binding) == "string" and binding:sub(1, 9) == "tap_key__" then
		local taps = rawget(package.loaded, "modules.shortcuts.tap_keys")
		local catalogue = BindingPublication.current("tap", "modules.shortcuts.tap_keys", taps)
		return BindingIdentity.tap_binding_fits(binding, catalogue), BindingIdentity.RETIRED_TAP
	end
	if type(binding) == "string" and binding:sub(1, 8) == "script__" then
		local chords = rawget(package.loaded, "modules.shortcuts.script_chords")
		local catalogue = BindingPublication.current("script", "modules.shortcuts.script_chords", chords)
		return BindingIdentity.script_binding_fits(binding, catalogue), BindingIdentity.RETIRED_SCRIPT
	end
	local catalogue = BindingPublication.current("gesture", "modules.gestures.manager", M)
	return BindingIdentity.gesture_binding_fits(binding, catalogue), BindingIdentity.RETIRED_GESTURE
end

--- Builds a validated detached row for the canonical parameter publisher.
--- No source, native owner or runtime state is modified by this constructor.
--- @param binding string Exact binding identifier.
--- @param action_name string Declared parameter-bearing action.
--- @param value string Validated parameter scalar.
--- @return table|nil update Canonical section/key/value row, or refusal.
function M.action_parameter_update(binding, action_name, value)
	local physical = type(binding) == "string" and binding:match("^keyboard__physical_[a-z_]+_[A-Za-z][A-Za-z0-9]*$")
	if type(binding) ~= "string" or binding == ""
		or (not binding:match("^[a-z0-9_]+$") and not physical)
		or M.action_parameter_binding_fits(binding) == false
		or type(action_name) ~= "string" or type(value) ~= "string"
		or M.get_action_parameter_spec(action_name) == nil
		or M.validate_action_parameter(action_name, value) ~= true then return nil end
	return { section = CONFIG_SECTION_PARAMS, key = parameter_key(binding, action_name), value = value }
end

function M.set_action_parameter(binding, action_name, value)
	if not admit_mutation() then return false end
	if M.action_parameter_binding_fits(binding) == false then return false end
	if not M.validate_action_parameter(action_name, value) then return false end
	local key = parameter_key(binding, action_name)
	local staged = copy_state(_action_params)
	staged[key] = value
	if not M._persist_updates({ { section = CONFIG_SECTION_PARAMS, key = key, value = value } }, action_name == "run_program") then
		Logger.error(LOG, "Gesture action parameter was not persisted — nothing changed.")
		return false
	end
	_action_params = staged
	_program_revision = _program_revision + 1
	return true
end

--- Captures private revision/lease currency across physical input callbacks.
function M.capture_parameter_delivery_guard()
	local revision, epoch, parameters = _program_revision, _parameter_delivery_epoch, _action_params
	return function()
		return _parameter_configuration_owner == nil and _program_revision == revision
			and _parameter_delivery_epoch == epoch and _action_params == parameters
	end
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
	if M.get_action_parameter_spec(action) == "program" then return label end
	return ParameterLabel.for_spec(label, M.get_action_parameter_spec(action), value)
end

--- Returns all gesture actions.
--- @return table slot → action_name
function M.get_all_actions()
	local t = {}
	for k, v in pairs(_actions) do t[k] = v end
	return t
end

--- Retains each physical obligation by identity across a provisional scope.
--- @return function|nil finalize Called with the final commit verdict.
function M.capture_scope_click_retirement()
	if _gesture_click_fence ~= nil or _parameter_configuration_owner ~= nil then return nil end
	local fence = {}
	_gesture_click_fence = fence
	local captured = {}
	for slot, action in pairs(_actions) do
		local button = action == "left_click_toggle" and "1" or action == "right_click_toggle" and "3" or nil
		if button then captured[#captured + 1] = { slot = slot, action = action,
			retire = _click_holds.capture_binding_retirement(button, slot) } end
	end
	return function(committed)
		if _gesture_click_fence ~= fence then return end
		for _, entry in ipairs(captured) do
			if committed and (not _enabled or _actions[entry.slot] ~= entry.action) then
				local ok = pcall(entry.retire)
				if not ok then pcall(Logger.error, LOG, "Could not advance captured gesture click cleanup; its owner retains the debt.") end
			end
		end
		if _gesture_click_fence == fence then _gesture_click_fence = nil end
	end
end

--- Applies a snapshot while its scope retains the captured click obligations.
--- @param candidate table Detached scope runtime snapshot.
--- @return boolean acknowledged
function M.apply_scope_state_provisional(candidate)
	return M.apply_scope_state(candidate, preserve_scope_clicks)
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
function M.apply_scope_state(candidate, preserve_clicks)
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
	if not retire_window_operation() then return false end
	_scope_native = true
	local called, acknowledged = pcall(function()
		if candidate.reading then return M.start_reading() == true and M.is_reading() end
		local stopped
		if preserve_clicks == preserve_scope_clicks then stopped = stop_reading_preserving_clicks()
		else stopped = M.stop_reading() end
		return stopped == true and not M.is_reading()
	end)
	_scope_native = false
	if not called or acknowledged ~= true then return false end
	_enabled = candidate.enabled
	_actions, _action_params = actions, parameters
	_program_revision = _program_revision + 1
	return true
end

--- Restores or clears all gesture-owned preferences and native reader state.
--- @param mode string `recommended` or `clear`.
--- @return boolean committed
--- @return string|nil detail
function M.apply_scope(mode, deferred)
	if _parameter_configuration_owner ~= nil then return false end
	if mode ~= "recommended" and mode ~= "clear" then return false, "invalid gesture scope mode" end
	if not retire_window_operation() then return false, "native window retirement remains pending" end
	if _is_paused() then return false, "gesture configuration is paused" end
	if not _persist or type(_config_path) ~= "string" then return false, "gesture persistence is not initialized" end
	if _scope_owner and _scope_owner.pending() then
		if not _scope_owner.retry_restore() then return false, "gesture runtime rollback remains pending" end
	end
	if _gesture_click_fence ~= nil then return false, "gesture scope remains owned" end
	_scope_sequence = _scope_sequence + 1
	local backup = _config_path .. ".gestures-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. _scope_sequence .. ".bak"
	local owner = require("infra.gesture_scope").new({
		path = _config_path,
		backup_path = backup,
		gestures = M,
	})
	_scope_owner = owner
	local committed, detail = owner.apply(mode)
	if committed and deferred ~= true then owner.release() end
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
	return require("settings.engine.scope.participant").synchronous({
		apply = function(mode) return M.apply_scope(mode, true) end,
		owner = function() return _scope_owner end,
	})
end

--- Resets all gesture actions to defaults.
--- @return boolean True only after every default is durable when persistence is enabled.
function M.reset_defaults()
	local previous = _actions
	local staged = copy_state(previous)
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
	_program_revision = _program_revision + 1
	retire_changed_click_bindings(previous, staged)
	Logger.info(LOG, "Gestures reset to defaults.")
	return true
end

--- Replaces every gesture action by the empty no-op without changing the
--- master enable flag.
--- @return boolean True only after every empty binding is durable when persistence is enabled.
function M.disable_all_actions()
	local previous = _actions
	local staged = copy_state(previous)
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
	_program_revision = _program_revision + 1
	retire_changed_click_bindings(previous, staged)
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

--- The key combination the catalogue emits for an action, when it is a single one.
--- @param action_name string An action id.
--- @return string|nil combo X keysym names joined by "+", or nil.
function M.emit_combo_for(action_name)
	return MODIFIER_ACTION_COMMANDS[action_name] or _EMIT_ROWS[action_name]
end

--- Installs the one observer of acknowledged catalogue key emissions. The
--- daemon owns it; a restarted session replaces its predecessor's.
--- @param observer function|nil fn(action_name, combo, binding), or nil to remove.
function M.set_effect_observer(observer)
	if observer ~= nil and type(observer) ~= "function" then
		error("the action effect observer must be a function or nil", 2)
	end
	_effect_observer = observer
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
	if (_parameter_configuration_owner ~= nil or _gesture_click_fence ~= nil) and M.DEFAULT_GESTURES[binding] ~= nil
		and (action_name == "left_click_toggle" or action_name == "right_click_toggle") then return false end
	if type(action_name) ~= "string" or action_name == "" or action_name == "none" then
		return false
	end
	_execute_action(action_name, nil, binding)
	return true
end

--- The mode of a swipe slot: "x1" fires once per swipe, "incremental" once per
--- step of travel while the fingers move.
--- @param slot string
--- @return string|nil mode nil for a slot with no mode (a tap).
function M.get_mode(slot)
	return _modes[slot] or M.DEFAULT_MODES[slot]
end

--- The step of an incremental slot, in millimetres of travel.
--- @param slot string
--- @return number|nil step
function M.get_sensitivity(slot)
	return _sensitivities[slot] or M.DEFAULT_SENSITIVITIES[slot]
end

--- The live tracker for a touchpad of a given scale, or nil without one.
--- @param units_x number|nil Device units per millimetre along x.
--- @param units_y number|nil Device units per millimetre along y.
--- @return table|nil tracker
local function new_incremental(units_x, units_y)
	if not (units_x and units_y) then return nil end
	return require("modules.gestures.incremental_tracker").new({
		units_x = units_x, units_y = units_y,
		mode_of = M.get_mode, step_of = M.get_sensitivity,
		-- The mode and step are the answering slot's: an axis slot standing in
		-- for an unbound direction slot keeps its own x1 or incremental.
		slot_of = function(slot, fingers, direction, dominant)
			local answer, _, answer_direction = answering_slot(slot, fingers, direction, false, dominant)
			return answer, answer_direction
		end,
		-- Each step runs the slot exactly as a completed swipe would, through
		-- the same pause, click-fence and axis-slot rules.
		fire = function(_, fingers, direction, count)
			local fired = 0
			for _ = 1, count do
				if not M.dispatch_gesture({ fingers = fingers, direction = direction, tap = false }) then break end
				fired = fired + 1
			end
			return fired
		end,
	})
end

--- Persists one mode or step and applies it.
--- @return boolean committed
local function set_slot_setting(store, section, slot, value)
	if not admit_mutation() then return false end
	if not M._persist_updates({ { section = section, key = slot, value = value } }) then
		Logger.error(LOG, "Gesture %s for %s was not persisted — nothing changed.", section, slot)
		return false
	end
	store[slot] = value
	Logger.info(LOG, "Gesture %s.%s → %s.", section, slot, tostring(value))
	return true
end

--- Sets a swipe slot's mode.
--- @param slot string
--- @param mode string "x1" or "incremental".
--- @return boolean committed
function M.set_mode(slot, mode)
	if M.DEFAULT_MODES[slot] == nil or (mode ~= M.MODE_SINGLE and mode ~= M.MODE_INCREMENTAL) then
		Logger.warn(LOG, "Refusing gesture mode '%s' for '%s'.", tostring(mode), tostring(slot))
		return false
	end
	return set_slot_setting(_modes, MODES_SECTION, slot, mode)
end

--- Sets an incremental slot's step.
--- @param slot string
--- @param value number Millimetres, within the shared range.
--- @return boolean committed
function M.set_sensitivity(slot, value)
	local step = require("gestures.engine.sensitivity").coerce(value)
	if M.DEFAULT_SENSITIVITIES[slot] == nil or step == nil then
		Logger.warn(LOG, "Refusing gesture step '%s' for '%s'.", tostring(value), tostring(slot))
		return false
	end
	return set_slot_setting(_sensitivities, SENSITIVITIES_SECTION, slot, step)
end

--- The slot that answers a gesture, and its action.
---
--- A straight horizontal swipe whose direction slot is unbound runs the axis
--- slot of its finger count. The direction slot wins when both are bound, so
--- an explicit left/right choice is never overridden. Diagonals and taps have
--- no axis slot. The decoder already applied the shared direction thresholds;
--- an incremental slot reaches here once per step of travel
--- (modules/gestures/incremental_tracker.lua), each step through this rule,
--- and the tracker takes its mode and step from the same answer, as macOS
--- takes them from resolveSwipeSlot's.
---
--- A diagonal whose own slot is unbound runs the slot of its dominant straight
--- direction (and that one's axis slot), as macOS does; a bound diagonal keeps
--- its own (maintainer decision of 11 November 2026).
--- @param slot string The gesture's own slot.
--- @param dominant string|nil A diagonal's dominant straight direction.
--- @return string slot, string|nil action, string direction The direction that answers.
answering_slot = function(slot, fingers, direction, tap, dominant)
	local action = _actions[slot]
	if (not action or action == "none") and not tap and dominant and direction:find("_", 1, true) then
		local straight = string.format("swipe_%d_%s", math.min(fingers, 5), dominant)
		local answer, answer_action, answer_direction = answering_slot(straight, fingers, dominant, false, nil)
		if answer_action and answer_action ~= "none" then
			Logger.debug(LOG, "%s is unbound: its dominant direction %s answers.", slot, answer)
			return answer, answer_action, answer_direction
		end
	end
	if (not action or action == "none") and not tap and (direction == "left" or direction == "right") then
		local axis_slot = AXIS_SLOT_FOR_FINGERS[math.min(fingers, 5)]
		local axis_action = axis_slot and _actions[axis_slot]
		if axis_action and axis_action ~= "none" then
			Logger.debug(LOG, "%s is unbound: the horizontal axis slot %s answers.", slot, axis_slot)
			return axis_slot, axis_action, direction
		end
	end
	return slot, action, direction
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

	local action
	slot, action = answering_slot(slot, gesture.fingers, gesture.direction, gesture.tap, gesture.dominant)
	if (_parameter_configuration_owner ~= nil or _gesture_click_fence ~= nil) and (action == "left_click_toggle" or action == "right_click_toggle") then return false end
	if not action or action == "none" then
		-- Not a warning. Linux ships no default bindings, so an unbound slot is
		-- the normal state until the user chooses — saying so at INFO would make
		-- every stray touch a log line.
		Logger.debug(LOG, "No action bound to %s.", slot)
		return false
	end

	-- A pause stops every gesture but the script-control ones, which are how the
	-- user resumes; the reader keeps running so those still arrive.
	if _is_paused() and not ScriptActions.runs_while_paused(action) then
		Logger.debug(LOG, "Gesture %s → %s held back: the script is paused.", slot, action)
		return false
	end

	-- An AI action is unarmed while the AI is off, as for the keys.
	if AiActions.blocked(action) then
		Logger.debug(LOG, "Gesture %s → %s held back: the AI is off.", slot, action)
		return false
	end

	Logger.info(LOG, "GESTURE FIRE: slot=%s action=%s", slot, action)
	if (_parameter_configuration_owner ~= nil or _gesture_click_fence ~= nil) and (action == "left_click_toggle" or action == "right_click_toggle") then return false end
	_execute_action(action, nil, slot)
	return true
end

--- Names, once per reading start, the slots this touchpad can never fire and
--- the bound slots the desktop also acts on. The menu greys the first kind, but
--- a binding written by hand or carried over from another machine is only seen
--- here: without this line a bound swipe_4_up on a three-finger pad is silent.
--- @param touchpad table The selected touchpad.
local function report_slots(touchpad)
	local slots, bound = {}, {}
	for slot in pairs(M.DEFAULT_GESTURES) do
		slots[#slots + 1] = slot
		local action = M.get_action(slot)
		if action ~= nil and action ~= "none" then bound[slot] = true end
	end
	local report = require("modules.gestures.slot_report").report(slots, bound, touchpad.max_fingers)
	if #report.unreachable > 0 then
		Logger.info(LOG, "This touchpad counts up to %d finger(s): %d of %d gesture slot(s) can never fire: %s.",
			touchpad.max_fingers, #report.unreachable, #slots, table.concat(report.unreachable, ", "))
	end
	for _, slot in ipairs(report.bound_unreachable) do
		Logger.warn(LOG, "Gesture %s is bound, but this touchpad cannot count that many fingers: it will never fire.", slot)
	end
	if #report.bound_two_finger > 0 then
		Logger.warn(LOG, "Two-finger gesture(s) bound: %s. The desktop reads the same touches as scrolling or a "
			.. "secondary click, so it acts on them too.", table.concat(report.bound_two_finger, ", "))
	end
end

--- Starts reading the touchpad.
---
--- Reads the device's evdev node directly, WITHOUT a grab, and decodes the
--- multitouch protocol in process. The docstring here used to describe scraping
--- `libinput debug-events`; that route is rejected (docs/memory/rejected_proposals.md) for
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
	local ok_reader, Reader = pcall(require, "platform.input.evdev_reader")
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

	local units_x, units_y = Finder.read_resolution(touchpad.path)
	-- The third-contact rule measures millimetres: the pad's resolution, or
	-- libinput's assumed size for a pad that reports none (tap_detector).
	local mm_x, mm_y = units_x, units_y
	if not (mm_x and mm_y) then
		mm_x, mm_y = require("modules.gestures.tap_detector").units_per_mm(Finder.read_axes(touchpad.path))
	end
	if not (mm_x and mm_y) then
		Logger.warn(LOG, "%s reports no MT axes: a resting thumb beside a pair cannot be told from a third finger.",
			touchpad.path)
	end
	_decoder = Decoder.new({ units_per_mm = (mm_x and mm_y) and { x = mm_x, y = mm_y } or nil })
	_touchpad = touchpad
	_reading = true
	_incremental = new_incremental(units_x, units_y)
	if _incremental then
		Logger.info(LOG, "%s: %d x %d units per mm; incremental swipes count millimetres.", touchpad.path, units_x, units_y)
	else
		-- No scale, no millimetres: an incremental slot cannot measure its step.
		Logger.warn(LOG, "%s reports no resolution: incremental swipes fire once, like x1 ones.", touchpad.path)
	end
	Logger.success(LOG, "Reading %s (%s), up to %d finger(s)%s.",
		touchpad.path, touchpad.name, touchpad.max_fingers,
		touchpad.semi_mt and ", semi-MT" or "")
	report_slots(touchpad)
	return true
end

--- Drains whatever the touchpad has produced since the last call.
---
--- Called from the daemon's pump, like the keyboard's. Returns the number of
--- events consumed so a caller can tell a quiet tick from a stalled reader.
--- @return integer
function M.pump()
	_click_holds.pump()
	if _is_paused() then M.release_clicks() end
	if not _reading or not _decoder or _reader_stop_error then return 0 end

	local ok_reader, Reader = pcall(require, "platform.input.evdev_reader")
	if not ok_reader then return 0 end

	local drained, status = Reader.drain(function(event)
		local gesture = _decoder:feed(event)
		if _incremental then
			-- A swipe that already stepped while the fingers moved is done.
			if gesture then
				if not _incremental:finish() then M.dispatch_gesture(gesture) end
				return
			end
			if event.type == 0 and event.code == 0 then -- EV_SYN / SYN_REPORT
				local live = _decoder:live()
				-- A touch that ended without a completed swipe ends the tracking too.
				if live then _incremental:update(live) elseif not _decoder:touching() then _incremental:finish() end
			end
			return
		end
		if gesture then M.dispatch_gesture(gesture) end
	end, Reader.TOUCHPAD)
	if status == "fatal" or status == "closed" then
		Logger.error(LOG, "Touchpad drain %s — stopping gesture reading; re-enable gestures to retry.",
			tostring(status))
		M.stop_reading()
	end
	return drained or 0
end

--- Retires synthetic buttons even when no touchpad reader was opened.
--- @return boolean True only after every native mouseup was acknowledged.
function M.release_clicks()
	return _click_holds.release_all()
end

--- Releases the held buttons at a physical key press, as Windows' click hold
--- does (click.ahk GestureOnKeyDown); a press with nothing held costs nothing.
--- @return boolean True when nothing is held or every mouseup was acknowledged.
function M.release_clicks_on_activity()
	if not _click_holds.holding() then return true end
	return M.release_clicks()
end

--- Stops reading the touchpad.
--- @return boolean True only when the reader acknowledges closure.
local function stop_reading(preserve_clicks)
	if not _scope_native and not admit_mutation() then return false end
	local clicks_retired = preserve_clicks == true or M.release_clicks()
	if _reading then
		local ok_reader, Reader = pcall(require, "platform.input.evdev_reader")
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
	_incremental = nil
	_touchpad = nil
	Logger.info(LOG, "Touchpad reader stopped.")
	return clicks_retired
end

stop_reading_preserving_clicks = function() return stop_reading(true) end
function M.stop_reading() return stop_reading(false) end

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
--- @param units_x number|nil Device units per millimetre along x, for incremental slots.
--- @param units_y number|nil Device units per millimetre along y.
function M._test_begin_reading(decoder, units_x, units_y)
	_decoder = decoder
	_reading = true
	_incremental = new_incremental(units_x, units_y)
end

--- Returns true if the touch reader is active.
--- @return boolean
function M.is_reading()
	return _reading
end

-- ======= 6/ Init =========================
-- =========================================
-- =========================================

function M._persist_updates(updates, private, owner, expected_source)
	-- Configuration cannot supersede a still-owned native window activation.
	if not retire_window_operation() then return false end
	if not admit_mutation(owner) then return false end
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

	local call_ok, committed, err = pcall(TomlWriter.batch_write, _config_path, updates, nil, expected_source)
	if not call_ok or committed ~= true then
		if private == true then
			Logger.error(LOG, "Could not persist private user program configuration.")
		else
			Logger.error(LOG, "Could not persist gesture configuration: %s",
			tostring(call_ok and err or committed))
		end
		return false, not call_ok and "publication_unknown" or nil
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
			elseif (slot == "modes" or slot == "sensitivities") and section_name == CONFIG_SECTION
				and type(action) == "table" then
				-- [gestures.modes] and [gestures.sensitivities], read by load_slot_settings.
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

--- Reads [gestures.modes] and [gestures.sensitivities]; an invalid entry is
--- outdated configuration, reported and left out. With `mark`, the entries the
--- loader takes are marked for the unused-key cleanup instead of applied: the
--- cleanup offered every saved mode and step for deletion before.
--- @param config table Decoded config.toml.
--- @param mark function|nil mark(...segments) from config_unused_keys.
local function load_slot_settings(config, mark)
	local section = type(config.gestures) == "table" and config.gestures or {}
	local Sensitivity = require("gestures.engine.sensitivity")
	for slot, mode in pairs(type(section.modes) == "table" and section.modes or {}) do
		-- A case variant reads in its manifest spelling, as Windows' loader admits it.
		if type(slot) == "string" then
			mode = ConfigOutdated.canonical_enum_value(Manifest.find_entry_by_path(MODES_SECTION .. "." .. slot), mode)
		end
		if M.DEFAULT_MODES[slot] ~= nil and (mode == M.MODE_SINGLE or mode == M.MODE_INCREMENTAL) then
			if mark then mark("gestures", "modes", slot) else _modes[slot] = mode end
		else
			ConfigOutdated.report({ "gestures", "modes", tostring(slot) }, "not a swipe slot mode (x1 or incremental)", Logger)
		end
	end
	for slot, value in pairs(type(section.sensitivities) == "table" and section.sensitivities or {}) do
		local step = Sensitivity.coerce(value)
		if M.DEFAULT_SENSITIVITIES[slot] ~= nil and step ~= nil then
			if mark then mark("gestures", "sensitivities", slot) else _sensitivities[slot] = step end
		else
			ConfigOutdated.report({ "gestures", "sensitivities", tostring(slot) }, "not a swipe slot step in range", Logger)
		end
	end
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
	load_slot_settings(config, mark)
end

local function load_user_config(path)
	if type(path) ~= "string" or path == "" then return nil end
	if type(TomlWriter) ~= "table" or type(TomlWriter.read_classified) ~= "function" then
		Logger.error(LOG, "Gesture configuration cannot be read: classified file reader unavailable.")
		return nil
	end
	local content, status, detail = TomlWriter.read_classified(path)
	if status ~= "ok" then
		if status ~= "absent" then Logger.error(LOG, "Gesture configuration is unreadable: %s.", tostring(detail or status)) end
		return nil
	end
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
	load_slot_settings(config)
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
	if _program_owner and _program_owner.stop() ~= true then return false end
	if _window_owner and _window_owner.stop() ~= true then return false end
	_program_owner = ProgramOwner.new(capture_program)
	_window_owner = WindowSwitch.new(capture_window)
	_program_revision = _program_revision + 1
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
	_config_path = opts.config_path or require("settings.engine.paths").config("config.toml")
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
	if type(owner) ~= "table" or not admit_mutation(owner) or not retire_window_operation() or not admit_mutation(owner) then return false end
	_parameter_configuration_owner = owner
	_parameter_delivery_epoch = _parameter_delivery_epoch + 1
	return true
end

--- Releases exact parameter ownership after acknowledged completion.
--- @param owner table Exact transaction token.
--- @return boolean released
function M.release_parameter_configuration(owner)
	if type(owner) ~= "table" or _parameter_configuration_owner ~= owner then return false end
	_parameter_configuration_owner = nil
	_parameter_delivery_epoch = _parameter_delivery_epoch + 1
	return true
end

--- Captures parameters independently from evdev acquisition and close state.
--- @param owner table Exact transaction token.
--- @return table|nil parameters
function M.parameter_configuration_snapshot(owner)
	if _parameter_configuration_owner ~= owner then return nil end
	return M.get_all_action_parameters()
end

--- Captures gesture assignments under the same exact parameter transaction.
--- @param owner table Exact transaction token.
--- @return table|nil actions Detached assignments.
function M.parameter_configuration_actions_snapshot(owner)
	if type(owner) ~= "table" or _parameter_configuration_owner ~= owner then return nil end
	return M.get_all_actions()
end

-- A parameter transaction may apply and roll back several candidate maps.
-- Its opaque receipt delays irreversible click retirement until publication and
-- lease release have both succeeded.
local _click_configuration_receipts = setmetatable({}, { __mode = "k" })
function M.capture_click_configuration(owner, slot)
	if type(owner) ~= "table" or _parameter_configuration_owner ~= owner or type(slot) ~= "string" then return nil end
	local old = _actions[slot]
	local button = old == "left_click_toggle" and "1" or old == "right_click_toggle" and "3" or nil
	local receipt = {}
	_click_configuration_receipts[receipt] = {
		owner = owner, slot = slot, old = old,
		retire = button and _click_holds.capture_binding_retirement(button, slot) or function() end,
	}
	return receipt
end
function M.seal_click_configuration(owner, receipt)
	local record = _click_configuration_receipts[receipt]
	if not record or record.owner ~= owner or _parameter_configuration_owner ~= owner or record.sealed then return false end
	record.changed = _actions[record.slot] ~= record.old
	record.sealed = true
	return true
end
function M.commit_click_configuration(owner, receipt)
	local record = _click_configuration_receipts[receipt]
	if not record or record.owner ~= owner or not record.sealed then return end
	_click_configuration_receipts[receipt] = nil
	if record.changed then
		local ok = pcall(record.retire)
		if not ok then pcall(Logger.error, LOG, "Could not advance captured gesture click cleanup; its owner retains the debt.") end
	end
end

--- Applies only assignments without changing input-reader ownership or files.
--- @param owner table Exact transaction token.
--- @param candidate table Detached assignments or exact prior snapshot.
--- @return boolean acknowledged
function M.apply_parameter_configuration_actions(owner, candidate)
	if type(owner) ~= "table" or _parameter_configuration_owner ~= owner or type(candidate) ~= "table" then return false end
	local actions = {}
	for slot in pairs(M.DEFAULT_GESTURES) do
		local action = candidate[slot]
		if type(action) ~= "string" or not M.is_assignable(action) then return false end
		actions[slot] = action
	end
	for slot in pairs(candidate) do if M.DEFAULT_GESTURES[slot] == nil then return false end end
	if not retire_window_operation() then return false end
	_actions = actions
	_program_revision = _program_revision + 1
	return true
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
	if not retire_window_operation() then return false end
	_action_params = copy
	_program_revision = _program_revision + 1
	return true
end

--- Compares the actual loader's canonical/legacy frame with private runtime intent.
--- The exact lease (or neutral nil for a detached editor capture) must survive
--- every external validator/domain callback. Unowned parameters stay untouched.
function M.parameter_configuration_matches(owner, document, recognizes)
	if _parameter_configuration_owner ~= owner or type(document) ~= "table" or type(recognizes) ~= "function" then return false end
	local revision, epoch, runtime = _program_revision, _parameter_delivery_epoch, _action_params
	local expected = {}
	walk_user_config(document, { param = function(_, key, value)
		local binding = M.split_action_parameter_key(key)
		if recognizes(binding) then expected[key] = value end
	end })
	for key, value in pairs(runtime) do
		local binding = M.split_action_parameter_key(key)
		if binding and recognizes(binding) and expected[key] ~= value then return false end
	end
	for key, value in pairs(expected) do if runtime[key] ~= value then return false end end
	return _parameter_configuration_owner == owner and _action_params == runtime
		and _program_revision == revision and _parameter_delivery_epoch == epoch
end

--- Captures source agreement without acquiring or retiring native work.
function M.capture_parameter_source_guard(document, recognizes)
	local revision, epoch, runtime = _program_revision, _parameter_delivery_epoch, _action_params
	local function current()
		return _parameter_configuration_owner == nil and _action_params == runtime
			and _program_revision == revision and _parameter_delivery_epoch == epoch
	end
	if not current() or M.parameter_configuration_matches(nil, document, recognizes) ~= true or not current() then return nil end
	return current
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

BindingPublication.register("gesture", "modules.gestures.manager", M, M.published_binding_catalogue)

return M
