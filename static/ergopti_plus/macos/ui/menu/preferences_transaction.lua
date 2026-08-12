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

--- Commits preferences and performs success-only cache side effects.
--- @param preferences table Preferences module or test double.
--- @param path string Destination config path.
--- @param state table Current menu state.
--- @param hotfiles table Hotstring source definitions.
--- @param core_modules table Loaded feature modules.
--- @param builder table Menu builder cache owner.
--- @param hot_counter table Hotstring-count cache owner.
--- @param on_commit function|nil Callback that marks instance-local state dirty.
--- @return boolean committed
function M.commit(
	preferences,
	path,
	state,
	hotfiles,
	core_modules,
	builder,
	hot_counter,
	on_commit
)
	if type(preferences) ~= "table" or type(preferences.save) ~= "function" then return false end
	local call_ok, committed = pcall(preferences.save, path, state, hotfiles, core_modules)
	if not call_ok or committed ~= true then
		Logger.error(LOG, "Preference save did not commit; success-only cache updates were skipped.")
		return false
	end
	if type(builder) == "table" and type(builder.invalidate_cache) == "function" then
		builder.invalidate_cache()
	end
	if type(hot_counter) == "table" and type(hot_counter.invalidate_cache) == "function" then
		hot_counter.invalidate_cache()
	end
	if type(on_commit) == "function" then on_commit() end
	return true
end

return M
