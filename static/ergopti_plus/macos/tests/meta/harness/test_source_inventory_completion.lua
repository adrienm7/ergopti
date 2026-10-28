--- tests/meta/harness/test_source_inventory_completion.lua

--- ==============================================================================
--- MODULE: Source Inventory Completion Regressions
--- DESCRIPTION:
--- Partial inventories must neither become source evidence nor poison the
--- shared source cache. Independent command consumers retain stream cleanup.
--- ==============================================================================

local helpers = require("tests.helpers")
local Discovery = require("test.runner_discovery")
local CommandLines = require("tests.support.command_lines")

helpers.describe("source inventory completion", function()
	helpers.it("(source-inventory-completion) rejects failed partial output before reading or caching it", function()
		helpers.with_fresh_modules({ "tests.helpers" }, function()
			local subject = require("tests.helpers")
			local discover, open = Discovery.files, io.open
			local attempts, reads, closes = 0, 0, 0
			Discovery.files = function()
				attempts = attempts + 1
				if attempts == 1 then return nil, "controlled native inventory refusal 7" end
				return { subject.driver_root() .. "inventory_probe.lua" }
			end
			io.open = function()
				reads = reads + 1
				return {
					read = function() return "-- complete inventory source" end,
					close = function() closes = closes + 1; return true end,
				}
			end
			local outcome = table.pack(pcall(function()
				local ok, reason = pcall(subject.read_driver_source)
				helpers.assert_eq(ok, false, "a failed enumeration must reject its partial output")
				helpers.assert_true(tostring(reason):find("7", 1, true) ~= nil, "retain the native refusal")
				helpers.assert_eq(reads, 0, "do not open sources from an incomplete inventory")
				helpers.assert_eq(subject.read_driver_source(), "-- complete inventory source")
				helpers.assert_eq(attempts, 2, "a failed inventory must not be cached")
				helpers.assert_eq(reads, 1)
				helpers.assert_eq(closes, 1, "close the acquired complete source handle")
			end))
			Discovery.files, io.open = discover, open
			if not outcome[1] then error(outcome[2], 0) end
		end)
	end)

	helpers.it("(source-inventory-completion) closes failed and complete command inventories", function()
		local popen = io.popen
		local attempts, closes = 0, 0
		io.popen = function()
			attempts = attempts + 1
			local attempt, emitted = attempts, false
			return {
				lines = function() return function()
					if emitted then return nil end
					emitted = true
					return "complete_source.lua"
				end end,
				close = function()
					closes = closes + 1
					if attempt == 1 then return nil, "exit", 7 end
					return true, "exit", 0
				end,
			}
		end
		local outcome = table.pack(pcall(function()
			local accepted, reason = pcall(CommandLines.read, "owned-inventory")
			helpers.assert_eq(accepted, false, "failed command output remains incomplete")
			helpers.assert_true(tostring(reason):find("7", 1, true) ~= nil, "retain the command exit code")
			helpers.assert_eq(CommandLines.read("owned-inventory"), { "complete_source.lua" })
			helpers.assert_eq(closes, 2, "close both command enumeration streams")
		end))
		io.popen = popen
		if not outcome[1] then error(outcome[2], 0) end
	end)
end)
