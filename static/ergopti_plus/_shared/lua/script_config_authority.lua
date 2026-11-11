--- _shared/lua/script_config_authority.lua

--- ==============================================================================
--- MODULE: Script Config Authority
--- DESCRIPTION:
--- Makes config.toml's `[script]` rows (locale, log level, error window) the
--- start authority on the Lua drivers, as on Windows. Each row has a native
--- alias (hs.settings on macOS, storage.json on Linux) that the runtime reads;
--- at start a configured row is written into its alias before any reader runs,
--- and a menu or wizard change rewrites the row the file already holds, so the
--- next start does not undo it.
---
--- FEATURES & RATIONALE:
--- 1. No migration (maintainer decision of 2026-10-31): a file without a row
---    leaves the native value alone, and a menu change touches config.toml only
---    when the file already holds that row. Nothing is copied between stores.
--- 2. Declared values only: a configured value the manifest refuses for this
---    platform is reported through config_outdated and not adopted.
--- 3. Fail fast: an unreadable or malformed config.toml adopts nothing and says
---    so; a refused native or file write is returned as false, never hidden.
--- ==============================================================================

local M = {}
local Codec = require("toml_codec")
local ConfigKeys = require("config_keys")
local KeyPath = require("toml_codec.key_path")
local Outdated = require("config_outdated")
local TableUtil = require("table_util")
local Writer = require("toml_codec.writer")





-- =================================
-- =================================
-- ======= 1/ Source reading =======
-- =================================
-- =================================

--- Returns the value a decoded document holds at a canonical dotted path.
--- @param document table Decoded configuration.
--- @param path string Canonical path such as `script.locale`.
--- @return any value Nil when any segment is absent or crosses a scalar.
local function source_value(document, path)
	local value = document
	for _, segment in ipairs(assert(KeyPath.parse(path))) do
		if type(value) ~= "table" then return nil end
		value = value[segment]
	end
	return value
end

--- Reads and decodes config.toml through the classified reader.
--- @param path string config.toml path.
--- @param file_adapter table|nil Platform file adapter.
--- @return table|nil document Nil when the source cannot be trusted.
--- @return table|nil source `{ status, content }` precondition for a later write.
--- @return string|nil detail Why no document was returned.
local function read_document(path, file_adapter)
	local content, status, detail = Writer.read_classified(path, file_adapter)
	if status == "absent" then return {}, { status = "absent" }, nil end
	if status ~= "ok" or type(content) ~= "string" then
		return nil, nil, "config.toml is unreadable: " .. tostring(detail)
	end
	local ok, document = pcall(Codec.decode, content)
	if not ok or type(document) ~= "table" then return nil, nil, "config.toml is not valid TOML" end
	return document, { status = "ok", content = content }, nil
end

--- The value rules the manifest type alone cannot state: a locale is a
--- string to the manifest, but only a shipped locale can be adopted, or the
--- start would replace a good saved locale with one i18n then refuses.
local VALUE_RULES = {
	[ConfigKeys.KEY.SCRIPT_LOCALE] = function(value)
		if type(value) ~= "string" then return false, "the value is not a string" end
		for _, row in ipairs(require("_generated.locale_table")) do
			if row.code == value then return true end
		end
		return false, "'" .. value .. "' is not a shipped locale"
	end,
}

--- Returns the declaration of a row and whether this platform carries it.
--- @param manifest table Manifest reader.
--- @param path string Canonical path.
--- @param platform string Platform tag.
--- @return table entry
--- @return boolean available
local function declared(manifest, path, platform)
	local find = manifest.find_declared_entry_by_path or manifest.find_entry_by_path
	assert(type(find) == "function", "script authority needs declaration metadata")
	local entry = assert(find(path),
		"script authority row has no declaration: " .. tostring(path))
	for _, tag in ipairs(entry.platforms or {}) do
		if tag == platform then return entry, true end
	end
	return entry, false
end





-- =================================
-- =================================
-- ======= 2/ Start adoption =======
-- =================================
-- =================================

