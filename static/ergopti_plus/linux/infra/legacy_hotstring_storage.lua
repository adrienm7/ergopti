--- infra/legacy_hotstring_storage.lua

--- ==============================================================================
--- MODULE: Legacy Hotstring Storage Import (Linux)
--- DESCRIPTION:
--- Carries the hotstring choices that earlier Linux builds kept in storage.json
--- into their canonical config.toml leaves, once, before any hotstring owner
--- reads config.toml. Without it an existing install loses every category and
--- section it had switched on, its magic key and its repeat key at the update,
--- because the canonical readers resolve absence to the neutral state.
---
--- FEATURES & RATIONALE:
--- 1. Effective state, not raw keys. The legacy category set opened every gate
---    by default and enabled a section only through a `+category.section`
---    entry, so each such entry becomes one section choice and, when its gate
---    was open, one category choice. The repeat key defaulted on there.
--- 2. config.toml wins. A leaf the file already sets explicitly is never
---    overwritten; the import only fills leaves the file leaves absent.
--- 3. One conditional write, then cleanup. Every leaf is published in one batch
---    against the exact bytes read; the legacy keys are removed only after that
---    write commits, so a refused import is retried at the next start and a
---    committed one never resurrects a later neutral choice.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")
local Preferences = require("infra.hotstring_preferences")
local Writer = require("toml_codec.writer")
local LeafRows = require("toml_codec.leaf_rows")
local Codec = require("toml_codec")
local Shell = require("adapters.shell_runner")
local Logger = require("logger.shim")

local LOG = "infra.legacy_hotstring_storage"

-- The legacy comma-joined category set and its opt-in prefix.
local CATEGORY_KEY = "hotstrings.disabled_categories"
local ENABLED_MARK = "+"

-- The repeat leaf, whose legacy storage key had the same name, and the value
-- that legacy reader answered for an absent key (its DEFAULT_ENABLED).
local REPEAT_PATH = "hotstrings.repeat_key_enabled"
local LEGACY_REPEAT_DEFAULT = true

-- Legacy dynamic family switches were keyed by engine section.
local LEGACY_FAMILY_PREFIX = "hotstrings.dynamic."




-- =========================================
-- =========================================
-- ======= 1/ Planning =====================
-- =========================================
-- =========================================

--- Whether an identity can be one canonical key path segment.
--- @param id string|nil
--- @return boolean
local function addressable(id)
	return type(id) == "string" and id ~= "" and not id:find(".", 1, true)
end

