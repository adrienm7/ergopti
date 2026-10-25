--- tests/unit/modules/llm/vectors/test_context_buffer_vectors.lua

--- ==============================================================================
--- MODULE: AI Context Buffer Corpus (shared Lua oracle)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/llm/context_buffer_vectors.json through the
--- shared context buffer (_shared/lua/llm/context_buffer.lua) that macOS and
--- Linux both feed with typed text, and pins the strict-input contract.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local SHARED = helpers.driver_root() .. "/../_shared/"
package.path = SHARED .. "lua/?.lua;" .. SHARED .. "lua/?/init.lua;" .. package.path

local ContextBuffer = require("llm.context_buffer")

local function read_vectors()
	local path = SHARED .. "tests/corpus/llm/context_buffer_vectors.json"
	local fh = assert(io.open(path, "r"), "cannot open " .. path)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), path .. " is not valid JSON")
end

local VECTORS = read_vectors()

helpers.describe("AI context buffer corpus", function()
	helpers.it("declares the window the module implements", function()
		helpers.assert_eq(VECTORS.capacity, ContextBuffer.CAPACITY_CODEPOINTS)
	end)

	for _, vector in ipairs(VECTORS.cases) do
		helpers.it(vector.id, function()
			local buffer = ContextBuffer.new()
			local cleared = {}
			for _, step in ipairs(vector.ops) do
				if step.op == "append" then
					for _ = 1, step["repeat"] or 1 do buffer:append(step.text) end
				elseif step.op == "backspace" then buffer:backspace()
				elseif step.op == "replace_tail" then buffer:replace_tail(step.deletes, step.text)
				elseif step.op == "set" then buffer:set(step.text)
				elseif step.op == "clear" then buffer:clear()
				elseif step.op == "navigated" then cleared[#cleared + 1] = buffer:navigated(step.reset_on_nav)
				else error("unknown vector op " .. tostring(step.op)) end
			end
			helpers.assert_eq(buffer:text(), vector.expect.text, vector.id .. " text")
			helpers.assert_eq(buffer:length(), vector.expect.length, vector.id .. " length")
			if vector.cleared then helpers.assert_eq(cleared, vector.cleared, vector.id .. " navigation verdicts") end
		end)
	end
end)

helpers.describe("AI context buffer strictness", function()
	helpers.it("rejects non-text and invalid UTF-8 instead of drifting from the field", function()
		local buffer = ContextBuffer.new()
		helpers.assert_throws(function() buffer:append(12) end)
		helpers.assert_throws(function() buffer:append("\xff") end)
		helpers.assert_throws(function() buffer:replace_tail(-1, "x") end)
		helpers.assert_throws(function() buffer:replace_tail(1.5, "x") end)
		helpers.assert_throws(function() buffer:navigated(nil) end)
		helpers.assert_eq(buffer:text(), "", "a refused edit leaves the context untouched")
	end)

	helpers.it("answers the navigation rule without a buffer", function()
		helpers.assert_eq(ContextBuffer.retained_after_navigation("abc", true), "")
		helpers.assert_eq(ContextBuffer.retained_after_navigation("abc", false), "abc")
		helpers.assert_throws(function() ContextBuffer.retained_after_navigation("abc", "yes") end)
	end)
end)
