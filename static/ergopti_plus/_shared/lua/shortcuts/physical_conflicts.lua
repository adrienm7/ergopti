--- _shared/lua/shortcuts/physical_conflicts.lua

--- Pure conflict matching; native source and configuration witnesses stay with hosts.
local M = {}
local function plain(value) return type(value) == "table" and getmetatable(value) == nil end
local function modifiers_equal(left, right)
	if not plain(left) or not plain(right) then return false end
	for _, role in ipairs({ "ctrl", "alt", "shift", "super" }) do
		if (left[role] == true) ~= (right[role] == true) then return false end
	end
	return true
end

--- Tests one physical action against exact, already-observed owner claims.
--- None preserves native intent rather than acquiring another owner's output.
--- @param request table Canonical slot, native code, modifiers, aliases and action.
--- @param claims table Detached native/logical/prefix claims from every owner.
--- @return boolean|nil collision Nil denotes malformed, incomplete input.
--- @return string|nil binding The original conflicting binding identity.
function M.conflicts(request, claims)
	if not plain(request) or not plain(claims) or type(request.slot) ~= "string"
		or type(request.action) ~= "string" or type(request.code) ~= "number" or not plain(request.mods)
		or not plain(request.aliases) then return nil end
	if request.action == "none" then return false end
	for _, claim in ipairs(claims) do
		if not plain(claim) or type(claim.binding) ~= "string" then return nil end
		if claim.binding ~= "keyboard__" .. request.slot then
			if claim.kind == "logical" then
				if type(claim.key) ~= "string" or not plain(claim.mods) then return nil end
				if request.aliases[claim.key] and modifiers_equal(request.mods, claim.mods) then return true, claim.binding end
			elseif claim.kind == "chord" then
				if type(claim.code) ~= "number" or not plain(claim.mods) then return nil end
				if claim.code == request.code and modifiers_equal(request.mods, claim.mods) then return true, claim.binding end
			elseif claim.kind == "prefix" then
				if not plain(claim.codes) then return nil end
				for _, code in ipairs(claim.codes) do
					if type(code) ~= "number" then return nil end
					if code == request.code then
						-- The host has proved the plain-key domain only. Modifier exceptions
						-- remain unknown instead of becoming guessed native collisions.
						if claim.unmodified_only then
							for _, role in ipairs({ "ctrl", "alt", "shift", "super" }) do
								if request.mods[role] then return nil end
							end
						end
						return true, claim.binding
					end
				end
			else return nil end
		end
	end
	return false
end
return M
