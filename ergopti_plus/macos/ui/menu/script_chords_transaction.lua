--- ui/menu/script_chords_transaction.lua

--- ==============================================================================
--- MODULE: Script Chord Preference Mutation Owner
--- DESCRIPTION:
--- Enters the existing global writer fence before changing the logical chord
--- gate. The ordinary preference owner publishes configuration and restores its
--- checkpoint; this owner retains the exact logical native inverse meanwhile.
--- ==============================================================================

local M = {}
local Logger = require("infra.logger")
local LOG = "menu.script_chords_transaction"

--- Creates a mutation owner around the existing logical native and disk owners.
--- @param options table State, native facade, admission, pause and save ports.
--- @return table owner Toggle and retained rollback operations.
function M.new(options)
	assert(type(options) == "table" and type(options.state) == "table", "script chord state required")
	for _, name in ipairs({ "admission", "paused", "save_prefs" }) do
		assert(type(options[name]) == "function", "script chord port missing: " .. name)
	end
	local owner, claim, debt = {}, {}, nil
	local function observe(getter)
		local called, value = pcall(getter)
		if called and type(value) == "boolean" then return value end
		return nil
	end
	local function ready()
		local called, paused = pcall(options.paused)
		return called and paused == false
	end
	local function apply(setter, getter, value)
		local called, accepted = pcall(setter, value)
		if not called or accepted ~= true or observe(getter) ~= value then
			Logger.warn(LOG, "Script chord logical gate was not acknowledged.")
			return false
		end
		return true
	end
	local function owned()
		local facade = options.script_control
		return debt ~= nil and rawequal(facade, debt.facade)
			and facade.set_script_chords_enabled == debt.setter
			and facade.script_chords_enabled == debt.getter
	end
	local function restore(retire)
		if debt == nil then return true end
		options.state.script_control_enabled = debt.state
		if not owned() or observe(debt.getter) == nil then return false end
		if apply(debt.setter, debt.getter, debt.runtime) ~= true then return false end
		if retire then debt = nil end
		return true
	end
	function claim.pending() return debt ~= nil end
	function claim.retry_restore() return restore(true) end
	function owner.pending() return claim.pending() end
	function owner.restore_runtime() return restore(false) end
	--- Keeps ordinary rollback's chord setter under this retained native owner.
	--- All other core module ports are preserved; no forward gate value from the
	--- checkpoint can overwrite the inverse during whole-preference sync.
	--- @param core_modules table Existing native dependency bag.
	--- @return table|nil modules Owned rollback projection, or refusal.
	function owner.rollback_modules(core_modules)
		if debt == nil then return core_modules end
		if not owned() or type(core_modules) ~= "table"
			or not rawequal(core_modules.shortcuts_mod, debt.facade) then return nil end
		local modules, facade = {}, {}
		for key, value in pairs(core_modules) do modules[key] = value end
		for key, value in pairs(debt.facade) do facade[key] = value end
		facade.set_script_chords_enabled = function() return owner.restore_runtime() end
		modules.shortcuts_mod = facade
		return modules
	end
	function owner.retry_restore()
		return options.admission("Script chord recovery", claim.retry_restore, claim) == true
	end
	--- Toggles the currently observed gate after admission and before publication.
	--- @return boolean committed Strict logical native and durable acknowledgement.
	function owner.toggle()
		return options.admission("Script chord preference", function()
			if not ready() then return false end
			if debt ~= nil and claim.retry_restore() ~= true then return false end
			local facade = options.script_control
			local setter = type(facade) == "table" and facade.set_script_chords_enabled or nil
			local getter = type(facade) == "table" and facade.script_chords_enabled or nil
			if type(setter) ~= "function" or type(getter) ~= "function"
				or type(options.state.script_control_enabled) ~= "boolean" then return false end
			local prior = observe(getter)
			if prior == nil or not ready() then return false end
			local candidate = not prior
			debt = { state = options.state.script_control_enabled, runtime = prior,
				facade = facade, setter = setter, getter = getter }
			if apply(setter, getter, candidate) ~= true then
				claim.retry_restore()
				return false
			end
			if not owned() or not ready() then
				claim.retry_restore()
				return false
			end
			options.state.script_control_enabled = candidate
			local called, committed = pcall(options.save_prefs)
			if not called or committed ~= true then
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
