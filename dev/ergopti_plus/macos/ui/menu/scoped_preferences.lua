--- ui/menu/scoped_preferences.lua

--- ==============================================================================
--- MODULE: Scoped Preferences Transaction
--- DESCRIPTION:
--- Applies one complete preference scope under the existing global writer fence.
--- The file source and ordinary-save rollback snapshots advance provisionally
--- with native state, and retain exact inverses until publication commits.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")
local Scope = require("config_scope_transaction")
local Logger = require("infra.logger")
local LOG = "scoped_preferences"

--- Creates a scope owner with terminal native ports and ordinary-save compensation.
--- @param options table Scope, runtime, persistence and admission ports.
--- @return table owner Scope application and retained compensation operations.
function M.new(options)
	local preferences, state = options.preferences, options.state
	local checkpoint, runtime = options.checkpoint, options.runtime
	local demotions = options.demotions
	if options.demotion_feature then
		assert(type(demotions) == "table" and type(demotions.release_feature) == "function"
			and type(demotions.readopt) == "function", "scope needs the session demotion owner")
	end
	assert(type(checkpoint) == "table" and type(checkpoint.capture) == "function"
		and type(checkpoint.replace) == "function" and type(checkpoint.restore) == "function",
		"scope needs the ordinary-save checkpoint")
	for _, name in ipairs({ "capture", "apply", "restore" }) do
		assert(type(runtime[name]) == "function", "scope runtime port missing: " .. name)
	end
	for _, name in ipairs({ "admission", "paused", "backup_path", "capture_preferences" }) do
		assert(type(options[name]) == "function", "scope port missing: " .. name)
	end
	-- Retired with the clear's question on 2026-09-30: a caller still wiring
	-- one would expect it to be asked, so it is refused rather than ignored.
	assert(options.confirm == nil, "a scope asks no question: the confirm port is retired")
	local owner, transaction, active_snapshot = {}, nil, nil
	local editing_receipt
	-- What the writer fence retains while this owner owes an inverse. Only this
	-- claim may settle the debt, and settling it through the fence is what hands
	-- the fence back to every other writer: a retry outside it left the fence
	-- retained after the debt was paid, refusing a composed rollback's other
	-- reverts, every save and Quit/Reload until this owner happened to run again.
	local claim = {}
	function claim.pending() return transaction ~= nil and transaction.pending() end
	function claim.retry_restore()
		return transaction == nil or transaction.retry_restore() == true
	end
	function owner.pending() return claim.pending() end
	--- Settles a retained inverse under the writer fence, which releases the
	--- fence once nothing is owed; a debt that stays owed keeps it refused.
	--- @return boolean settled
	function owner.retry_restore()
		return options.admission("Preference scope retry: " .. options.scope, claim.retry_restore, claim) == true
	end
	--- Undoes the last commit under the global writer fence; the transaction
	--- restores the runtime, the staged source and checkpoint, then the file.
	--- @return boolean reverted
	function owner.revert()
		if transaction == nil then return false end
		return options.admission("Preference scope revert: " .. options.scope, function()
			if options.paused() ~= false then return false end
			local reverted, detail = transaction.revert()
			if reverted ~= true then
				Logger.warn(LOG, "Scope %s revert did not settle: %s.", options.scope, tostring(detail))
			end
			return reverted == true
		end, claim)
	end
	--- Forgets the last commit's inverse once its composition has committed.
	function owner.release()
		if transaction ~= nil then transaction.release() end
	end
	--- Applies one mode at once. Neither mode asks: the backup and the exact
	--- inverse already make a restore or a clear recoverable (the maintainer
	--- retired the clear's question on 2026-09-30).
	--- @param mode string "recommended" or "clear".
	--- @param select function|nil Narrows the scope to the rows whose path it
	---   returns true for (config_scope_transaction `select`).
	--- @return boolean committed
	local function perform(mode, select, edit_rows, receipt)
		local function validate_edit(rows, token)
			local called, accepted, reason = pcall(options.edit_fence.validate, rows, token)
			if called and accepted == true then return true end
			if receipt then
				local closed = { source_changed = true, collision = true, unavailable = true, save_failed = true }
				receipt.reason = called and closed[reason] and reason or "save_failed"
			end
			return false
		end
		if edit_rows == nil and mode ~= "clear" and mode ~= "recommended" then return false end
		if select ~= nil and type(select) ~= "function" then return false end
		return options.admission("Preference scope: " .. options.scope, function()
			if options.paused() ~= false then return false end
			if claim.pending() and claim.retry_restore() ~= true then return false end
			transaction = (options.transaction_factory or Scope.new)({
				manifest = Manifest, select = select, editing = edit_rows ~= nil,
				path = options.path, backup_path = options.backup_path(), files = options.files,
				capture = function(source, candidate, updates)
					local baseline = preferences.source_snapshot(options.path)
					assert(type(baseline) == "table" and baseline.status == source.status
						and (source.status == "absent" or baseline.content == source.content),
						"scope source differs from loaded preferences")
					local native = runtime.capture(updates, source)
					assert(type(native) == "table", "scope native snapshot unavailable")
					local snapshot = { source = baseline, candidate = { status = "ok", content = candidate },
						checkpoint = checkpoint.capture(), native = native }
					if edit_rows ~= nil then
						assert(type(options.edit_fence) == "table" and type(options.edit_fence.acquire) == "function"
							and type(options.edit_fence.release) == "function", "scope edit requires an exact delivery fence")
						local token = {}
						assert(options.edit_fence.acquire(token) == true, "scope edit delivery fence refused")
						snapshot.edit_claim, snapshot.physical_edit = token, true
					end
					active_snapshot = snapshot
					return snapshot
				end,
				apply = function(decoded, updates)
					if runtime.apply(decoded, updates) ~= true then return false end
					local saved = active_snapshot
					if saved.physical_edit and type(options.edit_fence.validate) == "function"
						and validate_edit(updates, saved.edit_claim) ~= true then return false end
					saved.edit_updates = saved.physical_edit and updates or nil
					if options.demotion_feature then
						local keys = options.demotion_keys and options.demotion_keys(updates) or nil
						saved.demotions = demotions.release_feature(options.demotion_feature, keys)
					end
					if preferences.replace_source(options.path, saved.source, saved.candidate) ~= true then return false end
					saved.source_staged = true
					local accepted, candidate_checkpoint = checkpoint.replace(saved.checkpoint, state, options.capture_preferences())
					if accepted ~= true then return false end
					saved.staged_checkpoint = candidate_checkpoint
					return true
				end,
				before_restore = function(snapshot)
					if not snapshot.physical_edit or snapshot.edit_claim ~= nil then return true end
					local token = {}
					if options.edit_fence.acquire(token) ~= true then return false end
					snapshot.edit_claim = token
					return true
				end,
				after_publish = function(snapshot)
					if snapshot.edit_claim == nil then return true end
					local expected = snapshot.candidate
					local content, status = options.files.read_with_status(options.path)
					local source = preferences.source_snapshot(options.path)
					if status ~= expected.status or content ~= expected.content or type(source) ~= "table"
						or source.status ~= expected.status or source.content ~= expected.content then return false end
					if type(options.edit_fence.validate) == "function"
						and validate_edit(snapshot.edit_updates, snapshot.edit_claim) ~= true then return false end
					if options.edit_fence.release(snapshot.edit_claim) ~= true then return false end
					snapshot.edit_claim = nil
					return true
				end,
				after_restore = function(snapshot)
					if snapshot.edit_claim == nil then return true end
					if options.edit_fence.release(snapshot.edit_claim) ~= true then return false end
					snapshot.edit_claim = nil
					return true
				end,
				restore = function(snapshot)
					if runtime.restore(snapshot.native) ~= true then return false end
					if snapshot.demotions then
						if demotions.readopt(snapshot.demotions) ~= true then return false end
						snapshot.demotions = nil
					end
					if snapshot.source_staged then
						if preferences.replace_source(options.path, snapshot.candidate, snapshot.source) ~= true then return false end
						snapshot.source_staged = false
					end
					if snapshot.staged_checkpoint then
						-- restore, not replace: a later owner of this checkpoint, reverted
						-- first, advanced the revision this staged capture holds.
						if checkpoint.restore(snapshot.staged_checkpoint, snapshot.checkpoint) ~= true then return false end
						snapshot.staged_checkpoint = nil
					end
					return true
				end,
			})
			local committed, detail
			if edit_rows ~= nil then
				if type(transaction.apply_updates) ~= "function" then return false end
				committed, detail = transaction.apply_updates(options.scope, edit_rows)
			else committed, detail = transaction.apply(options.scope, mode) end
			if committed ~= true then
				if receipt then Logger.warn(LOG, "Physical shortcut scope did not commit (%s).", receipt.reason or "save_failed")
				else Logger.warn(LOG, "Scope %s did not commit: %s.", options.scope, tostring(detail)) end
			end
			return committed, detail
		end, claim)
	end
	function owner.apply(mode, select) return perform(mode, select) end
	--- Edits the same scope under its existing source and ordinary-save fence.
	function owner.edit(rows)
		if type(rows) ~= "table" then return false, "save_failed" end
		if editing_receipt ~= nil then return false, "unavailable" end
		local receipt = {}
		editing_receipt = receipt
		local called, committed = pcall(perform, "edit", nil, rows, receipt)
		if editing_receipt == receipt then editing_receipt = nil end
		if called and committed == true then return true end
		return false, receipt.reason or "save_failed"
	end
	return owner
end

return M
