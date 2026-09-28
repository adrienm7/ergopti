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
--- @param options table Scope, runtime, persistence, admission and confirmation ports.
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
		and type(checkpoint.replace) == "function", "scope needs the ordinary-save checkpoint")
	for _, name in ipairs({ "capture", "apply", "restore" }) do
		assert(type(runtime[name]) == "function", "scope runtime port missing: " .. name)
	end
	for _, name in ipairs({ "admission", "confirm", "paused", "backup_path", "capture_preferences" }) do
		assert(type(options[name]) == "function", "scope port missing: " .. name)
	end
	local owner, transaction, active_snapshot = {}, nil, nil
	function owner.pending() return transaction ~= nil and transaction.pending() end
	function owner.retry_restore()
		return transaction == nil or transaction.retry_restore() == true
	end
	function owner.apply(mode)
		if mode ~= "clear" and mode ~= "recommended" then return false end
		return options.admission("Preference scope: " .. options.scope, function()
			if options.paused() ~= false then return false end
			if owner.pending() and owner.retry_restore() ~= true then return false end
			if options.confirm(mode) ~= true then return false end
			-- The modal runs a native event loop; pause may acquire the engine while
			-- confirmation is open, so its admission must be checked again.
			if options.paused() ~= false then return false end
			transaction = (options.transaction_factory or Scope.new)({
				manifest = Manifest,
				path = options.path, backup_path = options.backup_path(), files = options.files,
				capture = function(source, candidate, updates)
					local baseline = preferences.source_snapshot(options.path)
					assert(type(baseline) == "table" and baseline.status == source.status
						and (source.status == "absent" or baseline.content == source.content),
						"scope source differs from loaded preferences")
					local native = runtime.capture(updates)
					assert(type(native) == "table", "scope native snapshot unavailable")
					local snapshot = { source = baseline, candidate = { status = "ok", content = candidate },
						checkpoint = checkpoint.capture(), native = native }
					active_snapshot = snapshot
					return snapshot
				end,
				apply = function(decoded, updates)
					if runtime.apply(decoded, updates) ~= true then return false end
					local saved = active_snapshot
					if options.demotion_feature then saved.demotions = demotions.release_feature(options.demotion_feature) end
					if preferences.replace_source(options.path, saved.source, saved.candidate) ~= true then return false end
					saved.source_staged = true
					local accepted, candidate_checkpoint = checkpoint.replace(saved.checkpoint, state, options.capture_preferences())
					if accepted ~= true then return false end
					saved.staged_checkpoint = candidate_checkpoint
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
						if checkpoint.replace(snapshot.staged_checkpoint, snapshot.checkpoint.state,
							snapshot.checkpoint.preferences) ~= true then return false end
						snapshot.staged_checkpoint = nil
					end
					return true
				end,
			})
			local committed, detail = transaction.apply(options.scope, mode)
			if committed ~= true then Logger.warn(LOG, "Scope %s did not commit: %s.", options.scope, tostring(detail)) end
			return committed, detail
		end, owner)
	end
	return owner
end

return M
