--- ui/menu/base_delay_transaction.lua

--- ==============================================================================
--- MODULE: Baseline Delay Mutation Owner
--- DESCRIPTION:
--- Enters the existing global writer fence before changing the baseline delay.
--- The ordinary preference transaction owns publication and whole-state rollback;
--- this owner retains the exact native inverse until it is acknowledged.
--- ==============================================================================

local M = {}
local Logger = require("infra.logger")
local LOG = "menu.base_delay_transaction"

local function valid_delay(value)
	return type(value) == "number" and value >= 0 and value < math.huge
end

--- Creates the baseline delay owner around the existing native and disk owners.
--- @param options table State, keymap, admission, pause and ordinary save ports.
--- @return table owner Mutation and retained compensation operations.
function M.new(options)
	assert(type(options) == "table" and type(options.state) == "table", "baseline delay state required")
	for _, name in ipairs({ "admission", "paused", "save_prefs" }) do
		assert(type(options[name]) == "function", "baseline delay port missing: " .. name)
	end
	local debt = nil
	local owner, claim = {}, {}
	local function observe(getter)
		local called, value = pcall(getter)
		if not called or not valid_delay(value) then return nil end
		return value
	end
	local function apply(setter, getter, value)
		local called, accepted = xpcall(function() return setter(value) end, debug.traceback)
		if not called or accepted ~= true or observe(getter) ~= value then
			Logger.warn(LOG, "Baseline delay runtime mutation was not acknowledged.")
			return false
		end
		return true
	end
	function claim.pending() return debt ~= nil end
	local function restore(retire)
		if debt == nil then return true end
		options.state.expansion_delay = debt.state
		local keymap = options.keymap
		if not rawequal(keymap, debt.keymap) or keymap.set_base_delay ~= debt.setter
			or keymap.get_base_delay ~= debt.getter then return false end
		local current = observe(debt.getter)
		if current ~= debt.runtime and current ~= debt.candidate then
			Logger.warn(LOG, "Baseline delay recovery refused an unrelated runtime value.")
			return false
		end
		if apply(debt.setter, debt.getter, debt.runtime) ~= true then return false end
		if retire then debt = nil end
		return true
	end
	function claim.retry_restore() return restore(true) end
	function owner.pending() return claim.pending() end
	--- Protects the ordinary rollback from overwriting an unrelated baseline.
	--- The caller already holds this owner's global writer admission. The inverse
	--- remains retained until the entire ordinary rollback has returned.
	--- @return boolean restored Exact native inverse acknowledgement.
	function owner.restore_runtime() return restore(false) end
	function owner.retry_restore()
		return options.admission("Baseline delay recovery", claim.retry_restore, claim) == true
	end
	--- Publishes a baseline delay only after native and durable acknowledgement.
	--- @param seconds number Finite nonnegative delay in seconds.
	--- @return boolean committed
	function owner.set(seconds)
		if not valid_delay(seconds) then return false end
		return options.admission("Baseline delay preference", function()
			if options.paused() ~= false then return false end
			if debt ~= nil and claim.retry_restore() ~= true then return false end
			local keymap = options.keymap
			local setter = type(keymap) == "table" and keymap.set_base_delay or nil
			local getter = type(keymap) == "table" and keymap.get_base_delay or nil
			if type(setter) ~= "function" or type(getter) ~= "function"
				or not valid_delay(options.state.expansion_delay) then return false end
			local prior_runtime = observe(getter)
			if prior_runtime == nil or options.paused() ~= false then return false end
			debt = { state = options.state.expansion_delay, runtime = prior_runtime, candidate = seconds,
				keymap = keymap, setter = setter, getter = getter }
			if apply(setter, getter, seconds) ~= true then
				claim.retry_restore()
				return false
			end
			options.state.expansion_delay = seconds
			local called, committed = xpcall(options.save_prefs, debug.traceback)
			if not called or committed ~= true then
				-- The ordinary transaction restores its whole acknowledged checkpoint.
				-- Its legacy delay sync can return false, so prove this inverse too.
				claim.retry_restore()
				return false
			end
			debt = nil
			return true
		end, claim) == true
	end
	return owner
end

return M
