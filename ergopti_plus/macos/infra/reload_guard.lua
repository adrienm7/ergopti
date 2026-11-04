--- infra/reload_guard.lua

--- ==============================================================================
--- MODULE: Reload Guard
--- DESCRIPTION:
--- Distinguishes an in-progress Hammerspoon reload from a genuine quit so the
--- shutdown handler can make the right Karabiner-Elements teardown decision.
---
--- FEATURES & RATIONALE:
--- 1. Why it exists: the Hammerspoon shutdown callback fires for BOTH a reload
---    and a real quit with no flag to tell them apart. On a reload, KE must be
---    left ALONE — the root grabber daemon reloads karabiner.json via FSEvents,
---    so killing the user-level IPC bridge would needlessly drop remapping and,
---    on some KE versions, cascade the grabber itself down (the user then sees
---    the native "install Karabiner" prompt on the next boot). On a real quit
---    the bridge SHOULD be stopped so remapping does not outlive Hammerspoon.
--- 2. How it works: a controlled reload call is wrapped to drop a short-lived
---    sentinel (a timestamp) in the persistent store, which survives the VM
---    re-exec; the shutdown handler reads it to decide. The sentinel is cleared
---    once at boot, so it can only ever be set because a reload was initiated
---    inside the live session.
--- 3. Boundary-clean: persistence goes through the Storage adapter and time
---    through os.time, so this lib stays free of direct Hammerspoon API calls.
--- 4. The reload's own duration: the caller records when the reload call ran
---    (wall clock milliseconds, from its own clock) and the next boot takes it
---    back once, so it can name and judge the reload against [budgets]
---    driver_reload_ms.
--- ==============================================================================

local M = {}

local Logger  = require("infra.logger")
local LOG     = "reload_guard"
local Storage = require("adapters.storage")





-- ==========================================
-- ==========================================
-- ======= 1/ Constants and state ===========
-- ==========================================
-- ==========================================

--- Persistent-store key holding the reload sentinel timestamp.
local SENTINEL_KEY = "reload_in_progress"

--- Maximum age (seconds) for which a sentinel is honoured. A reload re-execs the
--- Lua VM almost immediately, so this is a generous ceiling whose only job is to
--- let a stale sentinel — left by a crash mid-reload — expire, so a later genuine
--- quit is never mistaken for a reload.
local SENTINEL_TTL_SEC = 60

--- Persistent-store key holding the wall clock milliseconds of the reload call.
local STARTED_KEY = "reload_started_epoch_ms"





-- =================================
-- =================================
-- ======= 2/ Public API ===========
-- =================================
-- =================================

--- Records that a controlled reload call is about to run. Read by the shutdown
--- handler in the SAME session, before the VM re-execs.
function M.mark_reload()
	Storage.set(SENTINEL_KEY, os.time())
	Logger.debug(LOG, "Reload sentinel set.")
end

--- Records when the reload call runs, for the next boot to measure it.
--- @param epoch_ms number Wall clock milliseconds.
function M.mark_started(epoch_ms)
	if type(epoch_ms) ~= "number" or epoch_ms <= 0 then error("reload_guard.mark_started: epoch_ms must be positive", 2) end
	Storage.set(STARTED_KEY, epoch_ms)
end

--- Takes back, once, the reload call time the previous session recorded.
--- @return number|nil epoch_ms Nil when this boot follows no recorded reload.
function M.take_started()
	local epoch_ms = Storage.get(STARTED_KEY, nil)
	Storage.delete(STARTED_KEY)
	return type(epoch_ms) == "number" and epoch_ms or nil
end

local function clear_sentinel(log_completion)
	Storage.delete(SENTINEL_KEY)
	if log_completion then Logger.debug(LOG, "Reload sentinel cleared.") end
end

--- Clears the sentinel. Called once at boot so the sentinel can only ever read
--- true because a reload was initiated within the live session.
function M.clear()
	clear_sentinel(true)
end

--- Clears the sentinel without producing a record. Terminal rollback calls this
--- after the native log drain may already have closed the asynchronous sink.
function M.clear_silent()
	clear_sentinel(false)
end

--- Reports whether a controlled reload was marked and is still fresh.
--- @return boolean True when a reload is in progress, false on a genuine quit.
function M.is_reloading()
	local ts = Storage.get(SENTINEL_KEY, nil)
	if type(ts) ~= "number" then return false end
	return (os.time() - ts) <= SENTINEL_TTL_SEC
end

return M
