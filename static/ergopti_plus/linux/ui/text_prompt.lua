--- ui/text_prompt.lua

--- ==============================================================================
--- MODULE: Text Prompt Dialog (Linux)
--- DESCRIPTION:
--- Asks the user for one line of text in a zenity entry. The tray's prompts and
--- the AI agent's command dialog (llm_agent_command) share it.
---
--- FEATURES & RATIONALE:
--- 1. Cancel is not an empty answer. Production runs LuaJIT, where a pipe's
---    close() returns the NUMBER 0 for success, and Lua 5.2+ returns true: both
---    spellings are success, anything else is Cancel or a closed window, which
---    returns nil. A confirmed empty entry returns "".
--- 2. The dialog runs through ui/modal.lua: it blocks the daemon's event loop,
---    so the keyboard is handed to the desktop while it is open.
--- 3. Every value reaches zenity as one quoted shell word.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Modal = require("ui.modal")

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
	local command = "zenity --entry --title=" .. shell_quote(title)
		.. " --text=" .. shell_quote(prompt)
		.. " --entry-text=" .. shell_quote(initial or "")
		.. (hidden and " --hide-text" or "")
	for _, choice in ipairs(type(choices) == "table" and choices or {}) do
		command = command .. " " .. shell_quote(choice)
	end
	command = command .. " 2>/dev/null"
	local value, ok = Modal.run(function()
		local pipe = io.popen(command, "r")
		if not pipe then return nil, nil end
		local text = pipe:read("*a") or ""
		return text, pipe:close()
	end)
	if value == nil then
		Logger.error(LOG, "Zenity is unavailable: cannot prompt for '%s'.", tostring(title))
		return nil
	end
	-- A non-zero exit is Cancel or the window being closed. Distinguished from an
	-- empty entry, which exits zero: the first must change nothing, the second is
	-- a value the caller gets to refuse with its own message.
	if not (ok == true or ok == 0) then return nil end
	return (value:gsub("[\r\n]+$", ""))
end

return M
