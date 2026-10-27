--- infra/keyboard_layout_scope.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Scope Transaction (Linux)
--- DESCRIPTION:
--- Restores or clears the layout rows of config.toml (the number-row ordering
--- and its edge-key switch) through the shared scope transaction, so a global
--- restore covers the layout category here as it does on the other drivers.
---
--- CONFIG ONLY ON LINUX: no runtime reader yet. The keyboard hook takes its
--- number-row mode when it starts and the daemon passes none (the hook keeps
--- "native"), and nothing reads the edge-key switch. This owner therefore keeps
--- the file honest and has no live state to change, capture or put back; its
--- native snapshot is an empty, opaque receipt. The macOS owner applies the same
--- rows to a live menu state instead (menu_keyboard_layout.lua).
---
--- FEATURES & RATIONALE:
--- 1. Same transaction as every other scope: verified backup, conditional
---    publication, an exact inverse kept while a later category may still
---    refuse, and retained debt when a restore is refused.
--- 2. Exact ownership: only the manifest's keyboard_layout rows change; unknown
---    sections and fields of config.toml survive.
--- 3. Honest absence: the day the daemon reads these rows at hook start, the
---    capture and restore here are the place to add the hook's acknowledgement.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")
local Transaction = require("config_scope_transaction")
local Logger = require("logger.shim")
local LOG = "infra.keyboard_layout_scope"
local SCOPE = "keyboard_layout"
local _owner, _sequence = nil, 0
require("infra.scope_registry").register("keyboard_layout_scope", function() return _owner ~= nil and _owner.pending() == true end)

--- Builds one recoverable transaction over config.toml's layout rows.
--- @param options table path, backup_path and an optional files port.
--- @return table owner apply(mode), revert(), release(), pending(), retry_restore().
function M.new(options)
	assert(type(options) == "table", "keyboard layout scope requires its options")
	local transaction = Transaction.new({
		path = options.path, backup_path = options.backup_path,
		files = options.files or require("adapters.file_system"), manifest = Manifest,
		-- No live owner: the receipt is empty but present, so the transaction
		-- records that the capture happened.
		capture = function() return {} end,
		apply = function() return true end,
		restore = function() return true end,
	})
	local owner = {}
	for _, name in ipairs({ "revert", "release", "pending", "retry_restore" }) do owner[name] = transaction[name] end
	--- @param mode string "recommended" or "clear".
	function owner.apply(mode) return transaction.apply(SCOPE, mode) end
	return owner
end

--- Executes a menu request, retaining any failed inverse for the next retry.
--- @param mode string "recommended" or "clear".
--- @param is_paused function Live pause getter.
--- @return boolean committed
--- @return string|nil detail
function M.apply(mode, is_paused)
	if mode ~= "recommended" and mode ~= "clear" then return false, "invalid keyboard layout scope mode" end
	if type(is_paused) ~= "function" or is_paused() then return false, "keyboard layout configuration is paused" end
	if _owner and _owner.pending() and _owner.retry_restore() ~= true then
		return false, "keyboard layout rollback is pending"
	end
	_sequence = _sequence + 1
	local path = require("infra.config_paths").config("config.toml")
	_owner = M.new({ path = path,
		backup_path = path .. ".layout-" .. os.date("%Y%m%d-%H%M%S") .. "-" .. _sequence .. ".bak" })
	Logger.info(LOG, "Keyboard layout scope '%s' started (config only: no runtime reader yet).", mode)
	local committed, detail = _owner.apply(mode)
	if committed then Logger.info(LOG, "Keyboard layout scope '%s' completed.", mode)
	else Logger.error(LOG, "Keyboard layout scope '%s' refused: %s.", mode, tostring(detail)) end
	return committed, detail
end

--- The layout participant of a composed scope, bound to the retained owner.
--- @param is_paused function Live pause getter.
--- @return table participant See config_scope_composition.
function M.participant(is_paused)
	return require("config_scope_participant").synchronous({
		apply = function(mode) return M.apply(mode, is_paused) end,
		owner = function() return _owner end,
	})
end

--- Test seam: forgets the retained owner and its debt.
function M._reset_for_test()
	_owner, _sequence = nil, 0
end

return M
