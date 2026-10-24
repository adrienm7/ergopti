--- infra/config_overrides.lua

--- ==============================================================================
--- MODULE: User Config Overrides
--- DESCRIPTION:
--- Loads the [script] section from the driver-specific config.toml and applies
--- its scalar values to hs.settings.
---
--- FEATURES & RATIONALE:
--- 1. Optional File: a missing config.toml is a valid no-op.
--- 2. Shared Schema: [script] owns driver settings, matching the AutoHotkey
---    driver. The `[features]` layer is retired: every declared feature has one
---    canonical leaf, and a file that still carries a `[features]` table gets it
---    reported by the unused-key scan instead of applied.
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
local Projection = require("script_override_projection")
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
--- Other [script] scalar keys retain their existing settings contract.
--- @param row table Exact source identity and projected native setting.
--- @return boolean fits
--- @return string|nil detail Why the native owner ignores this value.
local function known_value_fits(row)
	local function threshold(value)
		if type(Logger.LEVELS) ~= "table" or next(Logger.LEVELS) == nil then return true end
		if type(value) == "string" and Logger.LEVELS[value:upper()] ~= nil then return true end
		return false, "the value is not a published log threshold"
	end
	if row.section == "script" and type(row.key) == "string" then
		if row.key == "log_level" then
			local fits, detail = threshold(row.value)
			return fits, detail, row.path
		end
	end
	return true
end

--- Shares the exact rejected source identity between boot publication and cleanup.
--- @param row table Original override candidate.
--- @return boolean fits
local function admit_known_value(row)
	local fits, detail, path = known_value_fits(row)
	if not fits then
		local segments = { row.section }
		for _, segment in ipairs(path) do segments[#segments + 1] = segment end
		ConfigOutdated.report(segments, detail, Logger)
	end
	return fits
end

--- Reads one declared native setting through its published value catalogue.
--- Obsolete persisted defaults are ignored without granting deletion authority;
--- absent values remain available to the caller's canonical preference fallback.
--- @param path string Logical native setting and declared feature path.
--- @return any value Admitted value, or nil when absent or obsolete.
function M.read_native_value(path)
	local entry = assert(Manifest.find_declared_entry_by_path(path),
		"native setting has no published declaration: " .. tostring(path))
	local value = Storage.get(path)
	if value == nil then return nil end
	local fits, detail = ConfigOutdated.manifest_value_fits(entry, value, "hs")
	if fits then return value end
	ConfigOutdated.report_in_file("hs.settings", { path }, detail, Logger)
	return nil
end

--- Marks each original source path the legacy setting projection consumes.
--- @param decoded table Decoded config.toml.
--- @param mark function mark(...segments) from config_unused_keys.
function M.mark_config_reads(decoded, mark)
	local rows = Projection.prepare(decoded)
	if not rows then return end
	for _, row in ipairs(rows) do
		local fits = admit_known_value(row)
		if row.accepted and fits then mark(row.section, table.unpack(row.path)) end
	end
end

--- Reads file_path and applies scalar [script] values.
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
		Logger.error(LOG, "config.toml overrides cannot be projected; none was applied: %s.", projection_error)
		return 0
	end

	Logger.start(LOG, "Applying user overrides from '%s'…", file_path)
	local applied = 0
	for _, row in ipairs(candidates) do
		local section_name, key, value, accepted = row.section, row.key, row.value, row.accepted
		if not admit_known_value(row) then goto continue_override end
		if not accepted then
			Logger.warn(LOG, "Ignoring non-scalar override in [%s].", section_name)
			goto continue_override
		end
		if Storage.set(key, value) == true then
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
