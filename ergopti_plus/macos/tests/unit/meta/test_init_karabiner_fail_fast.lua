--- tests/unit/meta/test_init_karabiner_fail_fast.lua

--- ==============================================================================
--- MODULE: Root Karabiner Initialization Is an Exact Fail-Fast Gate
--- DESCRIPTION:
--- Root init.lua cannot run in the unit harness, so this mutation-sensitive
--- source guard proves that only literal true crosses the Karabiner boundary.
--- The guard must raise before menu startup, boot-success publication, or the
--- shared ready flag. The callee's own init refusals must return literal false,
--- otherwise root and tests receive an ambiguous nil contract.
--- ==============================================================================

local helpers = require("tests.helpers")

local ROOT_ANCHOR = "✅ Hammerspoon boot SUCCESSFUL."
local INIT_ANCHOR = "function M.init(file_system)"
local EXACT_ROOT_GUARD = "if type(karabiner) ~= \"table\" or karabiner.init(file_system) ~= true then"
local ROOT_FAILURE = "error(\"karabiner.init did not commit\")"
local MENU_START = "menu.start("
local BOOT_SUCCESS = "✅ Hammerspoon boot SUCCESSFUL."
local READY_PUBLICATION = "Storage.set(HS_BOOT_READY_SETTING_KEY, true)"

-- Source contract helpers

--- Removes full-line and trailing Lua comments from a source string.
--- @param source string Lua source.
--- @return string code
local function strip_comments(source)
	return (source:gsub("%-%-[^\n]*", ""))
end

