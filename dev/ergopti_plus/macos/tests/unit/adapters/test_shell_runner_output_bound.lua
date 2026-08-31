--- tests/unit/adapters/test_shell_runner_output_bound.lua

--- ==============================================================================
--- MODULE: ShellRunner captured-output bound regression tests
--- DESCRIPTION:
--- Drives the real non-streaming completion boundary with oversized native
--- stdout/stderr. Runaway output must never reach consumer parsers or trigger
--- success, while an exact-limit payload remains byte-for-byte observable.
--- ==============================================================================

local helpers = require("tests.helpers")

local MAX_CAPTURED_OUTPUT_BYTES = 4 * 1024 * 1024

local function with_task(callback)
	local captured_done = nil
	local business_terminal = nil
	local task = {
		start = function(self) return self end,
		terminate = function(self) return self end,
	}
	local ShellRunner = helpers.load_with_stubs("adapters.shell_runner", {
		task = {
			new = function(_, on_done, args)
				helpers.assert_type(args, "table",
					"the non-streaming constructor form must receive argv as its third argument")
				captured_done = on_done
				return task
			end,
		},
	})
	local handle = ShellRunner.spawn("/fixture/runaway", {}, function(exit_code, stdout, stderr)
		business_terminal = {
			exit_code = exit_code,
			stdout = stdout,
			stderr = stderr,
		}
	end)
	helpers.assert_true(handle.start())
	helpers.assert_type(captured_done, "function")
	callback(captured_done, function() return business_terminal end)
end

helpers.describe("ShellRunner: captured output is bounded before consumer delivery", function()
	helpers.it("rejects oversized stdout without forwarding its bytes (HS-130-output-cap)", function()
		with_task(function(done, terminal)
			local runaway = string.rep("x", MAX_CAPTURED_OUTPUT_BYTES + 1)
			done(0, runaway, "")
			local observed = terminal()
			helpers.assert_not_nil(observed)
			helpers.assert_true(observed.exit_code ~= 0,
				"oversized output must never retain a successful process result")
			helpers.assert_eq("", observed.stdout,
				"none of the runaway stdout may reach the consumer")
			helpers.assert_true(#observed.stderr < 1024,
				"the synthetic failure detail must stay independently bounded")
			helpers.assert_true(observed.stderr:find("output limit", 1, true) ~= nil,
				"the caller must receive an actionable bounded failure")
		end)
	end)

	helpers.it("counts stdout and stderr against one shared budget", function()
		with_task(function(done, terminal)
			done(0,
				string.rep("o", MAX_CAPTURED_OUTPUT_BYTES / 2),
				string.rep("e", MAX_CAPTURED_OUTPUT_BYTES / 2 + 1))
			local observed = terminal()
			helpers.assert_not_nil(observed)
			helpers.assert_true(observed.exit_code ~= 0)
			helpers.assert_eq("", observed.stdout)
		end)
	end)

	helpers.it("preserves an exact-limit payload byte-for-byte", function()
		with_task(function(done, terminal)
			local stdout = string.rep("a", MAX_CAPTURED_OUTPUT_BYTES - 3)
			done(0, stdout, "err")
			local observed = terminal()
			helpers.assert_not_nil(observed)
			helpers.assert_eq(0, observed.exit_code)
			helpers.assert_eq(stdout, observed.stdout)
			helpers.assert_eq("err", observed.stderr)
		end)
	end)
end)
