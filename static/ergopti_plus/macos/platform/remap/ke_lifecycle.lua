--- platform/remap/ke_lifecycle.lua

--- ==============================================================================
--- MODULE: Karabiner Lease Status and Notifications
--- DESCRIPTION:
--- Exposes read-only Karabiner health/status helpers and owns the delayed
--- user-facing notification emitted when Ergopti's exact lease becomes ready.
--- Official Karabiner processes remain entirely user-managed: this module never
--- starts, stops, signals, launchd-mutates or claims ownership of them.
---
--- FEATURES & RATIONALE:
--- 1. Lease-derived status: Menu state comes from Ergopti's controller rather
---    than process names shared with the user's personal Karabiner setup.
--- 2. Explicit GUI opening: The stock app may be opened only from the dedicated
---    user action; it is never launched as an automatic bridge bootstrap.
--- 3. Read-only onboarding probe: Installation guidance may check whether the
---    stock daemon exists without using that observation as ownership evidence.
--- 4. Deferred ready notification: Boot gating and cooldown retries keep the
---    banner accurate without losing a completion that arrives during startup.
--- ==============================================================================

local M = {}

local hs            = hs
local Logger        = require("infra.logger")
local Storage       = require("adapters.storage")
local Notifications = require("infra.notifications")
local i18n          = require("infra.i18n")
local text_utils    = require("infra.text_utils")
local KePaths       = require("platform.remap.ke_paths")

local LOG = "karabiner"

-- Health is about the keyboard-processing service, not "some Karabiner binary".
-- The broad installation-directory probe used here previously was also true for
-- the UI, EventViewer and auxiliary agents, so onboarding could report a dead
-- Core Service as healthy. Current Karabiner also has a logged-in-user agent
-- with the same executable name as the root daemon, so the effective-user filter
-- is required in addition to the exact executable. `-f -x` deliberately uses
-- the complete argv from the upstream plists instead of depending on platform-
-- specific command-name truncation behavior.
local ERE_SPECIAL = {
	["\\"] = true, ["."] = true, ["["] = true, ["]"] = true,
	["("] = true, [")"] = true, ["{"] = true, ["}"] = true,
	["^"] = true, ["$"] = true, ["*"] = true, ["+"] = true,
	["?"] = true, ["|"] = true,
}

--- Escapes one literal argv value for pgrep's POSIX extended regex matcher.
--- @param value string Literal executable path.
--- @return string escaped
local function ere_literal(value)
	return (value:gsub(".", function(character)
		return ERE_SPECIAL[character] and ("\\" .. character) or character
	end))
end

-- Both paths cover the v15.7 rename without assigning ownership to either
-- shared process. Grouping makes the diagnostic redirection apply to both
-- probes rather than only the fallback after `||`.
local KE_GRABBER_CHECK = "{ /usr/bin/pgrep -q -u root -f -x "
	.. text_utils.shell_quote(ere_literal(KePaths.CORE_SERVICE))
	.. " || /usr/bin/pgrep -q -u root -f -x "
	.. text_utils.shell_quote(ere_literal(KePaths.GRABBER))
	.. "; } 2>/dev/null"

local KARABINER_READY_NOTIFY_COOLDOWN_SEC = 10
local KARABINER_READY_NOTIFY_DELAY_SEC    = 2.5
local KARABINER_READY_RETRY_EPSILON_SEC   = 0.1
local KARABINER_READY_FAILURE_RETRY_SEC   = KARABINER_READY_NOTIFY_COOLDOWN_SEC
	+ KARABINER_READY_RETRY_EPSILON_SEC

local _last_karabiner_ready_notify_at = 0
local _pending_karabiner_ready_notify = false
local _karabiner_ready_notify_timer   = nil
local _karabiner_ready_retry_timer    = nil
local _pending_karabiner_ready_token  = nil
local _karabiner_ready_notify_epoch   = 0
local _karabiner_ready_timer_cleanup  = {}
local _lease_status_error_logged      = false

