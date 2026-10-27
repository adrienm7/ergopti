--- infra/metrics_state_keys.lua

--- ==============================================================================
--- MODULE: Metrics Menu State Keys
--- DESCRIPTION:
--- The flat names under which the Metrics preferences live in the menu state
--- and in the preference map (infra/preferences.lua), declared once. They keep
--- the `keystats_` spelling from before the rename to Metrics: the TOML side
--- is clean (`[metrics]`), so these names exist only in memory and in the
--- manifest rows that read them (`checked_when`, `disabled_when`).
---
--- FEATURES & RATIONALE:
--- 1. One declaration. Code and tests that pass one of these names as a string
---    (a demotion record, a filter toggle, the preference map) read it from
---    here, so the next rename edits this file and the manifest, not every
---    test that pinned the spelling.
--- 2. Strict. An unknown name raises instead of reading as nil.
--- 3. No dependency, so a test that stubs the preference module still reads it.
--- ==============================================================================

local names = {
	ENABLED = "keystats_enabled",
	ENCRYPT = "keystats_encrypt",
	FLOAT_COLORS = "keystats_float_colors",
	FLOAT_GRAPH = "keystats_float_graph",
	FLOAT_WPM = "keystats_float_wpm",
	MENUBAR_COLORS = "keystats_menubar_colors",
	MENUBAR_WPM = "keystats_menubar_wpm",
	PRIVATE_FILTER_ENABLED = "keystats_private_filter_enabled",
	SECURE_FILTER_ENABLED = "keystats_secure_filter_enabled",
	SYSTEM_AUTH_FILTER_ENABLED = "keystats_system_auth_filter_enabled",
	DISABLED_APPS = "keystats_disabled_apps",
}

return setmetatable({}, {
	__index = function(_, name)
		local value = names[name]
		if value == nil then error("metrics_state_keys has no name " .. tostring(name), 2) end
		return value
	end,
	__newindex = function() error("metrics_state_keys is read-only", 2) end,
	__pairs = function() return next, names end,
	__metatable = false,
})
