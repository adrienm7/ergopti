--- tests/meta/harness/test_runner_integrity.lua

--- ==============================================================================
--- MODULE: Linux Test Runner Integrity Regression Tests
--- DESCRIPTION:
--- Proves that empty/partial discovery, missing modules and unmatched filters are
--- failures. LNX-037 previously let all of them produce a green zero-test run.
--- ==============================================================================

local helpers = require("tests.helpers")
local Contract = require("tests.runner_contract")
local CONTINUATION_MODULE = "tests.unit.infra.scope.test_global_shortcuts_pair_scope"

--- Keeps the continuation actor's deliberate failure and headers out of the real tally.
--- @param body function Owned private actor, given its retained transcript.
--- @return any result Private actor result.
--- @return table transcript Private diagnostic lines.
local function capture_continuation(body)
	local modules = package.loaded
	local old_helpers, old_module = modules["tests.helpers"], modules[CONTINUATION_MODULE]
	local old_exit, old_print = os.exit, print
	local transcript = {}
	print = function(...)
		local parts = {}
		for index = 1, select("#", ...) do parts[index] = tostring(select(index, ...)) end
		transcript[#transcript + 1] = table.concat(parts, "\t")
	end
	local ok, result = xpcall(function() return body(transcript) end, debug.traceback)
	print, os.exit = old_print, old_exit
	modules["tests.helpers"], modules[CONTINUATION_MODULE] = old_helpers, old_module
	if not ok then error(result, 0) end
	return result, transcript
end

helpers.describe("linux test runner: truthful execution", function()

	helpers.it("accepts an exact manifest and a nonzero explicit subset", function()
		local discovered = { "tests.unit.test_alpha", "tests.unit.test_beta" }
		local manifest_ok = Contract.audit_manifest(discovered, discovered)
		local execution_ok = Contract.audit_execution(2, 1, 0, "alpha")

		helpers.assert_true(manifest_ok, "an exact discovered manifest is valid")
		helpers.assert_true(execution_ok, "one matching assertion proves the subset ran")
	end)

	helpers.it("rejects empty and failed discovery", function()
		local empty_ok, empty_error = Contract.audit_manifest({}, { "tests.unit.test_alpha" })
		local failed_ok, failed_error = Contract.audit_manifest(nil,
			{ "tests.unit.test_alpha" }, "directory unreadable")

		helpers.assert_true(not empty_ok, "an empty discovery cannot satisfy a nonempty manifest")
		helpers.assert_contains(empty_error, "was not discovered",
			"the missing module must be named")
		helpers.assert_true(not failed_ok, "a discovery exception must be fatal")
		helpers.assert_contains(failed_error, "directory unreadable",
			"the discovery diagnosis must survive")
	end)

	helpers.it("rejects partial or stale manifests in both directions", function()
		local partial_ok, partial_error = Contract.audit_manifest(
			{ "tests.unit.test_alpha" },
			{ "tests.unit.test_alpha", "tests.unit.test_beta" }
		)
		local stale_ok, stale_error = Contract.audit_manifest(
			{ "tests.unit.test_alpha", "tests.unit.test_beta" },
			{ "tests.unit.test_alpha" }
		)

		helpers.assert_true(not partial_ok, "a missing discovered module must fail")
		helpers.assert_contains(partial_error, "test_beta", "the missing module must be named")
		helpers.assert_true(not stale_ok, "an unmanifested discovered module must fail")
		helpers.assert_contains(stale_error, "test_beta", "the unexpected module must be named")
	end)

	helpers.it("retains a missing dependency as a module load failure", function()
		local attempted, errors = Contract.load_modules({ "tests.unit.test_missing" }, function(name)
			error("cannot load " .. name)
		end)

		helpers.assert_eq(attempted, 1, "the manifested module must be attempted")
		helpers.assert_eq(#errors, 1, "the load failure must be retained")
		helpers.assert_contains(errors[1].error, "test_missing",
			"the failing dependency must be diagnosable")
	end)

	helpers.it("rejects an unmatched filter and an assertion-free full run", function()
		local filtered_ok, filtered_error = Contract.audit_execution(2, 0, 0, "no-such-test")
		local full_ok, full_error = Contract.audit_execution(2, 0, 0, nil)

		helpers.assert_true(not filtered_ok, "an unmatched --only filter must fail")
		helpers.assert_contains(filtered_error, "no-such-test", "the filter must be named")
		helpers.assert_true(not full_ok, "loading modules without assertions must fail")
		helpers.assert_contains(full_error, "no assertion", "the empty run must explain itself")
	end)

end)

helpers.describe("linux test runner: unit module continuation", function()
	helpers.it("(linux-unit-module-continuation) loads the actual pair module after an earlier failure without exiting", function()
		-- A separate real helper tally retains a deliberate earlier failure. Skip
		-- pair bodies here: their ordinary cases remain owned by the canonical run.
		local actor, transcript = capture_continuation(function()
			local isolated = assert(loadfile(helpers.driver_root() .. "/tests/helpers.lua"))()
			isolated.it("controlled earlier unit failure", function() error("controlled preceding failure") end)
			isolated.set_only_filter("__pair_module_continuation_no_body__")
			local declared, describe = {}, isolated.describe
			isolated.describe = function(name, body)
				declared[name] = true
				return describe(name, body)
			end
			local exit_calls = 0
			package.loaded["tests.helpers"], package.loaded[CONTINUATION_MODULE] = isolated, nil
			os.exit = function()
				exit_calls = exit_calls + 1
				error("a unit module attempted to terminate its canonical runner", 0)
			end
			local loaded, result = pcall(require, CONTINUATION_MODULE)
			return { isolated = isolated, declared = declared, exit_calls = exit_calls, loaded = loaded, result = result }
		end)
		helpers.assert_true(actor.loaded, "the real module must finish loading despite the earlier failure: " .. tostring(actor.result))
		helpers.assert_eq(actor.exit_calls, 0, "only the canonical runner may terminate the process")
		helpers.assert_true(actor.declared["global scope includes only original known simultaneous leaves"],
			"the module must reach its controls after the former premature exit")
		helpers.assert_eq(actor.isolated.get_results().failed, 1, "loading must preserve the earlier failure")
		helpers.assert_eq(actor.isolated.get_results().failures[1].name, "controlled earlier unit failure",
			"the canonical runner retains the exact earlier failing case")
		local diagnostic = table.concat(transcript, "\n")
		helpers.assert_contains(diagnostic, "  FAIL controlled earlier unit failure")
		helpers.assert_contains(diagnostic, "controlled preceding failure")
		helpers.assert_contains(diagnostic, "=== global scope includes only original known simultaneous leaves ===")
	end)

	helpers.it("(linux-private-runner-restoration) restores private output and module owners after an actor raises", function()
		local modules, old_exit, old_print = package.loaded, os.exit, print
		local old_helpers, old_module = modules["tests.helpers"], modules[CONTINUATION_MODULE]
		local retained
		local ran, detail = pcall(capture_continuation, function(transcript)
			retained = transcript
			print("private actor diagnostic", nil, false)
			modules["tests.helpers"], modules[CONTINUATION_MODULE] = {}, {}
			os.exit = function() error("private exit must not survive", 0) end
			error("controlled continuation capture failure", 0)
		end)
		helpers.assert_eq(ran, false)
		helpers.assert_contains(tostring(detail), "controlled continuation capture failure")
		helpers.assert_true(print == old_print and os.exit == old_exit, "restore the exact public output and exit owners")
		helpers.assert_true(modules["tests.helpers"] == old_helpers and modules[CONTINUATION_MODULE] == old_module,
			"restore the exact module owners even when private execution raises")
		helpers.assert_eq(retained, { "private actor diagnostic\tnil\tfalse" })
	end)
end)

require("test.runner_timing_contract").run(helpers)

require("test.runner_home_contract").run(helpers)

require("test.runner_replay_contract").run(helpers, "linux")

helpers.describe("linux test runner: UTF-8 timing frames", function()
	helpers.it("(runner-output-utf8) retains valid diagnostic names for malformed byte inputs", function()
		local quote = require("text_utils").shell_quote
		local root = helpers.driver_root()
		local command = "cd " .. quote(root)
			.. " && luajit tests/run.lua --only onboarding-linux-trigger 2>&1"
		helpers.assert_eq(debug.getinfo(io.popen, "S").what, "C", "the capture must use native process I/O")
		-- A private load cannot inherit another fixture's _set_runner seam.
		local Shell = assert(loadfile(root .. "/adapters/shell_runner.lua"))()
		local Errors = require("adapter_errors")
		local function validate_output(output)
			helpers.assert_type(output, "string")
			helpers.assert_true(#output > 0, "an empty capture cannot prove timing coverage")
			local utf8 = require("compat.utf8")
			helpers.assert_true(utf8.len(output) ~= nil, "the whole canonical output must be valid UTF-8")
			local Json = require("json")
			local prefix = "# lua_timing "
			local case_count, module_count, unsafe_names = 0, 0, {}
			for line in output:gmatch("[^\n]+") do
				if line:sub(1, #prefix) == prefix then
					helpers.assert_true(utf8.len(line) ~= nil, "each timing frame must be valid UTF-8")
					local row = Json.decode(line:sub(#prefix + 1))
					helpers.assert_type(row, "table")
					helpers.assert_eq(row.schema, 1)
					helpers.assert_eq(row.driver, "linux")
					helpers.assert_eq(row.status, "pass")
					helpers.assert_eq(row.timing_error, "")
					if row.kind == "case" then
						case_count = case_count + 1
						helpers.assert_eq(row.module, "tests.unit.ui.editors.test_ui_bridge_handlers_onboarding")
						if row.name:find("refuses unsafe answer", 1, true) then
							unsafe_names[row.name] = (unsafe_names[row.name] or 0) + 1
						end
					else
						helpers.assert_eq(row.kind, "module")
						module_count = module_count + 1
					end
				end
			end
			helpers.assert_eq(case_count, 20, "all actual onboarding subject assertions must run")
			helpers.assert_true(module_count > 0, "the canonical module loader must also emit timings")
			local expected = {}
			for _, case in ipairs({
				{ "dialog.magic_key.error_common", "semicolon" },
				{ "dialog.magic_key.error_common", "accented letter" },
				{ "dialog.magic_key.error_common", "ASCII letter" },
				{ "dialog.magic_key.error_common", "Hebrew letter" },
				{ "dialog.magic_key.error_length", "multiple characters" },
				{ "dialog.magic_key.error_length", "invalid leading byte" },
				{ "dialog.magic_key.error_length", "overlong sequence" },
				{ "dialog.magic_key.error_empty", "empty input" },
			}) do
				expected["(onboarding-linux-trigger) refuses unsafe answer " .. case[1] .. " " .. case[2]] = 1
			end
			helpers.assert_eq(unsafe_names, expected, "every malformed-input vector retains its distinct authored label")
		end
		local ok, output, failure = Shell.exec_checked(command)
		helpers.assert_true(ok, "the actual canonical child must complete: " .. tostring(failure))
		validate_output(output)
		-- Complete valid frames cannot conceal a later failing process teardown.
		local late_status = 73
		local accepted, late_output, _, reason, status = Shell.exec_checked(command .. "; exit " .. late_status)
		helpers.assert_eq(accepted, false, "late child failure must refuse the complete capture")
		helpers.assert_eq(reason, Errors.COMMAND_EXITED_NONZERO)
		helpers.assert_eq(status, late_status)
		validate_output(late_output)
	end)
end)