--- Single source of truth for the boot-readiness setting consumed below.
M.HS_BOOT_READY_SETTING_KEY = "hs_boot_ready_v1"
local HS_BOOT_READY_SETTING_KEY = M.HS_BOOT_READY_SETTING_KEY





-- =====================================
-- =====================================
-- ======= 1/ Lease Status Views =======
-- =====================================
-- =====================================

--- Reads the controller's in-memory state without touching any stock process.
--- @return string phase Controller lifecycle phase.
--- @return table snapshot Controller status snapshot.
local function read_lease_status()
	local ok_require, Lease = pcall(require, "platform.remap.lease_controller")
	if not ok_require or type(Lease) ~= "table" or type(Lease.status) ~= "function" then
		if not _lease_status_error_logged then
			_lease_status_error_logged = true
			Logger.error(LOG, "Lease controller unavailable — Ergopti remapping is fail-closed.")
		end
		return "failed", {}
	end

	local ok_status, phase, snapshot = pcall(Lease.status)
	if not ok_status or type(phase) ~= "string" then
		if not _lease_status_error_logged then
			_lease_status_error_logged = true
			Logger.error(LOG, "Lease status unavailable — Ergopti remapping is fail-closed: %s.",
				tostring(phase))
		end
		return "failed", {}
	end

	_lease_status_error_logged = false
	return phase, type(snapshot) == "table" and snapshot or {}
end

--- Returns the exact Ergopti lease status without probing Karabiner processes.
--- @return string phase Controller lifecycle phase.
--- @return table snapshot Controller status snapshot.
function M.status()
	return read_lease_status()
end

--- Returns true only while the Ergopti lease is actively permitting rules.
--- @return boolean
function M.is_remapping_active()
	local phase = read_lease_status()
	return phase == "active"
end

--- Returns true while an Ergopti lease is attached to a live controller task.
--- This is a compatibility view for status consumers, not a process probe.
--- @return boolean
function M.is_bridge_running()
	local phase = read_lease_status()
	return phase == "active" or phase == "paused" or phase == "pausing"
		or phase == "resuming" or phase == "stopping"
end

--- Returns true while the controller is transitioning toward an active lease.
--- @return boolean
function M.is_priming()
	local phase = read_lease_status()
	return phase == "starting" or phase == "resuming"
end

--- Performs the read-only daemon probe used exclusively by onboarding health checks.
--- The result never authorizes a kill, launch, lease or ownership decision.
--- @return boolean
function M.is_grabber_running()
	local ok_call, _, ok_process = pcall(hs.execute, KE_GRABBER_CHECK)
	return ok_call and ok_process == true
end

--- Opens the stock Karabiner GUI after an explicit user menu action.
--- @return boolean True when either launch mechanism accepted the request.
function M.open_gui()
	Logger.start(LOG, "Opening Karabiner-Elements by explicit user request…")
	local ok_launch, launched = pcall(hs.application.launchOrFocus, "Karabiner-Elements")
	if ok_launch and launched ~= false then
		Logger.success(LOG, "Karabiner-Elements open request accepted.")
		return true
	end

	local command = "open -a " .. text_utils.shell_quote("Karabiner-Elements") .. " 2>/dev/null"
	local ok_execute, _, opened = pcall(hs.execute, command)
	if ok_execute and opened == true then
		Logger.success(LOG, "Karabiner-Elements open request accepted through Launch Services.")
		return true
	end

	Logger.error(LOG, "Karabiner-Elements could not be opened by explicit user request.")
	return false
end





-- ==========================================
-- ==========================================
-- ======= 2/ Ready Notification Gate =======
-- ==========================================
-- ==========================================

--- Returns true only after the root boot sequence has completed.
--- @return boolean
local function is_hs_boot_ready()
	return Storage.get(HS_BOOT_READY_SETTING_KEY) == true
end

