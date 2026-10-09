--- infra/metrics_preferences.lua

--- ==============================================================================
--- MODULE: Canonical Metrics Preferences (Linux)
--- DESCRIPTION:
--- Owns the collector and WPM boolean choices in config.toml. Widget positions
--- and collected data retain their separate owners; legacy storage cannot grant
--- consent or reactivate a preference removed by the canonical scope writer.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")
local ConfigPaths = require("infra.config_paths")
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local Logger = require("logger.shim")
local ConfigOutdated = require("config_outdated")
local LOG = "infra.metrics_preferences"
local _scope_owner = nil

--- Admits ordinary preference mutation only outside a retained scope transaction.
--- @return boolean admitted
function M.admit() return _scope_owner == nil end

--- Acquires the metrics preference domain before any scope effects.
--- @param owner table Transaction identity.
--- @return boolean acquired
function M.acquire(owner)
	if type(owner) ~= "table" or _scope_owner ~= nil then return false end
	_scope_owner = owner
	return true
end

--- Releases only the exact owner after all compensation has settled.
--- @param owner table Transaction identity.
--- @return boolean released
function M.release(owner)
	if _scope_owner ~= owner or owner.pending() then return false end
	_scope_owner = nil
	return true
end

local function owned(path)
	local entry = type(path) == "string" and Manifest.find_entry_by_path(path) or nil
	assert(entry and path:match("^metrics%.[^.]+$") and entry.type == "boolean",
		"unknown boolean metrics preference: " .. tostring(path))
	return path:sub(#"metrics." + 1)
end

--- Resolves owned booleans from one parsed configuration without file effects.
--- A leaf an older build or a hand edit left in another shape is outdated
--- configuration for that leaf alone: warned once, read as its neutral
--- default (never as consent) and left unmarked for the cleanup.
--- @param config table Parsed canonical configuration.
--- @param mark function|nil Exact consumed-key collector.
--- @param written table|nil Set of paths the caller's own transaction wrote:
---   those must hold a boolean, since a wrong one is that write's failure.
--- @return table values Canonical path to effective boolean.
function M.resolve(config, mark, written)
	assert(type(config) == "table", "metrics preferences contain malformed TOML")
	local metrics = config.metrics
	if metrics ~= nil and type(metrics) ~= "table" then
		ConfigOutdated.report({ "metrics" }, "a table of settings is expected here", Logger)
		metrics = nil
	end
	local values = {}
	metrics = metrics or {}
	for _, entry in ipairs(Manifest.features()) do
		if entry.path:match("^metrics%.[^.]+$") and entry.type == "boolean" then
			local key = owned(entry.path)
			local value = metrics[key]
			if value ~= nil and type(value) ~= "boolean" then
				assert(not (written and written[entry.path]), "invalid boolean metrics preference: " .. entry.path)
				ConfigOutdated.report({ "metrics", key }, "the value is not a boolean", Logger)
				value = nil
			end
			if mark and value ~= nil then mark("metrics", key) end
			if value == nil then value = Manifest.default_for(entry.path) end
			values[entry.path] = value
		end
	end
	return values
end

--- Reads validated values and their exact source for conditional publication.
--- @return table values Canonical effective preferences.
--- @return table source Classified source bytes.
function M.snapshot()
	local bytes, status, detail = Writer.read_classified(ConfigPaths.config("config.toml"))
	assert(status == "ok" or status == "absent", "metrics preferences are unreadable: " .. tostring(detail))
	return M.resolve(Codec.decode(bytes or "")), { status = status, content = bytes }
end

--- Reads one declared boolean without creating a file or caching a refusal.
--- @param path string Canonical manifest path.
--- @return boolean value
function M.get(path)
	owned(path)
	return M.snapshot()[path]
end

--- Publishes one sparse choice while preserving unknown configuration.
--- @param path string Canonical manifest path.
--- @param value boolean New preference.
--- @return boolean committed
function M.set(path, value)
	if not M.admit() then return false end
	local called, committed, detail = pcall(function()
		owned(path)
		assert(type(value) == "boolean", "metrics preferences require boolean values")
		local _, source = M.snapshot()
		local operation = Manifest.sparse_operation(path, value)
		return Writer.batch_write(ConfigPaths.config("config.toml"), { operation }, nil, source)
	end)
	if not called or committed ~= true then
		Logger.error(LOG, "Metrics preference '%s' was not persisted: %s.", tostring(path), tostring(called and detail or committed))
		return false
	end
	Logger.debug(LOG, "Metrics preference '%s' persisted as %s.", path, tostring(value))
	return true
end

return M
