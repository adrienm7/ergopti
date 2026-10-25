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
const os = require('node:os');
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
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-package-recipe-'));
try {
	const alias = path.join(scratch, "project root '\n literal");
	fs.symlinkSync(ROOT, alias, 'dir');
	for (const format of ['deb', 'rpm']) {
		const staged = spawnSync(
			bashExecutable(),
			[path.join(alias, `tools/build/build-linux-${format}.sh`), `--skip-${format}`],
			{
				cwd: ROOT,
				env,
				encoding: 'utf8',
				timeout: 120000,
				maxBuffer: 4 * 1024 * 1024
			}
		);
		assert.equal(staged.status, 0, staged.stderr || staged.stdout || staged.error?.message);
		const command = staged.stdout.match(
			format === 'deb' ? /^To package: (.+)$/m : /^  (rpmbuild .+)$/m
		)?.[1];
		assert.ok(command, 'the actual staging entry point must print its native producer recipe');
		const receipt = path.join(scratch, `${format}-argv`);
		const publicationReceipt = path.join(scratch, `${format}-publication-argv`);
		const executable = format === 'deb' ? 'dpkg-deb' : 'rpmbuild';
		// Record only the external producer boundary; real Bash parses the actual
		// printed recipe, including its quoting of literal source path bytes.
		const replay = spawnSync(
			bashExecutable(),
			[
				'-euc',
				`function ${executable} { printf '%s\\0' "$@" > "$ERGOPTI_PACKAGE_ARGV_RECEIPT";  }; function node { printf '%s\\0' "$@" > "$ERGOPTI_PACKAGE_PUBLICATION_RECEIPT"; }; ` +
					command
			],
			{
				cwd: ROOT,
				env: {
					...env,
					ERGOPTI_PACKAGE_ARGV_RECEIPT: receipt,
					ERGOPTI_PACKAGE_PUBLICATION_RECEIPT: publicationReceipt
				},
				encoding: 'utf8',
				timeout: 15000
			}
		);
		assert.equal(replay.status, 0, replay.stderr || replay.error?.message);
		const argv = fs.readFileSync(receipt, 'utf8').split('\0').slice(0, -1);
		const root = path.join(alias, 'build/linux', format);
		assert.deepEqual(
			argv,
			format === 'rpm'
				? [
						'--define',
						`_topdir ${root}`,
						'--define',
						`_rpmdir ${path.join(root, 'native-rpms')}`,
						'-bb',
						path.join(root, 'SPECS/ergopti.spec')
					]
				: [
						'--root-owner-group',
						'--build',
						root,
						path.join(alias, 'build/linux/ergopti_1.0.3_amd64.deb')
					]
		);
		if (format === 'rpm') {
			assert.deepEqual(fs.readFileSync(publicationReceipt, 'utf8').split('\0').slice(0, -1), [
				path.join(root, 'publish-linux-rpm.cjs'),
				path.join(root, 'native-rpms'),
				path.join(root, 'RPMS'),
				'ergopti',
				'1.0.3',
				'x86_64'
			]);
		}
		console.log(`PASS package-manual-recipe-literal-argv-${format}`);
	}
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
console.log(
	`PASS package-argument-admission refused=${refusals} real-valid-staging=2 manual-argv-replays=2`
);
