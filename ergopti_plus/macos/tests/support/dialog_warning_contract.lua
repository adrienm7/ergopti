--- tests/support/dialog_warning_contract.lua

--- ==============================================================================
--- MODULE: Native Warning Contract Fixture
--- DESCRIPTION:
--- Records native-shaped warnings without Cocoa or external work.
--- ==============================================================================

local M = {}





--- =========================================
--- =========================================
--- ======= 1/ Warning Port Ownership =======
--- =========================================
--- =========================================

--- Installs native-shaped warning boundaries on an existing captured facade.
--- @param dialog table Fixture-owned DialogUtil facade captured by the caller.
--- @return table observation Presented warning tuples and rejected alert calls.
function M.attach(dialog)
	local observation = { shown = {}, refused = 0 }
	dialog.alert = function(_x, _y, _callback, message)
		if type(message) ~= "string" then
			observation.refused = observation.refused + 1
			error("hs.dialog.webviewAlert: required message must be a string", 0)
		end
		-- Native alert construction returns zero values, not a Boolean ACK.
	end
	dialog.block_alert = function(title, message, button)
		assert(type(title) == "string" and type(message) == "string" and type(button) == "string",
			"A warning must present its title, message and acknowledgement button")
		observation.shown[#observation.shown + 1] = { title, message, button }
		return button
	end
	return observation
end

return M