--- Splits a dotted path into segments.
--- @param path string
--- @return table
local function segments(path)
	local out = {}
	for part in path:gmatch("[^.]+") do out[#out + 1] = part end
	return out
end

--- The value a decoded document holds at a path, or nil.
--- @param document table
--- @param parts table Path segments.
--- @return any
local function lookup(document, parts)
	local value = document
	for _, part in ipairs(parts) do
		if type(value) ~= "table" then return nil end
		value = value[part]
	end
	return value
end

--- Translates the legacy category set into canonical choices.
--- @param raw string Comma-joined legacy entries.
--- @return table choices Array of `{ path, value }`.
local function category_choices(raw)
	local entries, closed = {}, {}
	for entry in raw:gmatch("[^,]+") do
		entries[#entries + 1] = entry
		closed[entry] = true
	end
	local choices, gates = {}, {}
	for _, entry in ipairs(entries) do
		if entry:sub(1, #ENABLED_MARK) == ENABLED_MARK then
			local key = entry:sub(#ENABLED_MARK + 1)
			local category, section = key:match("^([^.]+)%.(.+)$")
			-- An explicit opt-out of the same section won over its opt-in there.
			if addressable(category) and addressable(section) and not closed[key] then
				choices[#choices + 1] = { path = { "hotstrings", "modules", category, section }, value = true }
				if not closed[category] and not gates[category] then
					gates[category] = true
					choices[#choices + 1] = { path = { "hotstrings", "groups", category }, value = true }
				end
			end
		end
	end
	return choices
end

--- Collects every legacy key present and the canonical leaves it implies.
--- @param storage table Storage adapter: has, get.
--- @param families table Dynamic rule families: `{ id, section }` rows.
--- @return table keys Legacy keys present.
--- @return table choices Array of `{ path, value }`.
local function plan(storage, families)
	local keys, choices = {}, {}
	local function scalar(key, path)
		if not storage.has(key) then return end
		keys[#keys + 1] = key
		local value = storage.get(key, nil)
		local neutral = Manifest.default_for(path)
		if type(value) ~= type(neutral) then
			Logger.warn(LOG, "Legacy '%s' has the wrong type and is not imported.", key)
		elseif value ~= neutral then
			choices[#choices + 1] = { path = segments(path), value = value }
		end
	end
	if storage.has(CATEGORY_KEY) then
		keys[#keys + 1] = CATEGORY_KEY
		local raw = storage.get(CATEGORY_KEY, "")
		if type(raw) == "string" then
			for _, choice in ipairs(category_choices(raw)) do choices[#choices + 1] = choice end
		else
			Logger.warn(LOG, "Legacy '%s' is not a list and is not imported.", CATEGORY_KEY)
		end
	end
	for _, path in ipairs(Preferences.paths()) do scalar(path, path) end
	for _, family in ipairs(families) do
		if type(family.id) == "string" and type(family.section) == "string" then
			scalar(LEGACY_FAMILY_PREFIX .. family.section, "hotstrings.dynamic." .. family.id .. ".enabled")
		end
	end
	if #keys > 0 then
		-- The legacy reader answered on for an absent repeat key.
		if not storage.has(REPEAT_PATH) then
			if LEGACY_REPEAT_DEFAULT ~= Manifest.default_for(REPEAT_PATH) then
				choices[#choices + 1] = { path = segments(REPEAT_PATH), value = LEGACY_REPEAT_DEFAULT }
			end
		else
			scalar(REPEAT_PATH, REPEAT_PATH)
		end
	end
	return keys, choices
end




-- =========================================
-- =========================================
-- ======= 2/ Import =======================
-- =========================================
-- =========================================

--- Imports the legacy hotstring keys once, then removes them from storage.
--- @param options table path (config.toml), storage (adapter: has, get, delete),
---   families (optional dynamic rule family rows).
--- @return boolean settled True when nothing was pending or the import committed.
function M.import(options)
	assert(type(options) == "table" and type(options.path) == "string" and type(options.storage) == "table",
		"the legacy hotstring import requires its path and storage")
	local storage = options.storage
	local keys, choices = plan(storage, options.families or {})
	if #keys == 0 then return true end
	Logger.start(LOG, "Importing %d legacy hotstring setting(s) from storage.", #keys)
	local called, committed, detail = pcall(function()
		local content, status, why = Writer.read_classified(options.path)
		assert(status == "ok" or status == "absent", "configuration is unreadable: " .. tostring(why))
		local document = Codec.decode(content or "")
		assert(type(document) == "table", "configuration is malformed")
		local operations = {}
		for _, choice in ipairs(choices) do
			if lookup(document, choice.path) == nil then
				operations[#operations + 1] = { path = choice.path, value = choice.value }
			end
		end
		if #operations == 0 then return true, 0 end
		local rows = LeafRows.prepare(content or "", operations)
		local directory = options.path:match("^(.*)/[^/]+$")
		if status == "absent" and not Shell.run("mkdir -p " .. Shell.quote(directory) .. " 2>/dev/null") then
			return false, "the configuration folder cannot be created"
		end
		local written, reason = Writer.batch_write(options.path, rows, nil, { status = status, content = content })
		if written ~= true then return false, tostring(reason) end
		return true, #operations
	end)
	if not called or committed ~= true then
		Logger.error(LOG, "Legacy hotstring settings were not imported; they stay in storage: %s.",
			tostring(called and detail or committed))
		return false
	end
	Preferences.refresh()
	local removed = true
	for _, key in ipairs(keys) do
		if storage.delete(key) ~= true then removed = false end
	end
	if not removed then
		Logger.error(LOG, "Imported %d leaf(s), but legacy keys could not be removed from storage.", detail)
		return false
	end
	Logger.success(LOG, "Imported %d leaf(s) from %d legacy hotstring setting(s).", detail, #keys)
	return true
end

return M
