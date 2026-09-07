--- tests/unit/ui/test_metrics_typing_clear_cache.lua

--- ==============================================================================
--- MODULE: Typing Metrics Cache Reset Behavior
--- DESCRIPTION:
--- An acknowledged reset invalidates cached projections and the previous query.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_delivery = require("tests.support.typing_delivery_fixture")

helpers.describe("typing metrics cache reset", function()
	helpers.it("(ui-windows-b-3) resets cached state and prevents old-query replay", function()
		with_delivery(function(dashboard, context, timers, errors, _, evaluations)
			local previous_remove = os.remove
			local ok, err = xpcall(function()
				os.remove = function() return true end
				local json = require("json")
				package.loaded["hs.json"].encode = json.encode
				package.loaded["hs.json"].decode = json.decode
				local source_reads = 0
				package.loaded["modules.keylogger.log_manager"].get_sqlite_path = function()
					source_reads = source_reads + 1
					return nil
				end
				local old_range, old_manifest = { old = true }, { old = true }
				dashboard._range_cache = old_range
				dashboard._manifest_cache = old_manifest
				dashboard._last_query = { start_date = "2000-01-01", end_date = "2000-01-02", apps = { "Old" } }
				context.poll()
				evaluations[1].done('{"action":"clear_cache"}')
				helpers.assert_eq(dashboard._range_cache, old_range, "reset waits for acknowledgement")
				helpers.assert_eq(dashboard._manifest_cache, old_manifest)
				helpers.assert_type(dashboard._last_query, "table")
				evaluations[2].done(true)
				helpers.assert_eq(next(dashboard._range_cache), nil)
				helpers.assert_true(dashboard._range_cache ~= old_range)
				helpers.assert_nil(dashboard._manifest_cache)
				helpers.assert_nil(dashboard._last_query)
				helpers.assert_eq(source_reads, 0)
				helpers.assert_true(dashboard.push_live_update())
				timers[#timers]()
				helpers.assert_eq(source_reads, 1, "live refresh reads only the fresh manifest")
				helpers.assert_nil(dashboard._last_query)
				helpers.assert_eq(#evaluations, 3, "live refresh must not publish the retired range")
				evaluations[3].done(nil)
				helpers.assert_eq(#errors, 0)
			end, debug.traceback)
			os.remove = previous_remove
			if not ok then error(err, 0) end
		end)
	end)
end)
