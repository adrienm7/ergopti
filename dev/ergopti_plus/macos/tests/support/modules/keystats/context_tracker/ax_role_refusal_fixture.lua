--- tests/support/modules/keystats/context_tracker/ax_role_refusal_fixture.lua

--- Adds native role failures to the existing public AX-focus lifecycle fixture.
local Base = require("tests.support.modules.keystats.context_tracker.ax_focus_refusal_fixture")
local M = {}

--- Restores the exact field port before either inherited finally retires owners.
---@param callback function Receives the existing real public runtime.
---@return ... results Original callback results.
function M.with_runtime(callback)
	return Base.with_runtime(function(runtime)
		local native = runtime.native
		-- This healthy setup read is included in the focus inventory, before faults.
		local app = assert(runtime.hs.axuielement.applicationElementForPID(native.pid))
		local field = assert(app:attributeValue("AXFocusedUIElement"))
		local original_attribute = field.attributeValue
		native.role_reads, native.subrole_reads = 0, 0
		native.refused_role_reads, native.refused_subrole_reads = 0, 0
		field.attributeValue = function(self, attribute)
			local role = attribute == "AXRole"
			local subrole = attribute == "AXSubrole"
			if role then native.role_reads = native.role_reads + 1 end
			if subrole then native.subrole_reads = native.subrole_reads + 1 end
			if (role and native.role_refused) or (subrole and native.subrole_refused) then
				if role then native.refused_role_reads = native.refused_role_reads + 1 end
				if subrole then native.refused_subrole_reads = native.refused_subrole_reads + 1 end
				return nil, "Messaging failed"
			end
			return original_attribute(self, attribute)
		end
		local values = table.pack(xpcall(function() return callback(runtime) end, debug.traceback))
		field.attributeValue = original_attribute
		if not values[1] then error(values[2], 0) end
		return table.unpack(values, 2, values.n)
	end)
end

return M
