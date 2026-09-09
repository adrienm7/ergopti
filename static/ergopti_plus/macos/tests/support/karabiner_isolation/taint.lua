--- tests/support/karabiner_isolation/taint.lua

--- ==============================================================================
--- MODULE: Karabiner Isolation taint
--- DESCRIPTION:
--- Pure source analysis shared by runtime guards and adversarial tests.
--- ==============================================================================

local syntax = require("tests.support.karabiner_isolation.syntax")
local has_stock_target = syntax.has_stock_target
local assignment_parts = syntax.assignment_parts
local contains_identifier = syntax.contains_identifier
local fold_constant_string = syntax.fold_constant_string
local has_folded_stock_target = syntax.has_folded_stock_target

local function is_tainted(text, tainted)
	if has_stock_target(text) then return true end
	for identifier in pairs(tainted) do
		if contains_identifier(text, identifier) then return true end
	end
	return false
end

local function collect_tainted_identifiers(statements, constants)
	local tainted = {}
	local changed = true
	while changed do
		changed = false
		for _, statement in ipairs(statements) do
			local names, rhs = assignment_parts(statement)
			local folded = names and fold_constant_string(rhs, constants) or nil
			if names and (is_tainted(rhs, tainted)
				or (folded ~= nil and has_stock_target(folded))
				or has_folded_stock_target(rhs, constants)) then
				for _, name in ipairs(names) do
					if not tainted[name] then
						tainted[name] = true
						changed = true
					end
				end
			end
		end
	end
	return tainted
end

--- Propagates taint across line-local Swift declarations inside class bodies.
--- The generic statement splitter deliberately keeps a whole `{ ... }` class
--- together, so a second line view is required for Foundation Process fields.
--- @param source string Comment-free source.
--- @param constants table Lowercase identifier-to-string map.
--- @param seed table Existing tainted identifiers.
--- @return table tainted Combined taint map.
local function collect_line_tainted_identifiers(source, constants, seed)
	local tainted = {}
	for identifier in pairs(seed or {}) do tainted[identifier] = true end
	local lines = {}
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
	local changed = true
	while changed do
		changed = false
		for _, line in ipairs(lines) do
			local comparison = line:find("==", 1, true)
				or line:find("!=", 1, true)
				or line:find("<=", 1, true)
				or line:find(">=", 1, true)
			local names, rhs
			if not comparison then names, rhs = assignment_parts(line) end
			local folded = names and fold_constant_string(rhs, constants) or nil
			if names and (is_tainted(rhs, tainted)
				or (folded ~= nil and has_stock_target(folded))
				or has_folded_stock_target(rhs, constants)) then
				for _, name in ipairs(names) do
					if not tainted[name] then
						tainted[name] = true
						changed = true
					end
				end
			end
		end
	end
	return tainted
end

return {
	is_tainted = is_tainted,
	collect_tainted_identifiers = collect_tainted_identifiers,
	collect_line_tainted_identifiers = collect_line_tainted_identifiers,
}
