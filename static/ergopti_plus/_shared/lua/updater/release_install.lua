--- _shared/lua/updater/release_install.lua

--- ==============================================================================
--- MODULE: Release Install From the Versions Window (Shared)
--- DESCRIPTION:
--- Sequences the one-click install of a chosen release that the Versions page
--- asks for (install_release): back the configuration up, find the release's
--- asset for this system, download and verify it through the driver's updater,
--- install it through the driver's update path and restart. Each phase is
--- reported to the page; a refusal or a failure ends the sequence visibly and
--- keeps the backup. The macOS and Linux Versions hosts run it with their own
--- ports; Windows mirrors the same order in windows/modules/updater/release_install.ahk.
---
--- FEATURES & RATIONALE:
--- 1. Only a click starts it: install() is the bridge handler's, and nothing in
---    the updater's schedule reaches it.
--- 2. Backup first: nothing is downloaded before the configuration is backed
---    up, and a failed backup refuses the whole install.
--- 3. No step is skipped: a release without this system's asset, a download
---    that fails its integrity check or an install refusal stops there, and
---    the next step never runs. There is no fallback source or unverified path.
--- 4. One install at a time: a second request while one runs is refused as busy.
--- 5. Pure Lua: every effect is a port.
--- ==============================================================================

local M = {}

-- Remains monotonic when a native window creates a new install session.
local operation_serial, failure_serial = 0, 0

-- The page's reason keys, one per way the install can stop.
M.REASON = {
	busy = "changelog_window.install_error_busy",
	unexpected = "changelog_window.install_error_unexpected",
	backup = "changelog_window.install_error_backup",
	no_asset = "changelog_window.install_error_no_asset",
	download = "changelog_window.install_error_download",
	verify = "changelog_window.install_error_verify",
	install = "changelog_window.install_error_install",
	unknown_release = "changelog_window.install_error_unknown_release",
	no_details = "changelog_window.install_error_no_details",
}

local KNOWN_REASON = {}
for _, key in pairs(M.REASON) do KNOWN_REASON[key] = true end

