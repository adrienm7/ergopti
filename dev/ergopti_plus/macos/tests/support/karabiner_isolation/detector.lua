--- tests/support/karabiner_isolation/detector.lua

--- ==============================================================================
--- MODULE: Karabiner Isolation detector
--- DESCRIPTION:
--- Pure source analysis shared by runtime guards and adversarial tests.
--- ==============================================================================

local syntax = require("tests.support.karabiner_isolation.syntax")
local taint = require("tests.support.karabiner_isolation.taint")
local process_calls = require("tests.support.karabiner_isolation.process_calls")
local without_comments = syntax.without_comments
local OWNERSHIP_PATTERNS = syntax.OWNERSHIP_PATTERNS
local PROCESS_SPAWN_CALL_PATTERNS = syntax.PROCESS_SPAWN_CALL_PATTERNS
local has_stock_target = syntax.has_stock_target
local split_statements = syntax.split_statements
local contains_identifier = syntax.contains_identifier
local fold_constant_string = syntax.fold_constant_string
local has_folded_stock_target = syntax.has_folded_stock_target
local collect_constant_strings = syntax.collect_constant_strings
local is_tainted = taint.is_tainted
local collect_tainted_identifiers = taint.collect_tainted_identifiers
local collect_line_tainted_identifiers = taint.collect_line_tainted_identifiers
local destructive_label = process_calls.destructive_label
local stock_gui_launch_label = process_calls.stock_gui_launch_label
local call_argument = process_calls.call_argument
local first_call_argument = process_calls.first_call_argument
local CANONICAL_KARABINER_CLI_LOWER = process_calls.CANONICAL_KARABINER_CLI_LOWER
local is_canonical_cli_expression = process_calls.is_canonical_cli_expression
local collect_canonical_cli_aliases = process_calls.collect_canonical_cli_aliases
local collection_items = process_calls.collection_items
local is_exact_variable_arguments = process_calls.is_exact_variable_arguments
local CLI_BOUNDARY_OFFENDER = process_calls.CLI_BOUNDARY_OFFENDER
local collect_exact_cli_argument_arrays = process_calls.collect_exact_cli_argument_arrays
local uses_exact_cli_argument_buffer = process_calls.uses_exact_cli_argument_buffer
local has_exact_executable = process_calls.has_exact_executable
local has_forbidden_stock_executable = process_calls.has_forbidden_stock_executable

