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
--- 7. Exact installer ownership: one epoch-scoped owner retains every task,
---    unique partial, and mounted volume until native cleanup settles.
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
M._install_owner = nil

-- One lifecycle epoch owns every poll, delayed continuation, and installer
-- completion spawned by the current wizard chain
local _wizard_epoch = 0
local _install_epoch = 0
local _timer_owner = nil
local _stop_waiters = {}
local _stop_failure_detail = nil
local run_wizard_step
local cancel_install_cleanup_retry
local schedule_install_cleanup_retry

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
local INSTALL_CLEANUP_RETRY_DELAY_SEC = 0.25
local INSTALL_CLEANUP_MAX_RETRIES = 3
local WIZARD_TIMER_MAX_ATTEMPTS = 3


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

--- True only while one installer owner still holds current execution authority.
--- @param owner table Installer lifecycle owner.
--- @return boolean current
local function install_owner_is_current(owner)
	return type(owner) == "table"
		and M._install_owner == owner
		and owner.epoch == _install_epoch
		and owner.terminal ~= true
end

--- Updates cleanup debt and releases a terminal owner only after exact settlement.
--- @param owner table Installer lifecycle owner.
--- @return boolean settled
local function refresh_install_owner(owner)
	if type(owner) ~= "table" then return true end
	local pending = next(owner.tasks) ~= nil
		or owner.mount_point ~= nil
		or owner.unique_partial ~= nil
		or next(owner.cleanup_debt.tasks) ~= nil
		or owner.cleanup_debt.mount_point ~= nil
		or owner.cleanup_debt.partial ~= nil
		or next(owner.cleanup_debt.retry_timer_owners) ~= nil
	owner.cleanup_debt.pending = pending
	if not pending and owner.terminal == true and M._install_owner == owner then
		M._install_owner = nil
	end
	return not pending
end

--- Releases one exact task from both the lifecycle owner and the GC root.
--- @param owner table Installer lifecycle owner.
--- @param task any Native task handle.
local function release_install_task(owner, task)
	if not task then return end
	owner.tasks[task] = nil
	owner.cleanup_debt.tasks[task] = nil
	owner.cleanup_debt.termination_accepted[task] = nil
	owner.cleanup_debt.termination_decisions[task] = nil
end

--- Invokes the public installer callback at most once with traceback logging.
--- @param owner table Installer lifecycle owner.
--- @param callback function Installer completion callback.
--- @param ok_result boolean Terminal result.
--- @param detail string|nil Terminal detail.
local function finish_install_owner(owner, callback, ok_result, detail)
	if owner.terminal == true then return end
	owner.terminal = true
	owner.stage = ok_result == true and "complete" or "failed"
	local callback_ok, callback_err = xpcall(function()
		callback(ok_result == true, detail)
	end, debug.traceback)
	if not callback_ok then
		Logger.error(LOG, "Karabiner installer terminal callback failed: %s.", tostring(callback_err))
	end
	if refresh_install_owner(owner) ~= true
		and owner.cleanup_debt.cancel_requested ~= true then
		schedule_install_cleanup_retry(owner, "installer terminal cleanup")
	end
end

--- Delivers every joined stop continuation exactly once.
--- Waiters are detached before invocation so re-entrant lifecycle calls cannot
--- redeliver an older transaction, including when native cleanup refuses and its
--- exact debt must outlive the public lifecycle terminal.
--- @param ok_result boolean Terminal stop result.
--- @param detail string Stable settlement detail.
local function complete_stop_waiters(ok_result, detail)
	local waiters = _stop_waiters
	_stop_waiters = {}
	_stop_failure_detail = nil
	for _, callback in ipairs(waiters) do
		local ok, err = xpcall(function()
			callback(ok_result == true, detail)
		end, debug.traceback)
		if not ok then
			Logger.error(LOG, "Onboarding stop continuation failed: %s.", tostring(err))
		end
	end
end

--- Delivers successful stop continuations only after every owner settles.
--- @return boolean settled True only when no exact owner remains.
local function complete_stop_waiters_if_settled()
	if M._install_owner ~= nil then return false end
	if _stop_failure_detail then
		complete_stop_waiters(false, _stop_failure_detail)
		return false
	end
	if _timer_owner ~= nil then return false end
	complete_stop_waiters(true, "onboarding-stopped")
	return true
end

--- Builds an attempt-unique staging path beside the published cache file.
--- @param cache_path string Published cache path.
--- @return string|nil partial_path
local function make_unique_partial_path(cache_path)
	if not hs or type(hs.host) ~= "table" or type(hs.host.uuid) ~= "function" then
		Logger.error(LOG, "Cannot allocate a unique installer partial because the UUID provider is unavailable.")
		return nil
	end
	local ok, uuid_or_err = xpcall(hs.host.uuid, debug.traceback)
	if not ok or type(uuid_or_err) ~= "string" or uuid_or_err == "" then
		Logger.error(LOG, "Cannot allocate a unique installer partial: %s.", tostring(uuid_or_err))
		return nil
	end
	local token = uuid_or_err:gsub("[^%w%-]", "")
	if token == "" then
		Logger.error(LOG, "Cannot allocate a unique installer partial from an invalid UUID.")
		return nil
	end
	return cache_path .. "." .. token .. ".part"