--- Creates the install session of one driver.
--- @param ports table {
---   blocked() -> reason_key|nil (a source run, a system package),
---   find_release(tag, channel) -> release|nil, reason_key,
---   backup(release) -> record|nil, error (record.path is shown to the user),
---   resolve_asset(release) -> asset|nil,
---   download(asset, release, done(path|nil, reason_key, detail, failure_receipt?)) -> dispatched,
---   install(path, release, asset) -> true | false, reason_key, detail,
---   restart(release) -> true | false,
---   report(message, native_owner?) -- safe public message plus optional PRIVATE native owner,
---   failure_contract?() -> canonical network.failure interpreter,
---   acceptance_owner?(tag, channel) -> private pre-acceptance snapshot,
---   acceptance_current?(owner) -> original owner still admits native work,
---   failure_owner?(release) -> private native snapshot,
---   failure_current?(owner) -> true only for that exact live native owner,
---   failure_capabilities?(owner) -> actual available native actions,
---   failure_action?(id, owner) -> true only after real native dispatch,
---   logger, log }
--- @return table session { install(tag, channel), busy() }
function M.new(ports)
	assert(type(ports) == "table", "release_install needs its ports")
	for _, name in ipairs({ "blocked", "find_release", "backup", "resolve_asset", "download", "install",
		"restart", "report" }) do
		assert(type(ports[name]) == "function", "release_install needs the " .. name .. " port")
	end
	local Logger, LOG = ports.logger, ports.log or "release_install"
	assert(type(Logger) == "table", "release_install needs a logger")

	local running, terminal, last_operation = nil, nil, nil
	local retired, retirement_revision = false, 0
	local session = {}

	local function owner_current(current)
		if retired or terminal ~= current or running ~= nil
			or type(ports.failure_current) ~= "function" then return false end
		local native = ports.failure_current(current.native_owner) == true
		-- A native capability probe can reenter and retire this operation.
		return native and not retired and terminal == current and running == nil
	end

	local function capabilities(current)
		local alive = owner_current(current) and not ports.blocked()
		local native = type(ports.failure_capabilities) == "function"
			and ports.failure_capabilities(current.native_owner) or {}
		local out = {}
		if type(native) == "table" then
			for key, value in pairs(native) do out[key] = value == true end
		end
		alive = alive and owner_current(current)
		out.owner_alive, out.retry_available = alive == true, alive == true
		return out
	end

	--- Sends one phase to the page, never letting a page failure unwind here.
	--- @param message table
	local function report(message, operation)
		if operation and (retired or last_operation ~= operation) then return false end
		local retained = operation or running or terminal
		local native_owner = retained and retained.native_owner or nil
		local ok, err = pcall(ports.report, message, native_owner)
		if not ok then Logger.error(LOG, "The Versions page could not be told the install phase: %s.", tostring(err)) end
	end

	--- Ends the running install with a failure the page shows.
	--- @param tag string
	--- @param reason string Locale key.
	--- @param backup table|nil The backup made before the failure.
	local function fail(tag, reason, backup, receipt, current)
		local operation = current or running
		if not operation or running ~= operation or last_operation ~= operation then return end
		if not KNOWN_REASON[reason] then reason = M.REASON.unexpected end
		running = nil
		local function publication_current()
			return not retired and last_operation == operation and running == nil
		end
		local message = { tag = tag, phase = "failed", reason_key = reason, backup_path = backup and backup.path or nil }
		if reason == M.REASON.download and current and type(ports.failure_contract) == "function" then
			message.managed_failure = true
			local ok, contract = pcall(ports.failure_contract)
			-- Loading or inspecting native policy may start another operation.
			if not publication_current() then return end
			if ok and type(contract) == "table" then
				failure_serial = failure_serial + 1
				current.epoch, current.contract = failure_serial, contract
				-- Never publish the native receipt, release, owner or detail to the page.
				current.receipt = type(receipt) == "table" and receipt or {}
				terminal = current
				local classified, safe = pcall(function()
					return contract.classify(current.receipt, capabilities(current))
				end)
				if not publication_current() or terminal ~= current then return end
				if classified then
					current.failure_report = safe
					message.operation, message.failure_epoch = current.id, current.epoch
					message.failure_report = safe
				else
					if terminal == current then terminal = nil end
					Logger.error(LOG, "Managed-network native capability inspection failed; no failure actions admitted.")
				end
			else
				Logger.error(LOG, "The canonical managed-network policy is unavailable; no failure actions admitted.")
			end
		end
		-- Logging may invoke a native observer; never publish into its successor.
		if not publication_current() then return end
		report(message, operation)
	end

	--- Whether an install is running.
	--- @return boolean
	function session.busy() return running ~= nil end

	--- Installs one release the user clicked.
	--- @param tag any Release tag posted by the page.
	--- @param channel any Registry channel the page listed it on.
	--- @return boolean started True when the backup and the download began.
	function session.install(tag, channel)
		if type(tag) ~= "string" or tag == "" then
			Logger.error(LOG, "Refused an install request without a release tag.")
			return false
		end
		if running then
			Logger.warn(LOG, "Refused to install %s while %s is being installed.", tag, running.tag)
			report({ tag = tag, phase = "failed", reason_key = M.REASON.busy })
			return false
		end
		local reservation, admission_revision = last_operation, retirement_revision
		local function unreserved()
			return running == nil and last_operation == reservation and retirement_revision == admission_revision
		end
		local admission_owner, guarded = nil, ports.acceptance_owner ~= nil or ports.acceptance_current ~= nil
		if guarded then
			if type(ports.acceptance_owner) ~= "function" or type(ports.acceptance_current) ~= "function" then return false end
			local captured, native_owner = pcall(ports.acceptance_owner, tag, channel)
			if not captured or not unreserved() then return false end
			admission_owner = native_owner
		end
		local function admission_current()
			if not unreserved() then return false end
			if not guarded then return true end
			local inspected, current = pcall(ports.acceptance_current, admission_owner)
			return inspected and current == true and unreserved()
		end
		if not admission_current() then return false end
		local blocked = ports.blocked()
		if not admission_current() then return false end
		if blocked then
			-- The page greys its buttons for this reason; a request anyway is a stale page.
			Logger.error(LOG, "Refused to install %s: this build cannot install a release (%s).", tag, blocked)
			if not admission_current() then return false end
			report({ tag = tag, phase = "failed", reason_key = M.REASON.unexpected })
			return false
		end
		local release, missing = ports.find_release(tag, channel)
		if not admission_current() then return false end
		if not release then
			Logger.error(LOG, "Refused to install %s: it is not in the release list the window loaded.", tag)
			if not admission_current() then return false end
			report({ tag = tag, phase = "failed", reason_key = missing or M.REASON.unknown_release })
			return false
		end

		terminal, retired = nil, false
		operation_serial = operation_serial + 1
		running = { tag = tag, channel = channel, id = operation_serial }
		local current = running
		last_operation = current
		-- Page retirement revokes presentation; an accepted native transaction
		-- still follows its existing backup/install/restart semantics.
		local function execution_current() return running == current and last_operation == current end
		-- Reserve private identity before consulting a reentrant native owner.
		if type(ports.failure_owner) == "function" then
			local owner_ok, native_owner = pcall(ports.failure_owner, release)
			if not owner_ok then
				if running == current then running = nil end
				Logger.error(LOG, "The Versions native failure owner could not be inspected.")
				if not retired and last_operation == current and running == nil then
					report({ tag = tag, phase = "failed", reason_key = M.REASON.unexpected }, current)
				end
				return false
			end
			current.native_owner = native_owner
		end
		if guarded then
			local inspected, native_current = pcall(ports.acceptance_current, admission_owner)
			if not inspected or native_current ~= true or retirement_revision ~= admission_revision then
				if running == current then running = nil end
				return false
			end
		end
		if running ~= current or last_operation ~= current or retired then
			if running == current then running = nil end
			return false
		end
		Logger.start(LOG, "Installing %s from the Versions window (channel %s)…", tag, tostring(channel))
		if not execution_current() then return false end
		report({ tag = tag, phase = "backing_up" }, current)
		if not execution_current() then return false end
		local ok_backup, backup, backup_err = pcall(ports.backup, release)
		if not execution_current() then return false end
		if not ok_backup or not backup then
			Logger.error(LOG, "Install of %s refused: the configuration backup failed (%s).", tag,
				tostring(ok_backup and backup_err or backup))
			fail(tag, M.REASON.backup, nil, nil, current)
			return false
		end
		local asset = ports.resolve_asset(release)
		if not execution_current() then return false end
		if not asset then
			Logger.error(LOG, "Install of %s refused: the release has no asset for this system.", tag)
			fail(tag, M.REASON.no_asset, backup, nil, current)
			return false
		end

		report({ tag = tag, phase = "downloading", backup_path = backup.path }, current)
		if not execution_current() then return false end
		local settled = false
		local function done(path, reason, detail, failure_receipt)
			if settled or not execution_current() then return end
			settled = true
			if not path then
				Logger.error(LOG, "Install of %s stopped before installing: %s.", tag, tostring(detail or reason))
				fail(tag, reason == M.REASON.verify and M.REASON.verify or M.REASON.download, backup, failure_receipt, current)
				return
			end
			report({ tag = tag, phase = "installing", backup_path = backup.path }, current)
			if not execution_current() then return end
			local ok_install, installed, install_reason, install_detail = pcall(ports.install, path, release, asset)
			if not execution_current() then return end
			if not ok_install or installed ~= true then
				Logger.error(LOG, "Install of %s failed: %s.", tag,
					tostring(ok_install and (install_detail or install_reason) or installed))
				fail(tag, ok_install and install_reason or M.REASON.install, backup, nil, current)
				return
			end
			Logger.success(LOG, "Release %s installed; restarting on it.", tag)
			if not execution_current() then return end
			report({ tag = tag, phase = "restarting", backup_path = backup.path }, current)
			if not execution_current() then return end
			local ok_restart, restarted = pcall(ports.restart, release)
			if not execution_current() then return end
			if not ok_restart or restarted ~= true then
				Logger.error(LOG, "Release %s is installed but the restart failed: %s.", tag,
					tostring(ok_restart and "refused" or restarted))
				fail(tag, M.REASON.install, backup, nil, current)
			end
		end
		local ok_dispatch, dispatched = pcall(ports.download, asset, release, done)
		if not ok_dispatch or dispatched ~= true then
			if not settled then
				Logger.error(LOG, "Install of %s stopped: the download could not start (%s).", tag,
					tostring(ok_dispatch and "refused" or dispatched))
				settled = true
				fail(tag, M.REASON.download, backup, nil, current)
			end
			return false
		end
		return true
	end

	--- Dispatches only an action of the exact native terminal operation.
	function session.failure_action(operation, epoch, id)
		local current = terminal
		if not current or operation ~= current.id or epoch ~= current.epoch
			or type(id) ~= "string" or not owner_current(current) then return false end
		local admitted = false
		for _, action in ipairs(current.contract.actions(current.failure_report.cause, capabilities(current))) do
			if action.id == id then admitted = true end
		end
		if not admitted or not owner_current(current) or current.epoch ~= epoch then return false end
		if id == "retry" then
			-- Retire this terminal before synchronous dispatch can publish a newer failure.
			terminal = nil
			return session.install(current.tag, current.channel)
		end
		return type(ports.failure_action) == "function" and ports.failure_action(id, current.native_owner) == true
	end

	--- Retires page action authority; an already running native install is unchanged.
	function session.retire()
		retirement_revision = retirement_revision + 1
		retired, terminal = true, nil
	end

	return session
end

return M
