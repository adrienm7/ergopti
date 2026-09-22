--- adapters/system_info.lua

--- ==============================================================================
--- MODULE: System Information Adapter (Hammerspoon)
--- DESCRIPTION:
--- Read-only environment probes for the boot diagnostic snapshot: macOS and
--- Hammerspoon versions, architecture, screens, keyboard input source and the
--- process owner. Kept in the adapter layer so the collector in
--- infra/diagnostic_snapshot.lua stays free of hs.* calls and is testable with
--- a plain table.
---
--- FEATURES & RATIONALE:
--- 1. No subprocess: every probe is an in-process Hammerspoon query, so the
---    snapshot can run on the main loop without a shell round-trip.
--- 2. Unknown is an answer: a probe that is unavailable or raises returns nil,
---    which the shared formatter renders as "unknown" — the snapshot is a
---    report, and a missing fact must never abort the boot that produced it.
--- ==============================================================================

local M = {}

local hs = hs

--- Calls a probe and returns its value, or nil when it is unavailable or raises.
--- @param fn function
--- @return any
local function probe(fn)
	local ok, value = pcall(fn)
	if ok then return value end
	return nil
end

--- @return string|nil Human-readable macOS version.
function M.os_version()
	return probe(function() return hs.host.operatingSystemVersionString() end)
end

--- @return string|nil Hammerspoon version.
function M.runtime_version()
	return probe(function() return hs.processInfo.version end)
end

--- @return string|nil CPU architecture the Hammerspoon binary runs as.
function M.arch()
	return probe(function() return hs.processInfo.arch end)
end

--- @return number|nil Number of connected screens.
function M.monitor_count()
	return probe(function() return #hs.screen.allScreens() end)
end

--- @return number|nil Backing scale factor of the main screen (2 on Retina).
function M.main_screen_scale()
	return probe(function()
		local mode = hs.screen.mainScreen():currentMode()
		return mode and mode.scale or nil
	end)
end

--- @return string|nil Active keyboard input source identifier.
function M.keyboard_layout()
	return probe(function()
		if type(hs.keycodes.currentSourceID) == "function" then
			return hs.keycodes.currentSourceID()
		end
		return hs.keycodes.currentLayout()
	end)
end

--- @return string|nil "true" when Hammerspoon runs as root.
function M.elevated()
	local user = os.getenv("USER")
	if type(user) ~= "string" or user == "" then return nil end
	return tostring(user == "root")
end

--- @return string|nil The user's home directory.
function M.home()
	return os.getenv("HOME")
end

return M
