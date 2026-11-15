--- infra/llm_preferences.lua

--- Owns declared AI preferences in canonical config.toml without legacy imports.
local M = {}
local Manifest = require("menu.engine.manifest_reader")
local Paths = require("settings.engine.paths")
local Writer = require("core.text.engine.toml_codec.writer")
local Codec = require("core.text.engine.toml_codec")
local Logger = require("core.logger.engine.shim")
local ConfigOutdated = require("settings.engine.migration.outdated")
local TableUtil = require("core.text.engine.table_util")
local LOG = "infra.llm_preferences"
local _scope_owner = nil
local _detached = nil
local _generation = 0
local _observed_source = nil
-- The document decoded from _observed_source's bytes. Only lookup() reads it and
-- every table value leaves as a copy, so identical bytes share one decode.
local _observed_document = nil

--- Admits ordinary actions only outside a retained scope and source write refusal.
--- @return boolean admitted
function M.admit()
	return _scope_owner == nil and Writer.write_refusal(Paths.config("config.toml")) == nil
end

--- Rechecks only the originating acknowledged revision and ordinary owner.
--- No IO or user callback occurs after this check in final write admission.
--- @param revision integer Captured source revision.
--- @return boolean current
function M.is_current_revision(revision)
	return _scope_owner == nil and _generation == revision
end

--- Acquires exclusive ownership before cancelling or changing AI runtime.
--- @param owner table Transaction identity.
--- @return boolean acquired
function M.acquire(owner)
	if type(owner) ~= "table" or _scope_owner ~= nil then return false end
	_scope_owner = owner
	_generation = _generation + 1
	return true
end

--- Releases the exact owner only after all compensation has settled.
--- @param owner table Transaction identity.
--- @return boolean released
function M.release(owner)
	if _scope_owner ~= owner or owner.pending() then return false end
	_scope_owner = nil
	return true
end

local function entry(path)
	local definition = type(path) == "string" and Manifest.find_entry_by_path(path) or nil
	assert(definition and path:sub(1, 4) == "llm.", "unknown AI preference: " .. tostring(path))
	return definition
end

local function validate(definition, value)
	if value == nil then return end
	local kind = definition.type
	if kind == "enum" then
		local fits, detail = ConfigOutdated.manifest_value_fits(definition, value, "linux")
		assert(fits, "invalid AI preference enum: " .. definition.path .. " (" .. tostring(detail) .. ")")
		return
	end
	assert(type(value) == (kind == "array" and "table" or kind), "invalid AI preference type: " .. definition.path)
	if kind == "number" then
		assert(value == value and value ~= math.huge and value ~= -math.huge, "AI preferences require finite numbers")
	elseif kind == "array" then
		local element_type
		for index, child in pairs(value) do
			local child_type = type(child)
			assert(type(index) == "number" and index % 1 == 0 and index >= 1 and index <= #value,
				"AI preference arrays must be dense")
			assert(child_type == "string" or child_type == "number" or child_type == "boolean",
				"AI preference arrays contain only scalar values")
			assert(not element_type or element_type == child_type, "AI preference arrays require one scalar kind")
			element_type = child_type
			if child_type == "number" then assert(child == child and math.abs(child) ~= math.huge, "invalid array number") end
		end
	end
end

