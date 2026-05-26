--- modules/karabiner/onboarding.lua

--- ==============================================================================
--- MODULE: Karabiner-Elements Onboarding
--- DESCRIPTION:
--- Detects the install state of Karabiner-Elements and guides the user through
--- any missing dependency (the app itself, the DriverKit System Extension,
--- the root grabber daemon, Input Monitoring permission) via a single
--- first-run wizard. Called by modules/karabiner/init.lua at boot time.
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
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")
local i18n   = require("lib.i18n")

-- Optional dependency: only used to surface user-friendly notifications.
-- Falls back to silent operation if the notifications lib is not present.
local ok_notif, Notifications = pcall(require, "lib.notifications")
if not ok_notif then Notifications = nil end

local LOG = "karabiner.onboarding"

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
local KE_GRABBER_BIN   = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_grabber"
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
--- ==========================================
-- ======= 1/ Vendor Manifest Loading =======
--- ==========================================
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
--- ==================================
-- ======= 2/ State Detection =======
--- ==================================
-- ==================================

--- True when /Applications/Karabiner-Elements.app exists.
--- @return boolean
function M.is_ke_app_installed()
	return file_exists(KE_APP_PATH)
end

--- True when the grabber binary exists on disk, independent of run state.
--- @return boolean
function M.is_grabber_binary_present()
	return file_exists(KE_GRABBER_BIN)
end

--- True when the karabiner_grabber root daemon is currently running.
--- Defers to ke_lifecycle to keep a single canonical pgrep call across modules.
--- @return boolean
function M.is_grabber_running()
	local KeLifecycle = require("modules.karabiner.ke_lifecycle")
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




-- =============================================
--- ==============================================
-- ======= 3/ Cache and Download Pipeline =======
--- ==============================================
-- =============================================