--- Replaces the first plain-text occurrence and proves the mutation existed.
--- @param source string Original source.
--- @param needle string Exact text to replace.
--- @param replacement string Replacement text.
--- @return string mutant
local function replace_plain(source, needle, replacement)
	local at = source:find(needle, 1, true)
	helpers.assert_true(at ~= nil, "mutation precondition missing: " .. needle)
	return source:sub(1, at - 1) .. replacement .. source:sub(at + #needle)
end

--- Validates the root's exact guard and all downstream publication ordering.
--- @param source string Root source or a synthetic mutant.
--- @return boolean valid
local function root_contract_is_exact(source)
	local code = strip_comments(source)
	local guard_at = code:find(EXACT_ROOT_GUARD, 1, true)
	local failure_at = code:find(ROOT_FAILURE, 1, true)
	local menu_at = code:find(MENU_START, 1, true)
	local success_at = code:find(BOOT_SUCCESS, 1, true)
	local ready_at = code:find(READY_PUBLICATION, 1, true)
	return guard_at ~= nil
		and failure_at ~= nil
		and menu_at ~= nil
		and success_at ~= nil
		and ready_at ~= nil
		and guard_at < failure_at
		and failure_at < menu_at
		and menu_at < success_at
		and success_at < ready_at
end

--- Extracts the remap M.init body using the next documented lifecycle helper.
--- @param source string Remap source.
--- @return string body
local function remap_init_body(source)
	local start_at = source:find(INIT_ANCHOR, 1, true)
	local stop_at = start_at and source:find("--- Releases local watchers", start_at, true)
	helpers.assert_true(start_at ~= nil and stop_at ~= nil and start_at < stop_at,
		"platform.remap M.init must remain uniquely extractable")
	return source:sub(start_at, stop_at - 1)
end

--- Extracts direct M.init return statements while ignoring nested callbacks.
--- @param body string Extracted M.init source.
--- @return table returns Direct return statements.
--- @return boolean balanced Whether the outer function closed exactly.
local function direct_init_returns(body)
	local returns = {}
	local blocks = { "function" }
	local function_depth = 1
	local line_index = 0
	for line in (strip_comments(body) .. "\n"):gmatch("([^\n]*)\n") do
		line_index = line_index + 1
		local statement = line:match("^%s*(.-)%s*$")
		if line_index > 1 and function_depth == 1
			and statement:match("^return%f[%W]") then
			returns[#returns + 1] = statement
		end

		if line_index > 1 then
			-- Keywords inside ordinary quoted strings are not Lua blocks; M.init has
			-- no long-bracket strings, so shortest quoted spans are sufficient here
			local code = line:gsub("\".-\"", "\"\""):gsub("'.-'", "''")
			for token in code:gmatch("[%a_]+") do
				if token == "function" then
					blocks[#blocks + 1] = "function"
					function_depth = function_depth + 1
				elseif token == "if" or token == "for" or token == "while"
					or token == "repeat" then
					blocks[#blocks + 1] = token
				elseif token == "end" or token == "until" then
					local closed = table.remove(blocks)
					if closed == "function" then function_depth = function_depth - 1 end
				end
			end
		end
	end
	return returns, function_depth == 0 and #blocks == 0
end

--- Accepts only the current init body's seven refusal exits and sole commit exit.
--- @param body string Extracted function body or a synthetic mutant.
--- @return boolean valid
local function remap_init_returns_are_literal(body)
	local returns, balanced = direct_init_returns(body)
	if not balanced or #returns ~= 8 then return false end
	local false_returns = 0
	local true_returns = 0
	for _, statement in ipairs(returns) do
		if statement == "return false" then false_returns = false_returns + 1 end
		if statement == "return true" then true_returns = true_returns + 1 end
		if statement ~= "return false" and statement ~= "return true" then return false end
	end
	return false_returns == 7 and true_returns == 1
end

-- Mutation-sensitive regressions

helpers.describe("root boot requires an exact Karabiner init commit", function()
	local root_source, root_source_err = helpers.read_driver_unit(ROOT_ANCHOR)

	helpers.it("HS-019 locates the root source by a unique boot-ready anchor", function()
		helpers.assert_nil(root_source_err)
		helpers.assert_true(type(root_source) == "string" and root_source ~= "")
	end)

	helpers.it("HS-019 raises before operational UI and every boot-success publication", function()
		helpers.assert_true(root_contract_is_exact(root_source),
			"false/nil Karabiner init must abort before menu.start, SUCCESS, and ready=true")
	end)

	helpers.it("HS-019 kills truthy, false-only, and log-only guard mutants", function()
		local truthy_mutant = replace_plain(
			root_source,
			"karabiner.init(file_system) ~= true",
			"not karabiner.init(file_system)"
		)
		local false_only_mutant = replace_plain(
			root_source,
			"karabiner.init(file_system) ~= true",
			"karabiner.init(file_system) == false"
		)
		local log_only_mutant = replace_plain(
			root_source,
			ROOT_FAILURE,
			"Logger.error(LOG, \"karabiner.init did not commit\")"
		)
		helpers.assert_eq(root_contract_is_exact(truthy_mutant), false,
			"a nil return must not cross a generic truthiness guard")
		helpers.assert_eq(root_contract_is_exact(false_only_mutant), false,
			"an explicit false check still lets nil publish boot-ready")
		helpers.assert_eq(root_contract_is_exact(log_only_mutant), false,
			"logging without aborting still exposes operational remap controls")
	end)
end)

helpers.describe("platform.remap init returns a literal boolean", function()
	local remap_source, remap_source_err = helpers.read_driver_unit(INIT_ANCHOR)
	local body = remap_source and remap_init_body(remap_source) or ""

	helpers.it("HS-019 has a non-vacuous exact-boolean init body", function()
		helpers.assert_nil(remap_source_err)
		helpers.assert_true(type(remap_source) == "string" and remap_source ~= "")
		helpers.assert_true(remap_init_returns_are_literal(body),
			"every early refusal must return false and the sole commit must return true")
	end)

	helpers.it("HS-019 rejects non-boolean and extra direct return mutants", function()
		local refusal_nil = replace_plain(body, "return false", "return")
		local success_nil = replace_plain(body, "return true", "return")
		local truthy_refusal = replace_plain(body, "return false", "return \"refused\"")
		local extra_non_boolean = replace_plain(
			body,
			INIT_ANCHOR,
			INIT_ANCHOR .. "\n\tif false then\n\t\treturn nil\n\tend"
		)
		local extra_boolean = replace_plain(
			body,
			INIT_ANCHOR,
			INIT_ANCHOR .. "\n\tif false then\n\t\treturn false\n\tend"
		)
		helpers.assert_eq(remap_init_returns_are_literal(refusal_nil), false)
		helpers.assert_eq(remap_init_returns_are_literal(success_nil), false)
		helpers.assert_eq(remap_init_returns_are_literal(truthy_refusal), false)
		helpers.assert_eq(remap_init_returns_are_literal(extra_non_boolean), false)
		helpers.assert_eq(remap_init_returns_are_literal(extra_boolean), false)
	end)
end)
