--- modules/llm/agent_connectors.lua

--- ==============================================================================
--- MODULE: AI Agent Connectors (Linux)
--- DESCRIPTION:
--- Carries out one action of the AI agent once the user accepted it: a
--- calendar event or a reminder, a mail draft, or one of the user's own tools.
--- One function per action type; the payloads (the iCalendar file, the mailto:
--- link) come from the shared _shared/lua/llm/agent.lua, so the three drivers
--- hand the system the same bytes.
---
--- FEATURES & RATIONALE:
--- 1. calendar and reminder: agent.ics() is written to a private temporary file
---    (a fresh 0700 directory) and opened with xdg-open, which hands it to the
---    default calendar application for import. The file is deleted at the next
---    run or when the daemon stops, never before the application read it.
--- 2. mail: xdg-email when installed (subject, body and recipients as
---    arguments), else xdg-open on the mailto: link. Either opens a draft in the
---    user's mail client; nothing is ever sent from here.
--- 3. shortcut: the tools are the executable files of <config dir>/agent_tools/
---    (the folder is created when missing); the chosen one runs with the input
---    as its only argument.
--- 4. Every program runs without a shell, as an argument vector, in an
---    asynchronous child: the daemon owns the grabbed keyboard meanwhile.
--- 5. Every OS boundary goes through `_deps`, which the tests replace.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Agent = require("llm.agent")
local ShellRunner = require("adapters.shell_runner")

local LOG = "modules.llm.agent_connectors"

-- The folder of the user's tools, under the configuration folder
M.TOOLS_DIR = "agent_tools"

-- How long a handler (xdg-open, xdg-email) may take to hand the file over
local OPEN_TIMEOUT_MS = 30000
-- How long one of the user's tools may run
local TOOL_TIMEOUT_MS = 120000
-- How long the tools list is reused before the folder is read again
local TOOLS_TTL_SEC = 600
-- A tool's name reaches the prompts and the menu: a plain file name only
local TOOL_NAME_PATTERN = "^[^/%c][^/%c]*$"
-- Random bytes of an iCalendar UID
local UID_BYTES = 16

-- The temporary .ics files handed to a calendar, deleted at the next run or
-- at stop: { { path, dir } }
local _pending_files = {}
-- The tools list and when it was read: { at, names }
local _tools_cache = nil




-- =========================================
-- =========================================
-- ======= 1/ OS boundaries ================
-- =========================================
-- =========================================

--- Creates a fresh directory only the user can read.
--- @return string|nil dir
local function private_dir()
	local base = os.getenv("XDG_RUNTIME_DIR")
	if not base or base == "" then base = os.getenv("TMPDIR") end
	if not base or base == "" then base = "/tmp" end
	return ShellRunner.exec_line("mktemp -d " .. ShellRunner.quote(base .. "/ergopti-agent.XXXXXXXX"))
end

--- Random hexadecimal digits from the kernel's generator.
--- @return string|nil hex
local function random_hex()
	local fh = io.open("/dev/urandom", "rb")
	if not fh then return nil end
	local bytes = fh:read(UID_BYTES)
	fh:close()
	if type(bytes) ~= "string" or #bytes ~= UID_BYTES then return nil end
	return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

