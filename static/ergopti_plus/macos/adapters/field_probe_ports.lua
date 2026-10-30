--- adapters/field_probe_ports.lua

--- ==============================================================================
--- MODULE: Field Run Probe Ports (Hammerspoon)
--- DESCRIPTION:
--- The real Mac side of infra/field_check_probes.lua: the system facts the
--- field run's own checks read. adapters/field_check_ports.lua merges them
--- into the ports every field check receives.
---
--- FEATURES & RATIONALE:
--- 1. Read-only: each port reads a state the driver or macOS already holds; no
---    port prompts, grants, writes a setting or starts a feature.
--- 2. Paths stay here: a port may hand a path to a bounded command, and the
---    check reports only what the command answered.
--- ==============================================================================

local M = {}





-- ==============================
-- ==============================
-- ======= 1/ Permissions =======
-- ==============================
-- ==============================

--- Calls a native query that may be missing from this Hammerspoon build.
--- @param fn any The native function.
--- @param ... any Its arguments.
--- @return boolean|nil answer nil when absent or when it raised.
local function optional_query(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, answer = pcall(fn, ...)
	if not ok or type(answer) ~= "boolean" then return nil end
	return answer
end

--- The privacy grants of this process, read without prompting.
--- @return table facts { accessibility, screen_recording, input_monitoring, secure_input, bundle_id }
local function permission_facts()
	local eventtap = type(hs.eventtap) == "table" and hs.eventtap or {}
	return {
		accessibility = (require("adapters.accessibility_permission").is_trusted()),
		screen_recording = (require("adapters.screen_capture").permission_state()),
		-- Only some Hammerspoon builds can ask without prompting; nil otherwise
		input_monitoring = optional_query(eventtap.checkKeyboardEventAccess, false),
		secure_input = optional_query(eventtap.isSecureInputEnabled),
		bundle_id = (require("adapters.accessibility_permission").bundle_id()),
	}
end

--- The running application bundle, the one macOS files the grants under.
--- @return string|nil path
local function running_bundle_path()
	return (require("adapters.accessibility_permission").bundle_path())
end





-- ==========================
-- ==========================
-- ======= 2/ Factory =======
-- ==========================
-- ==========================

--- The probe ports, merged into adapters/field_check_ports.lua's table.
--- @return table ports
function M.new()
	return {
		permission_facts = permission_facts,
		running_bundle_path = running_bundle_path,
	}
end

return M
