--- modules/llm/trigger_settings.lua

--- ==============================================================================
--- MODULE: LLM Trigger Settings (Linux)
--- DESCRIPTION:
--- Owns the durable automatic-trigger policy and privacy filters consumed by
--- the Linux prediction path. Shipped values come from the feature manifest;
--- only user changes are stored.
--- ==============================================================================

local M = {}

local Logger = require("core.logger.engine.shim")
local ConfigOutdated = require("settings.engine.migration.outdated")
local Manifest = require("infra.manifest_reader")
local AppIdentity = require("ai.engine.policy.app_identity")
local NEVER_MS = require("ai.engine.request_plan.debounce").NEVER_MS
local ConfigKeys = require("settings.engine.keys")
local KEY, LEAF = ConfigKeys.KEY, ConfigKeys.LEAF

-- Exported so the menu offers the same choice the file stores.
M.NEVER_MS = NEVER_MS

local LOG = "modules.llm.trigger_settings"
local PREF_PREFIX = "llm.trigger."

local DEFINITIONS = {
	debounce_ms = {
		path = KEY.LLM_TRIGGER_DEBOUNCE_MS,
		type = "number",
		min = 50,
		max = 10000,
		presets = { 50, 100, 200, 300, 500, 750, 1000, 2000 },
		-- The one value outside the range: no automatic trigger at all.
		never = NEVER_MS,
	},
	-- The minimum time between two automatic AI requests (the rate floor).
	min_request_interval_ms = {
		path = KEY.LLM_TRIGGER_MIN_REQUEST_INTERVAL_MS,
		type = "number",
		min = 0,
		max = 10000,
		presets = { 0, 100, 200, 300, 500, 750, 1000, 2000, 5000 },
	},
	instant_on_word_end = {
		path = KEY.LLM_TRIGGER_INSTANT_ON_WORD_END,
		type = "boolean",
	},
	after_hotstring = {
		path = KEY.LLM_TRIGGER_AFTER_HOTSTRING,
		type = "boolean",
	},
	-- A finished prediction is typed into the document instead of offered
	-- (the Windows inline mode, prediction_engine.lua).
	inline_autotype = {
		path = KEY.LLM_TRIGGER_INLINE_AUTOTYPE,
		type = "boolean",
	},
	-- What an automatic prediction does while a hotstring tooltip shows; the
	-- manifest owns its values ("wait", "both").
	while_hotstring_tooltip = {
		path = KEY.LLM_TRIGGER_WHILE_HOTSTRING_TOOLTIP,
		type = "string",
		enum = true,
	},
	secure_filter_enabled = {
		path = KEY.LLM_TRIGGER_SECURE_FILTER_ENABLED,
		type = "boolean",
	},
	url_bar_filter_enabled = {
		path = KEY.LLM_TRIGGER_URL_BAR_FILTER_ENABLED,
		type = "boolean",
	},
	-- The applications no prediction runs in, as the identifiers the session reports.
	disabled_apps = {
		path = KEY.LLM_TRIGGER_DISABLED_APPS,
		type = "table",
		apps = true,
	},
}

-- A hand-edited list cannot hold the menu hostage
local MAX_APPS = 200

local _defaults = {}
local _values = {}
-- An unreadable exclusion value cannot authorize typing-triggered requests. Keep this sentinel
-- in the cache itself so transaction snapshots restore the exact admission.
local EXCLUSIONS_REFUSED = {}

local function detached(name, value)
	if name ~= LEAF.DISABLED_APPS or type(value) ~= "table" then return value end
	local copy = {}
	for index, app in ipairs(value) do copy[index] = app end
	return copy
end

local function definition(name)
	local def = DEFINITIONS[name]
	if not def then Logger.error(LOG, "Unknown trigger setting '%s'.", tostring(name)) end
	return def
end

local function default_for(name)
	if _defaults[name] ~= nil then return _defaults[name] end
	local def = definition(name)
	if not def then return nil end
	local ok, value = pcall(Manifest.default_for, def.path)
	if not ok or type(value) ~= def.type then
		Logger.error(LOG, "Manifest default for '%s' is unavailable or has the wrong type.", def.path)
		return nil
	end
	_defaults[name] = value
	return value
end

-- ipairs alone silently discards everything after a hole. Confirm every index
-- before normalising or publishing a user's exclusion list.
local function dense_apps(value)
	if type(value) ~= "table" or #value > MAX_APPS then return false end
	local count, length = 0, #value
	for index in pairs(value) do
		count = count + 1
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > length then return false end
	end
	return count == length
end

--- Whether a value is a dense list of distinct, normalised application identifiers.
--- @param value any
--- @return boolean
local function valid_apps(value)
	if not dense_apps(value) then return false end
	local seen = {}
	for _, app in ipairs(value) do
		if type(app) ~= "string" or AppIdentity.normalize(app) ~= app or seen[app] then return false end
		seen[app] = true
	end
	return true
end

