--- infra/personal_shortcuts.lua

--- ==============================================================================
--- MODULE: Personal Shortcuts (Linux)
--- DESCRIPTION:
--- The user's programmable personal source: a Lua file in the configuration
--- folder that the daemon runs once at start, and that the
--- `open_personal_shortcuts` action (AltGr+Delete by default) opens in the
--- desktop's editor, creating it from a template when it does not exist yet.
---
--- WHY THIS MODULE EXISTS:
--- The action used to open `personal_shortcuts.toml`, a file no Linux code
--- read, so the default chord edited a dead file. Windows opens its personal
--- `.ahk` (included by the driver) and macOS its `personal_shortcuts.lua` (run
--- with dofile at boot); Linux follows them with its own Lua file, run in the
--- daemon's Lua state.
---
--- FEATURES & RATIONALE:
--- 1. No-replace creation: the template is published only through an
---    exclusive create, so a file written between the check and the write is
---    never overwritten.
--- 2. Contained failure: the file runs in a protected call; a syntax or
---    runtime error is logged with its line and the daemon keeps starting.
--- 3. One load per process: a second load is refused, since running user code
---    twice would register its effects twice.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local FileSystem = require("core.fs.adapters.file_system")
local Shell = require("core.process.adapters.shell_runner")
local NativePath = require("core.fs.engine.native_path")

local LOG = "infra.personal_shortcuts"
local FILE_NAME = "personal_shortcuts.lua"

local _loaded = false





-- ===========================
-- ===========================
-- ======= 1/ Template =======
-- ===========================
-- ===========================

--- The starter file: every line is a comment, so a fresh file changes nothing.
M.TEMPLATE = [[
--- personal_shortcuts.lua
---
--- ==============================================================================
--- MODULE: Personal Shortcuts (User)
--- DESCRIPTION:
--- Your own Lua code, run once by the Ergopti Linux daemon at each start,
--- after its modules are ready. The file lives in your configuration folder,
--- so updates never replace it. An error here is written to the log and the
--- daemon keeps starting.
---
--- The daemon's modules are reachable with require(). Key bindings to the
--- catalogue's actions are set in the menu (shortcuts, gestures, layers) and
--- stored in config.toml; this file is for anything those cannot express.
--- ==============================================================================



-- ============================================
-- ===== Example: write a line in the log =====
-- ============================================

-- require("core.logger.engine.shim").info("personal_shortcuts", "Personal shortcuts loaded.")
]]





-- ====================================
-- ====================================
-- ======= 2/ Path and creation =======
-- ====================================
-- ====================================

--- The absolute path of the personal source.
--- @return string|nil path Nil when the configuration folder cannot be resolved.
function M.path()
	local ok, path = pcall(function() return require("infra.config_paths").config(FILE_NAME) end)
	if not ok or type(path) ~= "string" or path == "" then return nil end
	return path
end

--- Makes sure the personal source exists, creating it from the template.
--- @param path string Absolute destination.
--- @return boolean ready True when a file is at the path.
function M.ensure(path)
	if type(path) ~= "string" or path == "" then
		Logger.error(LOG, "The personal shortcuts path is not resolvable.")
		return false
	end
	if FileSystem.exists(path) then return true end
	-- The folder is private to the user, as the storage adapter creates it.
	local directory = NativePath.dirname(path)
	if directory and directory ~= "" and Shell.run("mkdir -p -m 700 " .. Shell.quote(directory) .. " 2>/dev/null") ~= true then
		Logger.error(LOG, "The configuration folder '%s' could not be created.", directory)
		return false
	end
	local written, reason = FileSystem.write_new(path, M.TEMPLATE)
	if written then
		Logger.info(LOG, "Personal shortcuts template created at '%s'.", path)
		return true
	end
	-- Another writer created it first: the file is there, ours or not.
	if FileSystem.exists(path) then return true end
	Logger.error(LOG, "The personal shortcuts template could not be created at '%s': %s.", path, tostring(reason))
	return false
end

--- The path the open action hands the editor, after creating the file.
--- @return string|nil path Nil when the file is not there and cannot be made.
function M.path_for_editing()
	local path = M.path()
	if not M.ensure(path) then return nil end
	return path
end





-- ==========================
-- ==========================
-- ======= 3/ Loading =======
-- ==========================
-- ==========================

--- Runs the personal source once. An absent file is created, then run.
--- @return boolean ran True when the file ran without error.
function M.load()
	if _loaded then
		error("personal shortcuts already loaded in this process")
	end
	_loaded = true
	local path = M.path()
	if not M.ensure(path) then return false end
	Logger.start(LOG, "Running '%s'…", path)
	local ok, err = pcall(dofile, path)
	if not ok then
		Logger.error(LOG, "Error in '%s': %s.", path, tostring(err))
		return false
	end
	Logger.success(LOG, "Ran '%s'.", path)
	return true
end

return M
