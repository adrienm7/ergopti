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
-- Native construction and close debt outlive the logical action result.
local _jobs = {}
-- Desktop launchers keep their existing handoff contract, not tool group ownership.
local _desktop_jobs = {}
local _stopping = false
local _admissions = 0
local _checking_shutdown = false

--- Publishes only after the exact native operation physically retires.
--- @param job table Captured constructor, native ports and business callback.
local function retire_job(job)
	if job.constructing or job.uncertain or not _jobs[job] or not job.operation then return end
	local checked, settled = pcall(job.is_settled, job.operation)
	if not checked or settled ~= true then return end
	_jobs[job] = nil
	if _stopping or not job.result then return end
	local result = job.result
	local ok = type(result) == "table" and result.ok == true
	local reason = not ok and string.format("%s failed: %s", job.what,
		tostring(type(result) == "table" and (result.error or ("exit code " .. tostring(result.code))) or result)) or nil
	local delivered = pcall(job.done, ok, reason)
	if not delivered then pcall(Logger.error, LOG, "Agent connector completion callback failed.") end
end

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
	run_tool = function(executable, args, options, callback)
		-- Like the previous argv runner, anchor this new relative deadline to
		-- the current native clock, never to time cached before a blocking UI.
		local loaded, native = pcall(require, "luv")
		if not loaded or type(native.update_time) ~= "function" then return nil, "native clock unavailable" end
		local refreshed = pcall(native.update_time)
		if not refreshed then return nil, "native clock refresh refused" end
		return require("adapters.owned_process").start(executable, args, options, function(result)
			callback({ ok = result.ok, code = result.exit_code, error = result.error })
		end)
	end,
	has_command = function(name) return ShellRunner.has_command(name) end,
	private_dir = private_dir,
	write_file = function(path, content)
		local fh = io.open(path, "wb")
		if not fh then return false end
		-- A buffered write is not a complete calendar until close acknowledges it.
		local wrote, written = pcall(fh.write, fh, content)
		local closed, flushed = pcall(fh.close, fh)
		return wrote and written ~= nil and written ~= false and closed and flushed == true
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
	if next(_jobs) ~= nil or next(_desktop_jobs) ~= nil then return false end
	local kept = {}
	for _, file in ipairs(_pending_files) do
		if file.preparing and file.preparing.active then
			kept[#kept + 1] = file
		else
			local removed_file = true
			if file.path then
				local removed, _, errno = _deps.remove(file.path)
				removed_file = removed or errno == 2 -- Already absent after an interrupted write.
			end
			local removed_dir = _deps.remove(file.dir)
			if not removed_file or not removed_dir then
				Logger.warn(LOG, "A temporary calendar file could not be deleted; it is retried later.")
				kept[#kept + 1] = file
			end
		end
	end
	_pending_files = kept
	return #kept == 0
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
	if _stopping then return {} end
	local now = _deps.clock()
	if _stopping then return {} end
	if _tools_cache and now - _tools_cache.at < TOOLS_TTL_SEC then return _tools_cache.names end
	local directory = _deps.tools_dir()
	if _stopping then return {} end
	local names, reason = _deps.list_executables(directory)
	if _stopping then return {} end
	local kept = {}
	local limit = config.max_tools
	if _stopping then return {} end
	if not names then
		Logger.warn(LOG, "The agent's tools could not be listed: %s.", tostring(reason))
	else
		table.sort(names)
		for _, name in ipairs(names) do
			if #kept >= limit then break end
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
local function start_tool(what, executable, args, timeout_ms, on_done)
	if _stopping then return false end
	local job = { what = what, done = on_done, constructing = true }
	_jobs[job] = true
	local called, operation, reason = pcall(_deps.run_tool, executable, args, {
		timeout_ms = timeout_ms, owner = "agent_connector:" .. tostring(job),
		authorized = function() return not _stopping and _jobs[job] == true end,
	}, function(result)
		job.result = result
		retire_job(job)
	end)
	job.constructing = false
	if not called then
		job.uncertain = true
		return false
	end
	if operation == nil then
		-- Only an explicit pre-acquisition refusal may return no native owner.
		_jobs[job] = nil
		if not _stopping then on_done(false, string.format("%s could not start: %s", what, tostring(reason))) end
		return false
	end
	job.operation = operation
	if type(operation) ~= "table" then job.uncertain = true; return false end
	job.cancel, job.is_settled = operation.cancel, operation.is_settled
	local subscribe = operation.on_settled
	if type(job.cancel) ~= "function" or type(job.is_settled) ~= "function" or type(subscribe) ~= "function" then
		job.uncertain = true
		return false
	end
	local registered, accepted = pcall(subscribe, operation, function() retire_job(job) end)
	if not registered or accepted ~= true then job.uncertain = true end
	if _stopping then pcall(job.cancel, operation) end
	retire_job(job)
	return not _stopping and not job.uncertain and operation.started == true and operation.error == nil
end

--- Keeps the established desktop handoff; accepted GUI applications may outlive
--- their launcher. These logical records only protect .ics inputs and callbacks;
--- shutdown() does not claim physical retirement of desktop process groups.
--- @param executable string Desktop launcher name.
--- @param args table Launcher arguments.
--- @param on_done function Completion receiver, fenced by the action frame.
--- @return boolean started
local function start_desktop(executable, args, on_done)
	if _stopping then return false end
	local job = {}
	_desktop_jobs[job] = true
	local called, operation, reason = pcall(_deps.run, executable, args, { timeout_ms = OPEN_TIMEOUT_MS }, function(result)
		if not _desktop_jobs[job] then return end
		_desktop_jobs[job] = nil
		if _stopping then M.cleanup(); return end
		local ok = type(result) == "table" and result.ok == true
		local detail = not ok and string.format("%s failed: %s", executable,
			tostring(type(result) == "table" and (result.error or ("exit code " .. tostring(result.code))) or result)) or nil
		on_done(ok, detail)
	end)
	if not called then error(operation, 0) end
	if operation == nil then
		_desktop_jobs[job] = nil
		if not _stopping then on_done(false, string.format("%s could not start: %s", executable, tostring(reason))) end
		return false
	end
	job.operation = operation
	return not _stopping
end

--- Hands a calendar event or a reminder to the default calendar application.
--- @param config table Decoded agent.json.
--- @param action table A validated calendar or reminder action.
--- @param on_done function
--- @return boolean started
local function open_ics(config, action, on_done, frame)
	M.cleanup()
	if _stopping then return false end
	local hex = _deps.random_hex()
	if _stopping then return false end
	if not hex then
		on_done(false, "no random identifier could be drawn")
		return false
	end
	local content = Agent.ics(config, action, hex .. "@ergopti", _deps.utc_stamp())
	if _stopping then return false end
	local dir = _deps.private_dir()
	if not dir then
		on_done(false, "no private directory could be created")
		return false
	end
	-- Own the directory immediately, including a stop while its constructor
	-- returns. The file becomes ours before a write can partially create it.
	local pending = { dir = dir, preparing = frame }
	_pending_files[#_pending_files + 1] = pending
	if _stopping then return false end
	local path = dir .. "/" .. (action.type == "calendar" and "event" or "task") .. ".ics"
	if _stopping then return false end
	pending.path = path
	local written = _deps.write_file(path, content)
	if _stopping then return false end
	if not written then
		M.cleanup()
		on_done(false, "the calendar file could not be written")
		return false
	end
	Logger.info(LOG, "Opening a %s entry with the default calendar application.", action.type)
	if _stopping then return false end
	return start_desktop("xdg-open", { path }, on_done)
end

--- Opens a mail draft in the user's mail client. Never sends.
--- @param action table A validated mail action.
--- @param on_done function
--- @return boolean started
local function open_mail(action, on_done)
	local has_email = _deps.has_command("xdg-email")
	if _stopping then return false end
	if has_email then
		local args = { "--utf8" }
		if action.subject then
			args[#args + 1] = "--subject"
			args[#args + 1] = action.subject
		end
		args[#args + 1] = "--body"
		args[#args + 1] = action.body
		for _, address in ipairs(action.to or {}) do args[#args + 1] = address end
		if _stopping then return false end
		Logger.info(LOG, "Opening a mail draft through xdg-email (%d recipient(s)).", #(action.to or {}))
		if _stopping then return false end
		return start_desktop("xdg-email", args, on_done)
	end
	local link = Agent.mailto(action)
	if _stopping then return false end
	Logger.info(LOG, "Opening a mail draft through a mailto: link (xdg-email is not installed).")
	if _stopping then return false end
	return start_desktop("xdg-open", { link }, on_done)
end

--- Runs one of the user's tools with the action's input as its only argument.
--- @param config table Decoded agent.json.
--- @param action table A validated shortcut action.
--- @param on_done function
--- @return boolean started
local function run_tool(config, action, on_done)
	local name = action.name
	if _stopping then return false end
	local known = false
	for _, candidate in ipairs(M.tools(config)) do
		if candidate == name then known = true end
	end
	if _stopping then return false end
	if not known then
		on_done(false, "the tool is no longer in the tools folder")
		return false
	end
	local input = action.input
	local directory = _deps.tools_dir()
	if _stopping then return false end
	Logger.info(LOG, "Running an agent tool (%s an input).", input and "with" or "without")
	if _stopping then return false end
	return start_tool("the tool", directory .. "/" .. name, input and { input } or {}, TOOL_TIMEOUT_MS, on_done)
end

--- Carries out one validated action. on_done(ok, reason) is called once;
--- reason names the failure for the log and never holds the user's text.
--- @param config table Decoded agent.json.
--- @param action table A validated action (agent.parse_actions).
--- @param on_done function
--- @return boolean started
function M.run(config, action, on_done)
	if _stopping then return false end
	if type(on_done) ~= "function" then error("agent_connectors.run: on_done must be a function", 2) end
	if type(action) ~= "table" then error("agent_connectors.run: an action is required", 2) end
	_admissions = _admissions + 1
	local frame, completed, outcome = { active = true }, false, nil
	local function receive(ok, reason)
		if _stopping or completed then return end
		completed = true
		if frame.active then outcome = { ok = ok, reason = reason }; return end
		on_done(ok, reason)
	end
	local called, result = pcall(function()
		local kind = action.type
		if _stopping then return false end
		if kind == "calendar" or kind == "reminder" then return open_ics(config, action, receive, frame) end
		if kind == "mail" then return open_mail(action, receive) end
		if kind == "shortcut" then return run_tool(config, action, receive) end
		error("agent_connectors.run: unknown action type " .. tostring(kind), 2)
	end)
	frame.active = false
	_admissions = _admissions - 1
	if _stopping then M.shutdown() elseif not called or result ~= true then M.cleanup() end
	if not called then error(result, 0) end
	if _stopping then return false end
	if outcome then
		local delivered = pcall(on_done, outcome.ok, outcome.reason)
		if not delivered then pcall(Logger.error, LOG, "Agent connector completion callback failed.") end
	end
	return result
end

--- Closes action admission before cancelling tools and retaining close debt.
--- Only user tools receive physical process-group retirement here. Desktop
--- launchers retain their existing handoff and can leave temporary calendar
--- inputs until their logical completion; neither FileConsumed nor GUI process
--- retirement is claimed. File deletion keeps its best-effort retry policy.
--- @return boolean acknowledged Every user tool exit, group absence and close ACK.
function M.shutdown()
	_stopping = true
	if _checking_shutdown then return false end
	_checking_shutdown = true
	local captured = {}
	for job in pairs(_jobs) do captured[#captured + 1] = job end
	for _, job in ipairs(captured) do
		if _jobs[job] and job.operation and type(job.cancel) == "function" then
			pcall(job.cancel, job.operation)
			retire_job(job)
		end
	end
	if _admissions > 0 or next(_jobs) ~= nil then _checking_shutdown = false; return false end
	local cleaned = pcall(M.cleanup)
	_checking_shutdown = false
	return cleaned
end

--- Replaces OS boundaries (tests). Missing ones keep their defaults.
--- @param deps table|nil nil restores every default.
function M._set_deps_for_test(deps)
	if _admissions > 0 or next(_jobs) ~= nil or next(_desktop_jobs) ~= nil then error("agent connectors still own cleanup debt", 2) end
	if deps == nil then
		_deps = DEFAULT_DEPS
	else
		_deps = setmetatable(deps, { __index = DEFAULT_DEPS })
	end
	_pending_files = {}
	_tools_cache = nil
end

return M
