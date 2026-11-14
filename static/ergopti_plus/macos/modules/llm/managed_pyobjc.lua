--- modules/llm/managed_pyobjc.lua

--- ==============================================================================
--- MODULE: Managed PyObjC For App Cloner
--- DESCRIPTION:
--- Owns the PyObjC that App Cloner's helpers and the launchers it writes need,
--- installed into Ergopti's managed Python instead of read from /usr/bin/python3
--- (owned_runtimes.json, the macOS /usr/bin/python3 row). Readiness is a stat
--- of the versionless link the installer publishes; the install runs
--- ensure-managed-pyobjc.sh under the signed native PTY guardian, as the AI
--- installers do, and only when a caller that holds the user's consent asks.
---
--- FEATURES & RATIONALE:
--- 1. Stat-Only Readiness: the menu asks while it builds, so ready() spawns
---    nothing; App Cloner's own start runs the import check.
--- 2. Guardian-Owned Install: the guardian runs only the installers it names
---    (ManagedPTYWorker.admittedSourceNames) and returns a physical retirement
---    receipt, settled before the result is reported.
--- 3. One Install At A Time: callers that ask while one runs wait for it.
--- 4. Ports Only: every effect goes through the ports given to `new`.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")

local LOG = "llm.managed_pyobjc"

--- The versionless link the installer publishes, as a tilde path.
M.LINK = "~/" .. require("core.fs.engine.app_dirs").macos.support_relative .. "/native-bootstrap/app-cloner/python3"

--- The installer, relative to the driver folder.
M.INSTALLER = "modules/llm/ensure-managed-pyobjc.sh"

--- Stable reasons of a refused install.
M.REASON = {
	PREPARE = "pyobjc_prepare_refused",
	START = "pyobjc_start_refused",
	FAILED = "pyobjc_install_failed",
	RECEIPT = "pyobjc_receipt_refused",
	OUTPUT = "pyobjc_output_refused",
}
local REASON = M.REASON

--- Reads the installer's success line.
--- @param stdout any The installer's standard output.
--- @param link string The absolute link it must name.
--- @return boolean ready
function M.ready_line(stdout, link)
	if type(stdout) ~= "string" then return false end
	for line in stdout:gmatch("[^\r\n]+") do
		if line == "PYOBJC_READY\t" .. link then return true end
	end
	return false
end

--- Creates the owner bound to its ports.
--- Port contracts:
---   expand(path) -> absolute path; exists(path) -> boolean (follows the link);
---   driver_root() -> absolute driver folder; timeout_ms() -> guardian budget;
---   prepare(source, environment, timeout_ms) -> handle, prepared (native_bootstrap_pty);
---   task(executable, arguments, on_exit) -> task|nil; start(task) -> boolean.
--- @param ports table
--- @return table owner { link, ready, install }.
function M.new(ports)
	assert(type(ports) == "table", "Missing managed PyObjC ports")
	for _, name in ipairs({ "expand", "exists", "driver_root", "timeout_ms", "prepare", "task", "start" }) do
		assert(type(ports[name]) == "function", "Missing managed PyObjC port: " .. name)
	end
	local owner = {}
	local waiters

	--- Settles every waiter once.
	local function settle(ok, value)
		local pending = waiters
		waiters = nil
		if ok then
			Logger.success(LOG, "Managed PyObjC ready for App Cloner.")
		else
			Logger.error(LOG, "Managed PyObjC install refused (%s).", tostring(value))
		end
		for _, waiter in ipairs(pending or {}) do
			local called, failure = pcall(waiter, ok, value)
			if not called then Logger.error(LOG, "Managed PyObjC callback failed: %s.", tostring(failure)) end
		end
	end

	--- The absolute stable link.
	--- @return string link
	function owner.link()
		return ports.expand(M.LINK)
	end

	--- Whether the managed interpreter with PyObjC is installed (stat only).
	--- @return boolean ready
	function owner.ready()
		return ports.exists(owner.link()) == true
	end

	--- Installs PyObjC under the guardian. The caller holds the user's consent.
	--- @param callback function fn(ok, link|reason) called once.
	function owner.install(callback)
		assert(type(callback) == "function", "Missing managed PyObjC callback")
		if waiters then
			waiters[#waiters + 1] = callback
			return
		end
		waiters = { callback }
		local link = owner.link()
		Logger.start(LOG, "Installing the managed PyObjC for App Cloner…")
		local handle, prepared = ports.prepare(ports.driver_root() .. "/" .. M.INSTALLER, {}, ports.timeout_ms())
		if prepared ~= true or type(handle) ~= "table" then
			if type(handle) == "table" then handle.rollback() end
			return settle(false, REASON.PREPARE)
		end
		local task = ports.task(handle.executable, handle.arguments, function(code, stdout)
			if handle.settle(code) ~= true then return settle(false, REASON.RECEIPT) end
			if code ~= 0 then return settle(false, REASON.FAILED) end
			if not M.ready_line(stdout, link) or not owner.ready() then return settle(false, REASON.OUTPUT) end
			settle(true, link)
		end)
		if not task or handle.bind_input(task) ~= true then
			handle.rollback()
			return settle(false, REASON.START)
		end
		if handle.mark_start_attempted() ~= true or ports.start(task) ~= true then
			-- An attempted start owns the receipt; settle reports its retirement.
			if handle.settle(-1) ~= true then Logger.error(LOG, "The refused PyObjC start left its receipt owned.") end
			return settle(false, REASON.START)
		end
	end

	return owner
end

-- Live install tasks, pinned until their exit callback: an hs.task held only
-- by a local is collected and SIGTERMed with no callback.
M._active_tasks = {}

local default_owner

--- The owner bound to the real Mac, built once.
--- @return table owner
function M.default()
	if default_owner then return default_owner end
	local FileSystem = require("core.fs.adapters.file_system")
	local TaskLifecycle = require("adapters.task_lifecycle")
	local origin = debug.getinfo(1, "S").source
	local driver = type(origin) == "string" and origin:match("^@(.*)/modules/llm/managed_pyobjc%.lua$")
	assert(type(driver) == "string" and driver:sub(1, 1) == "/", "the driver folder of managed_pyobjc.lua is unknown")
	default_owner = M.new({
		expand = FileSystem.expand_path,
		exists = FileSystem.exists,
		driver_root = function() return driver end,
		timeout_ms = function() return require("infra.timings").ms("llm", "dependency_bootstrap_timeout_ms") end,
		prepare = function(source, environment, timeout_ms)
			return require("adapters.native_bootstrap_pty").prepare(source, environment, timeout_ms)
		end,
		task = function(executable, arguments, on_exit)
			local task
			task = TaskLifecycle.native("Managed PyObjC install", executable, function(code, stdout, stderr)
				if task then M._active_tasks[task] = nil end
				on_exit(code, stdout, stderr)
			end, arguments)
			if task then M._active_tasks[task] = true end
			return task
		end,
		start = function(task)
			if not TaskLifecycle.start(task, "Managed PyObjC install") then
				M._active_tasks[task] = nil
				return false
			end
			return true
		end,
	})
	return default_owner
end

return M
