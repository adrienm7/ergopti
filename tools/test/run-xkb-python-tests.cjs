// tools/test/run-xkb-python-tests.cjs

/**
 * ==============================================================================
 * MODULE: Linux XKB Python Test Runner
 * DESCRIPTION:
 * Runs the two Python suites of the Linux layout stack from one command: the
 * .keylayout to XKB converter (xkb_generation/tests) and the installers
 * (xkb_installation/tests). verify-change selects it for any change to the
 * converter, the installers, the layout registry or the shared keycode table.
 *
 * FEATURES & RATIONALE:
 * 1. Both suites are standard-library Python; the interpreter comes from
 *    $PYTHON (default "python"), the variable install.sh already honours.
 * 2. A suite that cannot start (no interpreter) is reported as a failure with
 *    its reason, never as a pass: a null spawn status is not a green run.
 * ==============================================================================
 */

'use strict';

const { spawnSync } = require('child_process');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const PYTHON = process.env.PYTHON || 'python';
const SUITES = [
	'static/ergopti/linux/xkb_generation/tests/run_all_tests.py',
	'static/ergopti/linux/xkb_installation/tests/run_all_tests.py'
];

let failed = 0;
for (const suite of SUITES) {
	console.log(`\n=== ${PYTHON} ${suite} ===`);
	const result = spawnSync(PYTHON, [suite], {
		cwd: ROOT,
		stdio: 'inherit',
		env: { ...process.env, PYTHONIOENCODING: 'utf-8' }
	});
	if (result.error || result.status !== 0) {
		failed += 1;
		const reason = result.error ? result.error.message : `exit status ${result.status}`;
		console.error(`FAILED ${suite}: ${reason}`);
	}
}
if (failed > 0) {
	console.error(`\n${failed}/${SUITES.length} XKB Python suite(s) failed.`);
	process.exit(1);
}
console.log(`\nAll ${SUITES.length} XKB Python suites passed.`);
