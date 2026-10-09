--- tests/unit/infra/test_source_inventory_completion.lua

--- ==============================================================================
--- MODULE: Source Inventory Completion Regressions
--- DESCRIPTION:
--- Partial command output must neither become source evidence nor poison the
--- shared source cache. A successful retry must perform a fresh enumeration.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("source inventory completion", function()
	helpers.it("(source-inventory-completion) rejects failed partial output before reading or caching it", function()
		helpers.with_fresh_modules({ "tests.helpers" }, function()
			local subject = require("tests.helpers")
			local popen, open = io.popen, io.open
			local attempts, reads, closes = 0, 0, 0
			io.popen = function()
				attempts = attempts + 1
				local attempt, emitted = attempts, false
				return {
					lines = function() return function()
						if emitted then return nil end
						emitted = true
						return subject.driver_root() .. "inventory_probe.lua"
					end end,
					close = function()
						closes = closes + 1
						if attempt == 1 then return nil, "exit", 7 end
						return true, "exit", 0
					end,
				}
			end
			io.open = function()
				reads = reads + 1
				return { read = function() return "-- complete inventory source" end, close = function() return true end }
			end
			local outcome = table.pack(pcall(function()
				local ok, reason = pcall(subject.read_driver_source)
				helpers.assert_eq(ok, false, "a failed enumeration must reject its partial output")
				helpers.assert_true(tostring(reason):find("7", 1, true) ~= nil, "retain the command's exit code")
				helpers.assert_eq(reads, 0, "do not open sources from an incomplete inventory")
				helpers.assert_eq(subject.read_driver_source(), "-- complete inventory source")
				helpers.assert_eq(attempts, 2, "a failed inventory must not be cached")
				helpers.assert_eq(closes, 2, "close both enumeration streams")
				helpers.assert_eq(reads, 1)
			end))
			io.popen, io.open = popen, open
			if not outcome[1] then error(outcome[2], 0) end
		end)
	end)
end)
