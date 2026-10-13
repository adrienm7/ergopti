--- modules/keylogger/physical_baseline.lua

--- Owns a paged initial state and reconciles subsequent per-element observations.
---
--- Baseline version 2 is the production contract the producer must emit:
--- - a device row declares whether it has keyboard-page elements and, if so, the
---   keyboard type macOS assigns it ("ansi", "iso" or "jis"; "none" otherwise),
---   because the keycode of the keys left of 1 and left of Z depends on it;
--- - a key row names its usage page, so the fn/globe key (Apple vendor pages)
---   and the media keys (Consumer page) are tracked like keyboard keys.
--- Version 1 (page-7 rows only, no keyboard type) is the historical diagnostic
--- format and is refused.
local M = {}
local Wire = require("modules.keylogger.physical_wire")
local Protocol = require("modules.keylogger.physical_protocol")
local ENVELOPE = { "version", "kind", "coverage", "incarnation", "lease" }
local PAGE = { "version", "kind", "coverage", "incarnation", "lease",
	"boundary", "offset", "next", "total", "complete", "rows" }

--- The only baseline descriptor version this consumer admits.
M.VERSION = 2

-- The keyboard type a device without keyboard-page elements declares.
local NO_KEYBOARD_TYPE = "none"

-- The largest element count one device may declare.
local ELEMENTS_MAX = 1024

-- Keyboard-page usages 1 to 3 are error states (rollover, POST fail, undefined).
local KEYBOARD_ERROR_USAGE_MAX = 3

--- Returns the largest usage a key row may carry on a page.
---@param page number Validated key page.
---@return number
local function usage_max(page)
	return page == Wire.PAGE_KEYBOARD and 0xFF or 0xFFFF
end

--- Creates a single-use baseline; the caller owns session identity and raw sequencing.
---@param descriptor table Opening baseline descriptor.
---@return table baseline
function M.new(descriptor)
	Wire.fields(descriptor, { "version", "boundary", "rows" })
	Protocol.require_version("baseline", descriptor.version, M.VERSION)
	local boundary = Wire.decimal(descriptor.boundary, false)
	local total = Wire.integer(descriptor.rows, 1, 64 * (ELEMENTS_MAX + 1))
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

	--- Returns the keyboard type a known device declared.
	---@param device string Canonical device identity.
	---@return string keyboard_type "ansi", "iso", "jis" or "none".
	function baseline.keyboard_type(device)
		local known = devices[device]
		assert(known, "Physical event has no baseline device")
		return known.keyboard_type
	end

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
				and Wire.integer(frame.total, 1, 64 * (ELEMENTS_MAX + 1)) == total, "Physical baseline cursor changed")
			local next_cursor = Wire.integer(frame.next, cursor + 1, total)
			assert(Wire.array(frame.rows, 1, 64) == next_cursor - cursor, "Invalid physical baseline page size")
			assert(type(frame.complete) == "boolean" and frame.complete == (next_cursor == total),
				"Invalid physical baseline page completion")
			for _, row in ipairs(frame.rows) do
				local device = Wire.decimal(row.device, true)
				if row.kind == "device" then
					Wire.fields(row, { "kind", "device", "keyboard", "keyboard_type", "elements" })
					device_complete()
					assert(type(row.keyboard) == "boolean" and not devices[device] and count < 64,
						"Invalid physical baseline device marker")
					assert(row.keyboard and Wire.KEYBOARD_TYPES[row.keyboard_type] == true
						or not row.keyboard and row.keyboard_type == NO_KEYBOARD_TYPE,
						"Invalid physical baseline keyboard type")
					local elements = Wire.integer(row.elements, row.keyboard and 1 or 0, ELEMENTS_MAX)
					current = { keyboard = row.keyboard, keyboard_type = row.keyboard_type,
						elements = elements, keys = {}, count = 0 }
					devices[device], count = current, count + 1
				elseif row.kind == "key" then
					Wire.fields(row, { "kind", "device", "page", "usage", "cookie", "timestamp", "down" })
					assert(current and devices[device] == current, "Physical key has no baseline device")
					local page = Wire.integer(row.page, 1, 0xFFFF)
					assert(Wire.KEY_PAGES[page] == true, "Physical baseline element is not on a key page")
					assert(page ~= Wire.PAGE_KEYBOARD or current.keyboard,
						"Keyboard element on a physical consumer interface")
					local cookie = Wire.integer(row.cookie, 0, 4294967295)
					local usage = Wire.integer(row.usage, 1, usage_max(page))
					local timestamp = Wire.decimal(row.timestamp, false)
					assert(not Wire.less(boundary, timestamp), "Physical baseline observation exceeds opening")
					assert(type(row.down) == "boolean" and (page ~= Wire.PAGE_KEYBOARD
						or usage > KEYBOARD_ERROR_USAGE_MAX or not row.down), "Invalid physical baseline value")
					assert(not current.keys[cookie] and current.count < current.elements, "Duplicate or excessive physical baseline key")
					current.keys[cookie] = { page = page, usage = usage, frontier = timestamp,
						initial = row.down, down = row.down }
					current.count = current.count + 1
				else error("Unknown physical baseline row") end
			end
			cursor = next_cursor
			return tostring(cursor)
		end)
	end

	--- Advances state once and reports qualified post-opening transitions.
	--- An inherited release reports a transition without an owned matched press;
	--- matching and historical permission remain the delivery owner's obligation.
	---@param row table Raw row whose sequence, usage flags and timestamp were validated.
	---@return string|nil transition "press", "release", or no qualified transition.
	function baseline.transition(row)
		return guarded(function()
			assert(status == "ready", "Physical baseline is not ready")
			local device = devices[row.device]
			assert(device, "Physical event has no baseline device")
			if not row.has_page or Wire.KEY_PAGES[row.page] ~= true then return nil end
			assert(row.page ~= Wire.PAGE_KEYBOARD or device.keyboard, "Keyboard input arrived on a consumer interface")
			assert(row.has_usage, "Physical key usage is missing")
			if row.usage == 0 or row.usage == -1 then return nil end
			Wire.integer(row.usage, 1, usage_max(row.page))
			assert(row.has_cookie == true, "Physical element cookie is missing")
			local key = device.keys[Wire.integer(row.cookie, 0, 4294967295)]
			assert(key and key.page == row.page and key.usage == row.usage, "Physical element identity changed")
			assert(row.value == "0" or row.value == "1", "Unqualified physical key value")
			local down, timestamp = row.value == "1", Wire.decimal(row.timestamp, false)
			assert(row.page ~= Wire.PAGE_KEYBOARD or row.usage > KEYBOARD_ERROR_USAGE_MAX or not down,
				"Active physical keyboard error")
			assert(not key.last_at or (not Wire.less(timestamp, key.last_at)
				and (timestamp ~= key.last_at or down == key.last_down)), "Physical element chronology changed")
			assert(timestamp ~= key.frontier or down == key.initial, "Physical observation contradicts baseline")
			key.last_at, key.last_down = timestamp, down
			if not Wire.less(key.frontier, timestamp) then return nil end
			local changed = key.down ~= down
			assert(not changed or timestamp ~= boundary, "Physical transition is ambiguous at opening")
			key.down = down
			if changed and Wire.less(boundary, timestamp) then return down and "press" or "release" end
			return nil
		end)
	end

	--- Preserves the press-only contract while advancing the same qualified state.
	---@param row table Raw observation whose common fields were already validated.
	---@return boolean press Fresh post-opening down; releases never create a press.
	function baseline.press(row) return baseline.transition(row) == "press" end

	return baseline
end

return M
