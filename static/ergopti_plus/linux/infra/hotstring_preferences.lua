--- infra/hotstring_preferences.lua

--- ==============================================================================
--- MODULE: Hotstring Scalar Preferences (Linux)
--- DESCRIPTION:
--- Owns the hotstring settings that are single canonical config.toml leaves:
--- the magic key, the four preview toggles, the dynamic master and each dynamic
--- family. Absence resolves through the manifest's neutral default, so an empty
--- configuration switches every one of them off.
---
--- FEATURES & RATIONALE:
--- 1. One cached document. The magic key and the dynamic family switches are
---    read on the typing path; they are answered from the document read at
---    refresh or at the last write, never from the disk per keystroke.
--- 2. Sparse, conditional writes. A value equal to its neutral default removes
---    the key, and every write carries the exact bytes it was prepared from, so
---    a concurrent edit is refused rather than overwritten.
--- 3. Scope ownership. A scope transaction acquires the owner, adopts its
---    candidate document before publishing the file, and restores the exact
---    previous document when it rolls back. Ordinary writes wait for it.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")
local ConfigPaths = require("infra.config_paths")
local Writer = require("toml_codec.writer")
local LeafRows = require("toml_codec.leaf_rows")
local Codec = require("toml_codec")
local Shell = require("adapters.shell_runner")
local Logger = require("logger.shim")

local LOG = "infra.hotstring_preferences"

