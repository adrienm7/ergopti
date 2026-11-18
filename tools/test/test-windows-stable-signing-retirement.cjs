// tools/test/test-windows-stable-signing-retirement.cjs

/**
 * ==============================================================================
 * MODULE: Stable Windows Signing Exception Retirement Test
 * DESCRIPTION:
 * Once SignPath signs the stable exe, retiring the unsigned exception is one
 * step: delete .github/ci/stable_windows_signing_exception.json. This test
 * proves that step leaves a working, strict gate: an absent file is the
 * retired state, every unsigned stable receipt is then refused, a signed
 * stable release is still admitted, the dev channel is unchanged, and no test
 * that reads the exception needs the file to exist.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const Signing = require('../ci/windows-stable-signing.cjs');

const root = path.resolve(__dirname, '..', '..');
const head = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
let passed = 0;
const check = (label, action) => {
	try {
		action();
	} catch (error) {
		error.message = `${label}: ${error.message}`;
		throw error;
	}
	passed++;
};

const stableEnv = (overrides = {}) => ({
	GITHUB_ACTIONS: 'true',
	GITHUB_REPOSITORY: 'adrienm7/ergopti',
	GITHUB_EVENT_NAME: 'push',
	GITHUB_REF: 'refs/heads/main',
	GITHUB_SHA: head,
	ERGOPTI_DEV_RELEASE_RELEASE: 'true',
	ERGOPTI_DEV_RELEASE_PRERELEASE: 'false',
	ERGOPTI_DEV_RELEASE_CHANNEL: 'main',
	ERGOPTI_DEV_RELEASE_TAG: 'v1.0.1',
	ERGOPTI_DEV_RELEASE_VERSION: '1.0.1',
	...overrides
});

// Runs the CLI entry with a given exception state and returns what it printed.
function run(args, env, policy) {
	const lines = [];
	const log = console.log;
	console.log = (line) => lines.push(line);
	try {
		Signing.main(args, env, policy);
	} finally {
		console.log = log;
	}
	return lines;
}

check('the shipped exception is still admitted, or already retired', () => {
	const file = path.join(root, '.github', 'ci', 'stable_windows_signing_exception.json');
	if (fs.existsSync(file)) {
		assert.deepEqual(Signing.POLICY, JSON.parse(fs.readFileSync(file, 'utf8')));
		assert.deepEqual({ ...Signing.POLICY, authorized: true }, Signing.EXCEPTION_RECORD);
	} else assert.equal(Signing.POLICY, null);
});

check('an absent exception file is the retired state; any other read failure refuses', () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-signing-exception-'));
	try {
		assert.equal(Signing.loadPolicy(path.join(dir, 'absent.json')), null);
		assert.throws(() => Signing.loadPolicy(dir), /EISDIR|EPERM|EACCES/);
		const altered = path.join(dir, 'altered.json');
		fs.writeFileSync(altered, JSON.stringify({ ...Signing.EXCEPTION_RECORD, channel: 'dev' }));
		assert.throws(() => Signing.loadPolicy(altered), /not admitted/);
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});

check('a retired exception refuses every unsigned stable receipt', () => {
	const env = stableEnv({
		ERGOPTI_WINDOWS_AUTHENTICODE_STATUS: 'NotSigned',
		ERGOPTI_UNSIGNED_ARTIFACT_SHA256: 'b'.repeat(64)
	});
	assert.throws(() => run(['--receipt'], env, null), /retired: a stable release must be signed/);
	const receipt = JSON.parse(run(['--receipt'], env, Signing.EXCEPTION_RECORD)[0]);
	assert.equal(
		receipt.signature,
		'NotSigned',
		'the same build is admitted while the exception lives'
	);
});

check('a retired exception still publishes a signed stable release, and only that', () => {
	// Without release-assets/windows-signing-qualification.json, as a signed build leaves it.
	assert.equal(
		fs.existsSync(path.join(root, 'release-assets', 'windows-signing-qualification.json')),
		false
	);
	assert.deepEqual(
		run(['--publication-admit'], stableEnv({ ERGOPTI_WINDOWS_SIGNING_CONFIGURED: 'true' }), null),
		['ERGOPTI_WINDOWS_SIGNING_QUALIFICATION_NOTE=']
	);
	assert.throws(
		() =>
			run(
				['--publication-admit'],
				stableEnv({ ERGOPTI_WINDOWS_SIGNING_CONFIGURED: 'false' }),
				null
			),
		/not admitted/
	);
	const dev = stableEnv({
		GITHUB_REF: 'refs/heads/dev',
		ERGOPTI_DEV_RELEASE_PRERELEASE: 'true',
		ERGOPTI_DEV_RELEASE_CHANNEL: 'dev',
		ERGOPTI_DEV_RELEASE_TAG: 'v1.0.1-dev.1',
		ERGOPTI_DEV_RELEASE_VERSION: '1.0.1-dev.1',
		ERGOPTI_WINDOWS_SIGNING_CONFIGURED: 'false'
	});
	assert.deepEqual(run(['--publication-admit'], dev, null), [
		'ERGOPTI_WINDOWS_SIGNING_QUALIFICATION_NOTE='
	]);
});

check('a retired exception refuses a receipt that the admitted record built', () => {
	const context = {
		github_actions: 'true',
		repository: 'adrienm7/ergopti',
		event_name: 'push',
		ref: 'refs/heads/main',
		release: true,
		prerelease: 'false',
		channel: 'main',
		tag: 'v1.0.1',
		version: '1.0.1'
	};
	const sha = 'a'.repeat(40);
	const hash = 'b'.repeat(64);
	const clock = new Date('2026-11-18T09:00:00Z');
	const value = Signing.receipt(context, sha, sha, hash, clock, Signing.EXCEPTION_RECORD);
	Signing.validateReceipt(value, context, sha, sha, hash, clock, Signing.EXCEPTION_RECORD);
	assert.throws(
		() => Signing.validateReceipt(value, context, sha, sha, hash, clock, null),
		/retired/
	);
});

check('no test needs the exception file to exist', () => {
	// Deleting the file must not break a test that copies or reads it.
	const tests = path.join(root, 'tools', 'test');
	for (const name of fs.readdirSync(tests).filter((entry) => entry.endsWith('.cjs'))) {
		const text = fs.readFileSync(path.join(tests, name), 'utf8');
		// POLICY is null once retired: a property read must follow a null check.
		for (const match of text.matchAll(/\bsigning\.POLICY\./gi))
			assert.match(
				text.slice(Math.max(0, match.index - 40), match.index),
				/POLICY === null \|\| !$/,
				name + ' reads a property of POLICY without a null check'
			);
		for (const match of text.matchAll(/'\.github\/ci\/stable_windows_signing_exception\.json'/g)) {
			const before = text.slice(Math.max(0, match.index - 200), match.index);
			const after = text.slice(match.index, match.index + 200);
			assert.ok(
				/\.\.\.\[[^\]]*$/.test(before) &&
					/^[^\]]*\]\.filter\(\(file\) =>\s*fs\.existsSync/.test(after),
				name + ' copies the exception file without an existence filter'
			);
		}
	}
});

console.log(`[OK] stable Windows signing exception retirement: ${passed} check(s)`);
