--- modules/gestures/user_actions.lua

--- ==============================================================================
--- MODULE: User Command and Path Actions (macOS)
--- DESCRIPTION:
--- The run_command and open_path actions of the shared catalogue: a shell
--- command line the user typed, run hidden or in a new Terminal window, and a
--- file or folder opened with its default application.
--- modules/gestures/actions.lua registers both and decodes their parameter
--- through _shared/shortcuts/engine/user_action_parameter.lua.
---
--- FEATURES & RATIONALE:
--- 1. Never blocks the runloop that feeds the keyboard tap: every process is an
---    owned asynchronous child of actions_aux_owner, under the parent that
---    dispatched the action, so PAUSE of that parent stops it.
--- 2. The command is run by /bin/sh -l -c: a login shell's environment
---    (/etc/profile, which runs path_helper, and ~/.profile), not the bare
---    environment the driver inherited from launchd. A PATH set only in
---    ~/.zprofile or ~/.zshrc is not read; the README says so.
--- 3. The command text is user configuration: it never reaches the log, the
---    native task log (run_private) or an AppleScript source. The Terminal
---    window receives it as an osascript argument of a fixed run handler.
--- 4. Bounded: a hidden command is stopped after run_command_timeout_ms or once
---    its output passes user_action_output_bytes, and both are notified.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")
local i18n = require("core.i18n.engine.i18n")
local notifications = require("core.ui.engine.notifications")
local Timings = require("core.timing.engine.timings")
local text_utils = require("core.text.engine.utils")
local AuxOwner = require("modules.gestures.actions_aux_owner")
local FileSystem = require("core.fs.adapters.file_system")
local Clipboard = require("clipboard.adapters.clipboard")
local SyntheticInput = require("platform.input.synthetic_input")
local Unicode = require("core.lifecycle.engine.compat.utf8")
local Parameter = require("shortcuts.engine.user_action_parameter")

local LOG = "gestures.user_actions"





-- ===============================
-- ===============================
-- ======= 1/ Native Tools =======
-- ===============================
-- ===============================

-- Absolute paths: the driver does not inherit a login shell's PATH.
M.SHELL_BIN = "/bin/sh"
M.OPEN_BIN = "/usr/bin/open"
M.OSASCRIPT_BIN = "/usr/bin/osascript"

M.RUN_COMMAND_TIMEOUT_SEC = Timings.sec("gestures", "run_command_timeout_ms")
M.MAX_OUTPUT_BYTES = Timings.count("limits", "user_action_output_bytes")

-- The run handler that opens a Terminal window on its first argument. The
-- shell line is an argument, never part of the source, so no quoting of the
-- user's text can turn into AppleScript.
M.TERMINAL_SCRIPT = {
	"on run argv",
	'tell application "Terminal"',
	"activate",
	"do script (item 1 of argv)",
	"end tell",
	"end run",
}

--- The argument vector of a hidden command: a login /bin/sh running it.
--- @param command string The user's command line.
--- @return table args
function M.shell_args(command)
	return { "-l", "-c", command }
end

