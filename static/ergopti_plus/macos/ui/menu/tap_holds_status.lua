--- ui/menu/tap_holds_status.lua

--- ==============================================================================
--- MODULE: Tap-Holds Title Status
--- DESCRIPTION:
--- Decides the status dot of the Tap-Holds title (maintainer, 2026-11-23): the
--- AI title's dot (menu/ui/title_status.lua), green when the tap-holds work,
--- red when they do not, the warning dot while they are on their way or wait
--- on the user. Like the AI title, no dot while the feature is off or paused.
---
--- FEATURES & RATIONALE:
--- 1. Read Only: every input is an in-memory read of the remap facade; a
---    watch calls it every second, so it never observes the system.
--- 2. Exhaustive Mapping: every state and every stable reason of Ergopti's own
---    runtime (platform/remap/runtime_owner.lua, runtime_vhid.lua) has an
---    explicit colour below, and a test holds the tables to those enums, so a
---    new reason cannot fall to a guessed colour.
--- 3. Order Of Checks: what keeps every rule from applying comes first (the
---    Karabiner integration off, rules an older release left), then the engine
---    this boot runs: Ergopti's own runtime, or the shared Karabiner-Elements
---    through its guardian and lease.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.logger")

local LOG = "ui.menu.tap_holds_status"

-- The statuses are the keys of the manifest's health_dot (menu.toml), as the
-- AI title returns them; test_title_status checks each one has its glyph.
local ready, warming, unreachable = "ready", "warming", "unreachable"

--- Ergopti's own runtime, by owner state (runtime_owner.lua STATE). A blocked
--- runtime (`unavailable`, `failed`) takes its colour from its reason.
M.OWNED_STATES = {
	ready = ready,
	uninitialized = warming,
	idle = warming,
	starting = warming,
	admitted = warming,
	peers_starting = warming,
	stopping = warming,
	stopped = warming,
	unavailable = false,
	failed = false,
}

--- Why the owned runtime is blocked (runtime_owner.lua REASON and the
--- runtime_vhid.lua reasons). A warning while the user is only asked to wait
--- or to finish what is already offered: the driver waits for its approval in
--- System Settings, or the user's own Karabiner runs while the consent to close
--- it is unticked. Red for every block that keeps the tap-holds off until
--- something is installed, repaired, downloaded or fixed.
M.OWNED_REASONS = {
	other_karabiner_running = warming,
	virtual_hid_not_active = warming,
	artifact_unpinned = unreachable,
	capture_unpinned = unreachable,
	runtime_not_installed = unreachable,
	runtime_job_not_loaded = unreachable,
	launchd_unreadable = unreachable,
	system_extension_listing_failed = unreachable,
	close_other_unsupported = unreachable,
	close_other_failed = unreachable,
	other_karabiner_still_running = unreachable,
	coexistence_probe_failed = unreachable,
	owned_configuration_missing = unreachable,
	artifact_fetch_failed = unreachable,
	capture_start_refused = unreachable,
	capture_lost = unreachable,
	capture_start_timeout = unreachable,
	readiness_timer_refused = unreachable,
	virtual_hid_absent = unreachable,
	virtual_hid_incompatible = unreachable,
	virtual_hid_unreadable = unreachable,
}

--- The shared Karabiner-Elements guardian (remap guardian_state): it blocks
--- every rule while macOS waits for its approval or cannot run it.
M.GUARDIAN_STATES = {
	requires_approval = warming,
	unavailable = unreachable,
}

--- The lease of the shared runtime (remap lease_phase): `active` once the
--- rules are in force, `failed` when they could not be; every other phase is
--- on its way.
M.LEASE_PHASES = {
	active = ready,
	failed = unreachable,
}

--- Calls one optional facade reader.
--- @param karabiner table Remap facade.
--- @param name string Reader name.
--- @return boolean present True when the facade has the reader.
--- @return any value Its answer, nil when it raised.
local function read(karabiner, name)
	local reader = karabiner[name]
	if type(reader) ~= "function" then return false, nil end
	local ok, value = pcall(reader)
	if not ok then
		Logger.error(LOG, "The remap %s could not be read: %s.", name, tostring(value))
		return true, nil
	end
	return true, value
end

--- The colour of Ergopti's own runtime.
--- @param status table { state, reason } from owned_runtime_status.
--- @return string status
local function owned_status(status)
	local by_state = M.OWNED_STATES[status.state]
	if by_state then return by_state end
	if by_state == nil then
		Logger.error(LOG, "Unknown owned runtime state '%s': the Tap-Holds title shows it as failed.",
			tostring(status.state))
		return unreachable
	end
	local by_reason = M.OWNED_REASONS[status.reason]
	if by_reason then return by_reason end
	Logger.error(LOG, "Unknown owned runtime reason '%s': the Tap-Holds title shows it as failed.",
		tostring(status.reason))
	return unreachable
end

--- The status the Tap-Holds title shows.
--- @param karabiner table|nil Remap facade.
--- @param tap_holds_on boolean The Tap-Holds feature switch.
--- @param paused boolean Whether Ergopti is paused.
--- @return string|nil status One of TitleStatus' statuses; nil draws no dot.
function M.read(karabiner, tap_holds_on, paused)
	if tap_holds_on ~= true or paused == true or type(karabiner) ~= "table" then return nil end
	-- « Ergopti uses Karabiner » off: nothing can deploy the switched-on tap-holds
	local _, integration_on = read(karabiner, "get_enabled")
	if integration_on ~= true then return unreachable end
	local _, conflicts = read(karabiner, "legacy_rule_conflicts")
	if type(conflicts) == "table" then return unreachable end
	local owned_present, owned = read(karabiner, "owned_runtime_status")
	if owned_present and type(owned) == "table" then return owned_status(owned) end
	local _, guardian = read(karabiner, "guardian_state")
	local by_guardian = M.GUARDIAN_STATES[guardian]
	if by_guardian then return by_guardian end
	local _, phase = read(karabiner, "lease_phase")
	return M.LEASE_PHASES[phase] or warming
end

return M