--- Writes every configured `[script]` row into its native alias at start.
--- @param options table { path, file_adapter, manifest, platform, aliases
---   (canonical path -> { alias }), storage ({ get, set }), logger, log }.
--- @return table|nil adopted Canonical path -> adopted value; nil when the
---   source could not be read (the native values stay in force).
--- @return string|nil detail Why nothing was adopted.
function M.adopt(options)
	assert(type(options) == "table" and type(options.aliases) == "table"
		and type(options.storage) == "table" and type(options.logger) == "table",
		"script authority needs its aliases, storage and logger")
	local Logger, LOG = options.logger, options.log or "script_config_authority"
	local document, _, detail = read_document(options.path, options.file_adapter)
	if document == nil then
		Logger.error(LOG, "config.toml [script] rows were not adopted at start: %s.", detail)
		return nil, detail
	end
	local adopted = {}
	for _, path in ipairs(TableUtil.sorted_keys(options.aliases, TableUtil.by_text)) do
		local value = source_value(document, path)
		local entry, available
		if value ~= nil then entry, available = declared(options.manifest, path, options.platform) end
		-- A case variant of a listed value is that value, as on Windows (CFS-001).
		if value ~= nil and available then value = Outdated.canonical_enum_value(entry, value) end
		if value ~= nil and available then
			local fits, reason = Outdated.manifest_value_fits(entry, value, options.platform, VALUE_RULES[path])
			if not fits then
				Outdated.report(assert(KeyPath.parse(path)), reason, Logger)
			else
				local alias = options.aliases[path].alias
				if options.storage.get(alias) ~= value and options.storage.set(alias, value) ~= true then
					Logger.error(LOG, "config.toml %s could not be written into its native setting.", path)
				else
					adopted[path] = value
					Logger.debug(LOG, "config.toml %s = %s wins at start.", path, tostring(value))
				end
			end
		end
	end
	return adopted, nil
end





-- =================================
-- =================================
-- ======= 3/ Change rewrite =======
-- =================================
-- =================================

--- Rewrites the config.toml row a native change replaces, when the file holds it.
--- Called before the native value is stored, so a refused write changes nothing.
--- @param options table { path, file_adapter, manifest, key (canonical path), value }.
--- @return boolean committed True when the file needs no change or was rewritten.
--- @return string|nil detail Why the change was refused.
function M.rewrite_owned(options)
	assert(type(options) == "table" and type(options.key) == "string", "script authority rewrite needs its key")
	local document, source, detail = read_document(options.path, options.file_adapter)
	if document == nil then return false, detail end
	local held = source_value(document, options.key)
	if held == nil or held == options.value then
		return true, nil, { path = options.path, file_adapter = options.file_adapter,
			before = source.content, after = source.content, status = source.status, noop = true }
	end
	local operation = options.manifest.sparse_operation(options.key, options.value)
	local committed, write_detail, content, cleanup, candidate = Writer.batch_write(options.path, { operation }, options.file_adapter, source)
	if committed ~= true then
		local receipt
		if type(cleanup) == "function" and type(candidate) == "string" and source.status == "ok" then
			receipt = { path = options.path, file_adapter = options.file_adapter, before = source.content,
				after = candidate, publication_cleanup = cleanup }
		end
		return false, "config.toml was not rewritten: " .. tostring(write_detail), receipt
	end
	if type(content) ~= "string" or source.status ~= "ok" then return false, "config.toml rewrite receipt is unavailable" end
	local receipt = { path = options.path, file_adapter = options.file_adapter, before = source.content, after = content }
	local observed, status = Writer.read_classified(options.path, options.file_adapter)
	if status ~= "ok" or observed ~= content then
		return false, "config.toml rewrite readback did not match", receipt
	end
	return true, nil, receipt
end

--- Restores only the exact bytes this rewrite published, never a later writer.
function M.restore_rewrite(receipt)
	if receipt == nil then return true end
	if type(receipt) == "table" and receipt.noop == true then return true end
	if type(receipt) ~= "table" or type(receipt.before) ~= "string" or type(receipt.after) ~= "string" then return false end
	if receipt.publication_cleanup ~= nil and Writer.retry_publication_cleanup(receipt) ~= true then return false end
	local current, status = Writer.read_classified(receipt.path, receipt.file_adapter)
	if status == "ok" and current == receipt.before then return true end
	if status ~= "ok" or current ~= receipt.after then return false end
	local _, _, cleanup = Writer.publish_if_unchanged(receipt.path, receipt.before, receipt.file_adapter,
		{ status = "ok", content = receipt.after })
	if type(cleanup) == "function" then receipt.publication_cleanup = cleanup; return false end
	local restored, restored_status = Writer.read_classified(receipt.path, receipt.file_adapter)
	return restored_status == "ok" and restored == receipt.before
end

function M.verify_rewrite(receipt)
	if receipt == nil then return true end
	if type(receipt) ~= "table" then return false end
	local observed, status = Writer.read_classified(receipt.path, receipt.file_adapter)
	if receipt.noop == true then
		return status == receipt.status and (status ~= "ok" or observed == receipt.after)
	end
	if type(receipt.after) ~= "string" then return false end
	return status == "ok" and observed == receipt.after
end

function M.rewrite(options)
	assert(type(options) == "table" and type(options.key) == "string", "script authority rewrite needs its key")
	local document, source, detail = read_document(options.path, options.file_adapter)
	if document == nil then return false, detail end
	local held = source_value(document, options.key)
	if held == nil or held == options.value then return true, nil end
	local operation = options.manifest.sparse_operation(options.key, options.value)
	local committed, write_detail = Writer.batch_write(options.path, { operation }, options.file_adapter, source)
	if committed ~= true then return false, "config.toml was not rewritten: " .. tostring(write_detail) end
	return true, nil
end

return M