end

--- Removes one exact partial path without sweeping sibling installer attempts.
--- @param owner table Installer lifecycle owner.
--- @param path string|nil Exact staging path.
--- @param context string Cleanup reason.
--- @return boolean settled
local function remove_owned_partial(owner, path, context)
	path = path or owner.unique_partial
	if not path then return true end
	local call_ok, removed_or_err, remove_err, error_code = xpcall(function()
		return os.remove(path)
	end, debug.traceback)
	local absent = call_ok and removed_or_err ~= true and error_code == 2
	if not call_ok or (removed_or_err ~= true and not absent) then
		owner.unique_partial = path
		owner.cleanup_debt.partial = path
		Logger.error(LOG, "%s: exact installer partial cleanup failed for '%s': %s.",
			context, path, tostring(call_ok and remove_err or removed_or_err))
		return false
	end
	if owner.unique_partial == path then owner.unique_partial = nil end
	if owner.cleanup_debt.partial == path then owner.cleanup_debt.partial = nil end
	Logger.debug(LOG, "%s: exact installer partial settled for '%s'.", context, path)
	return true
end

--- Detaches one exact mounted volume at most once for an installer owner.
--- @param owner table Installer lifecycle owner.
--- @param mount_point string Exact volume mount point.
--- @param context string Cleanup reason.
--- @return boolean settled
local function detach_owned_mount(owner, mount_point, context)
	if type(mount_point) ~= "string" or mount_point == "" then return true end
	if owner.cleanup_debt.detached_mounts[mount_point] == true then
		if owner.mount_point == mount_point then owner.mount_point = nil end
		if owner.cleanup_debt.mount_point == mount_point then owner.cleanup_debt.mount_point = nil end
		return true
	end
	owner.mount_point = mount_point
	local call_ok, output_or_err, succeeded = xpcall(function()
		return hs.execute("/usr/bin/hdiutil detach "
			.. text_utils.shell_quote(mount_point) .. " 2>/dev/null")
	end, debug.traceback)
	if not call_ok or succeeded ~= true then
		owner.cleanup_debt.mount_point = mount_point
		Logger.error(LOG, "%s: exact installer mount detach failed for '%s': %s.",
			context, mount_point, tostring(output_or_err))
		return false
	end
	owner.cleanup_debt.detached_mounts[mount_point] = true
	owner.mount_point = nil
	if owner.cleanup_debt.mount_point == mount_point then owner.cleanup_debt.mount_point = nil end
	Logger.debug(LOG, "%s: exact installer mount detached from '%s'.", context, mount_point)
	return true
end

--- Settles artifacts only after no subprocess can still recreate or consume them.
--- @param owner table Installer lifecycle owner.
--- @param context string Cleanup reason.
--- @return boolean settled
local function settle_install_artifacts(owner, context)
	if next(owner.tasks) ~= nil then
		if owner.mount_point then owner.cleanup_debt.mount_point = owner.mount_point end
		if owner.unique_partial then owner.cleanup_debt.partial = owner.unique_partial end
		refresh_install_owner(owner)
		return false
	end
	local settled = true
	if owner.mount_point then
		settled = detach_owned_mount(owner, owner.mount_point, context) and settled
	end
	if owner.unique_partial then
		settled = remove_owned_partial(owner, owner.unique_partial, context) and settled
	end
	refresh_install_owner(owner)
	return settled
		and owner.mount_point == nil
		and owner.unique_partial == nil
		and owner.cleanup_debt.mount_point == nil
		and owner.cleanup_debt.partial == nil
end

--- Publishes one failed cancellation terminal while retaining exact cleanup debt.
--- @param owner table Installer lifecycle owner.
--- @param detail string Stable failure detail.
local function fail_install_cleanup(owner, detail)
	if owner.cleanup_debt.cancel_requested == true and owner.terminal ~= true then
		finish_install_owner(owner, owner.cleanup_debt.callback, false,
			owner.cleanup_debt.cancel_detail or "Installer cancelled.")
	end
	complete_stop_waiters(false, detail)
end

