--- tests/unit/meta/test_runner_integrity.lua

--- ==============================================================================
--- MODULE: Linux Test Runner Integrity Regression Tests
--- DESCRIPTION:
--- Proves that empty/partial discovery, missing modules and unmatched filters are
--- failures. LNX-037 previously let all of them produce a green zero-test run.
--- ==============================================================================

local helpers = require("tests.helpers")
local Contract = require("tests.runner_contract")

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
