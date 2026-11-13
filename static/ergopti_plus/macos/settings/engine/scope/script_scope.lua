--- settings/engine/scope/script_scope.lua

--- Owns directly declared script rows under the existing ordinary-save fence.
local M = {}
local Manifest = require("menu.engine.manifest_reader")
local Runtime = require("settings.engine.scope.script_scope_runtime")
local Transaction = require("settings.engine.scope.transaction")
local Fenced = require("settings.engine.scope.fenced_transaction")
local ConfigKeys = require("settings.engine.keys")

--- Native settings alias of each directly declared script row.
local ALIAS_NAMES = {
	[ConfigKeys.KEY.SCRIPT_LOCALE] = "i18n_locale",
	[ConfigKeys.KEY.SCRIPT_LOG_LEVEL] = ConfigKeys.LEAF.LOG_LEVEL,
	[ConfigKeys.KEY.SCRIPT_SHOW_ERROR_DIALOG] = ConfigKeys.KEY.SCRIPT_SHOW_ERROR_DIALOG,
}

--- Native field owner module of each directly declared script row.
local NATIVE_OWNERS = {
	[ConfigKeys.KEY.SCRIPT_LOCALE] = "core.i18n.engine.i18n",
	[ConfigKeys.KEY.SCRIPT_LOG_LEVEL] = "core.logger.engine.logger",
	[ConfigKeys.KEY.SCRIPT_SHOW_ERROR_DIALOG] = "diagnostics.ui.error_dialog",
}

--- Binds actual legacy native aliases without copying canonical value policy.
--- @return table aliases Canonical path -> native alias/field owner.
local function aliases()
	local bound = {}
	for path, alias in pairs(ALIAS_NAMES) do bound[path] = { alias = alias, native = require(NATIVE_OWNERS[path]) } end
	return bound
end

--- Returns the native alias names alone, without loading their field owners,
--- for the start adoption that runs before those owners initialise.
--- @return table aliases Canonical path -> { alias }.
function M.alias_names()
	local names = {}
	for path, alias in pairs(ALIAS_NAMES) do names[path] = { alias = alias } end
	return names
end

--- Makes config.toml's [script] rows win over the saved values at start.
--- Runs once the config path is known and before any alias reader starts.
--- @return table|nil adopted Canonical path -> adopted value.
function M.adopt_configured()
	-- The log level is left to infra.config_overrides: it already writes the
	-- configured level into this same alias and admits every spelling of a
	-- logger threshold, and init re-applies the level after it.
	local adopted = M.alias_names()
	adopted[ConfigKeys.KEY.SCRIPT_LOG_LEVEL] = nil
	return require("settings.engine.scope.script_config_authority").adopt({
		path = require("settings.engine.paths").get("ConfigTomlPath"),
		file_adapter = require("core.fs.adapters.file_system"), manifest = Manifest, platform = "hs",
		aliases = adopted, storage = require("core.fs.adapters.storage"),
		logger = require("core.logger.engine.logger"), log = "script_scope" })
end

--- Rewrites the config.toml row a menu or wizard change replaces, when the
--- file holds it, so the next start keeps the change. Call before storing it.
--- @param path string Canonical script path.
--- @param value any New value.
--- @return boolean committed
function M.rewrite_configured(path, value)
	assert(ALIAS_NAMES[path] ~= nil, "not a native script row: " .. tostring(path))
	local committed, detail = require("settings.engine.scope.script_config_authority").rewrite({
		path = require("settings.engine.paths").get("ConfigTomlPath"),
		file_adapter = require("core.fs.adapters.file_system"), manifest = Manifest, key = path, value = value })
	if committed ~= true then
		require("core.logger.engine.logger").error("script_scope", "%s was not changed: %s.", path, tostring(detail))
	end
	return committed == true
end

--- Rewrites one configured row and retains its exact inverse for its caller.
function M.rewrite_configured_owned(path, value)
	assert(ALIAS_NAMES[path] ~= nil, "not a native script row: " .. tostring(path))
	return require("settings.engine.scope.script_config_authority").rewrite_owned({
		path = require("settings.engine.paths").get("ConfigTomlPath"),
		file_adapter = require("core.fs.adapters.file_system"), manifest = Manifest, key = path, value = value })
end

function M.restore_configured_rewrite(receipt)
	return require("settings.engine.scope.script_config_authority").restore_rewrite(receipt)
end

function M.verify_configured_rewrite(receipt)
	return require("settings.engine.scope.script_config_authority").verify_rewrite(receipt)
end

--- Returns detached alias descriptors bound to the existing native field owners.
--- Each call constructs fresh descriptor tables; native module identities remain
--- the exact live providers used by the ordinary participant, without policy copies.
--- @return table aliases Canonical path to native alias/field descriptor.
function M.native_aliases()
	return aliases()
end

--- Creates the direct native participant with existing checkpoint/source owners.
--- A pause does not refuse it: a pause stops typing, not configuration (EDD-1,
--- maintainer decision 2026-11-12).
--- @param options table Current menu persistence, backup and writer ports.
--- @return table owner Apply/revert/release/pending/retry_restore.
function M.new(options)
	assert(type(options) == "table"
		and type(options.storage_backup_path) == "function", "script scope requires current native menu owners")
	local transaction
	local token = { pending = function() return transaction ~= nil and transaction.pending() end }
	local runtime = Runtime.new({ manifest = Manifest, platform = "hs", aliases = options.aliases or aliases(),
		storage = options.storage or require("core.fs.adapters.storage"), token = token, files = options.files,
		storage_backup_path = options.storage_backup_path })
	local ports = {}
	for key, value in pairs(options) do ports[key] = value end
	ports.scope, ports.runtime = "global", runtime
	ports.transaction_factory = function(request)
		request.manifest = runtime.manifest
		transaction = Transaction.new(request)
		return transaction
	end
	local primary = require("settings.ui.menu.scoped_preferences").new(ports)
	local adapter = {
		apply = function(scope, mode)
			assert(scope == "global", "script owner cannot acquire included categories")
			return primary.apply(mode)
		end,
		revert = primary.revert, pending = primary.pending, retry_restore = primary.retry_restore,
		committed = function() return transaction ~= nil and transaction.committed() end,
		release = function()
			primary.release()
			assert(transaction == nil or transaction.committed() == false, "script primary inverse release refused")
		end,
	}
	local owner
	owner = Fenced.new({ owner = {}, native_token = token, transaction = adapter, scope = "global",
		fences = runtime.fences, available = function()
			return require("settings.engine.migration.migrate").read_only_reason(options.path) == nil
		end })
	local release = owner.release
	function owner.release()
		if release() ~= true then return false end
		return runtime.forget() == true
	end
	return owner
end

return M
