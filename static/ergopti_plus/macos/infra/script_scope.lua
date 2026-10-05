--- infra/script_scope.lua

--- Owns directly declared script rows under the existing ordinary-save fence.
local M = {}
local Manifest = require("infra.manifest_reader")
local Runtime = require("script_scope_runtime")
local Transaction = require("config_scope_transaction")
local Fenced = require("config_scope_fenced_transaction")

--- Binds actual legacy native aliases without copying canonical value policy.
--- @return table aliases Canonical path -> native alias/field owner.
local function aliases()
	return {
		["script.locale"] = { alias = "i18n_locale", native = require("infra.i18n") },
		["script.log_level"] = { alias = "log_level", native = require("infra.logger") },
		["script.show_error_dialog"] = { alias = "script.show_error_dialog", native = require("ui.error_dialog") },
	}
end

--- Creates the direct native participant with existing checkpoint/source owners.
--- @param options table Current menu persistence, pause, backup and writer ports.
--- @return table owner Apply/revert/release/pending/retry_restore.
function M.new(options)
	assert(type(options) == "table" and type(options.paused) == "function"
		and type(options.storage_backup_path) == "function", "script scope requires current native menu owners")
	local transaction
	local token = { pending = function() return transaction ~= nil and transaction.pending() end }
	local runtime = Runtime.new({ manifest = Manifest, platform = "hs", aliases = options.aliases or aliases(),
		storage = options.storage or require("adapters.storage"), token = token, files = options.files,
		storage_backup_path = options.storage_backup_path })
	local ports = {}
	for key, value in pairs(options) do ports[key] = value end
	ports.scope, ports.runtime = "global", runtime
	ports.transaction_factory = function(request)
		request.manifest = runtime.manifest
		transaction = Transaction.new(request)
		return transaction
	end
	local primary = require("ui.menu.scoped_preferences").new(ports)
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
			return options.paused() == false and require("config_migrate").read_only_reason(options.path) == nil
		end })
	local release = owner.release
	function owner.release()
		if release() ~= true then return false end
		return runtime.forget() == true
	end
	return owner
end

return M
