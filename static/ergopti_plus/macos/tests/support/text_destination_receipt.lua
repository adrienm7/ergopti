--- tests/support/text_destination_receipt.lua

--- Explicit native-boundary double for clipboard/timer ownership tests.
--- A receipt is issued only for the current destination and is revoked when the
--- fixture changes identity. Focus-lifecycle integration uses the real tracker.
local M = {}

function M.install()
	local element = {}
	local current = { generation = 1, pid = 101, window_id = 202, element = element }
	local issued = setmetatable({}, { __mode = "k" })
	local boundary = {}
	function boundary.capture_text_destination()
		if not current then return nil end
		local receipt = { generation = current.generation, pid = current.pid,
			window_id = current.window_id, element = current.element }
		issued[receipt] = true
		return receipt
	end
	function boundary.owns_text_destination(receipt)
		return issued[receipt] == true and current ~= nil
			and receipt.generation == current.generation and receipt.pid == current.pid
			and receipt.window_id == current.window_id and receipt.element == current.element
	end
	function boundary.revoke() current = nil end
	package.loaded["hotstrings.engine.expander.utils"] = boundary
	return boundary
end

return M