--- Verifies the SHA-256 of a local file against an expected hex digest. Async
--- so a slow shasum call cannot block Hammerspoon's main loop.
--- @param path string Absolute path of the file to hash.
--- @param expected_sha string Expected SHA-256, lowercase hex.
--- @param callback function fun(ok: boolean, err: string|nil)
local function verify_sha256_async(path, expected_sha, callback)
	local task = hs.task.new("/usr/bin/shasum", function(rc, stdout, _)
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
	if not task or not task:start() then
		callback(false, "Failed to start shasum task.")
	end
end

--- Downloads a URL to a destination file via curl, async. Creates the parent
--- directory beforehand if needed. Uses --fail so HTTP 4xx/5xx errors do not
--- silently produce a 0-byte file.
--- @param url string Source URL.
--- @param dest string Absolute destination path.
--- @param callback function fun(ok: boolean, err: string|nil)
local function download_async(url, dest, callback)
	local parent = dest:match("^(.*/)") or ""
	if parent ~= "" then
		hs.execute(string.format("/bin/mkdir -p %q", parent))
	end
	local task = hs.task.new("/usr/bin/curl", function(rc, _, stderr)
		if rc ~= 0 then
			callback(false, "curl rc=" .. tostring(rc) .. " stderr=" .. tostring(stderr))
			return
		end
		callback(true, nil)
	end, { "-L", "--fail", "--silent", "--show-error", "--output", dest, url })
	if not task or not task:start() then
		callback(false, "Failed to start curl task.")
	end
end

--- Mounts a DMG via hdiutil, async. Returns the mount point on success.
--- @param dmg_path string Absolute path to the .dmg.
--- @param callback function fun(ok: boolean, mount_point_or_err: string)
local function mount_dmg_async(dmg_path, callback)
	local task = hs.task.new("/usr/bin/hdiutil", function(rc, stdout, stderr)
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
	if not task or not task:start() then
		callback(false, "Failed to start hdiutil task.")
	end
end

--- Detaches a mounted DMG. Fire-and-forget — unmount is fast and any error
--- is non-fatal (the volume can be lazily released on reboot).
--- @param mount_point string
local function unmount_dmg(mount_point)
	hs.execute(string.format("/usr/bin/hdiutil detach %q 2>/dev/null", mount_point))
end

--- Locates the .pkg sitting at the root of a mounted DMG. KE ships exactly
--- one .pkg per release.
--- @param mount_point string
--- @return string|nil pkg_path
local function find_pkg_in_volume(mount_point)
	local out = hs.execute(string.format("/bin/ls %q 2>&1", mount_point))
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
	-- AppleScript's `quoted form of` handles spaces and special chars safely.
	-- We must escape any embedded `"` in the path to keep our enclosing
	-- AppleScript literal valid.
	local escaped = pkg_path:gsub('"', '\\"')
	local script  = string.format(
		[[do shell script "/usr/sbin/installer -pkg " & quoted form of "%s" & " -target /" with administrator privileges]],
		escaped
	)
	local task = hs.task.new("/usr/bin/osascript", function(rc, _, stderr)
		if rc ~= 0 then
			callback(false, "osascript rc=" .. tostring(rc) .. " stderr=" .. tostring(stderr))
			return
		end
		callback(true, nil)
	end, { "-e", script })
	if not task or not task:start() then
		callback(false, "Failed to start osascript task.")
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
				callback(false, i18n.get("karabiner.onboarding.error.mount_failed"):gsub("{error}", tostring(mount_or_err)))
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
--- ===================================
-- ======= 4/ Permission Panes =======
--- ===================================
-- ===================================

--- Opens the System Settings pane where the user grants Input Monitoring
--- permission. Used for pre-v16 Karabiner-Elements; v16+ asks for
--- Accessibility instead (see open_accessibility_pane). macOS does not let
--- scripts grant TCC, so a deep-link is the closest we can get to one click.
function M.open_input_monitoring_pane()
	Logger.info(LOG, "Opening Input Monitoring pane…")
	hs.execute(string.format("/usr/bin/open %q", URL_INPUT_MONITORING))
end

--- Opens the System Settings pane where the user grants Accessibility
--- permission. Karabiner-Elements v16+ requires Accessibility (and may make
--- Input Monitoring redundant); v15 and older required Input Monitoring.
function M.open_accessibility_pane()
	Logger.info(LOG, "Opening Accessibility pane…")
	hs.execute(string.format("/usr/bin/open %q", URL_ACCESSIBILITY))
end

--- Opens the System Extensions pane where the user must approve the
--- Karabiner-DriverKit-VirtualHIDDevice extension on first install.
function M.open_system_extensions_pane()
	Logger.info(LOG, "Opening System Extensions pane…")
	hs.execute(string.format("/usr/bin/open %q", URL_SYSTEM_EXTENSIONS))
end




-- =====================================
-- =====================================
-- ======= 5/ First-Run Wizard =========
-- =====================================
-- =====================================

--- Polls a predicate until it becomes true or the global timeout elapses.
--- On success, fires on_done; on timeout, fires on_timeout. The repeating
--- timer is stopped automatically as soon as either branch is taken.
--- @param predicate function fun(): boolean
--- @param on_done function fun()
--- @param on_timeout function|nil fun()
local function poll_until(predicate, on_done, on_timeout)
	local started = os.time()
	local timer
	timer = hs.timer.doEvery(POLL_INTERVAL_SEC, function()
		local ok, result = pcall(predicate)
		if ok and result == true then
			timer:stop()
			on_done()
			return
		end
		if os.time() - started > POLL_TIMEOUT_SEC then
			timer:stop()
			Logger.warn(LOG, "poll_until: timeout after %ds.", POLL_TIMEOUT_SEC)
			if on_timeout then on_timeout() end
		end
	end)
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

--- Runs the first-run wizard step that matches the user's actual situation.
--- Each invocation handles ONE missing dependency, schedules a re-poll on
--- success, and the next call handles the next missing dependency. The user
--- experiences a sequence of one-click dialogs separated by macOS prompts.
--- Safe to call repeatedly — does nothing once everything is operational.
function M.run_first_run_wizard()
	local report = M.health_check()
	if report.all_ok then
		Logger.info(LOG, "Onboarding: KE stack fully operational — wizard not needed.")
		return
	end

	Logger.start(LOG, "Onboarding wizard step…")
	local summary = summarize_missing(report) or ""

	-- Decide which step to run based on the first missing dependency in order
	-- of the install pipeline (app → sysext → daemon running).
	if not report.ke_installed or not report.grabber_present then
		local choice = hs.dialog.blockAlert(
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
			if not ok_install then
				hs.dialog.blockAlert(
					i18n.get("karabiner.install_error_title"),
					string.format(i18n.get("karabiner.install_error_body"), tostring(err_install)),
					i18n.get("button.ok"), nil, "critical")
				return
			end
			-- Wait briefly for the new binary to register, then re-poll to
			-- catch the next required step (sysext approval).
			hs.timer.doAfter(2.0, function() M.run_first_run_wizard() end)
		end)
		Logger.success(LOG, "Onboarding wizard step completed (install in flight).")
		return
	end

	if not report.sysext_activated then
		local choice = hs.dialog.blockAlert(
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
				hs.timer.doAfter(1.0, function() M.run_first_run_wizard() end)
			end,
			function() notify(i18n.get("karabiner.onboarding.ext_timeout"), "warning") end)
		Logger.success(LOG, "Onboarding wizard step completed (waiting on sysext).")
		return
	end

	if not report.grabber_running then
		local choice = hs.dialog.blockAlert(
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
				hs.timer.doAfter(1.0, function() M.run_first_run_wizard() end)
			end,
			function() notify(i18n.get("karabiner.onboarding.daemon_timeout"), "warning") end)
		Logger.success(LOG, "Onboarding wizard step completed (waiting on daemon).")
		return
	end

	Logger.success(LOG, "Onboarding wizard step completed (no actionable step).")
end

return M
