--- infra/keyboard_layout_scope.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Scope Transaction (Linux)
--- DESCRIPTION:
--- Restores or clears the layout rows of config.toml (the number-row ordering
--- and its edge-key switch) through the shared scope transaction, so a global
--- restore covers the layout category here as it does on the other drivers.
---
--- The file is the transaction; the effect is the keyboard layout. Where the session
--- loads a layout live (X11) and a layout of ours exists, the participant applies the
--- restored rows through the layout manager (modules/keymap/number_row_live) and
--- acknowledges only once the running layout holds them; if it does not, the file is put
--- back. Elsewhere there is nothing to apply and the request stays config only, as
--- before. The macOS owner applies the same rows to a live menu state instead
--- (menu_keyboard_layout.lua).
---
--- FEATURES & RATIONALE:
--- 1. Same transaction as every other scope: verified backup, conditional
---    publication, an exact inverse kept while a later category may still
---    refuse, and retained debt when a restore is refused.
--- 2. Exact ownership: only the manifest's keyboard_layout rows change; unknown
---    sections and fields of config.toml survive.
--- 3. Acknowledgement after the effect: a request that is applied live settles when
---    the layout manager reports the layout loaded, not when the file is written.
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
		-- The transaction owns the file only; the live effect is the participant's
		-- (M.participant), so the receipt is empty but present.
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
	Logger.info(LOG, "Keyboard layout scope '%s' started.", mode)
	local committed, detail = _owner.apply(mode)
	if committed then Logger.info(LOG, "Keyboard layout scope '%s' completed.", mode)
	else Logger.error(LOG, "Keyboard layout scope '%s' refused: %s.", mode, tostring(detail)) end
	return committed, detail
end

--- The layout participant of a composed scope, bound to the retained owner.
--- @param is_paused function Live pause getter.
--- @param live table|nil { available() -> boolean, apply_stored(on_done) } the layout
---   application; modules.keymap.number_row_live when omitted.
--- @return table participant See config_scope_composition.
function M.participant(is_paused, live)
	local base = require("config_scope_participant").synchronous({
		apply = function(mode) return M.apply(mode, is_paused) end,
		owner = function() return _owner end,
	})
	live = live or require("modules.keymap.number_row_live")
	-- True while a live application is outstanding: the scope is not settled then.
	local applying = false

	--- Applies the file's rows to the running layout; on_done(applied, code).
	local function apply_live(on_done)
		applying = true
		local called, started = pcall(live.apply_stored, function(applied, code, _, live_code)
			applying = false
			on_done(applied == true, applied == true and nil or (tostring(code) .. (live_code and ("/" .. live_code) or "")))
		end)
		if not called or started ~= true then
			applying = false
			on_done(false, called and "layout application did not start" or tostring(started))
		end
	end

	local participant = {}
	participant.release = base.release
	function participant.pending() return applying or base.pending() end
	function participant.apply(mode, done)
		base.apply(mode, function(committed, detail)
			if not committed then return done(false, detail) end
			if live.available() ~= true then return done(true) end
			apply_live(function(applied, code)
				if applied then return done(true) end
				Logger.error(LOG, "The restored layout rows were not applied (%s); putting the file back.", tostring(code))
				base.revert(function(reverted, why)
					done(false, "the keyboard layout did not follow the restored rows (" .. tostring(code) .. ")"
						.. (reverted and "" or "; rollback pending: " .. tostring(why)))
				end)
			end)
		end)
	end
	function participant.revert(done)
		base.revert(function(reverted, detail)
			if reverted ~= true or live.available() ~= true then return done(reverted == true, detail) end
			apply_live(function(applied, code)
				done(applied, applied and nil or ("the keyboard layout did not follow the reverted rows (" .. tostring(code) .. ")"))
			end)
		end)
	end
	function participant.retry_restore(done)
		base.retry_restore(function(restored, detail)
			-- Nothing owed (restored without a cohort) leaves the layout as it is.
			if restored ~= true or live.available() ~= true then return done(restored == true, detail) end
			apply_live(function(applied, code)
				done(applied, applied and nil or ("the keyboard layout did not follow the restored rows (" .. tostring(code) .. ")"))
			end)
		end)
	end
	return participant
end

--- Test seam: forgets the retained owner and its debt.
function M._reset_for_test()
	_owner, _sequence = nil, 0
end

return M
