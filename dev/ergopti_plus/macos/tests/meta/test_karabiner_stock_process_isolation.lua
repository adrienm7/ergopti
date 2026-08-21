--- tests/meta/test_karabiner_stock_process_isolation.lua

--- ==============================================================================
--- MODULE: Karabiner Stock Process Isolation Guard
--- DESCRIPTION:
--- Prevents Ergopti from controlling any official Karabiner process or treating
--- process identity as proof of ownership.
--- Karabiner's UI, Core Service, grabber, console server, session monitor,
--- watchers, updater, icon switcher and VirtualHID helpers are shared with the user's personal rules;
--- process identity therefore cannot establish Ergopti ownership.
---
--- FEATURES & RATIONALE:
--- 1. Whole-driver scope catches sibling kill, launch and probe paths instead of
---    protecting only the shutdown site where the defect was first observed.
--- 2. Command-shape checks leave explicit user-requested GUI opening and
---    read-only onboarding probes available while rejecting destructive commands.
--- 3. The source-size floor makes an empty production scan fail loudly.
--- 4. Narrow constant folding catches stock-family and destructive executable
---    names assembled inline or through aliases without evaluating dynamics.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ==============================================
-- ==============================================
-- ======= 1/ Stock Process Control Guard =======
-- ==============================================
-- ==============================================

local RUNTIME_EXTENSIONS = {
	lua = true, sh = true, bash = true, zsh = true, command = true,
	swift = true, py = true, applescript = true, js = true, rb = true,
	pl = true, fish = true, m = true, mm = true, c = true, h = true,
	hpp = true, cc = true, cpp = true,
}

