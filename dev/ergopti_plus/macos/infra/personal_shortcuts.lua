--- infra/personal_shortcuts.lua

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
--- - infra.config_paths (for the resolved path)
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("infra.logger")
local FileSystem = require("adapters.file_system")
local text_utils = require("infra.text_utils")
local LOG    = "personal_shortcuts"





-- ===========================
-- ===========================
-- ======= 1/ Template =======
-- ===========================
-- ===========================

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



-- ====================================================
-- ===== Example: ⌥⌘H opens Hammerspoon's console =====
-- ====================================================

-- hs.hotkey.bind({ "alt", "cmd" }, "H", function()
-- 	hs.openConsole()
-- end)
]]





-- ==================================
-- ==================================
-- ======= 2/ Path resolution =======
-- ==================================
-- ==================================

--- Resolve the absolute path via the central menu_paths module.
--- No local fallback — menu_paths handles defaults internally.
local function resolve_path()
	local MenuPaths = require("infra.config_paths")
	return MenuPaths.get("PersonalShortcutsLuaPath")
end





-- ========================================
-- ========================================
-- ======= 3/ Ensure-on-disk + load =======
-- ========================================
-- ========================================

--- Create the file from TEMPLATE only after the filesystem adapter proves that
--- the final pathname is absent. This is intentionally not an io.open probe:
--- ENOENT can also describe a dangling symlink or missing path component, and a
--- later "w" open can overwrite a file created between those two calls.
--- @param path string Absolute personal-shortcuts path.
--- @return boolean ready True only for a committed readable file.
local function ensure_file(path)
	local read_ok, _, status, detail = pcall(FileSystem.read_with_status, path)
	if not read_ok or status == "error" then
		Logger.error(LOG, "Personal shortcuts ownership could not be established; operation refused "
			.. "(failure content withheld; terminal type: %s).", type(read_ok and detail or status))
		return false
	end
	if status == "ok" then return true end
	if status ~= "absent" then
		Logger.error(LOG, "Personal shortcuts reader returned an unknown status; operation refused.")
		return false
	end

	local create_ok, created, create_status, create_detail = pcall(
		FileSystem.create_if_absent,
		path,
		TEMPLATE
	)
	if not create_ok or create_status == "error" then
		Logger.error(LOG, "Personal shortcuts template publication failed "
			.. "(failure content withheld; terminal type: %s).",
			type(create_ok and create_detail or created))
		return false
	end
	if created == true and create_status == "created" then
		Logger.info(LOG, "Personal shortcuts template created at '%s'.", path)
		return true
	end
	-- A concurrent creator is safe only when the adapter has re-read and
	-- classified its complete result as a stable ordinary file.
	if created == false and create_status == "exists" then return true end
	Logger.error(LOG, "Personal shortcuts create transaction returned an unknown status; operation refused.")
	return false
end

--- Load the user's file. Errors are logged but never propagated — a
--- broken personal_shortcuts.lua must not block the driver bootstrap.
function M.load()
	local path = resolve_path()
	if not ensure_file(path) then return false end
	local ok, err = pcall(dofile, path)
	if ok then
		Logger.success(LOG, "Loaded personal_shortcuts.lua.")
		return true
	else
		Logger.error(LOG, "Error in personal_shortcuts.lua: %s.", tostring(err))
		return false
	end
end





-- =================================
-- =================================
-- ======= 4/ Open in editor =======
-- =================================
-- =================================

--- Open the file in the user's default Lua / text editor.
function M.open()
	local path = resolve_path()
	if not ensure_file(path) then return false end
	local scheduled_ok, timer_or_err = pcall(hs.timer.doAfter, 0, function()
		local call_ok, _, launched, _, exit_code = pcall(
			hs.execute,
			"open " .. text_utils.shell_quote(path)
		)
		if not call_ok or launched ~= true then
			Logger.error(LOG, "Personal shortcuts editor launch failed (exit type: %s).",
				type(call_ok and exit_code or launched))
		end
	end)
	if not scheduled_ok or timer_or_err == nil then
		Logger.error(LOG, "Personal shortcuts editor launch could not be scheduled.")
		return false
	end
	return true
end

--- Returns the absolute path — handy for menu entries that display it.
function M.get_path()
	return resolve_path()
end


return M
