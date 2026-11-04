--- infra/script_scope.lua

--- Registers the global declaration's own script rows through native owners.
local M = {}
local Manifest = require("infra.manifest_reader")
local Runtime = require("script_scope_runtime")
local Transaction = require("config_scope_transaction")
local Fenced = require("config_scope_fenced_transaction")
local Logger = require("logger.shim")
local ConfigKeys = require("config_keys")
local _owner, _sequence = nil, 0
require("infra.scope_registry").register("script_scope", function() return _owner ~= nil and _owner.pending() == true end)

--- Native storage alias of each directly declared script row.
local ALIAS_NAMES = {
	[ConfigKeys.KEY.SCRIPT_LOCALE] = "locale",
	[ConfigKeys.KEY.SCRIPT_LOG_LEVEL] = ConfigKeys.KEY.SCRIPT_LOG_LEVEL,
	[ConfigKeys.KEY.SCRIPT_SHOW_ERROR_DIALOG] = ConfigKeys.KEY.SCRIPT_SHOW_ERROR_DIALOG,
}

--- Native field owner module of each directly declared script row.
local NATIVE_OWNERS = {
	[ConfigKeys.KEY.SCRIPT_LOCALE] = "infra.i18n",
	[ConfigKeys.KEY.SCRIPT_LOG_LEVEL] = "infra.script_settings",
	[ConfigKeys.KEY.SCRIPT_SHOW_ERROR_DIALOG] = "ui.error_dialog.bridge",
}

--- Binds the actual native aliases; policy and available rows come from metadata.
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
--- Runs before the error window, the log level and i18n read their alias.
--- @return table|nil adopted Canonical path -> adopted value.
function M.adopt_configured()
	return require("script_config_authority").adopt({
		path = require("infra.config_paths").config("config.toml"), manifest = Manifest, platform = "linux",
		aliases = M.alias_names(), storage = require("adapters.storage"), logger = Logger, log = "infra.script_scope" })
end

--- Rewrites the config.toml row a menu or wizard change replaces, when the
--- file holds it, so the next start keeps the change. Call before storing it.
--- @param path string Canonical script path.
--- @param value any New value.
--- @return boolean committed
function M.rewrite_configured(path, value)
	assert(ALIAS_NAMES[path] ~= nil, "not a native script row: " .. tostring(path))
	local committed, detail = require("script_config_authority").rewrite({
		path = require("infra.config_paths").config("config.toml"), manifest = Manifest, key = path, value = value })
	if committed ~= true then Logger.error("infra.script_scope", "%s was not changed: %s.", path, tostring(detail)) end
	return committed == true
end

function M.rewrite_configured_owned(path, value)
	assert(ALIAS_NAMES[path] ~= nil, "not a native script row: " .. tostring(path))
	return require("script_config_authority").rewrite_owned({
		path = require("infra.config_paths").config("config.toml"), manifest = Manifest, key = path, value = value })
end

function M.restore_configured_rewrite(receipt)
	return require("script_config_authority").restore_rewrite(receipt)
end

function M.verify_configured_rewrite(receipt)
	return require("script_config_authority").verify_rewrite(receipt)
end

--- Creates the direct participant's existing file transaction and native fences.
--- @param options table Path, backup path, storage backup path, files and pause getter.
--- @return table owner Apply/revert/release/pending/retry_restore.
function M.new(options)
	assert(type(options) == "table" and type(options.is_paused) == "function", "script scope requires its pause owner")
	local transaction
	local token = { pending = function() return transaction ~= nil and transaction.pending() end }
	local runtime = Runtime.new({ manifest = Manifest, platform = "linux", aliases = options.aliases or aliases(),
		storage = options.storage or require("adapters.storage"), token = token, files = options.files,
		storage_backup_path = function() return options.storage_backup_path end })
	transaction = Transaction.new({ path = options.path, backup_path = options.backup_path, files = options.files,
		manifest = runtime.manifest,
		capture = function(source, _, updates) return runtime.capture(updates, source) end,
		apply = runtime.apply, restore = runtime.restore })
	local owner
	owner = Fenced.new({ owner = {}, native_token = token, transaction = transaction, scope = "global",
		fences = runtime.fences, available = function()
			return options.is_paused() == false and require("config_migrate").read_only_reason(options.path) == nil
		end })
	local release = owner.release
	function owner.release()
		if release() ~= true then return false end
		return runtime.forget() == true
	end
	return owner
end

--- Applies requested script rows, retaining its exact native/file inverse.
--- @param mode string Recommended or clear.
--- @param is_paused function Live pause getter.
--- @return boolean committed
--- @return string|nil detail
function M.apply(mode, is_paused)
	if type(is_paused) ~= "function" or is_paused() ~= false then return false, "script configuration is paused" end
	if _owner and _owner.pending() and _owner.retry_restore() ~= true then return false, "script rollback remains pending" end
	_sequence = _sequence + 1
	local path = require("infra.config_paths").config("config.toml")
	local backup = path .. ".script-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. _sequence .. ".bak"
	_owner = M.new({ path = path, backup_path = backup, storage_backup_path = backup .. ".settings",
		files = require("adapters.file_system"), is_paused = is_paused })
	local committed, detail = _owner.apply(mode)
	if committed ~= true then Logger.warn("infra.script_scope", "Script scope refused: %s.", tostring(detail)) end
	return committed, detail
end

--- Retains the exact participant cohort through the shared composition.
--- @param is_paused function Live pause getter.
--- @return table participant Shared synchronous participant.
function M.participant(is_paused)
	return require("config_scope_participant").synchronous({
		apply = function(mode) return M.apply(mode, is_paused) end,
		owner = function() return _owner end,
	})
end

return M
