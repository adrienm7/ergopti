--- tests/meta/runloop/test_keymap_paste_replacement_transaction.lua

--- ==============================================================================
--- MODULE: Keymap paste replacement transaction (meta)
--- DESCRIPTION:
--- Cmd+V is emitted through SyntheticInput inside the same explicit replacement transaction as its deletes and text.
--- Source-scan guard split out of the audit-named regression file it came from.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads the one production unit containing a unique symbol.
--- @param selector string
--- @return string source
local function read_unit(selector)
	local src, err = helpers.read_driver_unit(selector)
	helpers.assert_not_nil(src, err)
	return src
end


--- Returns source from a declaration through the next public function.
--- @param source string
--- @param declaration string
--- @return string body
local function public_function_slice(source, declaration)
	local start_pos = source:find(declaration, 1, true)
	helpers.assert_not_nil(start_pos, declaration .. " must remain locatable")
	local next_pos = source:find("\nfunction M.", start_pos + #declaration, true)
	return source:sub(start_pos, next_pos or #source)
end


--- @param source string
--- @return string code
local function strip_line_comments(source)
	return (source:gsub("%-%-[^\n]*", ""))
end

helpers.describe("keymap paste: Cmd+V inherits the replacement transaction (audit-v6-bug2)", function()
	helpers.it("the paste helper emits Cmd+V through SyntheticInput", function()
		local src = helpers.read_driver_source("local function perform_paste(")
		helpers.assert_true(type(src) == "string" and src:match("%S") ~= nil,
			"the paste declaration must select nonempty production source")
		-- The complete unit stays contiguous if moved; ignore comments and parameter
		-- arity, but stop at this top-level end before a sibling can supply Cmd+V.
		src = "\n" .. strip_line_comments(src)
		local declaration = "\nlocal function perform_paste%([^()\r\n]*%)"
		local start_pos, declaration_end = src:find(declaration)
		local next_pos = declaration_end and src:find("\nend[ \t]*\n", declaration_end + 1)
		helpers.assert_not_nil(start_pos, "perform_paste must remain locatable")
		helpers.assert_nil(src:find(declaration, declaration_end + 1),
			"the paste declaration must be unique")
		helpers.assert_not_nil(next_pos, "the paste body must have its own top-level end")
		helpers.assert_true(src:sub(declaration_end + 1, next_pos - 1):match("%S") ~= nil,
			"the paste body must not be empty")
		local body = src:sub(start_pos, next_pos or #src)
		local count = 0
		for _ in body:gmatch("SyntheticInput%.emit_key_stroke") do count = count + 1 end
		helpers.assert_eq(count, 1,
			"the paste path must produce exactly one explicitly tagged Cmd+V pair")
		helpers.assert_true(
			body:find('SyntheticInput%.emit_key_stroke%({ "cmd" }, "v", 0%)') ~= nil,
			"the tagged pair must be the actual paste shortcut")
	end)

	helpers.it("the replacement owns its emitter from begin through seal", function()
		local src = read_unit("function M.try_terminator_expand")
		local body = public_function_slice(src, "function M.perform_text_replacement(")
		local begin_pos = body:find("SyntheticInput.begin", 1, true)
		local scope_pos = body:find("SyntheticInput.with_transaction", 1, true)
		local emit_pos = body:find("return emit_action()", 1, true)
		local seal_pos = body:find("SyntheticInput.seal", 1, true)
		helpers.assert_true(begin_pos and scope_pos and emit_pos and seal_pos,
			"begin, transaction scope, real emitter, and seal must all remain present")
		helpers.assert_true(begin_pos < scope_pos and scope_pos < emit_pos and emit_pos < seal_pos,
			"delete, Cmd+V, and text metadata must belong to one ordered replacement")
	end)

	helpers.it("the expander never reconstructs ownership from paste metadata", function()
		local src = read_unit("function M.try_terminator_expand")
		helpers.assert_true(src:find("take_paste_ops", 1, true) == nil,
			"compatibility metadata must not become a second ownership channel")
	end)
end)
