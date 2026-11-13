--- adapters/tap_to_click_setting.lua

--- ==============================================================================
--- MODULE: Desktop Tap-To-Click Setting (Linux)
--- DESCRIPTION:
--- Reads whether the desktop has tap-to-click on for one touchpad, and which
--- button map its taps use. libinput taps only when the compositor (or the X
--- server's libinput driver) asks it to, so a touch is a click only under
--- that setting; the metrics count it as one only when this module says so.
---
--- WHY ONE READER PER DESKTOP:
--- The setting lives with whoever configures libinput, and each one answers
--- another process differently:
---   - X11 (any desktop, the libinput Xorg driver): the device's own
---     `libinput Tapping Enabled` and `libinput Tapping Button Mapping Enabled`
---     properties, through xinput, matched by event node. This is what the X
---     server applied, so it holds on GNOME, KDE and every X11 desktop.
---   - KDE Plasma on Wayland: KWin's D-Bus object for the event node
---     (org.kde.KWin.InputDevice: tapToClick, lmrTapButtonMap, enabled),
---     again what KWin applied rather than what kcminputrc asks for.
---   - sway: `swaymsg -t get_inputs`, whose libinput block per input names
---     tap, tap_button_map and send_events.
---   - Hyprland: `hyprctl getoption input:touchpad:tap-to-click` and
---     tap_button_map. A per-device `device { }` override is not reported by
---     hyprctl; the global option is what applies to a pad without one.
---   - GNOME on Wayland: gsettings org.gnome.desktop.peripherals.touchpad
---     (tap-to-click, tap-button-map, send-events), which mutter applies.
---   - Anything else: unknown, said so with a reason. No setting is assumed.
---
--- FEATURES & RATIONALE:
--- 1. Every tool call is bounded by `timeout`: the daemon waits for it.
--- 2. An answer that cannot be parsed is unknown, never "off".
--- ==============================================================================

local M = {}

local Shell = require("core.process.adapters.shell_runner")
local DisplayServer = require("infra.display_server")
local TapDetector = require("modules.gestures.tap_detector")
local json = require("core.text.engine.json")

-- Seconds each tool call may take (see FEATURES 1).
local TOOL_TIMEOUT_S = 1

-- The reason every unknown answer shows in the Metrics menu.
M.UNKNOWN_REASON = "platform_reason.tap_to_click_setting_unreadable"

--- A known answer.
--- @param enabled boolean
--- @param map string TapDetector.MAP_LRM or MAP_LMR.
--- @param source string Which interface answered, for the log.
--- @return table setting
local function known(enabled, map, source)
	return { known = true, enabled = enabled, map = map, source = source }
end

--- An unknown answer.
--- @param detail string Why, for the log.
--- @return table setting
local function unknown(detail)
	return { known = false, reason = M.UNKNOWN_REASON, detail = detail }
end

--- Runs one bounded query.
--- @param cmd string
--- @return string|nil output, string|nil reason
local function query(cmd)
	local ok, output, err = Shell.exec_checked("timeout " .. TOOL_TIMEOUT_S .. " " .. cmd .. " 2>/dev/null")
	if not ok then return nil, cmd .. " failed: " .. tostring(err) end
	return output, nil
end

--- Reads an environment variable, treating empty as absent.
--- @param name string
--- @return string|nil
local function env(name)
	local value = os.getenv(name)
	if type(value) ~= "string" or value == "" then return nil end
	return value
end




-- =========================================
-- =========================================
-- ======= 1/ Parsers ======================
-- =========================================
-- =========================================

--- Parses the `xinput list-props` blocks of every device and answers for the
--- one whose `Device Node` is the given event node.
--- @param text string Concatenated `xinput list-props` outputs.
--- @param path string The event node, e.g. "/dev/input/event7".
--- @return table setting
function M.parse_xinput(text, path)
	if type(text) ~= "string" then return unknown("xinput gave no answer") end
	local block = nil
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		if line:match("^Device '") then
			if block and block.node == path then break end
			block = {}
		elseif block then
			local node = line:match("^%s*Device Node %(%d+%):%s*\"([^\"]*)\"")
			if node then block.node = node end
			local tapping = line:match("^%s*libinput Tapping Enabled %(%d+%):%s*(%d)")
			if tapping then block.tapping = tapping end
			local first, second = line:match("^%s*libinput Tapping Button Mapping Enabled %(%d+%):%s*(%d),%s*(%d)")
			if first then block.lrm, block.lmr = first, second end
			local enabled = line:match("^%s*Device Enabled %(%d+%):%s*(%d)")
			if enabled then block.enabled = enabled end
		end
	end
	if not block or block.node ~= path then return unknown("xinput lists no device on " .. path) end
	if not block.tapping then
		-- A synaptics or evdev Xorg driver: libinput does not tap that pad.
		return unknown("the X driver of " .. path .. " is not libinput")
	end
	if block.enabled == "0" then return known(false, TapDetector.MAP_LRM, "xinput") end
	local map = block.lmr == "1" and TapDetector.MAP_LMR or TapDetector.MAP_LRM
	return known(block.tapping == "1", map, "xinput")
end

--- Parses KWin's three InputDevice properties.
--- @param tap string|nil tapToClick
--- @param lmr string|nil lmrTapButtonMap
--- @param enabled string|nil enabled
--- @return table setting
function M.parse_kwin(tap, lmr, enabled)
	local function boolean(text)
		local word = type(text) == "string" and text:match("^%s*(%a+)%s*$")
		if word == "true" then return true elseif word == "false" then return false end
		return nil
	end
	local tapping, left_middle, on = boolean(tap), boolean(lmr), boolean(enabled)
	if tapping == nil or left_middle == nil or on == nil then return unknown("KWin did not report the pad's tap settings") end
	return known(tapping and on, left_middle and TapDetector.MAP_LMR or TapDetector.MAP_LRM, "kwin")
end

--- Parses `swaymsg -t get_inputs -r` for the touchpad of a given name.
--- @param text string
--- @param name string The evdev device name.
--- @return table setting
function M.parse_sway(text, name)
	local ok, inputs = pcall(json.decode, text)
	if not ok or type(inputs) ~= "table" then return unknown("swaymsg -t get_inputs is not JSON") end
	for _, input in ipairs(inputs) do
		if type(input) == "table" and input.type == "touchpad" and input.name == name and type(input.libinput) == "table" then
			local config = input.libinput
			if config.tap ~= "enabled" and config.tap ~= "disabled" then return unknown("sway reports no tap state") end
			local map = config.tap_button_map == TapDetector.MAP_LMR and TapDetector.MAP_LMR or TapDetector.MAP_LRM
			local sending = config.send_events == nil or config.send_events == "enabled"
			return known(config.tap == "enabled" and sending, map, "sway")
		end
	end
	return unknown("sway lists no touchpad named " .. tostring(name))
end

--- Parses Hyprland's two getoption answers.
--- @param tap_text string `hyprctl -j getoption input:touchpad:tap-to-click`
--- @param map_text string `hyprctl -j getoption input:touchpad:tap_button_map`
--- @return table setting
function M.parse_hyprland(tap_text, map_text)
	local ok_tap, tap = pcall(json.decode, tap_text)
	local ok_map, map = pcall(json.decode, map_text)
	if not ok_tap or type(tap) ~= "table" or type(tap.int) ~= "number" then
		return unknown("hyprctl did not report input:touchpad:tap-to-click")
	end
	if not ok_map or type(map) ~= "table" or type(map.str) ~= "string" then
		return unknown("hyprctl did not report input:touchpad:tap_button_map")
	end
	-- An empty map is Hyprland's default: libinput's own, left-right-middle.
	if map.str ~= "" and map.str ~= TapDetector.MAP_LRM and map.str ~= TapDetector.MAP_LMR then
		return unknown("unknown Hyprland tap_button_map " .. map.str)
	end
	return known(tap.int ~= 0, map.str == TapDetector.MAP_LMR and TapDetector.MAP_LMR or TapDetector.MAP_LRM, "hyprland")
end

--- Parses GNOME's three gsettings answers.
--- @param tap string|nil `tap-to-click`: "true" or "false".
--- @param map string|nil `tap-button-map`: "'default'", "'lrm'" or "'lmr'"; nil on a GNOME without the key.
--- @param send string|nil `send-events`: "'enabled'", "'disabled'" or "'disabled-on-external-mouse'".
--- @return table setting
function M.parse_gnome(tap, map, send)
	local tapping = type(tap) == "string" and tap:match("^%s*(%a+)%s*$")
	if tapping ~= "true" and tapping ~= "false" then return unknown("gsettings did not report tap-to-click") end
	local events = type(send) == "string" and send:match("^%s*'([%a%-]+)'%s*$")
	if events == "disabled-on-external-mouse" then
		-- Whether mutter counts a plugged mouse as external is its own decision.
		return unknown("GNOME disables the touchpad when an external mouse is plugged in")
	end
	if events ~= "enabled" and events ~= "disabled" then return unknown("gsettings did not report send-events") end
	local button_map = TapDetector.MAP_LRM
	if map ~= nil then
		local value = map:match("^%s*'(%a+)'%s*$")
		if value == TapDetector.MAP_LMR then button_map = TapDetector.MAP_LMR
		elseif value ~= "default" and value ~= TapDetector.MAP_LRM then
			return unknown("gsettings reported an unknown tap-button-map")
		end
	end
	return known(tapping == "true" and events == "enabled", button_map, "gnome")
end




-- =========================================
-- =========================================
-- ======= 2/ Reading the desktop ==========
-- =========================================
-- =========================================

local GNOME_SCHEMA = "org.gnome.desktop.peripherals.touchpad"

--- Reads the setting for one touchpad.
--- @param device table { path = "/dev/input/eventN", name = evdev device name }
--- @return table setting { known = true, enabled, map, source } or { known = false, reason, detail }
function M.read(device)
	assert(type(device) == "table" and type(device.path) == "string", "the tap setting is read for one device node")
	local kind = DisplayServer.kind()
	if kind == DisplayServer.X11 then
		if not Shell.has_command("xinput", true) then return unknown("xinput is not installed") end
		local text, err = query("sh -c " .. Shell.quote(
			"for id in $(xinput list --id-only); do xinput list-props \"$id\"; done"))
		if not text then return unknown(err) end
		return M.parse_xinput(text, device.path)
	end
	if kind ~= DisplayServer.WAYLAND then return unknown("no display server is known") end
	if env("HYPRLAND_INSTANCE_SIGNATURE") or DisplayServer.desktop_is("hyprland") then
		if not Shell.has_command("hyprctl", true) then return unknown("hyprctl is not installed") end
		local tap, err = query("hyprctl -j getoption input:touchpad:tap-to-click")
		if not tap then return unknown(err) end
		local map, map_err = query("hyprctl -j getoption input:touchpad:tap_button_map")
		if not map then return unknown(map_err) end
		return M.parse_hyprland(tap, map)
	end
	if env("SWAYSOCK") or DisplayServer.desktop_is("sway") then
		if not Shell.has_command("swaymsg", true) then return unknown("swaymsg is not installed") end
		local text, err = query("swaymsg -t get_inputs -r")
		if not text then return unknown(err) end
		return M.parse_sway(text, device.name)
	end
	if DisplayServer.desktop_is("kde") then
		local node = device.path:match("/(event%d+)$")
		if not node then return unknown("not an event node: " .. device.path) end
		for _, binary in ipairs(require("modules.gestures.workspace_switcher").QDBUS_BINARIES) do
			if Shell.has_command(binary, true) then
				local base = binary .. " org.kde.KWin /org/kde/KWin/InputDevice/" .. node .. " org.kde.KWin.InputDevice."
				return M.parse_kwin(query(base .. "tapToClick"), query(base .. "lmrTapButtonMap"), query(base .. "enabled"))
			end
		end
		return unknown("no qdbus binary is installed")
	end
	if DisplayServer.desktop_is("gnome") then
		if not Shell.has_command("gsettings", true) then return unknown("gsettings is not installed") end
		local keys, err = query("gsettings list-keys " .. GNOME_SCHEMA)
		if not keys then return unknown(err) end
		local tap = query("gsettings get " .. GNOME_SCHEMA .. " tap-to-click")
		-- A GNOME older than 40 has no tap-button-map key and leaves libinput's map.
		local map = nil
		if (("\n" .. keys .. "\n"):find("\ntap%-button%-map%s*\n")) then
			map = query("gsettings get " .. GNOME_SCHEMA .. " tap-button-map")
			if not map then return unknown("gsettings did not report tap-button-map") end
		end
		local send = query("gsettings get " .. GNOME_SCHEMA .. " send-events")
		return M.parse_gnome(tap, map, send)
	end
	return unknown("this Wayland compositor exposes no tap setting")
end

return M