--- Reads one declared leaf. A value an older build or a hand edit left in
--- another shape, or a scalar its path crosses, is outdated configuration for
--- that leaf alone: reported once and read as absent (its manifest value),
--- while every other AI preference keeps its value.
--- @param document table Decoded configuration.
--- @param path string Declared canonical path.
--- @return any value
local function lookup(document, path)
	local value, walked = document, {}
	for key in path:gmatch("[^.]+") do
		if value == nil then return nil, "absent" end
		if type(value) ~= "table" then
			ConfigOutdated.report(table.concat(walked, "."), "a table of settings is expected here", Logger)
			return nil, "invalid"
		end
		walked[#walked + 1] = key
		value = value[key]
	end
	if value == nil then return nil, "absent" end
	local definition = Manifest.find_entry_by_path(path)
	-- A case variant reads in its manifest spelling, as Windows' loader admits it.
	value = ConfigOutdated.canonical_enum_value(definition, value)
	if definition and not pcall(validate, definition, value) then
		ConfigOutdated.report(path, "the value no longer fits its " .. tostring(definition.type) .. " setting", Logger)
		return nil, "invalid"
	end
	return value, "ok"
end

local function read()
	if _detached then return _detached.document, _detached.source end
	-- Fresh bytes on every call: an external edit is seen at once. Only their
	-- decode is reused, which the managed download's per-chunk source fence
	-- otherwise repeated about 80 times for each 64 KiB chunk.
	local bytes, status, detail = Writer.read_classified(Paths.config("config.toml"))
	assert(status == "ok" or status == "absent", "AI configuration is unreadable: " .. tostring(detail))
	local source = { status = status, content = bytes }
	if _observed_source and _observed_source.status == status and _observed_source.content == bytes then
		return _observed_document, source
	end
	local document = Codec.decode(bytes or "")
	assert(type(document) == "table", "AI configuration contains malformed TOML")
	_generation = _generation + 1
	_observed_source, _observed_document = source, document
	return document, source
end

--- The exact source's acknowledged revision, including observed external edits.
--- @return integer
function M.generation()
	read()
	return _generation
end

--- Reads one override; the caller resolves absence through its manifest owner.
--- @param path string Declared preference path.
--- @param absent any Value returned only for proven absence.
--- @return any value Stored override or explicit absence value.
function M.get(path, absent)
	entry(path)
	local value = lookup(read(), path)
	if value == nil then return absent end
	if type(value) == "table" then return TableUtil.deep_copy(value) end
	return value
end

--- Reads a preference while distinguishing proven absence from a refused value.
--- @param path string Declared preference path.
--- @return any value Detached accepted value or nil.
--- @return string status "ok", "absent", or "invalid".
function M.get_with_status(path)
	entry(path)
	local value, status = lookup(read(), path)
	if type(value) == "table" then value = TableUtil.deep_copy(value) end
	return value, status
end

--- Resolves related choices from one exact source snapshot.
--- @param paths table Declared canonical paths.
--- @return table values Effective values keyed by path.
--- @return table source Exact bytes used to resolve the values.
--- @return integer revision Source revision captured before lookup callbacks.
function M.get_many(paths)
	for _, path in ipairs(paths) do entry(path) end
	local document, source = read()
	local revision = _generation
	local values = {}
	for _, path in ipairs(paths) do
		local value = lookup(document, path)
		if value == nil then value = Manifest.default_for(path) end
		if type(value) == "table" then value = TableUtil.deep_copy(value) end
		values[path] = value
	end
	return values, source, revision
end

--- Marks exactly one declared leaf through the same lookup as its reader. A
--- value the lookup or the owner's rule refuses is reported and left
--- unmarked, so the cleanup offers what the reader ignores.
--- @param document table Parsed configuration.
--- @param path string Reader-owned canonical path.
--- @param mark function Consumed-key collector.
--- @param accepts function|nil The owner's value rule, `accepts(value) -> boolean`.
function M.mark_config_read(document, path, mark, accepts)
	entry(path)
	local value = lookup(document, path)
	if value == nil then return end
	if accepts and not accepts(value) then
		ConfigOutdated.report(path, ConfigOutdated.REFUSED, Logger)
		return
	end
	local segments = {}
	for key in path:gmatch("[^.]+") do segments[#segments + 1] = key end
	mark((table.unpack or unpack)(segments))
end

--- Publishes one complete batch using the exact source observed before writing.
--- @param values table Canonical path to desired value.
--- @param expected_source table|nil Exact snapshot used to build a cached candidate.
--- @param admission function|nil Captured final writer admission.
--- @return boolean committed
local function set_many(values, expected_source, admission, on_notice)
	if not M.admit() or (admission ~= nil and type(admission) ~= "function") then return false end
	local called, committed, detail = pcall(function()
		assert(type(values) == "table", "AI preference batch requires a table")
		assert(expected_source == nil or type(expected_source) == "table", "AI preferences require an exact source snapshot")
		local operations = {}
		for path, value in pairs(values) do
			validate(entry(path), value)
			operations[#operations + 1] = Manifest.sparse_operation(path, value)
		end
		local _, source = read()
		return Writer.batch_write(Paths.config("config.toml"), operations, nil, expected_source or source, nil, admission, on_notice)
	end)
	if not called or committed ~= true then
		Logger.error(LOG, "AI preferences were not persisted: %s.", tostring(called and detail or committed))
		return false
	end
	_generation = _generation + 1
	return true
end

function M.set_many(values, expected_source, admission)
	return set_many(values, expected_source, admission)
end

--- Publishes a batch with notice acknowledgement for this exact write.
function M.set_many_with_notice(values, expected_source, admission, on_notice)
	return set_many(values, expected_source, admission, on_notice)
end

--- Publishes one leaf with notice acknowledgement for this exact write.
function M.set_with_notice(path, value, on_notice)
	return set_many({ [path] = value }, nil, nil, on_notice)
end

--- Persists a desired value sparsely against the manifest neutral default.
--- @param path string Declared preference path.
--- @param value any Desired value.
--- @return boolean committed
function M.set(path, value) return M.set_many({ [path] = value }) end

--- Removes an override by publishing its manifest-owned neutral value.
--- @param path string Declared preference path.
--- @return boolean committed
function M.delete(path)
	entry(path)
	return M.set(path, Manifest.default_for(path))
end

--- Validates and temporarily exposes one detached image to existing readers.
--- The owning transaction publishes the file; this API never writes or survives
--- the synchronous callback, including when a reader raises.
--- @param owner table Admission identity.
--- @param source table Classified source containing candidate bytes.
--- @param callback function Existing runtime readers.
--- @return boolean applied
function M.with_configuration(owner, source, callback)
	if _scope_owner ~= owner or _detached ~= nil then return false end
	local document = Codec.decode(source.content or "")
	assert(type(document) == "table", "AI configuration contains malformed TOML")
	for _, definition in ipairs(Manifest.features()) do
		if definition.path:sub(1, 4) == "llm." then validate(definition, lookup(document, definition.path)) end
	end
	_detached = { document = document, source = source }
	local ok, result = pcall(callback)
	_detached = nil
	if not ok then error(result, 0) end
	return result == true
end

return M
