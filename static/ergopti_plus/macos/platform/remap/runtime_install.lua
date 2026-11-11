--- platform/remap/runtime_install.lua

--- ==============================================================================
--- MODULE: Owned Runtime First Install
--- DESCRIPTION:
--- Installs Ergopti's own Karabiner runtime on this Mac after the user
--- confirmed it (ADR 011, WP8): the signed launcher's
--- `--request-owned-runtime-install` role stages the installer helper of the
--- verified download behind the macOS administrator prompt, the helper
--- publishes the runtime, starts its Core service and loads the
--- VirtualHIDDevice daemon job (installing pqrs' driver package when none is
--- installed), then pqrs' manager asks macOS to activate the driver.
---
--- FEATURES & RATIONALE:
--- 1. One Answer Line: the launcher prints exactly one line; anything else is
---    `install_unanswered`, never a guessed success.
--- 2. Named Refusals: an unsigned launcher, a missing download, a closed
---    prompt, a refused or half-finished helper each have their own reason.
--- 3. A Cancelled Prompt Is Not An Error: closing it changes nothing.
--- 4. Activation Last: installing a DriverKit package only stages it; macOS
---    may still wait for the user's approval in System Settings, which the
---    owner then names as `virtual_hid_not_active`.
--- 5. One Install At A Time: callers that ask while one runs wait for it.
--- 6. Ports Only: every effect goes through the ports given to `new`.
--- 7. Service Repair (MRT-004): an already published runtime whose job is not
---    loaded has its own role, `--request-owned-runtime-repair`, because the
---    first install refuses an existing runtime by design. It installs no
---    driver package and requests no activation: it restarts the services of
---    the installed copy, and the next owner names any approval still due.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local Update = require("platform.remap.runtime_vhid_update")

local LOG = "remap.runtime_install"

--- The launcher role (OwnedRuntimeInstallMainOperation.swift).
M.FLAG = "--request-owned-runtime-install"

--- pqrs' daemon program, which the driver package installs
--- (OwnedVirtualHIDDaemonReportReference.daemonExecutable).
M.DAEMON = "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/"
	.. "Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon"

--- The administrator prompt, the helper and pqrs' installer together take as
--- long as the driver-only update's prompt and installer.
M.INSTALL_TIMEOUT_SEC = Update.INSTALL_TIMEOUT_SEC

--- pqrs' manager submits the activation request within one local step, as in
--- the driver-only update.
M.ACTIVATE_TIMEOUT_SEC = require("platform.remap.runtime_artifact_fetch").STEP_TIMEOUT_SEC

--- The helper's closed result values (OwnedRuntimeIdleServiceEntry.swift).
M.RESULT = {
	INSTALLED = "files-published-services-observed-staging-retired",
	CLEANUP_PENDING = "files-published-service-cleanup-pending",
}

--- The launcher's service repair role (OwnedRuntimeInstallMainOperation.swift Mode.repair).
M.REPAIR_FLAG = "--request-owned-runtime-repair"

--- The repair helper's closed result values (OwnedRuntimeServiceRepairEntry.swift).
M.REPAIR_RESULT = {
	REPAIRED = "service-repaired-observed",
	PENDING = "service-repair-pending",
}

--- Stable reasons of a refused install.
M.REASON = {
	LAUNCHER = "install_launcher_unavailable",
	REFUSED = "install_refused",
	CANCELLED = "install_cancelled",
	FAILED = "install_failed",
	CLEANUP_PENDING = "install_cleanup_pending",
	UNANSWERED = "install_unanswered",
	ACTIVATE = "install_activation_failed",
	-- pqrs' driver package could not be downloaded, verified or installed.
	DRIVER = "install_driver_failed",
	-- The facade refused to start: the owned runtime is not blocked by a missing install.
	NOT_OFFERED = "install_not_offered",
	-- The repair restarted part of the services and left the rest for a retry.
	REPAIR_PENDING = "repair_pending",
}
local REASON = M.REASON

-- The administrator shell's exit statuses the helper uses (InstallerMain.swift).
local HELPER_REFUSED = 77
local HELPER_CLEANUP = 75





-- =================================
-- =================================
-- ======= 1/ Answer Parsing =======
-- =================================
-- =================================

