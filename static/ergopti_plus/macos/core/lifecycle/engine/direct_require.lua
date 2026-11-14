--- core/lifecycle/engine/direct_require.lua

--- ==============================================================================
--- MODULE: Direct Require
--- DESCRIPTION:
--- Puts Lua's own `require` back in place of the wrapper Hammerspoon installs.
---
--- FEATURES & RATIONALE:
--- 1. Hammerspoon's wrapper (_coresetup.lua, 1.1.1) runs on every call, loaded
---    module or not: it lists package.loaded, sorts it, joins it and hands the
---    string to its crash reporter. With the driver's modules that is about
---    300 us and 4 KB of garbage per call, on the main thread. One `require` per
---    script-chord row (3360 rows) took menu_item.shortcuts from 47 ms to 1 s and
---    added 13 MB to the Lua heap per rebuild (field reports of 2026-11-01).
--- 2. A lazy `require` inside a function is this codebase's normal way to break
---    a load cycle, so the cost belongs at the one owner of the global, not at
---    each caller.
--- 3. Only the crash reporter's list of modules is lost: the wrapper keeps the
---    original as the global `rawrequire` and returns what it returned.
--- ==============================================================================

local M = {}

--- Replaces the global `require` with the wrapped original.
--- @param env table The global table.
--- @return boolean installed False when the runtime exposes no original.
function M.install(env)
	if type(env.rawrequire) ~= "function" then return false end
	env.require = env.rawrequire
	return true
end

return M
