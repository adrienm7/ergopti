--- _shared/lua/shortcuts/physical_editor.lua

--- ==============================================================================
--- MODULE: Physical Shortcut Editor Session
--- DESCRIPTION:
--- Retains the exact native source displayed by a shared editor. Action selection
--- only creates a draft; the established native scope owns joint publication.
--- ==============================================================================

local Entries = require("shortcuts.physical_entries")
local M = {}

local function closed(value, fields)
	if type(value) ~= "table" or getmetatable(value) ~= nil then return false end
	for field in pairs(value) do if not fields[field] then return false end end
	return true
end

--- Creates one page-owned session with native source and publication ports.
--- @param options table Model, catalogue, parameter section and exact native ports.
--- @return table owner Detached rendering and acknowledged edit operations.
function M.new(options)
	assert(type(options) == "table" and type(options.model) == "table")
	for _, name in ipairs({ "capture", "current", "commit", "picker", "label", "emit" }) do
		assert(type(options[name]) == "function", "physical editor port is incomplete")
	end
	local model, catalogue = options.model, options.catalogue
	local planner = Entries.new(model, catalogue, { parameter_section = options.parameter_section })
	local owner, inventory, source, draft = {}, nil, nil, nil
	local alive, busy, generation, serial = true, false, 0, 0
	local function current()
		if not alive or source == nil then return false end
		local expected, epoch = source, generation
		local called, accepted = pcall(options.current, expected)
		return called and accepted == true and alive and source == expected and generation == epoch
	end
	local function capture()
		local called, snapshot, receipt = pcall(options.capture)
		if not called or type(snapshot) ~= "table" or type(snapshot.assignments) ~= "table"
			or type(snapshot.parameters) ~= "table" or type(receipt) ~= "table" then
			return false, receipt == "source_changed" and "source_changed" or "window_unavailable"
		end
		inventory, source = snapshot, receipt
		return current()
	end
	local function records()
		local result = {}
		for slot, action in pairs(inventory.assignments) do
			local descriptor = model.parse(slot)
			if descriptor and type(action) == "string" then
				result[#result + 1] = { slot = slot, code = descriptor.code, mods = descriptor.mods,
					action = action, label = options.label(action) }
			end
		end
		table.sort(result, function(left, right) return left.slot < right.slot end)
		return result
	end
	--- Opens from a coherent canonical/native snapshot, never browser state.
	--- @return table|nil packet Detached configured records and native positions.
	function owner.open()
		if not alive or busy or source ~= nil then return nil end
		busy = true
		local called, packet, reason = pcall(function()
			local captured, refusal = capture()
			if not captured then return nil, refusal or "source_changed" end
			local entries = records()
			if not current() then return nil end
			return { entries = entries, positions = options.positions, capture = false }
		end)
		busy = false
		return called and packet or nil, called and reason or "window_unavailable"
	end
	--- Opens the existing action picker without publishing its result.
	--- @param request table Manual position, exact modifiers and optional old slot.
	--- @return boolean opened
	function owner.choose(request)
		if busy then return false end
		busy = true
		local accepted, result = pcall(function()
			if not current() or not closed(request, { code = true, mods = true, previous_slot = true, request_id = true })
				or type(request.request_id) ~= "number" or request.request_id < 1 or request.request_id % 1 ~= 0 then return false end
			local slot = model.encode(request.code, request.mods)
			local previous = request.previous_slot
			if not slot or previous ~= nil and (not model.owns(previous) or inventory.assignments[previous] == nil) then return false end
			serial, generation = serial + 1, generation + 1
			local token, epoch = serial, generation
			draft = nil
			local action = inventory.assignments[previous or slot] or "none"
			local binding = "keyboard__" .. (previous or slot)
			local called, opened = pcall(options.picker, binding, action, function(selected, parameter)
				if busy then return false end
				busy = true
				local accepted, result = pcall(function()
					if generation ~= epoch or not current() then return false end
					local request_rows = planner.plan({ operation = previous and "edit" or "add", slot = slot,
						previous_slot = previous, action = selected, parameter = parameter }, inventory)
					if not request_rows or generation ~= epoch or not current() then return false end
					draft = { token = token, epoch = epoch, slot = slot, previous = previous,
						action = selected, parameter = parameter }
					options.emit({ action = "selected", token = token, request_id = request.request_id, label = options.label(selected) })
					return current() and generation == epoch
				end)
				busy = false
				return accepted and result == true
			end)
			return called and opened == true and alive and generation == epoch
		end)
		busy = false
		return accepted and result == true
	end
	local function publish(request)
		local rows = planner.plan(request, inventory)
		if not rows or not current() then return { committed = false, reason = "source_changed" } end
		local receipt, epoch = source, generation
		local called, committed, reason = pcall(options.commit, rows, receipt)
		if not called or committed ~= true then
			local reasons = { source_changed = true, collision = true, unavailable = true }
			return { committed = false, reason = reasons[reason] and reason or "save_failed" }
		end
		-- Durable success is truthful even when its refreshed display is refused.
		draft, inventory, source = nil, nil, nil
		generation = generation + 1
		local refreshed, packet = pcall(function()
			if not alive or generation ~= epoch + 1 or not capture() then return nil end
			return records()
		end)
		if not refreshed or packet == nil then
			return { committed = true, refreshed = false }
		end
		return { committed = true, refreshed = true, entries = packet }
	end
	--- Publishes only the exact acknowledged picker draft.
	--- @param token number Opaque page-session draft identity.
	--- @return table result Truthful publication and refreshed display receipts.
	function owner.save(token)
		if busy then return { committed = false, reason = "source_changed" } end
		busy = true
		if not current() or not draft or token ~= draft.token or draft.epoch ~= generation then
			busy = false
			return { committed = false, reason = "source_changed" }
		end
		local selected = draft
		local called, result = pcall(publish, { operation = selected.previous and "edit" or "add",
			slot = selected.slot, previous_slot = selected.previous, action = selected.action, parameter = selected.parameter })
		busy = false
		return called and result or { committed = false, reason = "save_failed" }
	end
	--- Removes one displayed entry and only its recognized binding parameters.
	--- @param slot string Exact canonical displayed identity.
	--- @return table result Publication acknowledgement.
	function owner.remove(slot)
		if busy then return { committed = false, reason = "source_changed" } end
		busy = true
		if not current() or type(slot) ~= "string" or inventory.assignments[slot] == nil then
			busy = false
			return { committed = false, reason = "source_changed" }
		end
		local called, result = pcall(publish, { operation = "remove", slot = slot })
		busy = false
		return called and result or { committed = false, reason = "save_failed" }
	end
	--- Retires drafts without touching native configuration or foreign windows.
	function owner.close()
		alive, draft = false, nil
		generation = generation + 1
	end
	return owner
end
return M
