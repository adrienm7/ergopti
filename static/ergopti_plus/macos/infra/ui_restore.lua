--- infra/ui_restore.lua

--- ==============================================================================
--- MODULE: UI Restore
--- DESCRIPTION:
--- Protects open UI windows against file-watcher-triggered Hammerspoon reloads
--- using two complementary strategies.
---
--- Primary strategy — Deferral (defer_reload):
---   When a reload is requested while a registered UI is open, the reload is
---   held in a pending state. A poll timer checks every second; once all
---   registered UIs are closed, the reload fires automatically. The user is
---   never interrupted mid-consultation.
---
--- Safety-net strategy — Snapshot / Restore:
---   For reloads that bypass the deferral (manual hs.reload(), crash), snapshot()
---   records open UIs in hs.settings before the process exits, and restore()
---   reopens them 0.5 s after the new session boots.
---
--- FEATURES & RATIONALE:
--- 1. Declarative Registry: Each restorable UI contributes a key, an is_open()
---    guard, and a reopen() action. init.lua stays agnostic of individual UIs.
--- 2. Settings Bus: hs.settings survives hs.reload(), making it the correct
---    persistence layer for the open-UI list across a process restart.
--- 3. Selective Scope: Only "view / consultation" UIs whose state can be fully
---    recreated are registered. Transient operation windows (downloads, editors
---    that depend on live callbacks) are intentionally excluded because their
---    context is lost after a reload.
--- ==============================================================================

local M = {}

local hs      = hs
local Logger  = require("infra.logger")
local Timings = require("infra.timings")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG          = "ui_restore"
local SETTINGS_KEY = "ergopti_ui_restore_state"

-- How often the deferred-reload poller wakes up to check whether all UIs closed.
-- Shared cross-driver value ([ui] ui_restore_poll_ms).
local POLL_INTERVAL_SEC = Timings.sec("ui", "ui_restore_poll_ms")
local RESTORE_DELAY_SEC = 0.5





-- =========================================
-- =========================================
-- ======= 1/ Restorable UI Registry =======
-- =========================================
-- =========================================

-- Each entry:
--   key     — string stored in hs.settings to identify this UI
--   is_open — function() → boolean: true when the window is currently visible
--   reopen  — function(): reopens the window; called 0.5 s after boot
--
-- Exclusions and rationale:
--   download_window      — mid-operation transient; _wv is a module-local
--   prompt_editor        — depends on an on_save callback that is lost at reload
--   personal_info_editor — same; also depends on current_info provided by caller
local REGISTRY = {
	{
		key = "metrics_typing",
		is_open = function()
			local m = package.loaded["ui.metrics_typing.init"]
				or package.loaded["ui.metrics_typing"]
			return m ~= nil and m._wv ~= nil
		end,
		reopen = function()
			local ok, m = pcall(require, "ui.metrics_typing.init")
			if ok and m and type(m.show) == "function" then
				m.show(hs.configdir .. "/logs")
			end
		end,
	},
	{
		key = "metrics_apps",
		is_open = function()
			local m = package.loaded["ui.metrics_apps.init"]
				or package.loaded["ui.metrics_apps"]
			return m ~= nil and m._wv ~= nil
		end,
		reopen = function()
			local ok, m = pcall(require, "ui.metrics_apps")
			if ok and m and type(m.show) == "function" then
				m.show(hs.configdir .. "/logs")
			end
		end,
	},
	{
		key = "hotstring_editor",
		is_open = function()
			local m = package.loaded["ui.hotstring_editor"]
			return m ~= nil
				and type(m.is_open) == "function"
				and m.is_open()
		end,
		-- The editor is already init()'d during normal boot; just call open()
		reopen = function()
			local m = package.loaded["ui.hotstring_editor"]
			if m and type(m.open) == "function" then
				m.open("menu")
			end
		end,
	},
}

-- Delayed restore owners are declared above M.restore() so its closure captures
-- local lifecycle state rather than nil globals (Lua local-after-closure rule)
local _restore_timers = {}
local _restore_generation = 0
local schedule_ui_restore





-- =====================================
-- =====================================
-- ======= 2/ Snapshot & Restore =======
-- =====================================
-- =====================================