--- Whether a value is one of the manifest's values for an enum setting.
--- @param def table Setting definition.
--- @param value string
--- @return boolean
local function valid_enum(def, value)
	local ok, entry = pcall(Manifest.find_entry_by_path, def.path)
	if not ok or type(entry) ~= "table" or type(entry.enum_values) ~= "table" then
		Logger.error(LOG, "Manifest values for '%s' are unavailable.", def.path)
		return false
	end
	for _, accepted in ipairs(entry.enum_values) do
		if accepted == value then return true end
	end
	return false
end

local function valid(name, value)
	local def = definition(name)
	if not def or type(value) ~= def.type then return false end
	if def.apps then return valid_apps(value) end
	if def.enum then return valid_enum(def, value) end
	if def.type == "number" then
		if def.never ~= nil and value == def.never then return true end
		return value == math.floor(value) and value >= def.min and value <= def.max
	end
	return true
end

--- Returns the active setting, falling back to the manifest when no valid
--- durable override exists.
--- @param name string
--- @return number|boolean|nil
function M.get(name)
	if _values[name] == EXCLUSIONS_REFUSED then return detached(name, default_for(name)) end
	if _values[name] ~= nil then return detached(name, _values[name]) end
	local shipped = default_for(name)
	if shipped == nil then return nil end
	local ok, Storage = pcall(require, "infra.llm_preferences")
	if name == LEAF.DISABLED_APPS and (not ok or type(Storage) ~= "table") then
		_values[name] = EXCLUSIONS_REFUSED
		Logger.error(LOG, "Trigger exclusions are unavailable; automatic predictions are suppressed.")
		return detached(name, shipped)
	end
	if ok and Storage then
		local stored, status
		if name == LEAF.DISABLED_APPS then
			if type(Storage.get_with_status) ~= "function" then
				_values[name] = EXCLUSIONS_REFUSED
				Logger.error(LOG, "Trigger exclusions could not be classified; automatic predictions are suppressed.")
				return detached(name, shipped)
			end
			local read_ok
			read_ok, stored, status = pcall(Storage.get_with_status, PREF_PREFIX .. name)
			if not read_ok then
				_values[name] = EXCLUSIONS_REFUSED
				Logger.error(LOG, "Trigger exclusions are unreadable; automatic predictions are suppressed.")
				return detached(name, shipped)
			end
		else
			stored = Storage.get(PREF_PREFIX .. name, nil)
		end
		if name == LEAF.DISABLED_APPS and (status == "invalid" or
				(status == "ok" and not valid(name, stored)) or
				(status ~= "ok" and status ~= "absent")) then
			_values[name] = EXCLUSIONS_REFUSED
			ConfigOutdated.report(PREF_PREFIX .. name, ConfigOutdated.REFUSED, Logger)
			Logger.warn(LOG, "Trigger exclusions are invalid; automatic predictions are suppressed until corrected.")
			return detached(name, shipped)
		end
		if valid(name, stored) then
			_values[name] = detached(name, stored)
			return detached(name, _values[name])
		elseif stored ~= nil then
			-- Outdated configuration: named once, offered by the cleanup.
			ConfigOutdated.report(PREF_PREFIX .. name, ConfigOutdated.REFUSED, Logger)
		end
	end
	_values[name] = detached(name, shipped)
	return detached(name, _values[name])
end

--- The applications the trigger never runs in, as a detached list.
--- @return table apps Normalised identifiers.
function M.disabled_apps()
	local copy = {}
	for index, app in ipairs(M.get(LEAF.DISABLED_APPS) or {}) do copy[index] = app end
	return copy
end

--- Whether the trigger is switched off in an application.
--- @param app any The identifier the session reports for the focused application.
--- @param automatic boolean|nil True for a typing-triggered request.
--- @return boolean disabled
local indexed_owner, disabled_index = setmetatable({}, { __mode = "v" }), nil
function M.is_app_disabled(app, automatic)
	if _values[LEAF.DISABLED_APPS] == nil then M.get(LEAF.DISABLED_APPS) end
	local apps = _values[LEAF.DISABLED_APPS]
	if apps == EXCLUSIONS_REFUSED then return automatic == true end
	if type(apps) ~= "table" then return automatic == true end
	if apps ~= indexed_owner[1] then
		indexed_owner[1], disabled_index = apps, AppIdentity.exclusion_index(apps)
	end
	return AppIdentity.exclusion_contains(disabled_index, app, apps)
end

