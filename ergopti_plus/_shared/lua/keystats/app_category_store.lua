--- _shared/lua/keystats/app_category_store.lua

--- ==============================================================================
--- MODULE: App Category Store (Shared)
--- DESCRIPTION:
--- The one on-disk model of the categories and scores a user assigns to
--- applications in the metrics dashboard: a versioned JSON document the macOS
--- and Linux drivers read and write through this codec. The drivers own only
--- the file access (their atomic writers), never the format.
---
--- FEATURES & RATIONALE:
--- 1. One document, one owner. macOS kept `app_categories.json` as a flat map,
---    Linux kept the scores in the SQLite `meta` table and the categories on the
---    day rows, and Windows has its own versioned file. The versioned layout of
---    the Windows store ({ schema, version, apps }) is the common target, so the
---    third driver can adopt it without a second migration.
--- 2. Validation on both sides of the disk. An entry needs a nonempty category
---    and a finite score inside [MIN_SCORE, MAX_SCORE]; a document that does not
---    parse or holds an invalid entry is refused whole, never read as empty, so
---    a damaged file cannot be overwritten by the next edit.
--- 3. The previous macOS layout (a flat map of { type, score } records) is read
---    once and reported as `legacy`, so the driver rewrites it in the versioned
---    layout at its next save and the user's categories survive the upgrade.
--- 4. Free of any file, clock or JSON library: the caller passes its decoder and
---    encoder, which keeps the codec testable with the shared vectors.
--- ==============================================================================

local M = {}

M.FILE_NAME = "app_categories.json"
M.SCHEMA = "ergopti.app_categories"
M.VERSION = 1
M.MIN_SCORE = -2
M.MAX_SCORE = 2

-- The `meta` key prefix of the scores the previous Linux store kept in SQLite
M.LEGACY_SCORE_PREFIX = "app_score."

-- The category an application holds before the user picks one
M.DEFAULT_CATEGORY = "Unknown"




-- ===============================
-- ===============================
-- ======= 1/ Entries ============
-- ===============================
-- ===============================

--- Reports whether a score is one the dashboard can store.
--- @param score any
--- @return boolean
function M.score_valid(score)
	return type(score) == "number" and score == score
		and score >= M.MIN_SCORE and score <= M.MAX_SCORE
end

--- Reports whether a category label is storable.
--- @param label any
--- @return boolean
local function label_valid(label)
	return type(label) == "string" and label:find("%S") ~= nil
end

--- Validates one { type, score } record.
--- @param name any Application name.
--- @param entry any
--- @return boolean ok
--- @return string|nil reason
local function entry_valid(name, entry)
	if type(name) ~= "string" or name == "" then return false, "an application name must be a nonempty string" end
	if type(entry) ~= "table" then return false, "the entry of '" .. name .. "' must be a record" end
	if not label_valid(entry.type) then return false, "the category of '" .. name .. "' must be a nonempty string" end
	if not M.score_valid(entry.score) then
		return false, "the score of '" .. name .. "' must be a number between " .. M.MIN_SCORE .. " and " .. M.MAX_SCORE
	end
	return true
end

--- A model with no application.
--- @return table model { apps = {}, legacy = false }
function M.empty()
	return { apps = {}, legacy = false }
end




-- ===============================
-- ===============================
-- ======= 2/ Codec ==============
-- ===============================
-- ===============================

--- Reads the apps of a decoded document into a fresh table, validating each.
--- @param source table name -> { type, score }.
--- @return table|nil apps
--- @return string|nil reason
local function read_apps(source)
	local apps = {}
	for name, entry in pairs(source) do
		local ok, reason = entry_valid(name, entry)
		if not ok then return nil, reason end
		apps[name] = { type = entry.type, score = entry.score }
	end
	return apps
end

--- Decodes the bytes of the store file.
--- @param text string File content.
--- @param decode function JSON decoder, returning the value or raising.
--- @return table|nil model { apps, legacy }
--- @return string|nil reason Set when the document is refused.
function M.decode(text, decode)
	if type(text) ~= "string" then return nil, "the store content must be a string" end
	local parsed, document = pcall(decode, text)
	if not parsed or type(document) ~= "table" then return nil, "the store is not a JSON object" end
	if document.schema ~= M.SCHEMA then
		-- The previous macOS layout: every member is an application record, so an
		-- application named "schema" is a record and never the marker above.
		local apps, reason = read_apps(document)
		if not apps then return nil, reason end
		return { apps = apps, legacy = true }
	end
	if document.version ~= M.VERSION then return nil, "unsupported store version: " .. tostring(document.version) end
	if type(document.apps) ~= "table" then return nil, "the store has no apps object" end
	local apps, reason = read_apps(document.apps)
	if not apps then return nil, reason end
	return { apps = apps, legacy = false }
end

--- Encodes a model in the versioned layout.
--- @param model table { apps }
--- @param encode function JSON encoder for a Lua table.
--- @return string text
function M.encode(model, encode)
	local apps = "{}"
	-- An empty Lua table has no object spelling in the callers' encoders.
	if next(model.apps) ~= nil then apps = encode(model.apps) end
	return string.format('{"schema":"%s","version":%d,"apps":%s}', M.SCHEMA, M.VERSION, apps)
end




-- ===============================
-- ===============================
-- ======= 3/ Edits ==============
-- ===============================
-- ===============================

--- Assigns a category and score to an application.
--- @param model table
--- @param name string
--- @param category string
--- @param score number
--- @return boolean ok
--- @return string|nil reason
function M.set(model, name, category, score)
	local entry = { type = category, score = score }
	local ok, reason = entry_valid(name, entry)
	if not ok then return false, reason end
	model.apps[name] = entry
	return true
end

--- Renames a category on every application that holds it.
--- @param model table
--- @param old string
--- @param new string
--- @return number|nil renamed Applications changed; nil when the name is invalid.
--- @return string|nil reason
function M.rename_category(model, old, new)
	if not label_valid(new) then return nil, "the new category must be a nonempty string" end
	local renamed = 0
	for _, entry in pairs(model.apps) do
		if entry.type == old then
			entry.type = new
			renamed = renamed + 1
		end
	end
	return renamed
end

--- Adds the applications an older store held, keeping every entry the model
--- already has: an edit made after the upgrade is newer than what is imported.
--- @param model table
--- @param imported table name -> { type, score }.
--- @return number|nil added Entries added; nil when an imported entry is invalid.
--- @return string|nil reason
function M.import_missing(model, imported)
	local apps, reason = read_apps(imported)
	if not apps then return nil, reason end
	local added = 0
	for name, entry in pairs(apps) do
		if model.apps[name] == nil then
			model.apps[name] = entry
			added = added + 1
		end
	end
	return added
end

--- The map the dashboard page receives: name -> { type, score }.
--- @param model table
--- @return table
function M.projection(model)
	local out = {}
	for name, entry in pairs(model.apps) do out[name] = { type = entry.type, score = entry.score } end
	return out
end

return M
