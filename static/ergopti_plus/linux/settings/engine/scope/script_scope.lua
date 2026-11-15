--- settings/engine/scope/script_scope.lua

--- Registers the global declaration's own script rows through native owners.
local M = {}
local Manifest = require("infra.manifest_reader")
local Runtime = require("settings.engine.scope.script_scope_runtime")
local Transaction = require("settings.engine.scope.transaction")
local Fenced = require("settings.engine.scope.fenced_transaction")
local Logger = require("core.logger.engine.shim")
local ConfigKeys = require("settings.engine.keys")
local _owner, _edit_owners, _sequence = nil, {}, 0
require("settings.engine.scope.registry").register("script_scope", function()
	if _owner ~= nil and _owner.pending() == true then return true end
	for _, owner in pairs(_edit_owners) do if owner.pending() == true then return true end end
	return false
end)

--- Native storage alias of each directly declared script row.
local ALIAS_NAMES = {
	[ConfigKeys.KEY.SCRIPT_LOCALE] = "locale",
	[ConfigKeys.KEY.SCRIPT_LOG_LEVEL] = ConfigKeys.KEY.SCRIPT_LOG_LEVEL,
	[ConfigKeys.KEY.SCRIPT_SHOW_ERROR_DIALOG] = ConfigKeys.KEY.SCRIPT_SHOW_ERROR_DIALOG,
}

