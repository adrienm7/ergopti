--- gestures/engine/user_actions.lua

--- ==============================================================================
--- MODULE: User Command and Path Actions (Linux)
--- DESCRIPTION:
--- The run_command and open_path actions of the shared catalogue: a shell
--- command line the user typed, run hidden or in a new terminal window, and a
--- file or folder opened with its default application.
--- gestures/engine/manager.lua dispatches both and decodes their parameter
--- through _shared/shortcuts/engine/user_action_parameter.lua.
---
--- FEATURES & RATIONALE:
--- 1. Never blocks the daemon's event loop: a hidden command is a libuv child
---    (ShellRunner.run_async), bounded by run_command_timeout_ms and by
---    user_action_output_bytes, both notified when they stop it.
--- 2. The command is run by /bin/sh -l -c: a login shell's environment
---    (/etc/profile and ~/.profile), not the daemon's own environment. A PATH
---    set only in ~/.bashrc or ~/.zshrc is not read; the README says so.
--- 3. The terminal is the session's own: $TERMINAL when it names a known
---    terminal, else the first of TERMINALS on PATH (x-terminal-emulator, the
---    Debian alternative, first). It is detached and not bounded: the window
---    and what runs in it are the user's.
--- 4. The command text is user configuration: it never reaches the log.
--- 5. A file or folder opens through xdg-open, else gio open; a path that no
---    longer exists is refused with a notice naming it.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local i18n = require("core.i18n.engine.i18n")
local Timings = require("core.timing.engine.timings")
local ShellRunner = require("core.process.adapters.shell_runner")
local FileSystem = require("core.fs.adapters.file_system")
local Unicode = require("core.lifecycle.engine.compat.utf8")
local Parameter = require("shortcuts.engine.user_action_parameter")

local LOG = "gestures.engine.user_actions"

M.SHELL_BIN = "/bin/sh"
M.COMMAND_TIMEOUT_MS = Timings.ms("gestures", "run_command_timeout_ms")
M.MAX_OUTPUT_BYTES = Timings.count("limits", "user_action_output_bytes")

--- The terminals a command window may open in, in preference order, each
--- with the arguments that precede the program it runs.
M.TERMINALS = {
	{ binary = "x-terminal-emulator", exec = { "-e" } },
	{ binary = "gnome-terminal", exec = { "--" } },
	{ binary = "ptyxis", exec = { "--" } },
	{ binary = "konsole", exec = { "-e" } },
	{ binary = "xfce4-terminal", exec = { "-x" } },
	{ binary = "mate-terminal", exec = { "-x" } },
	{ binary = "kitty", exec = {} },
	{ binary = "alacritty", exec = { "-e" } },
	{ binary = "foot", exec = {} },
	{ binary = "wezterm", exec = { "start", "--" } },
	{ binary = "xterm", exec = { "-e" } },
}

--- The openers of a file or folder, in preference order.
M.OPENERS = {
	{ binary = "xdg-open", args = {} },
	{ binary = "gio", args = { "open" } },
}

-- The program a terminal window runs: a login /bin/sh runs the command, then
-- the user's own shell keeps the window open on its result. The command is
-- the positional argument $1, never part of this source.
M.TERMINAL_SCRIPT = '/bin/sh -c "$1"; exec "${SHELL:-/bin/sh}"'

-- The commands in flight and whether new ones are admitted. Declared above
-- every reader.
local _handles = {}
local _settled_waiters = {}
local _paused = false

local function publish_settled()
	if next(_handles) ~= nil then return end
	local listeners = _settled_waiters
	_settled_waiters = {}
	for _, listener in ipairs(listeners) do
		local ok = pcall(listener)
		if not ok then Logger.error(LOG, "User command settlement listener failed.") end
	end
end

