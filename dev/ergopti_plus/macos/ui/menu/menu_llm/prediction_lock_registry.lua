--- ui/menu/menu_llm/prediction_lock_registry.lua

--- Shared exact-owner registry for temporary MLX prediction locks. Startup and
--- ordinary model switches may overlap; the runtime gate is restored only after
--- the last lease settles, never when the first async operation happens to finish.

local Logger = require("infra.logger")

local M = {}
local LOG = "menu_llm.prediction_locks"

--- @param ctx table Context with `state` and `keymap`.
--- @return table registry
function M.new(ctx)
	ctx = type(ctx) == "table" and ctx or {}
	local state = type(ctx.state) == "table" and ctx.state or {}
	local keymap = type(ctx.keymap) == "table" and ctx.keymap or {}
	local leases = {}
	local lease_count = 0
	local restore_when_empty = false

	local function read_runtime()
		if type(keymap.get_llm_enabled) ~= "function" then
			return state.llm_enabled == true
		end
		local ok, enabled = Logger.callback(LOG,
			"Prediction-lock runtime snapshot", keymap.get_llm_enabled)
		if ok ~= true or type(enabled) ~= "boolean" then return nil end
		return enabled
	end

	local function set_runtime(enabled, label)
		if type(keymap.set_llm_enabled) ~= "function" then return false end
		local ok, result = Logger.callback(LOG, label, keymap.set_llm_enabled, enabled)
		return ok == true and result == true
	end

	local inst = {}

	--- Acquires or reasserts one exact lease. Re-acquiring the same id deliberately
	--- replays set(false), preserving the observable A→B model-switch contract.
	--- @param id any Stable owner token.
	--- @return boolean committed
	function inst.acquire(id)
		if id == nil then return false end
		if leases[id] == true then
			return set_runtime(false, "Prediction-lock reassertion")
		end

		local runtime_enabled = read_runtime()
		if runtime_enabled == nil then return false end
		if lease_count == 0 then restore_when_empty = runtime_enabled == true end
		leases[id] = true
		lease_count = lease_count + 1
		if runtime_enabled ~= true then return true end
		return set_runtime(false, "Prediction-lock acquisition")
	end

	--- Ensures a retained or rollback-recreated lease still holds the live gate.
	--- @param id any Stable owner token.
	--- @return boolean committed
	function inst.ensure_locked(id)
		if id == nil then return false end
		if leases[id] ~= true then return inst.acquire(id) end
		local runtime_enabled = read_runtime()
		if runtime_enabled == nil then return false end
		if runtime_enabled ~= true then return true end
		return set_runtime(false, "Prediction-lock rollback")
	end

	--- Applies a persisted preference without allowing it to bypass a live lease.
	--- The caller owns the preference-table mutation; this method settles only the
	--- effective prediction gate. An enabled preference remains parked while work
	--- is protected, then is restored by the final release.
	--- @param enabled boolean Desired persisted preference.
	--- @return boolean settled
	function inst.apply_preference(enabled)
		if type(enabled) ~= "boolean" then return false end
		if lease_count > 0 then
			return set_runtime(false, "Prediction-lock preference settlement")
		end
		return set_runtime(enabled, "Prediction preference settlement")
	end

	--- Releases one lease. Only the last exact owner may settle the runtime gate.
	--- @param id any Stable owner token.
	--- @return boolean settled
	function inst.release(id)
		if id == nil or leases[id] ~= true then return true end
		if lease_count > 1 then
			-- A preference writer may have attempted to enable the gate while
			-- operations overlap. Prove the remaining owners are still protected
			-- before consuming this lease.
			local runtime_enabled = read_runtime()
			if runtime_enabled == nil then return false end
			if runtime_enabled == true
				and set_runtime(false, "Prediction-lock non-final settlement") ~= true then
				return false
			end
			leases[id] = nil
			lease_count = lease_count - 1
			return true
		end

		local settled = true
		if state.llm_enabled ~= true then
			settled = set_runtime(false, "Prediction-lock disabled-preference settlement")
		elseif restore_when_empty == true then
			settled = set_runtime(true, "Prediction-lock final restoration")
		else
			local runtime_enabled = read_runtime()
			if runtime_enabled == nil then return false end
			if runtime_enabled == true then
				settled = set_runtime(false, "Prediction-lock non-restoring settlement")
			end
		end
		if settled ~= true then return false end
		leases[id] = nil
		lease_count = 0
		restore_when_empty = false
		return true
	end

	--- @param id any Stable owner token.
	--- @return boolean
	function inst.held(id)
		return id ~= nil and leases[id] == true
	end

	return inst
end

return M
