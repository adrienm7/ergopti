--- tests/support/karabiner_isolation/syntax.lua

--- ==============================================================================
--- MODULE: Karabiner Isolation syntax
--- DESCRIPTION:
--- Pure source analysis shared by runtime guards and adversarial tests.
--- ==============================================================================


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
		local length = #line
		while index <= length do
			if in_c_block then
				local close = line:find("*/", index, true)
				if close then
					in_c_block = false
					index = close + 2
				else
					index = length + 1
				end
			elseif quote then
				if escaped then
					out[#out + 1] = line:sub(index, index)
					escaped = false
					index = index + 1
				else
					-- Copy the run up to the next escape or closing quote at once.
					local stop = line:find(quote == '"' and '[\\"]' or "[\\']", index)
					if not stop then
						out[#out + 1] = line:sub(index)
						index = length + 1
					else
						out[#out + 1] = line:sub(index, stop)
						if line:sub(stop, stop) == "\\" then escaped = true else quote = nil end
						index = stop + 1
					end
				end
			else
				-- Plain code: copy everything before the next byte that can open
				-- a string or a comment, then decide on that byte exactly as before.
				local special = line:find("[\"'/%-#]", index)
				if not special then
					out[#out + 1] = line:sub(index)
					index = length + 1
				elseif special > index then
					out[#out + 1] = line:sub(index, special - 1)
					index = special
				else
					local char = line:sub(index, index)
					local pair = line:sub(index, index + 1)
					if char == '"' or char == "'" then
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
	local pending = {}
	local depth = 0
	for line in (source .. "\n"):gmatch("([^\n]*)\n") do
		-- An empty pending text restarts with this line (leading blank lines drop).
		if #pending == 0 or (#pending == 1 and pending[1] == "") then
			pending = { line }
		else
			pending[#pending + 1] = line
		end
		local quote = nil
		local escaped = false
		local index = 1
		local length = #line
		while index <= length do
			if quote then
				if escaped then
					escaped = false
					index = index + 1
				else
					local stop = line:find(quote == '"' and '[\\"]' or "[\\']", index)
					if not stop then
						index = length + 1
					else
						if line:sub(stop, stop) == "\\" then escaped = true else quote = nil end
						index = stop + 1
					end
				end
			else
				local special = line:find("[\"'%(%){}%[%]]", index)
				if not special then break end
				local char = line:sub(special, special)
				if char == '"' or char == "'" then
					quote = char
				elseif char == "(" or char == "{" or char == "[" then
					depth = depth + 1
				else
					depth = math.max(0, depth - 1)
				end
				index = special + 1
			end
		end
		local trimmed = line:gsub("%s+$", "")
		local continues = depth > 0
			or trimmed:match("[=,|\\]$") ~= nil
			or trimmed:match("%.%.$") ~= nil
		if not continues then
			local text = table.concat(pending, "\n")
			if text:find("%S") then statements[#statements + 1] = text end
			pending = {}
		end
	end
	local text = table.concat(pending, "\n")
	if text:find("%S") then statements[#statements + 1] = text end
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
	if index > #expression then return index end
	return expression:find("%S", index) or (#expression + 1)
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

	local identifier = expression:match("^([%a_][%w_]*)", index)
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
					and statement:match("^([%a_][%w_]*)", index) or nil
				index = index + (identifier and #identifier or 1)
			end
		else
			-- Only a quote or a letter can start an atom; skip the bytes between.
			index = statement:find("[\"'%a_]", index + 1) or (#statement + 1)
		end
	end
	return values
end

--- Detects a stock-family value assembled inside any constant subexpression.
--- @param statement string Comment-free source statement.
--- @param constants table Lowercase identifier-to-string map.
--- @return boolean has_target Whether a constant concatenation builds a stock target.
local function has_folded_stock_target(statement, constants)
	-- Folded values require a join; standalone identifiers are handled by taint.
	if not statement:find("..", 1, true) and not statement:find("+", 1, true) then
		return false
	end
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

return {
	without_comments = without_comments,
	OWNERSHIP_PATTERNS = OWNERSHIP_PATTERNS,
	LAUNCHCTL_MUTATIONS = LAUNCHCTL_MUTATIONS,
	PROCESS_SPAWN_CALL_PATTERNS = PROCESS_SPAWN_CALL_PATTERNS,
	has_word = has_word,
	has_stock_target = has_stock_target,
	split_statements = split_statements,
	assignment_parts = assignment_parts,
	contains_identifier = contains_identifier,
	fold_constant_string = fold_constant_string,
	folded_constant_values = folded_constant_values,
	has_folded_stock_target = has_folded_stock_target,
	collect_constant_strings = collect_constant_strings,
}
