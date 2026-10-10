// tools/test/ci-linux-qualified-run.cjs

/** Assert the approved Linux disposition wrapper and the entire original command. */
'use strict';
const assert = require('node:assert/strict');

/**
 * Keep raw CI scripts exact: deferral grants no native credit and unknown modes fail.
 * The caller supplies its independent original command, never the observed body.
 * @param {string[]} actual Raw script lines from the workflow.
 * @param {string[]} original Independently fixed native command lines.
 */
function assertLinuxQualifiedRun(actual, original) {
	assert.ok(Array.isArray(original) && original.length > 0);
	assert.deepEqual(actual, [
		'set -euo pipefail',
		'receipt="$RUNNER_TEMP/stable-linux-e2e-suite.json"',
		'node tools/ci/dev-release-qualification.cjs --scope linux-e2e-suite --receipt "$receipt"',
		'mode="$(node tools/ci/dev-release-qualification.cjs --scope linux-e2e-suite --validate-scope-receipt "$receipt")"',
		'if [ "$mode" = deferred ]; then',
		'    echo "[DEFERRED] linux-e2e-suite: qualified=false; no suite assertion count is claimed."',
		'elif [ "$mode" = full ]; then',
		...original,
		'else',
		'    exit 1',
		'fi'
	]);
}

module.exports = { assertLinuxQualifiedRun };
