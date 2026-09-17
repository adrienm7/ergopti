--- tests/support/physical_stream_frames.lua

--- Builds independent explicit baseline frames shared by delivery and transport tests.
local M = {}

--- Creates a fresh two-phase fixture with released keys and exact device identities.
---@param incarnation string Producer identity.
---@param lease string Lease identity.
---@param devices table|nil Device identities; defaults to two precise uint64 examples.
---@return table frames
function M.new(incarnation, lease, devices)
	devices = devices or { "18446744073709551613", "18446744073709551614" }
	local function envelope(kind)
		return { version = 1, kind = kind, incarnation = incarnation, lease = lease, coverage = "fixture_only" }
	end
	local rows = {}
	for _, device in ipairs(devices) do
		rows[#rows + 1] = { kind = "device", device = device, keyboard = true, elements = 4 }
		for _, usage in ipairs({ 1, 41, 44, 53 }) do
			rows[#rows + 1] = { kind = "key", device = device, usage = usage, cookie = usage,
				timestamp = "0", down = false }
		end
	end
	local opening, page = envelope("opened"), envelope("baseline")
	opening.baseline = { version = 1, boundary = "0", rows = #rows }
	page.boundary, page.offset, page.next, page.total, page.complete = "0", 0, #rows, #rows, true
	page.rows = rows
	return { opened = opening, page = page, ready = envelope("baseline_ready") }
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
