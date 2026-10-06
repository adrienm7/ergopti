// tools/test/test-ubuntu-ci-acquisition.cjs
/** Pins host archive acquisition; distro containers retain their own managers. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const pipeline = require('./ci-pipeline.cjs');
const browsers = require('../ci/install-playwright.cjs');

const root = path.resolve(__dirname, '../..');
const scopes = new Map([
	['ci-linux.yml', 30],
	['ci-macos.yml', 2],
	['ci.yml', 1],
	['linux-layout.yml', 2],
	['metrics-reader-bench.yml', 1]
]);
const command = 'sudo python3 "$GITHUB_WORKSPACE/tools/ci/ubuntu_apt.py"';

/** Rejects host updates outside the owner, missing acquisitions or forgiven failures. */
function problems(text, rel, floor) {
	const errors = [];
	let count = 0;
	for (const job of pipeline.jobsOfText(text, rel)) {
		for (const step of pipeline.steps(job.body)) {
			const lines = pipeline.runOf(step.body) || [];
			for (const line of lines.filter((line) => !line.trimStart().startsWith('#'))) {
				if (
					/\bplaywright\s+install(?:-deps)?\b[^\n]*--with-deps|\bplaywright\s+install-deps\b/.test(
						line
					)
				)
					errors.push('delegated host acquisition escapes the signed owner');
				if (/\bsudo\s+apt(?:-get)?\s+/.test(line)) errors.push('unscoped host acquisition');
				if (!line.includes('ubuntu_apt.py')) continue;
				count++;
				if (!line.trimStart().startsWith(command + ' ')) errors.push('foreign acquisition owner');
				if (/\|\||\|\s*tee\b/.test(line)) errors.push('acquisition status may not be forgiven');
			}
		}
	}
	if (count < floor) errors.push('missing acquisition floor');
	return errors;
}

const browserCommand = 'node tools/ci/install-playwright.cjs chromium webkit';
const coreWorkflow = fs.readFileSync(path.join(root, '.github/workflows/ci.yml'), 'utf8');
assert.equal(
	pipeline.stepField(pipeline.step(pipeline.job('core'), 'Install shared UI browsers'), 'run'),
	browserCommand
);
const unscopedBrowser = coreWorkflow.replace(
	browserCommand,
	'npx playwright install --with-deps chromium webkit'
);
assert.notEqual(unscopedBrowser, coreWorkflow);
assert.ok(problems(unscopedBrowser, '.github/workflows/ci.yml', 1).length);

const catalogue = {
	'ubuntu24.04-x64': {
		tools: ['fontconfig'],
		chromium: ['libnss3', 'fontconfig'],
		webkit: ['libgtk-3-0t64']
	}
};
const selected = ['fontconfig', 'libnss3', 'libgtk-3-0t64'];
browsers.pinnedVersion('1.58.2', '1.58.2');
for (const [actual, expected] of [
	['1.58.1', '1.58.2'],
	['1.58.2', undefined],
	[undefined, undefined],
	['', '']
])
	assert.throws(() => browsers.pinnedVersion(actual, expected));
assert.deepEqual(
	browsers.prerequisites('ubuntu24.04-x64', true, catalogue, ['chromium', 'webkit']),
	selected
);
for (const [platform, official, data, names] of [
	['debian12-x64', true, catalogue, ['chromium']],
	['ubuntu24.04-x64', false, catalogue, ['chromium']],
	['ubuntu24.04-x64', true, {}, ['chromium']],
	['ubuntu24.04-x64', true, catalogue, []],
	['ubuntu24.04-x64', true, catalogue, ['chromium', 'chromium']],
	['ubuntu24.04-x64', true, catalogue, ['--with-deps']],
	[
		'ubuntu24.04-x64',
		true,
		{ 'ubuntu24.04-x64': { tools: ['-o'], chromium: ['libnss3'] } },
		['chromium']
	]
])
	assert.throws(() => browsers.prerequisites(platform, official, data, names));
