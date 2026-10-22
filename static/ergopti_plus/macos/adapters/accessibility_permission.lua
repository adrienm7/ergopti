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
--- ==============================================================================

local M = {}

local hs = hs

local SETTINGS_URL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

-- The longest any Accessibility call may hold the main thread. macOS disables
-- an event tap that holds a key for about a second; an application that has
-- not answered by then is hung, and its read fails instead of freezing input.
M.MESSAGING_TIMEOUT_SEC = 1.0

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
	return require("adapters.shell_runner").open(SETTINGS_URL) == true
end

return M
