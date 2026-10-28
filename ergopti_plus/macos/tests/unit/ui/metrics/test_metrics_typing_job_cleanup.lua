--- tests/unit/ui/metrics/test_metrics_typing_job_cleanup.lua

--- ==============================================================================
--- MODULE: Typing Metrics Projection Cleanup
--- DESCRIPTION:
--- Exercises real paced jobs through the dashboard's native cleanup boundaries.
--- A cancelled or completed computation still owns every refused timer stop.
--- ==============================================================================

local helpers = require("tests.helpers")
local Scope = require("tests.support.metrics_typing_scope")
local load_dashboard = require("tests.support.metrics_typing_fixture")

--- Loads real projection jobs behind independently observable timer ownership.
--- @return table dashboard
--- @return table context
local function fixture()
	local control = { pending = {}, stops = 0, resets = 0, removes = 0 }
	local scheduler = {
		after = function(_, callback)
			local handle = { timer = {}, callback = callback }
			control.pending[#control.pending + 1] = handle
			return handle, true
		end,
		every = function(_, callback) control.poll = callback; return { timer = {} }, true end,
		cancel = function(handle)
			if handle == control.refused then control.stops = control.stops + 1; return false end
			handle.timer = nil
			return true
		end,
	}
	local dashboard, native = load_dashboard(scheduler)
	control.native = native
	package.loaded["modules.keystats.log_manager"].get_sqlite_path = function() return nil end
	local snapshot = package.loaded["ui.metrics_typing.snapshot"]
	snapshot.load = function() return nil end
	snapshot.save = function() return true end
	snapshot.remove = function() control.removes = control.removes + 1; return true end
	package.loaded["ui.metrics_typing.projection"].reset = function() control.resets = control.resets + 1 end
	function control.fire(handle)
		-- One-shot delivery can run even when its native stop remains refused
		scheduler.cancel(handle)
		handle.callback()
	end
	helpers.assert_true(dashboard.show())
	control.fire(control.pending[1])
	helpers.assert_type(dashboard._job, "table", "bootstrap must own a real paced projection")
	return dashboard, control
end

helpers.describe("typing metrics projection custody", function()
	Scope.it("retains a refused cancelled job before opening a successor (metrics-job-cleanup)", function()
		local dashboard, control = fixture()
		local job = dashboard._job
		control.refused = job.timer
		helpers.assert_eq(dashboard.close(), false)
		helpers.assert_true(rawequal(dashboard._job, job), "native stop refusal must retain the exact job")
		helpers.assert_eq(job.state, "cancelled", "logical cancellation fences every queued slice")
		helpers.assert_eq(dashboard.show(), false, "a successor must wait for retained job cleanup")
		helpers.assert_eq(control.native.webviews_created, 1)
		helpers.assert_eq(control.stops, 2, "reopen must retry the exact cancelled timer")
		control.refused = nil
		helpers.assert_true(dashboard.show())
		helpers.assert_nil(dashboard._job)
		helpers.assert_nil(job.timer)
		helpers.assert_eq(control.native.webviews_created, 2)
		helpers.assert_true(dashboard.close())
	end)

	Scope.it("retains terminal projection cleanup before admitting more work (metrics-job-cleanup)", function()
		local dashboard, control = fixture()
		local job = dashboard._job
		local timer = job.timer
		control.refused = timer
		control.fire(timer)
		helpers.assert_eq(job.state, "done", "the real computation must finish before native cleanup")
		helpers.assert_true(rawequal(dashboard._job, job), "business completion must retain refused native cleanup")
		dashboard.push_live_update()
		control.fire(control.pending[#control.pending])
		helpers.assert_true(rawequal(dashboard._job, job), "a refused terminal job still blocks a new projection")
		control.refused = nil
		dashboard.push_live_update()
		control.fire(control.pending[#control.pending])
		helpers.assert_true(dashboard._job ~= nil and not rawequal(dashboard._job, job))
		helpers.assert_nil(timer.timer, "a successor needs exact cleanup acknowledgement")
		helpers.assert_true(dashboard.close())
	end)

	Scope.it("refuses cache reset until the running projection retires (metrics-job-cleanup)", function()
		local dashboard, control = fixture()
		local job = dashboard._job
		local timer = job.timer
		control.refused = timer
		local Json = require("json")
		package.loaded["hs.json"].decode = Json.decode
		local reset_id, acknowledgements = 1, {}
		function control.native.webview:evaluateJavaScript(code, callback)
			if code == "window._lua_request" then
				callback(Json.encode({ action = "clear_cache", reset_id = reset_id }), nil)
			elseif code:find("window._lua_request!==", 1, true) then
				callback(true, nil)
			elseif code:find("window.complete_cache_reset", 1, true) then
				acknowledgements[#acknowledgements + 1] = code
				callback(true, nil)
			end
			return self
		end
		control.poll()
		helpers.assert_eq(control.removes, 0, "a refused cancellation cannot delete the disk snapshot")
		helpers.assert_eq(control.resets, 0, "a refused cancellation cannot reset a live projection cache")
		helpers.assert_true(rawequal(dashboard._job, job))
		helpers.assert_contains(acknowledgements[1], "(1,false)")
		control.refused, reset_id = nil, 2
		control.poll()
		helpers.assert_eq(control.removes, 1, "only the settled reset may remove the disk snapshot")
		helpers.assert_eq(control.resets, 1)
		helpers.assert_nil(timer.timer, "a completed cache reset must settle the old native timer")
		helpers.assert_contains(acknowledgements[2], "(2,true)")
		helpers.assert_true(dashboard._job ~= nil and not rawequal(dashboard._job, job))
		helpers.assert_true(dashboard.close())
	end)
end)
