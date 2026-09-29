--- modules/llm/agent_learning.lua

--- ==============================================================================
--- MODULE: AI Agent Learning (macOS)
--- DESCRIPTION:
--- Keeps the threshold the automatic mode of the AI agent applies to each
--- (application, intent) pair: accepting a suggestion lowers it, dismissing
--- one raises it, within the bounds of agent.json (agent.learn).
---
--- FEATURES & RATIONALE:
--- 1. Local runtime state, not a preference: the map lives in the driver's
---    native-settings storage adapter (adapters/storage.lua), never in config.toml.
--- 2. Loaded on first use, saved after a change once the changes settle (a
---    debounce), so a burst of dismissals writes once.
--- 3. Bounded: at most MAX_APPS applications are kept; the one used least
---    recently is dropped first.
--- ==============================================================================

local M = {}

local Agent          = require("llm.agent")
local Logger         = require("infra.logger")
local Storage        = require("adapters.storage")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "llm.agent_learning"

-- Storage key of the map
M.STORAGE_KEY = "llm_agent_thresholds"

-- Most applications kept
M.MAX_APPS = 200

-- Seconds a change waits for the next one before the map is saved
M.SAVE_DELAY_SEC = 2

-- { apps = { [app] = { used = number, intents = { [intent] = threshold } } }, clock = number }
local _map = nil
local _save_timer = nil




-- ======================================
-- ======================================
-- ======= 1/ Storage ===================
-- ======================================
-- ======================================

--- Keeps only well-formed entries of a stored map.
--- @param stored any What the storage returned.
--- @return table map
local function sanitize(stored)
	local map = { apps = {}, clock = 0 }
	if type(stored) ~= "table" or type(stored.apps) ~= "table" then return map end
	for app, entry in pairs(stored.apps) do
		if type(app) == "string" and app ~= "" and type(entry) == "table" and type(entry.intents) == "table" then
			local intents = {}
			for intent, threshold in pairs(entry.intents) do
				if type(intent) == "string" and type(threshold) == "number" then intents[intent] = threshold end
			end
			local used = type(entry.used) == "number" and entry.used or 0
			map.apps[app] = { used = used, intents = intents }
			if used > map.clock then map.clock = used end
		end
	end
	return map
end

--- Returns the map, read from the storage on first use.
--- @return table map
local function load()
	if _map then return _map end
	local ok, stored = Storage.read_exact(M.STORAGE_KEY)
	if not ok then Logger.error(LOG, "The learned thresholds could not be read; starting afresh.") end
	_map = sanitize(ok and stored or nil)
	local count = 0
	for _ in pairs(_map.apps) do count = count + 1 end
	Logger.info(LOG, "Learned thresholds loaded for %d application(s).", count)
	return _map
end

--- Saves the map now.
--- @return boolean saved
function M.flush()
	if _save_timer then
		TimerScheduler.cancel(_save_timer)
		_save_timer = nil
	end
	if not _map then return true end
	if Storage.set(M.STORAGE_KEY, _map) ~= true then
		Logger.error(LOG, "The learned thresholds could not be saved.")
		return false
	end
	Logger.debug(LOG, "Learned thresholds saved.")
	return true
end

--- Saves the map once the changes settle.
local function schedule_save()
	if _save_timer then TimerScheduler.cancel(_save_timer) end
	local handle, committed = TimerScheduler.after(M.SAVE_DELAY_SEC, function()
		_save_timer = nil
		M.flush()
	end)
	if committed ~= true then
		Logger.error(LOG, "The save timer could not be armed; saving now.")
		_save_timer = nil
		M.flush()
		return
	end
	_save_timer = handle
end

--- Drops the applications used least recently beyond MAX_APPS.
--- @param map table
local function bound(map)
	local apps = {}
	for app, entry in pairs(map.apps) do apps[#apps + 1] = { app = app, used = entry.used } end
	if #apps <= M.MAX_APPS then return end
	table.sort(apps, function(a, b) return a.used < b.used end)
	for index = 1, #apps - M.MAX_APPS do map.apps[apps[index].app] = nil end
	Logger.debug(LOG, "Learned thresholds trimmed to %d application(s).", M.MAX_APPS)
end




-- ======================================
-- ======================================
-- ======= 2/ Public API ================
-- ======================================
-- ======================================

--- The threshold of an intent in an application.
--- @param config table Decoded agent.json.
--- @param app string Application name.
--- @param intent string Intent id.
--- @return number threshold config.system1.threshold until something was learned.
function M.threshold(config, app, intent)
	local entry = load().apps[app]
	local learned = entry and entry.intents[intent] or nil
	if type(learned) == "number" then return learned end
	return config.system1.threshold
end

--- Moves the threshold of an intent in an application after a suggestion was
--- accepted or dismissed, and saves the map once the changes settle.
--- @param config table Decoded agent.json.
--- @param app string Application name.
--- @param intent string Intent id.
--- @param accepted boolean
--- @return number threshold The new threshold.
function M.record(config, app, intent, accepted)
	if type(app) ~= "string" or app == "" or type(intent) ~= "string" then
		error("agent_learning.record: an application and an intent are required")
	end
	local map = load()
	local before = M.threshold(config, app, intent)
	local after = Agent.learn(config, before, accepted == true)
	map.clock = map.clock + 1
	local entry = map.apps[app] or { intents = {} }
	entry.used = map.clock
	entry.intents[intent] = after
	map.apps[app] = entry
	bound(map)
	schedule_save()
	Logger.info(LOG, "Threshold of '%s' in '%s' %s: %.3f -> %.3f.", intent, app,
		accepted and "lowered (accepted)" or "raised (dismissed)", before, after)
	return after
end

--- Forgets the map in memory (tests, a fresh start); the next use reloads it.
function M.reset()
	if _save_timer then TimerScheduler.cancel(_save_timer) end
	_save_timer = nil
	_map = nil
	Logger.debug(LOG, "Learned thresholds dropped from memory.")
end

return M
