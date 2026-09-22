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
--- ==============================================================================

local M = {}

local hs = hs

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

return M