-- Each role's line kind and the helper results that settle it: true for the
-- full success, a reason and a detail for a half-finished one.
local KINDS = {
	install = {
		kind = "OWNED_RUNTIME_INSTALL",
		results = {
			[M.RESULT.INSTALLED] = true,
			[M.RESULT.CLEANUP_PENDING] = { REASON.CLEANUP_PENDING,
				"the runtime files were published but a service step did not finish" },
		},
		refused = "the staged helper failed its checks or refused the install (an earlier install is still on this Mac)",
	},
	repair = {
		kind = "OWNED_RUNTIME_REPAIR",
		results = {
			[M.REPAIR_RESULT.REPAIRED] = true,
			[M.REPAIR_RESULT.PENDING] = { REASON.REPAIR_PENDING,
				"a service of the installed runtime was restarted but another step did not finish" },
		},
		refused = "the staged helper failed its checks or refused the repair (the installed runtime is not this release's"
			.. " exact copy, or an owned service file is not Ergopti's own)",
	},
}

--- Reads one role's answer line.
--- @param role table KINDS entry.
--- @param code any Exit status.
--- @param stdout any Standard output.
--- @return boolean done, string|nil reason, string|nil detail
local function parse_role(role, code, stdout)
	local line = type(stdout) == "string" and stdout:match("^([^\n]*)\n?$") or nil
	if line == nil then return false, REASON.UNANSWERED, "no answer line" end
	local result = line:match("^" .. role.kind .. "|1|([%w%-]+)$")
	if result and code == 0 then
		local settled = role.results[result]
		if settled == true then return true end
		if settled then return false, settled[1], settled[2] end
		return false, REASON.UNANSWERED, "unknown helper result " .. result
	end
	local request = role.kind .. "_REQUEST|1|"
	if line == request .. "cancelled" then return false, REASON.CANCELLED, nil end
	local refused = line:match("^" .. request .. "refused|([%w_%-]+)$")
	if refused then return false, REASON.REFUSED, refused end
	local status, step = line:match("^" .. request .. "failed|(%-?[%w]+)|([%l_]+)$")
	if not status then status = line:match("^" .. request .. "failed|(%-?[%w]+)$") end
	if status then
		local number = math.tointeger(tonumber(status))
		if number == HELPER_REFUSED then
			return false, REASON.REFUSED, role.refused .. (step and (" at step " .. step) or "")
		end
		if number == HELPER_CLEANUP then return false, REASON.CLEANUP_PENDING, "the helper left cleanup pending" end
		if number == Update.EXIT_DIGEST or number == Update.EXIT_SIGNATURE then
			return false, REASON.DRIVER, "the kept VirtualHIDDevice package failed its "
				.. (number == Update.EXIT_DIGEST and "digest" or "signature") .. " check as root"
		end
		-- The staged program names the step that failed (field reports 2026-11-05 and 2026-11-06 had only "1").
		return false, REASON.FAILED, "administrator shell status " .. status .. (step and (" at step " .. step) or "")
	end
	return false, REASON.UNANSWERED, "unexpected answer: " .. line
end

--- Reads the install role's one answer line.
--- @param code any Exit status.
--- @param stdout any Standard output.
--- @return boolean installed True only for the helper's full success.
--- @return string|nil reason Stable reason when not installed.
--- @return string|nil detail The refusal or status the line names.
function M.parse(code, stdout)
	return parse_role(KINDS.install, code, stdout)
end

--- Reads the service repair role's one answer line (MRT-004).
--- @param code any Exit status.
--- @param stdout any Standard output.
--- @return boolean repaired True only when the helper observed every service.
--- @return string|nil reason Stable reason when not repaired.
--- @return string|nil detail The refusal or status the line names.
function M.parse_repair(code, stdout)
	return parse_role(KINDS.repair, code, stdout)
end





-- ==============================
-- ==============================
-- ======= 2/ Install Run =======
-- ==============================
-- ==============================

