--- ui/menu/gesture_scope.lua

--- ==============================================================================
--- MODULE: Gesture Scope Transaction
--- DESCRIPTION:
--- Applies one complete gesture scope under the existing global writer fence.
--- The file source and ordinary-save rollback snapshots advance provisionally
--- with native state, and retain exact inverses until publication commits.
--- ==============================================================================

local M = {}
local Manifest = require("infra.manifest_reader")
local Scope = require("infra.preferences_scope")

--- Creates the session owner for the two existing whole-gesture menu commands.
--- @param options table Native, persistence and admission ports.
--- @return table owner Scope application and retained compensation operations.
function M.new(options)
	local gestures, state = options.gestures, options.state
	local slots = {}
	for _, list in ipairs({ gestures.SINGLE_SLOTS, gestures.AXIS_SLOTS }) do
		for _, slot in ipairs(list) do slots[slot] = true end
	end
	local function accessor(row)
		if row.section == "gestures.action_parameters" then return nil end
		if row.section == "gestures.modes" then return "get_mode", "set_mode", row.key end
		if row.section == "gestures.sensitivities" then return "get_sensitivity", "set_sensitivity", row.key end
		assert(row.section == "gestures", "unexpected gesture scope owner: " .. row.section)
		if row.key == "enabled" then return "is_enabled", nil end
		-- Retired manifest action fields still have persisted ownership but no
		-- native slot; clearing them must not create a new runtime assignment.
		if not slots[row.key] then return nil end
		return "get_action", "set_action", row.key
	end
	local function apply_native(values, master)
		if gestures.disable_all() ~= true then return false end
		for _, item in ipairs(values) do
			if item.setter then
				local result
				if item.slot then result = gestures[item.setter](item.slot, item.value)
				else result = gestures[item.setter](item.value) end
				if result ~= true or gestures[item.getter](item.slot) ~= item.value then return false end
			end
		end
		if master == true and gestures.enable_all() ~= true then return false end
		if gestures.is_enabled() ~= master then return false end
		state.gestures = master
		return true
	end
	local ports = {}
	for key, value in pairs(options) do ports[key] = value end
	ports.scope, ports.demotion_feature = "gestures", "gestures"
	-- A demotion is the saved switch held off for this session: only a scope
	-- that publishes the switch ends it. A clear leaves the switch as it is
	-- (the manifest's `clear_exclude`), so it leaves the demotion too.
	ports.demotion_keys = function(rows)
		for _, row in ipairs(rows) do
			if row.section == "gestures" and row.key == "enabled" then return { gestures = true } end
		end
		return {}
	end
	ports.transaction_factory = function(config)
		config.gestures = gestures
		return Scope.new(config)
	end
	ports.runtime = {
		capture = function(updates)
			local snapshot = { master = gestures.is_enabled(), state_master = state.gestures, values = {} }
			assert(type(snapshot.master) == "boolean", "gesture master snapshot unavailable")
			for _, row in ipairs(updates) do
				local getter, setter, slot = accessor(row)
				if getter and setter then
					local value = gestures[getter](slot)
					assert(value ~= nil, "gesture setting snapshot unavailable")
					snapshot.values[#snapshot.values + 1] = { getter = getter, setter = setter, slot = slot, value = value }
				end
			end
			return snapshot
		end,
		apply = function(_, updates)
			local values, master = {}, nil
			for _, row in ipairs(updates) do
				local getter, setter, slot = accessor(row)
				if getter then
					local value = row.value
					if row.delete then value = Manifest.default_for(row.section .. "." .. row.key) end
					if setter then values[#values + 1] = { getter = getter, setter = setter, slot = slot, value = value }
					else master = value end
				end
			end
			-- A scope with no row for the switch (a clear) keeps the live one.
			if master == nil then master = gestures.is_enabled() end
			assert(type(master) == "boolean", "gesture master is unavailable")
			if apply_native(values, master) ~= true then return false end
			return true
		end,
		restore = function(snapshot)
			if apply_native(snapshot.values, snapshot.master) ~= true then return false end
			state.gestures = snapshot.state_master
			return true
		end,
	}
	return require("ui.menu.scoped_preferences").new(ports)
end

return M