--- Reads each executable/runtime translation unit separately. Keeping file
--- boundaries prevents a harmless Karabiner probe in one module from tainting
--- an unrelated Dock/Ollama kill in the next concatenated module.
--- @return table units Production { path, body } records.
--- @return table unreadable Enumerated runtime paths that could not be opened.
local function read_runtime_units()
	local root = helpers.driver_root()
	local is_windows = package.config:sub(1, 1) == "\\"
	local command
	if is_windows then
		local native_root = root:gsub("/", "\\"):gsub("\\+$", "")
		command = 'dir /b /s /a-d "' .. native_root .. '\\*" 2>nul'
	else
		command = 'find "' .. root:gsub('"', '\\"') .. '" -type f'
	end

	local paths = {}
	local pipe = io.popen(command, "r")
	if pipe then
		for path in pipe:lines() do
			local normalized = path:gsub("\\", "/")
			local normalized_lower = normalized:lower()
			local extension = normalized_lower:match("%.([^./]+)$")
			if (RUNTIME_EXTENSIONS[extension] or extension == nil)
				and not normalized_lower:find("/tests/", 1, true)
				and not normalized_lower:find("/.codex-", 1, true)
				and not normalized_lower:find("/.venv/", 1, true)
				and not normalized_lower:find("/.pytest_cache/", 1, true) then
				paths[#paths + 1] = { native = path, normalized = normalized }
			end
		end
		pipe:close()
	end
	table.sort(paths, function(a, b) return a.normalized < b.normalized end)

	local units = {}
	local unreadable = {}
	for _, path in ipairs(paths) do
		local file = io.open(path.native, "r")
		if file then
			local body = file:read("*a")
			file:close()
			local extension = path.normalized:lower():match("%.([^./]+)$")
			if RUNTIME_EXTENSIONS[extension] or body:sub(1, 2) == "#!" then
				units[#units + 1] = { path = path.normalized, body = body }
			end
		else
			unreadable[#unreadable + 1] = path.normalized
		end
	end
	return units, unreadable
end

--- Removes comments while retaining quoted command strings. This is deliberately
--- lexical rather than a blanket gsub: `--set-variables` inside a shell script
--- is data, while prose saying "kill Karabiner" must not convict production.
--- @param source string Production source text.
--- @return string Code and string contents with comments removed.
local function without_comments(source)
	local kept = {}
	local in_c_block = false
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do
		local out = {}
		local quote = nil
		local escaped = false
		local first_code = line:find("%S") or (#line + 1)
		local index = 1
		while index <= #line do
			local char = line:sub(index, index)
			local pair = line:sub(index, index + 1)
			if in_c_block then
				if pair == "*/" then
					in_c_block = false
					index = index + 2
				else
					index = index + 1
				end
			elseif quote then
				out[#out + 1] = char
				if escaped then
					escaped = false
				elseif char == "\\" then
					escaped = true
				elseif char == quote then
					quote = nil
				end
				index = index + 1
			elseif char == '"' or char == "'" then
				quote = char
				out[#out + 1] = char
				index = index + 1
			elseif pair == "/*" then
				in_c_block = true
				index = index + 2
			elseif pair == "//" then
				break
			elseif pair == "--"
				and (index == first_code or line:sub(index + 2, index + 2):match("[%s%-]") ~= nil) then
				break
			elseif char == "#"
				and (index == first_code or line:sub(index - 1, index - 1):match("%s") ~= nil) then
				break
			else
				out[#out + 1] = char
				index = index + 1
			end
		end
		kept[#kept + 1] = table.concat(out)
	end
	return table.concat(kept, "\n")
end

local STOCK_TARGET_PATTERNS = {
	"karabiner[%W_]*elements",
	"karabiner[%W_]*core[%W_]*service",
	"karabiner[%W_]*menu",
	"karabiner[%W_]*event[%W_]*viewer",
	"karabiner_grabber",
	"karabiner_console_user_server",
	"karabiner[%W_]*session",
	"karabiner[%W_]*non[%W_]*privileged",
	"karabiner[%W_]*observer",
	"karabiner[%W_]*notification[%W_]*window",
	"karabiner[%W_]*multitouch[%W_]*extension",
	"karabiner[%W_]*updater",
	"karabiner[%W_]*app[%W_]*icon[%W_]*switcher",
	"virtual[%W_]*hid",
	"org%.pqrs[%w%._/%-]*karabiner",
	"kepaths%s*%.%s*console_user_server",
	"kepaths%s*%.%s*grabber",
	"kepaths%s*%.%s*core_service",
}

local OWNERSHIP_PATTERNS = {
	{ pattern = "is_hs_owned_bridge", label = "stock-process ownership predicate" },
	{ pattern = "hs_owner_marker", label = "stock-process ownership marker" },
	{ pattern = "ergopti_ke_hs_owner", label = "stock-process ownership marker file" },
	{ pattern = "karabiner_kill_[%w_]*cmd", label = "stock Karabiner kill command" },
}

local LAUNCHCTL_MUTATIONS = {
	"bootout", "disable", "enable", "kickstart", "unload", "remove",
	"stop", "kill", "bootstrap", "start",
}

local PROCESS_SPAWN_CALL_PATTERNS = {
	"shellrunner%s*%.%s*spawn",
	"hs%s*%.%s*task%s*%.%s*new",
	"processlifecycle%s*%.%s*spawn",
}

local function has_word(text, word)
	return text:find("%f[%w_]" .. word .. "%f[^%w_]") ~= nil
end

local function has_stock_target(text)
	local lower = text:lower()
	for _, pattern in ipairs(STOCK_TARGET_PATTERNS) do
		if lower:find(pattern) then return true end
	end
	return false
end

local function split_statements(source)
	local statements = {}
	local pending = ""
	local depth = 0
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do
		pending = pending == "" and line or (pending .. "\n" .. line)
		local quote = nil
		local escaped = false
		for index = 1, #line do
			local char = line:sub(index, index)
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
				depth = math.max(0, depth - 1)
			end
		end
		local trimmed = line:gsub("%s+$", "")
		local continues = depth > 0
			or trimmed:match("[=,|\\]$") ~= nil
			or trimmed:match("%.%.$") ~= nil
		if not continues then
			if pending:find("%S") then statements[#statements + 1] = pending end
			pending = ""
		end
	end
	if pending:find("%S") then statements[#statements + 1] = pending end
	return statements
end

local function assignment_parts(statement)
	local prefix, rhs = statement:match("^%s*(.-)%s*=%s*(.*)$")
	if not prefix or prefix == "" then return nil end
	if prefix:find("[~<>=]") or statement:match("^%s*if%s") then return nil end
	prefix = prefix:gsub("^local%s+", "")
		:gsub("^let%s+", "")
		:gsub("^var%s+", "")
		:gsub("^const%s+", "")
	if prefix:find("[^%w_,%s]") then return nil end
	local names = {}
	for name in prefix:gmatch("[%a_][%w_]*") do
		if name ~= "_" then names[#names + 1] = name:lower() end
	end
	if #names == 0 then return nil end
	return names, rhs
end

local function contains_identifier(text, identifier)
	return text:lower():find("%f[%w_]" .. identifier .. "%f[^%w_]") ~= nil
end

--- Advances over expression whitespace without mutating hidden parser state.
--- @param expression string Source expression.
--- @param index number Current byte index.
--- @return number index First non-whitespace byte index.
local function skip_expression_space(expression, index)
	while index <= #expression and expression:sub(index, index):match("%s") do
		index = index + 1
	end
	return index
end

--- Reads one quoted string or previously resolved constant identifier.
--- @param expression string Source expression.
--- @param index number Candidate atom byte index.
--- @param constants table Lowercase identifier-to-string map.
--- @return string|nil value Static atom value, or nil for a dynamic atom.
--- @return number next_index First byte after the atom when resolved.
local function constant_atom_at(expression, index, constants)
	index = skip_expression_space(expression, index)
	local char = expression:sub(index, index)
	if char == '"' or char == "'" then
		local quote = char
		local value = {}
		local valid = true
		index = index + 1
		while index <= #expression do
			char = expression:sub(index, index)
			if char == quote then
				return valid and table.concat(value) or nil, index + 1
			elseif char == "\\" then
				local escaped = expression:sub(index + 1, index + 1)
				if escaped ~= quote and escaped ~= "\\" then
					valid = false
				else
					value[#value + 1] = escaped
				end
				index = index + 2
			else
				value[#value + 1] = char
				index = index + 1
			end
		end
		return nil, #expression + 1
	end

	local identifier = expression:sub(index):match("^([%a_][%w_]*)")
	if not identifier then return nil, index end
	local value = constants[identifier:lower()]
	if type(value) ~= "string" then return nil, index end
	return value, index + #identifier
end

--- Folds the longest static concatenation beginning at one source position.
--- @param expression string Source expression or statement.
--- @param start_index number Candidate first atom byte index.
--- @param constants table Lowercase identifier-to-string map.
--- @return string|nil value Folded prefix, or nil when its first atom is dynamic.
--- @return number next_index First byte after the last resolved atom.
--- @return number joins Number of resolved concatenation operators.
local function fold_constant_expression_at(expression, start_index, constants)
	local value, index = constant_atom_at(expression, start_index, constants)
	if value == nil then return nil, index, 0 end
	local joins = 0
	while true do
		local operator_index = skip_expression_space(expression, index)
		local operator_length
		if expression:sub(operator_index, operator_index + 1) == ".." then
			operator_length = 2
		elseif expression:sub(operator_index, operator_index) == "+" then
			operator_length = 1
		else
			break
		end

		local part, next_index = constant_atom_at(
			expression, operator_index + operator_length, constants)
		if part == nil then break end
		value = value .. part
		index = next_index
		joins = joins + 1
	end
	return value, index, joins
end

--- Resolves an entire expression made only of constant string concatenations.
--- Rejecting every other token keeps assignment propagation deterministic.
--- @param expression string Assignment right-hand side.
--- @param constants table Lowercase identifier-to-string map.
--- @return string|nil value Folded string, or nil when the expression is dynamic.
local function fold_constant_string(expression, constants)
	local value, index = fold_constant_expression_at(expression, 1, constants)
	if value == nil then return nil end
	index = skip_expression_space(expression, index)
	if expression:sub(index, index) == ";" then
		index = skip_expression_space(expression, index + 1)
	end
	if index <= #expression then return nil end
	return value
end

--- Enumerates values assembled by constant concatenations inside a statement.
--- @param statement string Comment-free source statement.
--- @param constants table Lowercase identifier-to-string map.
--- @param include_identifiers boolean|nil Whether resolved standalone names count.
--- @return table values Folded values, excluding standalone string literals.
local function folded_constant_values(statement, constants, include_identifiers)
	local values = {}
	local index = 1
	while index <= #statement do
		local char = statement:sub(index, index)
		local previous = statement:sub(index - 1, index - 1)
		local is_identifier_start = char:match("[%a_]") ~= nil
			and previous:match("[%w_]") == nil
		if char == '"' or char == "'" or is_identifier_start then
			local value, next_index, joins = fold_constant_expression_at(statement, index, constants)
			if value ~= nil and (joins > 0 or (include_identifiers and is_identifier_start)) then
				values[#values + 1] = value
			end
			if next_index > index then
				index = next_index
			else
				local identifier = is_identifier_start
					and statement:sub(index):match("^([%a_][%w_]*)") or nil
				index = index + (identifier and #identifier or 1)
			end
		else
			index = index + 1
		end
	end
	return values
end

--- Detects a stock-family value assembled inside any constant subexpression.
--- @param statement string Comment-free source statement.
--- @param constants table Lowercase identifier-to-string map.
--- @return boolean has_target Whether a constant concatenation builds a stock target.
local function has_folded_stock_target(statement, constants)
	for _, value in ipairs(folded_constant_values(statement, constants)) do
		if has_stock_target(value) then return true end
	end
	return false
end

--- Propagates only statically foldable string assignments to a fixed point.
--- @param statements table Comment-free source statements.
--- @return table constants Lowercase identifier-to-string map.
local function collect_constant_strings(statements)
	local assignments = {}
	for _, statement in ipairs(statements) do
		local names, rhs = assignment_parts(statement)
		if names and #names == 1 then
			local name = names[1]
			assignments[name] = assignments[name] or {}
			assignments[name][#assignments[name] + 1] = rhs
		end
	end

	local constants = {}
	local changed = true
	while changed do
		changed = false
		for name, values in pairs(assignments) do
			if #values == 1 and constants[name] == nil then
				local value = fold_constant_string(values[1], constants)
				if value ~= nil then
					constants[name] = value
					changed = true
				end
			end
		end
	end
	return constants
end

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

helpers.describe("Karabiner stock processes remain entirely user-managed", function()
	helpers.it("stock-process isolation: contains no kill, launchd mutation, auto-launch or ownership path", function()
		local lua_source = helpers.read_driver_source()
		local units, unreadable = read_runtime_units()
		helpers.assert_true(type(lua_source) == "string" and #lua_source > 100000,
			"the production scan must cover the whole macOS driver")
		helpers.assert_true(#units > 100,
			"the per-translation-unit runtime scan must not be empty or narrowly scoped")
		helpers.assert_eq(#unreadable, 0,
			"every enumerated runtime source must be readable; missing: " .. table.concat(unreadable, ", "))
		local runtime_source = {}
		for _, unit in ipairs(units) do runtime_source[#runtime_source + 1] = unit.body end
		local all_runtime_source = table.concat(runtime_source, "\n")
		helpers.assert_true(all_runtime_source:find("enum KarabinerLeaseWorker", 1, true) ~= nil,
			"the runtime scan must include the native Swift lease worker, not only Lua")
		helpers.assert_true(all_runtime_source:find("karabiner_lease_watchdog.sh", 1, true) == nil,
			"the retired shell watchdog must not remain in production runtime sources")

		local lifecycle_source, lifecycle_err = helpers.read_driver_unit("local KE_GRABBER_CHECK")
		helpers.assert_true(lifecycle_source ~= nil,
			"ke_lifecycle must be uniquely readable without a pinned path: " .. tostring(lifecycle_err))
		local guarded_lifecycle, explicit_capabilities, forbidden_inside =
			mask_explicit_open_gui_capability(lifecycle_source)
		helpers.assert_eq(explicit_capabilities, 1,
			"only ke_lifecycle.M.open_gui may contain stock Karabiner launch APIs")

		local offenders = {}
		local lifecycle_units = 0
		local exact_owned_task_terminations = 0
		for _, unit in ipairs(units) do
			local guarded_body = unit.body
			-- Onboarding owns the hs.task objects in its private registry. Cancelling
			-- those exact download/installer handles is required lifecycle cleanup,
			-- not control of a shared Karabiner process.
			if guarded_body:find("for task in pairs(M._active_tasks) do", 1, true) then
				local masked
				guarded_body, masked = guarded_body:gsub(
					"task:%s*terminate%s*%(%s*%)", "task:cancel_exact_owned_task()")
				exact_owned_task_terminations = exact_owned_task_terminations + masked
			end
			if unit.body == lifecycle_source then
				guarded_body = guarded_lifecycle
				lifecycle_units = lifecycle_units + 1
				for _, label in ipairs(forbidden_inside) do
					offenders[#offenders + 1] = unit.path .. ": explicit open_gui also contains " .. label
				end
			end
			for _, label in ipairs(find_offenders(guarded_body)) do
				offenders[#offenders + 1] = unit.path .. ": " .. label
			end
		end
		helpers.assert_eq(lifecycle_units, 1,
			"the runtime unit scan must include ke_lifecycle exactly once")
		helpers.assert_eq(exact_owned_task_terminations, 1,
			"the onboarding lifecycle must cancel exactly one private active-task class")
		local menu_source, menu_err = helpers.read_driver_unit('i18n.get("menu.karabiner.open_gui")')
		helpers.assert_true(menu_source ~= nil,
			"the explicit Karabiner menu action must be uniquely readable: " .. tostring(menu_err))
		helpers.assert_true(
			without_comments(menu_source):find(
				"action%s*=%s*function%s*%(%s*%)%s*karabiner%.open_gui%s*%(%s*%)") ~= nil,
			"the only stock-GUI capability must remain behind the explicit Karabiner menu action")

		helpers.assert_eq(#offenders, 0,
			"Ergopti may revoke only its exact lease/watchdog; official Karabiner "
				.. "processes are shared with personal rules and must never be killed, "
				.. "auto-launched, launchd-mutated or claimed by process identity. Found: "
				.. table.concat(offenders, ", "))
	end)

	helpers.it("stock-process isolation: rejects direct shell destruction", function()
		local mutant = [[
#!/bin/sh
pkill -f Karabiner-Menu
launchctl disable gui/501/org.pqrs.karabiner.karabiner_console_user_server
pid=$(pgrep -f Karabiner-Core-Service); kill -TERM "$pid"
]]
		helpers.assert_true(#find_offenders(mutant) >= 3,
			"the guard must be mutation-sensitive to destructive commands in .sh runtime files")
	end)

	helpers.it("stock-process isolation: rejects Swift stock-process launch APIs", function()
		local mutants = {
			[[
var childPID: pid_t = 0
posix_spawn(&childPID, "/Applications/Karabiner-Elements.app/Contents/MacOS/Karabiner-Elements", nil, nil, nil, nil)
]],
			[[
let stockBinary = "/Library/Application Support/org.pqrs/Karabiner-Elements/Karabiner-Core-Service.app/Contents/MacOS/Karabiner-Core-Service"
let process = Process()
process.executableURL = URL(fileURLWithPath: stockBinary)
try process.run()
]],
			[[
try Process.run(URL(fileURLWithPath: "/Applications/Karabiner-Elements.app/Contents/MacOS/Karabiner-Elements"), arguments: [])
]],
		}
		for index, mutant in ipairs(mutants) do
			helpers.assert_eq(
				find_offenders(mutant)[1],
				"stock Karabiner process auto-launch",
				"the guard must classify Swift stock-process launch mutant #" .. index
			)
		end

		local canonical_cli_children = {
			[[
ShellRunner.spawn(KePaths.CLI, { "--set-variables", payload }, onDone)
]],
			[[
local KARABINER_CLI = KePaths.CLI
local ok, task = pcall(
	hs.task.new,
	KARABINER_CLI,
	onDone,
	{ "--get-variable", scoped_name }
)
]],
			[[
let cli = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
let process = Process()
process.executableURL = URL(fileURLWithPath: cli)
process.arguments = ["--set-variables", payload]
try process.run()
]],
			[[
let cli = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
var childPID: pid_t = 0
posix_spawn(&childPID, cli, nil, nil, [cli, "--set-variables", payload], nil)
]],
		}
		for index, source in ipairs(canonical_cli_children) do
			helpers.assert_eq(#find_offenders(source), 0,
				"exact transient --set-variables CLI context must remain allowed #" .. index)
		end
	end)

	helpers.it("stock-process isolation: rejects CLI commands outside exact variable operations", function()
		local mutants = {
			[[ShellRunner.spawn(KePaths.CLI, { "--show-current-profile-name" })]],
			[[
local KARABINER_CLI = KePaths.CLI
local ok, task = pcall(
	hs.task.new,
	KARABINER_CLI,
	onDone,
	{ "--select-profile", "Gaming" }
)
]],
			[[
let cli = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
let process = Process()
process.executableURL = URL(fileURLWithPath: cli)
process.arguments = ["--select-profile", "Gaming"]
try process.run()
]],
			[[
guard let rawArguments = duplicateLeaseArguments([
	cliPath,
	"--list-profile-names",
]) else { return .spawnFailed(ENOMEM) }
]],
			[[
let cli = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
var childPID: pid_t = 0
posix_spawn(&childPID, cli, nil, nil, [cli, "--version"], nil)
]],
			[[
let kCanonicalKarabinerCLIPath = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
final class Mutant {
	func run(cliPath: String) {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: cliPath)
		process.arguments = ["--version"]
		try process.run()
	}
}
]],
		}
		for index, source in ipairs(mutants) do
			helpers.assert_eq(
				find_offenders(source)[1],
				CLI_BOUNDARY_OFFENDER,
				"canonical CLI subcommand mutant must be rejected #" .. index
			)
		end
	end)

	helpers.it("stock-process isolation: correlates Swift /bin/kill with stock-derived PIDs", function()
		local mutants = {
			[[
let stockPID = processIdentifier(named: "Karabiner-Core-Service")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/kill")
process.arguments = ["-TERM", String(stockPID)]
try process.run()
]],
			[[
let stockPID = processIdentifier(named: "karabiner_grabber")
try Process.run(
	URL(fileURLWithPath: "/bin/kill"),
	arguments: ["-KILL", String(stockPID)]
)
]],
			[[
final class Mutant {
	func stopStock() {
		let stockPID = processIdentifier(named: "Karabiner-Menu")
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/kill")
		process.arguments = ["-TERM", String(stockPID)]
		try process.run()
	}
}
]],
		}
		for index, source in ipairs(mutants) do
			helpers.assert_eq(find_offenders(source)[1], "stock Karabiner kill",
				"Swift Process PID-flow mutant must be rejected #" .. index)
		end

		local private_child = [[
let childPID = privateLeaseChild.processIdentifier
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/kill")
process.arguments = ["-TERM", String(childPID)]
try process.run()
]]
		helpers.assert_eq(#find_offenders(private_child), 0,
			"signalling a directly-owned private helper must not imply stock ownership")
	end)

	helpers.it("stock-process isolation: rejects destructive data flows across argv, lines and indirection", function()
		local mutants = {
			[[kill -TERM "$(pgrep -f Karabiner-Core-Service)"]],
			[[pgrep -f org.pqrs.Karabiner-Elements | xargs kill -TERM]],
			[[
pid=$(pgrep -f karabiner_grabber)
kill -KILL "$pid"
]],
			[[
local _, pid = ShellRunner.exec("/usr/bin/pgrep", { "-f", "karabiner_session_monitor" })
ShellRunner.spawn("/bin/kill", { "-TERM", pid })
]],
			[[
local app = hs.application.get("org.pqrs.Karabiner-Elements")
app:kill()
]],
			[[
local stock_group = process_group_for("Karabiner-Core-Service")
Darwin.killpg(stock_group, SIGKILL)
]],
			[[
ShellRunner.spawn("/bin/launchctl", {
	"bootout",
	"gui/501/org.pqrs.karabiner.karabiner_console_user_server",
})
]],
			[[
local target = KePaths.CORE_SERVICE
WindowManager.kill({ path = target })
]],
			[[hs.application.launchOrFocus("Karabiner-Elements")]],
			[[ShellRunner.spawn("/usr/bin/open", { "-a", "Karabiner-Elements" })]],
		}

		for index, mutant in ipairs(mutants) do
			helpers.assert_true(#find_offenders(mutant) > 0,
				"the stock-process guard must reject destructive mutant #" .. index)
		end
	end)

	helpers.it("stock-process isolation: folds split stock-family constants before destructive use", function()
		local mutant = [[
local prefix = "karabiner_"
local family = prefix .. "grabber"
ShellRunner.spawn("/usr/bin/pkill", { "-f", family })
]]
		local offenders = find_offenders(mutant)
		helpers.assert_eq(#offenders, 1,
			"the guard must reject one destructive use of a constant-propagated stock family")
		helpers.assert_eq(offenders[1], "pkill stock Karabiner",
			"the folded family must taint the actual destructive process command")

		local suffix_mutant = [[
local suffix = "grabber"
local family = "karabiner_" .. suffix
ShellRunner.spawn("/usr/bin/pkill", { "-f", family })
]]
		helpers.assert_eq(find_offenders(suffix_mutant)[1], "pkill stock Karabiner",
			"a constant suffix alias must not hide a destructive stock-family command")

		local inline_mutant = [[
ShellRunner.spawn("/usr/bin/pkill", { "-f", "karabiner_" .. "grabber" })
]]
		helpers.assert_eq(find_offenders(inline_mutant)[1], "pkill stock Karabiner",
			"an inline constant concatenation must taint the destructive process command")

		local inline_probe = [[
ShellRunner.exec("/usr/bin/pgrep", { "-f", "karabiner_" .. "grabber" })
]]
			helpers.assert_eq(#find_offenders(inline_probe), 0,
			"an inline constant concatenation in a read-only probe must remain allowed")
	end)

	helpers.it("stock-process isolation: folds split destructive executable names", function()
		local command_mutants = {
			{
				source = [[
ShellRunner.spawn("/usr/bin/p" .. "kill", { "-f", "Karabiner-Menu" })
]],
				label = "pkill stock Karabiner",
			},
			{
				source = [[
ShellRunner.spawn("/bin/launch" .. "ctl", {
	"bootout",
	"gui/501/org.pqrs.karabiner.karabiner_console_user_server",
})
]],
				label = "launchctl bootout stock Karabiner",
			},
			{
				source = [[
ShellRunner.spawn("/bin/" .. "kill", { "-TERM", "Karabiner-Core-Service" })
]],
				label = "stock Karabiner kill",
			},
			{
				source = [[
local command = "/usr/bin/p" .. "kill"
ShellRunner.spawn(command, { "-f", "Karabiner-Menu" })
]],
				label = "pkill stock Karabiner",
			},
			{
				source = [[
local command = "/bin/launch" .. "ctl"
local mutation = "boot" .. "out"
ShellRunner.spawn(command, { mutation, "org.pqrs.karabiner.karabiner_console_user_server" })
]],
				label = "launchctl bootout stock Karabiner",
			},
		}
		for index, mutant in ipairs(command_mutants) do
			helpers.assert_eq(find_offenders(mutant.source)[1], mutant.label,
				"the guard must classify split destructive executable mutant #" .. index)
		end

		local gui_mutants = {
			[[ShellRunner.spawn("/usr/bin/op" .. "en", { "-a", "Karabiner-Elements" })]],
			[=[
local command = "/usr/bin/op" .. "en"
ShellRunner.spawn(command, { "-a", "Karabiner-Menu" })
]=],
			[[ShellRunner.spawn("op" .. "en", { "-a", "Karabiner-EventViewer" })]],
		}
		for index, source in ipairs(gui_mutants) do
			helpers.assert_eq(
				find_offenders(source)[1],
				"stock Karabiner GUI launch outside explicit capability",
				"the guard must classify split GUI executable mutant #" .. index
			)
		end

		local read_only_probe = [[
ShellRunner.spawn("/usr/bin/p" .. "grep", { "-f", "Karabiner-Menu" })
]]
		helpers.assert_eq(#find_offenders(read_only_probe), 0,
			"a split read-only process probe must not be classified as destructive")

		local aliased_read_only_probe = [[
local command = "/usr/bin/p" .. "grep"
ShellRunner.spawn(command, { "-f", "Karabiner-Menu" })
]]
		helpers.assert_eq(#find_offenders(aliased_read_only_probe), 0,
			"an aliased read-only process probe must not be classified as destructive")
	end)

	helpers.it("stock-process isolation: covers every shared family without flagging unrelated kills", function()
		local shared_families = {
			"Karabiner-Elements",
			"Karabiner-Core-Service",
			"karabiner_grabber",
			"Karabiner-Menu",
			"Karabiner-EventViewer",
			"karabiner_console_user_server",
			"karabiner_session_monitor",
			"org.pqrs.service.agent.karabiner_non_privileged_agent",
			"karabiner_observer",
			"Karabiner-NotificationWindow",
			"Karabiner-Multitouch-Extension",
			"Karabiner-MultitouchExtension",
			"Karabiner-Updater",
			"Karabiner-AppIconSwitcher",
			"Karabiner-VirtualHIDDevice-Daemon",
			"org.pqrs.Karabiner-DriverKit-VirtualHIDDevice",
		}
		for _, family in ipairs(shared_families) do
			helpers.assert_true(#find_offenders("pkill -f " .. family) > 0,
				"the guard must cover shared Karabiner family " .. family)
		end

		local safe_controls = {
			[[kill -TERM "$ERGOPTI_WATCHDOG_PID"]],
			[[pgrep -f mlx_lm | xargs kill -9]],
			[[local app = hs.application.get("Dock"); app:kill()]],
			[[local running = ShellRunner.exec("/usr/bin/pgrep", { "-f", "Karabiner-Core-Service" })]],
			[[
local prefix = "karabiner_"
local family = prefix .. "grabber"
local running = ShellRunner.exec("/usr/bin/pgrep", { "-f", family })
]],
			[[ShellRunner.spawn(KePaths.CLI, { "--set-variables", payload })]],
			[[-- kill -TERM "$(pgrep -f Karabiner-Core-Service)"]],
			[[local ok = true -- app:kill() Karabiner-Core-Service]],
			[[# pkill -f Karabiner-NotificationWindow]],
			[[// launchctl bootout org.pqrs.karabiner.karabiner_console_user_server]],
			[[/* hs.application.get("Karabiner-Elements"):kill() */]],
			[[Logger.info(LOG, "Never kill Karabiner-Elements from Ergopti")]],
		}
		for index, source in ipairs(safe_controls) do
			helpers.assert_eq(#find_offenders(source), 0,
				"the guard must not flag safe control #" .. index)
		end
	end)
end)
