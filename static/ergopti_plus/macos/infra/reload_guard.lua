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
local SENTINEL_KEY = "ergopti_reload_in_progress"

--- Maximum age (seconds) for which a sentinel is honoured. A reload re-execs the
--- Lua VM almost immediately, so this is a generous ceiling whose only job is to
--- let a stale sentinel — left by a crash mid-reload — expire, so a later genuine
--- quit is never mistaken for a reload.
local SENTINEL_TTL_SEC = 60





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
