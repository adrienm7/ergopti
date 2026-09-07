--- tests/unit/ui/test_hotstring_counter_file_transaction.lua

--- ==============================================================================
--- MODULE: Hotstring Counter File Transaction Tests
--- DESCRIPTION:
--- Failed extension reads close their streams and cannot poison cached counts.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_counter = require("tests.support.hotstring_counter_fixture")

helpers.describe("hotstring counter file transactions", function()
	for _, case in ipairs({
		{ label = "empty", content = "", count = 0 },
		{ label = "LF", content = '[[section]]\n"a" = { output = "b" }\n', count = 1 },
		{ label = "CRLF", content = '[[section]]\r\n"a" = { output = "b" }\r\n', count = 1 },
		{ label = "no final LF", content = '[[section]]\n"a" = { output = "b" }', count = 1 },
	}) do
		helpers.it("(hotstring-counter-read) preserves successful " .. case.label .. " content", function()
			with_counter(function(counter, state, context)
				state.content = case.content
				helpers.assert_eq(counter.count_all(context, {}).ext, case.count)
				helpers.assert_eq(counter.count_all(context, {}).ext, case.count)
				helpers.assert_eq(state.opens, 1)
				helpers.assert_eq(state.closes, 1)
				helpers.assert_eq(#state.errors, 0)
			end)
		end)
	end
	helpers.it("(hotstring-counter-read) repeated failure is bounded while successful retry becomes cached", function()
		with_counter(function(counter, state, context)
			state.mode = "read_throw"
			for _ = 1, 2 do
				local ok, failure = pcall(counter.count_all, context, {})
				helpers.assert_eq(ok, false)
				helpers.assert_eq(failure, "Extension file transaction failed; hotstring counts were not published")
			end
			helpers.assert_eq(state.closes, 2)
			helpers.assert_eq(#state.errors, 1)
			state.mode = "success"
			helpers.assert_eq(counter.count_all(context, {}).ext, 1)
			helpers.assert_eq(counter.count_all(context, {}).ext, 1)
			helpers.assert_eq(state.opens, 3)
			helpers.assert_eq(state.closes, 3)
		end)
	end)
	for _, target in ipairs({ "manifest", "hotstrings" }) do
		for _, mode in ipairs({ "open_nil", "open_throw", "read_nil", "read_throw", "close_nil", "close_throw" }) do
			helpers.it("(hotstring-counter-read) " .. target .. " " .. mode, function()
				with_counter(function(counter, state, context)
					state.target, state.mode = target, mode
					local ok, failure = pcall(counter.count_all, context, {})
					helpers.assert_eq(ok, false, "failed read must abort rather than publish fallback counts")
					helpers.assert_eq(failure, "Extension file transaction failed; hotstring counts were not published")
					helpers.assert_eq(state.closes, mode:find("open_", 1, true) and 0 or 1)
					helpers.assert_eq(#state.errors, 1)
					state.mode = "success"
					local recovered = counter.count_all(context, {})
					helpers.assert_eq(recovered.ext, 1)
					helpers.assert_eq(recovered.ext_details[1].name, "Demo")
					helpers.assert_eq(state.opens, 2, "failed aggregate must remain retryable")
					for _, message in ipairs(state.errors) do
						helpers.assert_nil(message:find("PRIVATE_DETAIL", 1, true))
						helpers.assert_nil(message:find("/virtual", 1, true))
					end
				end)
			end)
		end
	end
end)