--- Shows a failure notice; a notice that cannot be shown is logged.
--- @param key string Locale key.
--- @param ... any Values for its {1}, {2} placeholders, replaced on plain
---   indices: a path or an error line may hold a %.
function M.notify(key, ...)
	local text = i18n.get(key)
	-- select, not table.pack: LuaJIT is 5.1-based and has no table.pack
	for index = 1, select("#", ...) do
		local token = "{" .. index .. "}"
		local at = text:find(token, 1, true)
		if at then text = text:sub(1, at - 1) .. tostring((select(index, ...))) .. text:sub(at + #token) end
	end
	local ok, Notifier = pcall(require, "platform.focus.application_notifier")
	if not ok or type(Notifier.send) ~= "function" or Notifier.send(text, { level = "error", private = true }) ~= true then
		Logger.warn(LOG, "Notice '%s' could not be shown.", key)
	end
end





-- ==================================
-- ==================================
-- ======= 1/ Output Delivery =======
-- ==================================
-- ==================================

--- Types or copies a captured text output. A trailing line break is not part
--- of the text.
--- @param text string The captured output.
--- @param output string none, type or copy.
--- @param max_typed number Longest text typed, in code points (send_keys.json).
--- @param publication table|nil Destination retained when the command started.
--- @return boolean delivered
function M.deliver_output(text, output, max_typed, publication)
	if output == "none" then return true end
	local value = tostring(text or ""):gsub("[\r\n]+$", "")
	if value == "" then
		Logger.warn(LOG, "The command of a run_command binding printed no text to %s.", output)
		return false
	end
	local code_points = Unicode.len(value)
	if code_points == nil then
		Logger.error(LOG, "The command of a run_command binding printed text that is not UTF-8.")
		M.notify("user_actions.output_not_text")
		return false
	end
	if output == "copy" then
		local written = require("clipboard.adapters.clipboard").write(value) == true
		if not written then Logger.error(LOG, "The output of a run_command binding could not be copied.") end
		return written
	end
	if code_points > max_typed then
		Logger.warn(LOG, "A run_command output of %d characters is more than the %d typed.", code_points, max_typed)
		M.notify("user_actions.output_too_long_to_type", max_typed)
		return false
	end
	if publication then
		local checked, current = pcall(publication.current)
		if not checked or current ~= true then
			Logger.warn(LOG, "Command output was not typed: its original destination changed.")
			return false
		end
	end
	local typed = require("modules.shortcuts.manager").insert_text(value, publication) == true
	if not typed then Logger.error(LOG, "The output of a run_command binding could not be typed.") end
	return typed
end





-- ================================
-- ================================
-- ======= 2/ Run a Command =======
-- ================================
-- ================================

--- The argument vector of a hidden command: a login /bin/sh running it.
--- @param command string
--- @return table args
function M.shell_args(command)
	return { "-l", "-c", command }
end

--- The terminal a command window opens in: $TERMINAL when it names a known
--- terminal on PATH, else the first known terminal on PATH.
--- @param has_command function fn(binary) -> boolean.
--- @param preferred string|nil The value of $TERMINAL.
--- @return table|nil terminal One row of TERMINALS.
function M.resolve_terminal(has_command, preferred)
	if type(preferred) == "string" and preferred ~= "" then
		local name = require("core.fs.engine.native_path").basename(preferred)
		for _, terminal in ipairs(M.TERMINALS) do
			if terminal.binary == name and has_command(terminal.binary) then return terminal end
		end
	end
	for _, terminal in ipairs(M.TERMINALS) do
		if has_command(terminal.binary) then return terminal end
	end
	return nil
end

--- The full argument vector of a terminal window running a command.
--- @param terminal table One row of TERMINALS.
--- @param command string
--- @return table argv The terminal first.
function M.terminal_argv(terminal, command)
	local argv = { terminal.binary }
	for _, value in ipairs(terminal.exec) do argv[#argv + 1] = value end
	for _, value in ipairs({ M.SHELL_BIN, "-l", "-c", M.TERMINAL_SCRIPT, "ergopti", command }) do
		argv[#argv + 1] = value
	end
	return argv
end

--- The shell line that starts a program detached in its own session, with no
--- inherited streams, every argument quoted.
--- @param argv table
--- @return string command
function M.detached_command(argv)
	local quoted = {}
	for index, value in ipairs(argv) do quoted[index] = ShellRunner.quote(value) end
	return "setsid " .. table.concat(quoted, " ") .. " </dev/null >/dev/null 2>&1 &"
end

--- Starts a detached program without waiting for it: the shell returns as soon
--- as the background job is forked. ShellRunner.run logs the program name only.
--- @param argv table
--- @return boolean started
local function detach(argv)
	return ShellRunner.run(M.detached_command(argv)) == true
end

--- Reports one finished hidden command and delivers its output.
--- @param answer table ShellRunner.run_async's result.
--- @param fields table The decoded parameter.
--- @param max_typed number Longest text typed, in code points.
local function finish_hidden(answer, fields, max_typed, publication)
	if answer.timed_out then
		Logger.error(LOG, "The command of a run_command binding was stopped after %d ms.", M.COMMAND_TIMEOUT_MS)
		M.notify("user_actions.command_timeout", string.format("%.0f", M.COMMAND_TIMEOUT_MS / 1000))
		return
	end
	if answer.overflow then
		Logger.error(LOG, "The command of a run_command binding printed more than %d bytes and was stopped.",
			M.MAX_OUTPUT_BYTES)
		M.notify("user_actions.command_output_too_large", M.MAX_OUTPUT_BYTES)
		return
	end
	if answer.ok ~= true then
		Logger.error(LOG, "The command of a run_command binding failed (%s).", tostring(answer.code or answer.error))
		local line = Parameter.first_line(answer.stderr, Parameter.NOTICE_LINE_BYTES)
		local code = tostring(answer.code or answer.error)
		if line then M.notify("user_actions.command_failed_detail", code, line)
		else M.notify("user_actions.command_failed", code) end
		return
	end
	Logger.info(LOG, "The command of a run_command binding exited with code 0.")
	M.deliver_output(answer.stdout, fields.output, max_typed, publication)
end

--- Runs a decoded run_command parameter.
--- @param fields table { command, mode, output } from user_action_parameter.
--- @param max_typed number Longest text typed, in code points.
--- @return boolean started
function M.run_command(fields, max_typed)
	if _paused then
		Logger.warn(LOG, "run_command refused: the actions are paused.")
		return false
	end
	if fields.mode == "terminal" then
		local terminal = M.resolve_terminal(ShellRunner.has_command, os.getenv("TERMINAL"))
		if not terminal then
			Logger.error(LOG, "run_command: no known terminal is installed.")
			M.notify("user_actions.terminal_unavailable")
			return false
		end
		local started = detach(M.terminal_argv(terminal, fields.command))
		if started then
			Logger.info(LOG, "Opened %s for a run_command binding.", terminal.binary)
		else
			Logger.error(LOG, "%s could not start for a run_command binding.", terminal.binary)
			M.notify("user_actions.terminal_unavailable")
		end
		return started
	end
	local publication
	if fields.output == "type" then
		local shortcuts = require("modules.shortcuts.manager")
		publication = shortcuts.capture_text_destination()
		if not publication or _paused then
			Logger.warn(LOG, "run_command refused: no retained text destination.")
			return false
		end
	end
	local token, finished = {}, false
	local handle, refusal, cleanup = ShellRunner.run_async(M.SHELL_BIN, M.shell_args(fields.command),
		{ timeout_ms = M.COMMAND_TIMEOUT_MS, max_output_bytes = M.MAX_OUTPUT_BYTES }, function(answer)
			finished = true
			_handles[token] = nil
			publish_settled()
			finish_hidden(answer, fields, max_typed, publication)
		end)
	if not handle then
		-- A child may have started before its output watcher was refused. Keep
		-- its cleanup owner visible to pause until the native exit is observed.
		if cleanup then
			_handles[token] = cleanup
			pcall(cleanup.on_settled, function() _handles[token] = nil; publish_settled() end)
		end
		Logger.error(LOG, "The command of a run_command binding could not start: %s.", tostring(refusal))
		M.notify("user_actions.command_failed", tostring(refusal))
		return false
	end
	-- A child that settled during admission has already reported itself
	if not finished then
		_handles[token] = handle
		if type(handle.on_settled) == "function" then
			pcall(handle.on_settled, function() _handles[token] = nil; publish_settled() end)
		end
	end
	Logger.info(LOG, "Started the command of a run_command binding.")
	return true
end

--- Admits or refuses new commands; pausing also stops the hidden ones.
--- @param paused boolean
--- @return boolean settled
function M.set_paused(paused)
	_paused = paused == true
	if _paused then return M.stop() end
	return true
end

--- Stops every hidden command in flight; their completion is not delivered.
--- @return boolean settled
function M.stop()
	local settled = true
	for token, handle in pairs(_handles) do
		local ok, cancelled = pcall(handle.cancel)
		if ok and cancelled == true then
			_handles[token] = nil
		else
			settled = false
		end
	end
	publish_settled()
	return settled and next(_handles) == nil
end

--- Notifies after every currently owned hidden command has settled.
function M.when_settled(listener)
	if type(listener) ~= "function" then return false end
	if next(_handles) == nil then
		local ok = pcall(listener)
		if not ok then Logger.error(LOG, "User command settlement listener failed.") end
	else
		_settled_waiters[#_settled_waiters + 1] = listener
	end
	return true
end

--- Whether a hidden command is in flight.
--- @return boolean
function M.busy() return next(_handles) ~= nil end





-- ==============================
-- ==============================
-- ======= 3/ Open a Path =======
-- ==============================
-- ==============================

--- The opener of a file or folder: xdg-open, else gio.
--- @param has_command function fn(binary) -> boolean.
--- @return table|nil opener One row of OPENERS.
function M.resolve_opener(has_command)
	for _, opener in ipairs(M.OPENERS) do
		if has_command(opener.binary) then return opener end
	end
	return nil
end

--- Opens a decoded open_path parameter with its default application.
--- @param fields table { path } from user_action_parameter.
--- @param exists function|nil Test seam: fn(path) -> boolean.
--- @return boolean started
function M.open_path(fields, exists)
	if not (exists or FileSystem.exists)(fields.path) then
		Logger.warn(LOG, "open_path refused: its stored path no longer exists.")
		M.notify("user_actions.path_missing", fields.path)
		return false
	end
	local opener = M.resolve_opener(ShellRunner.has_command)
	if not opener then
		Logger.error(LOG, "open_path: neither xdg-open nor gio is installed.")
		M.notify("user_actions.opener_unavailable")
		return false
	end
	local argv = { opener.binary }
	for _, value in ipairs(opener.args) do argv[#argv + 1] = value end
	-- An absolute path never reads as an option, so no -- is needed (gio and
	-- xdg-open do not both accept one)
	argv[#argv + 1] = fields.path
	local started = detach(argv)
	if started then
		Logger.info(LOG, "Opened the stored file or folder of an open_path binding with %s.", opener.binary)
	else
		Logger.error(LOG, "%s could not start for an open_path binding.", opener.binary)
		M.notify("user_actions.path_open_failed", fields.path)
	end
	return started
end

return M
