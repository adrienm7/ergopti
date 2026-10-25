--- tests/unit/adapters/processes/test_shell_runner_private_output_cleanup.lua

--- ==============================================================================
--- MODULE: Private Shell Output Cleanup Ownership
--- DESCRIPTION:
--- Actual cipher commands run through the real ShellRunner over a faithful
--- native pipe/file model. A refused unlink must retain its exact private file,
--- refuse output publication and block another allocation until cleanup commits.
--- ==============================================================================

local helpers = require("tests.helpers")
local Double = require("tests.support.keystats.cipher_shell_double")
local COMMAND = "openssl enc -aes-256-cbc -K private-command-key"
local INPUT = "private typed material"

--- Runs one scenario through the real adapter and the cipher's native boundary.
--- @param faults table Mutable native faults.
--- @param body function Receives (runner, native, logs, logger).
local function with_runner(faults, body)
	helpers.with_fresh_modules({ "adapters.shell_runner", "infra.logger" }, function()
		local execute, _, native = Double.new(faults)
		helpers.load_with_stubs("adapters.shell_runner", { execute = execute })
		local logger, logs = helpers.make_logger_stub(), {}
		for _, level in ipairs({ "error", "debug", "warn", "info" }) do
			logger[level] = function(_, template, ...)
				logs[#logs + 1] = string.format(template, ...)
			end
		end
		package.loaded["infra.logger"] = logger
		package.loaded["adapters.shell_runner"] = nil
		local runner = require("adapters.shell_runner")
		runner._set_private_stdin_native(native)
		local ok, err = xpcall(function() body(runner, native, logs, logger) end, debug.traceback)
		runner._set_private_stdin_native(nil)
		if not ok then error(err, 0) end
	end)
end

helpers.describe("private shell output retains native cleanup ownership", function()
	helpers.it("refuses publication and new allocations after nil-error unlink refusal (private-output-unlink)", function()
		local faults = { cleanup_refused = true }
		with_runner(faults, function(runner, native, logs)
			local output, reason = runner.exec_private_stdin(COMMAND, INPUT)
			helpers.assert_nil(output, "private output must not publish before its file is removed")
			helpers.assert_true(type(reason) == "string" and reason ~= "")
			local retained = native.leftover_files()
			helpers.assert_eq(#retained, 1)
			helpers.assert_true(#logs > 0, "a native unlink refusal must be visible")
			helpers.assert_nil(runner.exec_private_stdin(COMMAND, "a later private value"))
			helpers.assert_eq(native.allocation_count(), 1, "unsettled cleanup must not allocate another file")
			helpers.assert_eq(native.leftover_files(), retained)
			faults.cleanup_refused = false
			helpers.assert_eq(runner.exec_private_stdin(COMMAND, INPUT), "C" .. Double.to_hex(INPUT))
			helpers.assert_eq(#native.leftover_files(), 0)
			helpers.assert_eq(native.allocation_count(), 2)
			for _, line in ipairs(logs) do
				helpers.assert_true(not line:find(INPUT, 1, true))
				helpers.assert_true(not line:find("private-command-key", 1, true))
				helpers.assert_true(not line:find(retained[1], 1, true), "cleanup diagnostics must not quote private paths")
			end
		end)
	end)

	helpers.it("uses the retained native boundary after a test provider changes (private-output-native-owner)", function()
		local faults = { cleanup_refused = true }
		with_runner(faults, function(runner, native)
			helpers.assert_nil(runner.exec_private_stdin(COMMAND, INPUT))
			local _, _, successor = Double.new()
			runner._set_private_stdin_native(successor)
			helpers.assert_nil(runner.exec_private_stdin(COMMAND, INPUT))
			helpers.assert_eq(successor.allocation_count(), 0)
			faults.cleanup_refused = false
			helpers.assert_eq(runner.exec_private_stdin(COMMAND, INPUT), "C" .. Double.to_hex(INPUT))
			helpers.assert_eq(#native.leftover_files(), 0)
			helpers.assert_eq(#successor.leftover_files(), 0)
			helpers.assert_eq(successor.allocation_count(), 1)
		end)
	end)

	helpers.it("accepts an independent absence proof and refuses unreadable cleanup metadata (private-output-absence)", function()
		local faults = { cleanup_refused = true, cleanup_status_error = true }
		with_runner(faults, function(runner, native)
			helpers.assert_nil(runner.exec_private_stdin(COMMAND, INPUT))
			local path = native.leftover_files()[1]
			faults.cleanup_refused = false
			helpers.assert_true(native.remove(path))
			faults.cleanup_refused = true
			helpers.assert_nil(runner.exec_private_stdin(COMMAND, INPUT))
			helpers.assert_eq(native.allocation_count(), 1, "failed metadata cannot prove absence")
			faults.cleanup_status_error, faults.cleanup_refused = false, false
			helpers.assert_eq(runner.exec_private_stdin(COMMAND, INPUT), "C" .. Double.to_hex(INPUT))
			helpers.assert_eq(native.allocation_count(), 2)
			helpers.assert_eq(#native.leftover_files(), 0)
		end)
	end)

	helpers.it("fences reentrant work inside a process-exit diagnostic (private-output-reentry)", function()
		with_runner({}, function(runner, native, logs, logger)
			local debug_log = logger.debug
			local observed, nested, reason = false, nil, nil
			logger.debug = function(tag, template, ...)
				if not observed and template:find("Process '", 1, true) then
					observed = true
					nested, reason = runner.exec_private_stdin(COMMAND, "nested private value")
				end
				return debug_log(tag, template, ...)
			end
			helpers.assert_eq(runner.exec_private_stdin(COMMAND, INPUT), "C" .. Double.to_hex(INPUT))
			helpers.assert_true(observed, "the real process-exit recorder must reach the diagnostic")
			helpers.assert_nil(nested, "a synchronous private transaction must not reenter before cleanup")
			helpers.assert_true(type(reason) == "string" and reason ~= "")
			helpers.assert_eq(native.allocation_count(), 1)
			helpers.assert_eq(#native.leftover_files(), 0)
		end)
	end)

	helpers.it("retains cleanup after an already-refused input delivery (private-output-failed-input)", function()
		local faults = { producer = 1, cleanup_refused = true }
		with_runner(faults, function(runner, native)
			helpers.assert_nil(runner.exec_private_stdin(COMMAND, INPUT))
			helpers.assert_eq(#native.leftover_files(), 1)
			helpers.assert_nil(runner.exec_private_stdin(COMMAND, INPUT))
			helpers.assert_eq(native.allocation_count(), 1,
				"a failed pipe delivery still owns its uncleared private output file")
			faults.producer, faults.cleanup_refused = nil, false
			helpers.assert_eq(runner.exec_private_stdin(COMMAND, INPUT), "C" .. Double.to_hex(INPUT))
			helpers.assert_eq(#native.leftover_files(), 0)
		end)
	end)

	helpers.it("settles its file and busy frame after a diagnostic raises (private-output-diagnostic-error)", function()
		with_runner({}, function(runner, native, logs, logger)
			local debug_log = logger.debug
			logger.debug = function()
				logger.debug = debug_log
				error(INPUT .. " private-command-key")
			end
			local output, reason = runner.exec_private_stdin(COMMAND, INPUT)
			helpers.assert_nil(output, "a diagnostic failure must not publish an unfinished private transaction")
			helpers.assert_true(type(reason) == "string" and reason ~= "")
			helpers.assert_eq(#native.leftover_files(), 0)
			helpers.assert_eq(runner.exec_private_stdin(COMMAND, INPUT), "C" .. Double.to_hex(INPUT))
			helpers.assert_eq(native.allocation_count(), 2, "the failed frame must release admission for a healthy retry")
			for _, line in ipairs(logs) do
				helpers.assert_true(not line:find(INPUT, 1, true))
				helpers.assert_true(not line:find("private-command-key", 1, true))
			end
		end)
	end)

	helpers.it("keeps failed process output refused while cleaning its exact file (private-output-exit-control)", function()
		with_runner({ encrypt = { "private partial output", 1 } }, function(runner, native)
			local output, reason = runner.exec_private_stdin(COMMAND, INPUT)
			helpers.assert_nil(output)
			helpers.assert_true(type(reason) == "string" and reason ~= "")
			helpers.assert_eq(#native.leftover_files(), 0)
		end)
	end)
end)