for (const [acquisition, browserExit] of [
	[0, 0],
	[100, 0],
	[0, 42]
]) {
	const calls = [];
	const result = browsers.prepare(['chromium', 'webkit'], {
		platform: 'ubuntu24.04-x64',
		official: true,
		catalogue,
		cli: '/owned/playwright/cli.js',
		execute: (exe, args) => {
			calls.push([exe, args]);
			return { status: calls.length === 1 ? acquisition : browserExit, signal: null };
		}
	});
	assert.equal(result, acquisition || browserExit);
	assert.equal(calls.length, acquisition === 0 ? 2 : 1);
	assert.deepEqual(calls[0], [
		'sudo',
		[
			'python3',
			path.join(root, 'tools/ci/ubuntu_apt.py'),
			'-y',
			'--no-install-recommends',
			...selected
		]
	]);
	if (acquisition === 0)
		assert.deepEqual(calls[1], [
			process.execPath,
			['/owned/playwright/cli.js', 'install', 'chromium', 'webkit']
		]);
}
for (const terminal of [
	{ status: null, signal: null },
	{ status: 0, signal: 'SIGTERM' }
]) {
	assert.throws(() =>
		browsers.prepare(['chromium'], {
			platform: 'ubuntu24.04-x64',
			official: true,
			catalogue,
			execute: () => terminal
		})
	);
}
const spawnFailure = new Error('Constructed child acquisition refusal');
assert.throws(
	() =>
		browsers.prepare(['chromium'], {
			platform: 'ubuntu24.04-x64',
			official: true,
			catalogue,
			execute: () => ({ error: spawnFailure })
		}),
	(error) => error === spawnFailure
);
for (const terminal of [
	{ status: null, signal: null },
	{ status: 0, signal: 'SIGTERM' },
	{ status: 0 },
	{ error: spawnFailure }
]) {
	let calls = 0;
	assert.throws(
		() =>
			browsers.prepare(['chromium'], {
				platform: 'ubuntu24.04-x64',
				official: true,
				catalogue,
				cli: '/owned/playwright/cli.js',
				execute: () => (++calls === 1 ? { status: 0, signal: null } : terminal)
			}),
		terminal.error ? (error) => error === spawnFailure : undefined
	);
	assert.equal(calls, 2, 'browser terminal refusal follows exactly one successful acquisition');
}

for (const [file, floor] of scopes) {
	const rel = '.github/workflows/' + file;
	const text = fs.readFileSync(path.join(root, rel), 'utf8');
	assert.deepEqual(problems(text, rel, floor), [], rel);
	for (const [name, replacement] of [
		['unscoped install', 'sudo apt-get install'],
		['unscoped update', 'sudo apt-get update && sudo apt-get install'],
		['wrong owner', 'python3 /foreign/ubuntu_apt.py'],
		['missing invocation', 'echo']
	]) {
		const changed = text.replace(command, replacement);
		assert.notEqual(changed, text, name + ' must actually mutate ' + rel);
		assert.ok(problems(changed, rel, floor).length, name + ' must refuse ' + rel);
	}
	for (const suffix of [' || true', ' || exit 0', ' | tee acquired.log']) {
		const changed = text.replace(/(ubuntu_apt\.py"[^\n]*)/, '$1' + suffix);
		assert.notEqual(changed, text, 'failure mutation must find an invocation');
		assert.ok(problems(changed, rel, floor).length, 'swallowed status must refuse ' + rel);
	}
}

const result = spawnSync(
	process.platform === 'win32' ? 'python' : 'python3',
	['tools/ci/ubuntu_apt_test.py'],
	{ cwd: root, encoding: 'utf8' }
);
assert.ifError(result.error);
assert.equal(result.signal, null);
assert.equal(result.status, 0, result.stdout + result.stderr);
assert.match(result.stderr, /Ran 7 tests in /);
console.log('PASS: signed Ubuntu host acquisition, failure controls and workflow mutations');
