--- tests/unit/ui/menu/menu_llm/download/test_process_identity.lua

--- ==============================================================================
--- MODULE: MLX Download Process Identity
--- DESCRIPTION:
--- Exercises one download ownership boundary without weakening receipt assertions.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture_support = require("tests.support.mlx_download_fixture")
local with_fixture = fixture_support.with_fixture
local launch_detached_download = fixture_support.launch_detached_download

local function assert_successor_admitted(fixture)
	helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
		{is_current = function() return true end}), true,
		"settled detached cleanup must release the single download slot")
end

helpers.describe("HS-036 detached download cleanup owns a process identity", function()
	helpers.it("trusts the current download exit file before any PID signal", function()
		with_fixture({pid_alive = true, pid_identity = true}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			launch_detached_download(fixture)
			local tail = fixture.controls.latest("tail")
			fixture.controls.exit_code = 1

			fixture.controls.window.on_cancel()
			tail:complete(0)

			helpers.assert_eq(fixture.records.raw_pid_signals, 0,
				"an authoritative exit file must suppress the legacy raw PID signal")
			helpers.assert_eq(fixture.records.verified_pid_signals, 0,
				"an authoritative exit file must suppress even a verified PID signal")
			assert_successor_admitted(fixture)
		end)
	end)

	helpers.it("trusts the reattached exit file before any PID signal", function()
		with_fixture({pid_alive = true, pid_identity = true}, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			local tail = fixture.controls.latest("tail")
			fixture.controls.exit_code = 1

			fixture.controls.window.on_cancel()
			tail:complete(0)

			helpers.assert_eq(fixture.records.raw_pid_signals, 0)
			helpers.assert_eq(fixture.records.verified_pid_signals, 0)
			assert_successor_admitted(fixture)
		end)
	end)

	helpers.it("releases a current-download PID recycled by another process", function()
		with_fixture({pid_alive = true, pid_identity = false}, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			launch_detached_download(fixture)
			local tail = fixture.controls.latest("tail")

			fixture.controls.window.on_cancel()
			tail:complete(0)

			helpers.assert_eq(fixture.records.pid_identity_probes, 1,
				"cleanup must verify the exact Python script before signalling a live PID")
			helpers.assert_eq(fixture.records.raw_pid_signals, 0,
				"a recycled PID must never reach an unverified signal call")
			helpers.assert_eq(fixture.records.verified_pid_signals, 0,
				"a mismatched process identity must never receive a signal")
			assert_successor_admitted(fixture)
		end)
	end)

	helpers.it("releases a reattached PID recycled by another process", function()
		with_fixture({pid_alive = true, pid_identity = false}, function(fixture)
			helpers.assert_true(fixture.controls.reattach())
			local tail = fixture.controls.latest("tail")

			fixture.controls.window.on_cancel()
			tail:complete(0)

			helpers.assert_eq(fixture.records.pid_identity_probes, 1)
			helpers.assert_eq(fixture.records.raw_pid_signals, 0)
			helpers.assert_eq(fixture.records.verified_pid_signals, 0)
			assert_successor_admitted(fixture)
		end)
	end)

	helpers.it("bounds verified TERM retries before KILL escalation", function()
		local plan = {pid_alive = true, pid_identity = true}
		with_fixture(plan, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			launch_detached_download(fixture)
			local tail = fixture.controls.latest("tail")

			fixture.controls.window.on_cancel()
			for _ = 1, 3 do fixture.controls.fire(0.25) end
			helpers.assert_eq(fixture.records.verified_term_signals, 4,
				"cleanup must bound graceful termination attempts")
			helpers.assert_eq(fixture.records.verified_kill_signals, 0)

			fixture.controls.fire(0.25)
			helpers.assert_eq(fixture.records.verified_term_signals, 4)
			helpers.assert_eq(fixture.records.verified_kill_signals, 1,
				"a still-owned PID must escalate after the bounded TERM budget")
			helpers.assert_eq(fixture.records.raw_pid_signals, 0)

			plan.pid_alive = false
			fixture.controls.fire(0.25)
			tail:complete(0)
			assert_successor_admitted(fixture)
		end)
	end)

	helpers.it("retains an inconclusive identity without signalling", function()
		local plan = {pid_alive = true, pid_identity = "unknown"}
		with_fixture(plan, function(fixture)
			helpers.assert_true(fixture.controls.pull())
			launch_detached_download(fixture)
			local tail = fixture.controls.latest("tail")

			fixture.controls.window.on_cancel()
			tail:complete(0)
			helpers.assert_eq(fixture.records.verified_pid_signals, 0)
			helpers.assert_eq(fixture.records.raw_pid_signals, 0)
			helpers.assert_eq(fixture.obj.pull_model("C", "org/other", nil, nil,
				{is_current = function() return true end}), false,
				"an inconclusive identity must retain the cleanup owner")

			plan.pid_identity = false
			fixture.controls.fire(0.25)
			assert_successor_admitted(fixture)
		end)
	end)
end)
