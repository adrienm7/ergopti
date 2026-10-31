--- tests/unit/platform/remap/lease/test_lease_controller_guardian_receipts.lua

--- ==============================================================================
--- MODULE: Lease Controller Activation Identity Regression
--- DESCRIPTION:
--- Exercises real lease ownership with task and timer callbacks kept in one scope.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.platform.remap.lease.lease_controller_fixture"] = nil
local Fixture = require("tests.support.platform.remap.lease.lease_controller_fixture")
local with_fixture = Fixture.with_fixture





helpers.describe("karabiner guardian unregistration receipts", function()
	helpers.it("joins OFF requests and blocks all activation until exact native settlement", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local results = {}
			helpers.assert_true(controller.unregister_guardian(function(ok) results[#results + 1] = ok end))
			helpers.assert_true(controller.unregister_guardian(function(ok) results[#results + 1] = ok end))
			helpers.assert_eq(#ctx.spawns, 1)
			helpers.assert_eq(ctx.spawns[1].args[1], "--unregister-remap-guardian")
			helpers.assert_eq(controller.status(), "unregistering")
			helpers.assert_nil(controller.token())
			helpers.assert_eq(controller.start(), false)
			local probe, reason = controller.register_guardian(function() end)
			helpers.assert_nil(probe)
			helpers.assert_eq(reason, "guardian-unregistration-in-progress")
			helpers.assert_eq(#results, 0)
			ctx.complete(1, 0, "unregistered\n")
			helpers.assert_true(helpers.deep_equal(results, { true, true }))
			helpers.assert_eq(controller.status(), "idle")
			helpers.assert_true(controller.guardian_registration_required())
			helpers.assert_true(type(controller.token()) == "string")
		end)
	end)

	helpers.it("rejects stale registration cancellation until its real exit", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller({ terminate_results = { "pending" } })
			controller.init()
			local registration = controller.register_guardian(function() end)
			helpers.assert_true(registration.terminate())
			local result, reason
			helpers.assert_eq(controller.unregister_guardian(function(ok, detail) result, reason = ok, detail end), false)
			helpers.assert_eq(result, false)
			helpers.assert_eq(reason, "guardian-owner-busy")
			helpers.assert_eq(#ctx.spawns, 1)
			ctx.spawns[1].settle()
			helpers.assert_true(controller.unregister_guardian(function(ok) result = ok end))
			ctx.complete(2, 0, "unregistered\n")
			helpers.assert_true(result)
		end)
	end)

	helpers.it("requires the exact receipt and leaves registration due after every partial refusal", function()
		with_fixture(function(load_controller)
			for _, case in ipairs({
				{ code = 0, stdout = "refused\n" }, { code = 0, stdout = "unregistered" },
				{ code = 0, stdout = "unregistered\nready\n" }, { code = 1, stdout = "unregistered\n" },
			}) do
				local controller, ctx = load_controller()
				controller.init()
				local result
				controller.unregister_guardian(function(ok) result = ok end)
				ctx.complete(1, case.code, case.stdout)
				helpers.assert_eq(result, false)
				helpers.assert_eq(controller.status(), "idle")
				helpers.assert_true(controller.guardian_registration_required())
			end
		end)
	end)

	helpers.it("retains activation debt when native start refuses until cleanup acknowledges exit", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			ctx.next_start_result = false
			ctx.start_refusal_debt = true
			local result, reason
			helpers.assert_true(controller.unregister_guardian(function(ok, detail) result, reason = ok, detail end))
			helpers.assert_nil(result)
			helpers.assert_eq(controller.status(), "unregistering")
			helpers.assert_nil(controller.token())
			ctx.spawns[1].settle()
			helpers.assert_eq(result, false)
			helpers.assert_eq(reason, "helper-start-failed")
			helpers.assert_eq(controller.status(), "idle")
			helpers.assert_true(type(controller.token()) == "string")
		end)
	end)

	helpers.it("refuses outstanding prepared leases before native removal", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			controller.token()
			local result
			helpers.assert_eq(controller.unregister_guardian(function(ok) result = ok end), false)
			helpers.assert_eq(result, false)
			helpers.assert_eq(#ctx.spawns, 0)
		end)
	end)

	helpers.it("keeps an ad hoc registration note and refuses unknown or probe notes", function()
		with_fixture(function(load_controller)
			local controller, ctx = load_controller()
			controller.init()
			local answered
			controller.register_guardian(function(status) answered = status end)
			ctx.complete(1, 0, "ready\ndeveloper_adhoc_legacy_only\n")
			helpers.assert_eq(answered, "ready")
			local note, status = controller.guardian_registration_note()
			helpers.assert_eq(note, "developer_adhoc_legacy_only")
			helpers.assert_eq(status, "ready")
			helpers.assert_eq(controller.guardian_registration_required(), false)

			-- The retired reset note is no longer a launcher answer.
			for _, stdout in ipairs({ "ready\nunknown_note\n", "ready\ndeveloper_adhoc_legacy_only", "ready\nready\n",
				"ready\ndeveloper_adhoc_reregistered\n" }) do
				local refused, failure = load_controller()
				refused.init()
				local status, reason = "unset", nil
				refused.register_guardian(function(observed, detail) status, reason = observed, detail end)
				failure.complete(1, 0, stdout)
				helpers.assert_nil(status)
				helpers.assert_true(type(reason) == "string")
				helpers.assert_nil(refused.guardian_registration_note())
				helpers.assert_true(refused.guardian_registration_required())
			end

			local probed, probe_ctx = load_controller()
			probed.init()
			local probe_status = "unset"
			probed.probe_guardian_status(function(observed) probe_status = observed end)
			probe_ctx.complete(1, 0, "ready\ndeveloper_adhoc_legacy_only\n")
			helpers.assert_nil(probe_status)
		end)
	end)
end)
