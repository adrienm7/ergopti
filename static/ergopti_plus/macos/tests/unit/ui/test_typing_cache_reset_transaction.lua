--- tests/unit/ui/test_typing_cache_reset_transaction.lua

--- ==============================================================================
--- MODULE: Typing Cache Reset Transaction Tests
--- DESCRIPTION:
--- Commits memory reset only after deletion or authoritative native absence.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_delivery = require("tests.support.typing_delivery_fixture")

helpers.describe("typing cache reset transaction", function()
	helpers.it("(typing-cache-reset) repeated refusal remains bounded and explicit retry can commit", function()
		with_delivery(function(dashboard, context, _, errors, _, evaluations)
			local infos, removed = 0, false
			package.loaded["infra.logger"].info = function(_, template)
				if template == "Caches cleared by user reset." then infos = infos + 1 end
			end
			package.loaded["hs.json"].decode = function() return { action = "clear_cache" } end
			local original_remove = os.remove
			os.remove = function() if removed then return true end; return nil, "PRIVATE_DETAIL", 13 end
			local ok, err = xpcall(function()
				for index = 1, 3 do
					removed = index == 3
					context.poll()
					evaluations[#evaluations].done("request", nil)
					evaluations[#evaluations].done(true, nil)
				end
				helpers.assert_eq(#errors, 1)
				helpers.assert_eq(infos, 1)
				helpers.assert_nil(dashboard._last_query)
			end, debug.traceback)
			os.remove = original_remove
			if not ok then error(err, 0) end
		end)
	end)
	for _, mode in ipairs({ "refused", "false", "nil", "truthy", "throw", "absent", "success", "reentry", "log_reentry" }) do
		helpers.it("(typing-cache-reset) " .. mode, function()
			with_delivery(function(dashboard, context, _, errors, _, evaluations)
				local range, manifest, query = {}, {}, {}
				dashboard._range_cache, dashboard._manifest_cache, dashboard._last_query = range, manifest, query
				local infos, removals = 0, 0
				package.loaded["infra.logger"].info = function(_, template)
					if template == "Caches cleared by user reset." then infos = infos + 1 end
				end
				package.loaded["hs.json"].decode = function() return { action = "clear_cache" } end
				if mode == "log_reentry" then
					local capture = package.loaded["infra.logger"].error
					package.loaded["infra.logger"].error = function(...)
						capture(...)
						context.on_close()
					end
				end
				local original_remove = os.remove
				os.remove = function()
					removals = removals + 1
					if mode == "throw" then error("PRIVATE_DETAIL") end
					if mode == "refused" then return nil, "PRIVATE_DETAIL", 13 end
					if mode == "false" then return false end
					if mode == "nil" then return nil end
					if mode == "truthy" then return {} end
					if mode == "log_reentry" then return nil, "PRIVATE_DETAIL", 13 end
					if mode == "absent" then return nil, "PRIVATE_DETAIL", 2 end
					if mode == "reentry" then context.on_close() end
					return true
				end
				local ok, err = xpcall(function()
					context.poll()
					evaluations[1].done("request", nil)
					helpers.assert_eq(#evaluations, 2)
					evaluations[2].done(true, nil)
					helpers.assert_eq(removals, 1)
					local committed = mode == "success" or mode == "absent"
					helpers.assert_eq(infos, committed and 1 or 0)
					helpers.assert_eq(#errors, (not committed and mode ~= "reentry") and 1 or 0)
					if committed then
						helpers.assert_true(dashboard._range_cache ~= range)
						helpers.assert_nil(dashboard._manifest_cache)
						helpers.assert_nil(dashboard._last_query)
					else
						helpers.assert_eq(dashboard._range_cache, range)
						helpers.assert_eq(dashboard._manifest_cache, manifest)
						helpers.assert_eq(dashboard._last_query, query)
					end
					for _, message in ipairs(errors) do
						helpers.assert_eq(message, "Typing metrics cache reset failed (disk deletion; content withheld; repeats suppressed).")
					end
				end, debug.traceback)
				os.remove = original_remove
				if not ok then error(err, 0) end
			end)
		end)
	end
end)
