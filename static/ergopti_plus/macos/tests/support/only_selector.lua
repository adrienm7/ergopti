--- tests/support/only_selector.lua

--- ==============================================================================
--- MODULE: Hammerspoon Focused-Test Module Selector
--- DESCRIPTION:
--- Selects the test modules that can register a requested plain-text test name
--- before the runner requires them. This keeps focused replays isolated from
--- unrelated module-level setup while retaining a full-load fallback.
--- ==============================================================================

local M = {}

--- Returns true when a module registers at least one test whose name is not a
--- source literal. Such a module cannot be excluded from a focused replay by a
--- plain source search: the requested name may be assembled from a vector at
--- load time.
--- @param source string Lua source text.
--- @return boolean dynamic
local function has_dynamic_test_name(source)
	local cursor = 1
	while true do
		local call_at = source:find("helpers.it", cursor, true)
		if not call_at then return false end
		local open_at = source:find("%(", call_at + #"helpers.it")
		if not open_at then return false end
		local between = source:sub(call_at + #"helpers.it", open_at - 1)
		if between:match("^%s*$") then
			local argument_tail = source:sub(open_at + 1, open_at + 512)
			local first = argument_tail:match("^%s*(.)")
			local function_at = argument_tail:find("function", 1, true)
			local name_expression = function_at
				and argument_tail:sub(1, function_at - 1)
				or argument_tail
			if first ~= '"' and first ~= "'" and first ~= "["
				or name_expression:find("..", 1, true) then
				return true
			end
		end
		cursor = call_at + #"helpers.it"
	end
end

--- Selects candidate modules for one test-name filter.
--- @param module_names string[] Discovered dotted module names.
--- @param only_filter string|nil Plain-text test-name filter.
--- @param source_loader function Function returning source text for a module.
--- @return string[] selected Candidate module names.
--- @return boolean narrowed Whether discovery was safely narrowed.
function M.select_modules(module_names, only_filter, source_loader)
	if type(only_filter) ~= "string" or only_filter == "" then
		return module_names, false
	end
	if type(source_loader) ~= "function" then
		return module_names, false
	end

	local selected = {}
	local identifiable_candidate_count = 0
	for _, module_name in ipairs(module_names) do
		local ok_source, source = pcall(source_loader, module_name)
		if not ok_source or type(source) ~= "string" then
			-- An unreadable candidate cannot be safely excluded
			selected[#selected + 1] = module_name
		elseif source:find(only_filter, 1, true) or has_dynamic_test_name(source) then
			-- Dynamic registrations remain candidates even when the complete
			-- runtime name is not present as one contiguous source literal.
			selected[#selected + 1] = module_name
			identifiable_candidate_count = identifiable_candidate_count + 1
		end
	end

	-- If neither a literal nor a dynamic registration can own the name, retain
	-- the original load-all behavior. Filtering at helpers.it() remains final.
	if identifiable_candidate_count == 0 then return module_names, false end
	return selected, #selected < #module_names
end

return M
