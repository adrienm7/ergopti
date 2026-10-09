--- infra/hotstring_preferences.lua

--- ==============================================================================
--- MODULE: Hotstring Scalar Preferences (Linux)
--- DESCRIPTION:
--- Owns the hotstring settings that are single canonical config.toml leaves:
--- the magic key and its physical key, the four preview toggles, the dynamic
--- master and each dynamic family. Absence resolves through the manifest's
--- neutral default, so an empty configuration switches every one of them off.
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
local ConfigOutdated = require("config_outdated")
local Terminators = require("keymap.terminators")

local LOG = "infra.hotstring_preferences"

--- The owned scalar leaves. Dynamic families are the manifest's own
--- `hotstrings.dynamic` feature rows, appended below, so a family declared there
--- is owned here without a second list.
local OWNED = {
	"hotstrings.trigger_char",
	"hotstrings.magic_key_source",
	"hotstrings.preview_star_enabled",
	"hotstrings.preview_autocorrect_enabled",
	"hotstrings.preview_ai_enabled",
	"hotstrings.preview_colored_tooltips",
	"hotstrings.dynamic.enabled",
	"hotstrings.dynamic.user_code.time_activation_seconds",
}
for _, entry in ipairs(Manifest.features()) do
	if entry.section == "hotstrings.dynamic" and entry.type == "feature" then
		OWNED[#OWNED + 1] = entry.path .. ".enabled"
	end
end
local _owned = {}
for _, path in ipairs(OWNED) do
	local neutral = Manifest.default_for(path)
	assert(type(neutral) == "boolean" or type(neutral) == "string" or type(neutral) == "number",
		"hotstring preference default is not a scalar: " .. path)
	_owned[path] = type(neutral)
end

-- Owners' rules beyond the declared type. A stored value its owner refuses
-- (a magic key today's shared policy rejects) is outdated for the cleanup
-- exactly as it is for the owner's reader, which warns with the same words.
local VALUE_RULES = {
	["hotstrings.trigger_char"] = function(value) return Terminators.validate_magic_key(value) == true end,
	["hotstrings.dynamic.user_code.time_activation_seconds"] = function(value)
		return type(value) == "number" and value == value and value >= 0 and value < math.huge
	end,
}

local _document = nil
-- Bumped on every change of _document, so a reader that caches what it derived
-- from a leaf (the physical magic key's evdev code, asked on every grabbed
-- key-down) knows when to derive it again.
local _generation = 0
local _scope_owner = nil
local _file = nil




-- =========================================
-- =========================================
-- ======= 1/ Document =====================
-- =========================================
-- =========================================

local function file() return _file or ConfigPaths.config("config.toml") end

--- Makes a document the cached one.
--- @param document table|false|nil Decoded document; false after a refused
---   first read, nil to read again.
local function publish(document)
	_document = document
	_generation = _generation + 1
end

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

--- Reads one owned leaf without judging it.
--- @param document table
--- @param path string
--- @return any value The stored value, nil when absent or unusable.
--- @return string|nil outdated Path of the unusable entry: the leaf itself
---   (wrong type) or the scalar its path crosses (`[hotstrings] dynamic = true`).
--- @return string|nil detail Why that entry is outdated.
local function inspect(document, path)
	local value, walked = document, {}
	for _, key in ipairs(segments(path)) do
		if value == nil then return nil end
		if type(value) ~= "table" then
			return nil, table.concat(walked, "."), "a table of settings is expected here"
		end
		walked[#walked + 1] = key
		value = value[key]
	end
	if value ~= nil and type(value) ~= _owned[path] then
		return nil, path, "the value is not a " .. _owned[path]
	end
	-- An enum leaf (the physical magic key) holding a value its manifest no
	-- longer lists is outdated on its own, never read as another choice.
	local entry = value ~= nil and Manifest.find_entry_by_path(path) or nil
	if type(entry) == "table" and entry.type == "enum" then
		local fits, detail = ConfigOutdated.manifest_value_fits(entry, value, "linux")
		if not fits then return nil, path, detail end
	end
	return value
end

--- Reads one owned leaf. An unusable entry an older build or a hand edit left
--- is outdated configuration for that leaf alone: warned once and read as
--- absent (its neutral default), while every other leaf keeps its value.
--- @param document table
--- @param path string
--- @return any value
local function lookup(document, path)
	local value, outdated, detail = inspect(document, path)
	if value ~= nil and path == "hotstrings.dynamic.user_code.time_activation_seconds" and not VALUE_RULES[path](value) then
		outdated, detail, value = path, "the activation interval is not a finite non-negative number", nil
	end
	if outdated then ConfigOutdated.report(outdated, detail, Logger) end
	return value
end

--- Checks the shape of a decoded document; owned leaves are judged one by one.
--- @param document table
--- @return table document
local function validate(document)
	assert(type(document) == "table", "hotstring preferences are malformed")
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
	publish(document)
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
		publish(false)
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

--- The generation of the cached document: it changes whenever the document
--- does (a write, a refresh, a scope's adoption or restoration).
--- @return number
function M.generation()
	return _generation
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

--- Marks the owned leaves a document sets, through the same reading as the
--- reader: an outdated leaf is reported and left unmarked, so the cleanup
--- offers it.
--- @param document table Decoded config.toml.
--- @param mark function mark(...segments).
function M.mark_config_reads(document, mark)
	validate(document)
	for _, path in ipairs(OWNED) do
		local value = lookup(document, path)
		if value ~= nil and VALUE_RULES[path] and not VALUE_RULES[path](value) then
			ConfigOutdated.report(path, ConfigOutdated.REFUSED, Logger)
		elseif value ~= nil then
			mark((table.unpack or unpack)(segments(path)))
		end
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
			if path == "hotstrings.dynamic.user_code.time_activation_seconds" then
				assert(VALUE_RULES[path](value), "programmable hotstring activation interval is invalid")
			end
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
		publish(decode(content))
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

--- Whether a scope transaction owns the hotstring configuration, so another
--- config.toml writer of the same scope waits instead of breaking its inverse.
--- @return boolean
function M.is_acquired()
	return _scope_owner ~= nil
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
--- @param touched table|nil Explicit owned paths written by a narrower scope.
--- @return boolean adopted
function M.adopt(owner, document, touched)
	if _scope_owner ~= owner then return false end
	local ok, validated = pcall(function()
		validate(document)
		-- A complete scope validates every owned leaf. A narrower owner proves
		-- its own outputs without claiming unrelated outdated configuration.
		assert(touched == nil or type(touched) == "table", "invalid hotstring preference selection")
		for path, selected in pairs(touched or _owned) do
			owned(path)
			assert(touched == nil or selected == true, "invalid hotstring preference selection")
			local _, outdated, detail = inspect(document, path)
			assert(outdated ~= path, "hotstring preference has the wrong type: " .. path)
			if touched then assert(outdated == nil, "hotstring preference crosses an unusable parent: " .. path) end
			if outdated then ConfigOutdated.report(outdated, detail, Logger) end
		end
		return document
	end)
	if not ok then
		Logger.error(LOG, "Candidate hotstring preferences were refused: %s.", tostring(validated))
		return false
	end
	publish(clone(validated))
	return true
end

--- Restores a snapshot taken before a refused publication.
--- @param owner table The acquiring transaction.
--- @param snapshot table Result of M.snapshot().
--- @return boolean restored
function M.restore(owner, snapshot)
	if _scope_owner ~= owner or type(snapshot) ~= "table" or type(snapshot.document) ~= "table" then return false end
	publish(clone(snapshot.document))
	return true
end

--- Test seam: routes every read and write to an isolated configuration file.
--- @param path string|nil Absolute path, or nil to restore production routing.
--- @return boolean
function M._set_file_for_test(path)
	if path ~= nil and (type(path) ~= "string" or path:sub(1, 1) ~= "/") then return false end
	_file = path
	publish(nil)
	return true
end

return M
