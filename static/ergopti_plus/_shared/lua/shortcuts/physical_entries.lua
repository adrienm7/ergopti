--- _shared/lua/shortcuts/physical_entries.lua

--- Shared user entry edits for the acknowledged shortcut scope coordinator.
--- This pure planner acquires no native input and publishes no file itself.
local M = {}
local Assignment = require("shortcuts.assignment")

local function dictionary(value)
	return type(value) == "table" and getmetatable(value) == nil
end

--- Binds canonical physical slots and the existing action/parameter catalogue.
--- @param model table Immutable shared physical-slot owner.
--- @param actions table is_assignable, get_action_parameter_spec,
---   validate_action_parameter and split_action_parameter_key catalogue ports.
function M.new(model, actions, options)
	assert(type(model) == "table" and type(model.parse) == "function", "physical entry model unavailable")
	for _, name in ipairs({ "is_assignable", "get_action_parameter_spec", "validate_action_parameter", "split_action_parameter_key" }) do
		assert(type(actions) == "table" and type(actions[name]) == "function", "physical entry action catalogue unavailable")
	end
	assert(type(options) == "table" and (options.parameter_section == "gestures.action_parameters"
		or options.parameter_section == "gesture_parameters"), "physical entry parameter owner unavailable")
	local parameter_section = options.parameter_section
	local owner = {}
	--- Plans Add/Edit/Remove against a detached acknowledged inventory.
	--- Repositioning removes only the old entry's owned parameters; unrelated
	--- entries and unknown parameter keys remain preserved by the scope owner.
	--- @param request table { operation, slot, action?, parameter?, previous_slot? }.
	--- @param inventory table { assignments, parameters } exact owner snapshots.
	--- @return table|nil rows Existing scope updates, or a closed refusal.
	--- @return string|nil reason
	function owner.plan(request, inventory)
		if not dictionary(request) or not dictionary(inventory) or not dictionary(inventory.assignments)
			or not dictionary(inventory.parameters) then return nil, "invalid_inventory" end
		for field in pairs(request) do
			if field ~= "operation" and field ~= "slot" and field ~= "action" and field ~= "parameter"
				and field ~= "previous_slot" then return nil, "invalid_request" end
		end
		local operation, slot = request.operation, request.slot
		if operation ~= "add" and operation ~= "edit" and operation ~= "remove" then return nil, "invalid_operation" end
		if not model.parse(slot) then return nil, "invalid_slot" end
		local previous = request.previous_slot or slot
		if not model.parse(previous) or operation ~= "edit" and request.previous_slot ~= nil then return nil, "invalid_previous_slot" end
		if operation == "add" and inventory.assignments[slot] ~= nil then return nil, "entry_exists" end
		if operation ~= "add" and inventory.assignments[previous] == nil then return nil, "entry_absent" end
		if operation == "edit" and previous ~= slot and inventory.assignments[slot] ~= nil then return nil, "entry_exists" end
		if operation == "remove" and (request.action ~= nil or request.parameter ~= nil) then return nil, "invalid_request" end
		local rows = {}
		local function remove_entry(id)
			rows[#rows + 1] = { section = "shortcuts.keyboard", key = id, delete = true }
			local binding, keys = "keyboard__" .. id, {}
			for key in pairs(inventory.parameters) do
				local candidate, action = actions.split_action_parameter_key(key)
				if candidate == binding and type(actions.get_action_parameter_spec(action)) == "string" then keys[#keys + 1] = key end
			end
			table.sort(keys)
			for _, key in ipairs(keys) do rows[#rows + 1] = { section = parameter_section, key = key, delete = true } end
		end
		if operation == "remove" then remove_entry(slot); return rows end
		if type(request.action) ~= "string" or actions.is_assignable(request.action) ~= true then return nil, "invalid_action" end
		local spec = actions.get_action_parameter_spec(request.action)
		if type(spec) == "string" then
			if type(request.parameter) ~= "string" or actions.validate_action_parameter(request.action, request.parameter) ~= true then
				return nil, "invalid_parameter"
			end
		elseif request.parameter ~= nil then return nil, "unexpected_parameter" end
		if operation == "edit" and previous ~= slot then remove_entry(previous) end
		rows[#rows + 1] = Assignment.operation(slot, request.action, model.owns, actions.is_assignable)
		if type(spec) == "string" then rows[#rows + 1] = { section = parameter_section,
			key = "keyboard__" .. slot .. "__" .. request.action, value = request.parameter } end
		return rows
	end
	return owner
end

return M
