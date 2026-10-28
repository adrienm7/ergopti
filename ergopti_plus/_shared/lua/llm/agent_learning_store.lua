--- _shared/lua/llm/agent_learning_store.lua

--- ==============================================================================
--- MODULE: AI Agent Learning Store (Shared)
--- DESCRIPTION:
--- The in-memory map behind the automatic mode of the AI agent on macOS and
--- Linux (modules/llm/agent_learning.lua): the threshold each (application,
--- intent) pair needs before System 2 wakes. Accepting a suggestion lowers it,
--- dismissing one raises it, within agent.json's learning bounds (Agent.learn).
--- The drivers own what differs: where and in which format the map persists,
--- when it is saved, and how an unusable application or intent is refused.
---
--- FEATURES & RATIONALE:
--- 1. PURE Lua: no storage, timer or logger. The map is plain data, so each
---    driver keeps its persisted format and the same vectors replay on both.
--- 2. Recency is a counter, not a clock: every record stamps its application
---    with the next number of `map.clock`, so the order survives a restart and
---    two records can never tie.
--- 3. Bounded: at most MAX_APPS applications are kept; the one used least
---    recently is dropped first.
--- ==============================================================================

local Agent = require("llm.agent")
local TableUtil = require("table_util")

local M = {}

-- Most applications kept.
M.MAX_APPS = 200




-- =============================================
-- =============================================
-- ======= 1/ Public API =======================
-- =============================================
-- =============================================

--- Builds a store whose per-application entries keep their thresholds in `field`
--- (the name the driver's persisted format already uses).
--- @param field string Entry field holding { [intent] = threshold }.
--- @return table store { new_map, threshold, record }
function M.new(field)
	assert(type(field) == "string" and field ~= "", "an agent learning store needs its entry field name")
	local store = {}

	--- An empty map.
	--- @return table map { apps = { [app] = { used = number, [field] = {} } }, clock = number }
	function store.new_map()
		return { apps = {}, clock = 0 }
	end

	--- The threshold of an intent in an application.
	--- @param map table
	--- @param config table Decoded agent.json.
	--- @param app string|nil Application name.
	--- @param intent string Intent id.
	--- @return number threshold config.system1.threshold until something was learned.
	function store.threshold(map, config, app, intent)
		local entry = type(app) == "string" and map.apps[app] or nil
		local learned = entry and entry[field][intent] or nil
		if type(learned) == "number" then return learned end
		return config.system1.threshold
	end

	--- Moves the threshold of an intent in an application after a suggestion was
	--- accepted or dismissed, then trims the map to MAX_APPS.
	--- @param map table
	--- @param config table Decoded agent.json.
	--- @param app string Application name, already validated by the driver.
	--- @param intent string Intent id.
	--- @param accepted boolean
	--- @return number after The new threshold.
	--- @return number before The threshold it replaced.
	--- @return number dropped How many least-recently-used applications were trimmed.
	function store.record(map, config, app, intent, accepted)
		local before = store.threshold(map, config, app, intent)
		local after = Agent.learn(config, before, accepted == true)
		map.clock = map.clock + 1
		local entry = map.apps[app]
		if not entry then
			entry = { used = 0, [field] = {} }
			map.apps[app] = entry
		end
		entry.used = map.clock
		entry[field][intent] = after
		return after, before, store.bound(map)
	end

	--- Drops the applications used least recently beyond MAX_APPS.
	--- @param map table
	--- @return number dropped How many applications were removed.
	function store.bound(map)
		local count = TableUtil.count(map.apps)
		local dropped = 0
		while count > M.MAX_APPS do
			local oldest, oldest_used = nil, math.huge
			for name, candidate in pairs(map.apps) do
				if candidate.used < oldest_used then oldest, oldest_used = name, candidate.used end
			end
			map.apps[oldest] = nil
			count = count - 1
			dropped = dropped + 1
		end
		return dropped
	end

	return store
end

return M