--- Cancels every exact retry timer while retaining native cancellation debt.
--- A refused handle stays in retry_timer_owners and counts as installer debt;
--- retry_timer_owner tracks only the currently committed user callback so a
--- fenced predecessor cannot block an autonomous cleanup successor.
--- @param owner table Installer lifecycle owner.
--- @param context string Cleanup reason.
--- @return boolean cancelled
cancel_install_cleanup_retry = function(owner, context)
	local retry_owners = owner.cleanup_debt.retry_timer_owners
	local snapshot = {}
	for retry_owner in pairs(retry_owners) do snapshot[#snapshot + 1] = retry_owner end
	local settled = true
	for _, retry_owner in ipairs(snapshot) do
		retry_owner.committed = false
		if owner.cleanup_debt.retry_timer_owner == retry_owner then
			owner.cleanup_debt.retry_timer_owner = nil
		end
		if retry_owner.handle == nil then
			retry_owners[retry_owner] = nil
		else
			local ok, result = xpcall(function()
				return TimerScheduler.cancel(retry_owner.handle)
			end, debug.traceback)
			if ok and result == true then
				retry_owner.handle = nil
				retry_owners[retry_owner] = nil
			else
				settled = false
				Logger.error(LOG,
					"%s: exact installer cleanup retry timer remains scheduler-owned: %s.",
					context, tostring(result))
			end
		end
	end
	refresh_install_owner(owner)
	return settled and next(retry_owners) == nil
end

--- Finishes a revoked installer only after its task and artifacts are settled.
--- The public installer terminal is delivered exactly once before joined pause,
--- disable, or shutdown continuations resume. Unsettled debt arms one bounded,
--- identity-checked retry owner rather than waiting for another user gesture.
--- @param owner table Installer lifecycle owner.
--- @param context string Cleanup reason.
--- @return boolean settled
local function settle_stopped_install_owner(owner, context)
	if settle_install_artifacts(owner, context) ~= true then
		schedule_install_cleanup_retry(owner, context)
		return false
	end
	if cancel_install_cleanup_retry(owner, context) ~= true then
		schedule_install_cleanup_retry(owner, context)
		return false
	end
	if owner.cleanup_debt.cancel_requested == true and owner.terminal ~= true then
		finish_install_owner(owner, owner.cleanup_debt.callback, false,
			owner.cleanup_debt.cancel_detail or "Installer cancelled.")
	end
	complete_stop_waiters_if_settled()
	return refresh_install_owner(owner)
end

--- Sends one termination signal without mistaking acceptance for process exit.
--- Only the exact native completion callback releases the task and its GC pin.
--- @param owner table Installer lifecycle owner.
--- @param task any Exact native task handle.
--- @param context string Cleanup reason.
--- @return boolean accepted True for any truthy native signal result.
local function request_install_task_termination(owner, task, context)
	local stage = owner.tasks[task]
	if stage == nil then return true end
	owner.cleanup_debt.tasks[task] = stage
	if owner.cleanup_debt.termination_accepted[task] == true then
		Logger.debug(LOG,
			"%s: installer stage '%s' already accepted its termination signal; awaiting exact exit.",
			context, tostring(stage))
		return true
	end
	local decision = {
		delivery = nil,
		in_progress = true,
	}
	owner.cleanup_debt.termination_decisions[task] = decision
	local ok, result = xpcall(function()
		return task:terminate()
	end, debug.traceback)
	decision.in_progress = false
	owner.cleanup_debt.termination_decisions[task] = nil
	local accepted = ok and result ~= false and result ~= nil
	if accepted then
		owner.cleanup_debt.termination_accepted[task] = true
	else
		-- A native callback may run synchronously inside terminate(). Do not let
		-- that exact exit publish a successful joined stop before the enclosing
		-- native call reveals that it refused or raised.
		_stop_failure_detail = "onboarding-task-termination-refused"
	end
	local pending_delivery = decision.delivery
	decision.delivery = nil
	if pending_delivery then pending_delivery() end
	if accepted then
		Logger.debug(LOG, "%s: termination signal accepted for installer stage '%s'; awaiting exact exit.",
			context, tostring(stage))
		return true
	end
	Logger.error(LOG, "%s: termination signal refused for installer stage '%s': %s.",
		context, tostring(stage), tostring(result))
	return false
end

--- Retries exact installer cleanup after one owned delay.
--- @param owner table Installer lifecycle owner.
--- @param context string Cleanup reason.
local function run_install_cleanup_retry(owner, context)
	if M._install_owner ~= owner then return end
	local termination_refused = false
	local tasks = {}
	for task in pairs(owner.tasks) do tasks[#tasks + 1] = task end
	for _, task in ipairs(tasks) do
		if owner.tasks[task] ~= nil
			and request_install_task_termination(owner, task, context) ~= true then
			termination_refused = true
		end
	end
	if termination_refused then
		fail_install_cleanup(owner, "onboarding-task-termination-refused")
	end
	settle_stopped_install_owner(owner, context)
end

--- Arms one bounded retry/deadline owner for task and artifact cleanup debt.
--- @param owner table Installer lifecycle owner.
--- @param context string Cleanup reason.
--- @return boolean committed
schedule_install_cleanup_retry = function(owner, context)
	if M._install_owner ~= owner then return false end
	if owner.cleanup_debt.retry_timer_owner then return true end
	if owner.cleanup_debt.retry_attempts >= INSTALL_CLEANUP_MAX_RETRIES then
		Logger.error(LOG, "%s: installer cleanup deadline reached after %d retry attempt(s).",
			context, owner.cleanup_debt.retry_attempts)
		fail_install_cleanup(owner, "onboarding-cleanup-timeout")
		return false
	end
	owner.cleanup_debt.retry_attempts = owner.cleanup_debt.retry_attempts + 1

	local retry_owner = {
		committed = false,
		handle = nil,
	}
	owner.cleanup_debt.retry_timer_owner = retry_owner
	owner.cleanup_debt.retry_timer_owners[retry_owner] = true
	local timer_ok, handle_or_err, committed = xpcall(function()
		return TimerScheduler.after(INSTALL_CLEANUP_RETRY_DELAY_SEC, function()
			if owner.cleanup_debt.retry_timer_owner ~= retry_owner
				or retry_owner.committed ~= true then return end
			owner.cleanup_debt.retry_timer_owner = nil
			retry_owner.committed = false
			cancel_install_cleanup_retry(owner, context .. " retry delivery")
			complete_stop_waiters_if_settled()
			run_install_cleanup_retry(owner, context)
		end)
	end, debug.traceback)
	if timer_ok then retry_owner.handle = handle_or_err end
	if not timer_ok or committed ~= true then
		if owner.cleanup_debt.retry_timer_owner == retry_owner then
			owner.cleanup_debt.retry_timer_owner = nil
		end
		cancel_install_cleanup_retry(owner, context .. " acquisition rollback")
		local detail = handle_or_err
		if timer_ok then detail = committed end
		Logger.error(LOG, "%s: installer cleanup retry timer was not committed: %s.",
			context, tostring(detail))
		if owner.cleanup_debt.retry_attempts < INSTALL_CLEANUP_MAX_RETRIES then
			return schedule_install_cleanup_retry(owner, context)
		end
		fail_install_cleanup(owner, "onboarding-cleanup-timer-refused")
		return false
	end
	retry_owner.committed = true
	Logger.debug(LOG, "%s: installer cleanup retry %d/%d armed in %.2fs.",
		context, owner.cleanup_debt.retry_attempts,
		INSTALL_CLEANUP_MAX_RETRIES, INSTALL_CLEANUP_RETRY_DELAY_SEC)
	return true
end

--- Pins one exact task before start and treats only literal true as commitment.
--- @param owner table Installer lifecycle owner.
--- @param task any Native task candidate.
--- @param stage string Stable installer stage.
--- @param label string Native task label.
--- @param callback function Failure callback.
--- @param start_gate table Completion publication gate.
--- @return boolean committed
local function start_owned_task(owner, task, stage, label, callback, start_gate)
	if not task then
		if start_gate then start_gate.refuse() end
		callback(false, "Failed to create " .. stage .. " task.")
		return false
	end
	if not install_owner_is_current(owner) then
		if start_gate then start_gate.refuse() end
		return false
	end
	owner.stage = stage
	owner.tasks[task] = stage
	M._active_tasks[task] = true
	if start_gate then start_gate.task = task end
	if TaskLifecycle.start(task, label) ~= true then
		if start_gate then start_gate.refuse() end
		M._active_tasks[task] = nil
		release_install_task(owner, task)
		callback(false, "Failed to start " .. stage .. " task.")
		return false
	end
	if start_gate then start_gate.commit() end
	return true
end

--- Latches one exact native task completion before it may advance the pipeline.
--- Native callbacks are not assumed to be single-shot because a duplicate from
--- the current task would otherwise construct a second successor while the owner
--- generation still has valid authority.
--- @param owner table Installer lifecycle owner.
--- @param stage string Stable installer stage.
--- @param callback function Native task completion body.
--- @return table start_gate Buffers completion until native start commits.
--- @return function guarded_callback Single-shot completion callback.
local function latch_install_task_completion(owner, stage, callback)
	local gate = {
		committed = false,
		completed = false,
		pending = nil,
	}
	local function deliver(rc, stdout, stderr)
		if gate.completed then
			Logger.warn(LOG, "Duplicate %s completion ignored for installer epoch %s.",
				tostring(stage), tostring(owner.epoch))
			return
		end
		gate.completed = true
		local callback_ok, callback_result = xpcall(function()
			return callback(rc, stdout, stderr)
		end, debug.traceback)
		if not callback_ok then
			Logger.error(LOG, "%s completion failed for installer epoch %s: %s.",
				tostring(stage), tostring(owner.epoch), tostring(callback_result))
			return nil
		end
		return callback_result
	end
	function gate.commit()
		if gate.completed then return end
		gate.committed = true
		local pending = gate.pending
		gate.pending = nil
		if pending then return deliver(pending.rc, pending.stdout, pending.stderr) end
	end
	function gate.refuse()
		gate.committed = false
		gate.completed = true
		gate.pending = nil
	end
	local function guarded_callback(rc, stdout, stderr)
		if gate.completed then
			Logger.warn(LOG, "Duplicate %s completion ignored for installer epoch %s.",
				tostring(stage), tostring(owner.epoch))
			return
		end
		if gate.committed ~= true then
			if gate.pending == nil then
				gate.pending = { rc = rc, stdout = stdout, stderr = stderr }
			else
				Logger.warn(LOG, "Duplicate pre-commit %s completion ignored for installer epoch %s.",
					tostring(stage), tostring(owner.epoch))
			end
			return
		end
		local task = gate.task
		local decision = task and owner.cleanup_debt.termination_decisions[task] or nil
		if decision and decision.in_progress == true then
			if decision.delivery == nil then
				decision.delivery = function() return deliver(rc, stdout, stderr) end
			else
				Logger.warn(LOG,
					"Duplicate synchronous %s termination completion ignored for installer epoch %s.",
					tostring(stage), tostring(owner.epoch))
			end
			return
		end
		return deliver(rc, stdout, stderr)
	end
	return gate, guarded_callback
end

--- Verifies the SHA-256 of a local file against an expected hex digest. Async
--- so a slow shasum call cannot block Hammerspoon's main loop.
--- @param owner table Installer lifecycle owner.
--- @param path string Absolute path of the file to hash.
--- @param expected_sha string Expected SHA-256, lowercase hex.
--- @param callback function fun(ok: boolean, err: string|nil)
local function verify_sha256_async(owner, path, expected_sha, callback)
	local task
	local start_gate, on_completion = latch_install_task_completion(owner, "checksum",
		function(rc, stdout)
			if task then M._active_tasks[task] = nil end
			release_install_task(owner, task)
			if not install_owner_is_current(owner) then
				settle_stopped_install_owner(owner, "stale checksum completion")
				return
			end
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
		end)
	task = TaskLifecycle.native("Karabiner installer checksum", "/usr/bin/shasum",
		on_completion, { "-a", "256", path })
	start_owned_task(owner, task, "checksum", "Karabiner installer checksum", callback, start_gate)
end

--- Downloads a URL to a destination file via curl, async. Creates the parent
--- directory beforehand if needed. Uses --fail so HTTP 4xx/5xx errors do not
--- silently produce a 0-byte file.
--- @param owner table Installer lifecycle owner.
--- @param url string Source URL.
--- @param dest string Absolute destination path.
--- @param callback function fun(ok: boolean, err: string|nil)
local function download_async(owner, url, dest, callback)
	local parent = dest:match("^(.*/)") or ""
	if parent ~= "" then
		local mkdir_ok, mkdir_output, mkdir_succeeded = xpcall(function()
			return hs.execute("/bin/mkdir -p " .. text_utils.shell_quote(parent))
		end, debug.traceback)
		if not mkdir_ok or mkdir_succeeded ~= true then
			callback(false, "Failed to prepare cache directory: " .. tostring(mkdir_output))
			return
		end
	end
	local task
	local start_gate, on_completion = latch_install_task_completion(owner, "download",
		function(rc, _, stderr)
			if task then M._active_tasks[task] = nil end
			release_install_task(owner, task)
			if not install_owner_is_current(owner) then
				if owner.unique_partial == nil then owner.unique_partial = dest end
				settle_stopped_install_owner(owner, "stale download completion")
				return
			end
			if rc ~= 0 then
				callback(false, "curl rc=" .. tostring(rc) .. " stderr=" .. tostring(stderr))
				return
			end
			callback(true, nil)
		end)
	task = TaskLifecycle.native("Karabiner installer download", "/usr/bin/curl",
		on_completion, { "-L", "--fail", "--silent", "--show-error", "--output", dest, url })
	start_owned_task(owner, task, "download", "Karabiner installer download", callback, start_gate)
end

--- Mounts a DMG via hdiutil, async. Returns the mount point on success.
--- @param owner table Installer lifecycle owner.
--- @param dmg_path string Absolute path to the .dmg.
--- @param callback function fun(ok: boolean, mount_point_or_err: string)
local function mount_dmg_async(owner, dmg_path, callback)
	local task
	local start_gate, on_completion = latch_install_task_completion(owner, "mount",
		function(rc, stdout, stderr)
			if task then M._active_tasks[task] = nil end
			release_install_task(owner, task)
			local mount_point
			if rc == 0 and type(stdout) == "string" then
				for line in stdout:gmatch("[^\n]+") do
					local parsed = line:match("(/Volumes/[^\t]+)")
					if parsed then mount_point = parsed end
				end
			end
			if not install_owner_is_current(owner) then
				if mount_point then owner.mount_point = mount_point end
				settle_stopped_install_owner(owner, "stale mount completion")
				return
			end
			if rc ~= 0 or type(stdout) ~= "string" then
				callback(false, "hdiutil rc=" .. tostring(rc) .. " stderr=" .. tostring(stderr))
				return
			end
			if not mount_point then
				callback(false, "Could not parse hdiutil output: " .. stdout)
				return
			end
			owner.mount_point = mount_point
			callback(true, mount_point)
		end)
	task = TaskLifecycle.native("Karabiner installer DMG mount", "/usr/bin/hdiutil",
		on_completion, { "attach", "-nobrowse", dmg_path })
	start_owned_task(owner, task, "mount", "Karabiner installer DMG mount", callback, start_gate)
end

--- Locates the .pkg sitting at the root of a mounted DMG. KE ships exactly
--- one .pkg per release.
--- @param mount_point string
--- @return string|nil pkg_path
--- @return string|nil err
local function find_pkg_in_volume(mount_point)
	local call_ok, out_or_err, succeeded = xpcall(function()
		return hs.execute("/bin/ls " .. text_utils.shell_quote(mount_point) .. " 2>&1")
	end, debug.traceback)
	if not call_ok or succeeded ~= true or type(out_or_err) ~= "string" then
		return nil, tostring(out_or_err)
	end
	local out = out_or_err
	for line in out:gmatch("[^\n]+") do
		if line:match("%.pkg$") then
			return mount_point .. "/" .. line, nil
		end
	end
	return nil, "no package found"
end

--- Runs `installer -pkg PATH -target /` with sudo, via osascript so macOS shows
--- its native admin password prompt. This is the only user-friendly way to
--- escalate from a Hammerspoon script.
--- @param owner table Installer lifecycle owner.
--- @param pkg_path string Absolute path to the .pkg.
--- @param callback function fun(ok: boolean, err: string|nil)
local function run_pkg_with_sudo_async(owner, pkg_path, callback)
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
	local start_gate, on_completion = latch_install_task_completion(owner, "install",
		function(rc, _, stderr)
			if task then M._active_tasks[task] = nil end
			release_install_task(owner, task)
			if not install_owner_is_current(owner) then
				settle_stopped_install_owner(owner, "stale package completion")
				return
			end
			if rc ~= 0 then
				callback(false, "osascript rc=" .. tostring(rc) .. " stderr=" .. tostring(stderr))
				return
			end
			callback(true, nil)
		end)
	task = TaskLifecycle.native("Karabiner package install", "/usr/bin/osascript",
		on_completion, { "-e", script })
	start_owned_task(owner, task, "install", "Karabiner package install", callback, start_gate)
end

--- Ensures the DMG is present in the cache and matches the manifest SHA-256.
--- If the cached file is missing or the hash mismatches, downloads fresh and
--- re-verifies. Calls callback(true) only when the cache file is verified good.
--- @param manifest table
--- @param cache_path string
--- @param callback function fun(ok: boolean, err: string|nil)
--- @param owner table|nil Exact owner supplied by install_karabiner_elements().
function M.ensure_dmg_cached(manifest, cache_path, callback, owner)
	owner = owner or M._install_owner
	if not install_owner_is_current(owner) then
		callback(false, "Installer authority is unavailable.")
		return false
	end

	local function fresh_download()
		if not install_owner_is_current(owner) then return false end
		local partial_path = make_unique_partial_path(cache_path)
		if not partial_path then
			callback(false, "Failed to allocate a unique download path.")
			return false
		end
		owner.unique_partial = partial_path
		Logger.start(LOG, "Downloading KE DMG (~46 MB) from %s…", manifest.source_url)
		notify(i18n.get("karabiner.downloading"), "info")
		download_async(owner, manifest.source_url, partial_path, function(ok_dl, err_dl)
			if not ok_dl then
				Logger.error(LOG, "Download failed: %s.", err_dl)
				settle_install_artifacts(owner, "download failure")
				callback(false, string.format(i18n.get("karabiner.download_failed"), tostring(err_dl)))
				return
			end
			if not install_owner_is_current(owner) then
				settle_stopped_install_owner(owner, "download successor fence")
				return
			end
			Logger.success(LOG, "Download complete.")
			Logger.start(LOG, "Verifying SHA-256…")
			verify_sha256_async(owner, partial_path, manifest.sha256, function(ok_sha, err_sha)
				if not ok_sha then
					Logger.error(LOG, "Hash verification failed: %s.", err_sha)
					settle_install_artifacts(owner, "checksum failure")
					callback(false, string.format(i18n.get("karabiner.sha_failed"), tostring(err_sha)))
					return
				end
				if not install_owner_is_current(owner) then
					settle_stopped_install_owner(owner, "checksum successor fence")
					return
				end
				local rename_ok, renamed_or_err, rename_err = xpcall(function()
					return os.rename(partial_path, cache_path)
				end, debug.traceback)
				if not rename_ok or renamed_or_err ~= true then
					Logger.error(LOG, "Verified DMG atomic cache promotion failed: %s.",
						tostring(rename_ok and rename_err or renamed_or_err))
					settle_install_artifacts(owner, "cache promotion failure")
					callback(false, "Verified DMG could not be published atomically.")
					return
				end
				owner.unique_partial = nil
				owner.cleanup_debt.partial = nil
				Logger.success(LOG, "SHA-256 verified.")
				callback(true, nil)
			end)
		end)
		return true
	end

	if not file_exists(cache_path) then
		Logger.debug(LOG, "Cache miss: '%s'.", cache_path)
		return fresh_download()
	end

	-- Cache hit — re-verify before trusting it. A previous partial download
	-- or bit rot would be invisible without this check.
	Logger.debug(LOG, "Cache hit, verifying SHA-256 before installer use.")
	verify_sha256_async(owner, cache_path, manifest.sha256, function(ok_sha, err_sha)
		if ok_sha then
			Logger.info(LOG, "Cached DMG SHA-256 verified; download skipped.")
			callback(true, nil)
			return
		end
		Logger.warn(LOG, "Cached DMG hash mismatch (%s) — redownloading.", tostring(err_sha))
		fresh_download()
	end)
	return true
end

--- High-level installer pipeline: ensures the DMG is cached + verified,
--- mounts it, runs the inner .pkg with sudo, then unmounts. Calls callback
--- exactly once with overall success/failure.
--- @param callback function fun(ok: boolean, err: string|nil) optional.
function M.install_karabiner_elements(callback)
	callback = callback or function() end
	if M._install_owner or #_stop_waiters > 0 then
		callback(false, "An installer operation is already active.")
		return false
	end
	_install_epoch = _install_epoch + 1
	local owner = {
		epoch = _install_epoch,
		stage = "preparing",
		tasks = {},
		mount_point = nil,
		unique_partial = nil,
		cleanup_debt = {
			callback = callback,
			cancel_detail = nil,
			cancel_requested = false,
			detached_mounts = {},
			mount_point = nil,
			partial = nil,
			pending = false,
			retry_attempts = 0,
			retry_timer_owner = nil,
			retry_timer_owners = {},
			tasks = {},
			termination_accepted = {},
			termination_decisions = {},
		},
		terminal = false,
	}
	M._install_owner = owner

	local manifest = M.load_manifest()
	if not manifest then
		finish_install_owner(owner, callback, false, "Manifest is unreadable.")
		return false
	end
	if M.manifest_is_unpinned(manifest) then
		Logger.warn(LOG, "Manifest unpinned (TODO placeholders) — auto-install disabled.")
		finish_install_owner(owner, callback, false,
			i18n.get("karabiner.onboarding.error.manifest_unconfigured"))
		return false
	end

	local cache_path = M.get_cache_dmg_path(manifest)
	Logger.start(LOG, "Installing Karabiner-Elements (cache='%s')…", cache_path)

	M.ensure_dmg_cached(manifest, cache_path, function(ok_cache, err_cache)
		if not install_owner_is_current(owner) then
			settle_stopped_install_owner(owner, "cache completion fence")
			return
		end
		if not ok_cache then
			finish_install_owner(owner, callback, false, err_cache)
			return
		end

		Logger.trace(LOG, "Mounting DMG…")
		mount_dmg_async(owner, cache_path, function(ok_mount, mount_or_err)
			if not ok_mount then
				Logger.error(LOG, "Mount failed: %s.", mount_or_err)
				-- Parenthesised so gsub's second return (the match count) does not leak in
				-- as callback's third argument, and escaped because the payload is raw
				-- hdiutil stderr — a "%" in it would raise inside this async callback,
				-- where the error reaches only the HS Console.
				finish_install_owner(owner, callback, false,
					(i18n.get("karabiner.onboarding.error.mount_failed")
						:gsub("{error}", text_utils.escape_gsub_replacement(tostring(mount_or_err)))))
				return
			end
			local mount_point = mount_or_err
			Logger.done(LOG, "Mounted at '%s'.", mount_point)
			if not install_owner_is_current(owner) then
				settle_stopped_install_owner(owner, "mount successor fence")
				return
			end

			local pkg_path, pkg_err = find_pkg_in_volume(mount_point)
			if not pkg_path then
				settle_install_artifacts(owner, "package discovery failure")
				Logger.error(LOG, "No .pkg found in mounted volume.")
				finish_install_owner(owner, callback, false,
					i18n.get("karabiner.pkg_not_found") .. ": " .. tostring(pkg_err))
				return
			end
			if not install_owner_is_current(owner) then
				settle_stopped_install_owner(owner, "privileged installer fence")
				return
			end

			Logger.info(LOG, "Running pkg installer; admin prompt expected.")
			notify(i18n.get("karabiner.installing"), "info")
			run_pkg_with_sudo_async(owner, pkg_path, function(ok_install, err_install)
				local artifacts_settled = settle_install_artifacts(owner,
					"package installer completion")
				if not ok_install then
					Logger.error(LOG, "Installer failed: %s.", err_install)
					finish_install_owner(owner, callback, false,
						string.format(i18n.get("karabiner.install_failed"), tostring(err_install)))
					return
				end
				if not artifacts_settled then
					Logger.error(LOG, "Installer succeeded but exact artifact cleanup remains pending.")
					finish_install_owner(owner, callback, false,
						"Installer cleanup remains pending.")
					return
				end
				Logger.success(LOG, "Karabiner-Elements installed.")
				finish_install_owner(owner, callback, true, nil)
			end)
		end)
	end, owner)
	return true
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
		complete_stop_waiters_if_settled()
		return true
	end
	local ok, result = xpcall(function()
		return TimerScheduler.cancel(owner.handle)
	end, debug.traceback)
	if ok and result == true then
		owner.handle = nil
		if _timer_owner == owner then _timer_owner = nil end
		complete_stop_waiters_if_settled()
		return true
	end
	Logger.error(LOG, "%s: exact onboarding timer cleanup remains pending — %s.",
		context, tostring(result))
	return false
end

--- Retries settlement of one exact wizard timer without acquiring a sibling.
--- @param owner table Timer transaction owner.
--- @param context string Operation requesting cancellation.
--- @return boolean settled True only after literal cancellation success.
local function cancel_timer_owner_bounded(owner, context)
	for attempt = 1, WIZARD_TIMER_MAX_ATTEMPTS do
		if cancel_timer_owner(owner, context) == true then return true end
		Logger.error(LOG, "%s: onboarding timer cleanup attempt %d/%d refused.",
			context, attempt, WIZARD_TIMER_MAX_ATTEMPTS)
	end
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
	return cancel_timer_owner_bounded(_timer_owner, context)
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
local function arm_owned_timer_once(method, delay, epoch, label, callback)
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
					cancel_timer_owner_bounded(owner, label .. " stale callback")
				end
				return
			end
			if owner.epoch ~= _wizard_epoch then
				owner.committed = false
				cancel_timer_owner_bounded(owner, label .. " stale epoch")
				return
			end
			if method == "after" then
				owner.committed = false
				cancel_timer_owner_bounded(owner, label .. " completion")
			end
			invoke_wizard_callback(label, function() callback(owner) end)
		end)
	end, debug.traceback)
	candidate = handle_or_err
	owner.handle = type(candidate) == "table" and candidate or nil
	owner.acquiring = false

	if not schedule_ok or committed ~= true or type(candidate) ~= "table" then
		owner.committed = false
		cancel_timer_owner_bounded(owner, label .. " acquisition rollback")
		Logger.error(LOG, "%s: onboarding timer acquisition failed — %s.",
			label, tostring(handle_or_err))
		return false
	end
	owner.committed = true
	return true
