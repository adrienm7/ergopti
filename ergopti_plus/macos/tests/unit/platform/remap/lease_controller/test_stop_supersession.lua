--- tests/unit/platform/remap/lease_controller/test_stop_supersession.lua

--- ==============================================================================
--- MODULE: Lease Controller Stop Supersession Regression
--- DESCRIPTION:
--- Pins the reasons the real controller gives the operations an accepted Stop
--- of their own generation supersedes. The remap coordinator reads them through
--- LeaseContract.is_superseded_by_stop to log such an activation at INFO: the
--- boot's RESUME fenced by a layout change logged « prepared lease RESUME
--- failed: lease-stopping » at ERROR and opened the error window
--- (lease-stop-supersedes-activation). A worker that never answers is still a
--- failure, never a supersession.
--- ==============================================================================

local helpers = require("tests.helpers")
local LeaseContract = require("platform.remap.lease_contract")
local support = require("tests.support.lease_controller_fixture")
local with_fixture = support.with_fixture

helpers.describe("karabiner lease controller: operations a Stop supersedes", function()
	helpers.it("(lease-stop-supersedes-activation) a Stop answers the pending READY wait as superseded", function()
		with_fixture(function(load_controller)
			local controller = load_controller()
			controller.init()
			local ready_ok, ready_reason = nil, nil
			helpers.assert_true(controller.start_paused(function(ok, reason)
				ready_ok, ready_reason = ok, reason
			end))
			helpers.assert_eq(controller.status(), "starting")

			helpers.assert_true(controller.stop("layout_changed_during_activation"))
			helpers.assert_true(ready_ok == false, "a stopped generation never reports READY")
			helpers.assert_eq(ready_reason, LeaseContract.STOPPED_BEFORE_READY)
			helpers.assert_true(LeaseContract.is_superseded_by_stop(ready_reason))
		end)
	end)

	helpers.it("(lease-stop-supersedes-activation) a Stop answers the RESUME in flight as superseded", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			helpers.assert_true(controller.start_paused())
			ctx.chunk(1, "READY\n")
			local _, snapshot = controller.status()
			local resumed_ok, resume_reason = nil, nil
			helpers.assert_true(controller.resume_prepared(snapshot.token, function(ok, reason)
				resumed_ok, resume_reason = ok, reason
			end))
			helpers.assert_eq(controller.status(), "resuming", "RESUME must be in flight")

			helpers.assert_true(controller.stop("layout_changed_during_activation"))
			helpers.assert_true(resumed_ok == false, "a stopped generation never reports RESUMED")
			helpers.assert_eq(resume_reason, LeaseContract.COMMAND_SUPERSEDED_BY_STOP)
			helpers.assert_true(LeaseContract.is_superseded_by_stop(resume_reason))
			helpers.assert_eq(controller.status(), "stopping",
				"the superseded generation is still fencing, owned by the Stop's requester")
		end)
	end)

	helpers.it("(lease-stop-supersedes-activation) a RESUME the worker never answers is not superseded", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			helpers.assert_true(controller.start_paused())
			ctx.chunk(1, "READY\n")
			local _, snapshot = controller.status()
			local variables = controller.variables()
			local resumed_ok, resume_reason = nil, nil
			helpers.assert_true(controller.resume_prepared(snapshot.token, function(ok, reason)
				resumed_ok, resume_reason = ok, reason
			end))

			ctx.fire_latest_timer()
			helpers.assert_eq(controller.status(), "fencing", "a silent worker is fenced as a failure")
			-- The failed RESUME settles once the exact native revoker completed.
			local revoker = support.find_native_revoke(ctx, variables)
			helpers.assert_not_nil(revoker)
			for index, task in ipairs(ctx.spawns) do
				if task == revoker then ctx.complete(index, 0, "") end
			end
			helpers.assert_true(resumed_ok == false)
			helpers.assert_type(resume_reason, "string")
			helpers.assert_true(not LeaseContract.is_superseded_by_stop(resume_reason),
				"a timed-out RESUME must stay a failure, got " .. tostring(resume_reason))
		end)
	end)

	helpers.it("(lease-stop-supersedes-activation) recognises exactly the two Stop reasons", function()
		helpers.assert_true(LeaseContract.is_superseded_by_stop("stopped-before-ready"))
		helpers.assert_true(LeaseContract.is_superseded_by_stop("lease-stopping"))
		for _, reason in ipairs({ "generation-stopping", "timeout waiting for RESUMED", "no-live-lease", "", nil }) do
			helpers.assert_true(not LeaseContract.is_superseded_by_stop(reason),
				"not a Stop supersession: " .. tostring(reason))
		end
	end)
end)
