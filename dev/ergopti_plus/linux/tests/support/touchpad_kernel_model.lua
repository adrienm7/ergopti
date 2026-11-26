--- tests/support/touchpad_kernel_model.lua

--- ==============================================================================
--- MODULE: Touchpad Kernel Model
--- DESCRIPTION:
--- A multitouch touchpad as the Linux input core and evdev present it to one
--- reader, behind the evdev reader's backend seam: a value equal to the one a
--- slot holds is dropped, ABS_MT_SLOT is sent only when the slot changes, an
--- empty frame is never delivered, an overflow replaces the unread events with
--- SYN_DROPPED, EVIOCGABS and EVIOCGMTSLOTS answer the registers, and an
--- unplugged device fails read(2) with ENODEV and refuses open(2).
--- ==============================================================================

local M = {}

local EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
local SYN_REPORT, SYN_DROPPED = 0, 3
local ABS_MT_SLOT, ABS_MT_TOUCH_MAJOR = 0x2f, 0x30
local ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 0x35, 0x36, 0x39
local BTN_TOUCH, BTN_TOOL_TRIPLETAP = 0x14a, 0x14e
local SLOT_COUNT = 5

--- A touchpad as the input core and evdev present it to one reader.
--- @return table kernel
function M.new()
	local kernel = { slot = 0, reported_slot = 0, axes = {}, keys = {}, unread = {}, frame = {}, clock_us = 1000000,
		answers_registers = true, unplugged = false, opens = 0 }
	for index = 0, SLOT_COUNT - 1 do
		kernel.axes[index] = { [ABS_MT_TRACKING_ID] = -1, [ABS_MT_POSITION_X] = 0, [ABS_MT_POSITION_Y] = 0,
			[ABS_MT_TOUCH_MAJOR] = 0 }
	end

	local function queue(etype, code, value)
		kernel.frame[#kernel.frame + 1] = { etype, code, value }
	end

	--- One axis value of one slot, through the input core's filter.
	function kernel.abs(slot, code, value)
		if kernel.axes[slot][code] == value then return end
		kernel.axes[slot][code] = value
		if slot ~= kernel.reported_slot then
			queue(EV_ABS, ABS_MT_SLOT, slot)
			kernel.reported_slot = slot
		end
		kernel.slot = slot
		queue(EV_ABS, code, value)
	end

	function kernel.key(code, value)
		if (kernel.keys[code] or 0) == value then return end
		kernel.keys[code] = value
		queue(EV_KEY, code, value)
	end

	--- Ends a frame: delivered only when something changed.
	function kernel.syn()
		kernel.clock_us = kernel.clock_us + 10000
		if #kernel.frame == 0 then return end
		for _, event in ipairs(kernel.frame) do
			kernel.unread[#kernel.unread + 1] = { event[1], event[2], event[3], kernel.clock_us }
		end
		kernel.unread[#kernel.unread + 1] = { EV_SYN, SYN_REPORT, 0, kernel.clock_us }
		kernel.frame = {}
	end

	--- The reader fell behind while this frame was written: evdev replaces what
	--- it has not read, and the frame so far, with SYN_DROPPED; the rest of the
	--- frame follows it.
	function kernel.overflow()
		kernel.unread = { { EV_SYN, SYN_DROPPED, 0, kernel.clock_us } }
		kernel.frame = {}
	end

	--- Three fingers land on slots 0 to 2 at (x, y), (x + 200, y), (x + 400, y).
	--- @param order table|nil Slot order the hardware reports them in.
	function kernel.land(first_id, x, y, order)
		for _, slot in ipairs(order or { 0, 1, 2 }) do
			kernel.abs(slot, ABS_MT_TRACKING_ID, first_id + slot)
			kernel.abs(slot, ABS_MT_POSITION_X, x + slot * 200)
			kernel.abs(slot, ABS_MT_POSITION_Y, y)
		end
		kernel.key(BTN_TOUCH, 1); kernel.key(BTN_TOOL_TRIPLETAP, 1)
		kernel.syn()
	end

	--- The three fingers travel together by (dx, dy) per frame.
	function kernel.move(steps, dx, dy)
		for _ = 1, steps do
			for slot = 0, 2 do
				kernel.abs(slot, ABS_MT_POSITION_X, kernel.axes[slot][ABS_MT_POSITION_X] + dx)
				kernel.abs(slot, ABS_MT_POSITION_Y, kernel.axes[slot][ABS_MT_POSITION_Y] + dy)
			end
			kernel.syn()
		end
	end

	--- One finger travels alone by (dx, dy) per frame.
	function kernel.move_slot(slot, steps, dx, dy)
		for _ = 1, steps do
			kernel.abs(slot, ABS_MT_POSITION_X, kernel.axes[slot][ABS_MT_POSITION_X] + dx)
			kernel.abs(slot, ABS_MT_POSITION_Y, kernel.axes[slot][ABS_MT_POSITION_Y] + dy)
			kernel.syn()
		end
	end

	--- The fingers leave; `during` runs between the contacts and the keys.
	function kernel.lift(order, during)
		for _, slot in ipairs(order or { 0, 1, 2 }) do kernel.abs(slot, ABS_MT_TRACKING_ID, -1) end
		if during then during() end
		kernel.key(BTN_TOOL_TRIPLETAP, 0); kernel.key(BTN_TOUCH, 0)
		kernel.syn()
	end

	--- The reader backend over this kernel: read(2), EVIOCGABS and EVIOCGMTSLOTS.
	function kernel.backend(codec, requests)
		return {
			open = function()
				if kernel.unplugged then return nil, "open failed" end
				kernel.opens = kernel.opens + 1
				return 7
			end,
			close = function() return true end,
			read = function(_, count)
				-- A removed device: read(2) fails with ENODEV, as evdev answers it.
				if kernel.unplugged then return nil, "fatal", "read failed (errno=19)" end
				local event = table.remove(kernel.unread, 1)
				if not event then return nil, "would_block" end
				local bytes = codec.encode(event[1], event[2], event[3], codec.native_size(), event[4])
				assert(#bytes == count, "the reader asks one native input_event at a time")
				return bytes
			end,
			read_abs = function(_, request)
				requests[#requests + 1] = request
				if not kernel.answers_registers then return nil, "EVIOCGABS failed (errno=19)" end
				if request ~= 0x8018456f then return nil, "only ABS_MT_SLOT is modelled" end
				return { kernel.slot, 0, SLOT_COUNT - 1, 0, 0, 0 }
			end,
			read_mt_slots = function(_, request, code, count)
				requests[#requests + 1] = request
				if not kernel.answers_registers then return nil, "EVIOCGMTSLOTS failed (errno=19)" end
				local values = {}
				for index = 1, count do values[index] = kernel.axes[index - 1][code] end
				return values
			end,
		}
	end

	return kernel
end

return M
