--- platform/remap/onboarding.lua

--- ==============================================================================
--- MODULE: Karabiner-Elements Onboarding
--- DESCRIPTION:
--- Detects the install state of Karabiner-Elements and guides the user through
--- any missing dependency (the app itself, the DriverKit System Extension,
--- the root grabber daemon, Input Monitoring permission) via a single
--- first-run wizard. Called by platform/remap/init.lua at boot time.
---
--- FEATURES & RATIONALE:
--- 1. Single source of truth for "is the KE stack ready?" — every dependency
---    has its own predicate (is_ke_app_installed / is_sysext_activated / etc.)
---    so the menu, the boot wizard, and the status indicator never disagree
---    about what is or isn't operational.
--- 2. Download-on-demand from the official pqrs-org GitHub release: the DMG
---    is fetched on first launch into ~/Library/Caches/Ergopti/karabiner-elements/,
---    SHA-256 verified against the version pinned in vendor/karabiner-elements/
---    manifest.lua, then auto-installed via the macOS admin-prompt pipeline.
---    Repo stays light, version is reproducible, and the cache makes future
---    reinstalls offline-capable.
--- 3. Async-only pipeline (hs.task): the 46 MB download and the privileged
---    installer step run as subprocesses with completion callbacks so
---    Hammerspoon's main loop is never blocked. The user can keep using HS
---    while the wizard works in the background.
--- 4. Permission deep-links: opens the exact System Settings panes for
---    Input Monitoring and System Extensions via x-apple.systempreferences URLs
---    so the user clicks one button rather than navigating Settings manually.
--- 5. macOS limits acknowledged: TCC and System Extension approvals require
---    explicit user clicks that no script can bypass. The wizard reduces
---    the friction to ~3 clicks total but never pretends to skip them.
--- 6. Exact timer ownership: polls and delayed continuations share one
---    generation-scoped slot so stop cannot leave a callback that reopens UI.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")
local i18n   = require("infra.i18n")
local text_utils = require("infra.text_utils")
local KePaths = require("platform.remap.ke_paths")
local TaskLifecycle = require("adapters.task_lifecycle")
local TimerScheduler = require("adapters.timer_scheduler")

-- Optional dependency: only used to surface user-friendly notifications.
-- Falls back to silent operation if the notifications lib is not present.
local ok_notif, Notifications = pcall(require, "infra.notifications")
if not ok_notif then Notifications = nil end

local LOG = "karabiner.onboarding"

-- GC-root table: every live hs.task is pinned here so Lua's garbage collector
-- cannot SIGTERM it mid-run (hs.task held only in a local is collected on return).
M._active_tasks = {}

-- One lifecycle epoch owns every poll, delayed continuation, and installer
-- completion spawned by the current wizard chain
local _wizard_epoch = 0
local _install_epoch = 0
local _timer_owner = nil
local run_wizard_step

