--- _shared/lua/shortcuts/physical_editor_inventory.lua

--- Exact canonical editor frames backed by the actual native source owners.
local Codec = require("toml_codec")
local PhysicalSlots = require("shortcuts.physical_slots")
local M = {}
function M.new(options)
	local receipts = setmetatable({}, { __mode = "k" })
	local owner = {}
	local function privately_current(record)
		return record.keyboard() == true and record.parameters() == true
			and (record.native_source == nil or record.native_source() == true)
	end
	function owner.current(receipt)
		local record = receipts[receipt]
		if not record or not privately_current(record) then return false end
		local called, path = pcall(options.current_path)
		if not called or path ~= options.path or not privately_current(record) then return false end
		local read, bytes, status = pcall(options.read, options.path)
		local routed, final_path = pcall(options.current_path)
		return read and routed and final_path == options.path and status == record.status
			and bytes == record.content and privately_current(record)
	end
	function owner.capture()
		local called, bytes, status = pcall(options.read, options.path)
		if not called or status ~= "ok" and status ~= "absent" or status == "ok" and type(bytes) ~= "string" then return nil, "unavailable" end
		local parsed, document = pcall(Codec.decode, bytes or "")
		if not parsed or type(document) ~= "table" then return nil, "source_changed" end
		local native = options.keyboard.capture_physical_editor_inventory()
		if type(native) ~= "table" or type(native.assignments) ~= "table" or type(native.current) ~= "function" then return nil, "unavailable" end
		local assignments = {}
		local section = type(document.shortcuts) == "table" and document.shortcuts.keyboard or nil
		if section ~= nil and type(section) ~= "table" then return nil, "source_changed" end
		for slot, action in pairs(section or {}) do
			if PhysicalSlots.is_namespace(slot) then
				if not options.keyboard.physical_slot_descriptor(slot) or type(action) ~= "string"
					or options.parameters.is_assignable(action) ~= true then return nil, "source_changed" end
				assignments[slot] = action
			end
		end
		for slot, action in pairs(assignments) do if native.assignments[slot] ~= action then return nil, "source_changed" end end
		for slot, action in pairs(native.assignments) do if assignments[slot] ~= action then return nil, "source_changed" end end
		local params = options.parameters.capture_parameter_source_guard(document, options.recognizes)
		if type(params) ~= "function" then return nil, "source_changed" end
		local parameters = options.parameters.get_all_action_parameters()
		local record = { status = status, content = bytes, keyboard = native.current, parameters = params }
		if options.source_guard then
			record.native_source = options.source_guard(record)
			if type(record.native_source) ~= "function" then return nil, "source_changed" end
		end
		local receipt = {}; receipts[receipt] = record
		if not owner.current(receipt) then receipts[receipt] = nil; return nil, "source_changed" end
		return { assignments = assignments, parameters = parameters }, receipt
	end
	function owner.expected_source(receipt)
		if not owner.current(receipt) then return nil end
		local record = receipts[receipt]
		return { path = options.path, status = record.status, content = record.content,
			guard = function() return owner.current(receipt) end }
	end
	return owner
end
return M
