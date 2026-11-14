--- modules/gestures/background_commands.lua

--- ==============================================================================
--- MODULE: Observed Background Commands (Linux)
--- DESCRIPTION:
--- Runs a one-shot desktop command in the background and reports its own
--- failure. The daemon holds the grabbed keyboard, so it never waits for the
--- command: the backgrounded shell leaves the child's exit status and its
--- stderr in a private session folder, and a deferred collector logs a
--- nonzero exit as an error. Windows observes its workers the same way
--- (SystemControl.SpawnObserved logs a refused start, a throw or a nonzero
--- exit with its output).
---
--- FEATURES & RATIONALE:
--- 1. The acquisition stays os.execute(... &): a shell that cannot start is
---    reported at once, and the action never blocks on its command.
--- 2. The status file is published by rename, so a half-written status is
---    never read; stderr is read only once that status exists.
--- 3. The command itself is never logged: it can carry a selected path or a
---    URL. A caller marks a command private when even its stderr may name one.
--- 4. Applications launched for the user (xdg-open, gtk-launch) are not run
---    here: their child is the application, which outlives the action and has
---    no completion to report.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local ShellRunner = require("adapters.shell_runner")
local TableUtil = require("core.text.engine.table_util")

local LOG = "modules.gestures.background_commands"

-- How often pending results are looked for, and how much of a failed
-- command's stderr reaches the log
local POLL_MS = 1000
local STDERR_LOG_BYTES = 300

-- Launch id -> { prefix, label, private } for every command still running
local _pending = {}
local _next_id = 0
local _collector_armed = false
local _folder = nil





-- ==================================
-- ==================================
-- ======= 1/ Result Receipts =======
-- ==================================
-- ==================================

--- The private folder the background shells write their results into, the
--- session folder the other Linux locks use ($XDG_RUNTIME_DIR, else ~/.cache).
--- @return string|nil folder
--- @return string|nil error_message
local function result_folder()
	if _folder then return _folder end
	local root = os.getenv("XDG_RUNTIME_DIR")
	if root == nil or root == "" then
		local home = require("infra.config_paths").account_home()
		if home == nil then return nil, "neither XDG_RUNTIME_DIR nor an absolute HOME is set" end
		root = home .. "/.cache"
	end
	local uv = require("luv")
	local folder = root .. "/ergopti/actions"
	for _, path in ipairs({ root, root .. "/ergopti", folder }) do
		local made, err, code = uv.fs_mkdir(path, 448)
		if not made and code ~= "EEXIST" then return nil, tostring(err) end
	end
	_folder = folder
	return folder
end

--- Reads at most limit bytes of a file.
--- @param path string
--- @param limit integer
--- @return string|nil text Nil when the file does not exist.
local function read_bounded(path, limit)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local text = fh:read(limit) or ""
	fh:close()
	return text
end

--- Wraps a command so its status and stderr land next to prefix.
--- @param cmd string
--- @param prefix string
--- @return string
local function observed(cmd, prefix)
	local quote = ShellRunner.quote
	return "( ( " .. cmd .. " ) </dev/null >/dev/null 2>" .. quote(prefix .. ".err")
		.. "; printf '%s' \"$?\" >" .. quote(prefix .. ".tmp")
		.. " && mv -f " .. quote(prefix .. ".tmp") .. " " .. quote(prefix .. ".status")
		.. " ) >/dev/null 2>&1 &"
end

local arm

--- Logs every command that finished since the last look.
local function collect_finished()
	for id, job in pairs(_pending) do
		local status = read_bounded(job.prefix .. ".status", 16)
		if status ~= nil then
			_pending[id] = nil
			local stderr = read_bounded(job.prefix .. ".err", STDERR_LOG_BYTES) or ""
			os.remove(job.prefix .. ".status")
			os.remove(job.prefix .. ".err")
			if tonumber(status) ~= 0 then
				local detail
				if job.private then
					detail = string.format(" (stderr withheld, %d byte(s))", #stderr)
				else
					local line = stderr:match("^%s*([^\r\n]*)") or ""
					detail = line ~= "" and (": " .. line) or ""
				end
				Logger.error(LOG, "The background command of '%s' failed (exit %s)%s.",
					job.label, status, detail)
			end
		end
	end
end

--- The deferred collector: keeps looking while a command is still running.
local function collect()
	_collector_armed = false
	collect_finished()
	if next(_pending) ~= nil then arm() end
end

--- Schedules the next collection, once.
--- @return boolean armed
arm = function()
	if _collector_armed then return true end
	_collector_armed = require("core.events.loop").defer(collect, POLL_MS) == true
	return _collector_armed
end





-- =============================
-- =============================
-- ======= 2/ Public API ========
-- =============================
-- =============================

--- Starts a one-shot command in the background and owns its result.
--- @param cmd string The shell command.
--- @param label string The action it runs for, logged instead of the command.
--- @param private boolean|nil True when its stderr may name a user path or URL.
--- @return boolean started
function M.run(cmd, label, private)
	assert(type(cmd) == "string" and cmd ~= "", "a background command needs a command")
	assert(type(label) == "string" and label ~= "", "a background command needs an action label")
	local folder, why = result_folder()
	if not folder then
		Logger.error(LOG, "The background command of '%s' was not started: no private result folder (%s).",
			label, tostring(why))
		return false
	end
	_next_id = _next_id + 1
	local prefix = folder .. "/" .. tostring(require("luv").os_getpid()) .. "-" .. tostring(_next_id)
	local called, result, _, code = pcall(os.execute, observed(cmd, prefix))
	-- LuaJIT returns the status number; Lua 5.2+ returns true, or nil and the code.
	if not (called and (result == true or result == 0)) then
		Logger.error(LOG, "The shell refused to start the background command of '%s' (%s).",
			label, tostring(called and (code or result) or result))
		return false
	end
	_pending[_next_id] = { prefix = prefix, label = label, private = private == true }
	if not arm() then
		Logger.error(LOG, "The result of the background command of '%s' cannot be observed: no collector timer.",
			label)
	end
	return true
end

--- Number of commands whose result has not been collected yet.
--- @return integer
function M.pending_count()
	return TableUtil.count(_pending)
end

--- Collects finished results now, leaving the deferred collector armed
--- (test seam: the daemon's loop runs the collector itself).
function M._collect_now()
	collect_finished()
end

return M
