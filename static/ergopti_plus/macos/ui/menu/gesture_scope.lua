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
local Logger = require("infra.logger")
local LOG = "gesture_scope"

--- Creates the session owner for the two existing whole-gesture menu commands.
--- @param options table Native, persistence, admission and confirmation ports.
--- @return table owner Scope application and retained compensation operations.
function M.new(options)
	local gestures, preferences = options.gestures, options.preferences
	local checkpoint, state = options.checkpoint, options.state
	local demotions = options.demotions
	assert(type(demotions) == "table" and type(demotions.release_feature) == "function"
		and type(demotions.readopt) == "function", "gesture scope needs the session demotion owner")
	assert(type(checkpoint) == "table" and type(checkpoint.capture) == "function"
		and type(checkpoint.replace) == "function", "gesture scope needs the ordinary-save checkpoint")
	for _, name in ipairs({ "admission", "confirm", "paused", "backup_path", "capture_preferences" }) do
		assert(type(options[name]) == "function", "gesture scope port missing: " .. name)
	end
	local owner, transaction, active_snapshot = {}, nil, nil
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
		if row.key == "space_wrap" then return "get_space_wrap", "set_space_wrap" end
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
	function owner.pending() return transaction ~= nil and transaction.pending() end
	function owner.retry_restore()
		return transaction == nil or transaction.retry_restore() == true
	end
	function owner.apply(mode)
		if mode ~= "clear" and mode ~= "recommended" then return false end
		return options.admission("Gesture scope", function()
			if options.paused() ~= false then return false end
			if owner.pending() and owner.retry_restore() ~= true then return false end
			if options.confirm(mode) ~= true then return false end
			-- The modal runs a native event loop; pause may acquire the engine while
			-- confirmation is open, so its admission must be checked again.
			if options.paused() ~= false then return false end
			transaction = Scope.new({
				path = options.path, backup_path = options.backup_path(), files = options.files, gestures = gestures,
				capture = function(source, candidate, updates)
					local baseline = preferences.source_snapshot(options.path)
					assert(type(baseline) == "table" and baseline.status == source.status
						and (source.status == "absent" or baseline.content == source.content),
						"gesture scope source differs from loaded preferences")
					local snapshot = { source = baseline, candidate = { status = "ok", content = candidate },
						checkpoint = checkpoint.capture(), master = gestures.is_enabled(), state_master = state.gestures,
						values = {} }
					assert(type(snapshot.master) == "boolean", "gesture master snapshot unavailable")
					for _, row in ipairs(updates) do
						local getter, setter, slot = accessor(row)
						if getter and setter then
							local value = gestures[getter](slot)
							assert(value ~= nil, "gesture setting snapshot unavailable")
							snapshot.values[#snapshot.values + 1] = { getter = getter, setter = setter, slot = slot, value = value }
						end
					end
					active_snapshot = snapshot
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
					assert(type(master) == "boolean", "gesture scope omitted its master")
					if apply_native(values, master) ~= true then return false end
					local saved = active_snapshot
					saved.demotions = demotions.release_feature("gestures")
					if preferences.replace_source(options.path, saved.source, saved.candidate) ~= true then return false end
					saved.source_staged = true
					local accepted, candidate_checkpoint = checkpoint.replace(saved.checkpoint, state, options.capture_preferences())
					if accepted ~= true then return false end
					saved.staged_checkpoint = candidate_checkpoint
					return true
				end,
				restore = function(snapshot)
					if apply_native(snapshot.values, snapshot.master) ~= true then return false end
					state.gestures = snapshot.state_master
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
			local committed, detail = transaction.apply("gestures", mode)
			if committed ~= true then Logger.warn(LOG, "Gesture scope did not commit: %s.", tostring(detail)) end
			return committed, detail
		end, owner)
	end
	return owner
end

return M