--- Native field owner module of each directly declared script row.
local NATIVE_OWNERS = {
	[ConfigKeys.KEY.SCRIPT_LOCALE] = "core.i18n.engine.i18n",
	[ConfigKeys.KEY.SCRIPT_LOG_LEVEL] = "settings.engine.scope.script_settings",
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
	return require("settings.engine.scope.script_config_authority").adopt({
		path = require("settings.engine.paths").config("config.toml"), manifest = Manifest, platform = "linux",
		aliases = M.alias_names(), storage = require("core.fs.adapters.storage"), logger = Logger, log = "settings.engine.scope.script_scope" })
end

--- Rewrites the config.toml row a menu or wizard change replaces, when the
--- file holds it, so the next start keeps the change. Call before storing it.
--- @param path string Canonical script path.
--- @param value any New value.
--- @return boolean committed
function M.rewrite_configured(path, value)
	assert(ALIAS_NAMES[path] ~= nil, "not a native script row: " .. tostring(path))
	local committed, detail = require("settings.engine.scope.script_config_authority").rewrite({
		path = require("settings.engine.paths").config("config.toml"), manifest = Manifest, key = path, value = value })
	if committed ~= true then Logger.error("settings.engine.scope.script_scope", "%s was not changed: %s.", path, tostring(detail)) end
	return committed == true
end

function M.rewrite_configured_owned(path, value)
	assert(ALIAS_NAMES[path] ~= nil, "not a native script row: " .. tostring(path))
	return require("settings.engine.scope.script_config_authority").rewrite_owned({
		path = require("settings.engine.paths").config("config.toml"), manifest = Manifest, key = path, value = value })
end

function M.restore_configured_rewrite(receipt)
	return require("settings.engine.scope.script_config_authority").restore_rewrite(receipt)
end

function M.verify_configured_rewrite(receipt)
	return require("settings.engine.scope.script_config_authority").verify_rewrite(receipt)
end

--- Creates the direct participant's existing file transaction and native fences.
--- A pause does not refuse it: a pause stops typing, not configuration (EDD-1,
--- maintainer decision 2026-11-12).
--- @param options table Path, backup path, storage backup path and files.
--- @return table owner Apply/revert/release/pending/retry_restore.
function M.new(options)
	assert(type(options) == "table", "script scope requires its options")
	local transaction
	local token = { pending = function() return transaction ~= nil and transaction.pending() end, edit_key = options.edit_key }
	local runtime = Runtime.new({ manifest = Manifest, platform = "linux", aliases = options.aliases or aliases(),
		storage = options.storage or require("core.fs.adapters.storage"), token = token, files = options.files,
		only = options.only, allow_invalid_source = options.allow_invalid_source, storage_backup_path = function() return options.storage_backup_path end })
	transaction = Transaction.new({ path = options.path, backup_path = options.backup_path, files = options.files,
		manifest = runtime.manifest,
		prepare_batch = options.prepare_batch, preserve_unchanged = options.preserve_unchanged,
		validate_update = options.validate_update, allow_boolean = options.allow_boolean,
		capture = function(source, _, updates) return runtime.capture(updates, source) end,
		apply = runtime.apply, restore = runtime.restore })
	local owner
	owner = Fenced.new({ owner = {}, native_token = token, transaction = transaction, scope = "global",
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

--- Settles an earlier native inverse before admitting another edit.
--- @param key string Canonical script row.
--- @return boolean settled
function M.retry_edit(key)
	local owner = _edit_owners[key]
	return not owner or not owner.pending() or owner.retry_restore() == true
end

function M.retry_locale() return M.retry_edit(ConfigKeys.KEY.SCRIPT_LOCALE) end

--- Atomically changes one native alias and any already configured source row.
--- @param key string Canonical script row.
--- @param value any Native value admitted by the field owner.
--- @return boolean committed
function M.edit_setting(key, value)
	local alias, native_name = ALIAS_NAMES[key], NATIVE_OWNERS[key]
	if not alias or not native_name or not M.retry_edit(key) then return false end
	local previous = _edit_owners[key]
	if previous and previous.release() ~= true then return false end
	_sequence = _sequence + 1
	local path = require("settings.engine.paths").config("config.toml")
	local timestamp = os.date("%Y%m%d-%H%M%S") .. "-" .. _sequence
	local backup = path .. ".edit-" .. timestamp .. ".bak"
	local storage_backup = require("settings.engine.paths").default_config_dir() .. "/storage.edit-" .. timestamp .. ".bak"
	local field = assert(key:match("^script%.([%w_]+)$"))
	local function prepare(target, updates, files)
		local Writer, Codec = require("core.text.engine.toml_codec.writer"), require("core.text.engine.toml_codec")
		local content, status, detail = Writer.read_classified(target, files)
		if status ~= "ok" and status ~= "absent" then return false, detail end
		local source = { status = status, content = status == "ok" and content or nil }
		local decoded = Codec.decode(content or "")
		if type(decoded) ~= "table" then return false, "config.toml is not valid TOML" end
		local script = decoded.script
		if script ~= nil and type(script) ~= "table" then return false, "script configuration is not a table" end
		return Writer.prepare_batch(target, script and script[field] ~= nil and updates or {}, files, source)
	end
	local owner = M.new({ path = path, backup_path = backup,
		storage_backup_path = storage_backup,
		files = require("core.fs.adapters.file_system"), allow_invalid_source = true, edit_key = key, allow_boolean = key == ConfigKeys.KEY.SCRIPT_SHOW_ERROR_DIALOG,
		aliases = { [key] = { alias = alias, native = require(native_name) } }, only = { [key] = true },
		prepare_batch = prepare, preserve_unchanged = true,
		validate_update = function(scope, row)
			return scope == "global" and row.section == "script" and row.key == field
		end })
	_edit_owners[key] = owner
	local committed = owner.apply_updates({ { section = "script", key = field, value = value } })
	if committed ~= true then return false end
	if owner.release() ~= true then return false end
	-- A released edit has nothing left to roll back: its two copies, named for
	-- this edit alone, go. Windows and macOS keep no copy per edit (CFL-002).
	for _, copy in ipairs({ backup, storage_backup }) do
		local removed, detail = os.remove(copy)
		local remaining = not removed and io.open(copy, "rb") or nil
		if remaining then
			remaining:close()
			Logger.warn("settings.engine.scope.script_scope", "An edit's rollback copy could not be removed (%s): %s.", copy, tostring(detail))
		end
	end
	return true
end

function M.edit_locale(value) return M.edit_setting(ConfigKeys.KEY.SCRIPT_LOCALE, value) end

--- Applies requested script rows, retaining its exact native/file inverse.
--- @param mode string Recommended or clear.
--- @return boolean committed
--- @return string|nil detail
function M.apply(mode)
	if _owner and _owner.pending() and _owner.retry_restore() ~= true then return false, "script rollback remains pending" end
	_sequence = _sequence + 1
	local path = require("settings.engine.paths").config("config.toml")
	local backup = path .. ".script-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. _sequence .. ".bak"
	_owner = M.new({ path = path, backup_path = backup, storage_backup_path = backup .. ".settings",
		files = require("core.fs.adapters.file_system") })
	local committed, detail = _owner.apply(mode)
	if committed ~= true then Logger.warn("settings.engine.scope.script_scope", "Script scope refused: %s.", tostring(detail)) end
	return committed, detail
end

--- Retains the exact participant cohort through the shared composition.
--- @return table participant Shared synchronous participant.
function M.participant()
	return require("settings.engine.scope.participant").synchronous({
		apply = function(mode) return M.apply(mode) end,
		owner = function() return _owner end,
	})
end

return M