--- The osascript argument vector that runs a command in a new Terminal window.
--- Terminal types the line into the user's interactive shell, which starts the
--- same login /bin/sh as a hidden run; the window stays open afterwards.
--- @param command string The user's command line.
--- @return table args
function M.terminal_args(command)
	local args = {}
	for _, line in ipairs(M.TERMINAL_SCRIPT) do
		args[#args + 1] = "-e"
		args[#args + 1] = line
	end
	args[#args + 1] = M.SHELL_BIN .. " -l -c " .. text_utils.shell_quote(command)
	return args
end





-- ===================================
-- ===================================
-- ======= 2/ Notices & Output =======
-- ===================================
-- ===================================

--- Shows a failure notice; a notice that cannot be shown is logged.
--- @param key string Locale key.
--- @param ... any Values for its {1}, {2} placeholders.
function M.notify(key, ...)
	local shown, err = notifications.notify(i18n.format(key, ...), nil, "error")
	if shown ~= true then
		Logger.warn(LOG, "Notice '%s' could not be shown: %s.", key, tostring(err))
	end
end

--- Types or copies a captured text output. A trailing line break (the one
--- `date` or `pwgen` prints) is not part of the text.
--- @param text string The captured output.
--- @param output string none, type or copy.
--- @param max_typed number Longest text typed, in code points (send_keys.json).
--- @param label string Log label, free of user data.
--- @return boolean delivered
function M.deliver_output(text, output, max_typed, label)
	if output == "none" then return true end
	local value = tostring(text or ""):gsub("[\r\n]+$", "")
	if value == "" then
		Logger.warn(LOG, "%s printed no text to %s.", label, output)
		return false
	end
	local code_points = Unicode.len(value)
	if code_points == nil then
		Logger.error(LOG, "%s printed text that is not UTF-8: nothing to %s.", label, output)
		M.notify("user_actions.output_not_text")
		return false
	end
	if output == "copy" then
		local written = Clipboard.write(value)
		if written ~= true then Logger.error(LOG, "%s: its output could not be copied.", label) end
		return written == true
	end
	if code_points > max_typed then
		Logger.warn(LOG, "%s printed %d characters, more than the %d typed.", label, code_points, max_typed)
		M.notify("user_actions.output_too_long_to_type", max_typed)
		return false
	end
	local ok, typed = pcall(SyntheticInput.emit_key_strokes, value)
	if not ok or typed ~= true then
		Logger.error(LOG, "%s: its output could not be typed: %s.", label, tostring(typed))
		return false
	end
	return true
end





-- ================================
-- ================================
-- ======= 3/ Run a Command =======
-- ================================
-- ================================

--- Reports one finished hidden command and delivers its output.
--- @param result table|boolean The owner's result, false on its deadline.
--- @param fields table The decoded parameter.
--- @param max_typed number Longest text typed, in code points.
local function finish_hidden(result, fields, max_typed)
	if result == false or type(result) ~= "table" then
		Logger.error(LOG, "The command of a run_command binding was stopped after %.0f seconds.", M.RUN_COMMAND_TIMEOUT_SEC)
		M.notify("user_actions.command_timeout", string.format("%.0f", M.RUN_COMMAND_TIMEOUT_SEC))
		return
	end
	if result.overflow then
		Logger.error(LOG, "The command of a run_command binding printed more than %d bytes and was stopped.",
			M.MAX_OUTPUT_BYTES)
		M.notify("user_actions.command_output_too_large", M.MAX_OUTPUT_BYTES)
		return
	end
	if result.code ~= 0 then
		-- The exit code is logged; the stderr line may quote the command, so it
		-- goes only to the user's own notification
		Logger.error(LOG, "The command of a run_command binding exited with code %s.", tostring(result.code))
		local line = Parameter.first_line(result.stderr, Parameter.NOTICE_LINE_BYTES)
		if line then
			M.notify("user_actions.command_failed_detail", tostring(result.code), line)
		else
			M.notify("user_actions.command_failed", tostring(result.code))
		end
		return
	end
	Logger.success(LOG, "The command of a run_command binding exited with code 0.")
	M.deliver_output(result.stdout, fields.output, max_typed, "The command of a run_command binding")
end

--- Runs a decoded run_command parameter.
--- @param fields table { command, mode, output } from user_action_parameter.
--- @param parent string|nil Action parent.
--- @param max_typed number Longest text typed, in code points.
--- @return boolean started
function M.run_command(fields, parent, max_typed)
	if fields.mode == "terminal" then
		Logger.start(LOG, "Opening a Terminal window for a run_command binding…")
		local started = AuxOwner.run_private(M.OSASCRIPT_BIN, M.terminal_args(fields.command),
			"run_command terminal", function(result)
				if type(result) == "table" and result.code == 0 and not result.overflow then
					Logger.success(LOG, "The Terminal window of a run_command binding opened.")
					return
				end
				Logger.error(LOG, "Terminal refused the command of a run_command binding (code %s).",
					type(result) == "table" and tostring(result.code) or "timeout")
				M.notify("user_actions.terminal_unavailable")
			end, parent, M.RUN_COMMAND_TIMEOUT_SEC, M.MAX_OUTPUT_BYTES)
		if not started then Logger.error(LOG, "The Terminal window of a run_command binding could not start.") end
		return started
	end
	Logger.start(LOG, "Running the command of a run_command binding…")
	local started = AuxOwner.run_private(M.SHELL_BIN, M.shell_args(fields.command), "run_command",
		function(result) finish_hidden(result, fields, max_typed) end,
		parent, M.RUN_COMMAND_TIMEOUT_SEC, M.MAX_OUTPUT_BYTES)
	if not started then Logger.error(LOG, "The command of a run_command binding could not start.") end
	return started
end





-- ==============================
-- ==============================
-- ======= 4/ Open a Path =======
-- ==============================
-- ==============================

--- Opens a decoded open_path parameter with its default application. A path
--- that no longer exists is refused with a notice naming it.
--- @param fields table { path } from user_action_parameter.
--- @param parent string|nil Action parent.
--- @return boolean started
function M.open_path(fields, parent)
	local status, detail = FileSystem.path_status(fields.path)
	if status ~= "present" then
		Logger.warn(LOG, "open_path refused: its stored path is %s (%s).", status,
			status == "error" and tostring(detail) or "missing")
		M.notify("user_actions.path_missing", fields.path)
		return false
	end
	Logger.start(LOG, "Opening the stored file or folder of an open_path binding…")
	-- Private like a command: open's own error line quotes the path
	local started = AuxOwner.run_private(M.OPEN_BIN, { fields.path }, "open_path", function(result)
		if type(result) == "table" and result.code == 0 and not result.overflow then
			Logger.success(LOG, "The stored file or folder of an open_path binding opened.")
		else
			Logger.error(LOG, "open refused the stored file or folder of an open_path binding.")
			M.notify("user_actions.path_open_failed", fields.path)
		end
	end, parent, M.RUN_COMMAND_TIMEOUT_SEC, M.MAX_OUTPUT_BYTES)
	if not started then Logger.error(LOG, "open could not start for an open_path binding.") end
	return started
end

return M