-- Resolve our own directory at load time so the manifest lookup works whether
-- this file is symlinked, run from the project tree, or deployed elsewhere.
local _SELF_DIR = (debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./")

-- Path to the version-pinning manifest, relative to this module's location.
local MANIFEST_PATH = _SELF_DIR .. "../../vendor/karabiner-elements/manifest.lua"

-- Where the downloaded DMG is cached. Standard macOS cache location for
-- regenerable, app-specific data.
local CACHE_DIR = (os.getenv("HOME") or "") .. "/Library/Caches/Ergopti/karabiner-elements/"

-- Filesystem signposts revealing the install state of KE.
local KE_APP_PATH      = "/Applications/Karabiner-Elements.app"
-- Releases before v15.7 shipped karabiner_grabber under bin/; v15.7 moved the
-- renamed Karabiner-Core-Service executable into its own app bundle.
local KE_LEGACY_GRABBER_BIN = KePaths.GRABBER
local KE_CORE_SERVICE_BIN   = KePaths.CORE_SERVICE
-- karabiner_cli is present in all KE versions (v14-v16+) and never renamed,
-- making it the most reliable signal that the full PKG stack is installed.
local KE_CLI_BIN          = KePaths.CLI
local KE_SYSEXT_BUNDLE = "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice"

-- macOS deep-links into the relevant System Settings panes. The scheme is
-- stable across Ventura → Sequoia for these preference IDs.
-- Karabiner-Elements v16+ relies on Accessibility (per the v16.0.0 release
-- notes); pre-v16 versions rely on Input Monitoring instead. Both panes are
-- exposed so the wizard can route the user to the right one.
local URL_INPUT_MONITORING  = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
local URL_ACCESSIBILITY     = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
local URL_SYSTEM_EXTENSIONS = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?Extensions"

-- Re-poll cadence after the user takes a wizard action, so the next step
-- pops automatically once macOS reflects the change. Capped to avoid leaking
-- timer resources if the user never completes the action.
local POLL_INTERVAL_SEC = 3
local POLL_TIMEOUT_SEC  = 300
local INSTALL_SETTLE_DELAY_SEC = 2
local NEXT_STEP_DELAY_SEC = 1


--- File-existence test that does not pull in lfs (not available in HS by default).
--- @param path string Absolute path to test.
--- @return boolean
local function file_exists(path)
	if type(path) ~= "string" or path == "" then return false end
	local f = io.open(path, "r")
	if f then f:close() return true end
	return false
end

--- Surfaces a user notification, falling back to a no-op if lib.notifications
--- is not loaded in this deployment.
--- @param message string Single-line French text shown to the user.
--- @param kind string|nil "info" | "success" | "warning" | "error".
local function notify(message, kind)
	if not Notifications then return end
	pcall(function() Notifications.notify(message, nil, kind or "info") end)
end





-- ==========================================
-- ==========================================
-- ======= 1/ Vendor Manifest Loading =======
-- ==========================================
-- ==========================================

--- Loads the vendor manifest pinning the KE version + checksum + URL.
--- Returns nil and logs an error if the manifest is missing or malformed.
--- @return table|nil manifest
function M.load_manifest()
	local ok, manifest = pcall(dofile, MANIFEST_PATH)
	if not ok or type(manifest) ~= "table" then
		Logger.error(LOG, "Vendor manifest unreadable at '%s': %s.", MANIFEST_PATH, tostring(manifest))
		return nil
	end
	if type(manifest.version) ~= "string"
		or type(manifest.file_name) ~= "string"
		or type(manifest.sha256) ~= "string"
		or type(manifest.source_url) ~= "string" then
		Logger.error(LOG, "Vendor manifest missing required fields (version/file_name/sha256/source_url).")
		return nil
	end
	Logger.debug(LOG, "Manifest loaded: version=%s file=%s.", manifest.version, manifest.file_name)
	return manifest
end

--- Returns the absolute path where the cached DMG sits (or will sit) for the
--- given manifest. Does NOT verify the file is present.
--- @param manifest table Output of M.load_manifest().
--- @return string cache_path
function M.get_cache_dmg_path(manifest)
	return CACHE_DIR .. manifest.file_name
end

--- True when the manifest still has TODO placeholders, i.e. the maintainer
--- has not yet pinned a real KE version. Used to skip auto-install gracefully.
--- @param manifest table
--- @return boolean
function M.manifest_is_unpinned(manifest)
	return manifest.version == "TODO"
		or manifest.sha256  == "TODO"
		or manifest.file_name:find("TODO", 1, true) ~= nil
end





-- ==================================
-- ==================================
-- ======= 2/ State Detection =======
-- ==================================
-- ==================================

--- True when /Applications/Karabiner-Elements.app exists.
--- @return boolean
function M.is_ke_app_installed()
	return file_exists(KE_APP_PATH)
end

--- True when a KE daemon binary exists on disk, independent of run state.
--- Accepts the legacy name (karabiner_grabber), v15.7+ name (Karabiner-Core-Service),
--- or karabiner_cli (stable across all KE versions) so any upgrade permutation
--- returns true without needing to track every daemon rename going forward.
--- @return boolean
function M.is_grabber_binary_present()
	return file_exists(KE_LEGACY_GRABBER_BIN)
		or file_exists(KE_CORE_SERVICE_BIN)
		or file_exists(KE_CLI_BIN)
end

--- True when a Karabiner Core Service generation is currently running.
--- Defers to ke_lifecycle to keep a single canonical pgrep call across modules.
--- @return boolean
function M.is_grabber_running()
	local KeLifecycle = require("platform.remap.ke_lifecycle")
	return KeLifecycle.is_grabber_running()
end

--- True when the KE DriverKit System Extension is both activated and enabled
--- according to systemextensionsctl. A working entry shows the literal token
--- "activated enabled" on the same line as the bundle id.
--- @return boolean
function M.is_sysext_activated()
	local out, ok = hs.execute("/usr/bin/systemextensionsctl list 2>&1")
	if ok ~= true or type(out) ~= "string" then
		Logger.debug(LOG, "is_sysext_activated: systemextensionsctl ok=%s — assuming inactive.", tostring(ok))
		return false
	end
	for line in out:gmatch("[^\n]+") do
		if line:find(KE_SYSEXT_BUNDLE, 1, true) and line:find("activated enabled", 1, true) then
			return true
		end
	end
	return false
end

--- Returns a snapshot of every dependency in the KE stack with one boolean per
--- check. Caller can render a checklist or choose which step of the wizard to
--- launch. all_ok is true only when every dependency is satisfied.
--- @return table { ke_installed, grabber_present, grabber_running, sysext_activated, all_ok }
function M.health_check()
	local report = {
		ke_installed     = M.is_ke_app_installed(),
		grabber_present  = M.is_grabber_binary_present(),
		grabber_running  = M.is_grabber_running(),
		sysext_activated = M.is_sysext_activated(),
	}
	report.all_ok = report.ke_installed
		and report.grabber_present
		and report.grabber_running
		and report.sysext_activated
	Logger.debug(LOG,
		"Health check: ke=%s grabber_bin=%s grabber_run=%s sysext=%s all_ok=%s.",
		tostring(report.ke_installed), tostring(report.grabber_present),
		tostring(report.grabber_running), tostring(report.sysext_activated),
		tostring(report.all_ok))
	return report
end





-- ==============================================
-- ==============================================
-- ======= 3/ Cache and Download Pipeline =======
-- ==============================================
-- ==============================================

--- Verifies the SHA-256 of a local file against an expected hex digest. Async
--- so a slow shasum call cannot block Hammerspoon's main loop.
--- @param path string Absolute path of the file to hash.
--- @param expected_sha string Expected SHA-256, lowercase hex.
--- @param callback function fun(ok: boolean, err: string|nil)
local function verify_sha256_async(path, expected_sha, callback)
	local epoch = _install_epoch
	local task
	task = TaskLifecycle.native("Karabiner installer checksum", "/usr/bin/shasum", function(rc, stdout)
		if task then M._active_tasks[task] = nil end  -- task captured by closure; clears the GC-root pin
		if epoch ~= _install_epoch then return end
		if rc ~= 0 or type(stdout) ~= "string" then
			callback(false, "shasum exit code " .. tostring(rc))
			return
		end
		local actual = stdout:match("^([%x]+)")
		if not actual then
			callback(false, "Could not parse shasum output: " .. stdout)
			return
		end
		if actual:lower() ~= expected_sha:lower() then
			callback(false, string.format("expected=%s actual=%s", expected_sha, actual))
			return
		end
		callback(true, nil)
	end, { "-a", "256", path })
	if not task or not TaskLifecycle.start(task, "Karabiner installer checksum") then
		callback(false, "Failed to start shasum task.")
	else
		M._active_tasks[task] = true
	end
end

--- Downloads a URL to a destination file via curl, async. Creates the parent
--- directory beforehand if needed. Uses --fail so HTTP 4xx/5xx errors do not
--- silently produce a 0-byte file.
--- @param url string Source URL.
--- @param dest string Absolute destination path.
--- @param callback function fun(ok: boolean, err: string|nil)
local function download_async(url, dest, callback)
	local epoch = _install_epoch
	local parent = dest:match("^(.*/)") or ""
	if parent ~= "" then
		hs.execute("/bin/mkdir -p " .. text_utils.shell_quote(parent))
	end
	local task
	task = TaskLifecycle.native("Karabiner installer download", "/usr/bin/curl", function(rc, _, stderr)
		if task then M._active_tasks[task] = nil end  -- task captured by closure; clears the GC-root pin
		if epoch ~= _install_epoch then return end
		if rc ~= 0 then
			callback(false, "curl rc=" .. tostring(rc) .. " stderr=" .. tostring(stderr))
			return
		end
		callback(true, nil)
	end, { "-L", "--fail", "--silent", "--show-error", "--output", dest, url })
	if not task or not TaskLifecycle.start(task, "Karabiner installer download") then
		callback(false, "Failed to start curl task.")
	else
		M._active_tasks[task] = true
	end
end

--- Mounts a DMG via hdiutil, async. Returns the mount point on success.
--- @param dmg_path string Absolute path to the .dmg.
--- @param callback function fun(ok: boolean, mount_point_or_err: string)
local function mount_dmg_async(dmg_path, callback)
	local epoch = _install_epoch
	local task
	task = TaskLifecycle.native("Karabiner installer DMG mount", "/usr/bin/hdiutil", function(rc, stdout, stderr)
		if task then M._active_tasks[task] = nil end  -- task captured by closure; clears the GC-root pin
		if epoch ~= _install_epoch then return end
		if rc ~= 0 or type(stdout) ~= "string" then
			callback(false, "hdiutil rc=" .. tostring(rc) .. " stderr=" .. tostring(stderr))
			return
		end
		local mount_point
		for line in stdout:gmatch("[^\n]+") do
			local mp = line:match("(/Volumes/[^\t]+)")
			if mp then mount_point = mp end
		end
		if not mount_point then
			callback(false, "Could not parse hdiutil output: " .. stdout)
			return
		end
		callback(true, mount_point)
	end, { "attach", "-nobrowse", dmg_path })
	if not task or not TaskLifecycle.start(task, "Karabiner installer DMG mount") then
		callback(false, "Failed to start hdiutil task.")
	else
		M._active_tasks[task] = true
	end
end

--- Detaches a mounted DMG. Fire-and-forget — unmount is fast and any error
--- is non-fatal (the volume can be lazily released on reboot).
--- @param mount_point string
local function unmount_dmg(mount_point)
	hs.execute("/usr/bin/hdiutil detach " .. text_utils.shell_quote(mount_point) .. " 2>/dev/null")
end

--- Locates the .pkg sitting at the root of a mounted DMG. KE ships exactly
--- one .pkg per release.
--- @param mount_point string
--- @return string|nil pkg_path
local function find_pkg_in_volume(mount_point)
	local out = hs.execute("/bin/ls " .. text_utils.shell_quote(mount_point) .. " 2>&1")
	if type(out) ~= "string" then return nil end
	for line in out:gmatch("[^\n]+") do
		if line:match("%.pkg$") then
			return mount_point .. "/" .. line
		end
	end
	return nil
end

--- Runs `installer -pkg PATH -target /` with sudo, via osascript so macOS shows
--- its native admin password prompt. This is the only user-friendly way to
--- escalate from a Hammerspoon script.
--- @param pkg_path string Absolute path to the .pkg.
--- @param callback function fun(ok: boolean, err: string|nil)
local function run_pkg_with_sudo_async(pkg_path, callback)
	local epoch = _install_epoch
	-- `quoted form of` operates on the AppleScript VALUE, and that value is
	-- produced by PARSING the literal below — so anything the literal itself
	-- mis-parses is already lost before `quoted form of` ever runs. The escape must
	-- therefore handle the backslash too, and handle it first: pkg_path is
	-- mount_point .. "/" .. a filename listed from a third-party DMG, and this
	-- string reaches a shell running with administrator privileges.
	local script = text_utils.applescript_format(
		[[do shell script "/usr/sbin/installer -pkg " & quoted form of "%s" & " -target /" with administrator privileges]],
		pkg_path
	)
	local task
	task = TaskLifecycle.native("Karabiner package install", "/usr/bin/osascript", function(rc, _, stderr)
		if task then M._active_tasks[task] = nil end  -- task captured by closure; clears the GC-root pin
		if epoch ~= _install_epoch then return end
		if rc ~= 0 then
			callback(false, "osascript rc=" .. tostring(rc) .. " stderr=" .. tostring(stderr))
			return
		end
		callback(true, nil)
	end, { "-e", script })
	if not task or not TaskLifecycle.start(task, "Karabiner package install") then
		callback(false, "Failed to start osascript task.")
	else
		M._active_tasks[task] = true
	end
end

--- Ensures the DMG is present in the cache and matches the manifest SHA-256.
--- If the cached file is missing or the hash mismatches, downloads fresh and
--- re-verifies. Calls callback(true) only when the cache file is verified good.
--- @param manifest table
--- @param cache_path string
--- @param callback function fun(ok: boolean, err: string|nil)
function M.ensure_dmg_cached(manifest, cache_path, callback)
	local function fresh_download()
		Logger.start(LOG, "Downloading KE DMG (~46 MB) from %s…", manifest.source_url)
		notify(i18n.get("karabiner.downloading"), "info")
		download_async(manifest.source_url, cache_path, function(ok_dl, err_dl)
			if not ok_dl then
				Logger.error(LOG, "Download failed: %s.", err_dl)
				callback(false, string.format(i18n.get("karabiner.download_failed"), tostring(err_dl)))
				return
			end
			Logger.success(LOG, "Download complete.")
			Logger.start(LOG, "Verifying SHA-256…")
			verify_sha256_async(cache_path, manifest.sha256, function(ok_sha, err_sha)
				if not ok_sha then
					Logger.error(LOG, "Hash verification failed: %s.", err_sha)
					os.remove(cache_path)
					callback(false, string.format(i18n.get("karabiner.sha_failed"), tostring(err_sha)))
					return
				end
				Logger.success(LOG, "SHA-256 verified.")
				callback(true, nil)
			end)
		end)
	end

	if not file_exists(cache_path) then
		Logger.debug(LOG, "Cache miss: '%s'.", cache_path)
		fresh_download()
		return
	end

	-- Cache hit — re-verify before trusting it. A previous partial download
	-- or bit rot would be invisible without this check.
	Logger.trace(LOG, "Cache hit, verifying SHA-256…")
	verify_sha256_async(cache_path, manifest.sha256, function(ok_sha, err_sha)
		if ok_sha then
			Logger.done(LOG, "Cached DMG SHA-256 verified — skipping download.")
			callback(true, nil)
			return
		end
		Logger.warn(LOG, "Cached DMG hash mismatch (%s) — redownloading.", tostring(err_sha))
		os.remove(cache_path)
		fresh_download()
	end)
end

--- High-level installer pipeline: ensures the DMG is cached + verified,
--- mounts it, runs the inner .pkg with sudo, then unmounts. Calls callback
--- exactly once with overall success/failure.
--- @param callback function fun(ok: boolean, err: string|nil) optional.
function M.install_karabiner_elements(callback)
	callback = callback or function() end
	for _ in pairs(M._active_tasks) do
		callback(false, "An installer operation is already active.")
		return false
	end
	_install_epoch = _install_epoch + 1

	local manifest = M.load_manifest()
	if not manifest then
		callback(false, "Manifest illisible.")
		return
	end
	if M.manifest_is_unpinned(manifest) then
		Logger.warn(LOG, "Manifest unpinned (TODO placeholders) — auto-install disabled.")
		callback(false, i18n.get("karabiner.onboarding.error.manifest_unconfigured"))
		return
	end

	local cache_path = M.get_cache_dmg_path(manifest)
	Logger.start(LOG, "Installing Karabiner-Elements (cache='%s')…", cache_path)

	M.ensure_dmg_cached(manifest, cache_path, function(ok_cache, err_cache)
		if not ok_cache then
			callback(false, err_cache)
			return
		end

		Logger.trace(LOG, "Mounting DMG…")
		mount_dmg_async(cache_path, function(ok_mount, mount_or_err)
			if not ok_mount then
				Logger.error(LOG, "Mount failed: %s.", mount_or_err)
				-- Parenthesised so gsub's second return (the match count) does not leak in
				-- as callback's third argument, and escaped because the payload is raw
				-- hdiutil stderr — a "%" in it would raise inside this async callback,
				-- where the error reaches only the HS Console.
				callback(false, (i18n.get("karabiner.onboarding.error.mount_failed")
					:gsub("{error}", text_utils.escape_gsub_replacement(tostring(mount_or_err)))))
				return
			end
			local mount_point = mount_or_err
			Logger.done(LOG, "Mounted at '%s'.", mount_point)

			local pkg_path = find_pkg_in_volume(mount_point)
			if not pkg_path then
				unmount_dmg(mount_point)
				Logger.error(LOG, "No .pkg found in mounted volume.")
				callback(false, i18n.get("karabiner.pkg_not_found"))
				return
			end

			Logger.start(LOG, "Running pkg installer (admin prompt expected)…")
			notify(i18n.get("karabiner.installing"), "info")
			run_pkg_with_sudo_async(pkg_path, function(ok_install, err_install)
				unmount_dmg(mount_point)
				if not ok_install then
					Logger.error(LOG, "Installer failed: %s.", err_install)
					callback(false, string.format(i18n.get("karabiner.install_failed"), tostring(err_install)))
					return
				end
				Logger.success(LOG, "Karabiner-Elements installed.")
				callback(true, nil)
			end)
		end)
	end)
end





-- ===================================
-- ===================================
-- ======= 4/ Permission Panes =======
-- ===================================
-- ===================================

--- Opens the System Settings pane where the user grants Input Monitoring
--- permission. Used for pre-v16 Karabiner-Elements; v16+ asks for
--- Accessibility instead (see open_accessibility_pane). macOS does not let
--- scripts grant TCC, so a deep-link is the closest we can get to one click.
function M.open_input_monitoring_pane()
	Logger.info(LOG, "Opening Input Monitoring pane…")
	hs.execute("/usr/bin/open " .. text_utils.shell_quote(URL_INPUT_MONITORING))
end

--- Opens the System Settings pane where the user grants Accessibility
--- permission. Karabiner-Elements v16+ requires Accessibility (and may make
--- Input Monitoring redundant); v15 and older required Input Monitoring.
function M.open_accessibility_pane()
	Logger.info(LOG, "Opening Accessibility pane…")
	hs.execute("/usr/bin/open " .. text_utils.shell_quote(URL_ACCESSIBILITY))
end

--- Opens the System Extensions pane where the user must approve the
--- Karabiner-DriverKit-VirtualHIDDevice extension on first install.
function M.open_system_extensions_pane()
	Logger.info(LOG, "Opening System Extensions pane…")
	hs.execute("/usr/bin/open " .. text_utils.shell_quote(URL_SYSTEM_EXTENSIONS))
end




-- =====================================
-- =====================================
-- ======= 5/ First-Run Wizard =========
-- =====================================
-- =====================================

--- Cancels one exact wizard timer while retaining a refused native capability.
--- @param owner table Timer transaction owner.
--- @param context string Operation requesting cancellation.
--- @return boolean settled True only when no native timer can remain.
local function cancel_timer_owner(owner, context)
	if type(owner) ~= "table" then return true end
	owner.committed = false
	if not owner.handle then
		if owner.acquiring then return false end
		if _timer_owner == owner then _timer_owner = nil end
		return true
	end
	local ok, result = xpcall(function()
		return TimerScheduler.cancel(owner.handle)
	end, debug.traceback)
	if ok and result == true then
		owner.handle = nil
		if _timer_owner == owner then _timer_owner = nil end
		return true
	end
	Logger.error(LOG, "%s: exact onboarding timer cleanup remains pending — %s.",
		context, tostring(result))
	return false
end

--- Settles callback-inert cleanup debt before any sibling timer acquisition.
--- @param context string Acquisition requesting the timer slot.
--- @return boolean available True only when the exact slot is free.
local function settle_timer_slot(context)
	if not _timer_owner then return true end
	if _timer_owner.committed == true then
		Logger.error(LOG, "%s: onboarding timer sibling rejected while an active owner exists.", context)
		return false
	end
	return cancel_timer_owner(_timer_owner, context)
end

--- Invokes one wizard callback with a traceback in the Ergopti file logger.
--- @param label string Stable callback label.
--- @param callback function|nil Callback to invoke.
--- @return boolean ok True when the callback completed.
local function invoke_wizard_callback(label, callback)
	if type(callback) ~= "function" then return true end
	local ok, err = xpcall(callback, debug.traceback)
	if not ok then
		Logger.error(LOG, "%s callback failed: %s.", label, tostring(err))
	end
	return ok
end

--- Acquires one exact recurring or one-shot timer transaction.
--- @param method string TimerScheduler method name.
--- @param delay number Delay or interval in seconds.
--- @param epoch number Wizard lifecycle epoch.
--- @param label string Stable operation label.
--- @param callback function fun(owner: table)
--- @return boolean committed True only when the native timer was armed.
local function arm_owned_timer(method, delay, epoch, label, callback)
	if epoch ~= _wizard_epoch then return false end
	if settle_timer_slot(label) ~= true then return false end
	local scheduler = TimerScheduler[method]
	if type(scheduler) ~= "function" then
		Logger.error(LOG, "%s: TimerScheduler.%s is unavailable.", label, method)
		return false
	end

	local owner = {
		acquiring = true,
		committed = false,
		epoch = epoch,
		handle = nil,
		label = label,
	}
	_timer_owner = owner
	local candidate
	local schedule_ok, handle_or_err, committed = xpcall(function()
		return scheduler(delay, function()
			if _timer_owner ~= owner then return end
			if owner.committed ~= true then
				if owner.acquiring ~= true then
					cancel_timer_owner(owner, label .. " stale callback")
				end
				return
			end
			if owner.epoch ~= _wizard_epoch then
				cancel_timer_owner(owner, label .. " stale epoch")
				return
			end
			if method == "after" then
				owner.committed = false
				if cancel_timer_owner(owner, label .. " completion") ~= true then return end
			end
			invoke_wizard_callback(label, function() callback(owner) end)
		end)
	end, debug.traceback)
	candidate = handle_or_err
	owner.handle = type(candidate) == "table" and candidate or nil
	owner.acquiring = false

	if not schedule_ok or committed ~= true or type(candidate) ~= "table" then
		owner.committed = false
		cancel_timer_owner(owner, label .. " acquisition rollback")
		Logger.error(LOG, "%s: onboarding timer acquisition failed — %s.",
			label, tostring(handle_or_err))
		return false
	end
	owner.committed = true
	return true
end

--- Schedules the next wizard step under the current lifecycle epoch.
--- @param delay number Delay before the next step.
--- @param epoch number Wizard lifecycle epoch.
--- @param label string Stable operation label.
--- @return boolean committed True only when the continuation is owned.
local function schedule_wizard_step(delay, epoch, label)
	return arm_owned_timer("after", delay, epoch, label, function()
		if epoch == _wizard_epoch then run_wizard_step(epoch) end
	end)
end

--- Polls a predicate until it becomes true or the global timeout elapses.
--- @param predicate function fun(): boolean
--- @param on_done function fun()
--- @param on_timeout function|nil fun()
--- @param epoch number Wizard lifecycle epoch.
--- @return boolean committed True only when the recurring timer was armed.
local function poll_until(predicate, on_done, on_timeout, epoch)
	local started = os.time()
	local terminal = false

	--- Completes one terminal branch only after the recurring timer is settled.
	--- @param owner table Timer transaction owner.
	--- @param callback function|nil Terminal callback to invoke.
	local function finish(owner, callback)
		if terminal then
			cancel_timer_owner(owner, "poll_until duplicate terminal")
			return
		end
		terminal = true
		owner.committed = false
		if cancel_timer_owner(owner, "poll_until terminal") ~= true then return end
		if epoch == _wizard_epoch then invoke_wizard_callback("poll_until terminal", callback) end
	end

	local committed = arm_owned_timer("every", POLL_INTERVAL_SEC, epoch, "poll_until", function(owner)
		if terminal then
			cancel_timer_owner(owner, "poll_until stale tick")
			return
		end
		local ok, result = xpcall(predicate, debug.traceback)
		if not ok then
			Logger.error(LOG, "poll_until predicate failed: %s.", tostring(result))
			finish(owner, on_timeout)
			return
		end
		if result == true then
			finish(owner, on_done)
			return
		end
		if os.time() - started > POLL_TIMEOUT_SEC then
			Logger.warn(LOG, "poll_until: timeout after %ds.", POLL_TIMEOUT_SEC)
			finish(owner, on_timeout)
		end
	end)
	if committed ~= true and epoch == _wizard_epoch then
		terminal = true
		invoke_wizard_callback("poll_until acquisition failure", on_timeout)
	end
	return committed
end

--- Cancels every wizard continuation and invalidates queued async completions.
--- @return boolean settled True only when no native onboarding timer can remain.
function M.stop()
	_wizard_epoch = _wizard_epoch + 1
	_install_epoch = _install_epoch + 1
	local settled = true
	for task in pairs(M._active_tasks) do
		local ok, result = xpcall(function() return task:terminate() end, debug.traceback)
		if ok and result == true then
			M._active_tasks[task] = nil
		else
			settled = false
			Logger.error(LOG, "Onboarding task termination refused; owner retained: %s", tostring(result))
		end
	end
	if _timer_owner then
		local owner = _timer_owner
		owner.committed = false
		settled = cancel_timer_owner(owner, "M.stop") and settled
	end
	if not settled then
		Logger.error(LOG, "Onboarding stop incomplete; exact timer cleanup retained for retry.")
	end
	return settled
end

--- Builds a French-language summary of the missing pieces from a health report.
--- Returns nil when nothing is missing.
--- @param report table
--- @return string|nil
local function summarize_missing(report)
	if report.all_ok then return nil end
	local lines = {}
	if not report.ke_installed     then table.insert(lines, i18n.get("karabiner.onboarding.missing.ke_not_installed")) end
	if not report.grabber_present  then table.insert(lines, i18n.get("karabiner.onboarding.missing.grabber_absent")) end
	if not report.sysext_activated then table.insert(lines, i18n.get("karabiner.onboarding.missing.sysext_not_activated")) end
	if not report.grabber_running  then table.insert(lines, i18n.get("karabiner.onboarding.missing.daemon_not_running")) end
	return table.concat(lines, "\n")
end

--- Runs one first-run wizard step for an already-owned lifecycle epoch.
--- @param epoch number Wizard lifecycle epoch.
run_wizard_step = function(epoch)
	if epoch ~= _wizard_epoch then return false end
	local report = M.health_check()
	if report.all_ok then
		Logger.info(LOG, "Onboarding: KE stack fully operational — wizard not needed.")
		return true
	end

	Logger.start(LOG, "Onboarding wizard step…")
	local summary = summarize_missing(report) or ""

	-- Decide which step to run based on the first missing dependency in order
	-- of the install pipeline (app → sysext → daemon running).
	local dialog_util = require("infra.dialog_util")
	if not report.ke_installed or not report.grabber_present then
		local choice = dialog_util.block_alert(
			i18n.get("karabiner.onboarding.required_title"),
			i18n.get("karabiner.onboarding.missing_prefix") .. summary
				.. i18n.get("karabiner.onboarding.install_body_suffix"),
			i18n.get("karabiner.onboarding.btn_install_now"), i18n.get("common.later"), "warning")
		Logger.info(LOG, "Wizard step (install): user chose '%s'.", tostring(choice))
		if choice ~= i18n.get("karabiner.onboarding.btn_install_now") then
			Logger.success(LOG, "Onboarding wizard step completed (user deferred).")
			return
		end
		M.install_karabiner_elements(function(ok_install, err_install)
			if epoch ~= _wizard_epoch then return end
			if not ok_install then
				dialog_util.block_alert(
					i18n.get("karabiner.install_error_title"),
					string.format(i18n.get("karabiner.install_error_body"), tostring(err_install)),
					i18n.get("button.ok"), nil, "critical")
				return
			end
			-- Wait briefly for the new binary to register, then re-poll to
			-- catch the next required step (sysext approval).
			if schedule_wizard_step(INSTALL_SETTLE_DELAY_SEC, epoch,
				"post-install wizard continuation") ~= true then
				run_wizard_step(epoch)
			end
		end)
		Logger.success(LOG, "Onboarding wizard step completed (install in flight).")
		return
	end

	if not report.sysext_activated then
		local choice = dialog_util.block_alert(
			i18n.get("karabiner.onboarding.ext_title"),
			i18n.get("karabiner.onboarding.ext_body"),
			i18n.get("karabiner.onboarding.btn_open_settings"), i18n.get("common.later"), "warning")
		Logger.info(LOG, "Wizard step (sysext): user chose '%s'.", tostring(choice))
		if choice ~= i18n.get("karabiner.onboarding.btn_open_settings") then
			Logger.success(LOG, "Onboarding wizard step completed (user deferred).")
			return
		end
		M.open_system_extensions_pane()
		notify(i18n.get("karabiner.onboarding.ext_waiting"), "info")
		poll_until(M.is_sysext_activated,
			function()
				notify(i18n.get("karabiner.onboarding.ext_activated"), "success")
				if schedule_wizard_step(NEXT_STEP_DELAY_SEC, epoch,
					"post-system-extension wizard continuation") ~= true then
					run_wizard_step(epoch)
				end
			end,
			function() notify(i18n.get("karabiner.onboarding.ext_timeout"), "warning") end,
			epoch)
		Logger.success(LOG, "Onboarding wizard step completed (waiting on sysext).")
		return
	end

	if not report.grabber_running then
		local choice = dialog_util.block_alert(
			i18n.get("karabiner.onboarding.accessibility_title"),
			i18n.get("karabiner.onboarding.accessibility_body"),
			i18n.get("karabiner.onboarding.btn_open_accessibility"), i18n.get("common.later"), "warning")
		Logger.info(LOG, "Wizard step (accessibility): user chose '%s'.", tostring(choice))
		if choice ~= i18n.get("karabiner.onboarding.btn_open_accessibility") then
			Logger.success(LOG, "Onboarding wizard step completed (user deferred).")
			return
		end
		M.open_accessibility_pane()
		notify(i18n.get("karabiner.onboarding.daemon_waiting"), "info")
		poll_until(M.is_grabber_running,
			function()
				notify(i18n.get("karabiner.onboarding.daemon_ready"), "success")
				if schedule_wizard_step(NEXT_STEP_DELAY_SEC, epoch,
					"post-daemon wizard continuation") ~= true then
					run_wizard_step(epoch)
				end
			end,
			function() notify(i18n.get("karabiner.onboarding.daemon_timeout"), "warning") end,
			epoch)
		Logger.success(LOG, "Onboarding wizard step completed (waiting on daemon).")
		return
	end

	Logger.success(LOG, "Onboarding wizard step completed (no actionable step).")
	return true
end

--- Starts a fresh first-run wizard chain after settling any older timer owner.
--- Each invocation invalidates queued completions from the preceding chain.
--- @return boolean|nil started False only when cleanup or execution failed.
function M.run_first_run_wizard()
	_wizard_epoch = _wizard_epoch + 1
	local epoch = _wizard_epoch
	if _timer_owner then
		local owner = _timer_owner
		owner.committed = false
		if cancel_timer_owner(owner, "run_first_run_wizard replacement") ~= true then
			return false
		end
	end
	local ok, result = xpcall(function() return run_wizard_step(epoch) end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Onboarding wizard execution failed: %s.", tostring(result))
		return false
	end
	return result
end

return M
