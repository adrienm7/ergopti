--- apps/dialogs.lua

--- ==============================================================================
--- MODULE: Bundled App Dialogs (Linux)
--- DESCRIPTION:
--- The few native dialogs the bundled apps ask through: a hidden or visible
--- text entry, a question, a message and a file chooser. Each runs Ergopti's own
--- GTK host (ui/native_dialog.lua), never the host's zenity.
---
--- FEATURES & RATIONALE:
--- 1. The apps are separate processes, so a dialog blocks only the app: the
---    daemon keeps handling the keyboard and needs no ui/modal hand-over.
--- 2. The exit status comes from the shell itself (a printed receipt), because
---    LuaJIT's popen close can report success for a cancelled dialog.
--- 3. Cancel and failure differ: a dialog that could not open (status 69, no
---    display) raises instead of reading as the user's cancel.
--- ==============================================================================

local M = {}

local NativeDialog = require("ui.native_dialog")
local TextUtils = require("core.text.engine.utils_core")
local WindowTitles = require("core.ui.engine.window_titles")

local RECEIPT = "ERGOPTI_DIALOG_STATUS="

--- Runs one shell command and returns its stdout and exit status.
--- @param command string
--- @return string output
--- @return number|nil status
local function run_shell(command)
	local pipe = assert(io.popen(command .. "; printf '\\n" .. RECEIPT .. "%s\\n' \"$?\"", "r"))
	local output = pipe:read("*a") or ""
	pipe:close()
	local body, status = output:match("^(.*)\n" .. RECEIPT .. "(%d+)\n$")
	return body or "", tonumber(status)
end

--- Creates a dialog owner.
--- @param deps table|nil { run = function(command) -> output, status }; a test seam.
--- @return table dialogs
function M.new(deps)
	local run = (deps and deps.run) or run_shell
	local command = (deps and deps.command) or NativeDialog.command
	local self = {}

	--- Runs the host with words and returns its answer.
	--- @return string|nil answer Nil when the user cancelled.
	local function ask(words)
		local line = command()
		for _, word in ipairs(words) do line = line .. " " .. TextUtils.shell_quote(word) end
		local output, status = run(line .. " 2>/dev/null")
		if status == NativeDialog.EXIT_CANCELLED then return nil end
		if status ~= 0 then error("the native dialog could not open (status " .. tostring(status) .. ")") end
		return (output:gsub("\n$", ""))
	end

	--- Asks for a line of text.
	--- @param title string
	--- @param text string
	--- @param options table|nil { hidden, initial, ok, cancel }
	--- @return string|nil
	function self.entry(title, text, options)
		options = options or {}
		local words = { "--entry", "--no-markup", "--title=" .. WindowTitles.compose(title), "--text=" .. text,
			"--entry-text=" .. (options.initial or "") }
		if options.hidden then words[#words + 1] = "--hide-text" end
		if options.ok then words[#words + 1] = "--ok-label=" .. options.ok end
		if options.cancel then words[#words + 1] = "--cancel-label=" .. options.cancel end
		return ask(words)
	end

	--- Asks a yes/no question.
	--- @return boolean accepted
	function self.question(title, text, ok, cancel)
		local words = { "--question", "--no-markup", "--title=" .. WindowTitles.compose(title), "--text=" .. text }
		if ok then words[#words + 1] = "--ok-label=" .. ok end
		if cancel then words[#words + 1] = "--cancel-label=" .. cancel end
		return ask(words) ~= nil
	end

	--- Shows a message; kind is "info", "warning" or "error".
	--- @return boolean accepted True for the OK button, false when closed otherwise.
	function self.message(kind, title, text, ok, cancel)
		assert(kind == "info" or kind == "warning" or kind == "error", "unknown message kind")
		local words = { "--" .. kind, "--no-markup", "--title=" .. WindowTitles.compose(title), "--text=" .. text }
		if ok then words[#words + 1] = "--ok-label=" .. ok end
		if cancel then words[#words + 1] = "--cancel-label=" .. cancel end
		return ask(words) ~= nil
	end

	--- Asks for a file.
	--- @param title string
	--- @param options table|nil { filename = start path, filter = glob }
	--- @return string|nil path
	function self.file(title, options)
		options = options or {}
		local words = { "--file-selection", "--title=" .. WindowTitles.compose(title) }
		if options.filename then words[#words + 1] = "--filename=" .. options.filename end
		if options.filter then words[#words + 1] = "--file-filter=" .. options.filter end
		local answer = ask(words)
		if answer == nil or answer == "" then return nil end
		return answer
	end

	return self
end

return M
