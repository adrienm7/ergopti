--- _shared/lua/test/user_hotstring_source_contract.lua

--- Independent exact-byte factory-loading regressions for both Lua runtimes.
local M = {}

--- Registers source-loading cases against the production loader.
--- @param helpers table Native test assertions.
--- @param Source table Production loader.
function M.run(helpers, Source)
	helpers.describe("programmable hotstring source", function()
		helpers.it("preserves absence and rejects unreadable sources", function()
			local reads = 0
			local rules, receipt = Source.load(function()
				reads = reads + 1
				return nil, "absent"
			end, "/owned/personal_dynamic_hotstrings.lua", {})
			helpers.assert_eq(#rules, 0)
			helpers.assert_eq(receipt.present, false)
			helpers.assert_eq(reads, 1)
			local invalid, _, problem = Source.load(function() return nil, "error" end, "/owned/source", {})
			helpers.assert_eq(invalid, nil)
			helpers.assert_eq(problem, "source-read")
		end)
		helpers.it("creates an example only through an absent-source conditional publication", function()
			local writes = 0
			local function publish(path, text, expected)
				writes = writes + 1
				helpers.assert_eq(path, "/owned/source")
				helpers.assert_true(text:find("return function(api)", 1, true) ~= nil)
				helpers.assert_eq(expected, { status = "absent" })
				return true
			end
			helpers.assert_eq(Source.create_example(function() return "USER CONTENT", "ok" end, publish, "/owned/source"), false)
			helpers.assert_eq(writes, 0)
			helpers.assert_true(Source.create_example(function() return nil, "absent" end, publish, "/owned/source"))
			helpers.assert_eq(writes, 1)
			helpers.assert_eq(Source.create_example(function() return nil, "absent" end, function() return false end, "/owned/source"), false)
		end)
		helpers.it("loads a factory once and preserves Unicode metadata without executing callbacks", function()
			local content = [[return function(api)
				api.factory_loaded()
				return {{id="clock",suffix="@é",preview="Clock",callback=function() api.executed(); return "0" end}}
			end]]
			local loaded, executed = 0, 0
			local read = function() return content, "ok" end
			local rules, receipt = Source.load(read, "/owned/source", {
				factory_loaded = function() loaded = loaded + 1 end,
				executed = function() executed = executed + 1 end,
			})
			helpers.assert_eq(loaded, 1)
			helpers.assert_eq(executed, 0)
			helpers.assert_eq(rules[1].suffix, "@é")
			helpers.assert_true(Source.current(read, receipt))
			content = content .. "\n-- changed"
			helpers.assert_eq(Source.current(read, receipt), false)
		end)
		helpers.it("refuses syntax, factory and descriptor errors without source disclosure", function()
			for _, case in ipairs({
				{ source = "not lua!", expected = "source-syntax" },
				{ source = "return {}", expected = "source-factory" },
				{ source = "return function() error('PRIVATE') end", expected = "source-factory" },
				{ source = "return function() return {{id='bad'}} end", expected = "invalid-rule" },
			}) do
				local rules, _, problem = Source.load(function() return case.source, "ok" end, "/owned/source", {})
				helpers.assert_eq(rules, nil)
				helpers.assert_eq(problem, case.expected)
			end
		end)
	end)
end

return M