--- Records which registered UIs are currently open into hs.settings so they
--- can be restored after an uncontrolled hs.reload() (crash, manual reload).
--- Under normal deferral, the UIs are already closed before reload fires, so
--- this function saves nothing — it is a pure safety net.
function M.snapshot()
	local open_keys = {}
	for _, entry in ipairs(REGISTRY) do
		local ok, result = pcall(entry.is_open)
		if ok and result then
			table.insert(open_keys, entry.key)
			Logger.debug(LOG, "UI '%s' flagged for post-reload restore.", entry.key)
		end
	end
	-- Persist only when there is something to restore; clear otherwise to
	-- avoid stale entries from a previous crash bleeding into the next session
	if #open_keys > 0 then
		hs.settings.set(SETTINGS_KEY, open_keys)
	else
		hs.settings.set(SETTINGS_KEY, nil)
	end
end

--- Reopens any UIs that were open before the last uncontrolled reload.
--- Must be called after all modules have been initialized (post menu.start()).
function M.restore()
	local open_keys = hs.settings.get(SETTINGS_KEY)
	if not open_keys or type(open_keys) ~= "table" or #open_keys == 0 then return true end

	-- Clear immediately so a crash during restore does not cause an infinite
	-- reopen loop on the next boot
	hs.settings.set(SETTINGS_KEY, nil)

	local key_set = {}
	for _, k in ipairs(open_keys) do key_set[k] = true end

	local restored = true
	for _, entry in ipairs(REGISTRY) do
		if key_set[entry.key] then
			Logger.info(LOG, "Restoring UI '%s' after reload.", entry.key)
			if schedule_ui_restore(entry) ~= true then restored = false end
		end
	end
	return restored
end





-- =======================================
-- =======================================
-- ======= 3/ Deferred Reload Gate =======
-- =======================================
-- =======================================

-- Holds the pending reload callback while at least one registered UI is open
local _pending_reload_fn = nil
local _poll_timer        = nil
local _poll_timer_committed = false
local _poll_generation   = 0
local _dispatch_timer    = nil
local _dispatch_timer_committed = false
local _dispatch_generation = 0
-- Reentrancy guard: prevents a second defer_reload() called from inside fn()
-- from double-firing (fast-path would fire immediately since no UI is open)
local _reload_in_flight  = false

--- Returns true if at least one registered UI is currently open.
local function any_ui_open()
	for _, entry in ipairs(REGISTRY) do
		local ok, result = pcall(entry.is_open)
		if ok and result then return true end
	end
	return false
end

-- Forward declarations keep these lifecycle helpers as local upvalues for the
-- reload callback path that can re-enter before their definitions execute
local arm_poll_timer
local arm_dispatch_timer

--- Cancels the exact poller capability and retains it when cleanup refuses.
--- The generation is fenced before crossing the async cancellation boundary.
--- @return boolean settled True only when no native poller remains owned.
local function cancel_poll_timer()
	_poll_generation = _poll_generation + 1
	_poll_timer_committed = false
	if not _poll_timer then return true end
	local handle = _poll_timer
	local ok, stopped = xpcall(function()
		return TimerScheduler.cancel(handle)
	end, debug.traceback)
	if not ok or stopped ~= true then
		Logger.error(LOG, "Deferred-reload poller cleanup failed; exact timer retained: %s.",
			tostring(ok and stopped or stopped))
		return false
	end
	if _poll_timer == handle then _poll_timer = nil end
	return true
end

--- Cancels the exact re-entrant dispatch timer and retains stop debt.
--- @return boolean settled True only when no native dispatch timer remains.
local function cancel_dispatch_timer()
	_dispatch_generation = _dispatch_generation + 1
	_dispatch_timer_committed = false
	if not _dispatch_timer then return true end
	local handle = _dispatch_timer
	local ok, stopped = xpcall(function()
		return TimerScheduler.cancel(handle)
	end, debug.traceback)
	if not ok or stopped ~= true then
		Logger.error(LOG, "Deferred-reload dispatch cleanup failed; exact timer retained: %s.",
			tostring(ok and stopped or stopped))
		return false
	end
	if _dispatch_timer == handle then _dispatch_timer = nil end
	return true
end

