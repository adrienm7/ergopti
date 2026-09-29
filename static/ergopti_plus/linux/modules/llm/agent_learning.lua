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
---    (${XDG_STATE_HOME:-~/.local/state}/ergopti_plus/agent_learning.json),
---    never in config.toml.
--- 2. Loaded at start, saved on change after a short debounce, and written
---    through a temporary file then a rename, so a crash never leaves half a
---    file. A file that does not parse is kept aside and learning restarts.
--- 3. Bounded to MAX_APPS applications: the least recently used one goes first.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Json = require("json")
local Agent = require("llm.agent")

local LOG = "modules.llm.agent_learning"

-- The file under the XDG state folder
local STATE_FILE = "ergopti_plus/agent_learning.json"
-- How many applications are remembered
M.MAX_APPS = 200
-- How long after a change the file is written
local SAVE_DEBOUNCE_SEC = 2
-- The file's format
local VERSION = 1

-- { [app] = { used = integer, thresholds = { [intent] = number } } }
local _apps = nil
-- The last `used` stamp handed out: larger is more recent
local _sequence = 0
-- The pending save's timer
local _save_timer = nil
-- Boundaries, replaced by the tests: { path, scheduler }
local _path = nil
local _scheduler = nil




-- =========================================
-- =========================================
-- ======= 1/ File =========================
-- =========================================
-- =========================================

--- The state file's path.
--- @return string
local function state_path()
	if _path then return _path end
	return require("infra.config_paths").state_home() .. "/" .. STATE_FILE
end

--- Reads the file into memory once.
local function load()
	if _apps then return end
	_apps, _sequence = {}, 0
	local path = state_path()
	local fh = io.open(path, "r")
	if not fh then return end
	local text = fh:read("*a")
	fh:close()
	local root = Json.decode(text or "")
	if type(root) ~= "table" or root.version ~= VERSION or type(root.apps) ~= "table" then
		Logger.warn(LOG, "The agent's learning file is unreadable — it is kept aside and learning restarts.")
		os.rename(path, path .. ".corrupt")
		return
	end
	for app, entry in pairs(root.apps) do
		if type(app) == "string" and type(entry) == "table" and type(entry.used) == "number"
			and type(entry.thresholds) == "table" then
			local thresholds = {}
			for intent, value in pairs(entry.thresholds) do
				if type(intent) == "string" and type(value) == "number" and value >= 0 and value <= 1 then
					thresholds[intent] = value
				end
			end
			_apps[app] = { used = entry.used, thresholds = thresholds }
			if entry.used > _sequence then _sequence = entry.used end
		end
	end
	Logger.debug(LOG, "Agent learning loaded.")
end

--- Writes the map now: a temporary file, then a rename.
--- @return boolean saved
function M.flush()
	if _save_timer then
		(_scheduler or require("adapters.timer_scheduler")).cancel(_save_timer)
		_save_timer = nil
	end
	if not _apps then return true end
	local path = state_path()
	local dir = path:match("^(.*)/[^/]+$")
	if dir and not require("adapters.shell_runner").run("mkdir -p "
		.. require("adapters.shell_runner").quote(dir) .. " 2>/dev/null") then
		Logger.error(LOG, "The agent's learning folder could not be created.")
		return false
	end
	local text = Json.encode({ version = VERSION, apps = _apps })
	local temp = path .. ".tmp"
	local fh = io.open(temp, "w")
	if not fh or not text then
		if fh then fh:close() end
		Logger.error(LOG, "The agent's learning could not be written.")
		return false
	end
	fh:write(text)
	fh:close()
	local renamed, err = os.rename(temp, path)
	if not renamed then
		Logger.error(LOG, "The agent's learning could not be saved: %s", tostring(err))
		return false
	end
	return true
end

--- Schedules a save.
local function schedule_save()
	local scheduler = _scheduler or require("adapters.timer_scheduler")
	if _save_timer then scheduler.cancel(_save_timer) end
	_save_timer = scheduler.after(SAVE_DEBOUNCE_SEC, function()
		_save_timer = nil
		M.flush()
	end)
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
	local entry = type(app) == "string" and _apps[app] or nil
	local value = entry and entry.thresholds[intent] or nil
	return value or config.system1.threshold
end

--- Records that the user accepted or dismissed an automatic suggestion.
--- @param config table Decoded agent.json.
--- @param app string|nil
--- @param intent string
--- @param accepted boolean
--- @return number threshold The new threshold.
function M.record(config, app, intent, accepted)
	load()
	if type(app) ~= "string" or app == "" then app = "?" end
	local before = M.threshold(config, app, intent)
	local after = Agent.learn(config, before, accepted == true)
	local entry = _apps[app]
	if not entry then
		entry = { used = 0, thresholds = {} }
		_apps[app] = entry
	end
	_sequence = _sequence + 1
	entry.used = _sequence
	entry.thresholds[intent] = after
	-- Bounded: the least recently used applications go first.
	local count = 0
	for _ in pairs(_apps) do count = count + 1 end
	while count > M.MAX_APPS do
		local oldest, oldest_used = nil, math.huge
		for name, candidate in pairs(_apps) do
			if candidate.used < oldest_used then oldest, oldest_used = name, candidate.used end
		end
		_apps[oldest] = nil
		count = count - 1
	end
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
	_apps, _sequence, _save_timer = nil, 0, nil
end

return M
