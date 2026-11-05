--- modules/keystats/app_category_file.lua

--- ==============================================================================
--- MODULE: App Category File (Linux)
--- DESCRIPTION:
--- Reads and writes the shared app category store (keystats/app_category_store)
--- in the configuration folder, beside config.toml. macOS keeps the same
--- document in the same place; this module only owns the Linux file access.
---
--- FEATURES & RATIONALE:
--- 1. Fail closed. A source that cannot be read, or that the codec refuses, is
---    reported and never read as empty: the next edit would otherwise replace
---    the user's categories with a single entry.
--- 2. Atomic publication: a temporary file, both write receipts, then a rename.
---    The committed file is never replaced by a partial one.
--- 3. The previous Linux store (scores in the SQLite `meta` table, categories on
---    the day rows) is imported by `import_legacy`, which keeps every entry the
---    file already holds.
--- ==============================================================================

local M = {}

local Json = require("json")
local Logger = require("logger.shim")
local Store = require("keystats.app_category_store")
local ConfigPaths = require("infra.config_paths")
local RegularFileReader = require("infra.regular_file_reader")
local RegularFileWriter = require("infra.regular_file_writer")

local LOG = "keystats.app_category_file"
local ENOENT = 2 -- Linux reports genuine absence separately from read refusal.




-- ===============================
-- ===============================
-- ======= 1/ Access =============
-- ===============================
-- ===============================

--- The store file's path.
--- @return string
function M.path()
	return ConfigPaths.config(Store.FILE_NAME)
end

--- Loads the store.
--- @return table|nil model The shared model; empty when the file is absent.
--- @return string|nil reason Set when the file exists and cannot be used.
--- @return table|nil source Exact read receipt for save().
local function read_source(path)
	local stream, _, errno = RegularFileReader.open_source(path)
	if not stream then
		if errno == ENOENT then return "absent", nil end
		return "unreadable", nil
	end
	local read_ok, text = pcall(stream.read, stream, "*a")
	local close_ok, closed = pcall(stream.close, stream)
	if not read_ok or type(text) ~= "string" or not close_ok or closed ~= true then return "unreadable", nil end
	return "ok", text
end

function M.load()
	local path = M.path()
	local status, text = read_source(path)
	if status == "unreadable" then
		Logger.error(LOG, "The app category file could not be read.")
		return nil, "unreadable"
	end
	local source = { path = path, status = status, content = text }
	if status == "absent" then return Store.empty(), nil, source end
	local model, reason = Store.decode(text, Json.decode)
	if not model then
		Logger.error(LOG, "The app category file is invalid (%s); edits are refused.", tostring(reason))
		return nil, "invalid"
	end
	return model, nil, source
end

--- Captures native identity along with bytes for a dialog edit.
local function physical_identity(path)
	local ok, uv = pcall(require, "luv")
	if not ok or type(uv.fs_stat) ~= "function" then return nil end
	local stat = uv.fs_stat(path)
	if type(stat) ~= "table" or stat.type ~= "file" then return nil end
	local function exact(value)
		return type(value) == "number" and value >= 0 and value < 2 ^ 53 and value % 1 == 0
	end
	if not exact(stat.dev) or not exact(stat.ino) then return nil end
	return string.format("%.0f:%.0f", stat.dev, stat.ino)
end

--- Captures a category model and physical source receipt for an interactive edit.
--- @return table|nil model Detached validated model, or nil on refused capture.
--- @return string|nil reason Capture failure.
--- @return table|nil source Source receipt for save().
function M.load_owned()
	local available, uv = pcall(require, "luv")
	if not available or type(uv.fs_stat) ~= "function" then return nil, "source identity unavailable" end
	local path = M.path()
	local before = physical_identity(path)
	local model, reason, source = M.load()
	if not model or not source or source.path ~= path then return nil, reason end
	local after = physical_identity(path)
	if source.status == "ok" then
		if not before or before ~= after then return nil, "source identity unavailable or changed" end
		source.physical = before
	elseif before ~= nil or after ~= nil then
		return nil, "source identity changed"
	end
	return model, nil, source
end

--- Publishes the model.
--- @param model table
--- @param source table Exact receipt returned by load().
--- @return boolean saved
function M.save(model, source)
	local path = M.path()
	if type(source) ~= "table" or source.path ~= path or (source.status ~= "ok" and source.status ~= "absent") then
		Logger.error(LOG, "The app category source receipt is missing or stale.")
		return false
	end
	local function source_current()
		if M.path() ~= path or (source.physical and physical_identity(path) ~= source.physical) then return false end
		local status, content = read_source(path)
		return status == source.status and content == source.content
			and (not source.physical or physical_identity(path) == source.physical)
	end
	if not source_current() then return false end
	local text = Store.encode(model, Json.encode)
	local temp = path .. ".tmp"
	local opened, stream, _, _, remove_owned, current_image = pcall(RegularFileWriter.open, temp, "wx")
	if not opened or not stream then
		Logger.error(LOG, "The app category file could not be written.")
		return false
	end
	-- Buffered close can fail after write accepted every byte. Never replace the
	-- committed file until both receipts succeed, and close even a throwing write.
	local wrote, written = pcall(stream.write, stream, text)
	local closed, flushed = pcall(stream.close, stream)
	if not wrote or not written or not closed or flushed ~= true then
		remove_owned()
		Logger.error(LOG, "The app category file write or close was refused.")
		return false
	end
	local checked, stage_current = pcall(current_image, text)
	if not checked or stage_current ~= true or not source_current() then
		remove_owned()
		Logger.warn(LOG, "The app category source or staging file changed; save refused.")
		return false
	end
	local called, renamed, err = pcall(os.rename, temp, path)
	if not called or renamed ~= true then
		remove_owned()
		Logger.error(LOG, "The app category file could not be saved: %s", tostring(called and err or renamed))
		return false
	end
	return true
end




-- ===============================
-- ===============================
-- ======= 2/ Migration ==========
-- ===============================
-- ===============================

--- Clamps a legacy score into the store's range. The previous Linux editor
--- stored any number; the user's choice is kept as close as the store allows.
--- @param score number
--- @return number
local function clamp(score)
	return math.max(Store.MIN_SCORE, math.min(Store.MAX_SCORE, score))
end

--- Imports the categories the previous Linux store held in SQLite.
--- @param legacy table name -> { type, score } read from the database.
--- @return boolean committed True when the file holds every imported entry.
function M.import_legacy(legacy)
	local model, reason, source = M.load()
	if not model then
		Logger.error(LOG, "Legacy categories stay in SQLite: the file is %s.", tostring(reason))
		return false
	end
	local entries = {}
	for name, entry in pairs(legacy) do
		if Store.score_valid(entry.score) then
			entries[name] = entry
		else
			Logger.warn(LOG, "A legacy score of %s is outside the store's range; it is clamped.", tostring(entry.score))
			entries[name] = { type = entry.type, score = clamp(entry.score) }
		end
	end
	local added, import_reason = Store.import_missing(model, entries)
	if not added then
		Logger.error(LOG, "Legacy categories stay in SQLite: %s.", tostring(import_reason))
		return false
	end
	if added == 0 then return true end
	if not M.save(model, source) then return false end
	Logger.info(LOG, "Imported %d legacy application categories into the shared store.", added)
	return true
end

return M
