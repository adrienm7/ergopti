--- modules/keylogger/physical_baseline.lua

--- Owns a paged initial state and reconciles subsequent per-element observations.
local M = {}
local Wire = require("modules.keylogger.physical_wire")
local ENVELOPE = { "version", "kind", "coverage", "incarnation", "lease" }
local PAGE = { "version", "kind", "coverage", "incarnation", "lease",
	"boundary", "offset", "next", "total", "complete", "rows" }

--- Creates a single-use baseline; the caller owns session identity and raw sequencing.
---@param descriptor table Opening baseline descriptor.
---@return table baseline
function M.new(descriptor)
	Wire.fields(descriptor, { "version", "boundary", "rows" })
	assert(descriptor.version == 1, "Unsupported physical baseline version")
	local boundary = Wire.decimal(descriptor.boundary, false)
	local total = Wire.integer(descriptor.rows, 1, 64 * 1025)
	local status, cursor, count = "receiving", 0, 0
	local devices, current = {}, nil
	local baseline = {}

	local function device_complete()
		assert(not current or current.count == current.elements, "Incomplete physical baseline device")
	end

	local function guarded(callback)
		assert(status ~= "failed", "Physical baseline is failed")
		local ok, result = pcall(callback)
		if not ok then status = "failed"; error(result, 0) end
		return result
	end

	--- Reports explicit completed admission, not merely the last received page.
	---@return boolean
	function baseline.ready() return status == "ready" end

	--- Validates one page or the final marker; returns a page cursor to acknowledge.
	---@param frame table Frame whose session identity was already validated.
	---@return string|nil cursor Nil denotes the final marker, which needs no duplicate receipt.
	function baseline.accept(frame)
		return guarded(function()
			assert(status == "receiving", "Physical baseline is already complete")
			if frame.kind == "baseline_ready" then
				Wire.fields(frame, ENVELOPE)
				assert(cursor == total, "Premature physical baseline completion")
				device_complete()
				status = "ready"
				return nil
			end
			Wire.fields(frame, PAGE)
			assert(frame.kind == "baseline" and frame.boundary == boundary, "Physical baseline boundary changed")
			assert(Wire.integer(frame.offset, 0, total) == cursor
				and Wire.integer(frame.total, 1, 64 * 1025) == total, "Physical baseline cursor changed")
			local next_cursor = Wire.integer(frame.next, cursor + 1, total)
			assert(Wire.array(frame.rows, 1, 64) == next_cursor - cursor, "Invalid physical baseline page size")
			assert(type(frame.complete) == "boolean" and frame.complete == (next_cursor == total),
				"Invalid physical baseline page completion")
			for _, row in ipairs(frame.rows) do
				local device = Wire.decimal(row.device, true)
				if row.kind == "device" then
					Wire.fields(row, { "kind", "device", "keyboard", "elements" })
					device_complete()
					assert(type(row.keyboard) == "boolean" and not devices[device] and count < 64,
						"Invalid physical baseline device marker")
					local elements = Wire.integer(row.elements, row.keyboard and 1 or 0, row.keyboard and 1024 or 0)
					current = { keyboard = row.keyboard, elements = elements, keys = {}, count = 0 }
					devices[device], count = current, count + 1
				elseif row.kind == "key" then
					Wire.fields(row, { "kind", "device", "usage", "cookie", "timestamp", "down" })
					assert(current and devices[device] == current, "Physical key has no baseline device")
					local cookie = Wire.integer(row.cookie, 0, 4294967295)
					local usage = Wire.integer(row.usage, 1, 255)
					local timestamp = Wire.decimal(row.timestamp, false)
					assert(not Wire.less(boundary, timestamp), "Physical baseline observation exceeds opening")
					assert(type(row.down) == "boolean" and (usage > 3 or not row.down), "Invalid physical baseline value")
					assert(not current.keys[cookie] and current.count < current.elements, "Duplicate or excessive physical baseline key")
					current.keys[cookie] = { usage = usage, frontier = timestamp, initial = row.down, down = row.down }
					current.count = current.count + 1
				else error("Unknown physical baseline row") end
			end
			cursor = next_cursor
			return tostring(cursor)
		end)
	end

	--- Advances state for all raw observations, crediting only fresh post-opening presses.
	--- A release inherited from a held key updates state without creating a press.
	---@param row table Raw row whose sequence, usage flags and timestamp were validated.
	---@return boolean press
	function baseline.press(row)
		return guarded(function()
			assert(status == "ready", "Physical baseline is not ready")
			local device = devices[row.device]
			assert(device, "Physical event has no baseline device")
			if not row.has_page or row.page ~= 7 then return false end
			assert(device.keyboard, "Keyboard input arrived on a consumer interface")
			assert(row.has_usage, "Physical keyboard usage is missing")
			if row.usage == 0 or row.usage == -1 then return false end
			Wire.integer(row.usage, 1, 255)
			assert(row.has_cookie == true, "Physical element cookie is missing")
			local key = device.keys[Wire.integer(row.cookie, 0, 4294967295)]
			assert(key and key.usage == row.usage, "Physical element identity changed")
			assert(row.value == "0" or row.value == "1", "Unqualified physical key value")
			local down, timestamp = row.value == "1", Wire.decimal(row.timestamp, false)
			assert(row.usage > 3 or not down, "Active physical keyboard error")
			assert(not key.last_at or (not Wire.less(timestamp, key.last_at)
				and (timestamp ~= key.last_at or down == key.last_down)), "Physical element chronology changed")
			assert(timestamp ~= key.frontier or down == key.initial, "Physical observation contradicts baseline")
			key.last_at, key.last_down = timestamp, down
			if not Wire.less(key.frontier, timestamp) then return false end
			local changed = key.down ~= down
			assert(not changed or timestamp ~= boundary, "Physical transition is ambiguous at opening")
			key.down = down
			return changed and down and Wire.less(boundary, timestamp)
		end)
	end

	return baseline
end

return M
