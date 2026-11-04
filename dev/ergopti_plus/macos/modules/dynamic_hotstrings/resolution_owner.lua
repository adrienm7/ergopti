--- modules/dynamic_hotstrings/resolution_owner.lua

--- ==============================================================================
--- MODULE: Dynamic Resolution Ownership
--- DESCRIPTION:
--- Retains the lifecycle and semantic revision that admitted a resolver. User
--- callbacks may stop, restart or reconfigure their own input owner, so neither
--- returned text nor a preview lease may cross that boundary on the old receipt.
--- ==============================================================================

local M = {}

--- Creates one revision owner for an injected keymap group.
--- @param group string Registry group name.
--- @return table owner Capture, current and invalidate operations.
function M.new(group)
	local revision = {}
	local owner = {}

	--- Revokes resolutions before this owner's semantics change.
	function owner.invalidate() revision = {} end

	--- Captures the current start generation and optional input-owner revision.
	--- @param token table Start generation.
	--- @param keymap table Injected input owner.
	--- @param trigger string Admitted magic key.
	--- @return table receipt
	function owner.capture(token, keymap, trigger)
		return { revision = revision, token = token, keymap = keymap, trigger = trigger,
			input_revision = type(keymap.current_hotstring_lifecycle) == "function"
				and keymap.current_hotstring_lifecycle() or nil }
	end

	--- Rechecks ownership after resolver and policy callbacks return.
	--- @param receipt table Original resolution receipt.
	--- @param token table|nil Current start generation.
	--- @param keymap table|nil Current input owner.
	--- @param trigger string Current magic key.
	--- @param section string|nil Matched section, when a rule resolved.
	--- @return boolean current
	function owner.current(receipt, token, keymap, trigger, section)
		local function owns()
			return receipt.revision == revision and receipt.token == token
				and receipt.keymap == keymap and receipt.trigger == trigger
				and (receipt.input_revision == nil or (type(keymap.current_hotstring_lifecycle) == "function"
					and keymap.current_hotstring_lifecycle() == receipt.input_revision))
		end
		if not owns() then return false end
		if type(keymap.is_group_enabled) == "function" and not keymap.is_group_enabled(group) then return false end
		if section and type(keymap.is_section_enabled) == "function"
			and not keymap.is_section_enabled(group, section) then return false end
		return owns()
	end

	return owner
end

return M