--- Replaces the list of applications the trigger never runs in.
--- @param apps table Identifiers; each is normalised and duplicates are merged.
--- @param expected_source table|nil Exact source retained by a deferred editor.
--- @param admission function|nil Final originating configuration admission.
--- @return boolean committed
function M.set_disabled_apps(apps, expected_source, admission)
	if not dense_apps(apps) then return false end
	local list, seen = {}, {}
	for _, app in ipairs(apps) do
		local key = AppIdentity.normalize(app)
		if not key then
			Logger.error(LOG, "Refused an unusable application identifier for the trigger exclusions.")
			return false
		end
		if not seen[key] then seen[key] = true; list[#list + 1] = key end
	end
	return M.set(LEAF.DISABLED_APPS, list, expected_source, admission)
end

--- Persists before publishing the live value.
--- @param name string
--- @param value number|boolean
--- @param expected_source table|nil Exact source retained by a deferred editor.
--- @param admission function|nil Final originating configuration admission.
--- @return boolean
local function set(name, value, expected_source, admission, on_notice, publication_guard)
	local shipped = default_for(name)
	if shipped == nil or not valid(name, value) then
		Logger.error(LOG, "Refused invalid trigger setting %s=%s.", tostring(name), tostring(value))
		return false, "invalid"
	end
	value = detached(name, value)
	local ok, Storage = pcall(require, "infra.llm_preferences")
	if not ok or not Storage then
		Logger.error(LOG, "No storage; trigger setting '%s' was not changed.", name)
		return false, "unconfirmed"
	end
	local values_owner, previous_value = _values, _values[name]
	local persisted
	if expected_source ~= nil or admission ~= nil then
		if type(expected_source) ~= "table" or admission ~= nil and type(admission) ~= "function"
			or type(Storage.set_many) ~= "function" then return false, "invalid" end
		if on_notice then persisted = Storage.set_many_with_notice({[PREF_PREFIX .. name] = value}, expected_source, admission, on_notice)
		else persisted = Storage.set_many({[PREF_PREFIX .. name] = value}, expected_source, admission) end
	else
		if on_notice then persisted = Storage.set_with_notice(PREF_PREFIX .. name, value, on_notice)
		else persisted = Storage.set(PREF_PREFIX .. name, value) end
	end
	if persisted ~= true then
		Logger.error(LOG, "Trigger setting '%s' could not be persisted; live state is unchanged.", name)
		return false, "unconfirmed"
	end
	local may_publish = not publication_guard or publication_guard()
	if _values == values_owner and _values[name] == previous_value then
		-- Other trigger leaves, including the exclusion policy, may have changed
		-- in the source used by the committed write. Reclassify them on demand.
		if may_publish then _values = { [name] = detached(name, value) }
		else _values[name] = nil end
	end
	Logger.info(LOG, "%s: %s.", name, tostring(value))
	return true
end

function M.set(name, value, expected_source, admission)
	local committed = set(name, value, expected_source, admission)
	return committed
end

--- Stores a menu choice with a closed refusal reason and exact notice receipt.
--- @return boolean committed
--- @return string|nil reason
--- @return boolean noticed
function M.set_with_reason_notice(name, value, expected_source, admission, publication_guard)
	local noticed = false
	local receipt = { admit = admission, acknowledge = function() noticed = true end }
	local committed, reason = set(name, value, expected_source, admission, receipt, publication_guard)
	return committed, reason, noticed
end

--- Stores a value and returns whether this exact write already showed a notice.
--- @return boolean committed
--- @return boolean noticed
function M.set_with_notice(name, value)
	local noticed = false
	local committed = set(name, value, nil, nil, function() noticed = true end)
	return committed, noticed
end

--- Stores a retained setting with notice acknowledgement from its exact write.
--- @return boolean committed
function M.set_with_source_notice(name, value, expected_source, admission, on_notice, publication_guard)
	return set(name, value, expected_source, admission, on_notice, publication_guard)
end

--- Flips one boolean setting transactionally.
--- @param name string
--- @return boolean
function M.toggle(name)
	if type(M.get(name)) ~= "boolean" then return false end
	return M.set(name, not M.get(name))
end

--- Returns menu presets for a numeric setting.
--- @param name string
--- @return table
function M.presets(name)
	local def = definition(name)
	local values = {}
	for index, value in ipairs(def and def.presets or {}) do values[index] = value end
	return values
end

--- Whether a value of a numeric setting means "never" (the setting is off).
--- @param name string
--- @param value any
--- @return boolean never
function M.is_never(name, value)
	local def = definition(name)
	return def ~= nil and def.never ~= nil and value == def.never
end

--- Returns the accepted numeric range.
--- @param name string
--- @return table|nil
function M.bounds(name)
	local def = definition(name)
	if not def or def.type ~= "number" then return nil end
	return { min = def.min, max = def.max }
end

--- Test seam: forgets all cached reads.
function M._reset()
	_defaults = {}
	_values = {}
end

--- Marks only trigger leaves consumed by this owner.
--- @param document table Parsed canonical configuration.
--- @param mark function Consumed-key collector.
function M.mark_config_reads(document, mark)
	local preferences = require("infra.llm_preferences")
	for name, definition in pairs(DEFINITIONS) do
		preferences.mark_config_read(document, definition.path, mark, function(value) return valid(name, value) end)
	end
end

--- Captures the current cache without reading or publishing preferences.
--- @return table snapshot
function M.configuration_snapshot()
	return { values = _values, defaults = _defaults }
end

--- Restores the exact cache after a refused configuration transaction.
--- @param snapshot table Owner-issued snapshot.
--- @return boolean restored
function M.restore_configuration(snapshot)
	_values = snapshot.values
	_defaults = snapshot.defaults
	return true
end

--- Resolves the detached configuration through this owner's validation rules.
--- @return boolean applied
function M.reload_configuration()
	_values = {}
	for name in pairs(DEFINITIONS) do if not valid(name, M.get(name)) then return false end end
	return true
end

return M