--- Returns the token only while the exact generation is actively remapping.
--- @return string|nil token Active generation token.
local function active_lease_token()
	local phase, snapshot = read_lease_status()
	if phase ~= "active" or type(snapshot.token) ~= "string" or snapshot.token == "" then return nil end
	return snapshot.token
end

--- Appends one present timer handle without creating an ipairs-visible nil gap.
--- @param timers table Dense timer-entry list.
--- @param timer table|userdata|nil Exact timer handle.
--- @param label string Diagnostic role.
local function append_ready_timer(timers, timer, label)
	if timer then timers[#timers + 1] = { timer = timer, label = label } end
end

--- Stops exact notification timers and retains failed handles for a later retry.
--- The callback epoch is invalidated before this helper is called, so a timer
--- whose host-side cancellation fails is already harmless.
--- @param timers table|nil Additional exact handles to retire.
--- @return boolean all_stopped
local function stop_ready_timers(timers)
	local candidates = _karabiner_ready_timer_cleanup
	_karabiner_ready_timer_cleanup = {}
	for _, entry in ipairs(timers or {}) do candidates[#candidates + 1] = entry end

	local all_stopped = true
	for _, entry in ipairs(candidates) do
		local ok, err = pcall(function()
			if type(entry.timer) ~= "table" and type(entry.timer) ~= "userdata" then
				error("invalid timer handle")
			end
			if type(entry.timer.stop) ~= "function" then error("timer stop method unavailable") end
			entry.timer:stop()
		end)
		if not ok then
			all_stopped = false
			_karabiner_ready_timer_cleanup[#_karabiner_ready_timer_cleanup + 1] = entry
			Logger.error(LOG, "Karabiner ready %s timer cancellation failed: %s.",
				entry.label, tostring(err))
		end
	end
	return all_stopped
end

--- Arms a bounded retry after an async ready callback failure.
--- @param expected_token string Exact generation that still owns the banner.
--- @param epoch integer Notification lifecycle captured by the failed callback.
--- @return boolean scheduled
local function arm_failed_ready_retry(expected_token, epoch)
	if epoch ~= _karabiner_ready_notify_epoch then return false end
	_pending_karabiner_ready_notify = true
	_pending_karabiner_ready_token = expected_token

	local previous_retry = _karabiner_ready_retry_timer
	_karabiner_ready_retry_timer = nil
	local timers_to_stop = {}
	append_ready_timer(timers_to_stop, previous_retry, "callback-retry")
	stop_ready_timers(timers_to_stop)

	local retry_timer
	local retry_timer_published = false
	local retry_fired_before_publication = false
	local function retry_callback()
		if not retry_timer_published then
			retry_fired_before_publication = true
			return
		end
		if epoch ~= _karabiner_ready_notify_epoch
			or _karabiner_ready_retry_timer ~= retry_timer then return end
		_karabiner_ready_retry_timer = nil
		local ok_retry, retry_err = xpcall(function()
			M.flush_pending_ready_notification()
		end, debug.traceback)
		if not ok_retry and epoch == _karabiner_ready_notify_epoch then
			_pending_karabiner_ready_notify = true
			_pending_karabiner_ready_token = expected_token
			Logger.error(LOG, "Karabiner ready notification retry callback failed: %s.",
				tostring(retry_err))
			arm_failed_ready_retry(expected_token, epoch)
		end
	end
	local ok_create, timer_or_err = pcall(function()
		retry_timer = hs.timer.doAfter(KARABINER_READY_FAILURE_RETRY_SEC, retry_callback)
		return retry_timer
	end)
	if not ok_create or not retry_timer then
		Logger.error(LOG, "Karabiner ready notification retry timer creation failed: %s.",
			tostring(ok_create and "no timer returned" or timer_or_err))
		return false
	end
	_karabiner_ready_retry_timer = retry_timer
	retry_timer_published = true
	if retry_fired_before_publication then retry_callback() end
	return true
end

--- Dispatches the delayed ready notification with cooldown and retry handling.
--- @param expected_token string Generation that earned the READY notification.
local function notify_karabiner_ready(expected_token)
	if type(expected_token) ~= "string" or expected_token == "" then return end
	_karabiner_ready_notify_epoch = _karabiner_ready_notify_epoch + 1
	local epoch = _karabiner_ready_notify_epoch
	local previous_notify = _karabiner_ready_notify_timer
	local previous_retry = _karabiner_ready_retry_timer
	_karabiner_ready_notify_timer = nil
	_karabiner_ready_retry_timer = nil
	local timers_to_stop = {}
	append_ready_timer(timers_to_stop, previous_notify, "delay")
	append_ready_timer(timers_to_stop, previous_retry, "retry")
	stop_ready_timers(timers_to_stop)

	if not is_hs_boot_ready() then
		_pending_karabiner_ready_notify = true
		_pending_karabiner_ready_token = expected_token
		Logger.debug(LOG, "Karabiner ready notification deferred until boot completes.")
		return
	end

	_pending_karabiner_ready_notify = false
	_pending_karabiner_ready_token = expected_token
	local notify_timer
	local notify_timer_published = false
	local notify_fired_before_publication = false
	local function send_ready_notification(now)
		Notifications.notify(
			i18n.get("karabiner.ready_title"),
			i18n.get("karabiner.ready_body"),
			"success"
		)
		_last_karabiner_ready_notify_at = now
		_pending_karabiner_ready_notify = false
		_pending_karabiner_ready_token = nil
		Logger.info(LOG, "Karabiner ready notification sent.")
	end
	local function delayed_notify_callback()
		if not notify_timer_published then
			notify_fired_before_publication = true
			return
		end
		if epoch ~= _karabiner_ready_notify_epoch then return end
		if notify_timer and _karabiner_ready_notify_timer ~= notify_timer then return end
		if _karabiner_ready_notify_timer == notify_timer then
			_karabiner_ready_notify_timer = nil
		end

		local ok, err = xpcall(function()
			if not is_hs_boot_ready() then
				_pending_karabiner_ready_notify = true
				_pending_karabiner_ready_token = expected_token
				Logger.debug(LOG, "Karabiner ready notification postponed — boot not ready.")
				return
			end
			if active_lease_token() ~= expected_token then
				_pending_karabiner_ready_notify = false
				_pending_karabiner_ready_token = nil
				Logger.debug(LOG, "Karabiner ready notification cancelled — lease generation is no longer active.")
				return
			end

			local now = hs.timer.secondsSinceEpoch()
			if (now - _last_karabiner_ready_notify_at) < KARABINER_READY_NOTIFY_COOLDOWN_SEC then
				Logger.debug(LOG, "Karabiner ready notification skipped (cooldown %.1fs) — will retry.",
					KARABINER_READY_NOTIFY_COOLDOWN_SEC)
				_pending_karabiner_ready_notify = true
				_pending_karabiner_ready_token = expected_token
				local previous_cooldown_retry = _karabiner_ready_retry_timer
				_karabiner_ready_retry_timer = nil
				local cooldown_timers_to_stop = {}
				append_ready_timer(cooldown_timers_to_stop, previous_cooldown_retry,
					"cooldown-retry")
				stop_ready_timers(cooldown_timers_to_stop)
				local retry_delay = KARABINER_READY_NOTIFY_COOLDOWN_SEC
					- (now - _last_karabiner_ready_notify_at)
					+ KARABINER_READY_RETRY_EPSILON_SEC
				local retry_timer
				local retry_timer_published = false
				local retry_fired_before_publication = false
				local function cooldown_retry_callback()
					if not retry_timer_published then
						retry_fired_before_publication = true
						return
					end
					if epoch ~= _karabiner_ready_notify_epoch
						or _karabiner_ready_retry_timer ~= retry_timer then return end
					_karabiner_ready_retry_timer = nil
					local ok_retry, retry_err = xpcall(function()
						M.flush_pending_ready_notification()
					end, debug.traceback)
					if not ok_retry and epoch == _karabiner_ready_notify_epoch then
						_pending_karabiner_ready_notify = true
						_pending_karabiner_ready_token = expected_token
						Logger.error(LOG, "Karabiner ready cooldown retry callback failed: %s.",
							tostring(retry_err))
						arm_failed_ready_retry(expected_token, epoch)
					end
				end
				local ok_retry_timer, retry_timer_or_err = pcall(function()
					retry_timer = hs.timer.doAfter(retry_delay, cooldown_retry_callback)
					return retry_timer
				end)
				if ok_retry_timer and retry_timer then
					_karabiner_ready_retry_timer = retry_timer
					retry_timer_published = true
					if retry_fired_before_publication then cooldown_retry_callback() end
					return
				end
				Logger.error(LOG, "Karabiner ready cooldown retry timer creation failed: %s.",
					tostring(ok_retry_timer and "no timer returned" or retry_timer_or_err))
				Logger.warn(LOG, "Karabiner ready notification cooldown bypassed because retry scheduling failed.")
				send_ready_notification(now)
				return
			end

			send_ready_notification(now)
		end, debug.traceback)
		if not ok and epoch == _karabiner_ready_notify_epoch then
			_pending_karabiner_ready_notify = true
			_pending_karabiner_ready_token = expected_token
			Logger.error(LOG, "Karabiner ready notification callback failed: %s.", tostring(err))
			arm_failed_ready_retry(expected_token, epoch)
		end
	end

	local ok_create, timer_or_err = pcall(function()
		notify_timer = hs.timer.doAfter(KARABINER_READY_NOTIFY_DELAY_SEC, delayed_notify_callback)
		return notify_timer
	end)
	if ok_create and notify_timer then
		_karabiner_ready_notify_timer = notify_timer
		notify_timer_published = true
		if notify_fired_before_publication then delayed_notify_callback() end
		return
	end

	Logger.error(LOG, "Karabiner ready notification delay timer creation failed: %s.",
		tostring(ok_create and "no timer returned" or timer_or_err))
	-- Timer allocation is a presentation failure, not a reason to lose an exact
	-- READY completion. Re-run the same token/boot/cooldown gates synchronously.
	notify_timer_published = true
	delayed_notify_callback()
end

--- Queues the user-facing ready notification after a successful lease READY.
function M.notify_ready()
	local token = active_lease_token()
	if not token then
		Logger.debug(LOG, "Karabiner ready notification ignored — no active exact lease.")
		return
	end
	notify_karabiner_ready(token)
end

--- Flushes a ready notification deferred until root boot completion.
function M.flush_pending_ready_notification()
	if not _pending_karabiner_ready_notify or not is_hs_boot_ready() then return end
	local token = _pending_karabiner_ready_token
	Logger.debug(LOG, "Flushing pending Karabiner ready notification…")
	_pending_karabiner_ready_notify = false
	_pending_karabiner_ready_token = nil
	notify_karabiner_ready(token)
end

--- Cancels notification timers owned by this module during teardown.
--- Failed host-side stops are retained for the next exact cleanup attempt, but
--- the epoch makes their callbacks inert immediately.
--- @return boolean all_stopped
function M.stop()
	_karabiner_ready_notify_epoch = _karabiner_ready_notify_epoch + 1
	local notify_timer = _karabiner_ready_notify_timer
	local retry_timer = _karabiner_ready_retry_timer
	_karabiner_ready_notify_timer = nil
	_karabiner_ready_retry_timer = nil
	_pending_karabiner_ready_notify = false
	_pending_karabiner_ready_token = nil
	local timers_to_stop = {}
	append_ready_timer(timers_to_stop, notify_timer, "delay")
	append_ready_timer(timers_to_stop, retry_timer, "retry")
	return stop_ready_timers(timers_to_stop)
end

return M
