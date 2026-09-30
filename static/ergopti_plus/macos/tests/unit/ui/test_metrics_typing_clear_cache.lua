--- tests/unit/ui/test_metrics_typing_clear_cache.lua

--- ==============================================================================
--- MODULE: Typing Metrics Cache Reset Behavior
--- DESCRIPTION:
--- An acknowledged reset deletes the snapshot, drops cached projections, and
--- projects fresh data instead of replaying a retired range.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_delivery = require("tests.support.typing_delivery_fixture")

helpers.describe("typing metrics cache reset", function()
	helpers.it("(ui-windows-b-3) resets cached state and prevents old-query replay", function()
		with_delivery(function(_, context, _, errors, _, evaluations)
			local previous_remove = os.remove
			local ok, err = xpcall(function()
				local removals = 0
				os.remove = function() removals = removals + 1; return true end
				local json = require("json")
				package.loaded["hs.json"].encode = json.encode
				package.loaded["hs.json"].decode = json.decode
				local source_reads = 0
				package.loaded["modules.keylogger.log_manager"].get_sqlite_path = function()
					source_reads = source_reads + 1
					return nil
				end
				local projection = package.loaded["ui.metrics_typing.projection"]
				local resets = 0
				projection.reset = function() resets = resets + 1 end
				context.poll()
				evaluations[1].done('{"action":"clear_cache","reset_id":1}')
				helpers.assert_eq(removals, 0, "reset waits for acknowledgement")
				helpers.assert_eq(resets, 0)
				evaluations[2].done(true)
				helpers.assert_eq(removals, 2, "the snapshot and any partial save are deleted")
				helpers.assert_eq(resets, 1, "cached projections are dropped with the snapshot")
				helpers.assert_eq(source_reads, 0, "the reset itself reads nothing")
				helpers.assert_eq(evaluations[3].code, "window.complete_cache_reset(1,true);")
				evaluations[3].done(true)
				context.settle_jobs()
				helpers.assert_eq(source_reads, 1, "a fresh projection replaces the cleared one")
				helpers.assert_eq(#evaluations, 4)
				helpers.assert_eq(evaluations[4].code, "typeof window.publishTypingMetricsData")
				for _, evaluation in ipairs(evaluations) do
					helpers.assert_nil(evaluation.code:find("receive_range_data", 1, true),
						"no retired range is replayed")
				end
				helpers.assert_eq(#errors, 0)
			end, debug.traceback)
			os.remove = previous_remove
			if not ok then error(err, 0) end
		end)
	end)
end)