end

--- Acquires a wizard timer through one bounded constructor retry series.
--- Every refused candidate is settled exactly before a successor is attempted.
--- @param method string TimerScheduler method name.
--- @param delay number Delay or interval in seconds.
--- @param epoch number Wizard lifecycle epoch.
--- @param label string Stable operation label.
--- @param callback function fun(owner: table)
--- @return boolean committed True only when the native timer was armed.
local function arm_owned_timer(method, delay, epoch, label, callback)
	for _ = 1, WIZARD_TIMER_MAX_ATTEMPTS do
		if arm_owned_timer_once(method, delay, epoch, label, callback) == true then
			return true
		end
		if epoch ~= _wizard_epoch or _timer_owner ~= nil then return false end
	end
	return false
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
		cancel_timer_owner_bounded(owner, "poll_until terminal")
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

--- Revokes installer authority before terminating every exact native task.
--- Truthy native results only accept the termination signal; the exact callback
--- remains the process-exit proof. Refusal fails immediately, while accepted
--- signals and artifact debt receive bounded autonomous retries before timeout.
--- @param on_done function|nil Joined callback fn(ok, detail).
--- @return boolean accepted_or_settled Callback form reports acceptance; synchronous
--- form reports whether every onboarding owner is already settled.
function M.stop(on_done)
	local joins_settlement = type(on_done) == "function"
	if joins_settlement then _stop_waiters[#_stop_waiters + 1] = on_done end
	_wizard_epoch = _wizard_epoch + 1
	_install_epoch = _install_epoch + 1
	local installer_settled = true
	local termination_refused = false
	local install_owner = M._install_owner
	if install_owner then
		install_owner.cleanup_debt.cancel_requested = true
		install_owner.cleanup_debt.cancel_detail = "Installer cancelled."
		if install_owner.terminal ~= true then install_owner.stage = "stopping" end
		local tasks = {}
		for task in pairs(install_owner.tasks) do tasks[#tasks + 1] = task end
		for _, task in ipairs(tasks) do
			if install_owner.tasks[task] ~= nil
				and request_install_task_termination(install_owner, task, "M.stop") ~= true then
				termination_refused = true
			end
		end
		if termination_refused then
			fail_install_cleanup(install_owner, "onboarding-task-termination-refused")
		end
		installer_settled = settle_stopped_install_owner(install_owner, "M.stop")
	end
	local timer_settled = true
	if _timer_owner then
		local owner = _timer_owner
		owner.committed = false
		timer_settled = cancel_timer_owner_bounded(owner, "M.stop")
	end
	local settled = installer_settled and timer_settled
	if joins_settlement and timer_settled ~= true then
		_stop_failure_detail = "onboarding-stop-incomplete"
	end
	if settled then
		complete_stop_waiters_if_settled()
	elseif termination_refused or (install_owner and install_owner.terminal == true) then
		Logger.error(LOG, "Onboarding stop incomplete; exact cleanup debt retained for retry.")
		complete_stop_waiters(false, "onboarding-stop-incomplete")
	elseif timer_settled ~= true then
		Logger.error(LOG, "Onboarding timer stop incomplete; exact cleanup debt retained for retry.")
		if M._install_owner == nil then
			complete_stop_waiters(false, "onboarding-stop-incomplete")
		else
			Logger.debug(LOG,
				"Onboarding stop is awaiting installer terminal before reporting timer failure.")
		end
	else
		Logger.debug(LOG, "Onboarding stop is awaiting exact installer cleanup settlement.")
	end
	if joins_settlement then return true end
	return settled and not termination_refused
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
		if cancel_timer_owner_bounded(owner, "run_first_run_wizard replacement") ~= true then
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
