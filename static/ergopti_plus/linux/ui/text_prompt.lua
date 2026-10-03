--- ui/text_prompt.lua

--- ==============================================================================
--- MODULE: Text Prompt Dialog (Linux)
--- DESCRIPTION:
--- Asks the user for one line of text in a zenity entry. The tray's prompts and
--- the AI agent's command dialog (llm_agent_command) share it.
---
--- FEATURES & RATIONALE:
--- 1. Cancel is not an empty answer. LuaJIT's pipe close acknowledgement can
---    be true even when the native child exits one. The shell authority keeps
---    the actual child status independently, so cancellation returns nil and
---    a confirmed empty entry still returns "".
--- 2. The dialog runs through ui/modal.lua: it blocks the daemon's event loop,
---    so the keyboard is handed to the desktop while it is open.
--- 3. Every value reaches zenity as one quoted shell word.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Modal = require("ui.modal")
local Shell = require("adapters.shell_runner")
local WindowTitles = require("window_titles")

local LOG = "ui.text_prompt"

--- Quotes a value as one inert POSIX shell word.
--- @param value any
--- @return string
local function shell_quote(value)
	return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

--- Asks the user for a line of text.
--- @param title string Window title.
--- @param prompt string The question (Pango markup: escape user data first).
--- @param initial string|nil Pre-filled value.
--- @param hidden boolean|nil Mask the typed text (an API key).
--- @param choices table|nil Values offered in the entry's drop-down list.
--- @return string|nil The entered text, or nil when the dialog was cancelled.
function M.ask(title, prompt, initial, hidden, choices)
	local command = "zenity --entry --title=" .. shell_quote(WindowTitles.compose(title))
		.. " --text=" .. shell_quote(prompt)
		.. " --entry-text=" .. shell_quote(initial or "")
		.. (hidden and " --hide-text" or "")
	for _, choice in ipairs(type(choices) == "table" and choices or {}) do
		command = command .. " " .. shell_quote(choice)
	end
	command = command .. " 2>/dev/null"
	local ok, value, reason = Modal.run(function() return Shell.exec_checked(command) end)
	if ok ~= true then
		if reason ~= "command exited with status 1" then
			Logger.error(LOG, "Zenity could not prompt for '%s': %s.", tostring(title), tostring(reason))
		end
		return nil
	end
	return (value:gsub("[\r\n]+$", ""))
end

return M
