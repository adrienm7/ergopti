--- modules/llm/agent_learning.lua

--- ==============================================================================
--- MODULE: AI Agent Learning Store (Linux)
--- DESCRIPTION:
--- Holds the threshold each (application, intent) pair needs before the
--- automatic mode wakes System 2. Accepting a suggestion lowers it, dismissing
--- one raises it, within agent.json's learning bounds (agent.learn()).
---
--- FEATURES & RATIONALE:
--- 1. Runtime state, not configuration: the map lives in the XDG state folder
---    (${XDG_STATE_HOME:-~/.local/state}/ergopti/agent_learning.json),
---    never in config.toml.
--- 2. Loaded at start, saved on change after a short debounce, and written
---    through a temporary file then a rename, so a crash never leaves half a
---    file. A file that does not parse is kept aside and learning restarts.
--- 3. Bounded to MAX_APPS applications: the least recently used one goes first.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local Json = require("core.text.engine.json")
local LearningStore = require("ai.engine.agent.learning_store")
local CorruptAside = require("infra.corrupt_aside")
local RegularFileReader = require("infra.regular_file_reader")
local RegularFileWriter = require("infra.regular_file_writer")
local NativePath = require("core.fs.engine.native_path")

local LOG = "modules.llm.agent_learning"

-- The file in the driver's XDG state folder
local STATE_FILE = "agent_learning.json"
-- How many applications are remembered
M.MAX_APPS = LearningStore.MAX_APPS
-- How long after a change the file is written
local SAVE_DEBOUNCE_SEC = 2
-- The file's format
local VERSION = 1
local ENOENT = 2 -- Linux reports genuine absence separately from read refusal.

-- The shared map logic; this driver persists the thresholds under `thresholds`.
local Store = LearningStore.new("thresholds")
-- { apps = { [app] = { used = integer, thresholds = { [intent] = number } } }, clock = the
-- last `used` stamp handed out: larger is more recent }; nil until loaded.
local _map = nil
-- The pending save's timer
local _save_timer = nil
-- Boundaries, replaced by the tests: { path, scheduler }
local _path = nil
local _scheduler = nil
-- A rejected source stays authoritative until its preservation is acknowledged.
local _load_blocked = false
-- Exact source used by the in-memory learning map.
local _source = nil




-- =========================================
-- =========================================
-- ======= 1/ File =========================
-- =========================================
-- =========================================

--- The state file's path.
--- @return string
local function state_path()
	if _path then return _path end
	return require("infra.config_paths").state(STATE_FILE)
end

--- Preserves the rejected source without replacing an older recovery file.
--- @param path string
--- @return boolean preserved
local function preserve_corrupt(path)
	return CorruptAside.preserve(path) ~= nil
end

--- Refuse partial maps: dropping an invalid entry before the next save would
--- silently overwrite the only copy of that application's learning.
local function valid_root(root)
	if type(root) ~= "table" or root.version ~= VERSION or type(root.apps) ~= "table"
		or Json.is_array(root.apps) or Json.is_null(root.apps) then return false end
	for app, entry in pairs(root.apps) do
		if type(app) ~= "string" or type(entry) ~= "table" or Json.is_array(entry)
			or type(entry.used) ~= "number" or type(entry.thresholds) ~= "table"
			or Json.is_array(entry.thresholds) or Json.is_null(entry.thresholds) then return false end
		for intent, value in pairs(entry.thresholds) do
			if type(intent) ~= "string" or type(value) ~= "number" or value < 0 or value > 1 then
				return false
			end
		end
	end
	return true
end

--- Reads the file into memory once.
local function load()
	if _map and not _load_blocked then return end
	_map = Store.new_map()
	_source = nil
	local path = state_path()
	local fh, _, errno = RegularFileReader.open_source(path)
	if not fh then
		_load_blocked = errno ~= ENOENT
		if not _load_blocked then _source = { path = path, status = "absent" } end
		if _load_blocked then Logger.error(LOG, "The agent's learning source could not be read; mutations are blocked.") end
		return
	end
	local read_ok, text = pcall(fh.read, fh, "*a")
	local close_ok, closed = pcall(fh.close, fh)
	if not read_ok or type(text) ~= "string" or not close_ok or closed ~= true then
		_load_blocked = true
		Logger.error(LOG, "The agent's learning read or close was refused; mutations are blocked.")
		return
	end
	-- An overflowing persisted sequence becomes infinity in the legacy decoder,
	-- leaving LRU eviction without any oldest entry. Admit exact JSON instead.
	local root = Json.decode_lossless(text or "")
	if not valid_root(root) then
		_load_blocked = not preserve_corrupt(path)
		if _load_blocked then
			Logger.error(LOG, "The agent's learning source could not be preserved; mutations are blocked.")
		else
			_source = { path = path, status = "absent" }
			Logger.warn(LOG, "The agent's learning file is unreadable — it is kept aside and learning restarts.")
		end
		return
	end
	_load_blocked = false
	_source = { path = path, status = "ok", content = text }
	for app, entry in pairs(root.apps) do
		if type(app) == "string" and type(entry) == "table" and type(entry.used) == "number"
			and type(entry.thresholds) == "table" then
			local thresholds = {}
			for intent, value in pairs(entry.thresholds) do
				if type(intent) == "string" and type(value) == "number" and value >= 0 and value <= 1 then
					thresholds[intent] = value
				end
			end
			_map.apps[app] = { used = entry.used, thresholds = thresholds }
			if entry.used > _map.clock then _map.clock = entry.used end
		end
	end
	Logger.debug(LOG, "Agent learning loaded.")
