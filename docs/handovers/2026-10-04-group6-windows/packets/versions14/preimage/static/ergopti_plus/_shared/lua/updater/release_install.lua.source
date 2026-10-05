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
---   download(asset, release, done(path|nil, reason_key, detail)) -> dispatched,
---   install(path, release, asset) -> true | false, reason_key, detail,
---   restart(release) -> true | false,
---   report(message) -- { tag, phase, reason_key?, backup_path? },
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

	local running = nil
	local session = {}

	--- Sends one phase to the page, never letting a page failure unwind here.
	--- @param message table
	local function report(message)
		local ok, err = pcall(ports.report, message)
		if not ok then Logger.error(LOG, "The Versions page could not be told the install phase: %s.", tostring(err)) end
	end

	--- Ends the running install with a failure the page shows.
	--- @param tag string
	--- @param reason string Locale key.
	--- @param backup table|nil The backup made before the failure.
	local function fail(tag, reason, backup)
		if not KNOWN_REASON[reason] then reason = M.REASON.unexpected end
		running = nil
		report({ tag = tag, phase = "failed", reason_key = reason, backup_path = backup and backup.path or nil })
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
		local blocked = ports.blocked()
		if blocked then
			-- The page greys its buttons for this reason; a request anyway is a stale page.
			Logger.error(LOG, "Refused to install %s: this build cannot install a release (%s).", tag, blocked)
			report({ tag = tag, phase = "failed", reason_key = M.REASON.unexpected })
			return false
		end
		local release, missing = ports.find_release(tag, channel)
		if not release then
			Logger.error(LOG, "Refused to install %s: it is not in the release list the window loaded.", tag)
			report({ tag = tag, phase = "failed", reason_key = missing or M.REASON.unknown_release })
			return false
		end

		running = { tag = tag }
		local current = running
		Logger.start(LOG, "Installing %s from the Versions window (channel %s)…", tag, tostring(channel))
		report({ tag = tag, phase = "backing_up" })
		local ok_backup, backup, backup_err = pcall(ports.backup, release)
		if not ok_backup or not backup then
			Logger.error(LOG, "Install of %s refused: the configuration backup failed (%s).", tag,
				tostring(ok_backup and backup_err or backup))
			fail(tag, M.REASON.backup, nil)
			return false
		end
		local asset = ports.resolve_asset(release)
		if not asset then
			Logger.error(LOG, "Install of %s refused: the release has no asset for this system.", tag)
			fail(tag, M.REASON.no_asset, backup)
			return false
		end

		report({ tag = tag, phase = "downloading", backup_path = backup.path })
		local settled = false
		local function done(path, reason, detail)
			if settled or running ~= current then return end
			settled = true
			if not path then
				Logger.error(LOG, "Install of %s stopped before installing: %s.", tag, tostring(detail or reason))
				fail(tag, reason == M.REASON.verify and M.REASON.verify or M.REASON.download, backup)
				return
			end
			report({ tag = tag, phase = "installing", backup_path = backup.path })
			local ok_install, installed, install_reason, install_detail = pcall(ports.install, path, release, asset)
			if not ok_install or installed ~= true then
				Logger.error(LOG, "Install of %s failed: %s.", tag,
					tostring(ok_install and (install_detail or install_reason) or installed))
				fail(tag, ok_install and install_reason or M.REASON.install, backup)
				return
			end
			Logger.success(LOG, "Release %s installed; restarting on it.", tag)
			report({ tag = tag, phase = "restarting", backup_path = backup.path })
			local ok_restart, restarted = pcall(ports.restart, release)
			if not ok_restart or restarted ~= true then
				Logger.error(LOG, "Release %s is installed but the restart failed: %s.", tag,
					tostring(ok_restart and "refused" or restarted))
				fail(tag, M.REASON.install, backup)
			end
		end
		local ok_dispatch, dispatched = pcall(ports.download, asset, release, done)
		if not ok_dispatch or dispatched ~= true then
			if not settled then
				Logger.error(LOG, "Install of %s stopped: the download could not start (%s).", tag,
					tostring(ok_dispatch and "refused" or dispatched))
				settled = true
				fail(tag, M.REASON.download, backup)
			end
			return false
		end
		return true
	end

	return session
end

return M