--- The owned scalar leaves. Dynamic families are the manifest's own
--- `hotstrings.dynamic` feature rows, appended below, so a family declared there
--- is owned here without a second list.
local OWNED = {
	"hotstrings.trigger_char",
	"hotstrings.preview_star_enabled",
	"hotstrings.preview_autocorrect_enabled",
	"hotstrings.preview_ai_enabled",
	"hotstrings.preview_colored_tooltips",
	"hotstrings.dynamic.enabled",
}
for _, entry in ipairs(Manifest.features()) do
	if entry.section == "hotstrings.dynamic" and entry.type == "feature" then
		OWNED[#OWNED + 1] = entry.path .. ".enabled"
	end
end
local _owned = {}
for _, path in ipairs(OWNED) do
	local neutral = Manifest.default_for(path)
	assert(type(neutral) == "boolean" or type(neutral) == "string", "hotstring preference default is not a scalar: " .. path)
	_owned[path] = type(neutral)
end

local _document = nil
local _scope_owner = nil
local _file = nil




-- =========================================
-- =========================================
-- ======= 1/ Document =====================
-- =========================================
-- =========================================

local function file() return _file or ConfigPaths.config("config.toml") end

local function clone(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do copy[key] = clone(child) end
	return copy
end

local function segments(path)
	local parts = {}
	for part in path:gmatch("[^.]+") do parts[#parts + 1] = part end
	return parts
end

--- Reads one owned leaf, refusing a path that crosses a scalar.
--- @param document table
--- @param path string
--- @return any
local function lookup(document, path)
	local value = document
	for _, key in ipairs(segments(path)) do
		if value == nil then return nil end
		assert(type(value) == "table", "hotstring preference path crosses a scalar: " .. path)
		value = value[key]
	end
	return value
end

--- Validates every owned leaf of a decoded document.
--- @param document table
--- @return table document
local function validate(document)
	assert(type(document) == "table", "hotstring preferences are malformed")
	for path, kind in pairs(_owned) do
		local value = lookup(document, path)
		assert(value == nil or type(value) == kind, "hotstring preference has the wrong type: " .. path)
	end
	return document
end

local function decode(content)
	local document = Codec.decode(content or "")
	assert(type(document) == "table", "hotstring preferences contain malformed TOML")
	return validate(document)
end

local function read()
	local content, status, detail = Writer.read_classified(file())
	assert(status == "ok" or status == "absent", "hotstring preferences are unreadable: " .. tostring(detail))
	return decode(content), { status = status, content = content }
end

local function owned(path)
	assert(_owned[path] ~= nil, "not an owned hotstring preference: " .. tostring(path))
end




-- =========================================
-- =========================================
-- ======= 2/ Reading ======================
-- =========================================
-- =========================================

--- Rereads config.toml into the cache. A refused read keeps the previous one.
--- @return boolean refreshed
function M.refresh()
	local ok, document = pcall(read)
	if not ok then
		Logger.error(LOG, "Hotstring preferences were not refreshed: %s.", tostring(document))
		return false
	end
	_document = document
	return true
end

--- The cached document, read once. A configuration that cannot be read leaves
--- every owned leaf on its neutral default until an explicit refresh succeeds:
--- guessing an input-altering choice is worse than switching it off, and the
--- typing path must not retry the disk on every keystroke.
--- @return table document
local function current()
	if _document == nil and not M.refresh() then
		Logger.error(LOG, "Hotstring preferences are unreadable; every owned leaf stays neutral.")
		_document = false
	end
	return _document or {}
end

--- The effective value of one owned leaf: the explicit choice or its neutral default.
--- @param path string Owned preference path.
--- @return boolean|string value
function M.get(path)
	owned(path)
	local value = lookup(current(), path)
	if value == nil then return Manifest.default_for(path) end
	return value
end

--- Whether an owned leaf is explicitly present in the cached document.
--- @param path string Owned preference path.
--- @return boolean
function M.is_explicit(path)
	owned(path)
	return lookup(current(), path) ~= nil
end

--- The owned leaves, for scope and cleanup inventories.
--- @return table Array of paths.
function M.paths()
	local copy = {}
	for index, path in ipairs(OWNED) do copy[index] = path end
	return copy
end

--- Marks the owned leaves a document sets, through the same validation as the reader.
--- @param document table Decoded config.toml.
--- @param mark function mark(...segments).
function M.mark_config_reads(document, mark)
	validate(document)
	for _, path in ipairs(OWNED) do
		if lookup(document, path) ~= nil then mark((table.unpack or unpack)(segments(path))) end
	end
end




-- =========================================
-- =========================================
-- ======= 3/ Writing ======================
-- =========================================
-- =========================================

--- Publishes several owned leaves sparsely against their neutral defaults.
--- @param values table Owned path to desired value.
--- @return boolean committed
--- @return string|nil reason
function M.set_many(values)
	if _scope_owner ~= nil then return false, "a hotstring configuration scope is pending" end
	local called, committed, detail = pcall(function()
		assert(type(values) == "table", "hotstring preferences require a table of values")
		local _, source = read()
		local operations = {}
		for path, value in pairs(values) do
			owned(path)
			assert(type(value) == _owned[path], "hotstring preference has the wrong type: " .. path)
			if value == Manifest.default_for(path) then
				operations[#operations + 1] = { path = segments(path), delete = true }
			else
				operations[#operations + 1] = { path = segments(path), value = value }
			end
		end
		local rows = LeafRows.prepare(source.content or "", operations)
		local directory = file():match("^(.*)/[^/]+$")
		if source.status == "absent" and not Shell.run("mkdir -p " .. Shell.quote(directory) .. " 2>/dev/null") then
			return false, "the configuration folder cannot be created"
		end
		local written, why, content = Writer.batch_write(file(), rows, nil, source)
		if written ~= true then return false, why end
		_document = decode(content)
		return true
	end)
	if called and committed == true then return true end
	local reason = tostring(called and detail or committed)
	Logger.error(LOG, "Hotstring preferences were not persisted: %s.", reason)
	return false, reason
end

--- Publishes one owned leaf.
--- @param path string Owned preference path.
--- @param value boolean|string Desired value.
--- @return boolean committed
--- @return string|nil reason
function M.set(path, value) return M.set_many({ [path] = value }) end




-- =========================================
-- =========================================
-- ======= 4/ Scope ownership ==============
-- =========================================
-- =========================================

--- Acquires exclusive ownership for one scope transaction.
--- @param owner table Transaction identity.
--- @return boolean acquired
function M.acquire(owner)
	if type(owner) ~= "table" or _scope_owner ~= nil then return false end
	_scope_owner = owner
	return true
end

--- Releases ownership once the transaction retains no compensation.
--- @param owner table Transaction identity.
--- @return boolean released
function M.release(owner)
	if _scope_owner ~= owner then return false end
	_scope_owner = nil
	return true
end

--- A detached copy of the cached document for exact restoration.
--- @return table snapshot
function M.snapshot()
	if not _document and not M.refresh() then return nil end
	return { document = clone(_document) }
end

--- Makes a validated candidate document effective before its file is published.
--- @param owner table The acquiring transaction.
--- @param document table Decoded candidate.
--- @return boolean adopted
function M.adopt(owner, document)
	if _scope_owner ~= owner then return false end
	local ok, validated = pcall(validate, document)
	if not ok then
		Logger.error(LOG, "Candidate hotstring preferences were refused: %s.", tostring(validated))
		return false
	end
	_document = clone(validated)
	return true
end

--- Restores a snapshot taken before a refused publication.
--- @param owner table The acquiring transaction.
--- @param snapshot table Result of M.snapshot().
--- @return boolean restored
function M.restore(owner, snapshot)
	if _scope_owner ~= owner or type(snapshot) ~= "table" or type(snapshot.document) ~= "table" then return false end
	_document = clone(snapshot.document)
	return true
end

--- Test seam: routes every read and write to an isolated configuration file.
--- @param path string|nil Absolute path, or nil to restore production routing.
--- @return boolean
function M._set_file_for_test(path)
	if path ~= nil and (type(path) ~= "string" or path:sub(1, 1) ~= "/") then return false end
	_file = path
	_document = nil
	return true
end

return M
