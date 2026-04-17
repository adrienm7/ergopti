--- lib/ui_restore.lua

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

local hs     = hs
local Logger = require("lib.logger")

local LOG          = "ui_restore"
local SETTINGS_KEY = "ergopti_ui_restore_state"

-- How often the deferred-reload poller wakes up to check whether all UIs closed
local POLL_INTERVAL_SEC = 1




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
	if not open_keys or type(open_keys) ~= "table" or #open_keys == 0 then return end

	-- Clear immediately so a crash during restore does not cause an infinite
	-- reopen loop on the next boot
	hs.settings.set(SETTINGS_KEY, nil)

	local key_set = {}
	for _, k in ipairs(open_keys) do key_set[k] = true end

	for _, entry in ipairs(REGISTRY) do
		if key_set[entry.key] then
			Logger.info(LOG, "Restoring UI '%s' after reload.", entry.key)
			-- Delay allows menu.start() side-effects (keylogger start, etc.)
			-- to complete before the UI attempts to read their state
			hs.timer.doAfter(0.5, function()
				local ok, err = pcall(entry.reopen)
				if not ok then
					Logger.error(LOG, "Failed to restore UI '%s': %s", entry.key, tostring(err))
				end
			end)
		end
	end
end




-- ======================================
-- ======================================
-- ======= 3/ Deferred Reload Gate =======
-- ======================================
-- ======================================

-- Holds the pending reload callback while at least one registered UI is open
local _pending_reload_fn = nil
local _poll_timer        = nil

--- Returns true if at least one registered UI is currently open.
local function any_ui_open()
	for _, entry in ipairs(REGISTRY) do
		local ok, result = pcall(entry.is_open)
		if ok and result then return true end
	end
	return false
end

--- Wraps a reload callback with UI-awareness: fires immediately when no
--- registered UI is open, otherwise defers until all UIs have been closed.
--- Calling this a second time while a reload is already pending simply
--- replaces the callback (latest message wins) without resetting the poller.
--- @param reload_fn function Zero-argument function that performs the reload.
function M.defer_reload(reload_fn)
	if not any_ui_open() then
		-- Fast path: nothing to protect, fire right away
		reload_fn()
		return
	end

	-- Slow path: at least one UI is open — hold the reload
	local is_new_request = (_pending_reload_fn == nil)
	_pending_reload_fn = reload_fn

	if not is_new_request then
		-- Poller is already running; just updated the callback above
		Logger.debug(LOG, "Reload re-requested while already deferred — callback updated.")
		return
	end

	-- Log once per deferral batch so the developer can see what is blocking
	for _, entry in ipairs(REGISTRY) do
		local ok, result = pcall(entry.is_open)
		if ok and result then
			Logger.info(LOG, "Reload deferred — UI '%s' is open.", entry.key)
		end
	end

	-- Poll until all registered UIs are closed, then fire the reload
	_poll_timer = hs.timer.new(POLL_INTERVAL_SEC, function()
		if any_ui_open() then return end

		_poll_timer:stop()
		_poll_timer = nil

		local fn = _pending_reload_fn
		_pending_reload_fn = nil

		if fn then
			Logger.info(LOG, "All protected UIs closed — firing deferred reload.")
			fn()
		end
	end)
	_poll_timer:start()
end

return M
