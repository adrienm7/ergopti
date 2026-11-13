--- core/lifecycle/engine/app_identity_migration.lua

--- ==============================================================================
--- MODULE: Application Identity Migration (Linux)
--- DESCRIPTION:
--- Converts, once, the saved application exclusion lists from the X11 process
--- names the driver used to report (/proc/<pid>/comm) to the WM class it
--- reports now, the identity Wayland already used (ADD-3, decided by the
--- maintainer on 2026-11-11).
---
--- FEATURES & RATIONALE:
--- 1. Known names only: a comm name with a known WM class
---    (_shared/data/linux_app_identities.json `aliases`, read as its generated
---    Lua projection) is replaced by it; an
---    entry the table does not know is kept unchanged and logged, never
---    guessed or dropped, so no exclusion is lost.
--- 2. Once: the marker is written to storage.json only after every list is
---    persisted, so a refused write retries at the next start and a later
---    comm-named entry (a window without WM_CLASS) is never rewritten.
--- 3. Outside the shared config migration registry: its op set is closed and
---    interpreted by the three drivers, Windows included, whose identity (the
---    process name) does not change; the conversion is Linux data, run by the
---    Linux owners of the three lists (decided by the coordinator on
---    2026-11-11, to review by the maintainer).
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local ConfigKeys = require("settings.engine.keys")

local LOG = "core.lifecycle.engine.app_identity_migration"

-- The shared table (_shared/data/linux_app_identities.json, generated Lua).
local Data = require("apps.engine.linux_app_identities_data")

-- The marker storage.json holds once the lists were converted.
M.MARKER_KEY = Data.marker
M.MARKER_VALUE = 1

-- Every saved list of application identities, with the preference owner that
-- reads and persists it.
M.LISTS = {
	{ path = ConfigKeys.KEY.METRICS_DISABLED_APPS, owner = "metrics.engine.preferences" },
	{ path = ConfigKeys.KEY.LLM_TRIGGER_DISABLED_APPS, owner = "ai.engine.preferences" },
	{ path = ConfigKeys.KEY.LLM_AGENT_DISABLED_APPS, owner = "ai.engine.preferences" },
}




-- =================================
-- =================================
-- ======= 1/ Conversion ===========
-- =================================
-- =================================

--- Validates the shared alias table.
--- @return table aliases lowercase comm -> lowercase WM class
--- @return table same lowercase comm -> true
function M.load_table()
	if type(Data.marker) ~= "string" or Data.marker == "" or type(Data.aliases) ~= "table"
		or type(Data.same) ~= "table" then
		error("app identity migration: linux_app_identities_data is malformed")
	end
	local same = {}
	for _, name in ipairs(Data.same) do
		assert(type(name) == "string" and name == name:lower(), "app identity migration: bad same entry")
		same[name] = true
	end
	for from, to in pairs(Data.aliases) do
		assert(type(from) == "string" and from == from:lower() and type(to) == "string" and to ~= ""
			and to == to:lower() and not same[from], "app identity migration: bad alias " .. tostring(from))
	end
	return Data.aliases, same
end

--- Converts one list. Pure.
--- @param list table Array of identities as saved.
--- @param aliases table lowercase comm -> lowercase WM class
--- @param same table lowercase comm -> true
--- @return table converted A new array, order kept, duplicates removed.
--- @return boolean changed
--- @return table unknown The entries kept because the table does not know them.
function M.convert(list, aliases, same)
	local converted, seen, unknown, changed = {}, {}, {}, false
	for _, entry in ipairs(list) do
		local lower = type(entry) == "string" and entry:lower() or nil
		local value = entry
		if lower and aliases[lower] then
			value, changed = aliases[lower], true
		elseif lower and not same[lower] then
			unknown[#unknown + 1] = entry
		end
		local key = type(value) == "string" and value:lower() or value
		if seen[key] then
			changed = true
		else
			seen[key] = true
			converted[#converted + 1] = value
		end
	end
	return converted, changed, unknown
end




-- =================================
-- =================================
-- ======= 2/ Run at start =========
-- =================================
-- =================================

--- Reads one saved list through its owner.
--- @return table|nil list nil when the owner refuses the value.
local function read_list(spec)
	local owner = require(spec.owner)
	if spec.owner == "metrics.engine.preferences" then return owner.get_list(spec.path) end
	local value, status = owner.get_with_status(spec.path)
	if status == "absent" then return {} end
	if status ~= "ok" or type(value) ~= "table" then return nil end
	return value
end

--- Converts the saved lists once. Called by the daemon before any owner reads
--- them. A refused read or write leaves the marker unset, so the next start
--- tries again; the lists already written stay converted (convert is
--- idempotent on its own output).
--- @param opts table|nil { storage = adapters.storage, lists = M.LISTS }
--- @return boolean done Whether the marker is set.
function M.run(opts)
	opts = opts or {}
	local storage = opts.storage or require("core.fs.adapters.storage")
	if storage.get(M.MARKER_KEY, nil) == M.MARKER_VALUE then return true end
	local aliases, same = M.load_table()
	Logger.start(LOG, "Converting saved application lists to the WM class identity…")
	local complete, converted_lists = true, 0
	for _, spec in ipairs(opts.lists or M.LISTS) do
		local list = read_list(spec)
		if list == nil then
			Logger.error(LOG, "'%s' could not be read; it is converted at the next start.", spec.path)
			complete = false
		else
			local converted, changed, unknown = M.convert(list, aliases, same)
			if #unknown > 0 then
				Logger.info(LOG, "'%s' keeps %d entr%s with no known WM class: %s.", spec.path, #unknown,
					#unknown == 1 and "y" or "ies", table.concat(unknown, ", "))
			end
			if changed then
				if require(spec.owner).set(spec.path, converted) then
					converted_lists = converted_lists + 1
				else
					Logger.error(LOG, "'%s' was not persisted; it is converted at the next start.", spec.path)
					complete = false
				end
			end
		end
	end
	if complete and not storage.set(M.MARKER_KEY, M.MARKER_VALUE) then
		Logger.error(LOG, "The conversion marker was not persisted; the lists are checked again at the next start.")
		complete = false
	end
	if complete then
		Logger.success(LOG, "Saved application lists use the WM class identity (%d converted).", converted_lists)
	else
		Logger.warn(LOG, "Saved application lists partly converted (%d); retried at the next start.", converted_lists)
	end
	return complete
end

return M