local function find_offenders(source)
	local code = without_comments(source)
	local lower = code:lower()
	local statements = split_statements(code)
	local constants = collect_constant_strings(statements)
	local cli_aliases = collect_canonical_cli_aliases(statements, constants)
	local exact_cli_argument_arrays = collect_exact_cli_argument_arrays(
		statements,
		constants,
		cli_aliases
	)
	local has_native_cli_contract = lower:find(CANONICAL_KARABINER_CLI_LOWER, 1, true) ~= nil
	local function is_unit_cli_expression(expression)
		return is_canonical_cli_expression(expression, constants, cli_aliases)
			or (has_native_cli_contract and contains_identifier(expression, "clipath"))
	end
	local tainted = collect_line_tainted_identifiers(
		code,
		constants,
		collect_tainted_identifiers(statements, constants)
	)
	local offenders = {}
	local seen = {}
	local swift_processes = {}
	local function add(label)
		if not seen[label] then
			seen[label] = true
			offenders[#offenders + 1] = label
		end
	end

	for _, rule in ipairs(OWNERSHIP_PATTERNS) do
		if lower:find(rule.pattern) then add(rule.label) end
	end
	for _, statement in ipairs(statements) do
		local executable_arguments = {}
		local executable_values = {}
		for call_index, call_pattern in ipairs(PROCESS_SPAWN_CALL_PATTERNS) do
			local executable = first_call_argument(statement, call_pattern)
			if executable then
				executable_arguments[#executable_arguments + 1] = executable
				local value = fold_constant_string(executable, constants)
				if value ~= nil then executable_values[#executable_values + 1] = value end
				if is_canonical_cli_expression(executable, constants, cli_aliases) then
					local arguments_index = call_index == 2 and 3 or 2
					local arguments = call_argument(statement, call_pattern, arguments_index)
					if not arguments
						or not is_exact_variable_arguments(
							arguments, constants, false, cli_aliases) then
						add(CLI_BOUNDARY_OFFENDER)
					end
				end
			end
		end
		-- hs.task.new is commonly passed as the first argument to pcall rather
		-- than called directly. Treat that call shape as a real spawn boundary;
		-- otherwise a multiline alias can bypass every canonical-CLI assertion.
		local protected_target = call_argument(statement, "%f[%w_]pcall", 1)
		if protected_target
			and protected_target:lower():match("^%s*hs%s*%.%s*task%s*%.%s*new%s*$") then
			local executable = call_argument(statement, "%f[%w_]pcall", 2)
			if executable and is_canonical_cli_expression(executable, constants, cli_aliases) then
				local arguments = call_argument(statement, "%f[%w_]pcall", 4)
				if not arguments
					or not is_exact_variable_arguments(
						arguments, constants, false, cli_aliases) then
					add(CLI_BOUNDARY_OFFENDER)
				end
			end
		end
		local raw_arguments = first_call_argument(
			statement,
			"%f[%w_]duplicateleasearguments"
		)
		if raw_arguments then
			local raw_items = collection_items(raw_arguments)
			if raw_items and #raw_items > 0
				and (is_canonical_cli_expression(raw_items[1], constants, cli_aliases)
					or raw_items[1]:lower():match("^%s*clipath%s*$") ~= nil)
				and not is_exact_variable_arguments(
					raw_arguments, constants, true, cli_aliases) then
				add(CLI_BOUNDARY_OFFENDER)
			end
		end
		local posix_executable = call_argument(
			statement,
			"%f[%w_]posix_spawnp?",
			2
		)
		if posix_executable then
			if has_forbidden_stock_executable(posix_executable, constants) then
				add("stock Karabiner process auto-launch")
			elseif is_canonical_cli_expression(posix_executable, constants, cli_aliases)
				or (has_native_cli_contract
					and posix_executable:lower():match("^%s*clipath%s*$") ~= nil) then
				local posix_arguments = call_argument(
					statement,
					"%f[%w_]posix_spawnp?",
					5
				)
				if not posix_arguments
					or (not is_exact_variable_arguments(
							posix_arguments, constants, true, cli_aliases)
						and not uses_exact_cli_argument_buffer(
							statement, posix_arguments, exact_cli_argument_arrays)) then
					add(CLI_BOUNDARY_OFFENDER)
				end
			end
		end

		local new_process = statement:match("^%s*let%s+([%a_][%w_]*)%s*=%s*Process%s*%(")
			or statement:match("^%s*var%s+([%a_][%w_]*)%s*=%s*Process%s*%(")
		if new_process then swift_processes[new_process:lower()] = {} end
		local process_name, process_expression = statement:match(
			"^%s*([%a_][%w_]*)%.%s*executableURL%s*=%s*(.-)%s*;?%s*$"
		)
		if process_name then
			local key = process_name:lower()
			local record = swift_processes[key] or {}
			record.stock = has_forbidden_stock_executable(process_expression, constants)
			record.cli = is_unit_cli_expression(process_expression)
			record.kill = has_exact_executable(process_expression, constants, "/bin/kill")
			swift_processes[key] = record
		end
		local arguments_name, arguments_expression = statement:match(
			"^%s*([%a_][%w_]*)%.%s*arguments%s*=%s*(.-)%s*;?%s*$"
		)
		if arguments_name then
			local key = arguments_name:lower()
			local record = swift_processes[key] or {}
			record.arguments_tainted = is_tainted(arguments_expression, tainted)
				or has_folded_stock_target(arguments_expression, constants)
			record.valid_cli_arguments = is_exact_variable_arguments(
				arguments_expression, constants, false, cli_aliases)
			swift_processes[key] = record
		end
		local run_process = statement:match("([%a_][%w_]*)%.%s*run%s*%(")
		if run_process then
			local record = swift_processes[run_process:lower()]
			if record then
				if record.stock then add("stock Karabiner process auto-launch") end
				if record.cli and not record.valid_cli_arguments then
					add(CLI_BOUNDARY_OFFENDER)
				end
				if record.kill and record.arguments_tainted then
					add("stock Karabiner kill")
				end
			end
		end
		local static_process_executable = first_call_argument(
			statement,
			"%f[%w_]process%s*%.%s*run"
		)
		if static_process_executable then
			if has_forbidden_stock_executable(static_process_executable, constants) then
				add("stock Karabiner process auto-launch")
			elseif is_unit_cli_expression(static_process_executable) then
				local arguments = call_argument(
					statement,
					"%f[%w_]process%s*%.%s*run",
					2
				)
				arguments = arguments and arguments:gsub("^%s*arguments%s*:%s*", "") or nil
				if not arguments
					or not is_exact_variable_arguments(
						arguments, constants, false, cli_aliases) then
					add(CLI_BOUNDARY_OFFENDER)
				end
			elseif has_exact_executable(static_process_executable, constants, "/bin/kill") then
				local arguments = call_argument(
					statement,
					"%f[%w_]process%s*%.%s*run",
					2
				)
				if arguments and is_tainted(arguments, tainted) then
					add("stock Karabiner kill")
				end
			end
		end

		if is_tainted(statement, tainted)
			or has_folded_stock_target(statement, constants) then
			local label = destructive_label(statement, constants, executable_values)
			if label then add(label) end
			local launch_label = stock_gui_launch_label(statement, constants, executable_values)
			if launch_label then add(launch_label) end
		end

		for _, executable in ipairs(executable_arguments) do
			if executable and (is_tainted(executable, tainted)
				or has_folded_stock_target(executable, constants)) then
				add("stock Karabiner process auto-launch")
			end
		end
	end

	-- Foundation Process objects commonly live inside a Swift class whose braces
	-- form one generic statement. Scan their field assignments line-by-line so
	-- executable and argv provenance cannot be separated by that outer scope.
	local line_processes = {}
	for line in (code .. "\n"):gmatch("([^\n]*)\n") do
		local new_process = line:match("%f[%w_]let%s+([%a_][%w_]*)%s*=%s*Process%s*%(")
			or line:match("%f[%w_]var%s+([%a_][%w_]*)%s*=%s*Process%s*%(")
		if new_process then line_processes[new_process:lower()] = {} end
		local process_name, process_expression = line:match(
			"([%a_][%w_]*)%.%s*executableURL%s*=%s*(.-)%s*;?%s*$"
		)
		if process_name then
			local key = process_name:lower()
			local record = line_processes[key] or {}
			record.stock = has_forbidden_stock_executable(process_expression, constants)
			record.cli = is_unit_cli_expression(process_expression)
			record.kill = has_exact_executable(process_expression, constants, "/bin/kill")
			line_processes[key] = record
		end
		local arguments_name, arguments_expression = line:match(
			"([%a_][%w_]*)%.%s*arguments%s*=%s*(.-)%s*;?%s*$"
		)
		if arguments_name then
			local key = arguments_name:lower()
			local record = line_processes[key] or {}
			record.arguments_tainted = is_tainted(arguments_expression, tainted)
				or has_folded_stock_target(arguments_expression, constants)
			record.valid_cli_arguments = is_exact_variable_arguments(
				arguments_expression, constants, false, cli_aliases)
			line_processes[key] = record
		end
		local run_process = line:match("([%a_][%w_]*)%.%s*run%s*%(")
		if run_process then
			local record = line_processes[run_process:lower()]
			if record then
				if record.stock then add("stock Karabiner process auto-launch") end
				if record.cli and not record.valid_cli_arguments then
					add(CLI_BOUNDARY_OFFENDER)
				end
				if record.kill and record.arguments_tainted then add("stock Karabiner kill") end
			end
		end
	end
	return offenders
end

local function mask_explicit_open_gui_capability(source)
	local signature = "function M.open_gui()"
	local cursor = 1
	local parts = {}
	local capability_count = 0
	local forbidden_inside = {}
	while true do
		local start_at = source:find(signature, cursor, true)
		if not start_at then
			parts[#parts + 1] = source:sub(cursor)
			break
		end
		parts[#parts + 1] = source:sub(cursor, start_at - 1)
		local line_end = source:find("\n", start_at, true) or #source
		local signature_line = source:sub(start_at, line_end)
		local end_at
		if signature_line:find("%f[%w_]end%f[^%w_]") then
			end_at = line_end
		else
			local _, block_end = source:find("\nend%s*\n", start_at)
			end_at = block_end or #source
		end
		local body = source:sub(start_at, end_at)
		local launches = 0
		for _, statement in ipairs(split_statements(without_comments(body))) do
			if has_stock_target(statement) and stock_gui_launch_label(statement) then
				launches = launches + 1
			end
		end
		if launches > 0 then
			capability_count = capability_count + 1
			for _, label in ipairs(find_offenders(body)) do
				if label ~= "stock Karabiner GUI launch outside explicit capability" then
					forbidden_inside[#forbidden_inside + 1] = label
				end
			end
			parts[#parts + 1] = "\n"
		else
			parts[#parts + 1] = body
		end
		cursor = end_at + 1
	end
	return table.concat(parts), capability_count, forbidden_inside
end

return {
	find_offenders = find_offenders,
	mask_explicit_open_gui_capability = mask_explicit_open_gui_capability,
}
