--- ui/gesture_conflicts.lua

--- ==============================================================================
--- MODULE: Desktop Gesture Status
--- DESCRIPTION:
--- Reports the actual evdev reader and potential compositor overlap. Desktop
--- gestures cannot be queried portably, so an unknown policy is never called clean.
--- Dialogs release the keyboard grab and settings open only on an explicit click.
--- ==============================================================================

local M = {}
local WindowTitles = require("window_titles")
local I18n = require("infra.i18n")
local Storage = require("adapters.storage")
local Shell = require("adapters.shell_runner")
local Logger = require("logger.shim")
local LOG = "gesture_conflicts"
local boot_notified = false

--- Groups assignments without guessing the desktop's native gesture policy.
--- @param gestures table Live gesture manager.
--- @return table groups Sorted potential conflicts.
function M.groups(gestures)
	local groups = {}
	if not gestures.is_enabled() then return groups end
	local seen = {}
	local slots = {}
	for slot in pairs(gestures.DEFAULT_GESTURES) do slots[#slots + 1] = slot end
	table.sort(slots)
	for _, slot in ipairs(slots) do
		local action = gestures.get_action(slot)
		local group = slot:match("^(%a+_%d+)")
		if group and type(action) == "string" and action ~= "none" and action:match("%S") and not seen[group] then
			seen[group] = true
			groups[#groups + 1] = { key = group, slot = slot }
		end
	end
	table.sort(groups, function(a, b) return a.key < b.key end)
	return groups
end

--- Selects the current desktop's touchpad panel, without subprocess probing.
--- @param desktop string Desktop environment identifier.
--- @return string|nil command
function M.settings_command(desktop)
	desktop = tostring(desktop):lower()
	if desktop:find("gnome", 1, true) or desktop:find("unity", 1, true) then return "gnome-control-center mouse" end
	if desktop:find("kde", 1, true) then return "systemsettings kcm_touchpad" end
	if desktop:find("xfce", 1, true) then return "xfce4-mouse-settings" end
	if desktop:find("cinnamon", 1, true) then return "cinnamon-settings mouse" end
	if desktop:find("mate", 1, true) then return "mate-mouse-properties" end
	return nil
end

--- Opens a supported desktop panel; never guesses an unrelated settings app.
--- @return boolean started
function M.open_settings()
	local command = M.settings_command(os.getenv("XDG_CURRENT_DESKTOP") or os.getenv("DESKTOP_SESSION"))
	if not command then
		Logger.warn(LOG, "The current desktop exposes no supported touchpad settings command.")
		return false
	end
	if not Shell.has_command(command:match("^%S+")) then
		Logger.error(LOG, "The desktop touchpad settings executable is unavailable.")
		return false
	end
	local started = Shell.run(command .. " >/dev/null 2>&1 &")
	if not started then Logger.error(LOG, "The touchpad settings process could not start.") end
	return started
end

--- Defers a warning and remembers only an explicit dismissal.
--- @param group table { key, slot }.
--- @return boolean queued
function M.show(group)
	local key = "gesture_conflict_dismissed." .. group.key
	if Storage.get(key, false) == true then return true end
	return require("adapters.event_loop").defer(function()
		if Storage.get(key, false) == true then return end
		local title = WindowTitles.compose(I18n.get("menu.gestures.conflict_title"))
		local message = I18n.get("gesture.slots." .. group.slot) .. "\n" .. I18n.get("gestures.system.warning")
		local settings = I18n.get("menu.gestures.open_settings")
		local dismiss = I18n.get("gestures.system.dismiss")
		local command = "zenity --list --hide-header --no-markup --column=" .. Shell.quote(I18n.get("dialog.action_picker.label"))
			.. " --title=" .. Shell.quote(title)
			.. " --text=" .. Shell.quote(message)
			.. " " .. Shell.quote(settings) .. " " .. Shell.quote(dismiss)
		local accepted, selected = require("ui.modal").run(function() return Shell.exec_checked(command) end)
		if not accepted then return end
		selected = selected:gsub("[\r\n]+$", "")
		if selected == settings then M.open_settings()
		elseif selected == dismiss then
			if Storage.set(key, true) ~= true then
				Logger.error(LOG, "Gesture conflict dismissal could not be saved.")
			end
		end
	end, 0)
end

--- Announces active overlap once after the daemon's event loop starts.
--- @param gestures table Live gesture manager.
function M.notify_boot(gestures)
	if boot_notified then return end
	boot_notified = true
	for _, group in ipairs(M.groups(gestures)) do M.show(group) end
end

--- Returns renderer data without probing the desktop or touching the keyboard.
--- @param gestures table Live gesture manager.
--- @return table rows
function M.rows(gestures)
	local children = { {
		label = I18n.get(gestures.is_reading() and "menu.gestures.reading_on" or "menu.gestures.reading_off"),
		disabled = true,
	} }
	for _, group in ipairs(M.groups(gestures)) do
		children[#children + 1] = { label = I18n.get("gesture.slots." .. group.slot)
			.. " — " .. I18n.get("gestures.system.unknown"), action = M.open_settings }
	end
	local supported = M.settings_command(os.getenv("XDG_CURRENT_DESKTOP") or os.getenv("DESKTOP_SESSION")) ~= nil
	if not supported then
		children[#children + 1] = { label = I18n.get("gestures.system.unknown"), disabled = true }
	end
	return { { label = I18n.get("gestures.system.unknown"), items = children } }
end

return M