--- Lists the executable regular files of a folder, creating it when missing.
--- @param dir string
--- @return table|nil names, string|nil reason
local function list_executables(dir)
	if not ShellRunner.run("mkdir -p " .. ShellRunner.quote(dir) .. " 2>/dev/null") then
		return nil, "the tools folder could not be created"
	end
	local ok, output, err = ShellRunner.exec_checked("find " .. ShellRunner.quote(dir)
		.. " -mindepth 1 -maxdepth 1 -type f -perm -u+x -printf '%f\\n' 2>/dev/null")
	if not ok then return nil, tostring(err) end
	local names = {}
	for line in output:gmatch("[^\n]+") do names[#names + 1] = line end
	return names, nil
end

--- The default boundaries; `_deps` holds the ones in use.
local DEFAULT_DEPS = {
	-- run(executable, args, { timeout_ms }, callback({ ok, code, error })) -> handle|nil, reason
	run = function(executable, args, options, callback)
		return ShellRunner.run_async(executable, args, options, callback)
	end,
	has_command = function(name) return ShellRunner.has_command(name) end,
	private_dir = private_dir,
	write_file = function(path, content)
		local fh = io.open(path, "wb")
		if not fh then return false end
		local ok = fh:write(content) ~= nil
		fh:close()
		return ok
	end,
	remove = function(path) return os.remove(path) end,
	utc_stamp = function() return os.date("!%Y%m%dT%H%M%SZ") end,
	random_hex = random_hex,
	tools_dir = function() return require("infra.config_paths").config(M.TOOLS_DIR) end,
	list_executables = list_executables,
	clock = os.time,
}

local _deps = DEFAULT_DEPS




-- =========================================
-- =========================================
-- ======= 2/ Temporary files ==============
-- =========================================
-- =========================================

--- Deletes the .ics files handed to a calendar earlier. The application read
--- them long ago: xdg-open returns once it has handed the file over, and the
--- next action or the daemon's stop comes later still.
function M.cleanup()
	local kept = {}
	for _, file in ipairs(_pending_files) do
		local removed_file = _deps.remove(file.path)
		local removed_dir = _deps.remove(file.dir)
		if not removed_file or not removed_dir then
			Logger.warn(LOG, "A temporary calendar file could not be deleted; it is retried later.")
			kept[#kept + 1] = file
		end
	end
	_pending_files = kept
end




-- =========================================
-- =========================================
-- ======= 3/ The user's tools =============
-- =========================================
-- =========================================

--- The user's tools: the executable files of the tools folder, sorted, at most
--- config.max_tools. Read again after TOOLS_TTL_SEC or refresh_tools().
--- @param config table Decoded agent.json.
--- @return table Array of tool names.
function M.tools(config)
	local now = _deps.clock()
	if _tools_cache and now - _tools_cache.at < TOOLS_TTL_SEC then return _tools_cache.names end
	local names, reason = _deps.list_executables(_deps.tools_dir())
	local kept = {}
	if not names then
		Logger.warn(LOG, "The agent's tools could not be listed: %s.", tostring(reason))
	else
		table.sort(names)
		for _, name in ipairs(names) do
			if #kept >= config.max_tools then break end
			if type(name) == "string" and name:match(TOOL_NAME_PATTERN) and name ~= "." and name ~= ".." then
				kept[#kept + 1] = name
			end
		end
	end
	_tools_cache = { at = now, names = kept }
	return kept
end

--- Forgets the tools list: the next tools() reads the folder again.
function M.refresh_tools()
	_tools_cache = nil
end




-- =========================================
-- =========================================
-- ======= 4/ Connectors ===================
-- =========================================
-- =========================================

--- Starts one program and reports its outcome.
--- @param what string What the log names the run.
--- @param executable string
--- @param args table
--- @param timeout_ms integer
--- @param on_done function on_done(ok, reason)
--- @return boolean started
local function start(what, executable, args, timeout_ms, on_done)
	local handle, reason = _deps.run(executable, args, { timeout_ms = timeout_ms }, function(result)
		if type(result) == "table" and result.ok == true then
			on_done(true, nil)
			return
		end
		on_done(false, string.format("%s failed: %s", what,
			tostring(type(result) == "table" and (result.error or ("exit code " .. tostring(result.code))) or result)))
	end)
	if not handle then
		on_done(false, string.format("%s could not start: %s", what, tostring(reason)))
		return false
	end
	return true
end

--- Hands a calendar event or a reminder to the default calendar application.
--- @param config table Decoded agent.json.
--- @param action table A validated calendar or reminder action.
--- @param on_done function
--- @return boolean started
local function open_ics(config, action, on_done)
	M.cleanup()
	local hex = _deps.random_hex()
	if not hex then
		on_done(false, "no random identifier could be drawn")
		return false
	end
	local content = Agent.ics(config, action, hex .. "@ergopti", _deps.utc_stamp())
	local dir = _deps.private_dir()
	if not dir then
		on_done(false, "no private directory could be created")
		return false
	end
	local path = dir .. "/" .. (action.type == "calendar" and "event" or "task") .. ".ics"
	if not _deps.write_file(path, content) then
		_deps.remove(dir)
		on_done(false, "the calendar file could not be written")
		return false
	end
	_pending_files[#_pending_files + 1] = { path = path, dir = dir }
	Logger.info(LOG, "Opening a %s entry with the default calendar application.", action.type)
	return start("xdg-open", "xdg-open", { path }, OPEN_TIMEOUT_MS, on_done)
end

--- Opens a mail draft in the user's mail client. Never sends.
--- @param action table A validated mail action.
--- @param on_done function
--- @return boolean started
local function open_mail(action, on_done)
	if _deps.has_command("xdg-email") then
		local args = { "--utf8" }
		if action.subject then
			args[#args + 1] = "--subject"
			args[#args + 1] = action.subject
		end
		args[#args + 1] = "--body"
		args[#args + 1] = action.body
		for _, address in ipairs(action.to or {}) do args[#args + 1] = address end
		Logger.info(LOG, "Opening a mail draft through xdg-email (%d recipient(s)).", #(action.to or {}))
		return start("xdg-email", "xdg-email", args, OPEN_TIMEOUT_MS, on_done)
	end
	Logger.info(LOG, "Opening a mail draft through a mailto: link (xdg-email is not installed).")
	return start("xdg-open", "xdg-open", { Agent.mailto(action) }, OPEN_TIMEOUT_MS, on_done)
end

--- Runs one of the user's tools with the action's input as its only argument.
--- @param config table Decoded agent.json.
--- @param action table A validated shortcut action.
--- @param on_done function
--- @return boolean started
local function run_tool(config, action, on_done)
	local known = false
	for _, name in ipairs(M.tools(config)) do
		if name == action.name then known = true end
	end
	if not known then
		on_done(false, "the tool is no longer in the tools folder")
		return false
	end
	Logger.info(LOG, "Running an agent tool (%s an input).", action.input and "with" or "without")
	return start("the tool", _deps.tools_dir() .. "/" .. action.name, action.input and { action.input } or {},
		TOOL_TIMEOUT_MS, on_done)
end

--- Carries out one validated action. on_done(ok, reason) is called once;
--- reason names the failure for the log and never holds the user's text.
--- @param config table Decoded agent.json.
--- @param action table A validated action (agent.parse_actions).
--- @param on_done function
--- @return boolean started
function M.run(config, action, on_done)
	if type(on_done) ~= "function" then error("agent_connectors.run: on_done must be a function", 2) end
	if type(action) ~= "table" then error("agent_connectors.run: an action is required", 2) end
	if action.type == "calendar" or action.type == "reminder" then return open_ics(config, action, on_done) end
	if action.type == "mail" then return open_mail(action, on_done) end
	if action.type == "shortcut" then return run_tool(config, action, on_done) end
	error("agent_connectors.run: unknown action type " .. tostring(action.type), 2)
end

--- Replaces OS boundaries (tests). Missing ones keep their defaults.
--- @param deps table|nil nil restores every default.
function M._set_deps_for_test(deps)
	if deps == nil then
		_deps = DEFAULT_DEPS
	else
		_deps = setmetatable(deps, { __index = DEFAULT_DEPS })
	end
	_pending_files = {}
	_tools_cache = nil
end

return M
