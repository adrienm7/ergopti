// tools/test/test-untracked-driver-artifacts-do-not-affect-gates.cjs

/**
 * ==============================================================================
 * MODULE: Untracked Driver Artifact Isolation Regression
 * DESCRIPTION:
 * Proves architecture gates measure the staged commit candidate rather than
 * local runtime or personal files that happen to live below a driver root.
 *
 * ROOT CAUSE ENCODED:
 * Gates that walk the raw filesystem include personal files and runtime caches
 * that cannot ship. Platform symmetry must ignore those artifacts while still
 * rejecting asymmetric directories and new drivers present in Git's index.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const MACOS_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'macos');
const PLATFORM_GATE = 'tools/test/test-convention-p-platform-only.cjs';
const GATES = [
	PLATFORM_GATE,
	'tools/test/test-driver-tree-parity.cjs',
	'tools/test/test-source-trees-are-scanned.cjs',
	'tools/test/test-shared-sources-are-lf.cjs'
];

/**
 * Exercise the real platform gate with an isolated repository and private index.
 * The working tree stays unchanged while staged additions and removals alter
 * the candidate, so neither ignoring all new folders nor scanning disk can pass.
 */
function verifyPlatformCandidate() {
	const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-platform-candidate-'));
	const env = {
		...process.env,
		GIT_DIR: path.join(fixture, '.git'),
		GIT_WORK_TREE: fixture,
		GIT_INDEX_FILE: path.join(fixture, '.git', 'index')
	};
	const git = (args) => execFileSync('git', args, { cwd: fixture, env, encoding: 'utf8' });
	const write = (relative) => {
		const target = path.join(fixture, relative);
		fs.mkdirSync(path.dirname(target), { recursive: true });
		fs.writeFileSync(target, 'Private platform candidate fixture.\n');
		return relative;
	};
	const check = (status, message, missing = []) => {
		const result = spawnSync(process.execPath, [path.join(fixture, PLATFORM_GATE)], {
			cwd: fixture,
			env,
			encoding: 'utf8'
		});
		if (result.error) throw result.error;
		const output = `${result.stdout}${result.stderr}`;
		assert.equal(result.status, status, `${message}\n${output}`);
		for (const entry of missing)
			assert.ok(output.includes(`missing: ${entry}`), `${message}: ${entry}\n${output}`);
		return output;
	};
	try {
		git(['init', '--quiet']);
		fs.mkdirSync(path.join(fixture, 'tools', 'test'), { recursive: true });
		fs.copyFileSync(path.join(ROOT, PLATFORM_GATE), path.join(fixture, PLATFORM_GATE));
		const seeds = [];
		for (const driver of ['windows', 'macos', 'linux']) {
			seeds.push(write(`static/ergopti_plus/${driver}/adapters/README.md`));
			seeds.push(write(`static/ergopti_plus/${driver}/platform/remap/README.md`));
		}
		git(['add', '--', ...seeds]);
		check(0, 'the staged three-driver fixture must pass before contamination');

		fs.appendFileSync(path.join(fixture, '.git', 'info', 'exclude'), '\n__pycache__/\n');
		const cache = write('static/ergopti_plus/windows/platform/__pycache__/probe.pyc');
		assert.ok(
			git(['check-ignore', '--', cache]).includes(cache),
			'the cache probe must really be ignored'
		);
		write('static/ergopti_plus/windows/platform/untracked-folder/probe.txt');
		const extraDriver = write('static/ergopti_plus/scratch-driver/adapters/README.md');
		check(
			0,
			'untracked platform folders, ignored caches and an untracked driver cannot change symmetry'
		);

		git(['add', '--', extraDriver]);
		check(1, 'a newly staged driver still participates in symmetry', [
			'scratch-driver/platform/remap'
		]);
		git(['rm', '--cached', '--', extraDriver]);
		check(0, 'removing a driver from the index must exclude its remaining working files');

		const asymmetric = write('static/ergopti_plus/windows/platform/staged-folder/README.md');
		git(['add', '--', asymmetric]);
		check(1, 'a newly staged asymmetric platform folder must fail', [
			'linux/platform/staged-folder',
			'macos/platform/staged-folder'
		]);
		const counterparts = ['macos', 'linux'].map((driver) =>
			write(`static/ergopti_plus/${driver}/platform/staged-folder/README.md`)
		);
		git(['add', '--', ...counterparts]);
		check(0, 'staging the counterpart folders restores symmetry');
		git(['rm', '--cached', '--', asymmetric]);
		check(1, 'a staged deletion must count even while its file remains on disk', [
			'windows/platform/staged-folder'
		]);
		const platformSubjects = seeds
			.filter((file) => file.includes('/platform/'))
			.concat(counterparts);
		git(['rm', '--cached', '--', ...platformSubjects]);
		assert.match(
			check(1, 'removing every staged platform subject must not certify an empty union'),
			/no tracked platform\/ sub-folders found/
		);
	} finally {
		fs.rmSync(fixture, { recursive: true, force: true });
	}
}

const probeRoot = fs.mkdtempSync(path.join(MACOS_ROOT, 'untracked-gate-probe-'));
const nested = path.join(probeRoot, 'nested');
fs.mkdirSync(nested);
fs.writeFileSync(path.join(nested, 'personal.lua'), 'local enabled = true\r\nreturn enabled\r\n');

const failures = [];
try {
	verifyPlatformCandidate();
} catch (error) {
	failures.push(`${PLATFORM_GATE} candidate isolation\n${error.stack}`);
}
try {
	for (const gate of GATES) {
		const result = spawnSync(process.execPath, [path.join(ROOT, gate)], {
			cwd: ROOT,
			encoding: 'utf8'
		});
		if (result.status !== 0) {
			failures.push(`${gate}\n${result.stdout}${result.stderr}`);
		}
	}
} finally {
	fs.rmSync(probeRoot, { recursive: true, force: true });
}

if (failures.length > 0) {
	console.error(
		'\x1b[31m[ERROR] untracked driver artifacts contaminated commit-candidate gates:\x1b[0m'
	);
	for (const failure of failures) console.error(failure);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] all ${GATES.length} commit-candidate gates ignore untracked artifacts; staged platform asymmetry still fails.\x1b[0m`
);
