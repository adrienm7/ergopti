--- modules/keymap/layout_sources_cache.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Sources Cache
--- DESCRIPTION:
--- Keeps the disk half of the layout menu's « sources » stage (the highest
--- Ergopti bundle installed in each Keyboard Layouts scope and the variants
--- its Info.plist declares) between menu rebuilds, so a rebuild with nothing
--- changed on disk reads nothing. Field reports measured that stage at 57 to
--- 415 ms per rebuild, re-reading the same directories and plists each time.
---
--- FEATURES & RATIONALE:
--- 1. The contract: a cached answer is used only while an FSEvents watcher on
---    each scope folder is running and has reported nothing since it was read.
---    FSEvents is recursive and reports file events, so a nested Info.plist or
---    a same-second bundle replacement invalidates it, where a directory time
---    would not (layout_install keeps re-reading for that reason).
--- 2. The driver's own installs invalidate at once (invalidate), without
---    waiting for the FSEvents latency: the menu rebuilt right after an install
---    reads the disk again.
--- 3. No watcher, no cache: a scope folder that is absent or a watcher that
---    cannot start leaves every read fresh, and says so once.
--- 4. Explicit ownership: start() returns the one owner, whose stop() ends the
---    watchers; a second start() while one runs is refused.
--- ==============================================================================

local hs         = hs
local Logger     = require("core.logger.engine.logger")
local NativePath = require("core.fs.engine.native_path")
local FileSystem = require("core.fs.adapters.file_system")
local LOG        = "menu.keyboard_layout"

local M = {}

-- The running owner, or nil; and whether every scope folder is watched.
local _owner = nil
local _armed = false
-- The cached answer, or nil when the next read must go to the disk.
local _entry = nil





-- ===========================
-- ===========================
-- ======= 1/ Watchers =======
-- ===========================
-- ===========================

--- Forgets the cached answer.
--- @param reason string Why, for the log.
function M.invalidate(reason)
	if _entry ~= nil then
		Logger.debug(LOG, "Keyboard layout sources cache cleared: %s.", tostring(reason))
	end
	_entry = nil
end

--- The owner of a cache that serves nothing: every read stays fresh.
--- @param owner table
--- @return table owner
local function owner_without_cache(owner)
	_armed, _entry = false, nil
	function owner:stop()
		if _owner == owner then _owner = nil end
		return true
	end
	return owner
end

--- Watches every scope folder; the cache serves answers only once all of them are watched.
--- @param dirs table Array of absolute folder paths (the Keyboard Layouts scopes).
--- @return table|nil owner { stop = function(self) -> boolean }, nil when refused.
function M.start(dirs)
	if _owner ~= nil then
		Logger.error(LOG, "Keyboard layout sources cache already started; refusing a second owner.")
		return nil
	end
	if type(dirs) ~= "table" or #dirs == 0 then
		error("layout_sources_cache.start: the scope folders are required", 2)
	end
	local watchers = {}
	local owner = {}
	_owner, _armed, _entry = owner, false, nil

	local function stop_all()
		local stopped = true
		for index = #watchers, 1, -1 do
			local ok, result = pcall(function() return watchers[index]:stop() end)
			if ok and result ~= false then
				table.remove(watchers, index)
			else
				stopped = false
				Logger.error(LOG, "Keyboard layout sources watcher stop failed: %s.", tostring(result))
			end
		end
		return stopped
	end

	for _, dir in ipairs(dirs) do
		local path = NativePath.without_trailing_separators(dir)
		local attrs, status = FileSystem.classify_no_follow(path)
		if status ~= "ok" or type(attrs) ~= "table" or attrs.mode ~= "directory" then
			Logger.info(LOG, "Keyboard layout sources read fresh at each rebuild: %s is not a folder (%s).",
				path, tostring(status))
			stop_all()
			return owner_without_cache(owner)
		end
		local ok, watcher = pcall(function()
			return hs.pathwatcher.new(path, function()
				-- Only the running owner's events count: a stopped one is gone.
				if _owner == owner then M.invalidate("files changed under " .. path) end
			end):start()
		end)
		if not ok or type(watcher) ~= "table" or type(watcher.stop) ~= "function" then
			Logger.warn(LOG, "Keyboard layout sources read fresh at each rebuild: no watcher on %s (%s).",
				path, tostring(watcher))
			stop_all()
			return owner_without_cache(owner)
		end
		watchers[#watchers + 1] = watcher
	end
	_armed = true

	function owner:stop()
		if _owner ~= owner then return true end
		_armed, _entry = false, nil
		if not stop_all() then return false end
		_owner = nil
		return true
	end
	Logger.debug(LOG, "Keyboard layout sources cache started (%d scope folders watched).", #watchers)
	return owner
end





-- ========================
-- ========================
-- ======= 2/ Reads =======
-- ========================
-- ========================

--- The cached answer while every scope folder is watched and unchanged, else read().
--- @param read function read() -> table, the disk read; its answer must not be changed by callers.
--- @return table answer
function M.read(read)
	if _armed and _entry ~= nil then return _entry end
	local answer = read()
	if type(answer) ~= "table" then
		error("layout_sources_cache.read: the disk read must return a table", 2)
	end
	-- Cached only while watched: an unwatched answer could go stale unnoticed.
	if _armed then _entry = answer end
	return answer
end

--- Whether answers are being cached (every scope folder watched). Test seam.
--- @return boolean
function M.is_armed()
	return _armed
end

return M
