--- lib/personal_shortcuts.lua

--- ==============================================================================
--- MODULE: Personal Shortcuts (Lua)
--- DESCRIPTION:
--- User-owned Lua file loaded at boot to layer custom hotkeys on top of
--- the Hammerspoon driver. Mirrors the role of personal_shortcuts.ahk on
--- the Windows side: lives at <config_dir>/personal_shortcuts.lua, is
--- created from a template on first launch, and survives Hammerspoon
--- reloads because it sits in the user's synced config folder rather
--- than inside the repo.
---
--- FEATURES & RATIONALE:
--- 1. Auto-create on first launch: a fresh install gets a starter file
---    with a working example and a banner pointing to documentation, so
---    new users have something to copy-paste rather than a blank page.
--- 2. Loaded via dofile so syntax errors surface in the Hammerspoon
---    console as line-numbered tracebacks. Wrapped in pcall so a bad
---    user file cannot prevent the driver from booting.
--- 3. Open-in-editor entry point: M.open() launches the file in the
---    user's default .lua editor via `open`. Wired into the menu actions.
---
--- DEPENDENCIES:
--- - lib.logger
--- - ui.menu.menu_paths (for the resolved path)
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")
local LOG    = "personal_shortcuts"




-- ===================================
--- ===========================
-- ======= 1/ Template =======
--- ===========================
-- ===================================

--- Minimal but useful starter file. Edited at user discretion afterward.
--- The example uses Cmd+Alt+H so it does not collide with anything in the
--- default Hammerspoon driver bindings.
local TEMPLATE = [[
--- personal_shortcuts.lua
---
--- ==============================================================================
--- MODULE: Personal Shortcuts (User)
--- DESCRIPTION:
--- User-defined Hammerspoon hotkeys layered on top of the Ergopti driver.
--- This file is loaded at boot via dofile() and lives at:
---     <config_dir>/personal_shortcuts.lua
--- It survives Ergopti updates because it is *not* part of the repo.
---
--- Add your own hs.hotkey.bind / hs.urlevent / hs.application bindings
--- below. Any error here is logged in the Hammerspoon console — the
--- driver will keep booting even if your file does not parse.
--- ==============================================================================

--- ====================================================
-- ===== Example: ⌥⌘H opens Hammerspoon's console =====
--- ====================================================

-- hs.hotkey.bind({ "alt", "cmd" }, "H", function()
-- 	hs.openConsole()
-- end)
]]




-- =========================================
--- ==================================
-- ======= 2/ Path resolution =======
--- ==================================
-- =========================================

--- Resolve the absolute path via the central menu_paths module.
--- No local fallback — menu_paths handles defaults internally.
local function resolve_path()
	local MenuPaths = require("ui.menu.menu_paths")
	return MenuPaths.get("PersonalShortcutsLuaPath")
end




-- ============================================
--- ========================================
-- ======= 3/ Ensure-on-disk + load =======
--- ========================================
-- ============================================

--- Create the file from TEMPLATE if it does not exist yet. Idempotent.
local function ensure_file(path)
	local fh = io.open(path, "r")
	if fh then fh:close(); return true end

	-- Make sure the parent directory exists; on a fresh install
	-- ~/.config/ergopti_plus/ has just been created by MenuPaths.init.
	local parent = path:match("^(.*[/\\])") or ""
	if parent ~= "" then
		pcall(hs.execute, string.format("mkdir -p %q", parent))
	end

	local fw, err = io.open(path, "w")
	if not fw then
		Logger.error(LOG, "Cannot create personal_shortcuts.lua at '%s': %s.",
			path, tostring(err))
		return false
	end
	fw:write(TEMPLATE); fw:close()
	Logger.info(LOG, "Personal shortcuts template created at '%s'.", path)
	return true
end

--- Load the user's file. Errors are logged but never propagated — a
--- broken personal_shortcuts.lua must not block the driver bootstrap.
function M.load()
	local path = resolve_path()
	if not ensure_file(path) then return end
	local ok, err = pcall(dofile, path)
	if ok then
		Logger.success(LOG, "Loaded personal_shortcuts.lua.")
	else
		Logger.error(LOG, "Error in personal_shortcuts.lua: %s.", tostring(err))
	end
end




-- ====================================
--- =================================
-- ======= 4/ Open in editor =======
--- =================================
-- ====================================

--- Open the file in the user's default Lua / text editor.
function M.open()
	local path = resolve_path()
	ensure_file(path)
	hs.timer.doAfter(0, function()
		pcall(hs.execute, string.format("open %q", path))
	end)
end

--- Returns the absolute path — handy for menu entries that display it.
function M.get_path()
	return resolve_path()
end


return M
