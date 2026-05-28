--- lib/keycodes.lua

--- ==============================================================================
--- MODULE: Keycode Registry (Hammerspoon Shim)
--- DESCRIPTION:
--- Thin shim over shared/lua/keycodes/init.lua that re-exports every
--- platform-neutral keycode constant and adds the single Hammerspoon-specific
--- helper that depends on hs.keycodes.map. All numeric constants live in the
--- shared module — this file must never redeclare them.
---
--- FEATURES & RATIONALE:
--- 1. Single source of truth: numeric keycodes are defined once in
---    shared/lua/keycodes/init.lua and surfaced here via metatable delegation.
--- 2. HS-specific surface: M.to_name() requires hs.keycodes.map and therefore
---    cannot live in the platform-neutral shared module.
--- 3. Transparent delegation: callers that already require("lib.keycodes") see
---    no API change — all shared constants remain accessible as M.F13_*, etc.
--- ==============================================================================

local shared_keycodes = require("keycodes")
local M = setmetatable({}, { __index = shared_keycodes })




-- ========================
-- ========================
-- ======= 1/ HS API =======
-- ========================
-- ========================


--- ========================
-- ===== 1.1) Helpers =====
--- ========================

--- Returns the lowercase macOS key name (e.g. "f13", "f20", "spacebar") for a
--- numeric keycode, by reverse-mapping hs.keycodes.map. Used by callers that
--- emit JSON destined for Karabiner Elements (which expects textual key names),
--- so the source of truth stays the numeric registry in shared/lua/keycodes and
--- no magic "f13"/"f20" string ever appears in Lua code.
--- @param numeric_code integer The macOS HID keycode to translate.
--- @return string The lowercase key name. Errors if the code is unknown.
function M.to_name(numeric_code)
	for name, code in pairs(hs.keycodes.map) do
		if code == numeric_code then return name end
	end
	error(string.format("Keycodes.to_name: unknown keycode %d", numeric_code))
end

return M
