--- modules/shortcuts/actions/text_transform_grace.lua

--- ==============================================================================
--- MODULE: Transform Clipboard Grace
--- DESCRIPTION:
--- A native paste cannot be retracted after handoff. A fenced transform retains
--- its exact clipboard and completion timer through the fixed post-paste grace;
--- cancellation before handoff has no grace debt.
--- ==============================================================================

local M = {}

--- Installs cleanup-only settlement independent of a revoked business receipt.
--- @param owner table Exact Text transform owner.
--- @param ports table Native cancellation, timer and settlement callbacks.
function M.install(owner, ports)
	local settling = false
	owner.on_quiesce = function()
		if owner.synthetic_pending ~= true and (owner.transform_restore_after or 0) <= ports.now() then
			owner.transform_restore_after = nil
			return false
		end
		if settling then return true, false end
		settling = true
		local settled = true
		local snapshot = {}
		for _, entry in pairs(owner.timers) do
			if entry ~= owner.transform_grace_entry then snapshot[#snapshot + 1] = entry end
		end
		for _, entry in ipairs(snapshot) do
			if ports.cancel(entry) ~= true then settled = false end
		end
		if owner.synthetic_pending == true then pcall(ports.cancel_native, owner.synthetic_tx) end
		if owner.synthetic_pending == true then
			settling = false
			return true, false
		end
		local remaining = (owner.transform_restore_after or 0) - ports.now()
		if remaining > 0 and owner.clipboard_owned == true then
			if not settled then settling = false; return true, false end
			owner.completion_only = true
			if owner.transform_grace_entry == nil then
				local armed, _, entry = ports.schedule(remaining, function() ports.settle() end)
				if armed == true or (entry and owner.timers[entry.id] == entry) then
					owner.transform_grace_entry = entry
				end
			end
			settling = false
			return true, false
		end
		owner.transform_restore_after = nil
		settling = false
		return false
	end
end

return M
