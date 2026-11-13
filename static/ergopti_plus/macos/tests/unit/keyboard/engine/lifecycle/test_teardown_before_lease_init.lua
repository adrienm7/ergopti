--- tests/unit/keyboard/engine/lifecycle/test_teardown_before_lease_init.lua

--- ==============================================================================
--- MODULE: Local Teardown Before Lease Initialization
--- DESCRIPTION:
--- A controlled quit during the first-run wizard, or on a Mac without
--- Karabiner, reaches the Karabiner local teardown before the lease
--- controller ever started. The installed-app gate failed every scenario on
--- the ERROR the lease status guard logged there once the launcher's quit
--- handshake (MLC-002) routed outside quits through the full teardown.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.guardian_recovery_fixture")
local count_logs = fixture.count_logs
local with_remap = fixture.with_remap
local with_controller = require("tests.support.lease_controller_fixture").with_fixture

helpers.describe("Karabiner local teardown before lease initialization", function()
	helpers.it("tears down an uninitialized lease without logging an ERROR", function()
		with_remap({ initial_phase = "idle", lease_uninitialized = true }, function(remap, calls)
			local errors = count_logs(calls, "error")
			helpers.assert_true(remap.teardown_local(),
				"a quit before the lease started has no lease to fence")
			helpers.assert_eq(count_logs(calls, "error"), errors,
				"a quit before the lease started must not log an ERROR")
		end)
	end)

	helpers.it("still checks the phase of an initialized lease", function()
		with_remap({ initial_phase = "idle" }, function(remap, calls)
			local status_calls = calls.lease_status_calls
			helpers.assert_true(remap.teardown_local())
			helpers.assert_true(calls.lease_status_calls > status_calls)
		end)
	end)

	helpers.it("answers a declared pre-init status query from the real controller without an ERROR", function()
		with_controller(function(load_controller)
			local controller, ctx = load_controller()
			local phase = controller.status({ before_init = "uninitialized" })
			helpers.assert_eq(phase, "uninitialized")
			helpers.assert_eq(#ctx.logs.error, 0, "a declared pre-init query is not an error")
			helpers.assert_eq(controller.status(), "uninitialized")
			helpers.assert_eq(#ctx.logs.error, 1, "an undeclared pre-init query still reports its caller")
			helpers.assert_true(not pcall(controller.status, { before_init = "idle" }),
				"an unknown option is refused")
			controller.init()
			helpers.assert_eq(controller.status({ before_init = "uninitialized" }), "idle",
				"an initialized controller answers its real phase")
		end)
	end)
end)
