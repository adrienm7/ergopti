--- tests/support/only_selector.lua

--- ==============================================================================
--- MODULE: Hammerspoon Focused-Test Module Selector
--- DESCRIPTION:
--- Resolves exact module targets or selects modules that can register a requested
--- plain-text test name before the runner requires them. This keeps focused
--- replays isolated while retaining a fail-closed full-load fallback.
--- ==============================================================================

local M = {}

--- Resolves a user-provided exact path or dotted name to one discovered module.
--- @param module_names string[] Discovered dotted module names.
--- @param only_filter string User-provided `--only` value.
--- @return string|nil module_name
local function find_exact_module(module_names, only_filter)
	local normalized_filter = only_filter:gsub("\\", "/")
	local is_lua_path = normalized_filter:sub(-4) == ".lua"

	for _, module_name in ipairs(module_names) do
		if only_filter == module_name then return module_name end
		if is_lua_path then
			local relative_path = module_name:gsub("%.", "/") .. ".lua"
			if normalized_filter == relative_path
				or normalized_filter:sub(-#relative_path - 1) == "/" .. relative_path then
				return module_name
			end
		end
	end
	return nil
end

--- Returns the final byte of a Lua long-bracket token at `at`.
--- @param source string Lua source.
--- @param at integer Opening bracket byte.
--- @return integer|nil final_byte
local function long_bracket_end(source, at)
	local equals = source:sub(at):match("^%[(=*)%[")
	if equals == nil then return nil end
	local close = "]" .. equals .. "]"
	local close_at = source:find(close, at + #equals + 2, true)
	if not close_at then return #source end
	return close_at + #close - 1
end

--- Masks comments and string bodies while preserving byte positions. This lets
--- discovery find real `helpers.it(...)` calls without accepting an assertion,
--- comment, or fixture string that merely mentions the requested test name.
--- @param source string Lua source.
--- @return string mask
local function code_mask(source)
	local chunks = {}
	local cursor = 1
	local code_start = 1
	local source_len = #source
	local function mask_through(final_byte)
		if code_start < cursor then
			chunks[#chunks + 1] = source:sub(code_start, cursor - 1)
		end
		chunks[#chunks + 1] = string.rep(" ", final_byte - cursor + 1)
		cursor = final_byte + 1
		code_start = cursor
	end

	while cursor <= source_len do
		local char = source:sub(cursor, cursor)
		if source:sub(cursor, cursor + 1) == "--" then
			local long_end = long_bracket_end(source, cursor + 2)
			if long_end then
				mask_through(long_end)
			else
				local newline = source:find("\n", cursor + 2, true)
				mask_through((newline or (source_len + 1)) - 1)
			end
		elseif char == '"' or char == "'" then
			local quote = char
			local final_byte = cursor + 1
			while final_byte <= source_len do
				local current = source:sub(final_byte, final_byte)
				if current == "\\" then
					final_byte = final_byte + 2
				elseif current == quote then
					break
				else
					final_byte = final_byte + 1
				end
			end
			mask_through(math.min(final_byte, source_len))
		elseif char == "[" then
			local long_end = long_bracket_end(source, cursor)
			if long_end then
				mask_through(long_end)
			else
				cursor = cursor + 1
			end
		else
			cursor = cursor + 1
		end
	end
	if code_start <= source_len then chunks[#chunks + 1] = source:sub(code_start) end
	return table.concat(chunks)
end

--- Parses a literal first argument at one helpers.it call.
--- @param source string Lua source.
--- @param at integer First non-whitespace argument byte.
--- @return string|nil literal Nil means the test name is runtime-generated.
local function parse_literal_name(source, at)
	local char = source:sub(at, at)
	if char == '"' or char == "'" then
		local final_byte = at + 1
		while final_byte <= #source do
			local current = source:sub(final_byte, final_byte)
			if current == "\\" then
				final_byte = final_byte + 2
			elseif current == char then
				local expression = source:sub(at, final_byte)
				local separator_at = final_byte + 1
				while source:sub(separator_at, separator_at):match("%s") do
					separator_at = separator_at + 1
				end
				if source:sub(separator_at, separator_at) ~= "," then return nil end
				local loader = load("return " .. expression, "=(only selector)", "t", {})
				if not loader then return nil end
				local ok, value = pcall(loader)
				if ok and type(value) == "string" then return value end
				return nil
			else
				final_byte = final_byte + 1
			end
		end
		return nil
	end
	if char == "[" then
		local equals = source:sub(at):match("^%[(=*)%[")
		if equals == nil then return nil end
		local content_at = at + #equals + 2
		local close = "]" .. equals .. "]"
		local close_at = source:find(close, content_at, true)
		if not close_at then return nil end
		local separator_at = close_at + #close
		while source:sub(separator_at, separator_at):match("%s") do
			separator_at = separator_at + 1
		end
		if source:sub(separator_at, separator_at) ~= "," then return nil end
		return source:sub(content_at, close_at - 1)
	end
	return nil
end

--- Classifies real helpers.it registrations in one module.
--- @param source string Lua source.
--- @return string[] literals
--- @return boolean has_dynamic_name
local function classify_test_names(source)
	local mask = code_mask(source)
	local literals = {}
	local has_dynamic_name = false
	local cursor = 1
	while true do
		local call_at = mask:find("helpers.it", cursor, true)
		if not call_at then break end
		local before = call_at > 1 and mask:sub(call_at - 1, call_at - 1) or ""
		local after_at = call_at + #"helpers.it"
		local after = mask:sub(after_at, after_at)
		if not before:match("[%w_]") and not after:match("[%w_]") then
			local open_at = after_at
			while mask:sub(open_at, open_at):match("%s") do open_at = open_at + 1 end
			if mask:sub(open_at, open_at) == "(" then
				local argument_at = open_at + 1
				while source:sub(argument_at, argument_at):match("%s") do
					argument_at = argument_at + 1
				end
				local literal = parse_literal_name(source, argument_at)
				if literal ~= nil then
					literals[#literals + 1] = literal
				else
					has_dynamic_name = true
				end
			end
		end
		cursor = call_at + #"helpers.it"
	end
	return literals, has_dynamic_name
end

--- Selects candidate modules for one test-name filter.
--- @param module_names string[] Discovered dotted module names.
--- @param only_filter string|nil Plain-text test-name filter.
--- @param source_loader function Function returning source text for a module.
--- @return string[] selected Candidate module names.
--- @return boolean narrowed Whether discovery was safely narrowed.
--- @return string|nil case_filter Filter passed to helpers.it, or nil for an exact module.
function M.select_modules(module_names, only_filter, source_loader)
	if type(only_filter) ~= "string" or only_filter == "" then
		return module_names, false, nil
	end

	local exact_module = find_exact_module(module_names, only_filter)
	if exact_module then return { exact_module }, true, nil end

	if type(source_loader) ~= "function" then
		return module_names, false, only_filter
	end

	local records = {}
	local literal_hit = false
	for _, module_name in ipairs(module_names) do
		local ok_source, source = pcall(source_loader, module_name)
		if not ok_source or type(source) ~= "string" then
			records[#records + 1] = { name = module_name, unreadable = true }
		else
			local literals, dynamic = classify_test_names(source)
			local matches = false
			for _, literal in ipairs(literals) do
				if literal:find(only_filter, 1, true) then matches = true; break end
			end
			if matches then literal_hit = true end
			records[#records + 1] = {
				name = module_name,
				dynamic = dynamic,
				matches = matches,
			}
		end
	end

	-- A dynamic target cannot be proven from source. Without one literal owner,
	-- fall back to every module and let helpers.it() decide at registration time.
	if not literal_hit then return module_names, false, only_filter end

	local selected = {}
	for _, record in ipairs(records) do
		if record.unreadable or record.dynamic or record.matches then
			selected[#selected + 1] = record.name
		end
	end
	return selected, #selected < #module_names, only_filter
end

--- Converts a zero-test focused replay into a visible failure.
--- @param results table Mutable helpers.get_results() record.
--- @param only_filter string|nil Focused filter.
--- @return boolean matched True unless a non-empty filter ran zero cases.
function M.require_match(results, only_filter)
	if type(only_filter) ~= "string" or only_filter == ""
		or type(results) ~= "table"
		or (tonumber(results.passed) or 0) > 0
		or (tonumber(results.failed) or 0) > 0 then
		return true
	end
	results.failed = 1
	results.failures = results.failures or {}
	results.failures[#results.failures + 1] = {
		name = "--only " .. only_filter,
		err = "no test case matched the requested --only filter",
	}
	return false
end

return M
