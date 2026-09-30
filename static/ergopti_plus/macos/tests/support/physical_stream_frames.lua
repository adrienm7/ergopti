--- tests/support/physical_stream_frames.lua

--- Builds independent explicit baseline frames shared by delivery and transport tests.
local M = {}

-- The keyboard-page usages every default fixture device inventories; each
-- element's cookie equals its usage.
local DEFAULT_USAGES = { 1, 41, 44, 53 }

--- Creates a fresh two-phase fixture with released keys and exact device identities.
--- A device is either its decimal identity (an ANSI keyboard with the default
--- elements) or a table { id, keyboard, keyboard_type, keys = { { page, usage,
--- cookie }... } }.
---@param incarnation string Producer identity.
---@param lease string Lease identity.
---@param devices table|nil Devices; defaults to two precise uint64 examples.
---@return table frames
function M.new(incarnation, lease, devices)
	devices = devices or { "18446744073709551613", "18446744073709551614" }
	local function envelope(kind)
		return { version = 1, kind = kind, incarnation = incarnation, lease = lease, coverage = "fixture_only" }
	end
	local rows = {}
	for _, spec in ipairs(devices) do
		if type(spec) == "string" then spec = { id = spec } end
		local keyboard = spec.keyboard ~= false
		local keys = spec.keys
		if not keys then
			keys = {}
			for _, usage in ipairs(DEFAULT_USAGES) do keys[#keys + 1] = { page = 7, usage = usage, cookie = usage } end
		end
		rows[#rows + 1] = { kind = "device", device = spec.id, keyboard = keyboard,
			keyboard_type = spec.keyboard_type or (keyboard and "ansi" or "none"), elements = #keys }
		for _, key in ipairs(keys) do
			rows[#rows + 1] = { kind = "key", device = spec.id, page = key.page, usage = key.usage,
				cookie = key.cookie, timestamp = "0", down = false }
		end
	end
	local opening, page = envelope("opened"), envelope("baseline")
	opening.baseline = { version = 2, boundary = "0", rows = #rows }
	page.boundary, page.offset, page.next, page.total, page.complete = "0", 0, #rows, #rows, true
	page.rows = rows
	return { opened = opening, page = page, ready = envelope("baseline_ready") }
end

--- Resolves the fixture's keys the way the receiver's keycode callback must:
--- Escape (usage 41) and Space (usage 44) to their macOS keycodes, anything
--- else to nil and a reason, as the key-identity policy does.
---@param page number HID usage page.
---@param usage number HID usage.
---@return number|nil keycode
---@return string|nil reason
function M.keycode(page, usage)
	local keycode = page == 7 and ({ [41] = 53, [44] = 49 })[usage] or nil
	if keycode then return keycode end
	return nil, "unmapped_usage"
end

--- Completes the real receiver's baseline phase before an unrelated lifecycle test.
---@param receiver table Physical delivery receiver.
---@param frames table Explicit fixture frames.
function M.start(receiver, frames)
	receiver.open(frames.opened)
	assert(receiver.baseline(frames.page) == tostring(frames.page.next), "Fixture baseline was not acknowledged")
	assert(receiver.baseline(frames.ready) == nil, "Fixture completion requested a duplicate receipt")
end

return M