end

-- Check the exact source again before publishing; an unreadable or changed
-- image never authorizes replacing another process's learning updates.
local function source_current(path)
	if not _source or _source.path ~= path or state_path() ~= path then return false end
	local fh, _, errno = RegularFileReader.open_source(path)
	if not fh then return _source.status == "absent" and errno == ENOENT end
	local read_ok, text = pcall(fh.read, fh, "*a")
	local close_ok, closed = pcall(fh.close, fh)
	return read_ok and type(text) == "string" and close_ok and closed == true
		and _source.status == "ok" and text == _source.content
end

--- Retains a timer when its cancellation has not been acknowledged.
local function cancel_save_timer()
	if not _save_timer then return true end
	local scheduler = _scheduler or require("adapters.timer_scheduler")
	local called, cancelled = pcall(scheduler.cancel, _save_timer)
	if not called or cancelled ~= true then return false end
	_save_timer = nil
	return true
end

--- Writes the map now: a temporary file, then a rename.
--- @return boolean saved
function M.flush()
	cancel_save_timer()
	if _load_blocked then return false end
	if not _map then return true end
	local path = state_path()
	if not source_current(path) then
		Logger.warn(LOG, "The agent's learning source changed; save refused.")
		return false
	end
	local dir = NativePath.dirname(path)
	if dir and not require("adapters.shell_runner").run("mkdir -p "
		.. require("adapters.shell_runner").quote(dir) .. " 2>/dev/null") then
		Logger.error(LOG, "The agent's learning folder could not be created.")
		return false
	end
	local text = Json.encode({ version = VERSION, apps = _map.apps })
	local temp = path .. ".tmp"
	local opened, fh, _, _, remove_owned, current_image = pcall(RegularFileWriter.open, temp, "wx")
	if not opened or not fh or not text then
		if opened and fh then pcall(fh.close, fh); remove_owned() end
		Logger.error(LOG, "The agent's learning could not be written.")
		return false
	end
	-- Buffered close can fail after write accepted every byte. Never replace the
	-- committed map until both receipts succeed, and close even a throwing write.
	local wrote, written = pcall(fh.write, fh, text)
	local closed, flushed = pcall(fh.close, fh)
	if not wrote or not written or not closed or flushed ~= true then
		remove_owned()
		Logger.error(LOG, "The agent's learning write or close was refused.")
		return false
	end
	local checked, stage_current = pcall(current_image, text)
	if not checked or stage_current ~= true or not source_current(path) then
		remove_owned()
		Logger.warn(LOG, "The agent's learning source or staging file changed; save refused.")
		return false
	end
	local called, renamed, err = pcall(os.rename, temp, path)
	if not called or renamed ~= true then
		remove_owned()
		Logger.error(LOG, "The agent's learning could not be saved: %s", tostring(called and err or renamed))
		return false
	end
	_source = { path = path, status = "ok", content = text }
	return true
end

--- Schedules a save.
local function schedule_save()
	local scheduler = _scheduler or require("adapters.timer_scheduler")
	if not cancel_save_timer() then return end
	local timer
	timer = scheduler.after(SAVE_DEBOUNCE_SEC, function()
		if _save_timer ~= timer then return end
		_save_timer = nil
		M.flush()
	end)
	_save_timer = timer
	if type(_save_timer) ~= "table" or _save_timer.armed ~= true then
		_save_timer = nil
		M.flush()
	end
end




-- =========================================
-- =========================================
-- ======= 2/ Thresholds ===================
-- =========================================
-- =========================================

--- The threshold an intent needs in an application.
--- @param config table Decoded agent.json.
--- @param app string|nil
--- @param intent string
--- @return number
function M.threshold(config, app, intent)
	load()
	return Store.threshold(_map, config, app, intent)
end

-- LuaJIT numbers stop distinguishing consecutive integers at 2^53. Rebase
-- the persisted order before incrementing so the newest application cannot tie
-- an older entry merely because a finite imported counter was very large.
local function rebase_clock_if_needed()
	if _map.clock < 9007199254740991 then return end
	local entries = {}
	for name, entry in pairs(_map.apps) do entries[#entries + 1] = { name = name, entry = entry } end
	table.sort(entries, function(a, b)
		if a.entry.used ~= b.entry.used then return a.entry.used < b.entry.used end
		return a.name < b.name
	end)
	for rank, item in ipairs(entries) do item.entry.used = rank end
	_map.clock = #entries
end

--- Records that the user accepted or dismissed an automatic suggestion.
--- @param config table Decoded agent.json.
--- @param app string|nil
--- @param intent string
--- @param accepted boolean
--- @return number threshold The new threshold.
function M.record(config, app, intent, accepted)
	load()
	if _load_blocked then return config.system1.threshold end
	if type(app) ~= "string" or app == "" then app = "?" end
	-- Bounded by the store: the least recently used applications go first.
	rebase_clock_if_needed()
	local after, before = Store.record(_map, config, app, intent, accepted)
	Logger.info(LOG, "Agent %s for '%s': threshold %.3f -> %.3f.", accepted and "accepted" or "dismissed",
		intent, before, after)
	schedule_save()
	return after
end

--- Replaces the boundaries and forgets the loaded map (tests).
--- @param opts table|nil { path, scheduler }
function M._reset_for_test(opts)
	opts = opts or {}
	_path, _scheduler = opts.path, opts.scheduler
	_map, _save_timer, _load_blocked, _source = nil, nil, false, nil
end

return M