--- Cancels every delayed UI restore while retaining each refused handle.
--- @return boolean settled True only when every exact timer was released.
local function cancel_restore_timers()
	_restore_generation = _restore_generation + 1
	local snapshot = {}
	for handle in pairs(_restore_timers) do snapshot[#snapshot + 1] = handle end
	local settled = true
	for _, handle in ipairs(snapshot) do
		local ok, stopped = xpcall(function()
			return TimerScheduler.cancel(handle)
		end, debug.traceback)
		if ok and stopped == true then
			_restore_timers[handle] = nil
		else
			settled = false
			Logger.error(LOG, "UI restore timer cleanup failed; exact timer retained: %s.",
				tostring(ok and stopped or stopped))
		end
	end
	return settled
end

--- Reopens one remembered UI under a lifecycle-owned one-shot timer.
--- A scheduler failure falls back to an immediate protected call so a promised
--- UI is never silently dropped merely because the timer runtime is degraded.
--- @param entry table Registry entry with key and reopen callback.
--- @return boolean committed True only when the delayed owner was armed.
schedule_ui_restore = function(entry)
	local generation = _restore_generation
	local activation_in_progress = true
	local timer_committed = false
	local handle
	local schedule_ok, candidate, committed = xpcall(function()
		return TimerScheduler.after(RESTORE_DELAY_SEC, function()
			if activation_in_progress
			or timer_committed ~= true
			or generation ~= _restore_generation
			or not _restore_timers[handle]
			then
				return
			end
			-- TimerScheduler has logically consumed this one-shot. Keep its local
			-- owner only when native stop debt remains for M.stop() to retry
			if handle.timer == nil then _restore_timers[handle] = nil end
			local ok, err = xpcall(entry.reopen, debug.traceback)
			if not ok then
				Logger.error(LOG, "Failed to restore UI '%s': %s.", entry.key, tostring(err))
			end
		end)
	end, debug.traceback)
	activation_in_progress = false
	handle = candidate
	if type(handle) == "table" then _restore_timers[handle] = true end
	if not schedule_ok or type(handle) ~= "table" or committed ~= true then
		if type(handle) == "table" then
			local cancel_ok, cancelled = xpcall(function()
				return TimerScheduler.cancel(handle)
			end, debug.traceback)
			if cancel_ok and cancelled == true then _restore_timers[handle] = nil end
		end
		Logger.error(LOG, "UI '%s' restore timer unavailable; reopening immediately: %s.",
			entry.key, tostring(schedule_ok and committed or candidate))
		local reopen_ok, reopen_err = xpcall(entry.reopen, debug.traceback)
		if not reopen_ok then
			Logger.error(LOG, "Immediate UI restore failed for '%s': %s.",
				entry.key, tostring(reopen_err))
		end
		return false
	end
	timer_committed = true
	return true
end

--- Invokes one reload callback under the shared reentrancy latch.
--- @param reload_fn function Zero-argument reload callback.
--- @param path string Diagnostic name for the invocation path.
--- @return boolean completed True when the callback returned normally.
local function invoke_reload(reload_fn, path)
	_reload_in_flight = true
	local ok, err = xpcall(reload_fn, debug.traceback)
	_reload_in_flight = false
	if not ok then
		Logger.error(LOG, "defer_reload %s error: %s.", path, tostring(err))
	end

	-- A reload callback can be refused/non-terminal and re-enter defer_reload().
	-- Give that queued request a new async opportunity after the outer stack has
	-- unwound; merely storing it here stranded the callback forever.
	if _pending_reload_fn then
		if any_ui_open() then
			if not _poll_timer then arm_poll_timer() end
		else
			arm_dispatch_timer()
		end
	end
	return ok
end

--- Arms the one recurring poller for the current pending reload batch.
--- Scheduling failure deliberately executes the pending callback immediately:
--- a reload that cannot be deferred must recover the broken timer runtime rather
--- than remain parked forever with no native owner capable of waking it.
--- @return boolean committed True only when the poller was armed.
arm_poll_timer = function()
	local reload_fn = _pending_reload_fn
	_poll_generation = _poll_generation + 1
	local generation = _poll_generation
	local activation_in_progress = true
	local handle
	local schedule_ok, candidate, committed = xpcall(function()
		return TimerScheduler.every(POLL_INTERVAL_SEC, function()
			if activation_in_progress
			or generation ~= _poll_generation
			or _poll_timer ~= handle
			or _poll_timer_committed ~= true
			then
				return
			end
			if any_ui_open() then return end

			local fn = _pending_reload_fn
			_pending_reload_fn = nil
			cancel_poll_timer()
			if fn then
				Logger.info(LOG, "All protected UIs closed — firing deferred reload.")
				invoke_reload(fn, "timer-path")
			end
		end)
	end, debug.traceback)
	activation_in_progress = false
	handle = candidate

	if type(handle) == "table" then _poll_timer = handle end
	if not schedule_ok or type(handle) ~= "table" or committed ~= true then
		_poll_timer_committed = false
		_pending_reload_fn = nil
		cancel_poll_timer()
		Logger.error(LOG,
			"Deferred-reload poller unavailable; firing the reload immediately: %s.",
			tostring(schedule_ok and committed or candidate))
		if reload_fn then invoke_reload(reload_fn, "poller-fallback") end
		return false
	end

	_poll_timer_committed = true
	return true
end

--- Arms a one-shot dispatch for a reload queued by a re-entrant callback.
--- @return boolean committed True only when the dispatch timer was armed.
arm_dispatch_timer = function()
	if _dispatch_timer and _dispatch_timer_committed == true then return true end
	if _dispatch_timer and not cancel_dispatch_timer() then
		Logger.error(LOG, "Re-entrant reload dispatch blocked by timer cleanup debt.")
		return false
	end

	_dispatch_generation = _dispatch_generation + 1
	local generation = _dispatch_generation
	local activation_in_progress = true
	local handle
	local schedule_ok, candidate, committed = xpcall(function()
		return TimerScheduler.after(0, function()
			if activation_in_progress
			or generation ~= _dispatch_generation
			or _dispatch_timer ~= handle
			or _dispatch_timer_committed ~= true
			then
				return
			end
			_dispatch_timer_committed = false
			if handle and handle.timer == nil then _dispatch_timer = nil end

			local fn = _pending_reload_fn
			_pending_reload_fn = nil
			if not fn then return end
			if any_ui_open() then
				_pending_reload_fn = fn
				arm_poll_timer()
			else
				invoke_reload(fn, "re-entrant dispatch")
			end
		end)
	end, debug.traceback)
	activation_in_progress = false
	handle = candidate
	if type(handle) == "table" then _dispatch_timer = handle end
	if not schedule_ok or type(handle) ~= "table" or committed ~= true then
		_dispatch_timer_committed = false
		cancel_dispatch_timer()
		local fn = _pending_reload_fn
		_pending_reload_fn = nil
		Logger.error(LOG, "Re-entrant reload dispatch timer unavailable: %s.",
			tostring(schedule_ok and committed or candidate))
		if fn then invoke_reload(fn, "dispatch fallback") end
		return false
	end
	_dispatch_timer_committed = true
	return true
end

--- Wraps a reload callback with UI-awareness: fires immediately when no
--- registered UI is open, otherwise defers until all UIs have been closed.
--- Calling this a second time while a reload is already pending simply
--- replaces the callback (latest message wins) without resetting the poller.
--- @param reload_fn function Zero-argument function that performs the reload.
function M.defer_reload(reload_fn)
	if type(reload_fn) ~= "function" then
		Logger.error(LOG, "defer_reload(): reload_fn must be a function.")
		return false
	end
	if _poll_timer and _poll_timer_committed ~= true and not cancel_poll_timer() then
		Logger.error(LOG,
			"Deferred-reload cleanup debt blocks a replacement poller; firing immediately.")
		return invoke_reload(reload_fn, "cleanup-debt fallback") and false
	end
	if not any_ui_open() then
		if _reload_in_flight then
			-- A reload is already executing on the call stack; defer this new
			-- request rather than firing immediately — avoids double-fire when
			-- fn() itself calls defer_reload() and no UI is open at that point.
			_pending_reload_fn = reload_fn
			return true
		end
		-- Fast path: nothing to protect, fire right away
		return invoke_reload(reload_fn, "fast-path")
	end

	-- Slow path: at least one UI is open — hold the reload
	local is_new_request = (_pending_reload_fn == nil)
	_pending_reload_fn = reload_fn

	if not is_new_request then
		-- Poller is already running; just updated the callback above
		Logger.debug(LOG, "Reload re-requested while already deferred — callback updated.")
		return true
	end

	-- Log once per deferral batch so the developer can see what is blocking
	for _, entry in ipairs(REGISTRY) do
		local ok, result = pcall(entry.is_open)
		if ok and result then
			Logger.info(LOG, "Reload deferred — UI '%s' is open.", entry.key)
		end
	end

	return arm_poll_timer()
end

--- Fences pending work and retries release of the exact retained poller.
--- @return boolean settled True only when no native timer cleanup debt remains.
function M.stop()
	_pending_reload_fn = nil
	_reload_in_flight = false
	local poll_stopped = cancel_poll_timer()
	local dispatch_stopped = cancel_dispatch_timer()
	local restores_stopped = cancel_restore_timers()
	return poll_stopped and dispatch_stopped and restores_stopped
end

return M
