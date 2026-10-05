--- infra/config_overrides.lua

--- ==============================================================================
--- MODULE: User Config Overrides
--- DESCRIPTION:
--- Loads the [script] / [features] sections from the driver-specific
--- config.toml and applies their scalar values to hs.settings.
---
--- FEATURES & RATIONALE:
--- 1. Optional File: a missing config.toml is a valid no-op.
--- 2. Shared Schema: [script] owns driver settings and [features] owns dotted
---    feature keys, matching the AutoHotkey driver.
--- 3. Canonical Parser: the shared TOML codec owns strings, comments, and
---    continuations. Shared projection owns scalar settings and source paths,
---    so text inside a multiline value can never become executable settings.
--- 4. Fail Closed: incomplete reads, close failures, and invalid TOML publish
---    no partial override state.
--- ==============================================================================

local M = {}
local Logger    = require("infra.logger")
local Storage   = require("adapters.storage")
local TomlCodec = require("infra.toml.codec")
local Projection = require("config_override_projection")
local Manifest = require("infra.manifest_reader")
local ConfigOutdated = require("config_outdated")
local FileSystem = require("adapters.file_system")
local LOG       = "config_overrides"





-- =================================
-- =================================
-- ======= 1/ Value Coercion =======
-- =================================
-- =================================

--- Converts a raw scalar literal for the cross-driver coercion corpus.
--- Runtime file parsing uses TomlCodec.decode(); this public function remains
--- the small parity surface shared with the AHK override loader.
--- @param raw string Raw scalar literal.
--- @return any coerced
function M.coerce(raw)
	local trimmed = raw:match("^%s*(.-)%s*$") or ""
	local lower = trimmed:lower()
	if lower == "true" then return true end
	if lower == "false" then return false end
	if trimmed:match("^-?%d+$") then return tonumber(trimmed) end
	if trimmed:match("^-?%d+%.%d+$") then return tonumber(trimmed) end
	local body = trimmed:match('^"(.*)"$')
	if body then
		body = body:gsub("\\\\", "\\"):gsub('\\"', '"')
			:gsub("\\n", "\n"):gsub("\\t", "\t")
		return body
	end
	return trimmed
end





-- ==================================
-- ==================================
-- ======= 2/ Override Loader =======
-- ==================================
-- ==================================

local function read_committed(path)
	local category
	local called, content, status = pcall(FileSystem.read_with_status, path, function(reason)
		category = type(reason) == "string" and reason or "invalid diagnostic receipt"
	end)
	if not called then return nil, "classified reader raised" end
	if category then return nil, "classified " .. category .. " failure" end
	if status == "absent" and content == nil then return nil, "absent" end
	if status == "ok" and type(content) == "string" then return content, nil end
	return nil, "classified read did not commit"
end

--- Checks only settings whose native owner has published a value catalogue.
--- Arbitrary legacy expert scalar keys retain their existing settings contract.
--- @param row table Exact source identity and projected native setting.
--- @param decoded table Admitted source document.
--- @return boolean fits
--- @return string|nil detail Why the native owner ignores this value.
local function known_value_fits(row, decoded)
	local function threshold(value)
		if type(Logger.LEVELS) ~= "table" or next(Logger.LEVELS) == nil then return true end
		if type(value) == "string" and Logger.LEVELS[value:upper()] ~= nil then return true end
		return false, "the value is not a published log threshold"
	end
	if row.section == "script" and type(row.key) == "string" then
		local lower = row.key:lower()
		if lower == "log_level" or lower == "loglevel" then
			local fits, detail = threshold(row.value)
			return fits, detail, row.path
		end
	elseif row.section == "features" then
		local path, node = {}, decoded.features
		for _, segment in ipairs(row.path) do
			path[#path + 1] = segment
			if type(node) == "table" then node = node[segment] else node = nil end
			local setting = table.concat(path, ".")
			local fits, detail = true, nil
			local entry = Manifest.find_declared_entry_by_path(setting)
			if entry then fits, detail = ConfigOutdated.manifest_value_fits(entry, node, "hs") end
			-- Projection expands dictionaries. A wrong-shaped declared scalar
			-- must not escape its owner as arbitrary descendant settings.
			if not fits then return false, detail, path end
		end
	end
	return true
end

--- Shares the exact rejected source identity between boot publication and cleanup.
--- @param row table Original override candidate.
--- @param decoded table Admitted source document.
--- @return boolean fits
local function admit_known_value(row, decoded)
	local fits, detail, path = known_value_fits(row, decoded)
	if not fits then
		local segments = { row.section }
		for _, segment in ipairs(path) do segments[#segments + 1] = segment end
		ConfigOutdated.report(segments, detail, Logger)
	end
	return fits
end

--- Marks each original source path the legacy setting projection consumes.
--- @param decoded table Decoded config.toml.
--- @param mark function mark(...segments) from config_unused_keys.
function M.mark_config_reads(decoded, mark)
	local rows = Projection.prepare(decoded)
	if not rows then return end
	for _, row in ipairs(rows) do
		local fits = admit_known_value(row, decoded)
		if row.accepted and fits then mark(row.section, table.unpack(row.path)) end
	end
end

--- Reads file_path and applies scalar [script] / [features] values.
--- @param file_path string Absolute path to config.toml.
--- @return integer applied Number of settings committed.
function M.apply(file_path)
	if type(file_path) ~= "string" or file_path == "" then return 0 end
	local content, read_err = read_committed(file_path)
	if not content then
		if read_err == "absent" then
			Logger.debug(LOG, "config.toml not found at '%s' — skipping overrides.", file_path)
		else
			Logger.error(LOG, "config.toml read did not commit for '%s': %s.",
				file_path, tostring(read_err))
		end
		return 0
	end

	local decode_ok, decoded = pcall(TomlCodec.decode, content)
	if not decode_ok or type(decoded) ~= "table" then
		Logger.error(LOG, "config.toml is invalid; no overrides were applied from '%s'.", file_path)
		return 0
	end

	local candidates, projection_error = Projection.prepare(decoded)
	if not candidates then
		Logger.error(LOG, "config.toml override identities are ambiguous; no overrides were applied: %s.", projection_error)
		return 0
	end

	Logger.start(LOG, "Applying user overrides from '%s'…", file_path)
	local applied = 0
	for _, row in ipairs(candidates) do
		local section_name, key, value, accepted = row.section, row.key, row.value, row.accepted
		if not admit_known_value(row, decoded) then goto continue_override end
		if not accepted then
			Logger.warn(LOG, "Ignoring non-scalar override in [%s].", section_name)
			goto continue_override
		end
		local setting_key = key
		if section_name == "script" then
			local lower_key = key:lower()
			if lower_key == "log_level" or lower_key == "loglevel" then
				setting_key = "log_level"
			end
		end
		if Storage.set(setting_key, value) == true then
			applied = applied + 1
			Logger.debug(LOG, "Override [%s].%s = %s.",
				section_name, key, tostring(value))
		else
			Logger.error(LOG, "Override [%s].%s could not be persisted.",
				section_name, key)
		end
		::continue_override::
	end
	Logger.success(LOG, "User overrides applied (%d value(s)).", applied)
	return applied
end

return M
