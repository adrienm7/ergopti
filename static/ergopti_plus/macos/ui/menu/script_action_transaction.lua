--- ui/menu/script_action_transaction.lua

--- ==============================================================================
--- MODULE: Script Action Mutation Owner
--- DESCRIPTION:
--- Serializes a script chord assignment with preference publication and retains
--- the exact inverse when a partially applied runtime mutation cannot settle.
--- ==============================================================================

local M = {}
local Logger = require("infra.logger")
local LOG = "menu.script_action_transaction"

--- Creates an assignment owner around the global writer and preference owners.
--- @param options table State, native facade, admission, pause and save ports.
--- @return table owner Assignment operation.
function M.new(options)
	assert(type(options) == "table" and type(options.state) == "table", "script action state required")
	for _, name in ipairs({ "admission", "paused", "save_prefs" }) do
		assert(type(options[name]) == "function", "script action port missing: " .. name)
	end
	local owner, claim, debt = {}, {}, nil
	local function read(getter, slot)
		local ok, actions = pcall(getter)
		if not ok or type(actions) ~= "table" then return nil end
		local value = actions[slot] or "none"
		return type(value) == "string" and value or nil
	end
	local function restore(retire)
		if not debt then return true end
		local saved = debt
		local facade = options.script_control
		if not rawequal(facade, saved.facade) or facade.set_shortcut_action ~= saved.setter
			or facade.get_shortcut_actions ~= saved.getter then return false end
		if not rawequal(options.state.script_control_shortcuts, saved.state_owner) then return false end
		local current = read(saved.getter, saved.slot)
		if current ~= saved.runtime and current ~= saved.candidate then return false end
		local state_value = options.state.script_control_shortcuts[saved.slot]
		if state_value ~= saved.state and state_value ~= saved.candidate then return false end
		local ok, accepted = pcall(saved.setter, saved.slot, saved.runtime)
		if not ok or accepted ~= true or debt ~= saved
			or not rawequal(options.state.script_control_shortcuts, saved.state_owner)
			or read(saved.getter, saved.slot) ~= saved.runtime then return false end
		options.state.script_control_shortcuts[saved.slot] = saved.state
		if retire then debt = nil end
		return true
	end
	function claim.pending() return debt ~= nil end
	function claim.retry_restore() return restore(true) end
	function owner.pending() return debt ~= nil end
	function owner.restore_runtime() return restore(false) end
	--- Routes ordinary whole-state rollback through this owner's exact inverse.
	--- @param modules table Existing native dependency bag.
	--- @return table|nil projection Protected rollback ports, or refusal.
	function owner.rollback_modules(modules)
		if not debt then return modules end
		if type(modules) ~= "table" or not rawequal(modules.shortcuts_mod, debt.facade) then return nil end
		local projected, facade = {}, {}
		for key, value in pairs(modules) do projected[key] = value end
		for key, value in pairs(debt.facade) do facade[key] = value end
		local setter = debt.setter
		facade.set_shortcut_action = function(slot, value)
			if debt and slot == debt.slot then return restore(false) end
			return setter(slot, value)
		end
		projected.shortcuts_mod = facade
		return projected
	end
	--- Commits one non-parameterized script chord action.
	--- @param slot string Script chord identifier.
	--- @param action string Selected action.
	--- @return boolean committed
	function owner.assign(slot, action)
		if type(slot) ~= "string" or type(action) ~= "string" then return false end
		return options.admission("Script chord action", function()
			if options.paused() ~= false then return false end
			if debt and not restore(true) then return false end
			local facade = options.script_control
			local setter = type(facade) == "table" and facade.set_shortcut_action or nil
			local getter = type(facade) == "table" and facade.get_shortcut_actions or nil
			local state = options.state.script_control_shortcuts
			if type(setter) ~= "function" or type(getter) ~= "function" or type(state) ~= "table" then return false end
			local prior = read(getter, slot)
			if prior == nil then return false end
			debt = { facade = facade, setter = setter, getter = getter, slot = slot,
				runtime = prior, state_owner = state, state = state[slot], candidate = action }
			local called, accepted = pcall(setter, slot, action)
			if not called or accepted ~= true or read(getter, slot) ~= action
				or not rawequal(options.script_control, facade)
				or facade.set_shortcut_action ~= setter or facade.get_shortcut_actions ~= getter
				or not rawequal(options.state.script_control_shortcuts, state) or state[slot] ~= debt.state
				or options.paused() ~= false then
				if not restore(true) then Logger.error(LOG, "Script action rollback remains pending.") end
				return false
			end
			state[slot] = action
			local saved, committed = pcall(options.save_prefs)
			if not saved or committed ~= true then
				if not restore(true) then Logger.error(LOG, "Script action rollback remains pending.") end
				return false
			end
			if not rawequal(options.script_control, facade) or facade.set_shortcut_action ~= setter
				or facade.get_shortcut_actions ~= getter
				or not rawequal(options.state.script_control_shortcuts, state) or state[slot] ~= action
				or read(getter, slot) ~= action then return false end
			debt = nil
			return true
		end, claim) == true
	end
	return owner
end

return M