--- Creates an installer bound to its ports.
--- Port contracts:
---   launcher() -> executable|nil, detail, environment: the signed launcher (platform/remap/lease_helper.lua);
---   exec(executable, args, timeout, fn(code|nil, stdout, stderr), environment) runs one command;
---   exists(path) -> boolean;
---   fetch_driver(fn(ok, reason|nil, detail|nil)) downloads and verifies pqrs' pinned package into
---     Ergopti's folder (runtime_vhid_update.lua fetch), which the role installs when no driver is.
--- @param ports table launcher, exec, exists, fetch_driver.
--- @return table installer { install, repair }.
function M.new(ports)
	assert(type(ports) == "table", "Missing owned runtime install ports")
	for _, name in ipairs({ "launcher", "exec", "exists", "fetch_driver" }) do
		assert(type(ports[name]) == "function", "Missing owned runtime install port: " .. name)
	end
	local installer = {}
	local waiters
	local repair_waiters

	--- Settles every waiter of the running install once.
	local function settle(ok, reason, detail)
		local pending = waiters
		waiters = nil
		if ok then
			Logger.success(LOG, "Owned runtime installed and the driver activation requested.")
		elseif reason == REASON.CANCELLED then
			Logger.info(LOG, "Owned runtime install cancelled at the administrator prompt.")
		else
			Logger.error(LOG, "Owned runtime install refused (%s): %s", tostring(reason), tostring(detail))
		end
		for _, waiter in ipairs(pending or {}) do
			local called, failure = pcall(waiter, ok, reason, detail)
			if not called then Logger.error(LOG, "Owned runtime install callback failed: %s.", tostring(failure)) end
		end
	end

	--- Asks pqrs' manager to activate the driver the package staged.
	local function activate()
		if ports.exists(Update.MANAGER) ~= true then
			return settle(false, REASON.ACTIVATE, "pqrs' VirtualHIDDevice manager is not installed")
		end
		ports.exec(Update.MANAGER, { "activate" }, M.ACTIVATE_TIMEOUT_SEC, function(code, _, stderr)
			if code ~= 0 then
				return settle(false, REASON.ACTIVATE, "the manager answered status " .. tostring(code)
					.. ((type(stderr) == "string" and stderr ~= "") and (": " .. stderr:gsub("%s+$", "")) or ""))
			end
			settle(true)
		end)
	end

	--- Installs the owned runtime, then requests the driver's activation.
	--- @param callback function fn(ok, reason|nil, detail|nil) called once.
	function installer.install(callback)
		assert(type(callback) == "function", "Missing owned runtime install callback")
		if waiters then
			waiters[#waiters + 1] = callback
			return
		end
		if repair_waiters then
			-- The repair's helper holds the lifecycle lock; the install would only be refused behind it.
			local called, failure = pcall(callback, false, REASON.REFUSED, "a service repair is running")
			if not called then Logger.error(LOG, "Owned runtime install callback failed: %s.", tostring(failure)) end
			return
		end
		waiters = { callback }
		local executable, detail, environment = ports.launcher()
		if not executable then return settle(false, REASON.LAUNCHER, detail) end
		Logger.start(LOG, "Installing Ergopti's own Karabiner runtime on the user's request…")
		local function run_role()
			ports.exec(executable, { M.FLAG }, M.INSTALL_TIMEOUT_SEC, function(code, stdout)
				local installed, reason, why = M.parse(code, stdout)
				if not installed then return settle(false, reason, why) end
				activate()
			end, environment)
		end
		if ports.exists(M.DAEMON) == true then return run_role() end
		-- No pqrs driver yet: the role installs the pinned package in the same administrator prompt.
		ports.fetch_driver(function(fetched, reason, why)
			if fetched ~= true then
				return settle(false, REASON.DRIVER, tostring(reason) .. ": " .. tostring(why))
			end
			run_role()
		end)
	end

	--- Settles every waiter of the running repair once.
	local function settle_repair(ok, reason, detail)
		local pending = repair_waiters
		repair_waiters = nil
		if ok then
			Logger.success(LOG, "Owned runtime service repaired.")
		elseif reason == REASON.CANCELLED then
			Logger.info(LOG, "Owned runtime service repair cancelled at the administrator prompt.")
		else
			Logger.error(LOG, "Owned runtime service repair refused (%s): %s", tostring(reason), tostring(detail))
		end
		for _, waiter in ipairs(pending or {}) do
			local called, failure = pcall(waiter, ok, reason, detail)
			if not called then Logger.error(LOG, "Owned runtime service repair callback failed: %s.", tostring(failure)) end
		end
	end

	--- Restarts the services of the installed runtime (MRT-004).
	--- @param callback function fn(ok, reason|nil, detail|nil) called once.
	function installer.repair(callback)
		assert(type(callback) == "function", "Missing owned runtime repair callback")
		if repair_waiters then
			repair_waiters[#repair_waiters + 1] = callback
			return
		end
		if waiters then
			-- The install's own helper holds the lifecycle lock; the repair would only be refused behind it.
			local called, failure = pcall(callback, false, REASON.REFUSED, "an install is running")
			if not called then Logger.error(LOG, "Owned runtime service repair callback failed: %s.", tostring(failure)) end
			return
		end
		repair_waiters = { callback }
		local executable, detail, environment = ports.launcher()
		if not executable then return settle_repair(false, REASON.LAUNCHER, detail) end
		Logger.start(LOG, "Repairing the service of Ergopti's own Karabiner runtime on the user's request…")
		ports.exec(executable, { M.REPAIR_FLAG }, M.INSTALL_TIMEOUT_SEC, function(code, stdout)
			settle_repair(M.parse_repair(code, stdout))
		end, environment)
	end

	return installer
end

return M
