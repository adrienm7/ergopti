-- _shared/lua/layout/pause_switch_policy.lua
-- ============================================================================
-- MODULE: Pause Switch Policy
-- DESCRIPTION:
-- Decides which keyboard layout a pause, a resume or a quit switches to, from
-- the three [layout] settings declared in the features manifest. Twin of
-- _shared/modules/features/pause_switch_policy.ahk; both replay
-- tests/corpus/layouts/pause_switch_vectors.json. Drivers keep the native
-- switch (macOS TIS, Linux gsettings or setxkbmap, Windows
-- WM_INPUTLANGCHANGEREQUEST), the picker and the lifecycle hooks.
-- ============================================================================

local M = {}

local ConfigKeys = require("config_keys")
local KEY, LEAF = ConfigKeys.KEY, ConfigKeys.LEAF

--- The settings the policy reads, by role.
M.PATHS = {
	enabled = KEY.LAYOUT_PAUSE_SWITCH_ENABLED,
	on_pause = KEY.LAYOUT_ON_PAUSE,
	on_resume = KEY.LAYOUT_ON_RESUME,
}

-- Quitting leaves the keyboard on the layout a pause selects: a quit has no
-- setting of its own, and a user who wants their system layout back while
-- ErgoptiPlus is not typing gets it whether they paused or quit.
local EVENT_FIELDS = { pause = LEAF.ON_PAUSE, resume = LEAF.ON_RESUME, quit = LEAF.ON_PAUSE }

--- Whether a stored target is a value the setting can hold: a layout id, or
--- "" for « no change ». The id is the driver's own (a macOS KeyboardLayout
--- Name, a Linux input source, a Windows keyboard layout handle).
--- @param value any
--- @return boolean valid
--- @return string|nil detail Why the value is refused.
function M.valid_target(value)
	if type(value) == "string" then return true end
	return false, "the layout to switch to is not a text value"
end

--- The layout id a target names, nil for « no change » (the empty string).
--- @param value any A value valid_target accepts.
--- @return string|nil
function M.target_id(value)
	if type(value) ~= "string" or value == "" then return nil end
	return value
end

--- The layout an event switches to, or nil when nothing switches: the switch
--- is off, or the event's target is « no change ».
--- @param settings table { enabled, on_pause, on_resume } as stored.
--- @param event string "pause", "resume" or "quit".
--- @return string|nil target
function M.target(settings, event)
	local field = EVENT_FIELDS[event]
	if field == nil then error("unknown pause switch event: " .. tostring(event), 2) end
	if type(settings) ~= "table" then error("pause switch settings must be a table", 2) end
	if settings.enabled ~= true then return nil end
	return M.target_id(settings[field])
end

return M
