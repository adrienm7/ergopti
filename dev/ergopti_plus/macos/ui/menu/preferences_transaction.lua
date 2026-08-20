--- ui/menu/preferences_transaction.lua

--- ==============================================================================
--- MODULE: Menu Preferences Transaction
--- DESCRIPTION:
--- Commits preferences and gates every success-only menu cache side effect on
--- the exact persistence result. A returned false, nil, or raised error leaves
--- the caches untouched so the UI never advertises an uncommitted disk state.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local LOG = "menu"

local function clone_value(value)
	if type(value) ~= "table" then return value end
	local clone = {}
	for key, child in pairs(value) do clone[clone_value(key)] = clone_value(child) end
	return clone
end

--- Creates a detached transaction snapshot.
--- @param value any Value to clone.
--- @return any clone
function M.clone(value)
	return clone_value(value)
end

--- Restores a table in place so callbacks retaining its identity see rollback.
--- @param target table Mutable live table.
--- @param snapshot table Last committed snapshot.
--- @return boolean restored
function M.restore_table(target, snapshot)
	if type(target) ~= "table" or type(snapshot) ~= "table" then return false end
	for key in pairs(target) do
		if snapshot[key] == nil then target[key] = nil end
	end
	for key, value in pairs(snapshot) do
		if type(value) == "table" and type(target[key]) == "table" then
			M.restore_table(target[key], value)
		else
			target[key] = clone_value(value)
		end
	end
	return true
end

--- Creates a save wrapper with rollback snapshots already seeded from boot.
--- @param preferences table Preferences module or test double.
--- @param opts table Transaction dependencies and initial snapshots.
--- @return function save Transactional save function.
function M.bind(preferences, opts)
	if type(opts) ~= "table" then error("preferences transaction options are required", 2) end
	local state = opts.state
	local committed_state = clone_value(opts.initial_state)
	local committed_preferences = clone_value(opts.initial_preferences)
	local rolling_back = false

	local function rollback()
		if type(committed_state) ~= "table" or type(committed_preferences) ~= "table" then
			return false
		end
		if M.restore_table(state, committed_state) ~= true then return false end
		rolling_back = true
		local sync_ok, sync_result = xpcall(function()
			return opts.restore_runtime(committed_preferences)
		end, debug.traceback)
		rolling_back = false
		if not sync_ok or sync_result ~= true then return false end
		if type(opts.on_rollback) == "function" then opts.on_rollback() end
		return true
	end

	return function()
		if rolling_back then return false end
		local committed, snapshot = M.commit(
			preferences,
			opts.path,
			state,
			opts.hotfiles,
			opts.core_modules,
			opts.builder,
			opts.hot_counter,
			function(saved_snapshot)
				committed_state = clone_value(state)
				committed_preferences = clone_value(saved_snapshot)
				if type(opts.on_commit) == "function" then opts.on_commit(saved_snapshot) end
			end,
			rollback
		)
		return committed, snapshot
	end
end

--- Commits preferences and performs success-only cache side effects.
--- @param preferences table Preferences module or test double.
--- @param path string Destination config path.
--- @param state table Current menu state.
--- @param hotfiles table Hotstring source definitions.
--- @param core_modules table Loaded feature modules.
--- @param builder table Menu builder cache owner.
--- @param hot_counter table Hotstring-count cache owner.
--- @param on_commit function|nil Callback receiving the committed preference snapshot.
--- @param on_rollback function|nil Callback restoring the last committed state.
--- @return boolean committed
--- @return table|nil snapshot Complete preference snapshot acknowledged by save().
function M.commit(
	preferences,
	path,
	state,
	hotfiles,
	core_modules,
	builder,
	hot_counter,
	on_commit,
	on_rollback
)
	if type(preferences) ~= "table" or type(preferences.save) ~= "function" then return false end
	local call_ok, committed, snapshot = pcall(
		preferences.save,
		path,
		state,
		hotfiles,
		core_modules
	)
	if not call_ok or committed ~= true then
		Logger.error(LOG, "Preference save did not commit; success-only cache updates were skipped.")
		if type(on_rollback) == "function" then
			local rollback_ok, rollback_result = xpcall(on_rollback, debug.traceback)
			if not rollback_ok or rollback_result ~= true then
				Logger.error(LOG, "Preference rollback did not commit: %s.", tostring(rollback_result))
			end
		end
		return false
	end
	if type(builder) == "table" and type(builder.invalidate_cache) == "function" then
		builder.invalidate_cache()
	end
	if type(hot_counter) == "table" and type(hot_counter.invalidate_cache) == "function" then
		hot_counter.invalidate_cache()
	end
	if type(on_commit) == "function" then on_commit(snapshot) end
	return true, snapshot
end

return M
