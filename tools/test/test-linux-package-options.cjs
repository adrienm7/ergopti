// tools/test/test-linux-package-options.cjs

/**
 * MODULE: Linux System Package Argument Admission Regression
 * Invokes the real DEB/RPM entry points with invalid argument orders and proves
 * they refuse before replacing existing staging state. Documented skip modes
 * still perform real staging against a freshly built native runtime bundle.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '../..');
const env = { ...process.env, ERGOPTI_BUILD_VERSION: '1.0.3' };
function run(script, args = []) {
	return spawnSync(bashExecutable(), [path.join(ROOT, 'tools/build', script), ...args], {
		cwd: ROOT,
		env,
		encoding: 'utf8',
		timeout: 120000,
		maxBuffer: 4 * 1024 * 1024
	});
}
const built = run('build-linux-driver.sh');
assert.equal(built.status, 0, built.stderr || built.stdout || built.error?.message);
let refusals = 0;
for (const format of ['deb', 'rpm']) {
	const script = `build-linux-${format}.sh`;
	const skip = `--skip-${format}`;
	const stage = path.join(ROOT, 'build/linux', format);
	const marker = path.join(stage, 'argument-validation-sentinel');
	fs.mkdirSync(stage, { recursive: true });
	fs.writeFileSync(marker, 'existing staging must survive refused arguments\n');
	const before = fs.statSync(marker);
	for (const args of [
		[skip, '--not-an-option'],
		['--not-an-option'],
		['--not-an-option', skip],
		[skip, 'unexpected'],
		[skip, format === 'deb' ? '--skip-rpm' : '--skip-deb'],
		['unexpected']
	]) {
		const result = run(script, args);
		assert.notEqual(result.status, 0, `${script} must refuse ${args.join(' ')}`);
		assert.match(
			result.stderr,
			/Unknown option:/,
			'argument refusal must precede bundle/producer errors'
		);
		assert.equal(result.stdout, '', 'refused arguments must not begin a package build');
		assert.equal(
			fs.statSync(marker).ino,
			before.ino,
			'refusal must preserve existing staging inode'
		);
		assert.equal(
			fs.readFileSync(marker, 'utf8'),
			'existing staging must survive refused arguments\n'
		);
		refusals++;
	}
	const valid = run(script, [skip]);
	assert.equal(valid.status, 0, valid.stderr || valid.stdout || valid.error?.message);
	assert.ok(valid.stdout.includes(`Structure complete (${skip})`));
	assert.equal(
		fs.existsSync(marker),
		false,
		'a valid explicit staging request must still rebuild its owned tree'
	);
	console.log(`PASS package-argument-admission-${format}`);
}
console.log(`PASS package-argument-admission refused=${refusals} real-valid-staging=2`);
