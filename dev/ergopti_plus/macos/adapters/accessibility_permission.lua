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
--- ==============================================================================

local M = {}

local hs = hs

local SETTINGS_URL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

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
