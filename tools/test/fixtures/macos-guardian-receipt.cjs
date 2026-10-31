// tools/test/fixtures/macos-guardian-receipt.cjs
// Constructed macOS guardian acceptance evidence for portable admission tests;
// never native proof. The receipt mirrors what
// tools/diagnostics/macos_helper_registration.py writes on a passing run.
'use strict';

const macRoles = require('../../ci/macos-stage-roles.cjs');

/** One passing collector receipt. */
function guardianReceipt() {
	const invoked = (exit, stdout) => ({ exit, stdout, stderr: '' });
	return {
		kind: 'native-helper-registration',
		full_git_bootstrap_verified: false,
		initial_job_status: 113,
		rejected: invoked(64, ''),
		registered: invoked(0, 'ready\n'),
		observed: invoked(0, 'ready\n'),
		repeated: invoked(0, 'ready\n'),
		rejected_unregister: invoked(64, ''),
		job_status_after_rejected_unregister: 0,
		unregistered: invoked(0, 'unregistered\n'),
		job_status_after_unregister: 113,
		repeated_unregister: invoked(0, 'unregistered\n'),
		job_status_after_repeated_unregister: 113,
		unregistration_verified: true,
		final_job_status: 113,
		job_absent_after_cleanup: true,
		cleanup_errors: []
	};
}

/** The lot record desktop-ci-evidence.cjs keeps for one guardian receipt. */
function guardianRecord(sha = 'a'.repeat(40), runner = 'macos-15', lot = 'clean') {
	return { schema_version: 1, platform: 'macos', sha, runner, lot, receipt: guardianReceipt() };
}

/**
 * One record per launch lot of the test-build plan, for tests whose subject is
 * another part of the verdict. test-desktop-ci-evidence authors its lots by hand.
 */
function guardianRecordsForPlan(sha, scenarios, release) {
	return macRoles
		.testbuildCells(scenarios, release)
		.filter((cell) => cell.role === 'launch')
		.map((cell) => guardianRecord(sha, cell.runner, cell.scenario));
}

module.exports = { guardianReceipt, guardianRecord, guardianRecordsForPlan };
