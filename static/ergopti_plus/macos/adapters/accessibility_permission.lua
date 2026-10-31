--- adapters/accessibility_permission.lua

--- ==============================================================================
--- MODULE: Accessibility Permission Adapter
--- DESCRIPTION:
--- Reads and requests the macOS Accessibility trust that every input eventtap
--- of the driver needs, before any of them is armed.
---
--- FEATURES & RATIONALE:
--- 1. Checked before the first eventtap: without trust, CGEventTapCreate yields
---    a tap that never enables. The input pre-start transaction then refused,
---    which surfaced as a generic post-onboarding failure instead of the one
---    thing the user must do.
--- 2. Distinct identity: the packaged runtime is its own application
---    (com.ergoptiplus.app.hammerspoon). A user whose onboarding was skipped
---    because config.toml already existed, e.g. from a source Hammerspoon run
---    that holds its own grant, was never asked for it.
--- 3. Prompt once per refusal: requesting trust makes macOS add the entry and
---    show its own prompt, so the user lands on the right switch.
--- 4. Stale grants are cleared: the packaged app is signed ad hoc, so every
---    build has a new code identity. macOS then keeps the old switch checked
---    in System Settings while refusing the new binary, and the user sees a
---    permission that looks granted but is not. Resetting this app's own entry
---    lets the next prompt add a switch that matches the running binary.
--- 5. Bounded waits: every Accessibility call runs on the main thread, where
---    the keyboard event taps also run. macOS lets a call to an application
---    that does not answer wait six seconds; the taps then time out, macOS
---    disables them and every key typed meanwhile comes out late, held or lost
---    (issues #99 and #100). One process-wide messaging timeout bounds them all.
--- 6. Unanswering applications: the bound still holds the main thread for the
---    whole timeout on each unanswered read, and a caller that asks several
---    reads in a row multiplies it (2515 ms for the tooltip caret, 1512 ms for
---    the post-wake context capture of loginwindow, field run 2026-10-31). The
---    first unanswered read marks the application for a short cooldown in which
---    callers skip it, and this process is never asked: its own Accessibility
---    server answers on the main thread that is waiting.
--- ==============================================================================

local M = {}

local hs = hs


-- The longest any Accessibility call may hold the main thread. macOS disables
-- an event tap whose events wait about a second: a 1.0 s bound landed exactly
-- on that edge (a 1001 ms focused-window probe was followed by "Keystats event
-- tap found disabled"), so a hung application's read fails well before it.
M.MESSAGING_TIMEOUT_SEC = 0.5

--- Sets the process-wide Accessibility messaging timeout. macOS applies the
--- system-wide element's timeout to every element without its own, which is
--- every element the driver reads (AXUIElementSetMessagingTimeout).
--- @return boolean bounded True when macOS accepted the timeout.
--- @return string|nil detail Exact failure when bounded is false.
function M.bound_messaging_timeout()
	local window = type(hs) == "table" and hs.window or nil
	if type(window) ~= "table" or type(window.timeout) ~= "function" then
		return false, "hs.window.timeout is unavailable"
	end
	local ok, accepted = pcall(window.timeout, M.MESSAGING_TIMEOUT_SEC)
	if not ok then return false, tostring(accepted) end
	if accepted ~= true then return false, "macOS refused the messaging timeout" end
	return true
end

--- How long an application that left a read unanswered is not asked again,
--- unless another application comes to the front. Read when a cooldown starts:
--- requiring the timings at load would parse them for every reader of trust.
--- @return number seconds
function M.unanswered_cooldown_sec()
	return require("infra.timings").sec("adapters", "unresponsive_ax_backoff_ms")
end

-- A read that took this share of the messaging timeout waited it out: the
-- hs.window reads return nil without saying why
local UNANSWERED_ELAPSED_RATIO = 0.9

-- The AX error of a read the application did not answer (kAXErrorCannotComplete)
M.UNANSWERED_ERROR = "Messaging failed"

-- The one application in its cooldown: { pid, until_sec }, or nil
local _unanswered = nil

--- Returns this process's pid.
--- @return number|nil pid
local function own_pid()
	local info = type(hs) == "table" and hs.processInfo or nil
	return type(info) == "table" and info.processID or nil
end

--- Returns the caller's time, or the epoch clock's.
--- @param now number|nil Seconds a caller already read.
--- @return number now
local function now_sec(now)
	if type(now) == "number" then return now end
	return hs.timer.secondsSinceEpoch()
end

--- Returns the frontmost application's pid without an Accessibility read.
--- @return number|nil pid Nil when the workspace names none.
function M.frontmost_pid()
	local ok, pid = pcall(function()
		local app = hs.application.frontmostApplication()
		if app == nil or type(app.pid) ~= "function" then return nil end
		return app:pid()
	end)
	return ok and type(pid) == "number" and pid or nil
end

--- Whether an application is in its unanswered cooldown. Asking about another
--- application ends the cooldown: that one came to the front.
--- @param pid number|nil Application pid.
--- @param now number|nil Seconds the caller already read.
--- @return boolean unanswering
function M.is_unanswering(pid, now)
	if _unanswered == nil or pid == nil then return false end
	if _unanswered.pid ~= pid or now_sec(now) >= _unanswered.until_sec then
		_unanswered = nil
		return false
	end
	return true
end

--- Whether an application's elements may be asked an Accessibility read now.
--- An unknown pid is asked: only a proven unanswered read or this process skip.
--- @param pid number|nil Application pid.
--- @return boolean askable
function M.is_askable(pid)
	if pid == nil then return true end
	local own = own_pid()
	if own ~= nil and pid == own then return false end
	return not M.is_unanswering(pid)
end

--- Marks an application that left a read unanswered for the cooldown.
--- @param pid number|nil Application pid; nil is ignored.
--- @param now number|nil Seconds the caller already read.
function M.mark_unanswered(pid, now)
	if type(pid) ~= "number" then return end
	_unanswered = { pid = pid, until_sec = now_sec(now) + M.unanswered_cooldown_sec() }
end

--- Marks the application when one read waited out the messaging timeout.
--- @param pid number|nil Application pid.
--- @param elapsed_sec number Duration of the read.
--- @param now number|nil Seconds the caller already read.
--- @return boolean unanswered True when the read is taken as unanswered.
function M.note_read(pid, elapsed_sec, now)
	if type(elapsed_sec) ~= "number"
		or elapsed_sec < M.MESSAGING_TIMEOUT_SEC * UNANSWERED_ELAPSED_RATIO then return false end
	M.mark_unanswered(pid, now)
	return true
end

--- Forgets every unanswering application (tests only).
function M.reset_unanswered_for_tests()
	_unanswered = nil
end

--- Reports whether this process is currently trusted for Accessibility.
--- @return boolean|nil trusted Nil when the native query itself failed.
--- @return string|nil detail Exact failure when trusted is nil.
function M.is_trusted()
	if type(hs) ~= "table" or type(hs.accessibilityState) ~= "function" then
		return nil, "hs.accessibilityState is unavailable"
	end
	local ok, state = pcall(hs.accessibilityState, false)
	if not ok then return nil, tostring(state) end
	return state == true
end

--- Asks macOS to show its Accessibility prompt for this process.
--- @return boolean requested True when the native request returned.
--- @return string|nil detail Exact failure when the request raised.
function M.request_prompt()
	if type(hs) ~= "table" or type(hs.accessibilityState) ~= "function" then
		return false, "hs.accessibilityState is unavailable"
	end
	local ok, err = pcall(hs.accessibilityState, true)
	if not ok then return false, tostring(err) end
	return true
end

--- Returns the bundle identifier macOS files this process's grant under.
--- @return string|nil bundle_id Nil when the running process has none.
--- @return string|nil detail Exact reason when bundle_id is nil.
function M.bundle_id()
	return require("adapters.tcc_grant").bundle_id()
end

--- Returns the path of the running app, the one the Accessibility list shows
--- (as "Hammerspoon") and the one to add with + when the entry is missing.
--- @return string|nil path Nil when the running process reports none.
--- @return string|nil detail Exact reason when path is nil.
function M.bundle_path()
	local info = type(hs) == "table" and hs.processInfo or nil
	local path = type(info) == "table" and info.bundlePath or nil
	if type(path) ~= "string" or path == "" then
		return nil, "hs.processInfo.bundlePath is unavailable"
	end
	return path
end

--- Removes this app's Accessibility entry so a stale grant cannot mask a refusal.
--- @param bundle_id string Exact bundle identifier whose entry is reset.
--- @param on_done function fn(ok, detail) once tccutil has exited.
--- @return boolean started True when tccutil was started.
function M.reset_grant(bundle_id, on_done)
	return require("adapters.tcc_grant").reset("Accessibility", bundle_id, on_done)
end

--- Opens System Settings on the Accessibility list, without blocking.
--- @return boolean started True when the pane opener was started.
function M.open_settings()
	return require("adapters.shell_runner").open(require("adapters.privacy_settings").url("accessibility")) == true
end

return M
