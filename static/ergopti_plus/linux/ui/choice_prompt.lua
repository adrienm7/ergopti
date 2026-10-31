--- ui/choice_prompt.lua

--- ==============================================================================
--- MODULE: Choice Prompt Dialog (Linux)
--- DESCRIPTION:
--- Asks the user to pick one value among labelled choices in a native list
--- (zenity --list, else kdialog --menu), so a closed set is chosen instead of
--- typed from a list printed in the prompt.
---
--- FEATURES & RATIONALE:
--- 1. One row per choice, the label shown and the value returned: a long
---    catalogue (about forty AI providers) scrolls in the list instead of
---    filling the dialog with one line per value to copy by hand.
--- 2. The current value, when it is one of the choices, is listed first, so
---    keeping it is one Enter.
--- 3. Through ui/modal.lua, like every dialog the tray opens: the grabbed
---    keyboard is handed to the desktop while the list is open.
--- 4. Cancel is not a choice: a dismissed or failed dialog returns nil, and a
---    desktop with neither zenity nor kdialog is logged as an error.
--- ==============================================================================

local M = {}

local Errors = require("adapter_errors")
local Logger = require("logger.shim")
local Modal = require("ui.modal")
local Shell = require("adapters.shell_runner")
local WindowTitles = require("window_titles")

local LOG = "ui.choice_prompt"

--- The choices in display order, the current one first.
--- @param choices table { { value, label }, ... }
--- @param current string|nil
--- @return table ordered
local function ordered(choices, current)
	local first, rest = {}, {}
	for _, choice in ipairs(choices) do
		if choice.value == current then first[#first + 1] = choice else rest[#rest + 1] = choice end
	end
	for _, choice in ipairs(rest) do first[#first + 1] = choice end
	return first
end

--- The native command that lists the choices, or nil when no dialog tool is installed.
--- @param title string Window title.
--- @param text string The question, shown as plain text.
--- @param choices table Ordered choices.
--- @return string|nil command
function M.command(title, text, choices)
	local rows = {}
	for _, choice in ipairs(choices) do
		rows[#rows + 1] = Shell.quote(choice.value) .. " " .. Shell.quote(choice.label)
	end
	if Shell.has_command("zenity") then
		-- The first column holds the value: hidden, and the one printed.
		return "zenity --list --no-markup --hide-header --title=" .. Shell.quote(WindowTitles.compose(title))
			.. " --text=" .. Shell.quote(text) .. " --column='' --column='' --hide-column=1 --print-column=1 "
			.. table.concat(rows, " ") .. " 2>/dev/null"
	end
	if Shell.has_command("kdialog") then
		return "kdialog --title " .. Shell.quote(WindowTitles.compose(title)) .. " --menu " .. Shell.quote(text) .. " "
			.. table.concat(rows, " ") .. " 2>/dev/null"
	end
	return nil
end

--- Asks the user to pick one of the choices.
--- @param title string Window title.
--- @param text string The question (plain text, never markup).
--- @param choices table { { value = string, label = string }, ... }, at least one.
--- @param current string|nil The value in effect, listed first.
--- @return string|nil value The chosen value, nil when the dialog was dismissed.
function M.pick(title, text, choices, current)
	assert(type(choices) == "table" and #choices > 0, "a choice prompt needs at least one choice")
	local list = ordered(choices, current)
	local command = M.command(title, text, list)
	if not command then
		Logger.error(LOG, "Neither zenity nor kdialog is installed: '%s' cannot be chosen.", tostring(title))
		return nil
	end
	local ok, answer, message, reason, status = Modal.run(function() return Shell.exec_checked(command) end)
	if ok ~= true then
		if not (reason == Errors.COMMAND_EXITED_NONZERO and status == 1) then
			Logger.error(LOG, "The choice for '%s' could not be asked: %s.", tostring(title), tostring(message))
		end
		return nil
	end
	local selected = tostring(answer):gsub("[\r\n]+$", "")
	for _, choice in ipairs(list) do
		if choice.value == selected then return selected end
	end
	Logger.error(LOG, "The dialog for '%s' answered a value it was not offered.", tostring(title))
	return nil
end

return M
