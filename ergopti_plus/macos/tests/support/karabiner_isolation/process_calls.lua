--- tests/support/karabiner_isolation/process_calls.lua

--- ==============================================================================
--- MODULE: Karabiner Isolation process calls
--- DESCRIPTION:
--- Pure source analysis shared by runtime guards and adversarial tests.
--- ==============================================================================

local syntax = require("tests.support.karabiner_isolation.syntax")
local LAUNCHCTL_MUTATIONS = syntax.LAUNCHCTL_MUTATIONS
local has_word = syntax.has_word
local has_stock_target = syntax.has_stock_target
local assignment_parts = syntax.assignment_parts
local contains_identifier = syntax.contains_identifier
local fold_constant_string = syntax.fold_constant_string
local folded_constant_values = syntax.folded_constant_values

--- Produces one searchable view containing source and constant-folded values.
--- @param statement string Comment-free source statement.
--- @param constants table|nil Lowercase identifier-to-string map.
--- @param additional_values table|nil Context-specific folded values.
--- @return string lower Normalized lowercase search text.
local function searchable_statement(statement, constants, additional_values)
	local values = folded_constant_values(statement, constants or {}, true)
	for _, value in ipairs(additional_values or {}) do values[#values + 1] = value end
	local expanded = statement
	if #values > 0 then expanded = expanded .. "\n" .. table.concat(values, "\n") end
	return expanded:lower():gsub("%s+", " ")
end

--- Classifies destructive process-control operations aimed at a tainted target.
--- @param statement string Comment-free source statement.
--- @param constants table|nil Lowercase identifier-to-string map.
--- @param executable_values table|nil Folded process executable values.
--- @return string|nil label Destructive operation label, or nil when read-only.
local function destructive_label(statement, constants, executable_values)
	local lower = searchable_statement(statement, constants, executable_values)
	if lower:match("^%s*logger[%w_]*%s*%.") then return nil end
	if has_word(lower, "launchctl") then
		for _, mutation in ipairs(LAUNCHCTL_MUTATIONS) do
			if has_word(lower, mutation) then return "launchctl " .. mutation .. " stock Karabiner" end
		end
	end
	if has_word(lower, "pkill") then return "pkill stock Karabiner" end
	if has_word(lower, "killall") then return "killall stock Karabiner" end
	if has_word(lower, "xargs") and has_word(lower, "kill") then
		return "PID probe piped to kill"
	end
	if lower:find(":%s*kill9?%s*%(")
		or lower:find("%.%s*kill9?%s*%(")
		or lower:find(":%s*killpg%s*%(")
		or lower:find("%.%s*killpg%s*%(")
		or lower:match("^%s*killpg%s*%(")
		or lower:match("^%s*kill%s")
		or lower:find("[;|&]%s*kill%s")
		or lower:find("/bin/kill", 1, true)
		or lower:find("[\"']%s*kill%s+%-") then
		return "stock Karabiner kill"
	end
	if lower:find(":%s*terminate%s*%(")
		or lower:find(":%s*forceterminate%s*%(") then
		return "stock Karabiner termination"
	end
	return nil
end

--- Classifies stock GUI launches that require the explicit open capability.
--- @param statement string Comment-free source statement.
--- @param constants table|nil Lowercase identifier-to-string map.
--- @param executable_values table|nil Folded process executable values.
--- @return string|nil label GUI launch label, or nil when absent.
local function stock_gui_launch_label(statement, constants, executable_values)
	local lower = searchable_statement(statement, constants, executable_values)
	if lower:match("^%s*logger[%w_]*%s*%.") then return nil end
	local resolved_open = false
	for _, executable in ipairs(executable_values or {}) do
		local normalized = executable:lower()
		if normalized == "open" or normalized:match("/open$") then
			resolved_open = true
			break
		end
	end
	if lower:find("launchorfocus", 1, true)
		or lower:find("applauncher.launch", 1, true)
		or lower:find("windowmanager.launch", 1, true)
		or lower:find("open -a", 1, true)
		or lower:find("/usr/bin/open", 1, true)
		or resolved_open then
		return "stock Karabiner GUI launch outside explicit capability"
	end
	return nil
end

local function call_argument(statement, call_pattern, wanted_index)
	local _, open_index = statement:lower():find(call_pattern .. "%s*%(")
	if not open_index then return nil end
	local start_index = open_index + 1
	local argument_start = start_index
	local argument_index = 1
	local depth = 0
	local quote = nil
	local escaped = false
	for index = start_index, #statement do
		local char = statement:sub(index, index)
		if quote then
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == quote then
				quote = nil
			end
		elseif char == '"' or char == "'" then
			quote = char
		elseif char == "(" or char == "{" or char == "[" then
			depth = depth + 1
		elseif char == ")" or char == "}" or char == "]" then
			if depth == 0 then
				if argument_index == wanted_index then
					return statement:sub(argument_start, index - 1)
				end
				return nil
			end
			depth = math.max(0, depth - 1)
		elseif char == "," and depth == 0 then
			if argument_index == wanted_index then
				return statement:sub(argument_start, index - 1)
			end
			argument_index = argument_index + 1
			argument_start = index + 1
		end
	end
	if argument_index == wanted_index then return statement:sub(argument_start) end
	return nil
end

local function first_call_argument(statement, call_pattern)
	return call_argument(statement, call_pattern, 1)
end

local CANONICAL_KARABINER_CLI_LOWER =
	"/library/application support/org.pqrs/karabiner-elements/bin/karabiner_cli"

local CANONICAL_CLI_SYMBOL_PATTERNS = {
	"%f[%w_]kepaths%s*%.%s*cli%f[^%w_]",
	"%f[%w_]kcanonicalkarabinerclipath%f[^%w_]",
}

--- Reports whether an expression resolves to the sole canonical CLI executable.
--- @param expression string Executable expression.
--- @param constants table Lowercase identifier-to-string map.
--- @param aliases table|nil Identifiers proven to alias the canonical CLI.
--- @return boolean canonical Whether the expression denotes only karabiner_cli.
local function is_canonical_cli_expression(expression, constants, aliases)
	local lower = expression:lower()
	for _, pattern in ipairs(CANONICAL_CLI_SYMBOL_PATTERNS) do
		if lower:find(pattern) then return true end
	end
	for identifier in pairs(aliases or {}) do
		if contains_identifier(lower, identifier) then return true end
	end

	local values = folded_constant_values(expression, constants, true)
	local whole = fold_constant_string(expression, constants)
	if whole ~= nil then values[#values + 1] = whole end
	for _quote, literal in expression:gmatch("([\"'])(.-)%1") do
		values[#values + 1] = literal
	end
	for _, value in ipairs(values) do
		if value:lower() == CANONICAL_KARABINER_CLI_LOWER then return true end
	end
	return false
end

--- Propagates canonical CLI aliases without inferring ownership from a PID.
--- @param statements table Comment-free source statements.
--- @param constants table Lowercase identifier-to-string map.
--- @return table aliases Lowercase identifiers proven to denote the CLI path.
local function collect_canonical_cli_aliases(statements, constants)
	local aliases = {}
	local changed = true
	while changed do
		changed = false
		for _, statement in ipairs(statements) do
			local names, rhs = assignment_parts(statement)
			if names and is_canonical_cli_expression(rhs, constants, aliases) then
				for _, name in ipairs(names) do
					if not aliases[name] then
						aliases[name] = true
						changed = true
					end
				end
			end
		end
	end
	return aliases
end

--- Splits a Lua or Swift collection into top-level items.
--- @param expression string Table/array expression, optionally after a label.
--- @return table|nil items Collection members, or nil when shape is ambiguous.
local function collection_items(expression)
	local first = expression:find("[%[{]")
	if not first then return nil end
	local opener = expression:sub(first, first)
	local closer = opener == "{" and "}" or "]"
	local items = {}
	local item_start = first + 1
	local depth = 0
	local quote = nil
	local escaped = false
	for index = first + 1, #expression do
		local char = expression:sub(index, index)
		if quote then
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == quote then
				quote = nil
			end
		elseif char == '"' or char == "'" then
			quote = char
		elseif char == "(" or char == "{" or char == "[" then
			depth = depth + 1
		elseif char == ")" or char == "}" or char == "]" then
			if char == closer and depth == 0 then
				local item = expression:sub(item_start, index - 1):match("^%s*(.-)%s*$")
				if item ~= "" then items[#items + 1] = item end
				if expression:sub(index + 1):match("^%s*$") == nil then return nil end
				return items
			end
			depth = math.max(0, depth - 1)
		elseif char == "," and depth == 0 then
			local item = expression:sub(item_start, index - 1):match("^%s*(.-)%s*$")
			if item == "" then return nil end
			items[#items + 1] = item
			item_start = index + 1
		end
	end
	return nil
end

--- Proves the complete argv shape for the only permitted CLI variable commands.
--- @param expression string Lua table or Swift array expression.
--- @param constants table Lowercase identifier-to-string map.
--- @param includes_executable boolean Whether argv[0] is present.
--- @param aliases table Canonical CLI aliases.
--- @return boolean valid Whether the shape is exactly CLI, flag, payload.
local function is_exact_variable_arguments(expression, constants, includes_executable, aliases)
	local items = collection_items(expression)
	local expected_count = includes_executable and 3 or 2
	if not items or #items ~= expected_count then return false end
	local flag_index = includes_executable and 2 or 1
	if includes_executable
		and not is_canonical_cli_expression(items[1], constants, aliases)
		and items[1]:lower():match("^%s*clipath%s*$") == nil then
		return false
	end
	local flag = fold_constant_string(items[flag_index], constants)
	if flag ~= "--set-variables" and flag ~= "--get-variable" then return false end
	return items[flag_index + 1]:find("%S") ~= nil
end

local CLI_BOUNDARY_OFFENDER = "karabiner_cli command outside exact variable boundary"

--- Tracks argv arrays proven to contain only CLI, a variable flag and payload.
--- @param statements table Comment-free source statements.
--- @param constants table Lowercase identifier-to-string map.
--- @param aliases table Canonical CLI aliases.
--- @return table arrays Lowercase identifiers carrying an exact argv array.
local function collect_exact_cli_argument_arrays(statements, constants, aliases)
	local arrays = {}
	for _, statement in ipairs(statements) do
		local arguments = first_call_argument(
			statement,
			"%f[%w_]duplicateleasearguments"
		)
		local name = statement:lower():match(
			"%f[%w_]let%s+([%a_][%w_]*)%s*=%s*duplicateleasearguments"
		)
		if name and arguments
			and is_exact_variable_arguments(arguments, constants, true, aliases) then
			arrays[name] = true
		end
	end

	local changed = true
	while changed do
		changed = false
		for _, statement in ipairs(statements) do
			local names, rhs = assignment_parts(statement)
			local source_name = rhs and rhs:lower():match("^%s*([%a_][%w_]*)%s*;?%s*$")
			if names and source_name and arrays[source_name] then
				for _, name in ipairs(names) do
					if not arrays[name] then
						arrays[name] = true
						changed = true
					end
				end
			end
		end
	end
	return arrays
end

--- Correlates a POSIX argv pointer with its exact validated backing array.
--- @param statement string Statement containing the buffer closure and spawn.
--- @param arguments string posix_spawn argv expression.
--- @param arrays table Identifiers carrying exact CLI argument arrays.
--- @return boolean valid Whether the pointer comes from one such array.
local function uses_exact_cli_argument_buffer(statement, arguments, arrays)
	local lower = statement:lower()
	local posix_at = lower:find("%f[%w_]posix_spawnp?%s*%(")
	if not posix_at then return false end
	local cursor = 1
	while true do
		local start_at, end_at, candidate_array, candidate_buffer = lower:find(
			"([%a_][%w_]*)%.%s*withunsafemutablebufferpointer%s*{%s*([%a_][%w_]*)%s+in",
			cursor
		)
		if not start_at or start_at >= posix_at then break end
		local exact_array = arrays[candidate_array]
		if not exact_array then
			local source_name = lower:match(
				"%f[%w_]var%s+" .. candidate_array .. "%s*=%s*([%a_][%w_]*)"
			)
			exact_array = source_name and arrays[source_name] or false
		end
		if exact_array and arguments:lower():find(
			"%f[%w_]" .. candidate_buffer .. "%s*%.%s*baseaddress%f[^%w_]"
		) then
			return true
		end
		cursor = end_at + 1
	end
	return false
end

--- Detects an exact executable literal inside URL/path wrapper expressions.
--- @param expression string Executable expression.
--- @param constants table Lowercase identifier-to-string map.
--- @param expected string Lowercase absolute path.
--- @return boolean matches Whether the expression resolves to that path.
local function has_exact_executable(expression, constants, expected)
	local values = folded_constant_values(expression, constants, true)
	local whole = fold_constant_string(expression, constants)
	if whole ~= nil then values[#values + 1] = whole end
	for _quote, literal in expression:gmatch("([\"'])(.-)%1") do
		values[#values + 1] = literal
	end
	for _, value in ipairs(values) do
		if value:lower() == expected then return true end
	end
	return false
end

--- Detects a resolved stock executable while allowing only the documented CLI.
--- @param expression string Executable expression or URL initializer.
--- @param constants table Lowercase identifier-to-string map.
--- @return boolean forbidden Whether launching this value controls shared stock state.
local function has_forbidden_stock_executable(expression, constants)
	local values = folded_constant_values(expression, constants, true)
	local whole = fold_constant_string(expression, constants)
	if whole ~= nil then values[#values + 1] = whole end
	for _quote, literal in expression:gmatch("([\"'])(.-)%1") do
		values[#values + 1] = literal
	end
	for _, value in ipairs(values) do
		local lower = value:lower()
		if has_stock_target(lower) and lower ~= CANONICAL_KARABINER_CLI_LOWER then
			return true
		end
	end
	return false
end

return {
	destructive_label = destructive_label,
	stock_gui_launch_label = stock_gui_launch_label,
	call_argument = call_argument,
	first_call_argument = first_call_argument,
	CANONICAL_KARABINER_CLI_LOWER = CANONICAL_KARABINER_CLI_LOWER,
	is_canonical_cli_expression = is_canonical_cli_expression,
	collect_canonical_cli_aliases = collect_canonical_cli_aliases,
	collection_items = collection_items,
	is_exact_variable_arguments = is_exact_variable_arguments,
	CLI_BOUNDARY_OFFENDER = CLI_BOUNDARY_OFFENDER,
	collect_exact_cli_argument_arrays = collect_exact_cli_argument_arrays,
	uses_exact_cli_argument_buffer = uses_exact_cli_argument_buffer,
	has_exact_executable = has_exact_executable,
	has_forbidden_stock_executable = has_forbidden_stock_executable,
}
