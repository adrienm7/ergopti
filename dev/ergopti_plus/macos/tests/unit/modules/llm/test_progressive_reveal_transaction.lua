--- tests/unit/modules/llm/test_progressive_reveal_transaction.lua

--- ==============================================================================
--- MODULE: Progressive Reveal Timer Transaction Regression
--- DESCRIPTION:
--- Drives partial timer activation, refused cleanup and stale-request delivery.
--- A scheduling failure must publish the complete batch instead of silently
--- leaving the tooltip with only its first prediction.
--- ==============================================================================

local helpers = require("tests.helpers")

local saved_scheduler = package.loaded["adapters.timer_scheduler"]
local saved_reveal = package.loaded["modules.llm.progressive_reveal"]

helpers.describe("LLM progressive reveal owns every timer transaction", function()
	helpers.it("falls forward to the complete batch when timer commit is refused", function()
		local exact_handle = { timer = {} }
		local cancel_calls = 0
		package.loaded["adapters.timer_scheduler"] = {
			after = function() return exact_handle, false end,
			cancel = function(handle)
				helpers.assert_eq(handle, exact_handle)
				cancel_calls = cancel_calls + 1
				return false
			end,
		}
		package.loaded["modules.llm.progressive_reveal"] = nil
		local Reveal = require("modules.llm.progressive_reveal")
		local sizes = {}
		Reveal.deliver({ "one", "two", "three" }, function(values)
			sizes[#sizes + 1] = #values
		end, 7, function() return true end)
		helpers.assert_eq(#sizes, 2)
		helpers.assert_eq(sizes[1], 1)
		helpers.assert_eq(sizes[2], 3,
			"an uncommitted reveal timer must publish the full result, never truncate output")
		helpers.assert_eq(cancel_calls, 1,
			"the exact partially-active timer must be cancelled and retained on refusal")
	end)

	helpers.it("generation-fences a committed reveal after the request becomes stale", function()
		local callback
		local handle = { timer = {} }
		package.loaded["adapters.timer_scheduler"] = {
			after = function(_, fn) callback = fn; return handle, true end,
			cancel = function(candidate)
				helpers.assert_eq(candidate, handle)
				candidate.timer = nil
				return true
			end,
		}
		package.loaded["modules.llm.progressive_reveal"] = nil
		local Reveal = require("modules.llm.progressive_reveal")
		local current = true
		local sizes = {}
		Reveal.deliver({ "one", "two", "three" }, function(values)
			sizes[#sizes + 1] = #values
		end, 7, function() return current end)
		current = false
		callback()
		helpers.assert_eq(#sizes, 1,
			"a deferred reveal from a stale request must not mutate the current tooltip")
	end)
end)

package.loaded["adapters.timer_scheduler"] = saved_scheduler
package.loaded["modules.llm.progressive_reveal"] = saved_reveal
