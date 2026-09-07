--- tests/unit/ui/test_hotstring_counter_listing_transaction.lua

--- ==============================================================================
--- MODULE: Hotstring Counter Listing Transaction Tests
--- DESCRIPTION:
--- Failed native enumeration cannot become an authoritative cached empty count.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_counter = require("tests.support.hotstring_counter_fixture")

helpers.describe("hotstring counter listing transaction", function()
	helpers.it("(hotstring-counter-listing) authoritative empty enumeration is cached", function()
		with_counter(function(counter, state, context)
			local calls = 0
			hs.fs.dir = function()
				calls = calls + 1
				local directory = {}
				return function(actual) helpers.assert_eq(actual, directory); return nil end, directory
			end
			local captured = package.loaded["infra.fs_dir"]
			package.loaded["infra.fs_dir"] = nil
			local real = require("infra.fs_dir")
			captured.entries, captured.try_entries = real.entries, real.try_entries
			helpers.assert_eq(counter.count_all(context, {}).ext, 0)
			helpers.assert_eq(counter.count_all(context, {}).ext, 0)
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(state.opens, 0)
			helpers.assert_eq(#state.errors, 0)
		end)
	end)
	for _, target in ipairs({ "root", "hotstrings" }) do
		for _, failure in ipairs({ "open", "iteration" }) do
			helpers.it("(hotstring-counter-listing) " .. target .. " " .. failure, function()
				with_counter(function(counter, state, context)
					local phase, calls = 1, 0
					hs.fs.dir = function(path)
						local root = path:match("/extensions/$") ~= nil
						local selected = (target == "root") == root
						if selected then calls = calls + 1 end
						if selected and phase == 1 and failure == "open" then error("native open refused") end
						local directory = { index = 0 }
						return function(actual)
							helpers.assert_eq(actual, directory, "native iterator requires exact directory state")
							directory.index = directory.index + 1
							if selected and phase == 1 and failure == "iteration" then error("native iteration refused") end
							if directory.index == 1 then return root and "demo" or "demo.toml" end
						end, directory
					end
					local captured = package.loaded["infra.fs_dir"]
					package.loaded["infra.fs_dir"] = nil
					local real = require("infra.fs_dir")
					captured.entries, captured.try_entries = real.entries, real.try_entries
					local ok, failure_message = pcall(counter.count_all, context, {})
					helpers.assert_eq(ok, false)
					helpers.assert_eq(failure_message, "Extension directory enumeration failed; hotstring counts were not published")
					helpers.assert_eq(#state.errors, 1, "native listing failure already owns its diagnostic")
					phase = 2
					helpers.assert_eq(counter.count_all(context, {}).ext, 1)
					helpers.assert_eq(calls, 2)
					helpers.assert_eq(counter.count_all(context, {}).ext, 1)
					helpers.assert_eq(calls, 2, "successful recovery becomes cached")
				end)
			end)
		end
	end
end)
